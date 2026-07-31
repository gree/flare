/-
  GeneralSafety.lean - General inductive safety of the operator state machine

  Discharges the long-standing `sorry` in Safety.lean: EVERY GlobalStep
  preserves "at most one Master per partition", for ARBITRARY states and
  arbitrary step sequences — not `decide` over concrete scenarios.

  Proof architecture: every state-mutating operation satisfies the uniform,
  HYPOTHESIS-FREE bound

      ∀ p, countMastersFor p (op s).nodeMap ≤ max (countMastersFor p s.nodeMap) 1

  (`CLE` below). The bound composes (max is idempotent), and the invariant
  `∀ p, count ≤ 1` is preserved as a direct corollary. The two places that
  CREATE a master justify the bound differently:
  - fresh assignment: `findPartitionNeedingMaster_spec` guarantees the target
    partition had NO master, so the new count is exactly 1 ≤ max _ 1;
  - failover/zombie promotion: the demoted master is a strict removal
    (`count_filter_ne_lt`), so demote-then-promote never exceeds the old
    count. The defensive role/partition guards added to the promotion sites
    make these preconditions LOCAL to the branch — the proof reads them off
    the `if` conditions instead of trusting callers.
-/

import FlareOperator.StateMachine.GlobalModel

namespace FlareOperator.K8s

instance : LawfulBEq FlareRole where
  eq_of_beq {a b} h := by cases a <;> cases b <;> first | rfl | exact Bool.noConfusion h
  rfl {a} := by cases a <;> rfl

end FlareOperator.K8s

namespace FlareOperator.StateMachine.GeneralSafety

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.K8sReconciler (countMastersFor countMastersFor_cons
  assignProxiesPure handleFailoverWithPromotion handleFailoverWithPromotionSingleKey
  handleDrainWithPromotion handleDrainWithPromotionSingleKey
  detectDeadNodesPure)
open FlareOperator.StateMachine.GlobalModel

/-- The Bool "is a Master of partition `p`" flag used by `countMastersFor`. -/
abbrev isM (p : Int) (n : FlareNode) : Bool :=
  n.role == FlareRole.Master && n.partition == p

/-- Uniform per-operation bound: the master count for every partition either
    does not grow, or lands at exactly one. Hypothesis-free, hence
    composable. -/
def CLE (old new : List (String × FlareNode)) : Prop :=
  ∀ p : Int, countMastersFor p new ≤ max (countMastersFor p old) 1

theorem CLE.rfl (l : List (String × FlareNode)) : CLE l l :=
  fun _ => Nat.le_max_left _ _

theorem CLE.trans {a b c : List (String × FlareNode)}
    (h1 : CLE a b) (h2 : CLE b c) : CLE a c := by
  intro p
  have hb := h1 p
  have hc := h2 p
  omega

theorem CLE.of_le {a b : List (String × FlareNode)}
    (h : ∀ p, countMastersFor p b ≤ countMastersFor p a) : CLE a b := by
  intro p
  have := h p
  omega

/-! ## Count lemmas -/

theorem countMastersFor_filter_le (p : Int) (q : String × FlareNode → Bool)
    (l : List (String × FlareNode)) :
    countMastersFor p (l.filter q) ≤ countMastersFor p l :=
  List.Sublist.length_le (List.Sublist.filter _ List.filter_sublist)

/-- Removing every entry with key `k` strictly reduces the count when some
    `k` entry is a Master of `p`. -/
