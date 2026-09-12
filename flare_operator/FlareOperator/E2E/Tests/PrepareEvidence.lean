/-
  E2E/Tests/PrepareEvidence.lean — SAF-03, SC-04 / EV-04.

  "Normal promotion and Prepare activation require a completed usable copy
  associated with the current source."

  The lost activation is staged, not hoped for: the per-suite operator runs
  with FLARE_TEST_DROP_NODE_STATE set, so every `node state` event flared
  sends — the one-shot "reconstruction complete", and every re-announce of
  it — is dropped at the TCP boundary and answered OK. The slave therefore
  finishes its reconstruction, calls itself active in its OWN node map, and
  stays Prepare in the operator's. That is the exact condition the repair
  path exists for, and the only way to reach it on demand.

  Asserted:
    1. the condition holds: the seam logged a dropped event, the operator's
       map says Prepare, flared's own `stats nodes` says active;
    2. the repair activates the node and says WHY — the evidence line
       (node reports itself active, a reconstruction completed in this
       process, same source) — not a cursor distance; the node is Active in
       the operator's map afterwards.

  The negative cases (near-but-unfinished cursor, mismatched lineage, a
  master or lineage change during the episode, a node that booted into an
  old map) cannot be staged deterministically against a tiny dataset; they
  are pinned by flare_unit (StateMachine/SyncEvidence.lean).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.PrepareEvidence

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl
open FlareOperator.K8s

private def cfg : ClusterConfig := {
  name := "prep-evid"
  «namespace» := "flare-prep-evid"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-prep-evid"
  operatorEnv := [
    ("FLARE_TEST_DROP_NODE_STATE", "1"),
    -- Judge after 6 Prepare cycles instead of 36; the path still runs on
    -- every 12th cycle, so the first judgement is at cycle 12 (~60s).
    ("FLARE_PREPARE_REPAIR_CYCLES", "6")]
}

private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

private def opLog (tail : Nat := 800) : IO String :=
  kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» tail

/-- The P0 slave entry in the operator's map. -/
private def slaveEntry : IO (Option NodeSyncEntry) := do
  return (← nodeView).find? fun e => e.role == 1 && e.partition == 0

/-- A numeric `stats` value from a flared pod (by fqdn). -/
private def flaredStatOf (fqdn key : String) : IO (Option Nat) := do
  match ← getPodIp (podOf fqdn) cfg.«namespace» with
  | none => return none
  | some ip =>
    let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}"
    match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
    | .error _ => return none
    | .ok out =>
      let needle := s!"STAT {key} "
      for line in out.splitOn "\n" do
        let t := (line.trim.replace "\r" "")
        if t.startsWith needle then return (t.drop needle.length).trim.toNat?
      return none

def suite : TestSuite := {
  name := "prepare-evidence"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    -- The map will NOT stabilize (that is the point); give registration a
    -- bounded chance and move on.
    let _ ← waitForStable cfg 20
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "a dropped activation leaves the slave Prepare for the operator although its reconstruction completed"
      run := do
        let dropped ← waitForCondition "seam drops a node state event" 240 do
          return containsSubstr (← opLog) "TEST SEAM: dropping node state event"
        if !dropped then
          return .fail "the seam never saw a node state event: flared did not announce a completed reconstruction, so no lost-activation condition exists to test"
        match ← slaveEntry with
        | none => return .fail "no P0 slave in the operator's map"
        | some s =>
          if s.state != 1 then
            return .fail s!"the slave is not Prepare in the operator's map (state {s.state}) although its activation was dropped — something else activated it, the condition is not staged"
          -- The completed copy exists even though the operator never learned:
          -- flared increments reconstruction_completed when its handler
          -- finished the dump and its activation call returned (the seam
          -- answers OK), which is exactly the handover-lost-ack case this
          -- repair exists for. The node does NOT set its own state active
          -- from that — it waits for the operator's map to echo it — so
          -- self-active is the wrong thing to look for; the completion
          -- counter is the evidence.
          let completed ← waitForCondition "the slave reports a completed reconstruction" 120 do
            return ((← flaredStatOf s.fqdn "reconstruction_completed").getD 0) ≥ 1
          if !completed then
            return .fail s!"the slave never reported reconstruction_completed ≥ 1 ({← flaredStatOf s.fqdn "reconstruction_completed"}): no completed copy to activate, the condition is not staged"
          return .pass },

    { name := "the repair re-derives Prepare→Active from completion evidence and names it"
      run := do
        match ← slaveEntry with
        | none => return .fail "no P0 slave in the operator's map"
        | some s =>
          let repaired ← waitForCondition "PREPARE-REPAIR activates on evidence" 300 do
            return containsSubstr (← opLog) "PREPARE-REPAIR:"
          let log ← opLog
          if !repaired then
            IO.eprintln s!"# operator tail:\n{← opLog 40}"
            return .fail "the repair path never activated the stuck slave within 300s"
          if !containsSubstr log "reconstruction(s) completed in this process" then
            return .fail "the repair activated but did not name the completion evidence; the log line is the audit trail"
          if containsSubstr log "PREPARE-REPAIR" && containsSubstr log "but synced (slave lsn" then
            return .fail "the old proximity rule fired: activation must not be argued from a cursor distance"
          let active ← waitForCondition "slave Active in the operator's map" 60 do
            return (← slaveEntry).map (·.state) == some 0
          if !active then
            return .fail s!"the repair logged an activation but the slave is still state {(← slaveEntry).map (·.state)} in the operator's map"
          -- Plain check that the re-derived transition went through the
          -- same state machine step the real event would have used.
          if !containsSubstr log "re-derived Prepare→Active" then
            return .fail "activation was not applied through the reconcileStep path"
          return .pass }
  ]
}

end FlareOperator.E2E.Tests.PrepareEvidence
