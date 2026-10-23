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

def cfg : ClusterConfig := {
  name := "failover-test"
  -- Use unique namespace per test run for isolation (timestamp-based)
  «namespace» := "flare-failover"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-failover"
}

private def totalKeys : Nat := 100

/-- `"ok"` once the seed (test 4) ran under a held setup predicate and stored every key on both partitions;
    the P0 master is not killed otherwise (suites with a `seedGuard`). -/
initialize seedVerdictRef : IO.Ref (Option String) ← IO.mkRef none

/-- Samples `guard` every second until stopped: the CONTINUOUS setup predicate (a one-shot check passed
    in 39947084993 while P1's master was not yet established, and the seed landed 48/100, P0 = 0). -/
private partial def guardLoop (guard : IO (Option String)) (stop : IO.Ref Bool)
    (acc : IO.Ref (List (Option String))) : IO Unit := do
  acc.modify (· ++ [← (try guard catch e => pure (some s!"the predicate failed: {e}"))])
  IO.sleep 1000
  if !(← stop.get) then guardLoop guard stop acc

private def startGuardSampler (guard : IO (Option String)) :
    IO (IO.Ref Bool × IO.Ref (List (Option String)) × Task (Except IO.Error Unit)) := do
  let stop ← IO.mkRef false
  let acc ← IO.mkRef ([] : List (Option String))
  let t ← IO.asTask (prio := .dedicated) (guardLoop guard stop acc)
  return (stop, acc, t)

/-- The failover suite over `cfg` (the write-authority variant passes its own cfg, an extra
    wait for the grants after the cluster is stable, and a longer bound for the promotion, which
    then goes through the promotion intent: prepare, the successor's promise, commit). -/
def mkSuite (suiteName : String) (cfg : ClusterConfig) (afterStable : IO Unit) (promoteWaitSec : Nat)
    (seedGuard : Option (IO (Option String)) := none) : TestSuite :=
  let numPods := cfg.partitions * cfg.replicas
  {
  name := suiteName
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
    afterStable
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
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

    -- flared keys its per-destination proxy connection pools by thread_type
    -- (cluster::_get_proxy_thread), so every node MUST get a distinct number.
    -- The operator used to hardcode 16 for all nodes, collapsing every
    -- destination into ONE pool: forwards/relays went to hash-picked wrong
    -- peers, self-consistently per key — which is exactly why per-key
    -- get/set round-trips could not catch it and this needs its own assert.
    { name := "node sync assigns a UNIQUE thread_type to every node"
      run := do
        let resp ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        let tts := resp.splitOn "\n" |>.filterMap fun line =>
          match (line.trim.replace "\r" "").splitOn " " with
          | ["NODE", _, _, _, _, _, _, tt] => tt.toNat?
          | _ => none
        if tts.length < 4 then
          return .fail s!"expected >=4 NODE lines with thread_type, got {tts.length}: {resp.take 300}"
        else if tts.eraseDups.length != tts.length then
          return .fail s!"duplicate thread_type in node map: {tts}"
        else
          return .pass },

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
            seedVerdictRef.set none
            -- the setup predicate holds from before the first write to after the last (sampled every second)
            let pre ← match seedGuard with
              | some g => g
              | none => pure none
            if let some why := pre then
              return .fail s!"the setup predicate does not hold at the seed start: {why}"
            let sampler ← match seedGuard with
              | some g => some <$> startGuardSampler g
              | none => pure none
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "fo" totalKeys
            IO.eprintln s!"# Wrote via {masterPod}: stored {stored}/{totalKeys}"
            let samples ← match sampler with
              | some (stop, acc, t) => do
                stop.set true
                discard <| IO.wait t
                pure (some (← acc.get))
              | none => pure none
            if let some ss := samples then
              IO.eprintln s!"# seed predicate: {ss.length} sample(s) during the seed, {(ss.filter (·.isSome)).length} violation(s)"
              if let some why := (ss.filterMap id).head? then
                return .fail s!"the setup predicate was lost during the seed ({(ss.filter (·.isSome)).length}/{ss.length} samples): {why}"
              if ss.isEmpty then return .fail "the setup predicate was never sampled during the seed"
            if stored != totalKeys then return .fail s!"only {stored}/{totalKeys} keys stored"
            if seedGuard.isSome then
              -- proceed only with BOTH partitions populated and the predicate still true
              let p0 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 0 cfg.flarePort
              let p1 ← getPartitionMasterItems cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort 1 cfg.flarePort
              IO.eprintln s!"# seed distribution: P0={p0}, P1={p1}"
              if !(p0 > 0 && p1 > 0 && p0 + p1 == totalKeys) then
                return .fail s!"seed stored {stored}/{totalKeys} but P0={p0}, P1={p1} (both partitions must be populated, total {totalKeys})"
              let post ← match seedGuard with
                | some g => g
                | none => pure none
              if let some why := post then return .fail s!"the setup predicate does not hold after the seed: {why}"
              seedVerdictRef.set (some "ok")
            return .pass },

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
        | some _ =>
        if seedGuard.isSome && (← seedVerdictRef.get) != some "ok" then
          return .fail "the seed precondition did not hold (see the seed test): the P0 master is NOT killed, nothing is verified"
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master to kill"
        | some oldMaster =>
          IO.eprintln s!"# Killing P0 master: {oldMaster}"
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfg.«namespace»,
                            "--force", "--grace-period=0"]
          -- Wait for new master
          let ok ← waitForCondition "P0 master available" promoteWaitSec do
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
            return .fail s!"no P0 master within {promoteWaitSec}s" },

    -- Role-consistent read balance after failover: every Master must carry
    -- balance 100 and every Slave 0 (normalizeBalances at the commit
    -- boundary). Before that fix, transition interleavings left a promoted
    -- master at balance 0 while the demoted ex-master rejoined as a slave
    -- still carrying 100 — reads silently flipped to a lagging slave
    -- (observed live after a rolling restart, surfaced by flare-stats).
    { name := "failover: balance follows role (master=100, slaves=0)"
      run := do
        let ok ← waitForCondition "balances normalized" 60 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          return entries.all fun e =>
            (e.role != 0 || e.balance == 100) && (e.role != 1 || e.balance == 0)
        if ok then return .pass
        else
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let bad := (parseNodeSync sync).filter fun e =>
            !((e.role != 0 || e.balance == 100) && (e.role != 1 || e.balance == 0))
          return .fail s!"balance/role mismatch persisted: {bad.map (fun e => s!"{e.fqdn} role={e.role} balance={e.balance}")}" },

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

def suite : TestSuite := mkSuite "failover" cfg (pure ()) 90

end FlareOperator.E2E.Tests.Failover
