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
    -- Assign if partition needs more slaves (scale-out scenario)
    else if slaveCountForPartition state i < maxSlaves then
      some i
    else findPartitionNeedingSlaveAux state numPartitions maxSlaves (i + 1) fuel

/-- Find the first partition index that needs more Slaves (has fewer than replicas-1). -/
def findPartitionNeedingSlave (state : FlareClusterState) (numPartitions : Nat) (maxSlaves : Nat) : Option Nat :=
  findPartitionNeedingSlaveAux state numPartitions maxSlaves 0 numPartitions

/-! ## Topology-aware placement

The scheduler's spread constraints separate PODS across failure domains,
but which pod becomes a partition's master/slave is decided HERE — blind
assignment can put both copies of a partition into one zone even on a
perfectly spread cluster (observed live). The reconcile loop feeds the
pod→zone map in; TCP-context callers pass `[]` and get the old
placement-blind behavior unchanged. -/

/-- Zone of a node key per the reconcile loop's pod→zone map. `none` when
    topology is unknown (kind, tests, clusters without zone labels). -/
def zoneOf (zones : List (String × String)) (key : String) : Option String :=
  zones.lookup key

/-- The zone of partition `pIdx`'s current master, when both the master and
    its zone are known. -/
def masterZoneFor (state : FlareClusterState) (zones : List (String × String))
    (pIdx : Nat) : Option String := do
  let kv ← state.nodeMap.find? (fun kv =>
    kv.2.role == FlareRole.Master && kv.2.partition == Int.ofNat pIdx)
  zoneOf zones kv.1

/-- Every partition currently short of slaves, in index order. -/
def partitionsNeedingSlave (state : FlareClusterState)
    (numPartitions maxSlaves : Nat) : List Nat :=
  (List.range numPartitions).filter
    (fun i => slaveCountForPartition state i < maxSlaves)

/-- Zone-aware slave placement: among the partitions short of slaves,
    prefer one whose master provably sits in a DIFFERENT zone than the
    candidate — that slave becomes the partition's cross-zone copy.
    Falls back to the first needing partition (the placement-blind choice)
    when the candidate's zone is unknown or no cross-zone option exists. -/
def findPartitionNeedingSlaveZoneAware (state : FlareClusterState)
    (numPartitions maxSlaves : Nat) (zones : List (String × String))
    (candidateKey : String) : Option Nat :=
  let needing := partitionsNeedingSlave state numPartitions maxSlaves
  match zoneOf zones candidateKey with
  | none => needing.head?
  | some z =>
    match needing.filter (fun p =>
        match masterZoneFor state zones p with
        | some mz => mz != z
        | none => false) with
    | [] => needing.head?
    | p :: _ => some p

/-- Standby test for one node key against the readBalance.standby selectors.
    podName matches the key itself or its first DNS label (the STS ordinal
    name); zone matches via the podZones mapping when topology is known
    (TCP-context callers pass [] and only podName selectors apply). -/
def isStandbyKey (rb : ReadBalanceSpec) (podZones : List (String × String))
    (key : String) : Bool :=
  rb.standby.any fun sel =>
    (match sel.podName with
     | some pn => key == pn || (key.splitOn ".").head? == some pn
     | none => false)
    || (match sel.zone with
        | some z => podZones.lookup key == some z
        | none => false)

/-- Find a live replica of partition `pIdx`: a Slave in Active state (its
    reconstruction completed, so it holds a full copy of the partition's
    data) whose POD is actually alive. Prepare slaves are excluded —
    promoting a half-reconstructed replica would serve partial data.

    `livePodKeys` guards against GHOST entries: when a pod dies and is
    recreated under the same name faster than one reconcile tick, dead-node
    detection never fires and the operator state can still say Slave/Active
    for a pod that is gone or mid-restart. Promoting such a ghost points the
    whole partition at a down node and sets off an assignment churn that can
    end with an empty node as master (observed as the pvc-data-survival
    DATA LOSS flake). Callers that genuinely know only about one live node
    (the TCP registration fast path) pass just that node's key. -/
def findActiveSlaveForPartition (state : FlareClusterState) (pIdx : Nat)
    (livePodKeys : List String) (standbyKeys : List String := []) : Option String :=
  let isCandidate := fun ((key, n) : String × FlareNode) =>
    n.role == FlareRole.Slave && n.state == FlareState.Active
      && n.partition == Int.ofNat pIdx && livePodKeys.contains key
  -- standby slaves are the promotion choice of LAST resort: prefer any
  -- non-standby candidate; with only standby candidates left, availability
  -- wins and one is still returned.
  (state.nodeMap.find? (fun kv => isCandidate kv && !standbyKeys.contains kv.1)
    |>.map Prod.fst).orElse fun _ =>
      state.nodeMap.find? isCandidate |>.map Prod.fst

