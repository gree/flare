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
import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol

namespace FlareOperator.StateMachine.GlobalModel

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.StateMachine.FlaredNode

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
    -- Trigger reconciliation without external event
    let oldVersion := g.operatorState.nodeMapVersion
    let (newOpState, _) := reconcileStep g.operatorState g.crdSpec .Ping

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

      let newNodeStates := updateNodeState g.nodeStates nodeKey newNodeState

      let newNodeToOpQueue := match flaredOutputToMsg nodeState.name nodeState.port output with
        | some outMsg => g.nodeToOpQueue ++ [outMsg]
        | none => g.nodeToOpQueue

      { g with
        nodeStates := newNodeStates,
        nodeToOpQueue := newNodeToOpQueue }

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
