/-
  Reconciler.lean - Pure reconcile step for the Flare operator
  Core pure function: reconcileStep processes FlareEvents against FlareClusterState
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol

namespace FlareOperator.Reconciler

open FlareOperator.K8s
open FlareOperator.Flare

/-! ## Metric functions (for metric reduction proofs) -/

/-- Metric: does any node in nodeMap have role=Master for the given partition?
    Uses `decide` (not BEq) for clean Prop↔Bool conversion in proofs. -/
def hasMasterForPartition (state : FlareClusterState) (pIdx : Nat) : Bool :=
  state.nodeMap.any (fun (_, n) => decide (n.role = FlareRole.Master ∧ n.partition = Int.ofNat pIdx))

/-- Check if partition 0 has an Active master (cluster is operational). -/
def hasActiveMasterP0 (state : FlareClusterState) : Bool :=
  state.nodeMap.any (fun (_, n) =>
    decide (n.role = FlareRole.Master ∧ n.partition = 0 ∧ n.state = FlareState.Active))

/-- Metric: count of slaves for a given partition in nodeMap. -/
def slaveCountForPartition (state : FlareClusterState) (pIdx : Nat) : Nat :=
  (state.nodeMap.filter (fun (_, n) => n.role == FlareRole.Slave && n.partition == Int.ofNat pIdx)).length

/-- Check if a partition is currently reconstructing (has any node in Prepare state).
    Used for throttling to prevent thundering herd: only allow one reconstruction per partition.

    Throttled Reconciliation Pattern:
    - When mass failures occur (e.g., AZ failure), multiple nodes restart as Proxy simultaneously
    - Without throttling: all Proxies promoted to Slave→Prepare at once → synchronization storm
    - With throttling: only one Slave promoted at a time, others wait in Proxy pool
    - Once first node completes (Prepare→Active), next Proxy can be promoted

    This implements "Proxy Pool" pattern for controlled, serialized reconstruction. -/
def isPartitionReconstructing (state : FlareClusterState) (pIdx : Nat) : Bool :=
  state.nodeMap.any (fun (_, n) =>
    decide (n.partition == Int.ofNat pIdx ∧ n.state == FlareState.Prepare))

/-! ## Auto-assignment logic (metric reduction: decisions based on nodeMap) -/

/-- Auxiliary recursive search for partition needing a Master.
    Top-level def (not let rec) for easier inductive proofs. -/
def findPartitionNeedingMasterAux (state : FlareClusterState) (numPartitions : Nat)
    (i : Nat) (fuel : Nat) : Option Nat :=
  match fuel with
  | 0 => none
  | fuel + 1 =>
    if i >= numPartitions then none
    else if hasMasterForPartition state i then
      findPartitionNeedingMasterAux state numPartitions (i + 1) fuel
    else some i

/-- Find the first partition index (0..numPartitions-1) that needs a Master.
    Uses metric reduction: checks nodeMap directly instead of partitionMap. -/
def findPartitionNeedingMaster (state : FlareClusterState) (numPartitions : Nat) : Option Nat :=
  findPartitionNeedingMasterAux state numPartitions 0 numPartitions

/-- Spec lemma: findPartitionNeedingMasterAux returns a partition with no existing master.
    This is the key metric reduction lemma that enables the atMostOneMaster proof. -/
theorem findPartitionNeedingMasterAux_spec (state : FlareClusterState) (n i fuel pIdx : Nat) :
    findPartitionNeedingMasterAux state n i fuel = some pIdx →
    hasMasterForPartition state pIdx = false := by
  induction fuel generalizing i with
  | zero => simp [findPartitionNeedingMasterAux]
  | succ fuel ih =>
    unfold findPartitionNeedingMasterAux
    split
    · simp
    · split
      · intro h; exact ih (i + 1) h
      · intro h; injection h with h; subst h; next h_neg => simpa using h_neg

/-- Spec lemma for the top-level findPartitionNeedingMaster. -/
theorem findPartitionNeedingMaster_spec (state : FlareClusterState) (n pIdx : Nat) :
    findPartitionNeedingMaster state n = some pIdx →
    hasMasterForPartition state pIdx = false := by
  unfold findPartitionNeedingMaster
  exact findPartitionNeedingMasterAux_spec state n 0 n pIdx

/-- Key corollary: no node in nodeMap is Master for the returned partition.
    Converts the Bool metric to a Prop-level statement via decide_eq_true. -/
theorem findPartitionNeedingMaster_noMaster (state : FlareClusterState) (n pIdx : Nat) :
    findPartitionNeedingMaster state n = some pIdx →
    ∀ (k : String) (node : FlareNode),
      (k, node) ∈ state.nodeMap → node.role = FlareRole.Master →
      node.partition ≠ Int.ofNat pIdx := by
  intro h_find k node h_mem h_role h_part
  have h_no := findPartitionNeedingMaster_spec state n pIdx h_find
  -- h_no : hasMasterForPartition state pIdx = false
  -- But (k, node) witnesses hasMasterForPartition = true → contradiction
  have h_yes : hasMasterForPartition state pIdx = true := by
    unfold hasMasterForPartition
    rw [List.any_eq_true]
    exact ⟨(k, node), h_mem, decide_eq_true ⟨h_role, h_part⟩⟩
  simp [h_yes] at h_no

