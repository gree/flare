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
  /-- Registration epoch: bumped on every TCP (re-)registration of this key
      and NEVER serialized to the wire. Lets the FSM-commit merge tell a
      LATER registration from its own stale snapshot: without it the merge
      resurrected ghost Master/Slave roles over a pod's fresh Proxy
      re-registration every tick — the root cause of the pvc-data-survival
      DATA LOSS churn (operator log: re-adds flip to Proxy, next commit
      flips them back, M=2 S=2 P=0 forever). -/
  regEpoch : Nat := 0
  /-- Partition this key most recently held the Master role for, or -1.
      Set when a re-registration turns an ex-master into a syncing slave;
      read by the reconcile loop to pick the freshest live candidate when a
      partition has lost every master (total-partition restart). NEVER
      serialized (same policy as regEpoch): after an operator restart the
      roles themselves reload intact, so the marker only matters within the
      lifetime that witnessed the demotion. -/
  lastMasterOf : Int := -1
  deriving Repr, BEq

/-! ## Cluster Replication (Blue/Green Migration) -/

structure ClusterReplicationSpec where
  enabled : Bool := false
  serverName : String := ""
  port : Nat := 12121
  mode : String := "duplicate"  -- "duplicate" or "forward"
  concurrency : Nat := 2
  deriving Repr, BEq

/-! ## RocksDB Storage Backend Configuration

    Maps 1:1 to flared's `rocksdb-*` ini options. Fields are `Option` so an
    unset field produces no line in the generated `extra.conf`, preserving
    flared's built-in defaults. See `ROCKSDB_REPLICATION.md` for semantics. -/

structure RocksdbConfigSpec where
  /-- WAL retention time in seconds. flared: `rocksdb-wal-ttl-seconds`. -/
  walTtlSeconds : Option Nat := none
  /-- WAL size cap in megabytes. flared: `rocksdb-wal-size-limit-mb`. -/
  walSizeLimitMb : Option Nat := none
  /-- Force `sync=true` on every write for strict durability.
      flared: `rocksdb-sync-writes`. -/
  syncWrites : Option Bool := none
  /-- Consecutive resync failures before the slave self-demotes.
      flared: `rocksdb-resync-failure-threshold`. -/
  resyncFailureThreshold : Option Nat := none
  /-- Per-WriteBatch size ceiling (bytes) for WAL replication.
      flared: `rocksdb-wal-max-batch-bytes`. -/
  walMaxBatchBytes : Option Nat := none
  /-- Bandwidth cap (KB/s) for WAL-sync streaming.
      flared: `rocksdb-wal-sync-bwlimit`. -/
  walSyncBwlimit : Option Nat := none
  /-- Inter-batch delay (usec) for WAL-sync streaming.
      flared: `rocksdb-wal-sync-interval`. -/
  walSyncInterval : Option Nat := none
  /-- Bandwidth cap (KB/s) for serving a snapshot-bootstrap stream; the SENDER
      throttles. flared default is ~1/4 of a 1 Gbps link — override per
      cluster to ~1/4 of the actual node NIC. flared: `rocksdb-snapshot-bwlimit`. -/
  snapshotBwlimit : Option Nat := none
  deriving Repr, BEq

/-- True when at least one rocksdb field has been set by the user. -/
def RocksdbConfigSpec.hasAny (r : RocksdbConfigSpec) : Bool :=
  r.walTtlSeconds.isSome || r.walSizeLimitMb.isSome || r.syncWrites.isSome ||
  r.resyncFailureThreshold.isSome || r.walMaxBatchBytes.isSome ||
  r.walSyncBwlimit.isSome || r.walSyncInterval.isSome || r.snapshotBwlimit.isSome

/-- Render the rocksdb spec as `extra.conf` lines (one per set field).
    Returns an empty string when no fields are set. Lines are joined with "\n";
    the caller is responsible for joining with other sections. -/
def RocksdbConfigSpec.toExtraConf (r : RocksdbConfigSpec) : String :=
  let lines : List String := []
  let lines := match r.walTtlSeconds with
    | some n => lines ++ [s!"rocksdb-wal-ttl-seconds = {n}"]
    | none => lines
  let lines := match r.walSizeLimitMb with
    | some n => lines ++ [s!"rocksdb-wal-size-limit-mb = {n}"]
    | none => lines
  let lines := match r.syncWrites with
    | some b =>
      let v := if b then "true" else "false"
      lines ++ [s!"rocksdb-sync-writes = {v}"]
    | none => lines
  let lines := match r.resyncFailureThreshold with
    | some n => lines ++ [s!"rocksdb-resync-failure-threshold = {n}"]
    | none => lines
  let lines := match r.walMaxBatchBytes with
    | some n => lines ++ [s!"rocksdb-wal-max-batch-bytes = {n}"]
    | none => lines
  let lines := match r.walSyncBwlimit with
    | some n => lines ++ [s!"rocksdb-wal-sync-bwlimit = {n}"]
    | none => lines
  let lines := match r.walSyncInterval with
    | some n => lines ++ [s!"rocksdb-wal-sync-interval = {n}"]
    | none => lines
  let lines := match r.snapshotBwlimit with
    | some n => lines ++ [s!"rocksdb-snapshot-bwlimit = {n}"]
    | none => lines
  String.intercalate "\n" lines

inductive MigrationPhase where
  | None | Dumping | Forwarding
  deriving Repr, BEq

def MigrationPhase.toString : MigrationPhase → String
  | .None => "None"
  | .Dumping => "Dumping"
  | .Forwarding => "Forwarding"

/-! ## Circuit Breaker Configuration -/

/-- Circuit breaker configuration for AZ-level failure protection.
    Prevents automatic recovery during infrastructure failures.

    Hysteresis (tripThreshold ≠ resetThreshold) prevents flapping. -/
