/-
  E2E/Tests/StatsCost.lean — `stats-cost`: the cost a stats call puts on a
  replica that holds identity records (pf-dev 2026-10-20: plain stats
  scanned the whole replication-metadata family, ~15 s and ~0.7 core).

  A MEASUREMENT on ONE candidate SHA, not a comparison of rc67 with the fix:
  it separates the cost of the scan by alternating, on the same cluster and
  at the same call rate, phases of plain `stats` (the fixed path: no scan)
  and of `stats tombstones` (the exact scan, i.e. what every plain stats
  used to do). The phases run in ABBA order (plain, exact, exact, plain)
  after a warm-up, so load order and cache warm-up are not attributed to
  either side. Compaction is not controlled (recorded only as the RocksDB
  pending-compaction stats before and after each phase).

  Per phase: the replica container's CPU (cgroup), CFS throttling (periods
  and time, against a 1-core limit as on pf-dev), each call's response time,
  forwards dropped / in flight, and the replication lag of a write burst made
  during the phase (seconds until the replica's item count matches the
  master's). Numbers are reported for review; the test asserts only that
  every reading was observed and the semantics hold (plain stats carries no
  scan, its live count equals the exact scan when writes are quiet). No SLO is decided here.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.StatsCost

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "stats-cost"
  «namespace» := "flare-stats-cost"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-stats-cost"
  storageBackend := "rocksdb"
  -- identity forwarding only (as pf-dev after 2026-10-20): the replica keeps
  -- one identity record per forwarded key; no WAL follow
  extraFlaredConf := "repl-identity-forward = true"
  flaredCpuLimit := "1"
}

/-- Keys to load (FLARE_E2E_STATS_COST_KEYS, default 300000). -/
private def keysCount : IO Nat := return (((← IO.getEnv "FLARE_E2E_STATS_COST_KEYS").bind String.toNat?).getD 300000)

