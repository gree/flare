/-
  E2E/Tests/PvcDataSurvival.lean - Data survival with persistent volumes

  Replica promotion (data-survival-failover suite) protects a partition only
  while at least one replica stays alive. If the master AND all its slaves die
  at once (AZ outage, simultaneous eviction), the only remaining copy of the
  partition's data is on disk — which emptyDir throws away with the pod. This
  suite deploys the cluster with usePvc (volumeClaimTemplates, no startup
  wipe) and asserts the case emptyDir can never survive: kill BOTH P0 nodes
  simultaneously, then read every key back with its exact value. Any missing
  or mismatched key is `.fail` — never `.skip`.

  Uses the rocksdb backend: the production motivation for PVCs is RocksDB
  (WAL retention + LSN markers also only make sense on storage that outlives
  the pod).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.PvcDataSurvival

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "pvc-survival"
  «namespace» := "flare-pvc-survival"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-pvc-survival"
  storageBackend := "rocksdb"
  usePvc := true
}

private def numPods : Nat := cfg.partitions * cfg.replicas
private def totalKeys : Nat := 100
private def keyPrefix : String := "pvc"

/-- Read back every key `{keyPrefix}_{i}` and confirm the exact value
    (same assertion discipline as data-survival-failover: never skip). -/
private def assertAllKeysSurvive (ip : String) : IO TestResult := do
  let mut missing : List Nat := []
  let mut mismatched : List Nat := []
  for i in List.range totalKeys do
    let key := s!"{keyPrefix}_{i}"
    let expected := s!"val_{i}"
    match ← memcachedGet cfg.debugPod cfg.«namespace» ip cfg.flarePort key with
    | none => missing := missing ++ [i]
    | some got => if got != expected then mismatched := mismatched ++ [i]
  if missing.isEmpty && mismatched.isEmpty then
    return .pass
  else
    return .fail s!"DATA LOSS: {missing.length} missing, {mismatched.length} mismatched \
      (missing={missing.take 10}, mismatched={mismatched.take 10})"

/-- Current node-sync view from the operator. -/
private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- Pod name of the P0 master, or none. -/
private def currentP0Master : IO (Option String) := do
  return findMasterPod (← nodeView) 0

/-- Pod names of every node assigned to partition 0 (master and slaves).
    Role codes in node-sync lines: 0 = Master, 1 = Slave, 2 = Proxy. -/
private def currentP0Pods : IO (List String) := do
  let entries ← nodeView
  return entries.filter (fun e => e.partition == 0 && (e.role == 0 || e.role == 1))
    |>.map (fun e => (e.fqdn.splitOn ".").headD e.fqdn)

def suite : TestSuite := {
  name := "pvc-data-survival"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  -- Per-suite operators are deleted in teardown, so the CI end-of-run log
  -- dump can never capture a failing suite's logs; grab them here first.
  onFailure := dumpClusterDiagnostics cfg.«namespace»
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: baseline — write and read back through the P0 master.
    { name := s!"write {totalKeys} keys and verify baseline integrity (PVC, rocksdb)"
      run := do
        match ← currentP0Master with
        | none => return .fail "no P0 master found"
        | some masterPod =>
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort keyPrefix totalKeys
            IO.eprintln s!"# Wrote via {masterPod}: stored {stored}/{totalKeys}"
            if stored != totalKeys then
              return .fail s!"only {stored}/{totalKeys} keys stored"
            assertAllKeysSurvive ip },

    -- Test 2: the emptyDir-impossible case — kill the P0 master AND its
    -- slave in the same instant, so no live replica exists to promote. The
    -- StatefulSet recreates both pods on their PVCs; whichever re-registers
    -- first is re-assigned P0 master and must serve the data from its
    -- persisted RocksDB directory.
    { name := s!"all {totalKeys} keys survive SIMULTANEOUS death of P0 master and slave"
      run := do
        let p0Pods ← currentP0Pods
        if p0Pods.length < 2 then
          return .fail s!"expected P0 master+slave, found {p0Pods}"
        IO.eprintln s!"# Killing ALL P0 nodes simultaneously: {p0Pods}"
        let _ ← kubectl (["delete", "pod"] ++ p0Pods ++
                         ["-n", cfg.«namespace», "--force", "--grace-period=0"])
        let recovered ← waitForCondition "P0 master available after total P0 loss" 180 do
          match ← currentP0Master with
          | none => return false
          | some _ =>
            match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                      "{.status.readyReplicas}" with
            | .ok val => return (val.toNat?.getD 0 >= numPods)
            | .error _ => return false
        if !recovered then
          return .fail s!"P0 master not re-established within 180s after killing {p0Pods}"
        match ← currentP0Master with
        | none => return .fail "P0 master missing after recovery"
        | some newMaster =>
          IO.eprintln s!"# P0 master after total-P0 restart: {newMaster}"
          match ← getPodIp newMaster cfg.«namespace» with
          | none => return .fail s!"could not get IP for {newMaster}"
          | some ip => assertAllKeysSurvive ip },

    -- Test 3: count-level guard against a wholesale wipe.
    { name := "P0 master holds data after total-P0 restart"
      run := do
        let items ← getPartitionMasterItems cfg.debugPod cfg.«namespace»
          cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        IO.eprintln s!"# P0 curr_items: {items}"
        if items > 0 then return .pass
        else return .fail "P0 master reports 0 curr_items — PVC data did not survive" }
  ]
}

end FlareOperator.E2E.Tests.PvcDataSurvival