structure CircuitBreakerConfig where
  /-- Enable/disable circuit breaker. Default: true (enabled for production) -/
  enabled : Bool := true

  /-- Percentage of dead nodes that trips the breaker (0-100).
      Default: 50 (trip when ≥50% nodes are dead) -/
  tripThresholdPercent : Nat := 50

  /-- Percentage of healthy nodes required to auto-reset breaker (0-100).
      Default: 80 (reset when ≥80% nodes healthy, i.e., ≤20% dead)
      Must be > (100 - tripThresholdPercent) to prevent flapping. -/
  resetThresholdPercent : Nat := 80

  /-- Enable automatic reset when cluster recovers.
      If false, breaker requires manual pod restart even after recovery.
      Default: true -/
  autoResetEnabled : Bool := true
  deriving Repr, BEq

/-! ## Flare Cluster CRD Spec -/

structure FlareClusterSpecView where
  partitions : Nat := 1
  replicas : Nat := 1  -- 1 Master + (N-1) Slaves per partition
  clusterReplication : ClusterReplicationSpec := {}
  circuitBreaker : CircuitBreakerConfig := {}
  rocksdb : RocksdbConfigSpec := {}
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
  | [key, roleStr, stateStr, partStr, lastMasterStr] => do
    -- Optional 5th token: the lastMasterOf marker. Emitted only while a
    -- rejoined ex-master waits for the masterless-partition refill, so an
    -- operator restart in exactly that window no longer forgets which
    -- candidate holds the newest copy. (A DOWNGRADED operator drops such
    -- lines — acceptable: the marker is transient and pre-marker builds
    -- behaved that way everywhere.)
    let roleVal ← stripPrefix roleStr "role=" >>= fun (s : String) => s.toNat? >>= FlareRole.fromNat
    let stateVal ← stripPrefix stateStr "state=" >>= fun (s : String) => s.toNat? >>= FlareState.fromNat
    let partVal ← stripPrefix partStr "partition=" >>= parseIntStr
    let lastMasterVal ← stripPrefix lastMasterStr "lastMasterOf=" >>= parseIntStr
    let (host, port) ← fromNodeKey key
    return (key, { serverName := host, serverPort := port, role := roleVal, state := stateVal, partition := partVal, lastMasterOf := lastMasterVal })
  | _ => none

/-- Serialize a node map to the ConfigMap line format that `fromNodeMapData`
    parses back: one `host:port role=R state=S partition=P` line per node.
    This is the exact inverse of `parseNodeMapLine`; the FSM reconcile path MUST
    use this (not `repr`) or the persisted `{cr}-node-map` ConfigMap can't be
    reloaded on operator restart and the in-memory topology is lost. -/
def serializeNodeMap (state : FlareClusterState) : String :=
  let lines := state.nodeMap.map fun (key, node) =>
    if node.lastMasterOf != -1 then
      s!"{key} role={node.role.toNat} state={node.state.toNat} partition={node.partition} lastMasterOf={node.lastMasterOf}"
    else
      s!"{key} role={node.role.toNat} state={node.state.toNat} partition={node.partition}"
  -- The broadcast version MUST survive an operator restart. flared drops
  -- any `node sync` whose version is not newer than the last one it saw
  -- (cluster.cc reconstruct_node "ignored: ... newer than"); an operator
  -- that reloads the map but restarts the counter at zero broadcasts into
  -- the void until it out-counts the previous incarnation — observed live
  -- as a cluster that could not converge for hours after an operator
  -- replacement (flared at v10280, fresh operator at v189).
  s!"version={state.nodeMapVersion}\n" ++ "\n".intercalate lines

/-- Rebuild FlareClusterState from serialized ConfigMap data. -/
def fromNodeMapData (data : String) : FlareClusterState :=
  let lines := data.splitOn "\n" |>.filter (· != "")
  let version := (lines.findSome? fun l =>
    if l.startsWith "version=" then (l.drop "version=".length).toNat? else none).getD 0
  let nodes := lines.filterMap parseNodeMapLine
  { FlareClusterState.default with nodeMap := nodes, nodeMapVersion := version }

private def roundtripSample : FlareClusterState :=
  { FlareClusterState.default with
    nodeMap := [("h:12121", { serverName := "h", serverPort := 12121, role := FlareRole.Master, state := FlareState.Active, partition := 0 }),
                ("i:12121", { serverName := "i", serverPort := 12121, role := FlareRole.Slave, state := FlareState.Prepare, partition := 0, lastMasterOf := 0 })],
    nodeMapVersion := 10280 }

/-- The broadcast version survives the persist/reload roundtrip. Regression
    guard for the operator-restart version reset (flared ignores broadcasts
    whose version is not newer than the last it saw, so losing the counter
    silences the operator for hours). -/
theorem nodeMapVersion_roundtrip :
    (fromNodeMapData (serializeNodeMap roundtripSample)).nodeMapVersion = 10280
      ∧ (fromNodeMapData (serializeNodeMap roundtripSample)).nodeMap.length = 2
      ∧ ((fromNodeMapData (serializeNodeMap roundtripSample)).nodeMap.lookup "i:12121").map (·.lastMasterOf) = some 0 := by
  native_decide

/-- FENCING ARITHMETIC: any version from generation `g` (base g·2³² plus a
    counter that stays below 2³²) is strictly below every version of
    generation `g+1`. This is the whole correctness argument for the
    broadcast fencing: flared's existing "ignore non-newer versions" gate
    therefore rejects every broadcast of a deposed leader once it has
    heard the successor. The counter bound holds for ~95 years of 5s ticks. -/
theorem generation_fences (g v : Nat) (h : v < 4294967296) :
    g * 4294967296 + v < (g + 1) * 4294967296 := by omega

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