/-- Auto-assign a proxy node to the first partition that needs filling.
    Returns updated state and the assigned role/partition.
    First clears any stale entry for this nodeKey so re-registering nodes
    don't block their own partition from being filled. -/
def autoAssign (state : FlareClusterState) (crd : FlareClusterView) (nodeKey : String) (node : FlareNode)
    (livePodKeys : List String) (zones : List (String × String) := []) : FlareClusterState × FlareNode :=
  let numPartitions := crd.spec.partitions
  let maxSlaves := if crd.spec.replicas > 1 then crd.spec.replicas - 1 else 0
  -- Standby slaves must be the zombie-guard's promotion choice of last
  -- resort too (this TCP-side path promotes on ex-master re-registration,
  -- BEFORE dead detection — the FSM's partition-list deprioritization never
  -- sees it). Resolved over the whole node map: podName selectors always
  -- work; zone selectors only when the caller knows the topology.
  let standbyKeys := (state.nodeMap.map Prod.fst).filter
    (isStandbyKey crd.spec.readBalance zones)
  -- Clear stale entry for this node before checking partition needs.
  -- A re-registering node enters as Proxy, so the old Master/Slave entry
  -- must not block the partition from being refilled.
  let cleanState := state.addNode nodeKey node  -- Replace old entry with Proxy
  let cleanState := cleanState.rebuildPartitionMap  -- Rebuild so hasMasterForPartition is accurate
  -- Try Master first
  match findPartitionNeedingMaster cleanState numPartitions with
  | some pIdx =>
    -- ZOMBIE-MASTER GUARD: if the master-less partition still has a live
    -- Active slave, promote THAT slave — never hand the master slot to the
    -- (empty) proxy being assigned. Without this, a master whose flared
    -- restarts and re-registers before dead-node detection fires (the pod
    -- never leaves the live list, so failover never runs) is replaced by
    -- an empty node as Active master while the data-bearing slave keeps
    -- serving nothing — silent data loss. The proxy joins as a fresh slave
    -- of the same partition and reconstructs from the promoted master.
    match findActiveSlaveForPartition cleanState pIdx livePodKeys standbyKeys with
    | some slaveKey =>
      match cleanState.lookupNode slaveKey with
      | some slaveNode =>
        -- Defensive re-check on the LOOKED-UP entry (lookupNode may hit a
        -- different duplicate than the one findActiveSlaveForPartition saw):
        -- promote only a node that is really a Slave OF THIS PARTITION.
        -- Localizes the precondition for the general safety proof too.
        if slaveNode.role == FlareRole.Slave && slaveNode.partition == Int.ofNat pIdx then
          let promoted := { slaveNode with role := FlareRole.Master,
                                           state := FlareState.Active, balance := 100 }
          let newNode := { node with role := FlareRole.Slave, state := FlareState.Prepare,
                                     partition := Int.ofNat pIdx, balance := 0 }
          let newState := ((cleanState.addNode slaveKey promoted).addNode nodeKey newNode)
            |>.rebuildPartitionMap
          (newState, newNode)
        else
          let masterState := if pIdx == 0 then FlareState.Active else FlareState.Prepare
          let newNode := { node with role := FlareRole.Master, state := masterState, partition := Int.ofNat pIdx }
          let part := (cleanState.lookupPartition pIdx).getD {}
          let newPart := { part with master := some nodeKey }
          let newState := (cleanState.addNode nodeKey newNode).setPartition pIdx newPart
          (newState, newNode)
      | none =>
        -- Unreachable (findActiveSlaveForPartition returned a nodeMap key);
        -- fall through to the plain master assignment.
        let masterState := if pIdx == 0 then FlareState.Active else FlareState.Prepare
        let newNode := { node with role := FlareRole.Master, state := masterState, partition := Int.ofNat pIdx }
        let part := (cleanState.lookupPartition pIdx).getD {}
        let newPart := { part with master := some nodeKey }
        let newState := (cleanState.addNode nodeKey newNode).setPartition pIdx newPart
        (newState, newNode)
    | none =>
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
    match findPartitionNeedingSlaveZoneAware cleanState numPartitions maxSlaves zones nodeKey with
    | some pIdx =>
      let newNode := { node with role := FlareRole.Slave, state := FlareState.Prepare, partition := Int.ofNat pIdx, balance := 0 }
      let part := (cleanState.lookupPartition pIdx).getD {}
      let newPart := { part with slaves := part.slaves ++ [nodeKey] }
      let newState := (cleanState.addNode nodeKey newNode).setPartition pIdx newPart
      (newState, newNode)
    | none =>
      -- Stay as Proxy
      (cleanState, node)

