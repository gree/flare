/-
  Metrics/FlaredStats.lean - Scrape flared `stats` and re-export as Prometheus.

  The operator already connects to every flared node (port 12121) to push node
  sync, and its own /metrics endpoint is already scraped by Prometheus and
  remote_written to Grafana Cloud. flared's own memcached-style `stats` (rocksdb
  cursor/sequence, curr_items, WAL-sync counters) are NOT otherwise exported, so
  the operator polls `stats` on a slow cadence and republishes the numeric ones
  as per-pod `flare_node_*` gauges. No sidecar, no extra ServiceMonitor.

  Wire protocol (operator -> flared:12121):
    Operator -> flared: "stats\r\n"
    flared   -> Operator: "STAT <key> <value>\r\n" (repeated) then "END\r\n"
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

/-- Parse `stats` text into (key, value) pairs, keeping only integer-valued
    STAT lines (the rocksdb/repl/curr_items counters are all integers; string
    and float stats like version/rusage are dropped). -/
def parseStats (text : String) : List (String × Float) :=
  text.splitOn "\n" |>.filterMap fun line =>
    match line.trim.splitOn " " |>.filter (· != "") with
    | ["STAT", key, val] =>
      match val.trim.toNat? with
      | some v => some (key, v.toFloat)
      | none => none
    | _ => none

/-- Connect to a flared node, send `stats`, read until END, return parsed
    numeric stats. Returns [] on any connection/parse failure (best-effort;
    metrics scraping must never disrupt the operator). -/
def queryFlaredStats (ip : String) (port : Nat) : IO (List (String × Float)) := do
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
        let sendPromise ← sock.send "stats\r\n".toUTF8
        let _ ← IO.wait sendPromise.result!
        -- Accumulate bytes until "END" appears or the peer closes / fuel runs out.
        let rec loop (fuel : Nat) (acc : ByteArray) : IO ByteArray := do
          match fuel with
          | 0 => return acc
          | fuel + 1 =>
            if (String.fromUTF8! acc |>.splitOn "END").length > 1 then
              return acc
            let promise ← sock.recv? 4096
            match ← IO.wait promise.result! with
            | .error _ => return acc
            | .ok none => return acc
            | .ok (some bytes) =>
              if bytes.isEmpty then return acc else loop fuel (acc ++ bytes)
        let raw ← loop 200 ByteArray.empty
        return parseStats (String.fromUTF8! raw)
    catch _ =>
      return []
    finally
      try
        let shutdownPromise ← sock.shutdown
        let _ ← IO.wait shutdownPromise.result!
      catch _ => pure ()

/-- Scrape every flared pod. `pods` is (podName, ip, port). Returns
    (podName, parsed-stats) for each reachable pod. -/
def scrapeAllFlared (pods : List (String × String × Nat))
    : IO (List (String × List (String × Float))) := do
  pods.mapM fun (name, ip, port) => do
    let stats ← queryFlaredStats ip port
    return (name, stats)

/-- flared stat key -> exported Prometheus metric name. Whitelist keeps
    cardinality bounded and names clean; non-numeric stats (version, master_id)
    are dropped by parseStats anyway. Covers the memcached operational stats
    (ops, hit rate, memory, connections, traffic), the backup freshness stats
    (for the RPO alert in docs/BACKUP_RESTORE.md), and the rocksdb/replication
    counters. All exported as gauges — PromQL rate() handles the monotonic ones
    (and flared-restart resets) fine. -/
def exportedKeys : List (String × String) :=
  [ -- memcached operations (rate() for ops/sec; hits/misses for hit ratio)
    ("cmd_get",                            "flare_node_cmd_get"),
    ("cmd_set",                            "flare_node_cmd_set"),
    ("get_hits",                           "flare_node_get_hits"),
    ("get_misses",                         "flare_node_get_misses"),
    ("delete_hits",                        "flare_node_delete_hits"),
    ("delete_misses",                      "flare_node_delete_misses"),
    ("incr_hits",                          "flare_node_incr_hits"),
    ("incr_misses",                        "flare_node_incr_misses"),
    ("evictions",                          "flare_node_evictions"),
    -- storage / memory
    ("curr_items",                         "flare_node_curr_items"),
    ("total_items",                        "flare_node_total_items"),
    ("bytes",                              "flare_node_bytes"),
    ("limit_maxbytes",                     "flare_node_limit_maxbytes"),
    -- connections / traffic
    ("curr_connections",                   "flare_node_curr_connections"),
    ("total_connections",                  "flare_node_total_connections"),
    ("bytes_read",                         "flare_node_bytes_read"),
    ("bytes_written",                      "flare_node_bytes_written"),
    ("uptime",                             "flare_node_uptime"),
    -- rocksdb / WAL replication
    ("rocksdb_repl_last_lsn",              "flare_node_repl_last_lsn"),
    ("rocksdb_latest_sequence_number",     "flare_node_latest_sequence_number"),
    ("rocksdb_wal_sync_success",           "flare_node_wal_sync_success"),
    ("rocksdb_wal_sync_lsn_ahead",         "flare_node_wal_sync_lsn_ahead"),
    ("rocksdb_wal_sync_master_id_mismatch","flare_node_wal_sync_master_id_mismatch"),
    ("rocksdb_wal_fallback_to_dump",       "flare_node_wal_fallback_to_dump"),
    ("rocksdb_resync_failure_count",       "flare_node_resync_failure_count"),
    -- backup freshness (alert on time() - last_backup_epoch)
    ("rocksdb_backup_success",             "flare_node_backup_success"),
    ("rocksdb_backup_failure",             "flare_node_backup_failure"),
    ("rocksdb_last_backup_epoch",          "flare_node_last_backup_epoch") ]

/-- Render a Prometheus gauge line. -/
private def gaugeLine (name cluster pod : String) (v : Float) : String :=
  s!"{name}\{cluster=\"{cluster}\",pod=\"{pod}\"} {v}\n"

/-- Render all per-pod flared metrics. Raw whitelisted gauges only: we
    deliberately do NOT emit a derived "cursor > sequence" boolean, because
    repl_last_lsn > latest_sequence_number is the NORMAL state of a healthy
    slave (its cursor lives in the master's higher sequence space). The
    actionable wedge signal is `flare_node_wal_sync_lsn_ahead` — it increments
    when a MASTER rejects slave syncs, i.e. the Bug A stranding symptom. -/
def exportNodeStats (snapshot : List (String × List (String × Float)))
    (cluster : String) : String := Id.run do
  let mut out := ""
  for (statKey, metricName) in exportedKeys do
    out := out ++ s!"# HELP {metricName} flared stat {statKey} (per pod)\n"
    out := out ++ s!"# TYPE {metricName} gauge\n"
    for (pod, stats) in snapshot do
      match stats.lookup statKey with
      | some v => out := out ++ gaugeLine metricName cluster pod v
      | none => pure ()
  return out

end FlareOperator.Metrics.FlaredStats
