/-
  StateMachine/NodeGuard.lean — what the node-guard webhook allows (A0 stage
  6b, flare-ci-inputs/decisions/A0-DESIGN-rc68.md). Pure; Main reads the
  review, the operator's map and the Ready pods, and answers.

  A graceful `kubectl delete pod` of a data pod is safe: the pod turns
  Terminating, its preStop waits, and the ordered handover (stage 5) moves a
  master's partition to a caught-up replica. What is refused is what skips
  that: a force delete (grace 0: no preStop, no handover) of a pod holding
  data, the delete of a master with no replica to hand over to, and a
  StatefulSet scale-down that removes ordinals still holding data.
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.NodeGuard

open FlareOperator.K8s

inductive Verdict where
  | allow (why : String)
  | deny (why : String)
  deriving Repr, BEq

private def roleName : FlareRole → String
  | .Master => "master"
  | .Slave => "replica (slave)"
  | .Proxy => "proxy"

def Verdict.allowed : Verdict → Bool
  | .allow _ => true
  | .deny _ => false

def Verdict.message : Verdict → String
  | .allow why => why
  | .deny why => why

/-- The annotation that lets one pod (by UID) through anyway: an explicit,
    audited exception (logged by the operator). -/
def overrideAnnotation : String := "flare.gree.net/delete-override"

/-- Requests the guard never stands in the way of: the operator itself, and
    Kubernetes' own controllers (namespace deletion, garbage collection, the
    node lifecycle; the StatefulSet controller removes pods only after a
    scale-down this guard already allowed), and the kubelet's confirmation of
    a pod that already terminated. -/
def trustedRequester (username operatorAccount : String) : Bool :=
  (!operatorAccount.isEmpty && username == operatorAccount)
  || username == "system:kube-controller-manager"
  || username.startsWith "system:serviceaccount:kube-system:"
  -- the kubelet confirms a terminated pod's removal with its own DELETE
  -- (grace 0) once the containers stopped: refusing it would leave every
  -- deleted pod Terminating
  || username.startsWith "system:node:"

/-- An Active, Ready replica of `partition` other than `except`. -/
def hasSuccessor (s : FlareClusterState) (readyKeys : List String) (partition : Int) (except : String) : Bool :=
  s.nodeMap.any fun (k, n) =>
    k != except && n.role == FlareRole.Slave && n.state == FlareState.Active
      && n.partition == partition && readyKeys.contains k

/-- DELETE of the flared pod whose node key is `nodeKey`. -/
def podDelete (s : FlareClusterState) (readyKeys : List String) (requester operatorAccount : String)
    (nodeKey podUid : String) (overrideUid : Option String) (gracePeriod : Option Nat) : Verdict :=
  if trustedRequester requester operatorAccount then .allow s!"requested by {requester}"
  else if !podUid.isEmpty && overrideUid == some podUid then
    .allow s!"{overrideAnnotation} names this pod (uid {podUid}): allowed as an explicit exception"
  else match s.lookupNode nodeKey with
  | none => .allow "the pod is not in the flare node map (it holds no data)"
  | some n =>
    if n.role == FlareRole.Proxy then .allow "the pod is a proxy (it holds no data)"
    else if gracePeriod == some 0 then
      .deny s!"flare: a force delete (grace period 0) of a {roleName n.role} skips its preStop and the ordered handover, so acknowledged writes can be lost. Delete it without --force / --grace-period=0 (the operator hands a master over first), or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
    else if n.role == FlareRole.Master && !hasSuccessor s readyKeys n.partition nodeKey then
      .deny s!"flare: this pod is the master of partition {n.partition} and no Active, Ready replica can take it over now, so deleting it loses the partition's master (and its data on tmpfs). Wait until a replica has caught up, or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
    else if n.role == FlareRole.Master then
      .allow "a graceful delete of a master with a caught-up replica: the ordered handover moves its partition"
    else .allow s!"a graceful delete of a {roleName n.role}: its partition keeps its master"

/-- UPDATE of the flared StatefulSet (or its scale subresource) from
    `oldReplicas` to `newReplicas`; `keyOf i` is the node key of ordinal `i`. -/
def scale (s : FlareClusterState) (requester operatorAccount : String)
    (oldReplicas newReplicas : Nat) (keyOf : Nat → String) : Verdict :=
  if newReplicas >= oldReplicas then .allow "replicas are not reduced"
  else if trustedRequester requester operatorAccount then .allow s!"requested by {requester}"
  else
    let removed := (List.range (oldReplicas - newReplicas)).map (· + newReplicas)
    let holding := removed.filter fun i =>
      (s.lookupNode (keyOf i)).any fun n => n.role != FlareRole.Proxy
    if holding.isEmpty then .allow s!"the removed ordinals {removed} hold no data (proxies or not in the map)"
    else .deny s!"flare: scaling {oldReplicas} -> {newReplicas} removes ordinal(s) {holding} that still hold data (a master or a replica). Move their data first (the operator does this when the FlareCluster's replicas are reduced), or scale down only ordinals that are proxies"

end FlareOperator.NodeGuard
