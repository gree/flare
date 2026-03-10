/-
  E2E/Tests/ScaleOutMaster.lean - Scale out master (add partition) test suite

  Tests: stable cluster, write keys, patch partitions 2→3, scale pods, verify P2 master+slave
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ScaleOutMaster

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup

private def cfg : ClusterConfig := {
  name := "scale-out-master"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-scale-out-m"
}

def suite : TestSuite := {
  name := "scale-out-master"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: cluster is stable with 2 partitions
    { name := "pre-flight: cluster stable with 2 partitions"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        if countMasters entries >= 2 then return .pass
        else return .fail s!"only {countMasters entries} masters (expected 2)" },

    -- Test 2: write keys before scaling
    { name := "write keys before scaling"
      run := do
        let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        match ips.head? with
        | none => return .fail "no pod IPs"
        | some ip =>
          let ok ← memcachedSet cfg.debugPod cfg.«namespace» ip cfg.flarePort "scale_key" "scale_val"
          if ok then return .pass
          else return .fail "SET failed" },

    -- Test 3: patch CRD partitions 2→3
    { name := "patch partitions 2→3"
      run := do
        let patchJson := "{\"spec\":{\"partitions\":3}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patchJson with
        | .ok _ => return .pass
        | .error e => return .fail s!"patch failed: {e}" },

    -- Test 4: scale StatefulSet pods
    { name := "scale pods to 6 (3 partitions × 2 replicas)"
      run := do
        match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 6 with
        | .ok _ =>
          -- Create partition-2 service
          let svcYaml := partitionServiceYaml { cfg with partitions := 3 } 2
          try
            let result ← IO.Process.output {
              cmd := "sh"
              args := #["-c", s!"cat <<'ENDOFYAML' | kubectl apply -f -\n{svcYaml}\nENDOFYAML"]
            }
            let _ := result
            pure ()
          catch _ => pure ()
          let ok ← kubectlRolloutStatus s!"statefulset/{cfg.name}-nodes" cfg.«namespace» 300
          if ok then return .pass
          else return .fail "rollout timeout"
        | .error e => return .fail s!"scale failed: {e}" },

    -- Test 5: wait for new nodes to register
    { name := "new nodes registered with operator"
      run := do
        -- Wait for grace period + registration
        IO.sleep 60000
        let ok ← waitForCondition "6 nodes registered" 120 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          return (entries.length >= 6)
        if ok then return .pass
        else return .fail "not all 6 nodes registered" },

    -- Test 6: verify P2 has master and slave
    { name := "P2 has master and slave"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let p2Master := findMasterPod entries 2
        let p2Slaves := entries.filter (fun e => e.role == 1 && e.partition == 2)
        match p2Master with
        | none => return .fail "no master for P2"
        | some _ =>
          if p2Slaves.isEmpty then
            return .fail "no slave for P2"
          else
            return .pass },

    -- Test 7: all 3 partitions have masters
    { name := "all 3 partitions have masters"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let masters := countMasters entries
        if masters >= 3 then return .pass
        else return .fail s!"only {masters}/3 masters" }
  ]
}

end FlareOperator.E2E.Tests.ScaleOutMaster
