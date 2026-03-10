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

/-- Parse a node key "host:port" into (host, port). -/
def fromNodeKey (key : String) : Option (String × Nat) :=
  match key.splitOn ":" with
  | [name, portStr] => portStr.toNat?.map fun port => (name, port)
  | _ => none

private def stripPrefix (s pfx : String) : Option String :=
  if s.startsWith pfx then some (s.drop pfx.length) else none

private def parseIntStr (s : String) : Option Int :=
  if s.startsWith "-" then
    (s.drop 1).toNat?.map fun n => -(Int.ofNat n)
  else
    s.toNat?.map Int.ofNat

/-- Parse a single serialized node-map line:
    "host:port role=R state=S partition=P" → (key, FlareNode) -/
def parseNodeMapLine (line : String) : Option (String × FlareNode) :=
  match line.trim.splitOn " " with
  | [key, roleStr, stateStr, partStr] => do
    let roleVal ← stripPrefix roleStr "role=" >>= fun (s : String) => s.toNat? >>= FlareRole.fromNat
    let stateVal ← stripPrefix stateStr "state=" >>= fun (s : String) => s.toNat? >>= FlareState.fromNat
    let partVal ← stripPrefix partStr "partition=" >>= parseIntStr
    let (host, port) ← fromNodeKey key
    return (key, { serverName := host, serverPort := port, role := roleVal, state := stateVal, partition := partVal })
  | _ => none

/-- Rebuild FlareClusterState from serialized ConfigMap data. -/
def fromNodeMapData (data : String) : FlareClusterState :=
  let lines := data.splitOn "\n" |>.filter (· != "")
  let nodes := lines.filterMap parseNodeMapLine
  { FlareClusterState.default with nodeMap := nodes }

/-- Rebuild partitionMap deterministically from nodeMap.
    Scans all nodes and groups masters/slaves by partition index. -/
def rebuildPartitionMap (state : FlareClusterState) : FlareClusterState :=
  let partMap := state.nodeMap.foldl (fun acc entry =>
    let (key, node) := entry
    if node.partition < 0 then acc
    else
      let idx := node.partition.toNat
      let current := acc.lookup idx |>.getD { master := none, slaves := [] }
      let updated := match node.role with
        | .Master => { current with master := some key }
        | .Slave  => { current with slaves := current.slaves ++ [key] }
        | .Proxy  => current
      acc.filter (fun p => p.1 != idx) ++ [(idx, updated)]
  ) ([] : List (Nat × FlarePartition))
  { state with partitionMap := partMap }

end FlareClusterState

end FlareOperator.K8s