private def statVal (out key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    let t := (line.trim.replace "\r" "")
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

private def debug (cmd : String) : IO (Except String String) := execInDebugPod cfg.debugPod cfg.«namespace» cmd

/-- One call from the debug pod with its response time (ms from the debug
pod's /proc/uptime, 10 ms resolution). busybox `date` has no `%N` (it
printed `…%N`, the arithmetic failed and EVERY call — the convergence
checks included — read as none: 9c2d5ac 39365950386 and 25c18c0
39374110632 were this, not a replica that did not converge). `quit` closes
the connection, so nc does not idle out its -w. -/
private def timedCall (ip cmd : String) : IO (Option (Nat × String)) := do
  match ← debug s!"s=$(cut -d' ' -f1 /proc/uptime); out=$(printf '{cmd}\\r\\nquit\\r\\n' | nc -w 60 {ip} {cfg.flarePort}); e=$(cut -d' ' -f1 /proc/uptime); echo \"MS=$(echo $s $e | awk '\{printf \"%d\", ($2-$1)*1000}')\"; echo \"$out\"" with
  | .error _ => return none
  | .ok o =>
    match (o.splitOn "\n").head?.bind (fun l => if l.startsWith "MS=" then (l.drop 3).trim.toNat? else none) with
    | some ms => return if (o.splitOn "END").length > 1 then some (ms, o) else none
    | none => return none

/-- The replica container's CPU (ns) and CFS counters, cgroup v2 or v1. -/
private def cgroupCpu (pod : String) : IO (Option (Nat × Nat × Nat × Nat)) := do
  match ← kubectl ["exec", pod, "-n", cfg.«namespace», "-c", "flared", "--", "sh", "-c",
      "if [ -f /sys/fs/cgroup/cpu.stat ]; then awk '/^usage_usec/{u=$2*1000} /^nr_periods/{p=$2} /^nr_throttled/{t=$2} /^throttled_usec/{tt=$2*1000} END{print u, p, t, tt}' /sys/fs/cgroup/cpu.stat; else u=$(cat /sys/fs/cgroup/cpuacct/cpuacct.usage); awk -v u=$u '/^nr_periods/{p=$2} /^nr_throttled/{t=$2} /^throttled_time/{tt=$2} END{print u, p, t, tt}' /sys/fs/cgroup/cpu/cpu.stat; fi"] with
  | .error _ => return none
  | .ok o =>
    match (o.trim.splitOn " ").map String.toNat? with
    | [some u, some p, some t, some tt] => return some (u, p, t, tt)
    | _ => return none

structure Phase where
  label : String
  cpuCores : Float
  periods : Nat
  throttled : Nat
  throttledSec : Float
  calls : Nat
  failedCalls : Nat
  latMedianMs : Nat
  latMaxMs : Nat
  droppedDelta : Int
  lagSec : Option Nat
  deriving Repr

private def median (xs : List Nat) : Nat :=
  let s := xs.mergeSort (· ≤ ·)
  s.getD (s.length / 2) 0

private def statNat (ip key : String) : IO (Option Nat) := do
  match ← timedCall ip "stats" with
  | some (_, o) => return (statVal o key).bind (·.toNat?)
  | none => return none

/-- Bulk writes of keys `pfx_lo..pfx_hi` in one connection, WITH replies:
true only when every one answered STORED / DELETED. Not noreply: a noreply
client write is forwarded to the replica as noreply too (fire-and-forget,
`op_set::_parse_text_client_parameters` reads nothing), so a connection
reset loses the writes in flight with no retry and no proxy_write_dropped —
edc6377 39382996034: master 40000 / replica 39180 after chunk 1, two
connection resets, dropped 0. That is a separate finding, not what this
suite measures. `quit` makes the server close, so nc does not idle out. -/
private def bulkRange (ip pfx : String) (lo hi : Nat) (del : Bool) : IO Bool := do
  let (line, ok) := if del then (s!"delete {pfx}_%d\\r\\n", "DELETED") else (s!"set {pfx}_%d 0 0 1\\r\\nv\\r\\n", "STORED")
  match ← debug s!"(seq {lo} {hi} | awk '\{printf \"{line}\", $1}'; printf 'quit\\r\\n') | nc -w 30 {ip} {cfg.flarePort} | grep -c '^{ok}'" with
  | .ok o => return o.trim.toNat? == some (hi - lo + 1)
  | .error _ => return false

private def bulk (ip pfx : String) (n : Nat) (del : Bool := false) : IO Bool := bulkRange ip pfx 1 n del

/-- Why the replica did not converge: both counts and the forwarding counters. -/
private def notConverged (mIp sIp what : String) : IO String := do
  let m ← statNat mIp "curr_items"
  let r ← statNat sIp "curr_items"
  let d ← statNat mIp "proxy_write_dropped"
  let q ← statNat mIp "total_thread_queue"
  return s!"PRECONDITION NOT MET (not a measurement): the replica did not converge after {what} within 300 s (items master {m} / replica {r}; master proxy_write_dropped {d}, total_thread_queue {q})"

/-- Seconds until the replica's item count equals the master's (≤ 300). -/
private def lag (mIp sIp : String) : IO (Option Nat) := do
  let t0 ← IO.monoMsNow
  for _ in [0:300] do
    match ← statNat mIp "curr_items", ← statNat sIp "curr_items" with
    | some a, some b => if a == b then return some (((← IO.monoMsNow) - t0) / 1000)
    | _, _ => pure ()
    IO.sleep 1000
  return none

private def runPhase (label cmd : String) (sPod mIp sIp : String) (secs intervalMs : Nat) (burstPfx : String) : IO (Except String Phase) := do
  let some (u0, p0, t0, tt0) ← cgroupCpu sPod | return .error "the replica's cgroup CPU counters cannot be read"
  let d0 := (← statNat sIp "proxy_write_dropped").getD 0
  let w0 ← IO.monoMsNow
  -- a write burst at the start of the phase: its replication lag is measured
  if !(← bulk mIp burstPfx 20000) then return .error "the phase's write burst failed"
  let deadline := w0 + secs * 1000
  let mut lats : List Nat := []
  let mut failed := 0
  repeat
    match ← timedCall sIp cmd with
    | some (ms, _) => lats := lats ++ [ms]
    | none => failed := failed + 1
    if (← IO.monoMsNow) ≥ deadline then break
    IO.sleep intervalMs.toUInt32
  let w1 ← IO.monoMsNow
  let some (u1, p1, t1, tt1) ← cgroupCpu sPod | return .error "the replica's cgroup CPU counters cannot be read"
  let d1 := (← statNat sIp "proxy_write_dropped").getD d0
  let lg ← lag mIp sIp
  let wall := (w1 - w0).toFloat / 1000.0
  return .ok { label, cpuCores := (u1 - u0).toFloat / 1.0e9 / wall, periods := p1 - p0, throttled := t1 - t0,
               throttledSec := (tt1 - tt0).toFloat / 1.0e9, calls := lats.length, failedCalls := failed,
               latMedianMs := median lats, latMaxMs := lats.foldl max 0,
               droppedDelta := (Int.ofNat d1) - (Int.ofNat d0), lagSec := lg }

private def fmt (p : Phase) : String :=
  s!"{p.label}: cpu {p.cpuCores} core; throttled {p.throttled}/{p.periods} periods ({p.throttledSec} s); calls {p.calls} ok / {p.failedCalls} failed, median {p.latMedianMs} ms, max {p.latMaxMs} ms; forwards dropped +{p.droppedDelta}; burst lag {(p.lagSec.map toString).getD "not converged"} s"

private def measure : IO TestResult := do
  let entries := parseNodeSync (← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync")
  let some mFqdn := findMasterFqdn entries 0 | return .fail "no P0 master in the operator's map"
  let some sE := entries.find? (fun e => e.fqdn != mFqdn) | return .fail "no replica in the operator's map"
  let podOf := fun (f : String) => (f.splitOn ".").head?.getD f
  let (mPod, sPod) := (podOf mFqdn, podOf sE.fqdn)
  let (some mIp, some sIp) := (← getPodIp mPod cfg.«namespace», ← getPodIp sPod cfg.«namespace») | return .fail "pod IPs not resolved"
  -- identity records on the replica: keys written to the master are
  -- forwarded with their identity; a tenth are deleted (tombstones)
  let n ← keysCount
  IO.eprintln s!"# stats-cost: loading {n} keys (+{n / 10} deletes) through the master {mPod}"
  -- in chunks of 20000, each followed by convergence (kept; the earlier
  -- "non-convergence" was the broken stats reader above)
  let chunk := 20000
  for i in [0:(n + chunk - 1) / chunk] do
    if !(← bulkRange mIp "sc" (i * chunk + 1) (min n ((i + 1) * chunk)) false) then return .fail s!"the bulk load failed at chunk {i}"
    if (← lag mIp sIp).isNone then return .fail (← notConverged mIp sIp s!"load chunk {i}")
  if !(← bulkRange mIp "sc" 1 (n / 10) true) then return .fail "the bulk deletes failed"
  let some l0 ← lag mIp sIp | return .fail (← notConverged mIp sIp "the deletes")
  IO.eprintln s!"# stats-cost: replica converged {l0} s after the load"
  -- semantics: plain stats carries the LIVE count (a delta counter seeded at
  -- open), O(1); it must equal the exact scan once writes are quiet
  let some (_, plain0) ← timedCall sIp "stats" | return .fail "plain stats unreadable"
  let some (scanMs, exact) ← timedCall sIp "stats tombstones" | return .fail "the exact count failed"
  let exactN := (statVal exact "repl_tombstones").bind (·.toNat?)
  let some (_, plain1) ← timedCall sIp "stats" | return .fail "plain stats unreadable"
  IO.eprintln s!"# stats-cost: live before={statVal plain0 "repl_tombstones"} (known={statVal plain0 "repl_tombstones_known"}); exact {exactN} in {scanMs} ms; live after={statVal plain1 "repl_tombstones"}"
  if statVal plain1 "repl_tombstones_known" != some "1" then return .fail "plain stats reports the live tombstone count as unknown"
  if exactN.isNone || statVal plain1 "repl_tombstones" != exactN.map toString then
    return .fail s!"the live count ({statVal plain1 "repl_tombstones"}) differs from the exact scan ({exactN})"
  -- warm-up, then ABBA, same rate (one call every 2 s), 120 s each
  let secs := 120
  let iv := 2000
  discard <| runPhase "warm-up (exact)" "stats tombstones" sPod mIp sIp 30 iv "sw"
  let mut phases : List Phase := []
  for (i, label, cmd) in [(1, "A1 plain", "stats"), (2, "B1 exact scan", "stats tombstones"), (3, "B2 exact scan", "stats tombstones"), (4, "A2 plain", "stats")] do
    match ← runPhase label cmd sPod mIp sIp secs iv s!"sb{i}" with
    | .ok p => phases := phases ++ [p]; IO.eprintln s!"# stats-cost: {fmt p}"
    | .error e => return .fail (s!"UNOBSERVABLE (not a performance verdict): phase {label}: {e}")
  if phases.any (·.calls == 0) then return .fail "UNOBSERVABLE: a phase completed no call"
  IO.eprintln s!"# stats-cost RESULT (one candidate SHA; scan cost separated by alternating phases, NOT rc67 vs the fix; compaction not controlled): {String.intercalate " | " (phases.map fmt)}"
  return .pass

def suite : TestSuite := {
  name := "stats-cost"
  setup := do
    deployCluster cfg
    IO.sleep 50000
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "stats cost on a replica with identity records: plain stats (no scan) vs the exact scan, alternated ABBA at the same rate; CPU, throttling, response time, dropped forwards, burst lag reported (measurement, no SLO)"
      run := measure }
  ] }

end FlareOperator.E2E.Tests.StatsCost
