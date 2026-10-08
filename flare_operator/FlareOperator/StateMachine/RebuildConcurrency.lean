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

/-- One FRESH observation of a node, from a single stats read (review round
    2): a parked rebuild still reports its reconstruction as running (its
    thread waits inside it), so "running" and "parked" are decided together. -/
inductive Obs where
  | absent          -- the pod is confirmed NotFound
  | idle
  | running         -- a reconstruction running or a copy in flight, not parked-idle
  | parkedIdle      -- parked, nothing in flight, not serving
  | unknown         -- the pod or its stats could not be read: a rebuild is not ruled out
  deriving Repr, BEq

/-- One stat flag as read: explicit 0, explicit 1, missing, or present but invalid. -/
inductive Flag where
  | zero | one | missing | invalid
  deriving Repr, BEq

private def statValue (lines : List String) (k : String) : Option String :=
  lines.findSome? fun l =>
    if l.startsWith s!"STAT {k} " then some (l.drop (s!"STAT {k} ").length)
    else if l == s!"STAT {k}" then some "" else none

def flagOf (lines : List String) (k : String) : Flag :=
  match statValue lines k with
  | none => .missing
  | some "0" => .zero
  | some "1" => .one
  | some _ => .invalid

/-- The fresh observation from ONE stats reply, keeping missing and invalid
    apart from an explicit 0 (review round 3). `podFound`: `some false` =
    confirmed absent (an empty `--ignore-not-found` answer), `none` = the pod
    lookup failed. Parked-idle ONLY on an explicit parked=1, in_flight=0 and
    snapshot_serving=0; parked=1 with either of the others missing or invalid
    is unknown (a slot is never given back on a guess). -/
def obsOfReply (podFound : Option Bool) (reply : Option String) : Obs :=
  match podFound with
  | some false => .absent
  | none => .unknown
  | some true =>
    match reply with
    | none => .unknown
    | some out =>
      let lines := (out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)
      if !lines.contains "END" then .unknown else
      let parked := flagOf lines "rebuild_parked"
      let inFlight := flagOf lines "rebuild_in_flight"
      let serving := flagOf lines "rocksdb_snapshot_serving"
      let rs := statValue lines "reconstruction_current_state"
      let rsValid := match rs with
        | none => true
        | some v => ["none", "running", "succeeded", "failed", "aborted"].contains v
      if parked == .invalid || inFlight == .invalid || serving == .invalid || !rsValid then .unknown
      else if parked == .one then
        if inFlight == .one || serving == .one then .running
        else if inFlight == .zero && serving == .zero then .parkedIdle
        else .unknown
      else if inFlight == .one || rs == some "running" then .running
      else .idle

/-- Combine an OLDER parked list with FRESH observations. A fresh running or
    unknown reading wins over an older "parked" (the slot is not given back
    on a stale reading); a fresh parked-idle reading counts as parked; a key
    not read now keeps its older standing. -/
def reconcile (oldParked : List String) (fresh : List (String × Obs)) : List String × List String :=
  let running := fresh.filterMap fun (k, o) => if o == .running || o == .unknown then some k else none
  let freshParked := fresh.filterMap fun (k, o) => if o == .parkedIdle then some k else none
  let keptOld := oldParked.filter fun k => !(fresh.any (·.1 == k))
  (running, (keptOld ++ freshParked).eraseDups)

structure Decision where
  state : FlareClusterState
  /-- (node key, why it was held) -/
  held : List (String × String) := []

/-- Gate the reconcile pass's NEW assignments in `after` against what is
    already rebuilding (`before`'s map plus `running`, the nodes whose stats
    report a running reconstruction). Deterministic (map order). A held node
    keeps its `before` entry. -/
def gate (before after : FlareClusterState) (perPartition clusterWide : Nat)
    (running : List String := []) (parkedIdle' : List String := []) : Decision := Id.run do
  -- a key observed running (or unknown) is never subtracted as parked
  let parkedIdle := parkedIdle'.filter (!running.contains ·)
  let existing := (before.nodeMap.filter fun kv => rebuilding kv.2).map Prod.fst
  let counted := existing ++ (running.filter fun k => !existing.contains k)
  let partOf := fun (k : String) => ((before.lookupNode k).map (·.partition)).getD (-1)
  -- a PARKED rebuild with nothing left in flight (no transfer, serve or
  -- switch: read from its stats) gives back its CLUSTER slot; it still holds
  -- its partition's slot (the same replica is never rebuilt twice)
  let mut admitted : List (String × Int) := counted.map fun k => (k, partOf k)
  let mut clusterCount : Nat := (counted.filter fun k => !parkedIdle.contains k).length
  let mut nodeMap := after.nodeMap
  let mut held : List (String × String) := []
  for (k, a) in after.nodeMap do
    if newAssignment (before.lookupNode k) a then
      let inPart := (admitted.filter fun (_, p) => p == a.partition).length
      if clusterCount ≥ clusterWide || inPart ≥ perPartition then
        let why := if inPart ≥ perPartition
          then s!"partition {a.partition} already has {inPart} rebuild(s) (limit {perPartition})"
          else s!"the cluster already has {clusterCount} running rebuild(s) (limit {clusterWide})"
        match before.lookupNode k with
        | some b => nodeMap := nodeMap.map fun kv => if kv.1 == k then (k, b) else kv
        | none => pure ()
        held := held ++ [(k, why)]
      else
        admitted := admitted ++ [(k, a.partition)]
        clusterCount := clusterCount + 1
  let st := FlareClusterState.rebuildPartitionMap { after with nodeMap := nodeMap }
  return { state := st, held := held }

/-- Which parked rebuild may be RESUMED now (it takes its slot again): the
    first parked-idle rebuilding node (map order) when no other rebuild runs
    in the cluster beyond the limit and none other in its partition. -/
def resumeCandidate (state : FlareClusterState) (perPartition clusterWide : Nat)
    (parkedIdle' : List String) (running : List String := []) : Option String :=
  let parkedIdle := parkedIdle'.filter (!running.contains ·)
  let rebuildingKeys := (state.nodeMap.filter fun kv => rebuilding kv.2).map Prod.fst
  let counted := rebuildingKeys ++ (running.filter fun k => !rebuildingKeys.contains k)
  let active := counted.filter fun k => !parkedIdle.contains k
  if active.length ≥ clusterWide then none
  else
    let partOf := fun (k : String) => ((state.lookupNode k).map (·.partition)).getD (-1)
    parkedIdle.find? fun k =>
      rebuildingKeys.contains k &&
        (counted.filter fun o => o != k && partOf o == partOf k).length < perPartition

end FlareOperator.RebuildConcurrency
