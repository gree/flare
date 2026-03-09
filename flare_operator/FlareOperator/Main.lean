/-
  Main.lean - Flare Operator entry point
  Operator-as-Index: replaces flarei with a K8s-native operator

  Wires together:
  - K8s.Bridge: kubectl subprocess calls (CRD fetch, pod list, service patch, etc.)
  - Server.TcpServer: native TCP server for flarei text protocol
  - StateMachine.Reconciler: pure state transitions (verified)
  - Kubectl: low-level kubectl wrapper

  Reconcile loop (operatorLoop):
    1. Fetch CRD spec
    2. List live pods
    3. Detect dead nodes (pure comparison against stateRef)
    4. Handle failover (pure state transition + K8s service patches)
    5. Ensure service routing for all partitions
    6. Update ConfigMap for observability
    7. Sleep and repeat
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Bridge
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler
import FlareOperator.Kubectl
import FlareOperator.Server.TcpServer

namespace FlareOperator

open FlareOperator.K8s
open FlareOperator.K8s.Bridge
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.Kubectl
open FlareOperator.Server

-- ===========================================================================
-- CLI Argument Parsing
-- ===========================================================================

/-- Parse CLI arguments. Returns (namespace, port, reconcileInterval). -/
private def parseArgs (args : List String) : String × UInt16 × Nat :=
  let rec go (args : List String) (ns : String) (port : UInt16) (interval : Nat) :
      String × UInt16 × Nat :=
    match args with
    | [] => (ns, port, interval)
    | "--namespace" :: v :: rest => go rest v port interval
    | "--port" :: v :: rest =>
      match v.toNat? with
      | some p => go rest ns p.toUInt16 interval
      | none => go rest ns port interval
    | "--reconcile-interval" :: v :: rest =>
      match v.toNat? with
      | some i => go rest ns port i
      | none => go rest ns port interval
    | _ :: rest => go rest ns port interval
  go args "default" 12120 5

-- ===========================================================================
-- Dead Node Detection (pure)
-- ===========================================================================

/-- Detect dead nodes: nodes registered in state but not in the ready pods list.
    Uses Bridge.PodInfo for typed pod data. -/
private def detectDeadNodes (state : FlareClusterState) (pods : List PodInfo)
    : List String :=
  let liveKeys := liveNodeKeys pods
  state.nodeMap.filter (fun (key, _) => !liveKeys.contains key) |>.map Prod.fst

-- ===========================================================================
-- Failover Handler (pure state + IO for K8s patches)
-- ===========================================================================

/-- Handle failover: mark dead nodes Down, promote a Slave if master died.
    Pure state transition — no K8s I/O. -/
