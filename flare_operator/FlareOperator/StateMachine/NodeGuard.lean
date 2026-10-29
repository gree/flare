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
    scale-down this guard already allowed). The kubelet is NOT here: see
    `kubeletConfirms` (review of 262fde9: every system:node:* was trusted). -/
def trustedRequester (username operatorAccount : String) : Bool :=
  (!operatorAccount.isEmpty && username == operatorAccount)
  || username == "system:kube-controller-manager"
  || username.startsWith "system:serviceaccount:kube-system:"

/-- The kubelet's own DELETE that confirms a pod already terminating (it has
    a deletionTimestamp: a delete this guard judged earlier) — and only by the
    kubelet of the node the pod runs on. Refusing it would leave every
    deleted pod Terminating. -/
def kubeletConfirms (username podNodeName : String) (podTerminating : Bool) : Bool :=
  podTerminating && !podNodeName.isEmpty && username == s!"system:node:{podNodeName}"

/-- A replica of `partition` other than `except` that the handover can
    promote now: an Active Slave in the map that is in `caughtUp` — the keys
    Main proved for this review (pod Ready and not Terminating, R3
    `repl_read_source_eligible=1` read now, no replica repair pending). Map
    roles alone are not enough (review of 262fde9: a stale replica let the
    delete through while the handover could not promote it). -/
def hasSuccessor (s : FlareClusterState) (caughtUp : List String) (partition : Int) (except : String) : Bool :=
  s.nodeMap.any fun (k, n) =>
    k != except && n.role == FlareRole.Slave && n.state == FlareState.Active
      && n.partition == partition && caughtUp.contains k

/-- What the guard needs to know about the deleted pod besides the map. -/
structure PodFacts where
  nodeKey : String
  uid : String
  /-- the override annotation's value, if any -/
  overrideUid : Option String := none
  gracePeriod : Option Nat := none
  /-- spec.nodeName -/
  nodeName : String := ""
  /-- metadata.deletionTimestamp is set -/
  terminating : Bool := false
  /-- the pod's flared predates the ordered handover (an older release: no
      boot id / forward counters), so it can never be handed over losslessly
      (Handover.oldMasterPredatesHandover) -/
  predatesHandover : Bool := false
  /-- the operator is configured to accept that NOT loss-free switch
      (legacyMasterSwitch, FLARE_OPERATOR_LEGACY_MASTER_SWITCH=allow) -/
  legacySwitchAllowed : Bool := false
  /-- an ordered handover from this pod (its UID) is still running (not done,
      not aborted): the map may already show it as a proxy (V2 committed)
      before every pod has V2 (998dc30 G1: the delete was allowed between the
      commit and `done`) -/
  handoverUnfinished : Bool := false
  deriving Repr

/-- DELETE of the flared pod `pod`. `initialized` = the operator finished a
    full pass on its persisted map; before that (startup, a fresh leader) the
    map may be the empty default and nothing can be judged: refused (review
    of 262fde9: the webhook started before the map was loaded failed open). -/
