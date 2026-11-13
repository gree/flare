/-
  Re-enabling cluster replication after a snapshot-push seed must never
  write the destination's history into the SOURCE.

  Audit 2026-10-11 (code reading, not yet observed): the seed
  (handler_dump_replication::run) began with a "Phase 1" that asked the
  destination for its WAL since the source's repl_last_lsn and APPLIED it to
  the source's own storage, then returned without seeding when that
  succeeded. Its only guard was the master_id comparison — and a
  snapshot-push seed copies the source's files, master_id included, so after
  one the destination answers with the source's own master_id. On the next
  start() (enabled false → true, a source master restart, a name change) the
  source would apply the destination's WAL: older values of keys it has
  changed since.

  This test fixes that order: seed by snapshot push, forward K=old, disable,
  change K=new on the source only, re-enable. Required: the source still
  reads K=new, and the destination is seeded again (K=new there too).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ClusterReplicationReseed

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfgSrc : ClusterConfig := {
  name := "crs-src"
  «namespace» := "flare-crs-src"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crs-src"
  debugPod := "debug-crs"
  storageBackend := "rocksdb"
}

private def cfgDst : ClusterConfig := {
  name := "crs-dst"
  «namespace» := "flare-crs-dst"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crs-dst"
  debugPod := "debug-crs"
  storageBackend := "rocksdb"
}

private def dstSvc : String := s!"{cfgDst.name}-nodes.{cfgDst.«namespace»}.svc.cluster.local"

private def masterIp (cfg : ClusterConfig) : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  match findMasterPod (parseNodeSync sync) 0 with
  | none => return none
  | some m => getPodIp m cfg.«namespace»

private def statOf (ip stat : String) : IO (Option String) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfgSrc.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith s!"STAT {stat} " then some (t.drop s!"STAT {stat} ".length).trim else none

private def getSrc (ip key : String) : IO (Option String) :=
  memcachedGet cfgSrc.debugPod cfgSrc.«namespace» ip cfgSrc.flarePort key
private def getDst (ip key : String) : IO (Option String) :=
  memcachedGet cfgDst.debugPod cfgDst.«namespace» ip cfgDst.flarePort key

private def patchRepl (enabled : Bool) : IO (Except String String) :=
  let json := if enabled then
      s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{dstSvc}\",\"port\":{cfgDst.flarePort},\"mode\":\"duplicate\",\"concurrency\":1}}}"
    else "{\"spec\":{\"clusterReplication\":{\"enabled\":false}}}"
  kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» json

/-- The seed-path lines the source flared printed (which phase ran). -/
private def seedLines : IO (List String) := do
  let l ← kubectlLogsLabel s!"app=flare,cluster={cfgSrc.name}" cfgSrc.«namespace» 3000
  return (l.splitOn "\n").filter fun x =>
    containsSubstr x "WAL replication completed" || containsSubstr x "WAL sync refused"
      || containsSubstr x "WAL replication failed" || containsSubstr x "master does not support RocksDB WAL"
      || containsSubstr x "snapshot push" || containsSubstr x "dump replication completed"
      || containsSubstr x "dump replication FAILED" || containsSubstr x "SEED NOT STARTED"
      || containsSubstr x "start cluster replication" || containsSubstr x "stop cluster replication"

private def baseKeys : Nat := 20
private def key : String := "reseed_k"

def suite : TestSuite := {
  name := "cluster-replication-reseed"
  setup := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
    deployCluster cfgSrc
    let s1 ← waitForStable cfgSrc 50
    if !s1 then throw (IO.userError "source cluster did not stabilize")
    deploySecondCluster cfgDst
    let s2 ← waitForStable cfgDst 50
    if !s2 then throw (IO.userError "destination cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfgSrc.«namespace» s!"app={cfgSrc.operatorName}"
  teardown := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
  tests := [
    { name := "re-enable after a snapshot-push seed: the source keeps the value it changed while replication was off (the seed never applies the destination's history to the source), and the destination is seeded again"
      run := do
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let some dIp ← masterIp cfgDst | return .fail "no destination master"
        for i in List.range baseKeys do
          if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort s!"base_{i}" s!"b{i}") then
            return .fail s!"precondition: base_{i} not acknowledged"
        match ← patchRepl true with
        | .error e => return .fail s!"could not enable replication: {e}"
        | .ok _ => pure ()
        let seeded ← waitForCondition "the destination was seeded by snapshot push" 300 do
          let boot := ((← statOf dIp "rocksdb_snapshot_bootstrap").bind (·.toNat?)).getD 0
          return boot > 0 && (← getDst dIp s!"base_{baseKeys - 1}") == some s!"b{baseKeys - 1}"
        let srcId ← statOf sIp "rocksdb_master_id"
        let dstId ← statOf dIp "rocksdb_master_id"
        IO.eprintln s!"# after the first seed: master_id source {srcId}, destination {dstId}; seed lines: {(← seedLines).map (·.trim) |>.take 12}"
        if !seeded then
          return .fail "precondition: no snapshot-push seed happened (rocksdb_snapshot_bootstrap 0 or base keys missing) — the order under test was not reached"
        if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort key "old") then
          return .fail "precondition: K=old not acknowledged"
        let fwd ← waitForCondition "K=old forwarded to the destination" 120 do
          return (← getDst dIp key) == some "old"
        if !fwd then return .fail "precondition: K=old never reached the destination — the destination history does not hold it"
        match ← patchRepl false with
        | .error e => return .fail s!"could not disable replication: {e}"
        | .ok _ => pure ()
        let off ← waitForCondition "the source flared applied enabled=false" 180 do
          return (← statOf sIp "cluster_replication") == some "off"
        if !off then return .fail "the source never stopped replicating (cluster_replication stayed on)"
        if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort key "new") then
          return .fail "K=new not acknowledged by the source"
        if (← getDst dIp key) != some "old" then
          return .fail "precondition: the destination already moved off K=old while replication was off"
        let linesBefore := (← seedLines).length
        match ← patchRepl true with
        | .error e => return .fail s!"could not re-enable replication: {e}"
        | .ok _ => pure ()
        let isOn ← waitForCondition "the source flared applied enabled=true again" 180 do
          return (← statOf sIp "cluster_replication") == some "on"
        if !isOn then return .fail "the source never restarted replicating"
        -- the second seed ran (or decided not to) when one of these happens
        let _ ← waitForCondition "the source rolled back, or the destination took K=new" 240 do
          return (← getSrc sIp key) != some "new" || (← getDst dIp key) == some "new"
        IO.sleep 10000
        let srcK ← getSrc sIp key
        let dstK ← getDst dIp key
        let after := (← seedLines).drop linesBefore |>.map (·.trim)
        IO.eprintln s!"# after the re-enable: source K={srcK}, destination K={dstK}; seed state {← statOf sIp "cluster_replication_seed"}; source lines since: {after.take 15}"
        if srcK != some "new" then
          return .fail s!"SOURCE ROLLED BACK: the source reads K={srcK} after the re-enable, not the value 'new' it acknowledged while replication was off — the seed applied the destination's history to the source"
        if dstK != some "new" then
          return .fail s!"the destination was not seeded again: it reads K={dstK}, the source K=new"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplicationReseed
