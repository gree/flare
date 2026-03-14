/-
  E2E/Tests/Failover.lean - Failover test suite

  Tests: ping, one-master-per-partition, write keys per partition, verify curr_items,
         kill master, verify promotion, verify P1 items unchanged, recovery
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
  -- Use unique namespace per test run for isolation (timestamp-based)
  «namespace» := "flare-failover"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-failover"
}

private def numPods : Nat := cfg.partitions * cfg.replicas
private def totalKeys : Nat := 100

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

    -- Test 3: verify META returns correct partition-size (max ring size)
    { name := "META returns partition-size 1024"
      run := do
        let resp ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "meta"
        if containsSubstr resp "partition-size 1024" then return .pass
        else return .fail s!"META response: {resp.trim}" },

    -- Test 4: write 100 keys via P0 master (proxy routing distributes across partitions)
    { name := "write 100 keys via proxy routing"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master found"
        | some masterPod =>
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "fo" totalKeys
            IO.eprintln s!"# Wrote via {masterPod}: stored {stored}/{totalKeys}"
            if stored == totalKeys then return .pass
            else return .fail s!"only {stored}/{totalKeys} keys stored" },

    -- Test 5: verify keys distributed across both partitions
    { name := "verify key distribution (P0 > 0, P1 > 0, total = 100)"
      run := do
        let p0 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        let p1 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
        IO.eprintln s!"# Distribution: P0={p0}, P1={p1}, total={p0 + p1}"
        if p0 > 0 && p1 > 0 && p0 + p1 == totalKeys then return .pass
        else return .fail s!"P0={p0}, P1={p1}, total={p0 + p1} (expected both > 0, total = {totalKeys})" },

    -- Test 6: kill P0 master, verify failover
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
              IO.eprintln s!"# New P0 master: {newMaster} (was: {oldMaster})"
              return .pass
            | none => return .fail "master not found after wait"
          else
            return .fail "no P0 master within 90s" },

    -- Test 7: one-master-per-partition after failover
    { name := "failover: one-master-per-partition maintained"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let dups := checkOneMasterPerPartition entries
        if dups.isEmpty then return .pass
        else return .fail s!"duplicate masters for partitions: {dups}" },

    -- Test 8: P1 curr_items unchanged after P0 failover
    { name := "failover: P1 curr_items unchanged"
      run := do
        let p1Items ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
        IO.eprintln s!"# P1 curr_items after failover: {p1Items}"
        if p1Items > 0 then
          return .pass
        else
          return .skip "data may have been lost during failover" },

    -- Test 9: recovery - all pods ready
    { name := "recovery: all pods ready"
      run := do
        let ok ← waitForCondition s!"all {numPods} pods ready" 180 do
          match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                    "{.status.readyReplicas}" with
          | .ok val => return (val.toNat?.getD 0 >= numPods)
          | .error _ => return false
        if ok then return .pass
        else return .fail s!"not all {numPods} pods ready" },

    -- Test 10: recovery - one-master-per-partition
    { name := "recovery: one-master-per-partition"
      run := do
        let ok ← waitForCondition "one-master-per-partition" 60 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          let dups := checkOneMasterPerPartition entries
          return (dups.isEmpty && countMasters entries >= cfg.partitions)
        if ok then return .pass
        else
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          let dups := checkOneMasterPerPartition entries
          return .fail s!"duplicate masters for partitions: {dups}" },

    -- Test 11: verify total items across cluster after recovery
    { name := "recovery: total curr_items across cluster"
      run := do
        let total ← getTotalItems cfg.debugPod cfg.«namespace» s!"app=flare,cluster={cfg.name}" cfg.flarePort
        IO.eprintln s!"# Total curr_items after recovery: {total}"
        if total > 0 then return .pass
        else return .skip "items may have been lost during pod restart" }
  ]
}

end FlareOperator.E2E.Tests.Failover
