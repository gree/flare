/-
  E2E/Tests/SnapshotPushSeed.lean — physical INITIAL TRANSFER for cluster
  replication (repl_snapshot_push).

  Source and destination have the SAME partition count (1p ↔ 1p), so enabling
  duplicate replication must seed the destination via a pushed checkpoint
  (+ CRC-verified files + WAL tail) instead of the per-key logical dump —
  observable as `rocksdb_snapshot_bootstrap` incrementing on the destination
  master (the stat counts swap_in_snapshot executions).

  Also covered implicitly: REDIRECT (the source connects through the
  destination's headless Service, which may resolve to a slave; that node
  must redirect the push to its partition master), the fresh-destination
  guard, and the fall-through contract (any decline → the legacy dump still
  seeds the destination; the final key assertions hold either way, while the
  snapshot stat assertion pins the fast path).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.SnapshotPushSeed

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfgSrc : ClusterConfig := {
  name := "sps-src"
  «namespace» := "flare-sps-src"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-sps-src"
  debugPod := "debug-sps"
  storageBackend := "rocksdb"
}

private def cfgDst : ClusterConfig := {
  name := "sps-dst"
  «namespace» := "flare-sps-dst"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator-sps-dst"
  debugPod := "debug-sps"
  storageBackend := "rocksdb"
}

private def totalKeys : Nat := 500

private def dstStat (pod stat : String) : IO Nat := do
  let some ip ← getPodIp pod cfgDst.«namespace» | return 0
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfgDst.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .ok out =>
    let v := out.splitOn "\n" |>.findSome? fun line =>
      let t := line.trim.replace "\r" ""
      if t.startsWith s!"STAT {stat} " then (t.splitOn " ").getLast?.bind (·.toNat?) else none
    return v.getD 0
  | .error _ => return 0

def suite : TestSuite := {
  name := "snapshot-push-seed"
  setup := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
    deployCluster cfgSrc
    deployCluster cfgDst
    let okA ← waitForStable cfgSrc 50
    let okB ← waitForStable cfgDst 50
    if !(okA && okB) then throw (IO.userError "clusters did not stabilize")
  onFailure := do
    dumpClusterDiagnostics cfgSrc.«namespace» s!"app={cfgSrc.operatorName}"
    dumpClusterDiagnostics cfgDst.«namespace» s!"app={cfgDst.operatorName}"
  teardown := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
  tests := [
    { name := s!"seed {totalKeys} keys into the source"
      run := do
        let some ip ← getPodIp s!"{cfgSrc.name}-nodes-0" cfgSrc.«namespace»
          | return .fail "no source master IP"
        let stored ← writeKeys cfgSrc.debugPod cfgSrc.«namespace» ip cfgSrc.flarePort "sps" totalKeys
        if stored == totalKeys then return .pass
        else return .fail s!"stored {stored}/{totalKeys}" },

    { name := "enable duplicate replication (equal partition counts)"
      run := do
        let dstSvc := s!"{cfgDst.name}-nodes.{cfgDst.«namespace»}.svc.cluster.local"
        let patch := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{dstSvc}\",\"port\":{cfgDst.flarePort},\"mode\":\"duplicate\",\"concurrency\":2}}}"
        match ← kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» patch with
        | .error e => return .fail s!"CR patch failed: {e}"
        | .ok _ => return .pass },

    -- THE fast path: the destination master must have been seeded by a
    -- pushed checkpoint (swap_in_snapshot increments the stat), not by the
    -- per-key dump.
    { name := "destination master seeded via snapshot push (rocksdb_snapshot_bootstrap > 0)"
      run := do
        let ok ← waitForCondition "dst snapshot_bootstrap > 0" 240 do
          -- the partition master starts as nodes-0; check both to be
          -- role-flap-proof
          let a ← dstStat s!"{cfgDst.name}-nodes-0" "rocksdb_snapshot_bootstrap"
          let b ← dstStat s!"{cfgDst.name}-nodes-1" "rocksdb_snapshot_bootstrap"
          return a + b > 0
        if ok then return .pass
        else return .fail "no swap_in_snapshot on the destination — push declined or fell back to dump" },

    { name := s!"all {totalKeys} keys present on the destination (via proxy reads)"
      run := do
        let some ip ← getPodIp s!"{cfgDst.name}-nodes-0" cfgDst.«namespace»
          | return .fail "no destination IP"
        let mut present := 0
        for _ in List.range 20 do
          present := 0
          for i in List.range totalKeys do
            match ← memcachedGet cfgSrc.debugPod cfgSrc.«namespace» ip cfgDst.flarePort s!"sps_{i}" with
            | some v => if v == s!"val_{i}" then present := present + 1
            | none => pure ()
          if present == totalKeys then break
          IO.sleep 5000
        if present == totalKeys then return .pass
        else return .fail s!"destination holds {present}/{totalKeys}" },

    { name := "destination slave converges (relay from the swapped master)"
      run := do
        let ok ← waitForCondition "dst slave curr_items >= total" 120 do
          let a ← dstStat s!"{cfgDst.name}-nodes-0" "curr_items"
          let b ← dstStat s!"{cfgDst.name}-nodes-1" "curr_items"
          return a ≥ totalKeys && b ≥ totalKeys
        if ok then return .pass
        else return .fail "slave did not converge" },

    { name := "disable stops the stream declaratively"
      run := do
        let patch := "{\"spec\":{\"clusterReplication\":{\"enabled\":false}}}"
        match ← kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» patch with
        | .error e => return .fail s!"disable patch failed: {e}"
        | .ok _ =>
          let ok ← waitForCondition "src extra.conf has explicit false" 120 do
            match ← kubectlGetJsonpath "configmap" s!"{cfgSrc.name}-config" cfgSrc.«namespace»
                      "{.data.extra\\.conf}" with
            | .ok data => return containsSubstr data "cluster-replication = false"
            | .error _ => return false
          if ok then return .pass
          else return .fail "no explicit false after disable" }
  ]
}

end FlareOperator.E2E.Tests.SnapshotPushSeed
