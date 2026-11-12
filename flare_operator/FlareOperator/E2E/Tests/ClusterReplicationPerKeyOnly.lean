/-
  The opt-in cross-cluster snapshot-push switch
  (`spec.clusterReplication.snapshotPush: false` → flared
  `cluster-replication-snapshot-push = false`): a seed into a FRESH
  destination — one that would accept a snapshot push — runs as the per-key
  merge dump instead, so the destination keeps its own history.

  This makes the per-key-only option possible; it is not a decision to use
  it anywhere. The snapshot-push history problem (cluster-replication-faults
  T4/T5, review §10/§13) stays open and its tests stay as they are.

  Verdicts, separate tests:
    1. a failed seed (destination port closed) reports `failed_connect`,
       completes nothing and leaves the destination untouched;
    2. the seed declines the push and falls back to the per-key dump
       (`completed_dump`, `seed_snapshot_push_disabled` moved, the
       destination's `rocksdb_snapshot_bootstrap` 0) and the destination's
       master id / copy id / epoch are unchanged by it;
    3. verification V (kind-only capture: repl_snapshot + flared
       --dump-checkpoint) MATCHes every key, value, flag, expire and version,
       with deletes made before and after the seed absent on both sides;
    4. the destination master restarts (PVC kept) and comes back as master
       with the same history (the snapshot-push case stays masterless:
       faults T4), and V MATCHes again after more changes;
    5. in-cluster replica snapshots are not disabled by the switch: a
       source slave started empty reseeds by snapshot
       (`rocksdb_snapshot_bootstrap` moved on it).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ClusterReplicationPerKeyOnly

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfgSrc : ClusterConfig := {
  name := "crp-src"
  «namespace» := "flare-crp-src"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-crp-src"
  debugPod := "debug-crp"
  storageBackend := "rocksdb"
  -- a slave started empty rebuilds staged: the reserve must be in the CR
  -- (38183117517: "rebuild_blocked=reserve_unset", parked)
  reserveInCr := true
}

private def cfgDst : ClusterConfig := {
  name := "crp-dst"
  «namespace» := "flare-crp-dst"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crp-dst"
  debugPod := "debug-crp"
  storageBackend := "rocksdb"
  usePvc := true
  -- V captures this side too: a capture is refused without the reserve
  reserveInCr := true
}

private def dstSvc : String := s!"{cfgDst.name}-nodes.{cfgDst.«namespace»}.svc.cluster.local"
private def vDir : String := "/tmp/e2e-crp-v"

private def masterPod (cfg : ClusterConfig) : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return findMasterPod (parseNodeSync sync) 0

private def masterIp (cfg : ClusterConfig) : IO (Option String) := do
  match ← masterPod cfg with
  | none => return none
  | some m => getPodIp m cfg.«namespace»

private def statOf (cfg : ClusterConfig) (ip name : String) : IO (Option String) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith s!"STAT {name} " then some (t.drop s!"STAT {name} ".length).trim else none

private def statNat (cfg : ClusterConfig) (ip name : String) : IO Nat :=
  return ((← statOf cfg ip name).bind (·.toNat?)).getD 0

/-- master id / copy id of a node — the lineage a seed must not change. The
    epoch is printed but NOT compared across a restart: a re-promotion
    advances it by design ("source epoch advanced … reason: promotion",
    38183117517). -/
private def lineage (cfg : ClusterConfig) (ip : String) : IO String := do
  return s!"master_id={(← statOf cfg ip "rocksdb_master_id").getD "?"} copy_id={(← statOf cfg ip "rocksdb_copy_id").getD "?"}"

/-- master id / copy id / epoch of a node — the history a seed must not change. -/
private def identity (cfg : ClusterConfig) (ip : String) : IO String := do
  let ep ← match ← statOf cfg ip "rocksdb_rebuilt_from_epoch" with
    | some e => if e.isEmpty then statOf cfg ip "rocksdb_source_epoch" else pure (some e)
    | none => statOf cfg ip "rocksdb_source_epoch"
  return s!"master_id={(← statOf cfg ip "rocksdb_master_id").getD "?"} copy_id={(← statOf cfg ip "rocksdb_copy_id").getD "?"} epoch={ep.getD "?"}"

/-- A raw text command on the source master; the reply. -/
private def srcCmd (ip cmd : String) : IO String := do
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» s!"printf '{cmd}' | nc -w 3 {ip} {cfgSrc.flarePort}" with
  | .ok o => return o
  | .error e => return s!"ERROR {e}"

private def patchRepl (json : String) : IO (Except String String) :=
  kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» s!"\{\"spec\":\{\"clusterReplication\":{json}}}"

/-- Wait for a NEW seed (seed_started above `started0`) to end in a state
    `done` accepts — a state left by an earlier seed is not read as this
    one's (38183117517 read T1's failed_connect in T2). -/
private def waitSeed (ip : String) (started0 : Nat) (done : String → Bool) (timeoutSec : Nat) : IO String := do
  let _ ← waitForCondition "a new seed started and ended" timeoutSec do
    let started ← statNat cfgSrc ip "cluster_replication[seed_started]"
    return started > started0 && done ((← statOf cfgSrc ip "cluster_replication_seed").getD "")
  return (← statOf cfgSrc ip "cluster_replication_seed").getD "(none)"

/-- The ConfigMap reaches the pod late (kubelet sync): 38183117517 needed
    ~2 min after the disable. -/
private def waitReplicationOff (ip : String) : IO Bool :=
  waitForCondition "replication off on the source master" 300 do
    return (← statOf cfgSrc ip "cluster_replication") == some "off"

private def scriptsDir : IO String := do
  if ← System.FilePath.pathExists "../scripts/flare_verify_copy.py" then return "../scripts"
  else return "scripts"

private def runProc (cmd : String) (args : List String) : IO (UInt32 × String × String) := do
  let o ← IO.Process.output { cmd, args := args.toArray }
  return (o.exitCode, o.stdout, o.stderr)

/-- Capture both masters and compare. (exit code, verdict line, report head). -/
private def runV (tag : String) : IO (Except String (UInt32 × String)) := do
  let sd ← scriptsDir
  let dir := s!"{vDir}/{tag}"
  let _ ← runProc "rm" ["-rf", dir]
  let some sPod ← masterPod cfgSrc | return .error "no source master"
  let some dPod ← masterPod cfgDst | return .error "no destination master"
  for (side, ns, pod) in [("src", cfgSrc.«namespace», sPod), ("dst", cfgDst.«namespace», dPod)] do
    let (c, o, e) ← runProc "python3" [s!"{sd}/flare_v_capture_kind.py", "--ns", ns, "--out", s!"{dir}/{side}", pod]
    if c != 0 then return .error s!"{side} capture failed ({c}): {e.trim}"
    IO.eprintln s!"# V capture {tag} {side}: {o.trim}"
  let (c, _, err) ← runProc "python3" [s!"{sd}/flare_verify_copy.py",
    "--src-dump", s!"{dir}/src/{sPod}.dump", "--dst-dump", s!"{dir}/dst/{dPod}.dump",
    "--src-pre", s!"{dir}/src/pre.json", "--src-post", s!"{dir}/src/post.json",
    "--dst-pre", s!"{dir}/dst/pre.json", "--dst-post", s!"{dir}/dst/post.json",
    "--attempt-baseline", s!"{vDir}/baseline/stats.json", "--attempt-id", "crp-per-key-only",
    "--report", s!"{dir}/report.json"]
  let verdict := ((err.splitOn "\n").find? (·.startsWith "verdict: ")).getD ""
  let report ← try IO.FS.readFile s!"{dir}/report.json" catch _ => pure ""
  IO.eprintln s!"# V {tag}: exit {c}; {verdict}; report: {(report.replace "\n" " ").take 2000}"
  return .ok (c, verdict)

/-- Every source / destination key and the changes made around the seed. -/
private def seedData (ip : String) : IO (Option String) := do
  for i in List.range 20 do
    -- flags and a relative expiry (stored as an absolute time) vary per key
    let flag := i % 4
    let exp := if i % 3 == 0 then 3600 else 0
    let v := s!"v{i}-x"
    let r ← srcCmd ip s!"set crp_{i} {flag} {exp} {v.length}\\r\\n{v}\\r\\n"
    if !containsSubstr r "STORED" then return some s!"set crp_{i}: {r.trim}"
  -- deleted BEFORE the seed: must be absent on the destination
  for i in [0, 1] do
    let r ← srcCmd ip s!"delete crp_{i}\\r\\n"
    if !containsSubstr r "DELETED" then return some s!"delete crp_{i}: {r.trim}"
  return none

