/-
  GlobalModel.lean - Complete distributed system model

  Models the entire Flare cluster as a formal state machine:
  - Operator state (Reconciler)
  - Multiple FlaredNode states
  - Network message queues (asynchronous communication)
  - System-wide step function for simulation and verification
-/

import FlareOperator.StateMachine.Reconciler
import FlareOperator.StateMachine.FlaredNode
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol

namespace FlareOperator.StateMachine.GlobalModel

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.StateMachine.FlaredNode
open FlareOperator.K8sReconciler (assignProxiesPure promoteMasterlessPartitions handleFailoverWithPromotion detectDeadNodesPure)

/-! ## Network Messages -/

/-- Messages sent from Operator to FlaredNodes -/
inductive OperatorToNodeMsg where
  | NodeSync (version : Nat) (nodes : List FlareNode)
  deriving Repr, BEq

/-- Messages sent from FlaredNodes to Operator -/
inductive NodeToOperatorMsg where
  | NodeAdd (serverName : String) (serverPort : Nat)
  | NodeState (serverName : String) (serverPort : Nat) (state : FlareState)
  deriving Repr, BEq

/-! ## Global System State -/

structure GlobalState where
  /-- Operator's view of the cluster -/
  operatorState : FlareClusterState

  /-- CRD specification -/
  crdSpec : FlareClusterView

  /-- Individual flared node states (indexed by "name:port") -/
  nodeStates : List (String × FlaredState)

  /-- Messages in flight from Operator to Nodes -/
  opToNodeQueue : List (String × OperatorToNodeMsg)  -- (target node key, message)

  /-- Messages in flight from Nodes to Operator -/
  nodeToOpQueue : List NodeToOperatorMsg

  /-- Model parameter: is the truncate-before-full-dump GATED (slave role +
      reachable source), as the fixed flared implements? Setting this false
      models the recalled ungated version — used to prove the gate is what
      keeps `activeMasterHoldsData` from breaking (the truncate-last-copy
      bug as a theorem). -/
  gateTruncate : Bool := true

  deriving Repr

/-! ## Helper Functions -/

/-- Find a node's internal state by key -/
def findNodeState (states : List (String × FlaredState)) (key : String) : Option FlaredState :=
  states.find? (fun (k, _) => k == key) |>.map Prod.snd

/-- Update a node's internal state -/
def updateNodeState (states : List (String × FlaredState)) (key : String) (newState : FlaredState) : List (String × FlaredState) :=
  states.map fun (k, s) => if k == key then (k, newState) else (k, s)

/-- Convert FlaredOutput to NodeToOperatorMsg -/
def flaredOutputToMsg (nodeName : String) (nodePort : Nat) (output : FlaredOutput) : Option NodeToOperatorMsg :=
  match output with
  | .None => none
  | .SendNodeState state => some (.NodeState nodeName nodePort state)

/-! ## Global Step Function -/

/-- Process one step of the distributed system -/
inductive GlobalStep where
  /-- Operator processes a message from a node -/
  | OperatorProcessMsg
  /-- A specific node processes a message from the operator -/
  | NodeProcessMsg (nodeKey : String)
  /-- Operator performs reconciliation (assigns Proxies, broadcasts topology) -/
  | OperatorReconcile
  /-- A node completes its reconstruction -/
  | NodeReconstructionComplete (nodeKey : String)
  /-- A node's pod dies, and the operator's dead-node detection + failover
      run (mirrors the AfterDetectDead → AfterHandleFailover FSM steps) -/
  | NodeDie (nodeKey : String)
  /-- A client write commits on an Active master: the master and its
      partition's Active slaves now hold the data (flare replicates writes
      to live replicas synchronously via op forwarding). -/
  | MasterCommitsData (nodeKey : String)
  deriving Repr