def podDelete (initialized : Bool) (s : FlareClusterState) (caughtUp : List String)
    (requester operatorAccount : String) (pod : PodFacts) : Verdict :=
  if trustedRequester requester operatorAccount then .allow s!"requested by {requester}"
  else if kubeletConfirms requester pod.nodeName pod.terminating then
    .allow s!"the kubelet of {pod.nodeName} confirms the removal of a pod already terminating"
  else if !pod.uid.isEmpty && pod.overrideUid == some pod.uid then
    .allow s!"{overrideAnnotation} names this pod (uid {pod.uid}): allowed as an explicit exception"
  else if !initialized then
    .deny s!"flare: the operator has not finished reading the cluster yet (just started or just became leader), so it cannot tell what this pod holds. Retry in a few seconds, or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
  else match s.lookupNode pod.nodeKey with
  | none =>
    .deny s!"flare: this pod is not in the operator's node map, so it cannot tell what the pod holds (it may be starting with data on its volume). Retry once it has registered, or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
  | some n =>
    if pod.handoverUnfinished then
      .deny "flare: the ordered handover from this pod is still completing (the promote map is not on every pod yet); retry the delete in a few seconds"
    else if n.role == FlareRole.Proxy then .allow "the pod is a proxy (it holds no data)"
    else if pod.gracePeriod == some 0 then
      .deny s!"flare: a force delete (grace period 0) of a {roleName n.role} skips its preStop and the ordered handover, so acknowledged writes can be lost. Delete it without --force / --grace-period=0 (the operator hands a master over first), or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
    else if n.role == FlareRole.Master && !hasSuccessor s caughtUp n.partition pod.nodeKey then
      .deny s!"flare: this pod is the master of partition {n.partition} and no replica is caught up enough to take it over now (Active, Ready, eligible as a read source, no repair pending), so deleting it can lose the partition's master (and its data on tmpfs). Wait until a replica has caught up, or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
    else if n.role == FlareRole.Master && pod.predatesHandover && pod.legacySwitchAllowed then
      -- the one-time upgrade from a release before the handover, accepted
      -- explicitly by the operator's configuration
      .allow "a graceful delete of a master running a flared from before the ordered handover, with a caught-up replica, accepted by legacyMasterSwitch: the drain promotes it — NOT loss-free"
    else if n.role == FlareRole.Master && pod.predatesHandover then
      .deny s!"flare: this pod is the master of partition {n.partition} and runs a flared from before the ordered handover, which cannot be handed over without possible loss. Set the operator's legacyMasterSwitch (FLARE_OPERATOR_LEGACY_MASTER_SWITCH=allow) to accept that for this upgrade, or annotate the pod {overrideAnnotation}=<its uid>"
    else if n.role == FlareRole.Master then
      -- review of 9756855 (TOCTOU): a delete is irreversible, and the
      -- successor read now can change before a handover that starts from the
      -- pod's Terminating. The master is handed over FIRST (the operator
      -- starts it on this refusal: requestsHandover); once it is a proxy the
      -- retried delete is allowed above.
      .deny s!"flare: this pod is the master of partition {n.partition}. The operator is now handing the partition over to a caught-up replica (an ordered switch, normally seconds); retry the delete once it has — the pod is then a proxy and the delete is allowed. Or annotate the pod {overrideAnnotation}=<its uid> to accept the risk explicitly"
    else .allow s!"a graceful delete of a {roleName n.role}: its partition keeps its master"

/-- The delete refused above asks the operator to hand this master over now:
    a graceful delete of the Active master of a partition that has a caught-up
    successor, by a requester the guard judges (not the operator, not an
    override, the cluster read). -/
def requestsHandover (initialized : Bool) (s : FlareClusterState) (caughtUp : List String)
    (requester operatorAccount : String) (pod : PodFacts) : Bool :=
  initialized && !trustedRequester requester operatorAccount
    && !kubeletConfirms requester pod.nodeName pod.terminating
    && !(!pod.uid.isEmpty && pod.overrideUid == some pod.uid)
    && pod.gracePeriod != some 0 && !pod.terminating && !pod.predatesHandover
    && match s.lookupNode pod.nodeKey with
       | some n => n.role == FlareRole.Master && n.state == FlareState.Active && hasSuccessor s caughtUp n.partition pod.nodeKey
       | none => false

/-- UPDATE of the flared StatefulSet (or its scale subresource) from
    `oldReplicas` to `newReplicas`; `keyOf i` is the node key of ordinal `i`. -/
def scale (initialized : Bool) (s : FlareClusterState) (requester operatorAccount : String)
    (oldReplicas newReplicas : Nat) (keyOf : Nat → String) : Verdict :=
  if newReplicas >= oldReplicas then .allow "replicas are not reduced"
  else if trustedRequester requester operatorAccount then .allow s!"requested by {requester}"
  else if !initialized then
    .deny "flare: the operator has not finished reading the cluster yet (just started or just became leader), so it cannot tell what the removed ordinals hold. Retry in a few seconds"
  else
    let removed := (List.range (oldReplicas - newReplicas)).map (· + newReplicas)
    -- not in the map = unknown, not empty (it may hold data on its volume)
    let holding := removed.filter fun i =>
      match s.lookupNode (keyOf i) with
      | some n => n.role != FlareRole.Proxy
      | none => true
    if holding.isEmpty then .allow s!"the removed ordinals {removed} hold no data (proxies)"
    else .deny s!"flare: scaling {oldReplicas} -> {newReplicas} removes ordinal(s) {holding} that still hold data (a master or a replica) or that the operator does not know. Move their data first (the operator does this when the FlareCluster's replicas are reduced), or scale down only ordinals that are proxies"

end FlareOperator.NodeGuard
