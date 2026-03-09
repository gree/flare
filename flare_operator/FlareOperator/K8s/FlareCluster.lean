/-
  FlareOperator - Flare Cluster Domain Types
  Based on C++ src/lib/cluster.h (role, state, node, partition)
-/

import FlareOperator.K8s.Types

namespace FlareOperator.K8s

/-! ## Flare Role (wire: master=0, slave=1, proxy=2) -/

inductive FlareRole where
  | Master
  | Slave
  | Proxy
  deriving Repr, BEq, DecidableEq

def FlareRole.toNat : FlareRole → Nat
  | .Master => 0
  | .Slave => 1
  | .Proxy => 2

def FlareRole.fromNat : Nat → Option FlareRole
  | 0 => some .Master
  | 1 => some .Slave
  | 2 => some .Proxy
  | _ => none

/-! ## Flare State (wire: active=0, prepare=1, down=2, ready=3) -/

inductive FlareState where
  | Active
  | Prepare
  | Down
  | Ready
  deriving Repr, BEq, DecidableEq

def FlareState.toNat : FlareState → Nat
  | .Active => 0
  | .Prepare => 1
  | .Down => 2
  | .Ready => 3

def FlareState.fromNat : Nat → Option FlareState
  | 0 => some .Active
  | 1 => some .Prepare
  | 2 => some .Down
  | 3 => some .Ready
  | _ => none

/-! ## Flare Node -/

structure FlareNode where
  serverName : String
  serverPort : Nat
  role : FlareRole
  state : FlareState
  partition : Int  -- -1 = unassigned proxy
  balance : Nat := 100
  threadType : Nat := 16
  deriving Repr, BEq

/-! ## Flare Cluster CRD Spec -/

structure FlareClusterSpecView where
  partitions : Nat := 1
  replicas : Nat := 1  -- 1 Master + (N-1) Slaves per partition
  deriving Repr

structure FlareClusterView where
  metadata : ObjectMetaView
  spec : FlareClusterSpecView
  deriving Repr

/-! ## Partition State -/

structure FlarePartition where
  master : Option String := none
  slaves : List String := []
  deriving Repr, BEq

/-! ## Cluster State -/

structure FlareClusterState where
  nodeMap : List (String × FlareNode) := []
  partitionMap : List (Nat × FlarePartition) := []
  nodeMapVersion : Nat := 0
  partitionSize : Nat := 1024
  keyHashAlgorithm : String := "simple"
  deriving Repr

namespace FlareClusterState

def default : FlareClusterState := {}

def toNodeKey (name : String) (port : Nat) : String :=
  name ++ ":" ++ toString port

def lookupNode (state : FlareClusterState) (key : String) : Option FlareNode :=
  state.nodeMap.lookup key

def addNode (state : FlareClusterState) (key : String) (node : FlareNode) : FlareClusterState :=
  let filtered := state.nodeMap.filter (·.1 != key)
  { state with nodeMap := (key, node) :: filtered, nodeMapVersion := state.nodeMapVersion + 1 }

def removeNode (state : FlareClusterState) (key : String) : FlareClusterState :=
  { state with nodeMap := state.nodeMap.filter (·.1 != key), nodeMapVersion := state.nodeMapVersion + 1 }

def getNodes (state : FlareClusterState) : List FlareNode :=
  state.nodeMap.map Prod.snd

def lookupPartition (state : FlareClusterState) (idx : Nat) : Option FlarePartition :=
  state.partitionMap.lookup idx

def setPartition (state : FlareClusterState) (idx : Nat) (p : FlarePartition) : FlareClusterState :=
  let filtered := state.partitionMap.filter (·.1 != idx)
  { state with partitionMap := (idx, p) :: filtered }

end FlareClusterState

end FlareOperator.K8s
