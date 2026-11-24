/-
  E2E/Tests/WalFollowDrain.lean — the WAL follower's DRAIN throughput (issue flare-wal-follow-slow,
  PR #189).

  wal-follow-rollover (a sustained ~4,000 writes/s) does not discriminate on a CI runner: the
  load generator tops out near 3,700/s and the old follower (~3,000 positions/s in the loop
  measurement) still keeps up (fixed: ≈3,687 writes/s, max lag 741; base: ≈3,779/s, max lag 719).
  This suite measures the drain directly instead of relying on the generator out-running the
  follower:

  1. the follower is held (test seam FLARE_TEST_FOLLOW_PAUSE_FILE on the replica; inert without
     the env) while four paced connections write ≥ FLARE_E2E_WALDRAIN_POSITIONS (default
     600,000) positions to the master; the master's WAL archive is large enough (256 MB cap,
     1 h TTL) to hold the whole backlog;
  2. the hold is lifted and the lag (master rocksdb_latest_sequence_number − replica
     repl_applied_lsn) is sampled until it is below 1,000;
  3. drain rate = (backlog − final lag) / seconds from the lift to that sample.

  T1  the drain rate is at least FLARE_E2E_WALDRAIN_MIN_RATE positions/s (default 12,000): the
      loop measurement gives ~33,000/s fixed and ~3,000/s on the base tree, so 12,000 is 4x the
      base and about a third of the fixed rate (margin for the CI runner's PVC and network);
      the follower stays `following`, the master logs no `GetUpdatesSince failed` / `purged
      from WAL`, the replica is not reconstructed (reconstruction_started, replicaRepairs, pod
      UIDs and restart counts unchanged).
  T2  after the drain the item counts match and a key sample has the same values on both copies.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.WalFollowDrain

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def envNat (name : String) (dflt : Nat) : IO Nat :=
  return ((← IO.getEnv name).bind (·.toNat?)).getD dflt

private def pauseFile : String := "/tmp/follow-pause"

private def cfg0 : ClusterConfig := {
  name := "wal-drain"
  «namespace» := "flare-wal-drain"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-wal-drain"
  storageBackend := "rocksdb"
  usePvc := true
  flaredMemoryLimit := "2Gi"
  flaredMemoryRequest := "1Gi"
  flaredCpuLimit := "2"
  extraFlaredConf :=
    "rocksdb-write-buffer-size-mb = 2\nrocksdb-wal-ttl-seconds = 3600\nrocksdb-wal-size-limit-mb = 256\nrocksdb-block-cache-size-mb = 64"
  flaredEnv := [("FLARE_TEST_FOLLOW_PAUSE_FILE", pauseFile)]
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
}

private def ns : String := cfg0.«namespace»
private def debugPod : String := cfg0.debugPod
private def port : Nat := cfg0.flarePort

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

private def sampleKeys : List String :=
  (List.range 40).flatMap fun i => ["a" ++ toString (i * 4999), "b" ++ toString (i * 4999 + 7)]

/-- `get` of the sample keys on one node: the whole reply text (values included) -/
private def getSample (ip : String) : IO (Option String) := do
  let cmd := "printf 'get " ++ String.intercalate " " sampleKeys ++ "\\r\\nquit\\r\\n' | nc -w 5 " ++ ip ++ " " ++ toString port
  match ← execInDebugPod debugPod ns cmd with
  | .ok o => return some (o.replace "\r" "")
  | .error _ => return none


/-- Hold the follower (create the pause file) on a pod. -/
private def setHold (pod : String) (on : Bool) : IO Unit := do
  let cmd := if on then s!"touch {pauseFile}" else s!"rm -f {pauseFile}"
  discard <| kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "sh", "-c", cmd]

private def lagOf (mIp sIp : String) : IO (Nat × Nat × Nat) := do
  let head := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
  let applied := (← statNat sIp "repl_applied_lsn").getD 0
  return (head, applied, if head > applied then head - applied else 0)



