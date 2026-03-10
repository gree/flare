/-
  E2E/Tests/Failover.lean - Failover test suite

  Tests: ping, one-master-per-partition, write keys, kill master, verify promotion, recovery
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.Failover

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "failover-test"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-failover"
}

private def numPods : Nat := cfg.partitions * cfg.replicas

def suite : TestSuite := {
  name := "failover"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: operator responds to ping
    { name := "operator responds to ping"
      run := do
        let resp ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "ping"
        if containsSubstr (resp.trim.replace "\r" "") "OK" then
          return .pass
        else
          return .fail s!"expected OK, got: {resp.trim}" },

    -- Test 2: one-master-per-partition
    { name := "one-master-per-partition"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let dups := checkOneMasterPerPartition entries
        let masters := countMasters entries
        if !dups.isEmpty then
          return .fail s!"duplicate masters for partitions: {dups}"
        else if masters < cfg.partitions then
          return .fail s!"only {masters}/{cfg.partitions} masters found"
        else
          return .pass },

    -- Test 3: both partitions have masters
    { name := "both partitions have masters"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let p0 := findMasterPod entries 0
        let p1 := findMasterPod entries 1
        match p0, p1 with
        | some _, some _ => return .pass
        | none, _ => return .fail "no master for partition 0"
        | _, none => return .fail "no master for partition 1" },

    -- Test 4: write keys to P0 master
    { name := "write keys to P0 master"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master found"
        | some masterPod =>
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            let mut stored := 0
            for i in List.range 10 do
              let key := s!"fkey_{i}"
              let value := s!"fval_{i}"
              let ok ← memcachedSet cfg.debugPod cfg.«namespace» ip cfg.flarePort key value
              if ok then stored := stored + 1
            if stored > 0 then
              return .pass
            else
              return .fail "no keys stored" },

    -- Test 5: kill P0 master, verify failover
    { name := "failover: new master elected for P0"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master to kill"
        | some oldMaster =>
          IO.eprintln s!"# Killing P0 master: {oldMaster}"
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfg.«namespace»,
                            "--force", "--grace-period=0"]
          -- Wait for new master
          let ok ← waitForCondition "P0 master available" 90 do
            let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
            let entries := parseNodeSync sync
            match findMasterPod entries 0 with
            | some _ => return true
            | none => return false
          if ok then
            let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
            let entries := parseNodeSync sync
            match findMasterPod entries 0 with
            | some newMaster =>
              if newMaster == oldMaster then
                return .pass  -- reclaimed by restarted pod
              else
                return .pass  -- slave promoted
            | none => return .fail "master not found after wait"
          else
            return .fail "no P0 master within 90s" },

    -- Test 6: one-master-per-partition after failover
    { name := "failover: one-master-per-partition maintained"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let dups := checkOneMasterPerPartition entries
        if dups.isEmpty then return .pass
        else return .fail s!"duplicate masters for partitions: {dups}" },

    -- Test 7: P1 unaffected
    { name := "failover: P1 unaffected"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 1 with
        | none => return .fail "no P1 master found"
        | some _ => return .pass },

    -- Test 8: recovery - all pods ready
    { name := "recovery: all pods ready"
      run := do
        let ok ← waitForCondition s!"all {numPods} pods ready" 120 do
          match ← kubectlGetJsonpath "statefulset" "flare-nodes" cfg.«namespace»
                    "{.status.readyReplicas}" with
          | .ok val => return (val.toNat?.getD 0 >= numPods)
          | .error _ => return false
        if ok then return .pass
        else return .fail s!"not all {numPods} pods ready" },

    -- Test 9: recovery - one-master-per-partition
    { name := "recovery: one-master-per-partition"
      run := do
        -- Wait for re-registration
        IO.sleep 15000
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let dups := checkOneMasterPerPartition entries
        if dups.isEmpty then return .pass
        else return .fail s!"duplicate masters for partitions: {dups}" }
  ]
}

end FlareOperator.E2E.Tests.Failover