/-- With no topology ([]) the zone-aware finder IS the placement-blind
    choice: first partition short of slaves. TCP-context callers and
    unlabeled clusters are exactly the old behavior. -/
theorem findPartitionNeedingSlaveZoneAware_blind (state : FlareClusterState)
    (n maxS : Nat) (key : String) :
    findPartitionNeedingSlaveZoneAware state n maxS [] key
      = (partitionsNeedingSlave state n maxS).head? := by
  rfl

/-- THE PLACEMENT GUARANTEE: when the candidate's zone is known and at
    least one needing partition has a master provably in a different zone,
    the chosen partition is one of those — the new slave always becomes a
    cross-zone copy whenever that is possible at all. -/
theorem findPartitionNeedingSlaveZoneAware_cross
    (state : FlareClusterState) (n maxS : Nat) (zones : List (String × String))
    (key z : String) (p : Nat)
    (hz : zoneOf zones key = some z)
    (hex : (partitionsNeedingSlave state n maxS).any (fun q =>
        match masterZoneFor state zones q with
        | some mz => mz != z
        | none => false) = true)
    (h : findPartitionNeedingSlaveZoneAware state n maxS zones key = some p) :
    ∃ mz, masterZoneFor state zones p = some mz ∧ mz ≠ z := by
  unfold findPartitionNeedingSlaveZoneAware at h
  rw [hz] at h
  dsimp only at h
  cases hfil : (partitionsNeedingSlave state n maxS).filter (fun q =>
      match masterZoneFor state zones q with
      | some mz => mz != z
      | none => false) with
  | nil =>
    rw [List.any_eq_true] at hex
    obtain ⟨q, hqmem, hq⟩ := hex
    have hmem : q ∈ (partitionsNeedingSlave state n maxS).filter (fun q =>
        match masterZoneFor state zones q with
        | some mz => mz != z
        | none => false) := List.mem_filter.mpr ⟨hqmem, hq⟩
    rw [hfil] at hmem
    cases hmem
  | cons hd tl =>
    rw [hfil] at h
    injection h with h
    have hmem : hd ∈ (partitionsNeedingSlave state n maxS).filter (fun q =>
        match masterZoneFor state zones q with
        | some mz => mz != z
        | none => false) := by
      rw [hfil]; exact List.mem_cons_self ..
    have hp := (List.mem_filter.mp hmem).2
    rw [← h]
    cases hmz : masterZoneFor state zones hd with
    | none => rw [hmz] at hp; simp at hp
    | some mz =>
      rw [hmz] at hp
      exact ⟨mz, rfl, by simpa using hp⟩

/-- Partitions whose data-bearing copies (master + slaves) ALL sit in one
    known zone — the persistent placement violation a single-zone outage
    turns into a full partition outage. Partitions with fewer than two
    copies or with any copy of unknown zone are excluded (no false alarms
    while topology is partially known or the partition is degraded for
    other reasons). -/
def partitionsInSingleZone (state : FlareClusterState) (numPartitions : Nat)
    (zones : List (String × String)) : List Nat :=
  (List.range numPartitions).filter fun p =>
    let copies := state.nodeMap.filter (fun kv =>
      kv.2.partition == Int.ofNat p && kv.2.role != FlareRole.Proxy)
    let copyZones := copies.map (fun kv => zoneOf zones kv.1)
    copies.length >= 2 && copyZones.all Option.isSome &&
      (match copyZones with
       | some z :: rest => rest.all (· == some z)
       | _ => false)

/-! ## Zone-placement auto-repair (phase 2)

Detection (partitionsInSingleZone) tells the operator a partition would
not survive a zone outage; this section lets the reconcile loop FIX it.
The repair primitive is a slave SWAP: exchange the partitions of one
slave inside the violating partition and one cross-zone slave elsewhere,
dropping both to Slave/Prepare — flared reconstructs each against its
new partition's master (any-old-role slave shifts dispatch since the
transition-matrix generalization) and activates. Masters never move.

Gates, in order:
- steady state only: any Prepare node anywhere postpones repair, so it
  cannot interfere with rolls, failover, or a previous repair (which
  also throttles repairs to one in flight);
- loss-free only: the violating partition must keep master + an Active
  slave through the swap, i.e. have ≥ 2 slaves (replicas ≥ 3);