def stepGlobal (g : GlobalState) (step : GlobalStep) : GlobalState :=
  match step with
  | .OperatorProcessMsg =>
    match g.nodeToOpQueue with
    | [] => g  -- No messages to process
    | msg :: rest =>
      match msg with
      | .NodeAdd serverName serverPort =>
        let event := FlareEvent.NodeAdd serverName serverPort
        let oldVersion := g.operatorState.nodeMapVersion
        let (newOpState, _) := reconcileStep g.operatorState g.crdSpec event

        -- If topology changed (version incremented), enqueue broadcasts to all nodes
        let newQueue := if newOpState.nodeMapVersion > oldVersion then
          let nodes := newOpState.getNodes
          let version := newOpState.nodeMapVersion
          g.nodeStates.foldl (fun acc (nodeKey, _) =>
            acc ++ [(nodeKey, .NodeSync version nodes)]
          ) g.opToNodeQueue
        else
          g.opToNodeQueue

        { g with
          operatorState := newOpState,
          nodeToOpQueue := rest,
          opToNodeQueue := newQueue }

      | .NodeState serverName serverPort state =>
        let event := FlareEvent.NodeState serverName serverPort state
        let oldVersion := g.operatorState.nodeMapVersion
        let (newOpState, _) := reconcileStep g.operatorState g.crdSpec event

        -- If topology changed, enqueue broadcasts to all nodes
        let newQueue := if newOpState.nodeMapVersion > oldVersion then
          let nodes := newOpState.getNodes
          let version := newOpState.nodeMapVersion
          g.nodeStates.foldl (fun acc (nodeKey, _) =>
            acc ++ [(nodeKey, .NodeSync version nodes)]
          ) g.opToNodeQueue
        else
          g.opToNodeQueue

        { g with
          operatorState := newOpState,
          nodeToOpQueue := rest,
          opToNodeQueue := newQueue }

  | .NodeProcessMsg nodeKey =>
    -- Find messages for this node
    let (targetMsgs, otherMsgs) := g.opToNodeQueue.partition (fun (k, _) => k == nodeKey)

    match targetMsgs.head? with
    | none => g  -- No message for this node
    | some (_, msg) =>
      match findNodeState g.nodeStates nodeKey with
      | none => g  -- Node not found
      | some nodeState =>
        match msg with
        | .NodeSync version nodes =>
          let input := FlaredInput.ReceiveNodeSync version nodes
          let (newNodeState, output) := FlaredNode.step nodeState input

          -- Data semantics of reconstruction START (mirrors flared's
          -- truncate-before-full-dump): when this sync begins a
          -- reconstruction, local data is truncated ONLY under the gate —
          -- target role is Slave AND the partition's master (per the
          -- broadcast) is a live node. Ungated (gateTruncate = false, the
          -- recalled buggy version) truncates unconditionally.
          let startedReconstruction :=
            newNodeState.isReconstructing && !nodeState.isReconstructing
          let newNodeState :=
            if startedReconstruction then
              let myEntry := nodes.find? (fun n =>
                FlareClusterState.toNodeKey n.serverName n.serverPort == nodeKey)
              let sourceAlive : Bool :=
                match myEntry with
                | none => false
                | some me =>
                  nodes.any (fun n =>
                    n.role == FlareRole.Master && n.partition == me.partition
                      && (let k := FlareClusterState.toNodeKey n.serverName n.serverPort
                          k != nodeKey && (findNodeState g.nodeStates k).isSome))
              let truncates :=
                if g.gateTruncate then
                  newNodeState.internalRole == FlareRole.Slave && sourceAlive
                else
                  true
              if truncates then { newNodeState with holdsData := false }
              else newNodeState
            else newNodeState

          -- Update node state
          let newNodeStates := updateNodeState g.nodeStates nodeKey newNodeState

          -- Enqueue output message if any
          let newNodeToOpQueue := match flaredOutputToMsg nodeState.name nodeState.port output with
            | some outMsg => g.nodeToOpQueue ++ [outMsg]
            | none => g.nodeToOpQueue

          { g with
            nodeStates := newNodeStates,
            opToNodeQueue := targetMsgs.tail ++ otherMsgs,
            nodeToOpQueue := newNodeToOpQueue }

  | .OperatorReconcile =>
    -- Role assignment for unassigned proxies, using the SAME function the
    -- production FSM runs in its AfterAssignRoles step (assignProxiesPure →
    -- autoAssign). Previously this called `reconcileStep .Ping`, which is a
    -- no-op — meaning the model's "reconcile" never assigned any role and
    -- the scenario proofs only ever saw the single P0 master created by the
    -- NodeAdd fast path.
    let oldVersion := g.operatorState.nodeMapVersion
    let assigned := assignProxiesPure g.operatorState g.crdSpec (g.nodeStates.map Prod.fst)
    -- Same order as the production FSM's AfterAssignRoles: proxy
    -- assignment, then the masterless-partition refill (total restarts
    -- re-register replicas as Slave/Prepare, which autoAssign never touches).
    let promoted := promoteMasterlessPartitions assigned g.crdSpec (g.nodeStates.map Prod.fst)
    -- Zone repair runs in the same pipeline position as production. The
    -- model carries no topology (zones = []), which makes it a proven
    -- no-op here; the zone-repair scenario theorems exercise the pure
    -- functions directly with concrete zone maps.
    let newOpState := match FlareOperator.Reconciler.findZoneRepairSwap promoted g.crdSpec.spec.partitions [] with
      | some (sKey, dKey) => FlareOperator.Reconciler.applyZoneRepairSwap promoted sKey dKey
      | none => promoted

    let newQueue := if newOpState.nodeMapVersion > oldVersion then
      let nodes := newOpState.getNodes
      let version := newOpState.nodeMapVersion
      g.nodeStates.foldl (fun acc (nodeKey, _) =>
        acc ++ [(nodeKey, .NodeSync version nodes)]
      ) g.opToNodeQueue
    else
      g.opToNodeQueue

    { g with
      operatorState := newOpState,
      opToNodeQueue := newQueue }

  | .NodeReconstructionComplete nodeKey =>
    match findNodeState g.nodeStates nodeKey with
    | none => g
    | some nodeState =>
      let input := FlaredInput.ReconstructionComplete
      let (newNodeState, output) := FlaredNode.step nodeState input

      -- Data semantics of reconstruction COMPLETION: the node now holds the
      -- data iff it copied from a live source that held it (the partition's
      -- master in the operator's view). Otherwise its holdsData is
      -- whatever the (gated) truncate left it.
      let newNodeState :=
        if nodeState.isReconstructing then
          let myPartition := (g.operatorState.nodeMap.lookup nodeKey).map (·.partition)
          let sourceHolds : Bool :=
            match myPartition with
            | none => false
            | some p =>
              g.operatorState.nodeMap.any (fun kv =>
                kv.2.role == FlareRole.Master && kv.2.partition == p
                  && kv.1 != nodeKey
                  && (((findNodeState g.nodeStates kv.1).map (·.holdsData)).getD false))
          if sourceHolds then { newNodeState with holdsData := true }
          else newNodeState
        else newNodeState

      let newNodeStates := updateNodeState g.nodeStates nodeKey newNodeState

      let newNodeToOpQueue := match flaredOutputToMsg nodeState.name nodeState.port output with
        | some outMsg => g.nodeToOpQueue ++ [outMsg]
        | none => g.nodeToOpQueue

      { g with
        nodeStates := newNodeStates,
        nodeToOpQueue := newNodeToOpQueue }

  | .NodeDie nodeKey =>
    -- The pod disappears from the live pod list; the operator then runs the
    -- SAME dead-node detection and failover functions as the production FSM
    -- (detectDeadNodesPure → handleFailoverWithPromotion on the rebuilt
    -- partition map, cf. flareReconcileCore's AfterHandleFailover step).
    -- A dead Master's live Slave is promoted to Master/Active so the
    -- partition's data survives.
    let newNodeStates := g.nodeStates.filter (fun kv => kv.1 != nodeKey)
    let livePodKeys := newNodeStates.map Prod.fst
    let deadKeys := detectDeadNodesPure g.operatorState livePodKeys
    let oldVersion := g.operatorState.nodeMapVersion
    let newOpState :=
      handleFailoverWithPromotion g.operatorState.rebuildPartitionMap deadKeys

    let newQueue := if newOpState.nodeMapVersion > oldVersion then
      let nodes := newOpState.getNodes
      let version := newOpState.nodeMapVersion
      newNodeStates.foldl (fun acc (nodeKey, _) =>
        acc ++ [(nodeKey, .NodeSync version nodes)]
      ) g.opToNodeQueue
    else
      g.opToNodeQueue

    { g with
      operatorState := newOpState,
      nodeStates := newNodeStates,
      opToNodeQueue := newQueue }

  | .MasterCommitsData nodeKey =>
    -- A committed write lands on the Active master and is replicated to the
    -- partition's Active slaves (flare forwards writes to live replicas).
    match g.operatorState.nodeMap.lookup nodeKey with
    | none => g
    | some node =>
      if node.role == FlareRole.Master && node.state == FlareState.Active then
        let markHolder := fun (states : List (String × FlaredNode.FlaredState)) key =>
          states.map (fun kv =>
            if kv.1 == key then (kv.1, { kv.2 with holdsData := true }) else kv)
        let replicaKeys := g.operatorState.nodeMap.filterMap (fun kv =>
          if kv.2.partition == node.partition && kv.2.state == FlareState.Active
             && (kv.2.role == FlareRole.Master || kv.2.role == FlareRole.Slave) then
            some kv.1
          else none)
        { g with nodeStates := replicaKeys.foldl markHolder g.nodeStates }
      else g

/-! ## Data-preservation invariant -/

/-- THE invariant the truncate bugs violated while "at most one master"
    held perfectly: every ACTIVE master's pod is alive and holds its
    partition's committed data. An empty or dead Active master is exactly
    the pvc-data-survival failure. -/
def activeMasterHoldsData (g : GlobalState) : Bool :=
  g.operatorState.nodeMap.all fun kv =>
    !(kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active)
      || (((findNodeState g.nodeStates kv.1).map (·.holdsData)).getD false)

/-! ## Multi-Step Execution -/

/-- Execute a sequence of steps -/
def stepMany (g : GlobalState) (steps : List GlobalStep) : GlobalState :=
  steps.foldl stepGlobal g

/-! ## Scenario Helpers -/

/-- Initialize a fresh cluster with N nodes as Proxies -/
def initCluster (crd : FlareClusterView) (nodeNames : List String) : GlobalState :=
  let operatorState := FlareClusterState.default

  -- Create initial node states (all Proxy, Active)
  let nodeStates := nodeNames.map fun name =>
    let key := FlareClusterState.toNodeKey name 11211
    let nodeState : FlaredState := {
      name := name,
      port := 11211,
      internalRole := FlareRole.Proxy,
      internalState := FlareState.Active,
      localNodeMapVersion := 0,
      isReconstructing := false
    }
    (key, nodeState)

  -- Enqueue NodeAdd messages for all nodes
  let nodeToOpQueue := nodeNames.map fun name =>
    NodeToOperatorMsg.NodeAdd name 11211

  { operatorState := operatorState,
    crdSpec := crd,
    nodeStates := nodeStates,
    opToNodeQueue := [],
    nodeToOpQueue := nodeToOpQueue }

end FlareOperator.StateMachine.GlobalModel