theorem count_filter_ne_lt (p : Int) (k : String) (n0 : FlareNode)
    (l : List (String × FlareNode))
    (hmem : (k, n0) ∈ l) (hM : isM p n0 = true) :
    countMastersFor p (l.filter (fun kv => kv.1 != k)) < countMastersFor p l := by
  induction l with
  | nil => cases hmem
  | cons hd tl ih =>
    obtain ⟨k', n'⟩ := hd
    rcases List.mem_cons.mp hmem with heq | htail
    · -- the head is the witness: the filter drops it, the count keeps it
      cases heq
      have hfle := countMastersFor_filter_le p (fun kv => kv.1 != k) tl
      have hcnt : countMastersFor p ((k, n0) :: tl) = countMastersFor p tl + 1 := by
        rw [countMastersFor_cons]
        simp [show (n0.role == FlareRole.Master && n0.partition == p) = true from hM]
      rw [List.filter_cons]
      split
      · next habs => simp at habs
      · omega
    · have hlt := ih htail
      have hc1 : countMastersFor p ((k', n') :: List.filter (fun kv => kv.1 != k) tl)
          ≤ countMastersFor p (List.filter (fun kv => kv.1 != k) tl) + 1 := by
        rw [countMastersFor_cons]; split <;> omega
      have hc1' : countMastersFor p ((k', n') :: List.filter (fun kv => kv.1 != k) tl)
          ≥ countMastersFor p (List.filter (fun kv => kv.1 != k) tl) := by
        rw [countMastersFor_cons]; split <;> omega
      have hc2 : countMastersFor p ((k', n') :: tl)
          ≥ countMastersFor p tl := by
        rw [countMastersFor_cons]; split <;> omega
      have hc2' : ∀ b, (isM p (k', n').2 = b) →
          countMastersFor p ((k', n') :: tl)
            = countMastersFor p tl + (if b then 1 else 0) := by
        intro b hb
        rw [countMastersFor_cons]
        cases b with
        | true => simp [show ((k', n').2.role == FlareRole.Master
            && (k', n').2.partition == p) = true from hb]
        | false => simp [show ((k', n').2.role == FlareRole.Master
            && (k', n').2.partition == p) = false from hb]
      rw [List.filter_cons]
      split
      · -- head kept by the filter: contributions cancel
        have heq2 := hc2' (isM p (k', n').2) rfl
        have heq1 : countMastersFor p ((k', n') :: List.filter (fun kv => kv.1 != k) tl)
            = countMastersFor p (List.filter (fun kv => kv.1 != k) tl)
              + (if isM p (k', n').2 then 1 else 0) := by
          rw [countMastersFor_cons]
          cases hb : isM p (k', n').2 with
          | true => simp [show ((k', n').2.role == FlareRole.Master
              && (k', n').2.partition == p) = true from hb]
          | false => simp [show ((k', n').2.role == FlareRole.Master
              && (k', n').2.partition == p) = false from hb]
        cases isM p (k', n').2 <;> simp_all <;> omega
      · -- head dropped by the filter
        omega

/-- `addNode` as a list operation. -/
theorem addNode_nodeMap (s : FlareClusterState) (k : String) (n : FlareNode) :
    (s.addNode k n).nodeMap = (k, n) :: s.nodeMap.filter (·.1 != k) := rfl

/-- Adding a non-Master (for `p`) never increases the count for `p`. -/
theorem count_addNode_nonmaster (p : Int) (s : FlareClusterState)
    (k : String) (n : FlareNode) (h : isM p n = false) :
    countMastersFor p (s.addNode k n).nodeMap ≤ countMastersFor p s.nodeMap := by
  rw [addNode_nodeMap, countMastersFor_cons]
  simp only [show (n.role == FlareRole.Master && n.partition == p) = false from h,
    Bool.false_eq_true, if_false]
  exact countMastersFor_filter_le p _ _

/-- Adding any node lands at ≤ old count + 1. -/
theorem count_addNode_le_succ (p : Int) (s : FlareClusterState)
    (k : String) (n : FlareNode) :
    countMastersFor p (s.addNode k n).nodeMap ≤ countMastersFor p s.nodeMap + 1 := by
  rw [addNode_nodeMap, countMastersFor_cons]
  have := countMastersFor_filter_le p (fun kv => kv.1 != k) s.nodeMap
  split <;> omega

/-- `rebuildPartitionMap` and `setPartition` do not touch the node map. -/
theorem rebuild_nodeMap (s : FlareClusterState) :
    s.rebuildPartitionMap.nodeMap = s.nodeMap := rfl

theorem setPartition_nodeMap (s : FlareClusterState) (i : Nat) (part : FlarePartition) :
    (s.setPartition i part).nodeMap = s.nodeMap := rfl

/-- Bridge: `hasMasterForPartition = false` means the count is zero. -/
theorem count_zero_of_no_master (s : FlareClusterState) (pIdx : Nat)
    (h : hasMasterForPartition s pIdx = false) :
    countMastersFor (Int.ofNat pIdx) s.nodeMap = 0 := by
  unfold countMastersFor
  rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]
  intro kv hmem
  unfold hasMasterForPartition at h
  rw [List.any_eq_false] at h
  have hkv := h kv hmem
  simp only [decide_eq_true_eq] at hkv
  intro habs
  apply hkv
  have h1 : (kv.2.role == FlareRole.Master) = true := by
    revert habs; cases kv.2.role == FlareRole.Master <;> simp
  have h2 : (kv.2.partition == Int.ofNat pIdx) = true := by
    revert habs; cases hb : kv.2.partition == Int.ofNat pIdx
    · cases kv.2.role == FlareRole.Master <;> simp
    · intro _; rfl
  exact ⟨eq_of_beq h1, eq_of_beq h2⟩