initialize dstIdentRef : IO.Ref String ← IO.mkRef ""

def suite : TestSuite := {
  name := "cluster-replication-per-key-only"
  setup := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
    deployCluster cfgSrc
    let s1 ← waitForStable cfgSrc 50
    if !s1 then throw (IO.userError "source cluster did not stabilize")
    deploySecondCluster cfgDst
    let s2 ← waitForStable cfgDst 50
    if !s2 then throw (IO.userError "destination cluster did not stabilize")
  onFailure := do
    dumpClusterDiagnostics cfgSrc.«namespace» s!"app={cfgSrc.operatorName}"
    dumpClusterDiagnostics cfgDst.«namespace» s!"app={cfgDst.operatorName}"
  teardown := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
  tests := [
    { name := "a failed seed with the switch (destination port closed) reports failed_connect, completes nothing and leaves the destination untouched"
      run := do
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let some dIp ← masterIp cfgDst | return .fail "no destination master"
        let c0 ← statNat cfgSrc sIp "cluster_replication[seed_completed]"
        let st0 ← statNat cfgSrc sIp "cluster_replication[seed_started]"
        match ← patchRepl s!"\{\"enabled\":true,\"serverName\":\"{dstSvc}\",\"port\":12199,\"mode\":\"duplicate\",\"concurrency\":1,\"snapshotPush\":false}" with
        | .error e => return .fail s!"enable failed: {e}"
        | .ok _ => pure ()
        let sp ← do
          let _ ← waitForCondition "the switch is applied (stat off)" 120 do
            return (← statOf cfgSrc sIp "cluster_replication_snapshot_push") == some "off"
          statOf cfgSrc sIp "cluster_replication_snapshot_push"
        let st ← waitSeed sIp st0 (fun s => s.startsWith "failed" || s.startsWith "completed") 400
        let c1 ← statNat cfgSrc sIp "cluster_replication[seed_completed]"
        let dItems ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp cfgDst.flarePort
        let boot ← statNat cfgDst dIp "rocksdb_snapshot_bootstrap"
        IO.eprintln s!"# failed seed: switch stat {sp}; seed state {st}; seed_completed {c0} → {c1}; destination items {dItems}, snapshot_bootstrap {boot}"
        -- stop it (explicit false), wait until the source reports off
        match ← patchRepl "{\"enabled\":false}" with
        | .error e => return .fail s!"disable failed: {e}"
        | .ok _ => pure ()
        let off ← waitReplicationOff sIp
        if sp != some "off" then return .fail s!"the source does not report the switch off (cluster_replication_snapshot_push {sp})"
        if st != "failed_connect" then return .fail s!"seed state {st}, want failed_connect"
        if c1 != c0 then return .fail s!"seed_completed moved {c0} → {c1} on a failed seed"
        if dItems != 0 || boot != 0 then return .fail s!"the destination changed: items {dItems}, snapshot_bootstrap {boot}"
        if !off then return .fail "replication did not stop"
        return .pass },

    { name := "with the switch, a seed into a FRESH destination declines the snapshot push and completes by per-key dump; the destination's master id / copy id / epoch are unchanged"
      run := do
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let some dIp ← masterIp cfgDst | return .fail "no destination master"
        -- the data below must not be forwarded by an earlier enable
        if !(← waitReplicationOff sIp) then return .fail "replication still on before the seed data was written"
        if let some why ← seedData sIp then return .fail s!"source data: {why}"
        let identBefore ← identity cfgDst dIp
        dstIdentRef.set (← lineage cfgDst dIp)
        let sd ← scriptsDir
        let some sPod ← masterPod cfgSrc | return .fail "no source master pod"
        let _ ← runProc "rm" ["-rf", s!"{vDir}/baseline"]
        let (cb, _, eb) ← runProc "python3" [s!"{sd}/flare_v_capture_kind.py", "--stats-only", "--ns", cfgSrc.«namespace»,
                                             "--out", s!"{vDir}/baseline", sPod]
        if cb != 0 then return .fail s!"baseline stats failed: {eb}"
        let d0 ← statNat cfgSrc sIp "cluster_replication[seed_snapshot_push_disabled]"
        let st0 ← statNat cfgSrc sIp "cluster_replication[seed_started]"
        match ← patchRepl s!"\{\"enabled\":true,\"serverName\":\"{dstSvc}\",\"port\":{cfgDst.flarePort},\"mode\":\"duplicate\",\"concurrency\":1,\"snapshotPush\":false}" with
        | .error e => return .fail s!"enable failed: {e}"
        | .ok _ => pure ()
        let st ← waitSeed sIp st0 (fun s => s.startsWith "failed" || s.startsWith "completed") 400
        let d1 ← statNat cfgSrc sIp "cluster_replication[seed_snapshot_push_disabled]"
        let boot ← statNat cfgDst dIp "rocksdb_snapshot_bootstrap"
        let identAfter ← identity cfgDst dIp
        IO.eprintln s!"# seed: state {st}; seed_snapshot_push_disabled {d0} → {d1}; destination snapshot_bootstrap {boot}; destination {identBefore} → {identAfter}"
        if st != "completed_dump" then return .fail s!"seed state {st}, want completed_dump"
        if d1 ≤ d0 then return .fail "seed_snapshot_push_disabled did not move: the push was not declined by the switch"
        if boot != 0 then return .fail s!"the destination took a snapshot (bootstrap {boot})"
        if identAfter != identBefore then return .fail s!"the destination history changed: {identBefore} → {identAfter}"
        -- changes while duplicating: overwrite (new flag), delete, add
        for (c, want) in [("set crp_5 9 0 4\\r\\nnew5\\r\\n", "STORED"), ("delete crp_6\\r\\n", "DELETED"),
                          ("set crp_new 1 3600 3\\r\\nabc\\r\\n", "STORED")] do
          let r ← srcCmd sIp c
          if !containsSubstr r want then return .fail s!"change {c}: {r.trim}"
        IO.sleep 10000
        return .pass },

    { name := "V (kind capture) MATCHes every key, value, flag, expire and version; keys deleted before and after the seed are absent on both sides"
      run := do
        match ← runV "seeded" with
        | .error e => return .fail e
        | .ok (c, verdict) =>
          if c != 0 then return .fail s!"want MATCH (exit 0), got exit {c}: {verdict}"
          let dump ← try IO.FS.readFile s!"{vDir}/seeded/dst/{(← masterPod cfgDst).getD ""}.dump" catch _ => pure ""
          for k in ["crp_0 ", "crp_1 ", "crp_6 "] do
            if containsSubstr dump s!"VALUE {k}" then return .fail s!"deleted key {k.trim} is on the destination"
          if !containsSubstr dump "VALUE crp_5 9 4 " then return .fail "the overwrite (flag 9) is not on the destination"
          return .pass },

    { name := "the destination master restarts (PVC kept) and comes back as master with the same lineage (master id, copy id; the epoch advances at re-promotion); V MATCHes again after more changes"
      run := do
        let some dPod ← masterPod cfgDst | return .fail "no destination master pod"
        match ← kubectl ["delete", "pod", dPod, "-n", cfgDst.«namespace», "--grace-period=0", "--force", "--wait=false"] with
        | .error e => return .fail s!"could not delete {dPod}: {e}"
        | .ok _ => pure ()
        IO.sleep 10000
        let back ← waitForCondition "the destination master answers again" 300 do
          match ← masterIp cfgDst with
          | none => return false
          | some ip => return (← statOf cfgDst ip "rocksdb_master_id").isSome
        if !back then return .fail "the destination master did not come back within 300 s (per-key seeded: it keeps its own history)"
        let some dIp ← masterIp cfgDst | return .fail "no destination master after the restart"
        let identNow ← lineage cfgDst dIp
        let identBefore ← dstIdentRef.get
        IO.eprintln s!"# destination after restart: {← identity cfgDst dIp} (lineage before the seed: {identBefore}; the epoch advances at a re-promotion by design)"
        if identNow != identBefore then return .fail s!"lineage changed across the restart: {identBefore} → {identNow}"
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let _ ← waitForCondition "forwarding resumed (a probe key arrives)" 180 do
          let _ ← srcCmd sIp "set crp_probe 0 0 1\\r\\np\\r\\n"
          match ← execInDebugPod cfgDst.debugPod cfgDst.«namespace» s!"printf 'get crp_probe\\r\\n' | nc -w 3 {dIp} {cfgDst.flarePort}" with
          | .ok o => return containsSubstr o "VALUE"
          | .error _ => return false
        for c in ["set crp_7 2 0 4\\r\\nnew7\\r\\n", "delete crp_8\\r\\n", "set crp_post 3 0 4\\r\\npost\\r\\n"] do
          let _ ← srcCmd sIp c
        IO.sleep 10000
        match ← runV "restarted" with
        | .error e => return .fail e
        | .ok (c, verdict) =>
          if c != 0 then return .fail s!"want MATCH after the restart, got exit {c}: {verdict}"
          return .pass },

    { name := "in-cluster replica snapshots are NOT disabled by the switch: a source slave started empty reseeds by snapshot"
      run := do
        let some m ← masterPod cfgSrc | return .fail "no source master"
        let pods ← getPodNames s!"app=flare,cluster={cfgSrc.name}" cfgSrc.«namespace»
        let some slave := pods.find? (· != m) | return .fail s!"no source slave among {pods}"
        match ← kubectl ["delete", "pod", slave, "-n", cfgSrc.«namespace», "--wait=true"] with
        | .error e => return .fail s!"could not delete {slave}: {e}"
        | .ok _ => pure ()
        let seen ← waitForCondition "the restarted slave reseeded by snapshot" 300 do
          match ← getPodIp slave cfgSrc.«namespace» with
          | none => return false
          | some ip => return (← statNat cfgSrc ip "rocksdb_snapshot_bootstrap") ≥ 1
        let some ip ← getPodIp slave cfgSrc.«namespace» | return .fail "slave has no IP"
        IO.eprintln s!"# source slave {slave}: snapshot_bootstrap {← statNat cfgSrc ip "rocksdb_snapshot_bootstrap"}; source switch stat {← statOf cfgSrc ip "cluster_replication_snapshot_push"}"
        if seen then return .pass
        return .fail "the source slave did not reseed by snapshot within 300 s (rocksdb_snapshot_bootstrap stayed 0)" },

    -- item 1 (2026-10-13): the per-key-only migration must not enter the
    -- push path BY CONFIGURATION on the destination too. The source's switch
    -- alone left a destination open to a push from any other source or a
    -- hand-sent command. Here the DESTINATION's CR sets the switch (the
    -- runbook's setting: replication off there, snapshotPush false) and a
    -- hand-sent push is refused before anything else (old code: not_fresh
    -- or, on a fresh destination, accepted).
    { name := "the destination's own switch (clusterReplication enabled false, snapshotPush false) refuses a hand-sent repl_snapshot_push as snapshot_push_disabled; its data and history are unchanged"
      run := do
        let some dIp ← masterIp cfgDst | return .fail "no destination master"
        let identBefore ← identity cfgDst dIp
        let items0 ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp cfgDst.flarePort
        match ← kubectlPatch "flarecluster" cfgDst.name cfgDst.«namespace» "{\"spec\":{\"clusterReplication\":{\"enabled\":false,\"snapshotPush\":false}}}" with
        | .error e => return .fail s!"patch of the destination failed: {e}"
        | .ok _ => pure ()
        let off ← waitForCondition "the destination reports snapshot_push_accept off" 180 do
          return (← statOf cfgDst dIp "snapshot_push_accept") == some "off"
        if !off then return .fail s!"the destination did not apply the switch (snapshot_push_accept {← statOf cfgDst dIp "snapshot_push_accept"})"
        let reply ← match ← execInDebugPod cfgDst.debugPod cfgDst.«namespace» s!"printf 'repl_snapshot_push 0 1\\r\\n' | nc -w 10 {dIp} {cfgDst.flarePort}" with
          | .ok o => pure o.trim
          | .error e => pure s!"(exec error {e})"
        let identAfter ← identity cfgDst dIp
        let items1 ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp cfgDst.flarePort
        IO.eprintln s!"# hand-sent push to the destination master {dIp}: {reply}; destination {identBefore} → {identAfter}; items {items0} → {items1}; snapshot_bootstrap {← statNat cfgDst dIp "rocksdb_snapshot_bootstrap"}"
        if !containsSubstr reply "SERVER_ERROR snapshot_push_disabled" then
          return .fail s!"the push was not refused by the destination's switch: {reply}"
        if identAfter != identBefore || items1 != items0 then return .fail "the destination changed"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplicationPerKeyOnly
