/-
  Operator/FreshGate.lean - the rebuild-concurrency gate decided on a FRESH
  read of the nodes (flare-operator-slow-reconcile, review of PR #188).

  The FSM commits several times in one pass and each commit may admit a NEW
  assignment. An observation (idle / running) read for one decision must not
  be reused by the next: a reconstruction may have started in between, and a
  stale idle would admit a second assignment (one rebuild per cluster / per
  partition). `decide` calls `observe` once per decision, only when the
  decision has a new assignment to admit; the nodes of that one decision are
  read together by `observe` (Parallel.readFresh).
-/
import FlareOperator.StateMachine.RebuildConcurrency

namespace FlareOperator.FreshGate

open FlareOperator.K8s
open FlareOperator.RebuildConcurrency

structure Verdict where
  decision : Decision
  /-- nodes running (or unreadable) by this decision's own read -/
  running : List String
  parked : List String
  /-- whether this decision read the nodes -/
  read : Bool

/-- One gate decision of `after` against `before`. `observe` is called at most
    once, and only when `after` holds a new assignment. -/
def decide (observe : IO (List (String × Obs))) (parkedBefore : List String)
    (before after : FlareClusterState) (perPartition clusterWide : Nat) : IO Verdict := do
  let needs := after.nodeMap.any fun (k, a) => newAssignment (before.lookupNode k) a
  let (running, parked) ← if needs then pure (reconcile parkedBefore (← observe))
    else pure ([], parkedBefore)
  pure { decision := gate before after perPartition clusterWide running parked
         running, parked, read := needs }

end FlareOperator.FreshGate
