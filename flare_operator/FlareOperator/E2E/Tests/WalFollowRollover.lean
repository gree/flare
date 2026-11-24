/-
  E2E/Tests/WalFollowRollover.lean — the WAL follower keeps up with a sustained write load
  while the master's WAL archive is small (issue flare-wal-follow-slow, PR #189).

  In production a partition took ~4,400 writes/s, the follower applied ~3,200 positions/s, the
  lag grew until the master's archived WAL no longer held the follower's position
  (`GetUpdatesSince` / LSN purged), the follower declared needs_rebuild and the operator
  reseated the replica although forwarding had kept its copy equal. The follower now applies
  a response's batches in groups, skips the tombstone sweep at a known-zero live tombstone
  count and asks for up to 4096 batches a request (~33,000 positions/s in the loop
  measurement, ~3,000 before).

  Cluster: 1 partition x 2 replicas, rocksdb on a PVC, production-like replication settings
  (repl-identity-forward, repl-follow-enabled: Setup's `walFollow` default, the same lines
  as `replIdentityForward` / `replFollowEnabled` in the CR) and a SMALL archive:
  2 MB write buffer, `rocksdb-wal-size-limit-mb` (default 4) and a 60 s TTL (the TTL makes
  RocksDB look at the archive every 30 s; the size cap is what binds, ~200 kB/s of WAL at
  4,000 writes/s fills it in about 20 s). The archive therefore holds the last ~80,000
  positions: a follower that falls ~1,000 positions/s behind (the base tree) loses its
  position inside two minutes.

  Load: FLARE_E2E_WALFOLLOW_RATE (default 4000) sets/s on the master from two paced
  connections (200 sets per 100 ms tick each, values differ per write, 200,000-key space per
  stream so keys are overwritten) for FLARE_E2E_WALFOLLOW_SECS (default 300) seconds. If the
  runner cannot deliver the rate, the achieved rate is printed and the verdict is judged
  against it (the precondition is that the archive rolled over: its oldest file advanced);
  lower FLARE_E2E_WALFOLLOW_WALMB to make a lower rate roll the archive.

  T1  during the load, the lag (master rocksdb_latest_sequence_number − replica
      repl_applied_lsn, every 10 s) stays under 20,000 positions and the follower never
      leaves `following`; the master logs no `GetUpdatesSince failed` and no `purged from
      WAL`; the replica's reconstruction_started, the FlareCluster's status.replicaRepairs,
      both pods' UIDs and restart counts, and the operator log (no REPLICA REPAIR / REBUILD /
      reseat line) are unchanged; the archive did roll over.
  T2  after the load stops, the replica drains to the master's position, item counts match,
      and a sample of keys has the same values on both copies.

  The base tree (7ae01d5d) was not run: follow ~3,000 positions/s against 4,000 writes/s
  gives ~1,000 positions/s of growing lag, the ~80,000-position archive is lost within about
  80-120 s, the follower declares needs_rebuild (lsn_purged), the operator files a repair
  and reseats the replica: T1 fails on the follow state, the lag bound,
  reconstruction_started and the ledger.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.WalFollowRollover

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def envNat (name : String) (dflt : Nat) : IO Nat :=
  return ((← IO.getEnv name).bind (·.toNat?)).getD dflt

private def walMb : IO Nat := envNat "FLARE_E2E_WALFOLLOW_WALMB" 4

private def cfgFor (walLimitMb : Nat) : ClusterConfig := {
  name := "wal-follow"
  «namespace» := "flare-wal-follow"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-wal-follow"
  storageBackend := "rocksdb"
  usePvc := true
  flaredMemoryLimit := "2Gi"
  flaredMemoryRequest := "1Gi"
  flaredCpuLimit := "2"
  extraFlaredConf :=
    "rocksdb-write-buffer-size-mb = 2\nrocksdb-wal-ttl-seconds = 60\nrocksdb-wal-size-limit-mb = "
      ++ toString walLimitMb ++ "\nrocksdb-block-cache-size-mb = 64"
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
}

private def cfg0 : ClusterConfig := cfgFor 4
private def ns : String := cfg0.«namespace»
private def debugPod : String := cfg0.debugPod
private def port : Nat := cfg0.flarePort

/-- the largest lag (positions) the follower may show while the load runs; the archive
    holds ~80,000 positions at the default size, the fixed follower shows ~1,300 -/
private def lagBound : Nat := 20000

private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

private def utcStamp : IO String := do
  let o ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.%NZ"] }
  return o.stdout.trim

