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
        - nothing shows the cluster ever ran  → first build: start fresh
        - something shows it ran              → halt: an actual loss
        - the evidence cannot be read         → retry
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

/-- Evidence that this cluster ran before (independent of the ConfigMap). -/
inductive History where
  /-- Nothing shows a previous incarnation: no marker on the Lease, and every
      flared pod that could be read reports no node map and no data. -/
  | none (detail : String)
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
  let nodeLines := lines.filter (fun l => !l.startsWith "version=")
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
        else .ok { FlareClusterState.default with nodeMap := nodes, nodeMapVersion := version }

private def missing (what : String) (h : History) (reset : Bool) : Decision :=
  match h with
  | .none detail => .fresh s!"first build: the node map is {what} and nothing shows a previous incarnation ({detail})"
  | .unknown why => .retry s!"the node map is {what} and first build cannot be told from loss: {why}"
  | .seen why =>
    if reset then .fresh s!"FLARE_NODE_MAP_RESET=1: starting from an EMPTY map although it is {what} and the cluster ran before ({why})"
    else .halt s!"the node map is {what} but the cluster ran before ({why}): refusing to start from an empty map. Restore the ConfigMap, or set FLARE_NODE_MAP_RESET=1 to accept a fresh start (RUNBOOK #node-map-lost)"

def decide (r : Read) (h : History) (reset : Bool) : Decision :=
  match r with
  | .failed why => .retry s!"reading the node map failed: {why}"
  | .notFound => missing "missing" h reset
  | .present data =>
    if data.trim.isEmpty then missing "empty" h reset
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

/-- One flared pod's stats, as far as they bear on history. -/
structure PodEvidence where
  name : String
  ready : Bool
  /-- `none` = stats could not be read. -/
  nodeMapVersion : Option Nat := none
  currItems : Option Nat := none

/-- Combine the Lease marker and the pods' stats into History. A pod that is
    not Ready and cannot be read gives no evidence either way (on a first
    build flared exits until the operator serves, so its stats are
    unreadable); a Ready pod that cannot be read leaves the answer unknown. -/
def history (leaseMarker : Option String) (podsListed : Bool) (pods : List PodEvidence) : History :=
  match leaseMarker with
  | some v => .seen s!"the Lease records a persisted node map (version {v})"
  | none =>
    if !podsListed then .unknown "the flared pods could not be listed"
    else
      match pods.find? (fun p => p.nodeMapVersion.getD 0 > 0 || p.currItems.getD 0 > 0) with
      | some p => .seen s!"pod {p.name} reports node map version {p.nodeMapVersion.getD 0} and {p.currItems.getD 0} items"
      | none =>
        match pods.find? (fun p => p.ready && p.nodeMapVersion.isNone) with
        | some p => .unknown s!"Ready pod {p.name} did not answer stats"
        | none =>
          let unread := (pods.filter (·.nodeMapVersion.isNone)).length
          .none s!"{pods.length} pod(s), {unread} not Ready and unread, none with a node map or data"

end FlareOperator.NodeMapRecovery