/-- Auxiliary recursive search for partition needing a Slave. -/
def findPartitionNeedingSlaveAux (state : FlareClusterState) (numPartitions : Nat)
    (maxSlaves : Nat) (i : Nat) (fuel : Nat) : Option Nat :=
  match fuel with
  | 0 => none
  | fuel + 1 =>
    if i >= numPartitions then none
    -- Throttling: only assign if partition needs slaves AND no ongoing reconstruction
    else if slaveCountForPartition state i < maxSlaves
         && !isPartitionReconstructing state i then
      some i
    else findPartitionNeedingSlaveAux state numPartitions maxSlaves (i + 1) fuel

/-- Find the first partition index that needs more Slaves (has fewer than replicas-1). -/
def findPartitionNeedingSlave (state : FlareClusterState) (numPartitions : Nat) (maxSlaves : Nat) : Option Nat :=
  findPartitionNeedingSlaveAux state numPartitions maxSlaves 0 numPartitions

/-- Auto-assign a proxy node to the first partition that needs filling.
    Returns updated state and the assigned role/partition.
    First clears any stale entry for this nodeKey so re-registering nodes
    don't block their own partition from being filled. -/
def autoAssign (state : FlareClusterState) (crd : FlareClusterView) (nodeKey : String) (node : FlareNode)
    : FlareClusterState × FlareNode :=
  let numPartitions := crd.spec.partitions
  let maxSlaves := if crd.spec.replicas > 1 then crd.spec.replicas - 1 else 0
  -- Clear stale entry for this node before checking partition needs.
  -- A re-registering node enters as Proxy, so the old Master/Slave entry
  -- must not block the partition from being refilled.
  let cleanState := state.addNode nodeKey node  -- Replace old entry with Proxy
  let cleanState := cleanState.rebuildPartitionMap  -- Rebuild so hasMasterForPartition is accurate
  -- Try Master first
  match findPartitionNeedingMaster cleanState numPartitions with
  | some pIdx =>
    -- Mimic C++ flarei state assignment logic (cluster.cc:1010):
    -- Partition 0: always Active (special case, no reconstruction needed)
    -- Partition 1+: always Prepare (must reconstruct from P0 before becoming Active)
    -- C++ flared nodes will send "node state ready" after reconstruction completes
    let masterState := if pIdx == 0 then FlareState.Active else FlareState.Prepare
    let newNode := { node with role := FlareRole.Master, state := masterState, partition := Int.ofNat pIdx }
    let part := (cleanState.lookupPartition pIdx).getD {}
    let newPart := { part with master := some nodeKey }
    let newState := (cleanState.addNode nodeKey newNode).setPartition pIdx newPart
    (newState, newNode)
  | none =>
    -- Try Slave (enters Prepare state — reconstruction needed before Active)
    match findPartitionNeedingSlave cleanState numPartitions maxSlaves with
    | some pIdx =>
      let newNode := { node with role := FlareRole.Slave, state := FlareState.Prepare, partition := Int.ofNat pIdx, balance := 0 }
      let part := (cleanState.lookupPartition pIdx).getD {}
      let newPart := { part with slaves := part.slaves ++ [nodeKey] }
      let newState := (cleanState.addNode nodeKey newNode).setPartition pIdx newPart
      (newState, newNode)
    | none =>
      -- Stay as Proxy
      (cleanState, node)

/-! ## Core reconcile step -/

