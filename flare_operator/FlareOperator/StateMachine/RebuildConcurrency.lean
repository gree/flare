/-
  Copy retention, concurrency (docs/design-copy-retention.md §10): at most
  ONE rebuild per partition and ONE in the whole cluster.

  What counts as rebuilding (both survive an operator restart: the map is
  persisted, stats belong to each node):
    * a node the map has as a Slave in Prepare;
    * a node that reports a running reconstruction in its own stats
      (`reconstruction_current_state=running`), whatever the map says —
      e.g. a restarted member catching up at boot.

  The control point is the ASSIGNMENT: flared starts a rebuild of a copy only
  when the map makes it a Prepare slave. A NEW assignment (Proxy -> Slave in
  Prepare, made by the reconcile pass: initial build, refill, re-seat after a
  repair, zone swap) that would exceed a limit is HELD: the node keeps its
  previous entry (Proxy) for this pass and is assigned on a later one.

  Not gated (counted, but never turned back into a Proxy — listed as the
  exceptions §10 asks for):
    * a member REJOINING its partition over TCP after a restart (it may hold
      the partition's only data; demoting it to Proxy is how data was lost
      before) — it is usually a WAL catch-up, not a copy;
    * a MASTER being reconstructed (availability: the partition needs one);
    * flared's own catch-up at boot without a map change.
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.RebuildConcurrency

open FlareOperator.K8s

/-- The map has this node rebuilding a copy. -/
def rebuilding (n : FlareNode) : Bool :=
  n.role == FlareRole.Slave && n.state == FlareState.Prepare

/-- A NEW rebuild: not rebuilding (and not a Slave of the same partition) in
    `before`, rebuilding in `after`. -/
def newAssignment (before? : Option FlareNode) (after : FlareNode) : Bool :=
  rebuilding after &&
    match before? with
    | none => false          -- registered in this very pass (TCP): not the reconcile's assignment
    | some b => b.role == FlareRole.Proxy

structure Decision where
  state : FlareClusterState
  /-- (node key, why it was held) -/
  held : List (String × String) := []

/-- Gate the reconcile pass's NEW assignments in `after` against what is
    already rebuilding (`before`'s map plus `running`, the nodes whose stats
    report a running reconstruction). Deterministic (map order). A held node
    keeps its `before` entry. -/
def gate (before after : FlareClusterState) (perPartition clusterWide : Nat)
    (running : List String := []) : Decision := Id.run do
  let existing := (before.nodeMap.filter fun kv => rebuilding kv.2).map Prod.fst
  let counted := existing ++ (running.filter fun k => !existing.contains k)
  let partOf := fun (k : String) => ((before.lookupNode k).map (·.partition)).getD (-1)
  let mut admitted : List (String × Int) := counted.map fun k => (k, partOf k)
  let mut nodeMap := after.nodeMap
  let mut held : List (String × String) := []
  for (k, a) in after.nodeMap do
    if newAssignment (before.lookupNode k) a then
      let inPart := (admitted.filter fun (_, p) => p == a.partition).length
      if admitted.length ≥ clusterWide || inPart ≥ perPartition then
        let why := if inPart ≥ perPartition
          then s!"partition {a.partition} already has {inPart} rebuild(s) (limit {perPartition})"
          else s!"the cluster already has {admitted.length} rebuild(s) (limit {clusterWide})"
        match before.lookupNode k with
        | some b => nodeMap := nodeMap.map fun kv => if kv.1 == k then (k, b) else kv
        | none => pure ()
        held := held ++ [(k, why)]
      else
        admitted := admitted ++ [(k, a.partition)]
  let st := FlareClusterState.rebuildPartitionMap { after with nodeMap := nodeMap }
  return { state := st, held := held }

end FlareOperator.RebuildConcurrency
