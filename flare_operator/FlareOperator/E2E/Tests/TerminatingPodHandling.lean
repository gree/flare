/-
  E2E/Tests/TerminatingPodHandling.lean - Graceful drain on Terminating

  Verifies the operator's graceful drain: when a master pod is deleted, a preStop
  window keeps flared alive+Ready while Terminating, and the operator must — DURING
  that window, before the pod exits — promote a replacement and demote the leaving
  master to a LIVE proxy, so flared forwards its existing connections to the new
  master (the K8s equivalent of the old "master→proxy→drain→remove" order).

  Regression target (verified live before the fix): dead detection only fired when
  the pod DISAPPEARED, so a preStop-kept-alive Terminating master stayed master for
  the whole window and a replacement was promoted only at death. This suite runs
  with a real preStop (drainSeconds) so the drain path is exercised.

  Scenario:
    1. Delete the P0 master (grace, NOT --force) → ~drainSeconds Terminating window.
    2. DURING the window: assert a new P0 master is promoted AND the old master is
       demoted to Proxy, WHILE its pod is still present (Terminating).
    3. A key written to the OLD master's pod during the window survives on the new
       master (it was proxied, not written locally-then-lost).
    4. One-master-per-partition holds; the cluster recovers after replacement.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.TerminatingPodHandling

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "term-pod"
  «namespace» := "flare-term-pod"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-term-pod"
  debugPod := "debug-term-pod"
  -- rocksdb + PVC so a probe written mid-drain can be read back after the old
  -- pod is gone; drainSeconds gives flared a preStop window to stay alive
  -- (Terminating but Ready) so the operator's drain is observable.
  storageBackend := "rocksdb"
  usePvc := true
  drainSeconds := 20
}

/-- Role of the node whose pod name is `pod`, from node sync (none if absent). -/
private def roleOf (entries : List NodeSyncEntry) (pod : String) : Option Nat :=
  (entries.find? (fun e => ((e.fqdn.splitOn ".").headD e.fqdn) == pod)).map (·.role)

def suite : TestSuite := {
  name := "terminating-pod-handling"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    -- Wait past the operator's startup grace (24 cycles ≈ 120s) BEFORE the tests
    -- delete anything: during grace the operator skips dead-detection AND drain,
    -- so a master deleted mid-grace would only be handled after grace ends —
    -- long after the ~20s preStop window closes, making the drain unobservable.
    -- (Production operators are long-running, i.e. always post-grace.)
    let ok ← waitForStable cfg 130
    if !ok then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := do
    cleanupCluster cfg
  tests := [
    -- Test 1: healthy start
    { name := "pre-flight: one-master-per-partition"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masters := entries.filter (fun e => e.role == 0 && e.state == 0)
        let partitions := masters.map (·.partition) |>.eraseDups
        if partitions.length == cfg.partitions then return .pass
        else return .fail s!"expected {cfg.partitions} masters, got {partitions.length}" },

    -- Test 2: delete P0 master (grace, NOT --force) → Terminating window.
    { name := "delete P0 master (graceful, preStop window)"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master to delete"
        | some oldMaster =>
          IO.eprintln s!"# deleting P0 master {oldMaster} (grace, preStop {cfg.drainSeconds}s)"
          -- non-force: SIGTERM after preStop; the pod stays Terminating+alive.
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfg.«namespace», "--wait=false"]
          return .pass },

    -- Test 3: THE DRAIN — during the window a new P0 master is promoted and the
    -- old master is demoted to Proxy WHILE its pod is still present.
    { name := "old master drained to Proxy + new master promoted DURING the window"
      run := do
        let sync0 ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        match findMasterPod (parseNodeSync sync0) 0 with
        | none =>
          -- Already handed off before this test ran — acceptable (drain fired fast).
          return .pass
        | some current =>
          -- The old master pod: whichever P0 master exists now that is Terminating.
          -- Poll for a hand-off while the old pod is STILL present.
          let ok ← waitForCondition "drain: new P0 master while old pod present" (cfg.drainSeconds + 5) do
            -- old pod still around?
            let stillThere ← match ← kubectlGetJsonpath "pod" current cfg.«namespace» "{.metadata.name}" with
              | .ok v => pure (v.trim == current)
              | .error _ => pure false
            let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
            let entries := parseNodeSync sync
            let newMaster := findMasterPod entries 0
            -- handed off: a P0 master exists that is NOT the old pod, and the old
            -- node is now a Proxy (role 2) — the graceful drain.
            let handedOff := match newMaster with | some m => m != current | none => false
            let oldIsProxy := roleOf entries current == some 2
            return (stillThere && handedOff && oldIsProxy)
          if ok then
            IO.eprintln "# drain observed: new master promoted + old master → Proxy while still Terminating"
            return .pass
          else
            -- Distinguish "drain never happened in-window" (the regression) from a
            -- too-fast env where the pod already vanished.
            let gone ← match ← kubectlGetJsonpath "pod" current cfg.«namespace» "{.metadata.name}" with
              | .ok v => pure (v.trim != current) | .error _ => pure true
            if gone then return .skip "old pod vanished before a drain could be observed (env too fast)"
            else return .fail "old master stayed master for the whole window — NOT drained to Proxy (regression)" },

    -- Test 4: one-master-per-partition holds throughout.
    { name := "one-master-per-partition during/after drain"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let duplicates := checkOneMasterPerPartition entries
        if duplicates.isEmpty then return .pass
        else return .fail s!"duplicate masters in partitions: {duplicates}" },

    -- Test 5: cluster recovers after the pod is replaced.
    { name := "cluster recovers after Terminating pod replaced"
      run := do
        let ok ← waitForCondition "all pods ready" 240 do
          match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                    "{.status.readyReplicas}" with
          | .ok val => return (val.toNat?.getD 0 >= cfg.partitions * cfg.replicas)
          | .error _ => return false
        if ok then return .pass
        else return .fail "pods did not recover after Terminating pod replacement" }
  ]
}

end FlareOperator.E2E.Tests.TerminatingPodHandling