private def statVal (out : String) (key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    let t := (line.trim.replace "\r" "")
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

private def statsOf (ip : String) : IO (Option String) := do
  match ← execInDebugPod debugPod ns s!"printf 'stats\\r\\n' | nc -w 3 {ip} {port}" with
  | .ok o => return some o
  | .error _ => return none

private def statNat (ip key : String) : IO (Option Nat) := do
  match ← statsOf ip with
  | none => return none
  | some o => return (statVal o key).bind (·.toNat?)

private def statStr (ip key : String) : IO (Option String) := do
  match ← statsOf ip with
  | none => return none
  | some o => return statVal o key

private def kget (args : List String) : IO String := do
  match ← kubectl args with
  | .ok o => return o.trim
  | .error _ => return ""

private def podField (pod jsonpath : String) : IO String :=
  kget ["get", "pod", pod, "-n", ns, "-o", s!"jsonpath={jsonpath}"]

private def ledger : IO String :=
  kget ["get", "flarecluster", cfg0.name, "-n", ns, "-o", "jsonpath={.status.replicaRepairs}"]

private def opLogSince (since : String) : IO String := do
  let mut acc := ""
  for op in ← getPodNames s!"app={cfg0.operatorName}" ns do
    match ← kubectl ["logs", "-n", ns, op, s!"--since-time={since}"] with
    | .ok o => acc := acc ++ o
    | .error _ => pure ()
  return acc

private def flaredLogSince (pod since : String) : IO String := do
  match ← hostCmd "timeout" ["-k", "5", "120", "kubectl", "logs", "-n", ns, pod, "-c", "flared", s!"--since-time={since}", "--tail=-1"] with
  | .ok o => return o
  | .error _ => return ""

private def countLines (log needle : String) : Nat :=
  ((log.splitOn "\n").filter (containsSubstr · needle)).length

/-- (masterPod, masterIp, replicaPod, replicaIp) of partition 0 -/
private def pair : IO (Except String (String × String × String × String)) := do
  let mut lastErr := ""
  for _ in [0:6] do
    let sync ← operatorTcpCmd debugPod ns cfg0.operatorName cfg0.operatorPort "node sync"
    let entries := parseNodeSync sync
    match findMasterFqdn entries 0 with
    | none => lastErr := "no Active P0 master in the operator's map"
    | some mFqdn =>
      match entries.find? (fun e => e.fqdn != mFqdn) with
      | none => lastErr := "no second node in the operator's map"
      | some s =>
        match ← getPodIp (podOf mFqdn) ns, ← getPodIp (podOf s.fqdn) ns with
        | some mIp, some sIp => return .ok (podOf mFqdn, mIp, podOf s.fqdn, sIp)
        | _, _ => lastErr := "could not resolve pod IPs"
    IO.sleep 5000
  return .error lastErr

/-- The oldest archived WAL file of a pod's RocksDB (its log number), if any. -/
private def oldestArchived (pod : String) : IO (Option Nat) := do
  match ← kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "sh", "-c",
      "ls /data/flare/flare.rocksdb/archive 2>/dev/null | sort | head -1"] with
  | .ok o => return ((o.trim.splitOn ".").head?.getD "").toNat?
  | .error _ => return none

private def archiveKb (pod : String) : IO Nat := do
  match ← kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "sh", "-c",
      "du -sk /data/flare/flare.rocksdb/archive 2>/dev/null | awk '{print $1}'"] with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

/-- One paced stream of sets on `ip`: `ticks` ticks of 100 ms, `perTick` sets each, over one
    connection; the key is `<pfx><k mod 200000>`, the value is the 16-digit write counter.
    Returns the number of STORED replies. -/
private def streamWindow (ip pfx : String) (start perTick ticks : Nat) : IO Nat := do
  let awk := "awk -v s=" ++ toString start ++ " -v n=" ++ toString perTick ++ " -v t=" ++ toString ticks
    ++ " -v p=" ++ pfx
    ++ " 'BEGIN{k=s; for(i=0;i<t;i++){for(j=0;j<n;j++){printf \"set %s%d 0 0 16\\r\\n%016d\\r\\n\", p, k%200000, k; k++}; fflush(); system(\"sleep 0.1\")}}'"
  let cmd := "(" ++ awk ++ "; sleep 3) | nc -w 40 " ++ ip ++ " " ++ toString port ++ " | grep -c STORED"
  let secs := ticks / 10 + 60
  match ← hostCmd "timeout" ["-k", "5", toString secs, "kubectl", "exec", debugPod, "-n", ns, "--", "sh", "-c", cmd] with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

/-- Paced load on `ip` until `endMs` (monotonic): windows of 120 s per stream. -/
private def streamLoop (ip pfx : String) (perTick endMs : Nat) : IO Nat := do
  let mut stored := 0
  let mut start := 0
  let ticks := 1200
  while (← IO.monoMsNow) + 30000 < endMs do
    let left := (endMs - (← IO.monoMsNow)) / 100
    let t := if left < ticks then left else ticks
    stored := stored + (← streamWindow ip pfx start perTick t)
    start := start + perTick * t
  return stored

