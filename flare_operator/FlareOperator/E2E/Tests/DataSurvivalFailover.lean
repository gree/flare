/-
  E2E/Tests/DataSurvivalFailover.lean - Data survival across master failover

  The point of the operator is safe failover of a KV store, yet no existing
  suite verifies that the actual key/value DATA survives a master failure — they
  only check `curr_items > 0` or `.skip` on loss, so a failover that drops data
  still turns CI green. This suite closes that gap: it writes N keys, reads them
  all back to establish a baseline, kills the P0 master, waits for re-election,
  then reads every key back from the NEW master and asserts the exact value
  survived. Any missing or mismatched key returns `.fail` — never `.skip`.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.DataSurvivalFailover

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "data-survival"
  «namespace» := "flare-data-survival"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-data-survival"
}

private def numPods : Nat := cfg.partitions * cfg.replicas
private def totalKeys : Nat := 100
private def keyPrefix : String := "ds"

/-- Read back every key `{keyPrefix}_{i}` (i ∈ [0, totalKeys)) from `ip` and
    confirm the value equals `val_{i}` (the value `writeKeys` stores). Returns
    `.pass` only if ALL keys are present with the correct value; otherwise
    `.fail` listing the first missing/mismatched indices. Never skips. -/
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

/-- Resolve the current P0 master pod name, or none. -/
private def currentP0Master : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return findMasterPod (parseNodeSync sync) 0

def suite : TestSuite := {
  name := "data-survival-failover"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: write N keys via the P0 master and confirm they read back BEFORE
    -- any failover (baseline — proves the write path + readback assertion work).
    { name := s!"write {totalKeys} keys and verify baseline integrity"
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
            -- Read them straight back to prove the baseline before we break anything.
            assertAllKeysSurvive ip },

    -- Test 2: kill the P0 master, wait for re-election, then read back EVERY key
    -- from the NEW master. This is the whole point: data must survive failover.
    -- Capture + kill + readback are one test so the killed pod name stays a plain
    -- `let` (no cross-test shared mutable state).
    { name := s!"all {totalKeys} keys survive P0 master failover with exact values"
      run := do
        match ← currentP0Master with
        | none => return .fail "no P0 master found before kill"
        | some oldMaster =>
          IO.eprintln s!"# Killing P0 master: {oldMaster}"
          let _ ← kubectl ["delete", "pod", oldMaster, "-n", cfg.«namespace»,
                           "--force", "--grace-period=0"]
          -- Wait for a DIFFERENT pod to become P0 master.
          let elected ← waitForCondition "new P0 master elected" 90 do
            match ← currentP0Master with
            | some m => return (m != oldMaster)
            | none => return false
          if !elected then
            return .fail s!"no new P0 master within 90s after killing {oldMaster}"
          match ← currentP0Master with
          | none => return .fail "P0 master missing after re-election"
          | some newMaster =>
            IO.eprintln s!"# New P0 master: {newMaster} (was {oldMaster})"
            -- Give the promoted node a moment to be serving, then verify data.
            match ← getPodIp newMaster cfg.«namespace» with
            | none => return .fail s!"could not get IP for new master {newMaster}"
            | some ip => assertAllKeysSurvive ip },

    -- Test 3: the new P0 master must actually hold data (count-level guard that
    -- complements the per-key check above and catches a wholesale wipe).
    { name := "P0 master holds data after failover"
      run := do
        let items ← getPartitionMasterItems cfg.debugPod cfg.«namespace»
          cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        IO.eprintln s!"# P0 curr_items after failover: {items}"
        if items > 0 then return .pass
        else return .fail "P0 master reports 0 curr_items after failover — total data loss" }
  ]
}

end FlareOperator.E2E.Tests.DataSurvivalFailover
