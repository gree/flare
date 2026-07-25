/-
  Metrics/FlaredStats.lean - Scrape flared `stats` and re-export as Prometheus.

  The operator already connects to every flared node (port 12121) to push node
  sync, and its own /metrics endpoint is already scraped by Prometheus and
  remote_written to Grafana Cloud. flared's own memcached-style `stats` (rocksdb
  cursor/sequence, curr_items, WAL-sync counters, thread-queue depth) are NOT
  otherwise exported, so the operator polls `stats` on a slow cadence and
  republishes the numeric ones per-pod. No sidecar, no extra ServiceMonitor.

  Metric names are wire-compatible with the standalone `flare_exporter`
  (moc2-analysis/flare-monitoring/flare_exporter): the memcached-origin stats use
  the standard prometheus/memcached_exporter names (memcached_*), and the
  flared-specific stats use the flared_* namespace (flared_up, flared_version,
  flared_node_map_version, flared_thread_queue_total, flared_process_*_cpu_*).
  That exporter runs one instance per daemon and lets the scrape target carry the
  pod identity; the operator scrapes every pod centrally, so each sample also
  carries explicit {cluster,pod} labels (honorLabels:true on the ServiceMonitor
  keeps pod=<flared-pod>). rocksdb/replication/backup stats have no exporter
  equivalent and are exported under flare_node_rocksdb_* as operator extras.

  Wire protocol (operator -> flared:12121), two commands on one connection:
    Operator -> flared: "stats\r\n"                (memcached + node_map_version)
    Operator -> flared: "stats threads queue\r\n"  (total_thread_queue)
    flared   -> Operator: "STAT <key> <value>\r\n" (repeated) then "END\r\n"
                          (once per command)
-/

import Std.Internal.UV.TCP
import Std.Net.Addr

namespace FlareOperator.Metrics.FlaredStats

open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4 IPv4Addr)

/-- Parse an IPv4 string into IPv4Addr (none if malformed). -/
private def parseIPv4 (s : String) : Option IPv4Addr :=
  let parts := s.split (· == '.')
  if parts.length != 4 then none
  else match parts.mapM (·.toNat?) with
    | none => none
    | some octets =>
      if octets.any (· > 255) then none
      else match octets with
        | [a, b, c, d] => some ⟨#v[a.toUInt8, b.toUInt8, c.toUInt8, d.toUInt8]⟩
        | _ => none

/-- Parse `stats` text into (key, raw-value) pairs, one per `STAT key value`
    line. Values are kept as strings (not parsed to Float) so string stats
    (version) and timeval stats (rusage_user = "sec.usec") survive; numeric
    conversion happens per-metric at export time. -/
def parseStatsRaw (text : String) : List (String × String) :=
  text.splitOn "\n" |>.filterMap fun line =>
    match line.trim.splitOn " " |>.filter (· != "") with
    | "STAT" :: key :: rest =>
      if rest.isEmpty then none else some (key, " ".intercalate rest)
    | _ => none