private def sampleKeys : List String :=
  (List.range 40).flatMap fun i => ["a" ++ toString (i * 4999), "b" ++ toString (i * 4999 + 7)]

/-- `get` of the sample keys on one node: the whole reply text (values included) -/
private def getSample (ip : String) : IO (Option String) := do
  let cmd := "printf 'get " ++ String.intercalate " " sampleKeys ++ "\\r\\nquit\\r\\n' | nc -w 5 " ++ ip ++ " " ++ toString port
  match ← execInDebugPod debugPod ns cmd with
  | .ok o => return some (o.replace "\r" "")
  | .error _ => return none

def suite : TestSuite := {
  name := "wal-follow-rollover"
  setup := do
    let mb ← walMb
    let c := cfgFor mb
    IO.eprintln s!"# wal-follow-rollover: archive size cap {mb} MB"
    deployCluster c
    discard <| waitClusterSettled c
  teardown := cleanupCluster cfg0
  onFailure := dumpClusterDiagnostics ns s!"app={cfg0.operatorName}"
  tests := [
    { name := "T1: a sustained write load over a small WAL archive: the follower stays `following` with a bounded lag, the master never loses the archive (no GetUpdatesSince failed / purged from WAL), nothing is reseated (reconstruction_started, replicaRepairs, pods and operator log unchanged)"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let following ← waitForCondition "replica following" 180 do
            return (← statStr sIp "repl_follow_state") == some "following"
          if !following then return .fail "precondition: the replica never reached `following`"
          let rate ← envNat "FLARE_E2E_WALFOLLOW_RATE" 4000
          let secs ← envNat "FLARE_E2E_WALFOLLOW_SECS" 300
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let ledger0 ← ledger
          let uidM0 ← podField mPod "{.metadata.uid}"
          let uidS0 ← podField sPod "{.metadata.uid}"
          let rcM0 ← podField mPod "{.status.containerStatuses[0].restartCount}"
          let rcS0 ← podField sPod "{.status.containerStatuses[0].restartCount}"
          let since ← utcStamp
          let head0 := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
          -- the first archived file seen is the reference for "the archive rolled over"
          let t0 ← IO.monoMsNow
          let endMs := t0 + secs * 1000
          let perTick := rate / 2 / 10
          IO.eprintln s!"# load: {rate} sets/s target ({perTick} sets per 100 ms on each of 2 connections) for {secs} s; master {mPod} {mIp}, replica {sPod} {sIp}; archive cap {← walMb} MB"
          let la ← IO.asTask (streamLoop mIp "a" perTick endMs)
          let lb ← IO.asTask (streamLoop mIp "b" perTick endMs)
          let mut lags : List Nat := []
          let mut states : List String := []
          let mut archKbs : List Nat := []
          let mut oldest0 : Option Nat := none
          let mut oldest1 : Option Nat := none
          let mut i := 0
          while !(← IO.hasFinished la) || !(← IO.hasFinished lb) do
            IO.sleep 10000
            i := i + 1
            let head := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
            let applied := (← statNat sIp "repl_applied_lsn").getD 0
            let st := (← statStr sIp "repl_follow_state").getD "?"
            let lag := if head > applied then head - applied else 0
            let ak ← archiveKb mPod
            let od ← oldestArchived mPod
            if oldest0.isNone then oldest0 := od
            if od.isSome then oldest1 := od
            lags := lags ++ [lag]
            states := states ++ [st]
            archKbs := archKbs ++ [ak]
            IO.eprintln s!"# wal-follow {i * 10}s: state={st} lag={lag} (head {head}, applied {applied}) archive={ak}kB oldest archived log={od.map toString |>.getD "-"} items master={(← statNat mIp "curr_items").getD 0} replica={(← statNat sIp "curr_items").getD 0}"
          let storedA ← match ← IO.wait la with | .ok v => pure v | .error e => do IO.eprintln s!"# load a failed: {e}"; pure 0
          let storedB ← match ← IO.wait lb with | .ok v => pure v | .error e => do IO.eprintln s!"# load b failed: {e}"; pure 0
          let elapsed := ((← IO.monoMsNow) - t0) / 1000
          let head1 := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
          let achieved := (head1 - head0) / (if elapsed == 0 then 1 else elapsed)
          let maxLag := lags.foldl max 0
          let notFollowing := states.filter (· != "following")
          let mLog ← flaredLogSince mPod since
          let getFailed := countLines mLog "GetUpdatesSince failed"
          let purgedWal := countLines mLog "purged from WAL"
          let opLog ← opLogSince since
          let repairLines := countLines opLog "REPLICA REPAIR" + countLines opLog "REBUILD" + countLines opLog "reseat"
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          let ledger1 ← ledger
          let uidM1 ← podField mPod "{.metadata.uid}"
          let uidS1 ← podField sPod "{.metadata.uid}"
          let rcM1 ← podField mPod "{.status.containerStatuses[0].restartCount}"
          let rcS1 ← podField sPod "{.status.containerStatuses[0].restartCount}"
          IO.eprintln s!"# wal-follow summary: {elapsed} s, {storedA + storedB} STORED, positions {head0}→{head1} (≈{achieved}/s achieved); max lag {maxLag}; follow states other than following: {notFollowing}; archive oldest log {oldest0}→{oldest1}, archive kB max {archKbs.foldl max 0}; master GetUpdatesSince failed={getFailed}, purged from WAL={purgedWal}; operator repair/rebuild/reseat lines={repairLines}; reconstruction_started {recon0}→{recon1}; ledger '{ledger0}'→'{ledger1}'; restarts master {rcM0}→{rcM1}, replica {rcS0}→{rcS1}"
          -- the verdict: a run that never rolled the archive proves nothing
          let rolled := match oldest0, oldest1 with
            | some a, some b => b > a
            | _, _ => false
          if lags.length < 3 then return .fail s!"precondition: only {lags.length} lag sample(s); the load did not run"
          if head1 < head0 + 100000 then
            return .fail s!"precondition: only {head1 - head0} positions were written in {elapsed} s (≈{achieved}/s): the runner could not drive a load worth judging; lower FLARE_E2E_WALFOLLOW_WALMB or raise FLARE_E2E_WALFOLLOW_SECS"
          if !rolled then
            return .fail s!"precondition: the master's WAL archive did not roll over (oldest archived log {oldest0}→{oldest1}, archive up to {archKbs.foldl max 0} kB, cap {← walMb} MB): the run does not exercise a small archive; lower FLARE_E2E_WALFOLLOW_WALMB"
          if getFailed != 0 then return .fail s!"the master logged `GetUpdatesSince failed` {getFailed} time(s)"
          if purgedWal != 0 then return .fail s!"the master logged `not found (purged from WAL)` {purgedWal} time(s): the follower's position fell out of the archive"
          if !notFollowing.isEmpty then return .fail s!"the follower left `following` during the load: {notFollowing}"
          if maxLag > lagBound then return .fail s!"the follower lag reached {maxLag} positions (bound {lagBound}); samples {lags}"
          if recon1 != recon0 then return .fail s!"the replica was reconstructed during the load (reconstruction_started {recon0}→{recon1})"
          if ledger1 != ledger0 then return .fail s!"status.replicaRepairs changed during the load: '{ledger0}' → '{ledger1}'"
          if repairLines != 0 then return .fail s!"the operator logged {repairLines} REPLICA REPAIR / REBUILD / reseat line(s) during the load"
          if uidM0 != uidM1 || uidS0 != uidS1 then return .fail s!"a pod was replaced during the load (master {uidM0}→{uidM1}, replica {uidS0}→{uidS1})"
          if rcM0 != rcM1 || rcS0 != rcS1 then return .fail s!"a flared container restarted during the load (master {rcM0}→{rcM1}, replica {rcS0}→{rcS1})"
          return .pass },
    { name := "T2: after the load stops the replica drains to the master's position, the item counts match and a key sample has the same values on both copies"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let t0 ← IO.monoMsNow
          let drained ← waitForCondition "follower drains the backlog after the load stops" 300 do
            let head := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
            let applied := (← statNat sIp "repl_applied_lsn").getD 0
            return (← statStr sIp "repl_follow_state") == some "following" && applied ≥ head
          let drainS := ((← IO.monoMsNow) - t0) / 1000
          let mItems := (← statNat mIp "curr_items").getD 0
          let sItems := (← statNat sIp "curr_items").getD 0
          let mSample ← getSample mIp
          let sSample ← getSample sIp
          let found := match mSample with
            | some s => countLines s "VALUE "
            | none => 0
          IO.eprintln s!"# wal-follow after the load: drained={drained} in {drainS} s; items master={mItems} replica={sItems}; sample keys found on master {found}/{sampleKeys.length}; samples equal={mSample == sSample}"
          if !drained then return .fail "the replica did not drain to the master's position within 300 s of the load stopping"
          if mItems != sItems then return .fail s!"item counts differ after the drain: master {mItems}, replica {sItems}"
          if mItems == 0 then return .fail "no items on the master after the load"
          match mSample, sSample with
          | some m, some s =>
            if found < sampleKeys.length / 2 then return .fail s!"only {found} of {sampleKeys.length} sample keys exist on the master (the load did not write them)"
            if m != s then return .fail s!"the key sample differs between master and replica:\n master {m.take 400}\n replica {s.take 400}"
            return .pass
          | _, _ => return .fail "could not read the key sample from both copies" }
  ]
}

end FlareOperator.E2E.Tests.WalFollowRollover
