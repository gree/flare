/-
  E2E/Tests/PartitionReduction.lean - Partition reduction detection test

  Tests: deploy 2-partition cluster, attempt to reduce to 1 partition,
         verify operator blocks reduction and displays warning,
         verify cluster continues with 2 partitions
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.PartitionReduction

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "partition-reduction"
  «namespace» := "flare-part-red"  -- Unique namespace for test isolation
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-partition-reduction"
}

def suite : TestSuite := {
  name := "partition-reduction"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace»
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: verify initial 2-partition cluster
    { name := "pre-flight: cluster stable with 2 partitions"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masterCount := countMasters entries
        IO.eprintln s!"# Master count: {masterCount}"
        if masterCount >= 2 then return .pass
        else return .fail s!"only {masterCount} masters (expected 2)" },

    -- Test 2: attempt to reduce partitions from 2 to 1
    { name := "attempt partition reduction (2 → 1)"
      run := do
        let patchJson := "{\"spec\":{\"partitions\":1}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ =>
          IO.eprintln "# Partition reduction patch applied (operator should block it)"
          return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 3: wait for operator to process the reduction attempt
    { name := "wait for operator to detect reduction"
      run := do
        IO.sleep 15000  -- 15 seconds for operator to process (2-3 reconcile cycles)
        return .pass },

    -- Test 4: verify cluster still has 2 partitions (reduction was blocked)
    { name := "verify cluster still has 2 partitions (reduction blocked)"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masterCount := countMasters entries
        IO.eprintln s!"# After reduction attempt, master count: {masterCount}"
        if masterCount >= 2 then return .pass
        else return .fail s!"reduction was NOT blocked! Only {masterCount} masters (expected 2)" },

    -- Test 5: verify operator logs contain warning
    { name := "verify operator logged partition reduction warning"
      run := do
        -- Get operator pod names
        let opPods ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
        match opPods.head? with
        | none => return .fail "operator pod not found"
        | some opPod =>
          -- Get operator logs (more lines to ensure we catch the warning)
          let logs ← kubectlLogs opPod cfg.«namespace» 200
          -- Check for warning message (check if log contains substring)
          let hasWarning := (logs.splitOn "UNSAFE PARTITION REDUCTION DETECTED").length > 1
          if hasWarning then do
            IO.eprintln "# Operator logged partition reduction warning ✓"
            return .pass
          else
            return .fail "operator did not log partition reduction warning" },

    -- Test 6: restore CRD to correct state (2 partitions)
    { name := "restore CRD to 2 partitions"
      run := do
        let patchJson := "{\"spec\":{\"partitions\":2}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 7: verify cluster remains healthy after restoration
    { name := "verify cluster healthy after CRD restoration"
      run := do
        IO.sleep 3000  -- Wait for reconcile
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masterCount := countMasters entries
        if masterCount >= 2 then return .pass
        else return .fail s!"cluster unhealthy: only {masterCount} masters" }
  ]
}

end FlareOperator.E2E.Tests.PartitionReduction