/-- Pure reconcile step: process a FlareEvent against the current state. -/
def reconcileStep (state : FlareClusterState) (crd : FlareClusterView)
    (event : FlareEvent) : FlareClusterState × FlareResponse :=
  -- NOTE: partitionSize must remain 1024 (max ring size for consistent hashing),
  -- NOT crd.spec.partitions (current partition count). C++ flared allocates
  -- _map array using partition-size, then indexes it with actual partition count.
  -- Setting partitionSize=2 causes out-of-bounds access when _map[2] is read!
  match event with
  | .Ping =>
    (state, .OK)
  | .Meta =>
    (state, .End [
      s!"META partition-size {state.partitionSize}",
      s!"META key-hash-algorithm jenkins",
      s!"META partition-type modular",
      s!"META partition-modular-hint 1",
      s!"META partition-modular-virtual 4096"
    ])
  | .Stats =>
    (state, .End [s!"STAT node_count {state.nodeMap.length}"])
  | .Version =>
    (state, .End ["VERSION flare-operator 1.0.0"])
  | .Quit =>
    (state, .CloseConnection)
  | .NodeAdd serverName serverPort =>
    let nodeKey := FlareClusterState.toNodeKey serverName serverPort
    -- Register as Proxy initially
    let newNode : FlareNode := {
      serverName := serverName
      serverPort := serverPort
      role := FlareRole.Proxy
      state := FlareState.Active
      partition := -1
      balance := 100
      threadType := 16
    }
    -- SPECIAL CASE: P0 Master must be assigned immediately to avoid reconstruction.
    -- P0 is the source of truth - it should never witness a role transition and
    -- should never run reconstruction. P1+ Masters are assigned later via reconcile
    -- loop, which triggers Proxy→Master transition, which triggers reconstruction.
    let numPartitions := crd.spec.partitions
    let p0 := state.lookupPartition 0
    let needsP0Master := match p0 with | some part => part.master.isNone | none => true
    if needsP0Master && numPartitions > 0 then
      -- Assign as P0 Master immediately - no role transition, no reconstruction
      let (newState, assignedNode) := autoAssign state crd nodeKey newNode
      if assignedNode.role == FlareRole.Master && assignedNode.partition == 0 then
        -- Successfully assigned as P0 Master - return immediately
        let nodeList := newState.getNodes
        let lines := nodeList.map serializeNode
        (newState, .End (lines.map String.trim))
      else
        -- Not assigned as P0 Master - register as Proxy for later assignment
        let newState := state.addNode nodeKey newNode
        let nodeList := newState.getNodes
        let lines := nodeList.map serializeNode
        (newState, .End (lines.map String.trim))
    else
      -- Not the first node or P0 already has master - register as Proxy
      let newState := state.addNode nodeKey newNode
      let nodeList := newState.getNodes
      let lines := nodeList.map serializeNode
      (newState, .End (lines.map String.trim))
  | .NodeSync _ =>
    let nodeList := state.getNodes
    let lines := nodeList.map serializeNode
    (state, .End (lines.map String.trim))
  | .NodeState serverName serverPort newState =>
    let nodeKey := FlareClusterState.toNodeKey serverName serverPort
    match state.lookupNode nodeKey with
    | none =>
      (state, .ServerError s!"node state: unknown node {nodeKey}")
    | some node =>
      -- Allow Prepare → Active (slaves) and Prepare → Ready (masters)
      -- Auto-promote Ready to Active so partitions immediately become usable
      if node.state == FlareState.Prepare && (newState == FlareState.Active || newState == FlareState.Ready) then
        let updatedNode := { node with state := FlareState.Active }
        let newClusterState := state.addNode nodeKey updatedNode
        (newClusterState, .OK)
      else
        (state, .ServerError s!"node state: transition {node.state.toNat}→{newState.toNat} not allowed")
  | .NodeRemove _ _ =>
    (state, .ServerError "node removal is managed by Kubernetes")
  | .MutationAttempt _ =>
    (state, .ServerError "manual mutations are disabled in K8s mode")
  | .ParseError raw =>
    (state, .ServerError s!"parse error: {raw}")

/-! ## #eval tests -/

private def testCrd : FlareClusterView := {
  metadata := { name := some "test-cluster", «namespace» := some "default" }
  spec := { partitions := 2, replicas := 2 }
}

-- Ping returns OK, state unchanged
#eval do
  let (s', resp) := reconcileStep .default testCrd .Ping
  return (s'.nodeMapVersion, resp)

-- NodeAdd registers and auto-assigns
#eval do
  let (s1, _) := reconcileStep .default testCrd (.NodeAdd "host1" 12121)
  let (s2, _) := reconcileStep s1 testCrd (.NodeAdd "host2" 12121)
  return (s2.nodeMap.length, s2.partitionMap.length)

-- MutationAttempt never changes state
#eval do
  let s0 : FlareClusterState := .default
  let (s1, resp) := reconcileStep s0 testCrd (.MutationAttempt "node role host1 1234 master 100 0")
  return (s1.nodeMapVersion == s0.nodeMapVersion, resp)

-- META must report partition-size = 2 (from CRD), NOT 1024
#eval do
  let (_, resp) := reconcileStep .default testCrd .Meta
  return resp

-- NODE SYNC: register 4 nodes, verify partition assignment and balance
#eval do
  let (s1, _) := reconcileStep .default testCrd (.NodeAdd "host-a" 12121)
  let (s2, _) := reconcileStep s1 testCrd (.NodeAdd "host-b" 12121)
  let (s3, _) := reconcileStep s2 testCrd (.NodeAdd "host-c" 12121)
  let (s4, resp) := reconcileStep s3 testCrd (.NodeAdd "host-d" 12121)
  -- Print NODE SYNC to verify: partition 0,1 have masters, balance=100, partitionSize=2
  return (s4.partitionSize, resp)

end FlareOperator.Reconciler
