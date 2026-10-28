/-
  StateMachine/Rolling.lean — operator-driven replacement of the flared pods
  (A0, flare-lossless-a0-gate; design:
  flare-ci-inputs/decisions/A0-DESIGN-rc68.md).

  The StatefulSet uses updateStrategy OnDelete: a template change (helm
  upgrade, `kubectl rollout restart`) replaces no pod by itself. The operator
  replaces the pods not on the StatefulSet's update revision, ONE at a time,
  and only while the cluster is stable — so a master is never deleted while
  its replica is still catching up (with RollingUpdate the StatefulSet
  controller deleted the master as soon as the restarted replica was Ready,
  before it was eligible: no successor for the handover).

  Order: the pods that are not masters first; a master last, by deleting it
  (Terminating → the ordered handover moves its partition to a caught-up
  replica). Nothing is persisted: every pass decides again from what it
  observes, so a restart or a leader change simply continues.

  Everything here is pure; Main reads the observations and deletes the pod.
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Rolling

open FlareOperator.K8s

/-- One flared pod as the rolling decision sees it. -/
structure Candidate where
  name : String
  nodeKey : String
  uid : String
  /-- controller-revision-hash ("" = not labelled: never replaced) -/
  revision : String
  ready : Bool
  terminating : Bool
  deriving Repr, BEq, Inhabited

inductive Decision where
  /-- nothing to replace -/
  | idle (why : String)
  /-- something to replace, not now -/
  | wait (why : String)
  /-- delete this pod (UID precondition) -/
  | delete (c : Candidate) (why : String)
  deriving Repr, BEq

def Decision.label : Decision → String
  | .idle why => s!"idle ({why})"
  | .wait why => s!"waiting ({why})"
  | .delete c why => s!"delete {c.name} ({why})"

/-- The pods created from another revision than `updateRev`. -/
def outdated (updateRev : String) (pods : List Candidate) : List Candidate :=
  pods.filter fun p => !p.revision.isEmpty && p.revision != updateRev

/-- Stable enough to take one pod down: every partition of the map has an
    Active master and `slavesPerPartition` Active slaves, every slave is
    eligible (R3, not rebuilding), every pod is Ready, and no handover or
    replica repair is running. -/
def stable (s : FlareClusterState) (slavesPerPartition : Nat) (readyKeys eligibleSlaves : List String)
    (busy : Bool) : Bool :=
  !busy && !s.partitionMap.isEmpty &&
  s.partitionMap.all (fun (_, part) =>
    (match part.master with
     | some m => (s.lookupNode m).any (fun n => n.role == FlareRole.Master && n.state == FlareState.Active)
                   && readyKeys.contains m
     | none => false)
    && (part.slaves.filter fun k =>
          (s.lookupNode k).any (fun n => n.role == FlareRole.Slave && n.state == FlareState.Active)
            && readyKeys.contains k && eligibleSlaves.contains k).length >= slavesPerPartition)

/-- The one pod to delete now, if any. `stablePasses` = consecutive passes
    the cluster was stable (≥ `needPasses` before a delete: the previous
    replacement's replica settles first). -/
def decide (updateRev : String) (pods : List Candidate) (masterKeys : List String)
    (stablePasses needPasses : Nat) : Decision :=
  let old := outdated updateRev pods
  if updateRev.isEmpty then .idle "the StatefulSet has no update revision"
  else if old.isEmpty then .idle "every pod is on the update revision"
  else if pods.any (·.terminating) then .wait "a pod is terminating"
  else if stablePasses < needPasses then .wait s!"the cluster has been stable for {stablePasses} of {needPasses} pass(es)"
  else
    -- highest ordinal first, as the StatefulSet controller would
    let byName := fun (l : List Candidate) => (l.toArray.qsort (fun a b => a.name > b.name)).toList
    match byName (old.filter fun p => !masterKeys.contains p.nodeKey) with
    | c :: _ => .delete c s!"{old.length} pod(s) not on revision {updateRev}; not a master first"
    | [] =>
      match byName old with
      | c :: _ => .delete c s!"only master(s) left to replace; the ordered handover moves its partition"
      | [] => .idle "every pod is on the update revision"

end FlareOperator.Rolling
