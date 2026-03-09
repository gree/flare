/-
  Main.lean - Flare Operator entry point
  Operator-as-Index: replaces flarei with a K8s-native operator
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler
import FlareOperator.Kubectl
import FlareOperator.TcpServer

namespace FlareOperator

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.Kubectl
open FlareOperator.TcpServer

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

/-- Detect dead nodes: nodes registered in state but not in live pod list. -/
private def detectDeadNodes (state : FlareClusterState) (livePods : List (String × String × Nat))
    : List String :=
  let liveKeys := livePods.map fun (_, ip, port) => FlareClusterState.toNodeKey ip port
  state.nodeMap.filter (fun (key, _) => !liveKeys.contains key) |>.map Prod.fst

/-- Handle failover: mark dead nodes Down, promote a Slave if master died. -/
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

/-- Main reconcile loop iteration. -/
private def reconcileOnce (stateRef : IO.Ref FlareClusterState) (crdRef : IO.Ref FlareClusterView)
    (crName ns : String) : IO Unit := do
  -- 1. Fetch latest CRD spec
  match ← getFlareCluster crName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] warning: failed to fetch CRD: {e}"
  | .ok crd =>
    crdRef.set crd
  -- 2. List live pods
  let livePods ← listFlaredPods crName ns
  -- 3. Detect dead nodes
  let state ← stateRef.get
  let deadKeys := detectDeadNodes state livePods
  -- 4. Handle failover
  if !deadKeys.isEmpty then
    IO.eprintln s!"[flare-operator] detected {deadKeys.length} dead node(s): {deadKeys}"
    let newState := handleFailover state deadKeys
    stateRef.set newState
    -- 5. Patch K8s Service selectors for failover
    for (_, part) in newState.partitionMap do
      match part.master with
      | none => pure ()
      | some masterKey =>
        match newState.lookupNode masterKey with
        | none => pure ()
        | some masterNode =>
          let svcName := s!"{crName}-{masterNode.partition}"
          match ← patchServiceSelector svcName ns masterNode.serverName with
          | .error e => IO.eprintln s!"[flare-operator] warning: failed to patch service: {e}"
          | .ok () => pure ()

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

  -- Start TCP server in background
  let _ ← IO.asTask (prio := .default) do
    try
      startServer port stateRef crdRef
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