private def handleFailover (state : FlareClusterState) (deadKeys : List String)
    : FlareClusterState :=
  deadKeys.foldl (fun s key =>
    match s.lookupNode key with
    | none => s
    | some node =>
      let downNode := { node with state := FlareState.Down }
      let s' := s.addNode key downNode
      -- If dead node was a Master, try to promote a Slave in the same partition
      if node.role == FlareRole.Master then
        let partIdx := node.partition
        match s'.partitionMap.find? (fun (idx, _) => Int.ofNat idx == partIdx) with
        | none => s'
        | some (_, part) =>
          match part.slaves.head? with
          | none => s'
          | some slaveKey =>
            match s'.lookupNode slaveKey with
            | none => s'
            | some slaveNode =>
              let promoted := { slaveNode with role := FlareRole.Master }
              let newPart := { part with master := some slaveKey, slaves := part.slaves.tail }
              (s'.addNode slaveKey promoted).setPartition partIdx.toNat newPart
      else s'
  ) state

-- ===========================================================================
-- Service Routing
-- ===========================================================================

/-- Ensure K8s Service selectors point to the current Master for each partition. -/
private def ensureServiceRouting (state : FlareClusterState) (crName ns : String)
    : IO Unit := do
  for (_, part) in state.partitionMap do
    match part.master with
    | none => pure ()
    | some masterKey =>
      match state.lookupNode masterKey with
      | none => pure ()
      | some masterNode =>
        let svcName := s!"{crName}-{masterNode.partition}"
        match ← patchClientServiceSelector svcName ns masterNode.serverName with
        | .error e =>
          IO.eprintln s!"[flare-operator] warning: failed to patch service {svcName}: {e}"
        | .ok () => pure ()

-- ===========================================================================
-- ConfigMap Observability
-- ===========================================================================

/-- Serialize the current node map to a string for ConfigMap storage. -/
private def serializeNodeMap (state : FlareClusterState) : String :=
  let lines := state.nodeMap.map fun (key, node) =>
    s!"{key} role={node.role.toNat} state={node.state.toNat} partition={node.partition}"
  "\n".intercalate lines

/-- Update the ConfigMap with the current cluster state for observability. -/
private def updateObservabilityConfigMap (state : FlareClusterState) (crName ns : String)
    : IO Unit := do
  let cmName := s!"{crName}-node-map"
  let data := serializeNodeMap state
  match ← updateFlaredConfigMap cmName ns data with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to update configmap: {e}"
  | .ok () => pure ()

-- ===========================================================================
-- Lag Detection
-- ===========================================================================

/-- Check for severely lagging slave pods and force-restart them.
    A slave is considered lagging if it is registered but in Down state
    and still present in the ready pods list (zombie). -/
private def detectAndRestartLaggingPods (state : FlareClusterState) (pods : List PodInfo)
    (ns : String) : IO Unit := do
  let readyKeys := liveNodeKeys pods
  for (key, node) in state.nodeMap do
    -- If node is Down but still in the ready pods list, it's a zombie — force restart
    if node.state == FlareState.Down && readyKeys.contains key then
      -- Find the pod name from PodInfo list
      match pods.find? (fun p => p.toNodeKey == key) with
      | none => pure ()
      | some podInfo =>
        IO.eprintln s!"[flare-operator] force-restarting lagging pod {podInfo.name} (key={key})"
        match ← deletePod podInfo.name ns with
        | .error e =>
          IO.eprintln s!"[flare-operator] warning: failed to delete pod {podInfo.name}: {e}"
        | .ok () => pure ()

-- ===========================================================================
-- Main Reconcile Loop
-- ===========================================================================

/-- Single iteration of the operator reconcile loop.
    Implements the K8s reconcile pattern:
    fetch CRD → list pods → detect dead → failover → route services → update ConfigMap -/
private def reconcileOnce (stateRef : IO.Ref FlareClusterState) (crdRef : IO.Ref FlareClusterView)
    (crName ns : String) : IO Unit := do
  -- 1. Fetch latest CRD spec
  match ← getFlareClusterCRD crName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to fetch CRD: {e}"
  | .ok crd =>
    crdRef.set crd

  -- 2. List live pods (typed PodInfo with readiness)
  let pods ← Bridge.listFlaredPods crName ns

  -- 3. Detect dead nodes (pure)
  let state ← stateRef.get
  let deadKeys := detectDeadNodes state pods

  -- 4. Handle failover (pure state transition)
  if !deadKeys.isEmpty then
    IO.eprintln s!"[flare-operator] detected {deadKeys.length} dead node(s): {deadKeys}"
    let newState := handleFailover state deadKeys
    stateRef.set newState

    -- 5. Patch K8s Service selectors for failover
    ensureServiceRouting newState crName ns
  else
    -- 5b. Ensure service routing even when no failover (idempotent)
    ensureServiceRouting state crName ns

  -- 6. Update ConfigMap for observability
  let currentState ← stateRef.get
  updateObservabilityConfigMap currentState crName ns

  -- 7. Detect and restart lagging/zombie pods
  detectAndRestartLaggingPods currentState pods ns

-- ===========================================================================
-- Entry Point
-- ===========================================================================

/-- Main entry point. -/
def main (args : List String) : IO Unit := do
  let (ns, port, interval) := parseArgs args

  IO.eprintln s!"[flare-operator] starting (namespace={ns}, port={port}, interval={interval}s)"

  -- Discover FlareCluster CRs
  let crName ← do
    match ← listFlareClusters ns with
    | .error e =>
      IO.eprintln s!"[flare-operator] warning: could not list FlareClusters: {e}"
      pure "flare"
    | .ok [] =>
      IO.eprintln s!"[flare-operator] no FlareCluster CR found, using default name 'flare'"
      pure "flare"
    | .ok ((name, _) :: _) =>
      IO.eprintln s!"[flare-operator] managing FlareCluster '{name}'"
      pure name

  -- Initialize shared state
  let stateRef ← IO.mkRef FlareClusterState.default
  let crdRef ← IO.mkRef ({
    metadata := { name := some crName, «namespace» := some ns }
    spec := { partitions := 1, replicas := 1 }
  } : FlareClusterView)

  -- Start TCP server in background (using Server.TcpServer)
  let _ ← IO.asTask (prio := .default) do
    try
      startServerFromRefs port stateRef crdRef
    catch e =>
      IO.eprintln s!"[flare-operator] TCP server error: {e}"

  -- Reconcile loop (foreground)
  while true do
    try
      reconcileOnce stateRef crdRef crName ns
    catch e =>
      IO.eprintln s!"[flare-operator] reconcile error: {e}"
    IO.sleep (interval * 1000).toUInt32

end FlareOperator

def main (args : List String) : IO Unit :=
  FlareOperator.main args
