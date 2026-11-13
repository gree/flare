/-
  NodeMapRecovery.lean — SAF-09: what a starting leader does with the
  persisted node map (`{cr}-node-map` ConfigMap).

  Before this module every outcome of the startup read collapsed into one:
  an API error and a missing ConfigMap both logged "no persisted state
  found, starting fresh", and a map that did not parse was loaded leniently
  (bad lines dropped, a missing version read as 0). A leader that starts
  from an empty map while the data plane still holds a topology re-assigns
  roles from scratch: the registrations that follow can seat an empty node
  as master, and its versions rank below what every flared already accepted.

  The decision is pure and distinguishes:
    * the map is present and valid           → load it
    * the read FAILED (API error, timeout)    → retry; never start fresh
    * the map is present but INVALID          → halt (a human decides)
    * the map is missing or empty, and
        - the cluster is PROVEN new           → first build: start fresh
        - something shows it ran              → halt: an actual loss
        - the past cannot be observed         → retry, unless a first build
          of THIS FlareCluster was approved by annotation (its own UID)
  Not observing the past is never read as "no past" (review 2026-10-05).
  `reset` (FLARE_NODE_MAP_RESET=1) lets a human deliberately accept a fresh
  start where the decision would halt; it never overrides a failed read.
  Automatic reconstruction of a lost map is NOT done here (later work).
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.NodeMapRecovery

open FlareOperator.K8s

/-- Outcome of reading the ConfigMap. -/
inductive Read where
  | present (data : String)
  | notFound
  | failed (why : String)
  deriving Repr, BEq

/-- Evidence about a previous incarnation (independent of the ConfigMap).
    "Could not observe the past" is NOT "there was no past": every failed or
    incomplete observation is `unknown` (review 2026-10-05). -/
inductive History where
  /-- Positive proof of a new cluster: the Lease was read and carries no
      marker, and EVERY expected flared pod answered stats with node map
      version 0 and 0 items. -/
  | provenEmpty (detail : String)
  | seen (why : String)
  | unknown (why : String)
  deriving Repr, BEq

inductive Decision where
  | load (state : FlareClusterState)
  | fresh (why : String)
  | retry (why : String)
  | halt (why : String)

def Decision.kind : Decision → String
  | .load _ => "load"
  | .fresh _ => "fresh"
  | .retry _ => "retry"
  | .halt _ => "halt"

/-- Strict parse of the persisted format written by `serializeNodeMap`:
    exactly one `version=N` line, every other non-empty line a node line,
    no duplicate keys, and a non-zero version whenever nodes are present.
    The lenient `fromNodeMapData` drops what it cannot read; at startup that
    would silently load a smaller map. -/
def validate (data : String) : Except String FlareClusterState :=
  let lines := (data.splitOn "\n").map String.trim |>.filter (· != "")
  let versionLines := lines.filter (·.startsWith "version=")
  -- history transition ids (docs/design-authoritative-history.md): one
  -- non-empty token each, no duplicates
  let transitionLines := lines.filter (·.startsWith "transition=")
  let transitionIds := transitionLines.map (·.drop "transition=".length)
  let nodeLines := lines.filter (fun l => !l.startsWith "version=" && !l.startsWith "transition=")
  if lines.isEmpty then .error "no content"
  else if versionLines.length != 1 then
    .error s!"expected exactly one version= line, found {versionLines.length}"
  else
    match (versionLines.head!.drop "version=".length).toNat? with
    | none => .error s!"unreadable version line [{versionLines.head!}]"
    | some version =>
      let parsed := nodeLines.map (fun l => (l, FlareClusterState.parseNodeMapLine l))
      match parsed.find? (·.2.isNone) with
      | some (bad, _) => .error s!"node line does not parse [{bad}]"
      | none =>
        let nodes := parsed.filterMap (·.2)
        let keys := nodes.map (·.1)
        if keys.length != keys.eraseDups.length then .error "duplicate node keys"
        else if !nodes.isEmpty && version == 0 then .error "nodes present with version 0"
        else if transitionIds.any (fun t => t.isEmpty || (t.splitOn " ").length != 1) then .error "a transition= line is empty or not one token"
        else if transitionIds.length != transitionIds.eraseDups.length then .error "duplicate transition ids"
        else .ok { FlareClusterState.default with nodeMap := nodes, nodeMapVersion := version, transitions := transitionIds }

