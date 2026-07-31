/-
  E2E/Tests/CircuitBreaker.lean - AZ-scale outage: pause, don't flail

  The blast-radius circuit breaker (K8sReconciler.circuitBreakerDecision) had
  FSM-level theorems but no end-to-end exercise. This suite induces a
  sustained majority outage (scale the StatefulSet 4→1: 75% of Active nodes
  dead ≥ default 50% threshold), asserts the operator TRIPS and performs NO
  failover churn while tripped, then restores capacity and asserts recovery
  resumes AUTOMATICALLY — no operator restart (the FSM re-evaluates from
  Init every tick; an earlier log line claiming manual reset was wrong and
  is also fixed).

  Timing note: dead-node detection is suppressed for the operator's 120s
  startup grace period, so the outage is induced only after that.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.CircuitBreaker

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "breaker"
  «namespace» := "flare-breaker"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-breaker"
}

private def numPods : Nat := cfg.partitions * cfg.replicas

private def operatorLogs : IO String := do
  match ← kubectl ["logs", "-n", cfg.«namespace», "-l", "app=flare-operator",
                    "--tail=300"] with
  | .ok out => return out
  | .error _ => return ""

private def activeMasterCount : IO Nat := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return countMasters (parseNodeSync sync)

def suite : TestSuite := {
  name := "circuit-breaker"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace»
  teardown := cleanupCluster cfg
  tests := [
    { name := "baseline: two active masters"
      run := do
        let n ← activeMasterCount
        if n == 2 then return .pass
        else return .fail s!"expected 2 masters, got {n}" },

    -- Dead detection is disabled during the startup grace. The grace is
    -- counted in RECONCILE CYCLES (24), not wall-clock seconds — and a
    -- cycle is 5s sleep PLUS the reconcile's own duration (measured
    -- 1.5-2s in CI), so 24 cycles is ~160-170s of wall clock, not 120s.
    -- A fixed 125s sleep raced it (observed flake: outage induced while
    -- grace was still counting → no trip within the window). Wait on the
    -- operator's own grace countdown log instead, with a generous cap.
    { name := "wait out the operator startup grace period"
      run := do
        IO.sleep 125000
        let graceOver ← waitForCondition "grace countdown finished" 120 do
          match ← kubectl ["logs", "-n", cfg.«namespace», "-l", "app=flare-operator",
                            "--tail=5"] with
          | .error _ => return false
          | .ok out => return !(containsSubstr out "grace period:")
        if graceOver then return .pass
        else return .fail "operator still in startup grace after 245s" },

    { name := "majority outage (scale 4→1) trips the breaker"
      run := do
        match ← kubectl ["scale", s!"statefulset/{cfg.name}-nodes",
                          "-n", cfg.«namespace», "--replicas=1"] with
        | .error e => return .fail s!"scale down failed: {e}"
        | .ok _ =>
          let tripped ← waitForCondition "breaker tripped in operator log" 180 do
            return containsSubstr (← operatorLogs) "CIRCUIT BREAKER TRIPPED"
          if tripped then return .pass
          else return .fail "no CIRCUIT BREAKER TRIPPED log within 180s of majority outage" },

    -- While tripped the FSM must be inert: the dead masters keep their map
    -- entries (the pause happens BEFORE demote/failover) and nothing gets
    -- promoted into the holes. Two samples 15s apart guard against churn.
    { name := "no failover churn while tripped"
      run := do
        let n1 ← activeMasterCount
        IO.sleep 15000
        let n2 ← activeMasterCount
        if n1 == 2 && n2 == 2 then return .pass
        else return .fail s!"master entries changed under pause: {n1} then {n2} (expected 2/2 — pause must precede failover)" },

    { name := "restoring capacity resumes recovery automatically"
      run := do
        match ← kubectl ["scale", s!"statefulset/{cfg.name}-nodes",
                          "-n", cfg.«namespace», s!"--replicas={numPods}"] with
        | .error e => return .fail s!"scale up failed: {e}"
        | .ok _ =>
          -- NO operator restart here — that is the point of the assertion.
          -- 480s: readiness is sync-gated (Ready = state=active) and the STS is
          -- OrderedReady, so restored pods come back SERIALLY, each waiting for
          -- the previous one's full activation (register + assign + reseed).
          -- The old 240s budget assumed Ready = "port open" and parallel return.
          let recovered ← waitForCondition "cluster recovered after scale-up" 480 do
            match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                      "{.status.readyReplicas}" with
            | .error _ => return false
            | .ok val =>
              if val.toNat?.getD 0 < numPods then return false
              else return (← activeMasterCount) == 2
          if recovered then return .pass
          else return .fail "cluster did not auto-recover within 480s after capacity returned (auto-resume broken?)" }
  ]
}

end FlareOperator.E2E.Tests.CircuitBreaker