- no new violation: the donor's partition must stay zone-diverse after
  losing the donor and gaining the swapped-in (same-zone-as-p) slave. -/

/-- Pick one repair swap: `(slave of a violating partition, cross-zone
    donor slave)`. `none` when nothing needs repair or no safe swap
    exists (the standing WARNING then remains the operator's signal). -/
def findZoneRepairSwap (state : FlareClusterState) (numPartitions : Nat)
    (zones : List (String × String)) : Option (String × String) :=
  if state.nodeMap.any (fun kv => kv.2.state == FlareState.Prepare) then none
  else
    (partitionsInSingleZone state numPartitions zones).findSome? fun p => do
      let copies := state.nodeMap.filter (fun kv =>
        kv.2.partition == Int.ofNat p && kv.2.role != FlareRole.Proxy)
      let slaves := copies.filter (fun kv => kv.2.role == FlareRole.Slave)
      if slaves.length < 2 then none
      else do
        let first ← copies.head?
        let z ← zoneOf zones first.1
        let sKv ← slaves.head?
        let dKv ← state.nodeMap.find? fun kv =>
          kv.2.role == FlareRole.Slave && kv.2.state == FlareState.Active
            && kv.2.partition != Int.ofNat p && decide (kv.2.partition ≥ 0)
            && ((zoneOf zones kv.1).map (fun dz => dz != z)).getD false
            -- donor's partition keeps zone diversity: after the swap its
            -- copy set is (copies \ donor) ∪ {swapped-in node in zone z};
            -- it stays diverse unless everything remaining is ALSO in z.
            && !((state.nodeMap.filter (fun other =>
                  other.2.partition == kv.2.partition
                    && other.2.role != FlareRole.Proxy
                    && other.1 != kv.1)).all
                (fun other => zoneOf zones other.1 == some z))
        return (sKv.1, dKv.1)

/-- Execute the swap: exchange the two slaves' partitions and drop both
    to Prepare (balance 0) so they reconstruct from their new masters.
    Defensive no-op unless BOTH keys are currently Slaves — keeps the
    master-count argument local to this definition. -/
def applyZoneRepairSwap (state : FlareClusterState) (sKey dKey : String)
    : FlareClusterState :=
  match state.lookupNode sKey, state.lookupNode dKey with
  | some sN, some dN =>
    if sN.role == FlareRole.Slave && dN.role == FlareRole.Slave then
      ((state.addNode sKey { sN with partition := dN.partition, state := FlareState.Prepare, balance := 0 }).addNode dKey { dN with partition := sN.partition, state := FlareState.Prepare, balance := 0 }).rebuildPartitionMap
    else state
  | _, _ => state

/-! ## Core reconcile step -/

/-- First-time registration of a node key (extracted from the NodeAdd arm so
    the re-registration path below can bypass it). -/
def registerFreshNode (state : FlareClusterState) (crd : FlareClusterView)
    (nodeKey serverName : String) (serverPort : Nat) :
    FlareClusterState × FlareResponse :=
  -- Register as Proxy initially
  let newNode : FlareNode := {
    serverName := serverName
    serverPort := serverPort
    role := FlareRole.Proxy
    state := FlareState.Active
    partition := -1
    balance := 100
    -- UNIQUE per-node proxy channel number. flared keys its proxy-connection
    -- pools by thread_type (cluster::_get_proxy_thread), so distinct nodes
    -- MUST get distinct numbers — classic flare's index server allocates them
    -- with an incrementing counter starting at 16 (default_thread_type).
    -- Hardcoding 16 for every node collapsed ALL destinations into one shared
    -- pool of proxy connections: every forward/relay went to a hash-picked
    -- arbitrary peer (self-consistently per key, which is why per-key reads
    -- still worked and E2E stayed green). Observed live on a 2-partition
    -- cluster: keys proxied to "the P1 master" were stored on a P1 slave,
    -- and master→slave relays never reached the real slaves.
    -- max+1 over the current map mirrors the classic counter without extra
    -- persisted state (the map itself round-trips through the ConfigMap).
    threadType := (state.nodeMap.foldl (fun acc (_, n) => max acc n.threadType) 15) + 1
    -- Stamp the registration so a concurrent FSM commit (computed from a
    -- snapshot that predates this re-add) cannot resurrect the old role.
    regEpoch := state.nodeMapVersion + 1
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
    -- TCP context knows nothing about pod liveness except the node that is
    -- registering right now, so only IT counts as live for the zombie
    -- guard. Promotion of other slaves is the reconcile loop's job (which
    -- has the real pod list).
    let (newState, assignedNode) := autoAssign state crd nodeKey newNode [nodeKey]
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
  | .StatsNodes =>
    -- flarei-compatible `stats nodes` (op_stats::_send_stats_nodes): five
    -- STAT lines per node — role, state, partition, balance, thread_type —
    -- keyed by <server>:<port>. This is the wire format flare-tools'
    -- `flare-admin list` parses, so the operator answers it verbatim.
    let roleStr := fun (r : FlareRole) => match r with
      | .Master => "master" | .Slave => "slave" | .Proxy => "proxy"
    let stateStr := fun (s : FlareState) => match s with
      | .Active => "active" | .Prepare => "prepare"
      | .Down => "down" | .Ready => "ready"
    let lines := state.nodeMap.foldr (fun (_, n) acc =>
      let nk := s!"{n.serverName}:{n.serverPort}"
      s!"STAT {nk}:role {roleStr n.role}"
        :: s!"STAT {nk}:state {stateStr n.state}"
        :: s!"STAT {nk}:partition {n.partition}"
        :: s!"STAT {nk}:balance {n.balance}"
        :: s!"STAT {nk}:thread_type {n.threadType}"
        :: acc) []
    (state, .End lines)
  | .Version =>
    -- ONE line, NO END: flarei's version reply is a single bare line.
    -- (.End appended "END\r\n", which one-line readers like flare-tools
    -- left in the buffer — every later response was then off by one.)
    (state, .Raw ["VERSION flare-operator 1.0.0"])
  | .Quit =>
    (state, .CloseConnection)
  | .NodeAdd serverName serverPort =>
    let nodeKey := FlareClusterState.toNodeKey serverName serverPort
    -- Re-registration of a key that already owns a partition slot is a pod
    -- RESTART, not a new node: the process lost its in-memory view but its
    -- PVC may still hold the partition's only data. It must not fall through
    -- to fresh registration — the stale entry for this very key still
    -- occupies the partition, so autoAssign would conclude "all partitions
    -- full" (counting the node's own ghost) and demote the returning
    -- data-bearing node to Proxy. Observed live as total-P0 data loss when
    -- master and slave restarted inside the operator's startup grace period
    -- (dead detection suppressed, stale entries still Active).
    match state.lookupNode nodeKey with
    | some old =>
      if old.partition >= 0 then
        -- Rejoin the OLD partition as a syncing slave — deliberately the
        -- most conservative role. The TCP context cannot tell a zombie
        -- (an in-sync Active slave is alive and must be promoted instead)
        -- from a total-partition restart (this registrant holds the newest
        -- surviving copy): both look like "an Active slave entry exists",
        -- because entries can be ghosts. Only the reconcile loop has the
        -- real pod list, so the master decision is deferred to it; the
        -- lastMasterOf marker tells it which live candidate was the
        -- partition's newest copy (see promoteMasterlessPartitions).
        let rejoined : FlareNode :=
          { old with role := FlareRole.Slave, state := FlareState.Prepare,
                     lastMasterOf := if old.role == FlareRole.Master then
                       old.partition else old.lastMasterOf,
                     regEpoch := state.nodeMapVersion + 1 }
        let newState := state.addNode nodeKey rejoined
        let lines := newState.getNodes.map serializeNode
        (newState, .End (lines.map String.trim))
      else
        registerFreshNode state crd nodeKey serverName serverPort
    | none =>
      registerFreshNode state crd nodeKey serverName serverPort
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
        -- VACUOUS-ACTIVATION GUARD: a Prepare SLAVE reporting "reconstruction
        -- complete" while its partition has NO Active master cannot have
        -- synced anything — there was no source. Accepting it mints an
        -- "Active" replica with arbitrary (typically empty) data that the
        -- masterless refill then happily seats as master (observed live in
        -- E2E as total-P0 data loss: a restarted empty ex-master rejoined as
        -- Prepare, instantly reported completion against a masterless
        -- partition, went Active and was promoted over the partition's real
        -- — partially reseeded — copy). Masters are exempt: their
        -- Prepare→Ready is the bootstrap path and has no sync source by
        -- design. flared retries the report, so once a real master exists
        -- and a real reconstruction finishes, activation proceeds normally.
        if node.role == FlareRole.Slave
            && !(state.nodeMap.any (fun kv =>
                  kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active
                    && kv.2.partition == node.partition)) then
          (state, .ServerError s!"node state: refusing Prepare→Active for slave {nodeKey}: partition {node.partition} has no Active master to have synced from")
        else
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
