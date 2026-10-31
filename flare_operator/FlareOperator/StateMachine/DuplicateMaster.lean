/-
  StateMachine/DuplicateMaster.lean — a node that claims to be the master of a
  partition whose master in the DISTRIBUTED node map is another node (spec 13,
  user decision 2026-10-31: inconsistency is not tolerated).

  Every node gets the same node map, so such a claim means the node runs on a
  map other than the one the operator committed (it missed the push, or it is
  ahead of it). The topology audit already re-sends the map to a node that is
  behind; when the claim still stands after flarei's detection time
  (monitor_threshold x monitor_interval, 15 s, the same wait as for an
  unreachable node, StateMachine/UnreachableNode) the node joins the unhealthy
  list and is treated as down (proxy). The map's master is left as it is.

  Only a node on a map version OTHER than the committed one (the audit's
  verdict behind or ahead) can conflict: on the current map its view is the
  operator's own (spec 13: "配った版と違う版で master を名乗るノード").

  Pure: Main reads the claim from the audit's `stats` reply and keeps the
  first-seen times. Nothing is decided while the operator reaches no node
  (UnreachableNode's guard): then the evidence itself is suspect.
-/
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.UnreachableNode

namespace FlareOperator.DuplicateMaster

open FlareOperator.K8s

/-- How long a conflicting claim must stand before the node is treated as
    down: flarei's monitor_threshold x monitor_interval (15 s). -/
def holdMs : Nat :=
  FlareOperator.UnreachableNode.monitorThreshold * FlareOperator.UnreachableNode.monitorIntervalSec * 1000

private def statValue (reply key : String) : Option String :=
  (reply.splitOn "\n").findSome? fun line =>
    match (line.trim.replace "\r" "").splitOn " " with
    | ["STAT", k, v] => if k == key then some v else none
    | _ => none

/-- The (role, partition) a node reports about itself (`own_role`,
    `own_partition` in its `stats`); none when either is missing. -/
def ownClaim (reply : String) : Option (String × Int) := do
  let role ← statValue reply "own_role"
  let part ← (statValue reply "own_partition").bind String.toInt?
  return (role, part)

/-- The claim names this node master of a partition whose master in the
    committed map is a DIFFERENT node. A claim the map agrees with, a
    partition the map has no master for, or any other role is no conflict. -/
def conflicts (state : FlareClusterState) (key : String) (claim : String × Int) : Bool :=
  claim.1 == "master" && claim.2 ≥ 0 &&
    state.nodeMap.any (fun (k, n) => k != key && n.role == FlareRole.Master && n.partition == claim.2)

/-- One audit sample of `key` at `nowMs`: the first-seen times of standing
    conflicts after it, and whether `key` is now to be treated as down.
    `claim` none (unreadable) keeps what was known; no conflict clears it. -/
def step (firstSeen : List (String × Nat)) (key : String) (conflict : Option Bool) (nowMs : Nat)
    : List (String × Nat) × Bool :=
  match conflict with
  | none => (firstSeen, match firstSeen.lookup key with
      | some t => nowMs ≥ t + holdMs
      | none => false)
  | some false => (firstSeen.filter (·.1 != key), false)
  | some true =>
    match firstSeen.lookup key with
    | some t => (firstSeen, nowMs ≥ t + holdMs)
    | none => (firstSeen ++ [(key, nowMs)], false)

end FlareOperator.DuplicateMaster