def suite : TestSuite := {
  name := "wal-follow-drain"
  setup := do
    deployCluster cfg0
    discard <| waitClusterSettled cfg0
  teardown := cleanupCluster cfg0
  onFailure := dumpClusterDiagnostics ns s!"app={cfg0.operatorName}"
  tests := [
    { name := "T1: a backlog the follower has not applied drains at the required rate (positions/s) with the follower `following`, no archive loss and no reseat"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let following ← waitForCondition "replica following" 180 do
            return (← statStr sIp "repl_follow_state") == some "following"
          if !following then return .fail "precondition: the replica never reached `following`"
          let want ← envNat "FLARE_E2E_WALDRAIN_POSITIONS" 600000
          let minRate ← envNat "FLARE_E2E_WALDRAIN_MIN_RATE" 12000
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let ledger0 ← kget ["get", "flarecluster", cfg0.name, "-n", ns, "-o", "jsonpath={.status.replicaRepairs}"]
          let uidS0 ← podField sPod "{.metadata.uid}"
          let uidM0 ← podField mPod "{.metadata.uid}"
          let rcS0 ← podField sPod "{.status.containerStatuses[0].restartCount}"
          let rcM0 ← podField mPod "{.status.containerStatuses[0].restartCount}"
          let since ← utcStamp
          -- 1. hold the follower, then write the backlog over four connections
          setHold sPod true
          IO.sleep 2000
          let (head0, applied0, _) ← lagOf mIp sIp
          let perTick := 500
          let streams := 4
          let ticks := want / streams / perTick
          IO.eprintln s!"# drain: follower held on {sPod}; writing {want} positions ({streams} connections x {perTick} sets / 100 ms x {ticks} ticks) to {mPod} {mIp}; head {head0}, applied {applied0}"
          let tw ← IO.monoMsNow
          let ts ← (List.range streams).mapM fun i =>
            IO.asTask (streamWindow mIp (String.singleton (Char.ofNat (97 + i))) 0 perTick ticks)
          let mut stored := 0
          for t in ts do
            stored := stored + (match ← IO.wait t with | .ok v => v | .error _ => 0)
          let writeS := ((← IO.monoMsNow) - tw) / 1000
          let (head1, applied1, lag1) ← lagOf mIp sIp
          IO.eprintln s!"# drain: wrote {stored} STORED in {writeS} s; head {head1}, applied {applied1}, backlog {lag1}"
          if lag1 < want * 8 / 10 then
            setHold sPod false
            return .fail s!"precondition: the backlog is only {lag1} positions (wanted ≈{want}; {stored} STORED, head {head0}→{head1}, applied {applied0}→{applied1})"
          -- 2. lift the hold and watch the lag fall
          let t0 ← IO.monoMsNow
          setHold sPod false
          let mut lag := lag1
          let mut samples : List (Nat × Nat) := []
          let mut doneMs := t0
          let mut i := 0
          while lag ≥ 1000 && i < 1200 do
            IO.sleep 500
            i := i + 1
            let (_, _, l) ← lagOf mIp sIp
            lag := l
            doneMs ← IO.monoMsNow
            samples := samples ++ [((doneMs - t0) / 1000, l)]
          let drainMs := if doneMs > t0 then doneMs - t0 else 1
          let moved := lag1 - lag
          let rate := moved * 1000 / drainMs
          IO.eprintln s!"# drain: lag {lag1}→{lag} in {drainMs} ms = {rate} positions/s (required ≥ {minRate}); samples (s, lag) {samples.take 40}"
          let mLog ← flaredLogSince mPod since
          let getFailed := countLines mLog "GetUpdatesSince failed"
          let purgedWal := countLines mLog "purged from WAL"
          let st := (← statStr sIp "repl_follow_state").getD "?"
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          let ledger1 ← kget ["get", "flarecluster", cfg0.name, "-n", ns, "-o", "jsonpath={.status.replicaRepairs}"]
          let uidS1 ← podField sPod "{.metadata.uid}"
          let uidM1 ← podField mPod "{.metadata.uid}"
          let rcS1 ← podField sPod "{.status.containerStatuses[0].restartCount}"
          let rcM1 ← podField mPod "{.status.containerStatuses[0].restartCount}"
          IO.eprintln s!"# drain: follow state {st}; GetUpdatesSince failed={getFailed}, purged from WAL={purgedWal}; reconstruction_started {recon0}→{recon1}; ledger '{ledger0}'→'{ledger1}'"
          if getFailed != 0 then return .fail s!"the master logged `GetUpdatesSince failed` {getFailed} time(s)"
          if purgedWal != 0 then return .fail s!"the master logged `purged from WAL` {purgedWal} time(s)"
          if recon1 != recon0 || ledger1 != ledger0 then return .fail s!"the replica was reseated (reconstruction_started {recon0}→{recon1}, replicaRepairs '{ledger0}'→'{ledger1}')"
          if uidM0 != uidM1 || uidS0 != uidS1 || rcM0 != rcM1 || rcS0 != rcS1 then return .fail "a pod was replaced or a flared container restarted"
          if lag ≥ 1000 then return .fail s!"the backlog did not drain within 600 s (lag {lag1}→{lag}, {rate} positions/s)"
          if st != "following" then return .fail s!"the follower is `{st}` after the drain"
          if rate < minRate then
            return .fail s!"the follower drained {moved} positions in {drainMs / 1000} s = {rate} positions/s, below the required {minRate} (loop measurement: ~33,000/s fixed, ~3,000/s base)"
          return .pass },
    { name := "T2: after the drain the item counts match and a key sample has the same values on both copies"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let drained ← waitForCondition "follower at the master's position" 300 do
            let (h, a, _) ← lagOf mIp sIp
            return a ≥ h
          let mItems := (← statNat mIp "curr_items").getD 0
          let sItems := (← statNat sIp "curr_items").getD 0
          let mSample ← getSample mIp
          let sSample ← getSample sIp
          let found := match mSample with
            | some s => countLines s "VALUE "
            | none => 0
          IO.eprintln s!"# drain after: drained={drained}; items master={mItems} replica={sItems}; sample keys found {found}/{sampleKeys.length}; equal={mSample == sSample}"
          if !drained then return .fail "the replica did not reach the master's position"
          if mItems != sItems then return .fail s!"item counts differ after the drain: master {mItems}, replica {sItems}"
          if mItems == 0 then return .fail "no items on the master"
          match mSample, sSample with
          | some m, some s =>
            if found < sampleKeys.length / 2 then return .fail s!"only {found} of {sampleKeys.length} sample keys exist on the master"
            if m != s then return .fail s!"the key sample differs:\n master {m.take 400}\n replica {s.take 400}"
            return .pass
          | _, _ => return .fail "could not read the key sample from both copies" }
  ]
}

end FlareOperator.E2E.Tests.WalFollowDrain