/-- Parse a non-negative decimal ("157740") or fixed-point ("10.962023",
    flared's rusage timeval format sec.usec) string into a Float. Returns none
    on anything non-numeric (e.g. the version string "1.3.4"). Integers up to
    2^53 (node_map_version ~4.7e10) are exact in f64. -/
def parseDecimal (s : String) : Option Float :=
  match s.trim.splitOn "." with
  | [whole] => whole.toNat?.map (·.toFloat)
  | [whole, frac] =>
    match whole.toNat?, frac.toNat? with
    | some w, some f =>
      let divisor := frac.foldl (fun acc _ => acc * 10.0) 1.0
      some (w.toFloat + f.toFloat / divisor)
    | _, _ => none
  | _ => none

/-- Look up a stat key and parse it as a Float (none if absent or non-numeric). -/
def numericLookup (stats : List (String × String)) (key : String) : Option Float :=
  (stats.lookup key).bind parseDecimal

/-- Connect to a flared node, send `stats` then `stats threads queue` on the same
    connection, read until each block's END, return the merged parsed stats.
    Returns [] on any connection/parse failure (best-effort; metrics scraping
    must never disrupt the operator). -/
def queryFlaredStats (ip : String) (port : Nat) : IO (List (String × String)) := do
  match parseIPv4 ip with
  | none => return []
  | some ipAddr =>
    let sock ← Socket.new
    let addr := SocketAddress.v4 (SocketAddressV4.mk ipAddr port.toUInt16)
    try
      let connectPromise ← sock.connect addr
      match ← IO.wait connectPromise.result! with
      | .error _ => return []
      | .ok () =>
        -- Pipeline both commands; flared answers each with its own STAT.../END
        -- block, so we read until we have seen 2 ENDs (or the peer closes / fuel
        -- runs out). `stats threads queue` yields total_thread_queue.
        let sendPromise ← sock.send "stats\r\nstats threads queue\r\n".toUTF8
        let _ ← IO.wait sendPromise.result!
        let rec loop (fuel : Nat) (acc : ByteArray) : IO ByteArray := do
          match fuel with
          | 0 => return acc
          | fuel + 1 =>
            -- ≥2 ENDs -> splitOn yields ≥3 parts: both blocks are in.
            if (String.fromUTF8! acc |>.splitOn "END").length ≥ 3 then
              return acc
            let promise ← sock.recv? 4096
            match ← IO.wait promise.result! with
            | .error _ => return acc
            | .ok none => return acc
            | .ok (some bytes) =>
              if bytes.isEmpty then return acc else loop fuel (acc ++ bytes)
        let raw ← loop 200 ByteArray.empty
        return parseStatsRaw (String.fromUTF8! raw)
    catch _ =>
      return []
    finally
      try
        let shutdownPromise ← sock.shutdown
        let _ ← IO.wait shutdownPromise.result!
      catch _ => pure ()

/-- Scrape every flared pod. `pods` is (podName, ip, port). Returns
    (podName, parsed-stats) for each pod; unreachable pods get [] (surfaced as
    flared_up=0). -/
def scrapeAllFlared (pods : List (String × String × Nat))
    : IO (List (String × List (String × String))) := do
  pods.mapM fun (name, ip, port) => do
    let stats ← queryFlaredStats ip port
    return (name, stats)

/-- memcached-origin stats → the STANDARD prometheus/memcached_exporter metric
    name (+ TYPE), matching flare_exporter so community memcached Grafana
    dashboards are drop-in. (statKey, metricName, promType). -/
def memcachedGauges : List (String × String × String) :=
  [ ("curr_items",        "memcached_current_items",       "gauge"),
    ("bytes",             "memcached_current_bytes",       "gauge"),
    ("limit_maxbytes",    "memcached_limit_bytes",         "gauge"),
    ("curr_connections",  "memcached_current_connections", "gauge"),
    ("total_connections", "memcached_connections_total",   "counter"),
    ("total_items",       "memcached_items_total",         "counter"),
    ("bytes_read",        "memcached_read_bytes_total",    "counter"),
    ("bytes_written",     "memcached_written_bytes_total", "counter"),
    ("evictions",         "memcached_items_evicted_total", "counter"),
    ("uptime",            "memcached_uptime_seconds",      "counter"),
    ("time",              "memcached_time_seconds",        "gauge") ]

/-- hit/miss-style stats → memcached_commands_total{command,status}, matching
    memcached_exporter / flare_exporter. `cmd_set` is handled separately (set =
    cmd_set - cas_*, like flare_exporter). (statKey, command, status). -/
def memcachedCommands : List (String × String × String) :=
  [ ("get_hits",      "get",    "hit"),
    ("get_misses",    "get",    "miss"),
    ("delete_hits",   "delete", "hit"),
    ("delete_misses", "delete", "miss"),
    ("incr_hits",     "incr",   "hit"),
    ("incr_misses",   "incr",   "miss"),
    ("decr_hits",     "decr",   "hit"),
    ("decr_misses",   "decr",   "miss"),
    ("touch_hits",    "touch",  "hit"),
    ("touch_misses",  "touch",  "miss"),
    ("cas_hits",      "cas",    "hit"),
    ("cas_misses",    "cas",    "miss"),
    ("cas_badval",    "cas",    "badval") ]

/-- flared-specific numeric stats → flared_* namespace (wire-compatible with
    flare_exporter). rusage_user/system are timeval strings "sec.usec" parsed as
    fixed-point seconds. (statKey, metricName, promType). -/
def flaredGauges : List (String × String × String) :=
  [ ("node_map_version",   "flared_node_map_version",                 "gauge"),
    ("total_thread_queue", "flared_thread_queue_total",               "gauge"),
    ("rusage_user",        "flared_process_user_cpu_seconds_total",   "counter"),
    ("rusage_system",      "flared_process_system_cpu_seconds_total", "counter") ]

/-- rocksdb/replication/backup stats → flare_node_rocksdb_* (operator extras; no
    memcached_exporter / flare_exporter equivalent). -/
def rocksdbKeys : List String :=
  [ "rocksdb_repl_last_lsn", "rocksdb_latest_sequence_number",
    "rocksdb_wal_sync_success", "rocksdb_wal_sync_lsn_ahead",
    "rocksdb_wal_sync_master_id_mismatch", "rocksdb_wal_fallback_to_dump",
    "rocksdb_resync_failure_count",
    -- backup freshness (alert on time() - flare_node_rocksdb_last_backup_epoch)
    "rocksdb_backup_success", "rocksdb_backup_failure", "rocksdb_last_backup_epoch" ]

/-- Render a Prometheus sample line with {cluster,pod} labels. -/
private def gaugeLine (name cluster pod : String) (v : Float) : String :=
  s!"{name}\{cluster=\"{cluster}\",pod=\"{pod}\"} {v}\n"

/-- Render a memcached_commands_total sample with command/status labels. -/
private def commandLine (cluster pod command status : String) (v : Float) : String :=
  s!"memcached_commands_total\{cluster=\"{cluster}\",pod=\"{pod}\",command=\"{command}\",status=\"{status}\"} {v}\n"

/-- Render all per-pod flared metrics. memcached-origin stats under the standard
    memcached_exporter names, flared-specific stats under flared_* — both
    wire-compatible with the standalone flare_exporter — and rocksdb/replication/
    backup under flare_node_rocksdb_*. No derived "cursor > sequence" boolean —
    that is the NORMAL state of a healthy slave; the actionable wedge signal is
    flare_node_rocksdb_wal_sync_lsn_ahead (a master rejecting slave syncs). -/
def exportNodeStats (snapshot : List (String × List (String × String)))
    (cluster : String) : String := Id.run do
  let mut out := ""
  -- memcached simple gauges/counters (standard names).
  for (statKey, metricName, ty) in memcachedGauges do
    out := out ++ s!"# HELP {metricName} memcached {statKey} (per pod)\n"
    out := out ++ s!"# TYPE {metricName} {ty}\n"
    for (pod, stats) in snapshot do
      match numericLookup stats statKey with
      | some v => out := out ++ gaugeLine metricName cluster pod v
      | none => pure ()
  -- memcached_commands_total (labeled by command/status).
  out := out ++ "# HELP memcached_commands_total Total memcached commands by command and status\n"
  out := out ++ "# TYPE memcached_commands_total counter\n"
  for (statKey, command, status) in memcachedCommands do
    for (pod, stats) in snapshot do
      match numericLookup stats statKey with
      | some v => out := out ++ commandLine cluster pod command status v
      | none => pure ()
  -- set = cmd_set - (cas_hits + cas_misses + cas_badval), matching flare_exporter
  -- (cmd_set counts CAS operations too; the cas breakdown is emitted above).
  for (pod, stats) in snapshot do
    match numericLookup stats "cmd_set" with
    | some cmdSet =>
      let cas := (numericLookup stats "cas_hits").getD 0.0
               + (numericLookup stats "cas_misses").getD 0.0
               + (numericLookup stats "cas_badval").getD 0.0
      out := out ++ commandLine cluster pod "set" "hit" (cmdSet - cas)
    | none => pure ()
  -- flared_up: 1 if the pod answered stats, 0 otherwise (unreachable pods are
  -- kept in the snapshot with an empty stat list).
  out := out ++ "# HELP flared_up Could the flared server be reached (per pod)\n"
  out := out ++ "# TYPE flared_up gauge\n"
  for (pod, stats) in snapshot do
    out := out ++ gaugeLine "flared_up" cluster pod (if stats.isEmpty then 0.0 else 1.0)
  -- flared_version{version}: constant 1, version carried as a label.
  out := out ++ "# HELP flared_version The version of this flared server (per pod)\n"
  out := out ++ "# TYPE flared_version gauge\n"
  for (pod, stats) in snapshot do
    match stats.lookup "version" with
    | some ver => out := out ++ s!"flared_version\{cluster=\"{cluster}\",pod=\"{pod}\",version=\"{ver}\"} 1\n"
    | none => pure ()
  -- flared-specific numeric gauges/counters (node_map_version, thread_queue, rusage).
  for (statKey, metricName, ty) in flaredGauges do
    out := out ++ s!"# HELP {metricName} flared {statKey} (per pod)\n"
    out := out ++ s!"# TYPE {metricName} {ty}\n"
    for (pod, stats) in snapshot do
      match numericLookup stats statKey with
      | some v => out := out ++ gaugeLine metricName cluster pod v
      | none => pure ()
  -- rocksdb / replication / backup (flare-specific, no memcached equivalent).
  for statKey in rocksdbKeys do
    let metricName := s!"flare_node_{statKey}"
    out := out ++ s!"# HELP {metricName} flared stat {statKey} (per pod)\n"
    out := out ++ s!"# TYPE {metricName} gauge\n"
    for (pod, stats) in snapshot do
      match numericLookup stats statKey with
      | some v => out := out ++ gaugeLine metricName cluster pod v
      | none => pure ()
  return out

end FlareOperator.Metrics.FlaredStats
