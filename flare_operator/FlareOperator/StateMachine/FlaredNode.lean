/-
  FlaredNode.lean - Mathematical model of the C++ flared internal state machine

  Captures the precise behavior of `src/lib/cluster.cc`:
  1. Receiving `node sync` updates the local routing table.
  2. A role shift from Proxy -> Master/Slave triggers reconstruction.
  3. Completion of reconstruction triggers a `node state` command to the Operator.
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol

namespace FlareOperator.StateMachine.FlaredNode

open FlareOperator.K8s
open FlareOperator.Flare

/-! ## Internal State of a flared process -/
structure FlaredState where
  name : String
  port : Nat
  internalRole : FlareRole := FlareRole.Proxy
  internalState : FlareState := FlareState.Active
  localNodeMapVersion : Nat := 0
  isReconstructing : Bool := false
  /-- Data-preservation abstraction: does this node hold a full copy of its
      partition's committed data? Writes/replication set it, the (gated)
      truncate-before-full-dump clears it, a PVC-backed restart keeps it.
      Added after the truncate bugs showed the old spec never SAID anything
      about data — "at most one master" was fully compatible with an empty
      master. See `activeMasterHoldsData` in GlobalModel. -/
  holdsData : Bool := false
  deriving Repr, BEq

/-! ## Inputs to the flared process -/
inductive FlaredInput where
  | ReceiveNodeSync (version : Nat) (nodes : List FlareNode)
  | ReconstructionComplete
  deriving Repr

/-! ## Outputs (Actions) from the flared process to the Operator -/
inductive FlaredOutput where
  | None
  | SendNodeState (state : FlareState)
  deriving Repr, BEq

/-! ## Core Transition Logic -/
/-- Simulates `cluster::reconstruct_node` and `_shift_node_role` -/
def step (s : FlaredState) (input : FlaredInput) : FlaredState × FlaredOutput :=
  match input with
  | .ReceiveNodeSync version nodes =>
    let myKey := FlareClusterState.toNodeKey s.name s.port
    let myNewNodeOpt := nodes.find? (fun n => FlareClusterState.toNodeKey n.serverName n.serverPort == myKey)

    match myNewNodeOpt with
    | none =>
      -- Node is not in the topology map; remain unchanged
      (s, .None)
    | some myNewNode =>
      -- Detect role shift (Proxy -> Master/Slave)
      let isRoleShift := s.internalRole == FlareRole.Proxy &&
                         (myNewNode.role == FlareRole.Master || myNewNode.role == FlareRole.Slave)

      if isRoleShift then
        -- If assigned as P0 Master initially, it is instantly Active (no reconstruction)
        if myNewNode.state == FlareState.Active then
           ({ s with internalRole := myNewNode.role,
                     internalState := FlareState.Active,
                     localNodeMapVersion := version }, .None)
        else
           -- Transition to Prepare and start reconstruction thread
           ({ s with internalRole := myNewNode.role,
                     internalState := FlareState.Prepare,
                     localNodeMapVersion := version,
                     isReconstructing := true }, .None)
      else
        -- Routine topology update (no role shift)
        ({ s with localNodeMapVersion := version,
                  internalRole := myNewNode.role,
                  internalState := myNewNode.state }, .None)

  | .ReconstructionComplete =>
    if s.isReconstructing then
      -- Reconstruction finished. Shift to Active internally and notify Operator
      let newState := { s with isReconstructing := false, internalState := FlareState.Active }
      let cmd := if s.internalRole == FlareRole.Master then FlareState.Ready else FlareState.Active
      (newState, .SendNodeState cmd)
    else
      (s, .None)

end FlareOperator.StateMachine.FlaredNode