/-! ## autoAssign satisfies the bound -/

/-- Plain master assignment at a partition that provably has no master. -/
private theorem count_assign_master_le (s target : FlareClusterState)
    (k : String) (n' : FlareNode) (pIdx : Nat)
    (hclean : ∀ p, countMastersFor p target.nodeMap ≤ countMastersFor p s.nodeMap)
    (hzero : countMastersFor (Int.ofNat pIdx) target.nodeMap = 0)
    (hpart : n'.partition = Int.ofNat pIdx) :
    CLE s.nodeMap (target.addNode k n').nodeMap := by
  intro p
  cases hp : Int.ofNat pIdx == p with
  | true =>
    have hpe : Int.ofNat pIdx = p := eq_of_beq hp
    subst hpe
    have h1 := count_addNode_le_succ (Int.ofNat pIdx) target k n'
    omega
  | false =>
    have hnm : isM p n' = false := by
      have : (n'.partition == p) = false := by rw [hpart]; exact hp
      simp [isM, this]
    have h1 := count_addNode_nonmaster p target k n' hnm
    have h2 := hclean p
    omega

theorem autoAssign_cle (s : FlareClusterState) (crd : FlareClusterView)
    (k : String) (n : FlareNode) (live : List String)
    (hn : (n.role == FlareRole.Master) = false) :
    CLE s.nodeMap (autoAssign s crd k n live).1.nodeMap := by
  have hnM : ∀ p, isM p n = false := fun p => by simp [isM, hn]
  have hclean : ∀ p,
      countMastersFor p ((s.addNode k n).rebuildPartitionMap).nodeMap
        ≤ countMastersFor p s.nodeMap := fun p => by
    rw [rebuild_nodeMap]; exact count_addNode_nonmaster p s k n (hnM p)
  unfold autoAssign
  dsimp only
  split
  next pIdx hfind =>
    have hzero : countMastersFor (Int.ofNat pIdx)
        ((s.addNode k n).rebuildPartitionMap).nodeMap = 0 :=
      count_zero_of_no_master _ pIdx
        (findPartitionNeedingMaster_spec _ crd.spec.partitions pIdx hfind)
    split
    next slaveKey hguard =>
      split
      next slaveNode hlook =>
        split
        next hrp =>
          -- checked promotion of a Slave of pIdx, then adding k as a Slave
          have hrole : (slaveNode.role == FlareRole.Slave) = true := by
            revert hrp
            cases slaveNode.role == FlareRole.Slave <;>
              cases slaveNode.partition == Int.ofNat pIdx <;> simp
          have hpart : (slaveNode.partition == Int.ofNat pIdx) = true := by
            revert hrp
            cases slaveNode.role == FlareRole.Slave <;>
              cases slaveNode.partition == Int.ofNat pIdx <;> simp
          intro p
          dsimp only
          rw [rebuild_nodeMap]
          have hstep2 := count_addNode_nonmaster p (((s.addNode k n).rebuildPartitionMap).addNode slaveKey { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 }) k { n with role := FlareRole.Slave, state := FlareState.Prepare, partition := Int.ofNat pIdx, balance := 0 } (by simp [isM, show (FlareRole.Slave == FlareRole.Master) = false from rfl])
          have hstep1 := count_assign_master_le s ((s.addNode k n).rebuildPartitionMap) slaveKey { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 } pIdx hclean hzero (eq_of_beq hpart)
          have := hstep1 p
          omega
        next hrp =>
          intro p
          dsimp only
          rw [setPartition_nodeMap]
          exact count_assign_master_le s _ k _ pIdx hclean hzero rfl p
      next hlook =>
        intro p
        dsimp only
        rw [setPartition_nodeMap]
        exact count_assign_master_le s _ k _ pIdx hclean hzero rfl p
    next hguard =>
      intro p
      dsimp only
      rw [setPartition_nodeMap]
      exact count_assign_master_le s _ k _ pIdx hclean hzero rfl p
  next hfind =>
    split
    next pIdx hslave =>
      intro p
      dsimp only
      rw [setPartition_nodeMap]
      have h1 := count_addNode_nonmaster p ((s.addNode k n).rebuildPartitionMap) k
        { n with role := FlareRole.Slave, state := FlareState.Prepare,
                 partition := Int.ofNat pIdx, balance := 0 }
        (by simp [isM, show (FlareRole.Slave == FlareRole.Master) = false from rfl])
      have h2 := hclean p
      omega
    next hslave =>
      intro p
      dsimp only
      have := hclean p
      omega

/-! ## lookup gives membership -/

theorem mem_of_lookup {l : List (String × FlareNode)} {k : String} {v : FlareNode}
    (h : l.lookup k = some v) : (k, v) ∈ l := by
  induction l with
  | nil => cases h
  | cons hd tl ih =>
    obtain ⟨k', v'⟩ := hd
    rw [List.lookup] at h
    split at h
    · next heq =>
      cases h
      have : k = k' := eq_of_beq heq
      subst this
      exact List.mem_cons_self ..
    · exact List.mem_cons_of_mem _ (ih h)

theorem mem_of_lookupNode {s : FlareClusterState} {k : String} {v : FlareNode}
    (h : s.lookupNode k = some v) : (k, v) ∈ s.nodeMap :=
  mem_of_lookup h

/-- Replacing an entry with a node whose Master flag is backed by an existing
    entry of the same key never increases the count. -/
theorem count_addNode_replace_le (p : Int) (s : FlareClusterState)
    (k : String) (n' : FlareNode)
    (h : isM p n' = true → ∃ n0, (k, n0) ∈ s.nodeMap ∧ isM p n0 = true) :
    countMastersFor p (s.addNode k n').nodeMap ≤ countMastersFor p s.nodeMap := by
  cases hM : isM p n' with
  | false => exact count_addNode_nonmaster p s k n' hM
  | true =>
    obtain ⟨n0, hmem, h0⟩ := h hM
    have hlt := count_filter_ne_lt p k n0 s.nodeMap hmem h0
    rw [addNode_nodeMap, countMastersFor_cons]
    split
    · omega
    · next hno => exact absurd hM hno

/-! ## assignProxiesPure satisfies the bound -/

theorem assignProxiesPure_cle (s : FlareClusterState) (crd : FlareClusterView)
    (live : List String) (term : List String) :
    CLE s.nodeMap (assignProxiesPure s crd live [] term).nodeMap := by
  unfold assignProxiesPure
  -- generalize the fold: from any accumulator the bound holds w.r.t. it.
  -- The Terminating-exclusion conjunct only ADDS identity steps, so the bound
  -- is preserved regardless of `term`.
  suffices hgen : ∀ (items : List (String × FlareNode)) (acc : FlareClusterState),
      CLE acc.nodeMap
        (items.foldl (fun currentState kv =>
          if kv.2.role == FlareRole.Proxy && kv.2.state != FlareState.Down
              && !term.contains kv.1 then
            (autoAssign currentState crd kv.1 kv.2 live).1
          else currentState) acc).nodeMap by
    exact hgen s.nodeMap s
  intro items
  induction items with
  | nil => intro acc; exact CLE.rfl _
  | cons hd tl ih =>
    intro acc
    rw [List.foldl_cons]
    refine CLE.trans (b := (if hd.2.role == FlareRole.Proxy
        && hd.2.state != FlareState.Down && !term.contains hd.1 then
          (autoAssign acc crd hd.1 hd.2 live).1 else acc).nodeMap) ?_ (ih _)
    split
    · next hguard =>
      have hrole : (hd.2.role == FlareRole.Proxy) = true := by
        revert hguard
        cases hd.2.role == FlareRole.Proxy <;>
          cases hd.2.state != FlareState.Down <;>
          cases !term.contains hd.1 <;> simp
      have hnm : (hd.2.role == FlareRole.Master) = false := by
        have : hd.2.role = FlareRole.Proxy := eq_of_beq hrole
        rw [this]; rfl
      exact autoAssign_cle acc crd hd.1 hd.2 live hnm
    · exact CLE.rfl _

/-! ## promoteMasterlessPartitions satisfies the bound -/

theorem promoteMasterlessPartition_cle (s : FlareClusterState) (pIdx : Nat)
    (live : List String) :
    CLE s.nodeMap (K8sReconciler.promoteMasterlessPartition s pIdx live).nodeMap := by
  unfold K8sReconciler.promoteMasterlessPartition
  split
  · exact CLE.rfl _
  · next hno =>
    -- promotion is gated on "no master entry for pIdx", so the count there
    -- is zero and inserting one master lands at exactly 1; for every other
    -- partition the inserted node is not a master, so the count shrinks.
    have h0 : countMastersFor (Int.ofNat pIdx) s.nodeMap = 0 :=
      count_zero_of_no_master s pIdx (by simpa using hno)
    dsimp only
    split
    · next kv _ =>
      intro p
      by_cases hp : p = Int.ofNat pIdx
      · subst hp
        have hle := count_addNode_le_succ (Int.ofNat pIdx) s kv.1 { kv.2 with role := FlareRole.Master, state := FlareState.Active, partition := Int.ofNat pIdx, lastMasterOf := -1 }
        have h1 : countMastersFor (Int.ofNat pIdx) (s.addNode kv.1 { kv.2 with role := FlareRole.Master, state := FlareState.Active, partition := Int.ofNat pIdx, lastMasterOf := -1 }).nodeMap ≤ 1 := by omega
        exact Nat.le_trans h1 (Nat.le_max_right _ _)
      · have hbp : (Int.ofNat pIdx == p) = false := by
          cases hb : Int.ofNat pIdx == p
          · rfl
          · exact absurd (Eq.symm (eq_of_beq hb)) hp
        have hM : isM p { kv.2 with role := FlareRole.Master, state := FlareState.Active, partition := Int.ofNat pIdx, lastMasterOf := -1 } = false := by
          dsimp only [isM]
          rw [hbp]
          simp
        exact Nat.le_trans (count_addNode_nonmaster p s kv.1 _ hM)
          (Nat.le_max_left _ _)
    · exact CLE.rfl _

theorem promoteMasterlessPartitions_cle (s : FlareClusterState)
    (crd : FlareClusterView) (live : List String) :
    CLE s.nodeMap (K8sReconciler.promoteMasterlessPartitions s crd live).nodeMap := by
  unfold K8sReconciler.promoteMasterlessPartitions
  generalize List.range crd.spec.partitions = idxs
  induction idxs generalizing s with
  | nil => exact CLE.rfl _
  | cons hd tl ih =>
    rw [List.foldl_cons]
    exact CLE.trans (promoteMasterlessPartition_cle s hd live) (ih _)

/-! ## applyZoneRepairSwap satisfies the bound -/

theorem applyZoneRepairSwap_cle (s : FlareClusterState) (sKey dKey : String) :
    CLE s.nodeMap (applyZoneRepairSwap s sKey dKey).nodeMap := by
  unfold applyZoneRepairSwap
  split
  · next sN dN hs hd =>
    split
    · next hroles =>
      -- both writes are Slave records (roles copied from entries the guard
      -- checked): two non-master inserts can only shrink every count
      have hsr : (sN.role == FlareRole.Slave) = true := by
        revert hroles; cases sN.role == FlareRole.Slave <;> simp
      have hdr : (dN.role == FlareRole.Slave) = true := by
        revert hroles
        cases hb : sN.role == FlareRole.Slave <;> cases dN.role == FlareRole.Slave <;> simp
      have hsr' : sN.role = FlareRole.Slave := eq_of_beq hsr
      have hdr' : dN.role = FlareRole.Slave := eq_of_beq hdr
      apply CLE.of_le
      intro p
      rw [rebuild_nodeMap]
      have h1 : countMastersFor p ((s.addNode sKey { sN with partition := dN.partition, state := FlareState.Prepare, balance := 0 }).addNode dKey { dN with partition := sN.partition, state := FlareState.Prepare, balance := 0 }).nodeMap
          ≤ countMastersFor p (s.addNode sKey { sN with partition := dN.partition, state := FlareState.Prepare, balance := 0 }).nodeMap := by
        apply count_addNode_nonmaster
        simp [isM, hdr']
      have h2 : countMastersFor p (s.addNode sKey { sN with partition := dN.partition, state := FlareState.Prepare, balance := 0 }).nodeMap
          ≤ countMastersFor p s.nodeMap := by
        apply count_addNode_nonmaster
        simp [isM, hsr']
      exact Nat.le_trans h1 h2
    · exact CLE.rfl _
  · exact CLE.rfl _

/-! ## registerFreshNode satisfies the bound -/

theorem registerFreshNode_cle (s : FlareClusterState) (crd : FlareClusterView)
    (nodeKey serverName : String) (serverPort : Nat) :
    CLE s.nodeMap (registerFreshNode s crd nodeKey serverName serverPort).1.nodeMap := by
  unfold registerFreshNode
  -- Branch tree: match lookupPartition 0 × if needsP0Master × if assigned-as-P0.
  -- Every leaf is either an autoAssign result or a plain Proxy addNode; the
  -- incoming node record literally has role := Proxy, so `rfl` discharges
  -- both side conditions.
  dsimp only
  split <;> split <;> (try split) <;>
    first
      | (apply autoAssign_cle; rfl)
      | (apply CLE.of_le; intro p; apply count_addNode_nonmaster; rfl)

/-! ## reconcileStep satisfies the bound -/

theorem reconcileStep_cle (s : FlareClusterState) (crd : FlareClusterView)
    (ev : FlareEvent) :
    CLE s.nodeMap (reconcileStep s crd ev).1.nodeMap := by
  unfold reconcileStep
  cases ev with
  | Ping => exact CLE.rfl _
  | Meta => exact CLE.rfl _
  | Stats => exact CLE.rfl _
  | Version => exact CLE.rfl _
  | Quit => exact CLE.rfl _
  | NodeSync _ => exact CLE.rfl _
  | StatsNodes => exact CLE.rfl _
  | NodeRemove _ _ => exact CLE.rfl _
  | MutationAttempt _ => exact CLE.rfl _
  | ParseError _ => exact CLE.rfl _
  | NodeAdd serverName serverPort =>
    -- Branch tree: match lookupNode (rejoin vs fresh) × if partition≥0.
    -- The rejoin insert is always a Slave record — a non-master insert
    -- that can only shrink the count (the master decision is deferred to
    -- the reconcile loop's promoteMasterlessPartitions, proven separately).
    -- Fresh keys delegate to registerFreshNode_cle.
    dsimp only
    split
    · next old hlook =>
      split
      · -- old.partition ≥ 0: rejoin as syncing slave, a non-master insert
        exact CLE.of_le (fun p => count_addNode_nonmaster p _ _ _ rfl)
      · exact registerFreshNode_cle s crd _ serverName serverPort
    · exact registerFreshNode_cle s crd _ serverName serverPort
  | NodeState serverName serverPort newState =>
    dsimp only
    split
    · next hlook => exact CLE.rfl _
    · next node hlook =>
      split
      · apply CLE.of_le
        intro p
        apply count_addNode_replace_le
        intro hM
        exact ⟨node, mem_of_lookupNode hlook, hM⟩
      · exact CLE.rfl _

/-! ## Failover promotion satisfies the bound -/

theorem handleFailoverSingle_cle (s : FlareClusterState) (key : String) :
    CLE s.nodeMap (handleFailoverWithPromotionSingleKey s key).nodeMap := by
  unfold handleFailoverWithPromotionSingleKey
  dsimp only
  split
  · exact CLE.rfl _
  next node hlook =>
    have hmem : (key, node) ∈ s.nodeMap := mem_of_lookupNode hlook
    -- Parametric over the stamped lastMasterOf: countMastersFor only inspects
    -- role/partition, and the surrounding `split` reduces the record's inner
    -- if differently per branch — a fixed literal would match neither.
    have hdemote : ∀ (lmo : Int) p, countMastersFor p (s.addNode key { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1, lastMasterOf := lmo }).nodeMap ≤ countMastersFor p s.nodeMap := fun _lmo p => count_addNode_nonmaster p s key _ (by simp [isM, show (FlareRole.Proxy == FlareRole.Master) = false from rfl])
    split
    next hM =>
      split
      · exact CLE.of_le (fun p => hdemote _ p)
      next part hfindp =>
        split
        · exact CLE.of_le (fun p => hdemote _ p)
        next slaveKey hhead =>
          split
          · exact CLE.of_le (fun p => hdemote _ p)
          next slaveNode hlook2 =>
            split
            next hguard =>
              have hpartB : (slaveNode.partition == node.partition) = true := by
                revert hguard
                cases slaveNode.role == FlareRole.Slave <;>
                  cases slaveNode.partition == node.partition <;> simp
              have hpartEq : slaveNode.partition = node.partition := eq_of_beq hpartB
              intro p
              rw [setPartition_nodeMap]
              cases hp : node.partition == p with
              | false =>
                have hnm : isM p { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 } = false := by
                  simp only [isM]
                  have hpp : (slaveNode.partition == p) = false := by rw [hpartEq]; exact hp
                  simp [hpp]
                have h1 := count_addNode_nonmaster p (s.addNode key { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1, lastMasterOf := node.partition }) slaveKey _ hnm
                have h2 := hdemote node.partition p
                omega
              | true =>
                have hpe : node.partition = p := eq_of_beq hp
                have hwit : isM p node = true := by
                  simp only [isM, hM, Bool.true_and]
                  rw [hpe]
                  simp
                have hlt := count_filter_ne_lt p key node s.nodeMap hmem hwit
                have hdem0 : countMastersFor p (s.addNode key { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1, lastMasterOf := node.partition }).nodeMap ≤ countMastersFor p s.nodeMap - 1 := by
                  rw [addNode_nodeMap, countMastersFor_cons]
                  split
                  · next habs =>
                    exact absurd habs (by simp)
                  · omega
                have h1 := count_addNode_le_succ p (s.addNode key { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1, lastMasterOf := node.partition }) slaveKey { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 }
                omega
            next hguard => exact CLE.of_le (fun p => hdemote _ p)
    next hM => exact CLE.of_le (fun p => hdemote _ p)

theorem handleFailover_cle (s : FlareClusterState) (deadKeys : List String) :
    CLE s.nodeMap (handleFailoverWithPromotion s deadKeys).nodeMap := by
  unfold handleFailoverWithPromotion
  suffices hgen : ∀ (ks : List String) (acc : FlareClusterState),
      CLE acc.nodeMap (ks.foldl handleFailoverWithPromotionSingleKey acc).nodeMap by
    exact hgen deadKeys s
  intro ks
  induction ks with
  | nil => intro acc; exact CLE.rfl _
  | cons hd tl ih =>
    intro acc
    rw [List.foldl_cons]
    exact CLE.trans (handleFailoverSingle_cle acc hd) (ih _)

/-! ## Graceful drain preserves the bound (mirrors failover)

    `handleDrainWithPromotionSingleKey` is `handleFailoverWithPromotionSingleKey`
    with the demoted node left state=Active (a live proxy) instead of Down. The
    at-most-one-master count depends only on the `role` field, never `state`, so
    the proof is identical to `handleFailoverSingle_cle`. -/
theorem handleDrainSingle_cle (s : FlareClusterState) (key : String) :
    CLE s.nodeMap (handleDrainWithPromotionSingleKey s key).nodeMap := by
  unfold handleDrainWithPromotionSingleKey
  dsimp only
  split
  · exact CLE.rfl _
  next node hlook =>
    have hmem : (key, node) ∈ s.nodeMap := mem_of_lookupNode hlook
    have hdemote : ∀ p, countMastersFor p (s.addNode key { node with state := FlareState.Active, role := FlareRole.Proxy, partition := -1 }).nodeMap ≤ countMastersFor p s.nodeMap := fun p => count_addNode_nonmaster p s key _ (by simp [isM, show (FlareRole.Proxy == FlareRole.Master) = false from rfl])
    split
    next hM =>
      split
      · exact CLE.of_le hdemote
      next part hfindp =>
        split
        · exact CLE.of_le hdemote
        next slaveKey hhead =>
          split
          · exact CLE.of_le hdemote
          next slaveNode hlook2 =>
            split
            next hguard =>
              have hpartB : (slaveNode.partition == node.partition) = true := by
                revert hguard
                cases slaveNode.role == FlareRole.Slave <;>
                  cases slaveNode.partition == node.partition <;> simp
              have hpartEq : slaveNode.partition = node.partition := eq_of_beq hpartB
              intro p
              rw [setPartition_nodeMap]
              cases hp : node.partition == p with
              | false =>
                have hnm : isM p { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 } = false := by
                  simp only [isM]
                  have hpp : (slaveNode.partition == p) = false := by rw [hpartEq]; exact hp
                  simp [hpp]
                have h1 := count_addNode_nonmaster p (s.addNode key { node with state := FlareState.Active, role := FlareRole.Proxy, partition := -1 }) slaveKey _ hnm
                have h2 := hdemote p
                omega
              | true =>
                have hpe : node.partition = p := eq_of_beq hp
                have hwit : isM p node = true := by
                  simp only [isM, hM, Bool.true_and]
                  rw [hpe]
                  simp
                have hlt := count_filter_ne_lt p key node s.nodeMap hmem hwit
                have hdem0 : countMastersFor p (s.addNode key { node with state := FlareState.Active, role := FlareRole.Proxy, partition := -1 }).nodeMap ≤ countMastersFor p s.nodeMap - 1 := by
                  rw [addNode_nodeMap, countMastersFor_cons]
                  split
                  · next habs =>
                    exact absurd habs (by simp)
                  · omega
                have h1 := count_addNode_le_succ p (s.addNode key { node with state := FlareState.Active, role := FlareRole.Proxy, partition := -1 }) slaveKey { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 }
                omega
            next hguard => exact CLE.of_le hdemote
    next hM => exact CLE.of_le hdemote

theorem handleDrain_cle (s : FlareClusterState) (drainKeys : List String) :
    CLE s.nodeMap (handleDrainWithPromotion s drainKeys).nodeMap := by
  unfold handleDrainWithPromotion
  suffices hgen : ∀ (ks : List String) (acc : FlareClusterState),
      CLE acc.nodeMap (ks.foldl handleDrainWithPromotionSingleKey acc).nodeMap by
    exact hgen drainKeys s
  intro ks
  induction ks with
  | nil => intro acc; exact CLE.rfl _
  | cons hd tl ih =>
    intro acc
    rw [List.foldl_cons]
    exact CLE.trans (handleDrainSingle_cle acc hd) (ih _)

/-! ## Every GlobalStep satisfies the bound -/

theorem stepGlobal_cle (g : GlobalState) (step : GlobalStep) :
    CLE g.operatorState.nodeMap (stepGlobal g step).operatorState.nodeMap := by
  unfold stepGlobal
  cases step with
  | OperatorProcessMsg =>
    dsimp only
    split
    · exact CLE.rfl _
    · split
      · exact reconcileStep_cle _ _ _
      · exact reconcileStep_cle _ _ _
  | NodeProcessMsg nodeKey =>
    -- the operator state is untouched on every leaf of this arm's match tree
    dsimp only
    repeat' split
    all_goals exact CLE.rfl _
  | OperatorReconcile =>
    dsimp only
    split
    · exact CLE.trans (CLE.trans (assignProxiesPure_cle _ _ _ [])
        (promoteMasterlessPartitions_cle _ _ _)) (applyZoneRepairSwap_cle _ _ _)
    · exact CLE.trans (assignProxiesPure_cle _ _ _ [])
        (promoteMasterlessPartitions_cle _ _ _)
  | NodeReconstructionComplete nodeKey =>
    dsimp only
    repeat' split
    all_goals exact CLE.rfl _
  | MasterCommitsData nodeKey =>
    -- data-plane bookkeeping only: nodeStates.holdsData changes, the
    -- operator's nodeMap is untouched on every leaf
    dsimp only
    repeat' split
    all_goals exact CLE.rfl _
  | NodeDie nodeKey =>
    dsimp only
    have := handleFailover_cle g.operatorState.rebuildPartitionMap
      (detectDeadNodesPure g.operatorState
        ((g.nodeStates.filter (fun kv => kv.1 != nodeKey)).map Prod.fst))
    intro p
    have h2 := this p
    rw [rebuild_nodeMap] at h2
    exact h2

/-! ## THE GENERAL INVARIANT PRESERVATION THEOREM -/

/-- For EVERY state and EVERY step: if at most one Master per partition held
    before, it holds after. Arbitrary states, arbitrary steps — the general
    inductive safety property, sorry-free. -/
theorem stepGlobal_preserves_atMostOne (g : GlobalState) (step : GlobalStep)
    (h : ∀ p : Int, countMastersFor p g.operatorState.nodeMap ≤ 1) :
    ∀ p : Int, countMastersFor p (stepGlobal g step).operatorState.nodeMap ≤ 1 := by
  intro p
  have hc := stepGlobal_cle g step p
  have hp := h p
  omega

/-- Trace version: the invariant holds after ANY sequence of steps. -/
theorem stepMany_preserves_atMostOne (g : GlobalState) (steps : List GlobalStep)
    (h : ∀ p : Int, countMastersFor p g.operatorState.nodeMap ≤ 1) :
    ∀ p : Int, countMastersFor p (stepMany g steps).operatorState.nodeMap ≤ 1 := by
  induction steps generalizing g with
  | nil => exact h
  | cons hd tl ih =>
    rw [stepMany, List.foldl_cons]
    exact ih _ (stepGlobal_preserves_atMostOne g hd h)

end FlareOperator.StateMachine.GeneralSafety