private def missing (what : String) (h : History) (reset firstBuildApproved : Bool) : Decision :=
  match h with
  | .provenEmpty detail => .fresh s!"first build: the node map is {what} and the cluster is proven new ({detail})"
  | .unknown why =>
    if firstBuildApproved then
      .fresh s!"first build APPROVED by annotation (flare.gree.net/first-build-approved = this FlareCluster's UID): the node map is {what} and the past could not be observed ({why})"
    else .retry s!"the node map is {what} and a first build cannot be told from a loss: {why}. Restore the ConfigMap, or approve a first build of THIS FlareCluster: kubectl annotate flarecluster <name> flare.gree.net/first-build-approved=<its metadata.uid> (RUNBOOK #node-map-lost)"
  | .seen why =>
    if reset then .fresh s!"FLARE_NODE_MAP_RESET=1: starting from an EMPTY map although it is {what} and the cluster ran before ({why})"
    else .halt s!"the node map is {what} but the cluster ran before ({why}): refusing to start from an empty map. Restore the ConfigMap, or set FLARE_NODE_MAP_RESET=1 to accept a fresh start (RUNBOOK #node-map-lost)"

/-- `firstBuildApproved`: the FlareCluster carries
    flare.gree.net/first-build-approved equal to its own metadata.uid. It
    only resolves `unknown`; it never overrides `seen` or a failed read. -/
def decide (r : Read) (h : History) (reset : Bool) (firstBuildApproved : Bool := false) : Decision :=
  match r with
  | .failed why => .retry s!"reading the node map failed: {why}"
  | .notFound => missing "missing" h reset firstBuildApproved
  | .present data =>
    if data.trim.isEmpty then missing "empty" h reset firstBuildApproved
    else
      match validate data with
      | .ok s => .load s
      | .error e =>
        if reset then .fresh s!"FLARE_NODE_MAP_RESET=1: discarding an INVALID node map ({e})"
        else .halt s!"the persisted node map is invalid ({e}): refusing to load it or start fresh. Fix or remove the ConfigMap, or set FLARE_NODE_MAP_RESET=1 (RUNBOOK #node-map-lost)"

/-- Classify a `kubectl get configmap` outcome. `NotFound` is the only
    error that means "absent"; anything else is a failed read. -/
def classifyRead (result : Except String String) : Read :=
  match result with
  | .ok data => .present data
  | .error e =>
    if (e.splitOn "(NotFound)").length > 1 then .notFound
    else .failed e

/-- One flared pod's stats, as far as they bear on history. `none` = not
    observed (stats unreadable, or the field missing from the reply). -/
structure PodEvidence where
  name : String
  ready : Bool
  nodeMapVersion : Option Nat := none
  currItems : Option Nat := none

/-- Combine the Lease marker and the pods' stats into History.
    `leaseMarker`: `.ok none` = Lease read, no marker; `.error` = not read.
    `expectedPods`: partitions x replicas from the FlareCluster spec.
    `seen` needs one positive sign; `provenEmpty` needs every sign to be
    observed and empty; anything else is `unknown`. -/
def history (leaseMarker : Except String (Option String)) (podsListed : Bool)
    (pods : List PodEvidence) (expectedPods : Nat) (clusterMissing : Bool := false) : History :=
  match leaseMarker with
  | .ok (some v) => .seen s!"the Lease records a persisted node map (version {v})"
  | _ =>
    match pods.find? (fun p => p.nodeMapVersion.getD 0 > 0 || p.currItems.getD 0 > 0) with
    | some p => .seen s!"pod {p.name} reports node map version {p.nodeMapVersion.getD 0} and {p.currItems.getD 0} items"
    | none =>
      match leaseMarker with
      | .error e => .unknown s!"the Lease could not be read ({e})"
      | .ok _ =>
        if !podsListed then .unknown "the flared pods could not be listed"
        -- An ABSENT FlareCluster proves nothing about data: PVCs can outlive
        -- the CR and the pods (review 2026-10-05). The operator does not even
        -- reach this decision without a CR (it waits); `clusterMissing` only
        -- keeps the reason explicit.
        else if clusterMissing then .unknown "the FlareCluster does not exist (absence proves nothing: PVCs may hold data)"
        else if expectedPods == 0 then .unknown "the FlareCluster spec (expected pod count) is not known"
        else if pods.length < expectedPods then .unknown s!"only {pods.length} of {expectedPods} flared pods exist"
        else
          match pods.find? (fun p => p.nodeMapVersion.isNone || p.currItems.isNone) with
          | some p => .unknown s!"pod {p.name} did not report its node map version and item count{if p.ready then "" else " (not Ready)"}"
          | none => .provenEmpty s!"no Lease marker; all {pods.length} pods report node map version 0 and 0 items"

end FlareOperator.NodeMapRecovery
