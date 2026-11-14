/-
  PromotionForbiddenProofs.lean — a copy `PromotionEvidence.classify` calls
  FORBIDDEN is never chosen as master by any promotion path (issue
  flare-fv-forbidden-promotion, FORMAL_VERIFICATION §4 #3).

  The statements are about the PURE decision functions. What Main.lean builds
  with IO (the readings, the stats replies, the `evidence` list) enters as the
  named premises listed at the end of this file; `docs/FORMAL_VERIFICATION.md`
  §4 #3 carries the same list.

  The one claim every path shares is `NoNewMaster ex before after`: no key of
  `ex` is a Master in `after` unless it already was one in `before`.
-/

import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.PromotionEvidence
import FlareOperator.StateMachine.Handover

namespace FlareOperator.PromotionForbiddenProofs

open FlareOperator.K8s
open FlareOperator.K8sReconciler
open FlareOperator.PromotionEvidence

/-! ## The shared claim -/

/-- `k` is a Master in `s`. -/
def IsMaster (s : FlareClusterState) (k : String) : Prop :=
  ∃ n, s.lookupNode k = some n ∧ n.role = FlareRole.Master

/-- No key of `ex` BECOMES a Master from `before` to `after`. -/
def NoNewMaster (ex : List String) (before after : FlareClusterState) : Prop :=
  ∀ k, k ∈ ex → IsMaster after k → IsMaster before k

theorem NoNewMaster.refl (ex : List String) (s : FlareClusterState) : NoNewMaster ex s s :=
  fun _ _ h => h

theorem NoNewMaster.trans {ex : List String} {a b c : FlareClusterState}
    (h1 : NoNewMaster ex a b) (h2 : NoNewMaster ex b c) : NoNewMaster ex a c :=
  fun k hk hc => h1 k hk (h2 k hk hc)

theorem NoNewMaster.mono {ex ex' : List String} {a b : FlareClusterState}
    (h : NoNewMaster ex a b) (hsub : ∀ k, k ∈ ex' → k ∈ ex) : NoNewMaster ex' a b :=
  fun k hk hb => h k (hsub k hk) hb

/-- Two states with the same node map are interchangeable for `IsMaster`. -/
theorem NoNewMaster.of_nodeMap_eq {ex : List String} {a b : FlareClusterState}
    (h : a.nodeMap = b.nodeMap) : NoNewMaster ex a b := by
  intro k _ hb
  obtain ⟨n, hn, hr⟩ := hb
  exact ⟨n, by simpa [FlareClusterState.lookupNode, h] using hn, hr⟩

/-! ## Node map and partition map lemmas -/

theorem lookup_filter_ne (l : List (String × FlareNode)) (j k : String) (h : k ≠ j) :
    (l.filter (fun kv => kv.1 != j)).lookup k = l.lookup k := by
  induction l with
  | nil => rfl
  | cons hd tl ih =>
    obtain ⟨a, b⟩ := hd
    by_cases haj : a = j
    · subst haj
      have hka : (k == a) = false := by simpa using h
      simp [List.filter_cons, List.lookup, hka, ih]
    · have hne : (a != j) = true := by simpa using haj
      by_cases hka : k = a
      · subst hka; simp [List.filter_cons, List.lookup, hne]
      · have hka' : (k == a) = false := by simpa using hka
        simp [List.filter_cons, List.lookup, hne, hka', ih]

theorem lookupNode_addNode (s : FlareClusterState) (j : String) (n : FlareNode) (k : String) :
    (s.addNode j n).lookupNode k = if k = j then some n else s.lookupNode k := by
  by_cases h : k = j
  · subst h; simp [FlareClusterState.lookupNode, FlareClusterState.addNode, List.lookup]
  · have hkj : (k == j) = false := by simpa using h
    simp [FlareClusterState.lookupNode, FlareClusterState.addNode, List.lookup, hkj, h,
      lookup_filter_ne _ _ _ h]

theorem isMaster_addNode (s : FlareClusterState) (j : String) (n : FlareNode) (k : String) :
    IsMaster (s.addNode j n) k ↔
      (k = j ∧ n.role = FlareRole.Master) ∨ (k ≠ j ∧ IsMaster s k) := by
  unfold IsMaster
  rw [lookupNode_addNode]
  by_cases h : k = j
  · subst h; simp
  · simp [h]

theorem isMaster_setPartition (s : FlareClusterState) (i : Nat) (p : FlarePartition) (k : String) :
    IsMaster (s.setPartition i p) k ↔ IsMaster s k := Iff.rfl

theorem isMaster_rebuild (s : FlareClusterState) (k : String) :
    IsMaster s.rebuildPartitionMap k ↔ IsMaster s k := Iff.rfl

/-- Every partition's slave list avoids `ex`. -/
def SlavesAvoid (ex : List String) (s : FlareClusterState) : Prop :=
  ∀ i part, (i, part) ∈ s.partitionMap → ∀ j, j ∈ part.slaves → j ∉ ex

theorem slavesAvoid_addNode {ex : List String} {s : FlareClusterState} (h : SlavesAvoid ex s)
    (j : String) (n : FlareNode) : SlavesAvoid ex (s.addNode j n) := h

theorem slavesAvoid_setPartition {ex : List String} {s : FlareClusterState} (h : SlavesAvoid ex s)
    (i : Nat) (p : FlarePartition) (hp : ∀ j, j ∈ p.slaves → j ∉ ex) :
    SlavesAvoid ex (s.setPartition i p) := by
  intro i' part hmem j hj
  simp only [FlareClusterState.setPartition, List.mem_cons, List.mem_filter] at hmem
  rcases hmem with heq | ⟨hm, _⟩
  · obtain ⟨_, rfl⟩ := Prod.mk.inj heq
    exact hp j hj
  · exact h i' part hm j hj

theorem findActiveSuccessor_mem (s : FlareClusterState) (part : FlarePartition) (pIdx : Int)
    (j : String) (h : findActiveSuccessor s part pIdx = some j) : j ∈ part.slaves := by
  unfold findActiveSuccessor at h
  exact List.mem_of_find?_eq_some h

/-- Writing a non-Master entry never makes any key a Master. -/
theorem noNew_addNode_nonMaster (ex : List String) (s : FlareClusterState) (key : String)
    (d : FlareNode) (hd : d.role ≠ FlareRole.Master) : NoNewMaster ex s (s.addNode key d) := by
  intro k _ hk
  rw [isMaster_addNode] at hk
  rcases hk with ⟨_, hr⟩ | ⟨_, hm⟩
  · exact absurd hr hd
  · exact hm

/-! ## Failover and drain (the one-map drain)

  Both promote `findActiveSuccessor s part pIdx`, a member of the partition's
  slave list. If no slave list holds a key of `ex`, no key of `ex` becomes a
  Master. -/

theorem failoverSingle_noNew {ex : List String} {s : FlareClusterState} (hav : SlavesAvoid ex s)
    (key : String) :
    NoNewMaster ex s (handleFailoverWithPromotionSingleKey s key) ∧
      SlavesAvoid ex (handleFailoverWithPromotionSingleKey s key) := by
  unfold handleFailoverWithPromotionSingleKey
  split
  · exact ⟨NoNewMaster.refl _ _, hav⟩
  · rename_i node _
    -- the demotion alone: only `key` changes, and it stops being a Master
    have hdem : ∀ d : FlareNode, d.role ≠ FlareRole.Master → NoNewMaster ex s (s.addNode key d) :=
      fun d hd => noNew_addNode_nonMaster ex s key d hd
    split
    · rename_i hrole
      simp only []
      split
      · exact ⟨hdem _ (by simp), hav⟩
      · rename_i idx part hfind
        split
        · exact ⟨hdem _ (by simp), hav⟩
        · rename_i slaveKey hsucc
          have hmemP := List.mem_of_find?_eq_some hfind
          have hmem := findActiveSuccessor_mem _ _ _ _ hsucc
          have hnot : slaveKey ∉ ex := hav _ _ hmemP _ hmem
          split
          · exact ⟨hdem _ (by simp), hav⟩
          · rename_i slaveNode hlk
            split
            · refine ⟨?_, ?_⟩
              · intro k hk hm
                rw [isMaster_setPartition, isMaster_addNode] at hm
                rcases hm with ⟨hkj, _⟩ | ⟨hkj, hm⟩
                · exact absurd (hkj ▸ hk) hnot
                · exact noNew_addNode_nonMaster ex s key _ (by simp) k hk hm
              · apply slavesAvoid_setPartition (slavesAvoid_addNode (slavesAvoid_addNode hav _ _) _ _)
                intro j hj
                exact hav _ _ hmemP j (List.mem_of_mem_tail hj)
            · exact ⟨hdem _ (by simp), hav⟩
    · exact ⟨hdem _ (by simp), hav⟩

theorem failover_noNew {ex : List String} (deadKeys : List String) :
    ∀ (s : FlareClusterState), SlavesAvoid ex s →
      NoNewMaster ex s (handleFailoverWithPromotion s deadKeys) := by
  unfold handleFailoverWithPromotion
  induction deadKeys with
  | nil => intro s _; exact NoNewMaster.refl _ _
  | cons hd tl ih =>
    intro s hav
    rw [List.foldl_cons]
    have h1 := failoverSingle_noNew hav hd
    exact NoNewMaster.trans h1.1 (ih _ h1.2)

theorem drainSingle_noNew {ex : List String} {s : FlareClusterState} (hav : SlavesAvoid ex s)
    (key : String) :
    NoNewMaster ex s (handleDrainWithPromotionSingleKey s key) ∧
      SlavesAvoid ex (handleDrainWithPromotionSingleKey s key) := by
  unfold handleDrainWithPromotionSingleKey
  split
  · exact ⟨NoNewMaster.refl _ _, hav⟩
  · rename_i node _
    split
    · rename_i hrole
      dsimp only
      split
      · exact ⟨NoNewMaster.refl _ _, hav⟩
      · rename_i idx part hfind
        split
        · exact ⟨NoNewMaster.refl _ _, hav⟩
        · rename_i slaveKey hsucc
          have hmemP := List.mem_of_find?_eq_some hfind
          have hmem := findActiveSuccessor_mem _ _ _ _ hsucc
          have hnot : slaveKey ∉ ex := hav _ _ hmemP _ hmem
          split
          · exact ⟨NoNewMaster.refl _ _, hav⟩
          · rename_i slaveNode hlk
            split
            · refine ⟨?_, ?_⟩
              · intro k hk hm
                rw [isMaster_setPartition, isMaster_addNode] at hm
                rcases hm with ⟨hkj, _⟩ | ⟨hkj, hm⟩
                · exact absurd (hkj ▸ hk) hnot
                · rw [isMaster_addNode] at hm
                  rcases hm with ⟨_, hr⟩ | ⟨_, hm⟩
                  · exact absurd hr (by simp)
                  · exact hm
              · apply slavesAvoid_setPartition (slavesAvoid_addNode (slavesAvoid_addNode hav _ _) _ _)
                intro j hj
                exact hav _ _ hmemP j (List.mem_of_mem_tail hj)
            · exact ⟨NoNewMaster.refl _ _, hav⟩
    · refine ⟨?_, hav⟩
      intro k _ hk
      rw [isMaster_addNode] at hk
      rcases hk with ⟨_, hr⟩ | ⟨_, hm⟩
      · exact absurd hr (by simp)
      · exact hm

theorem drain_noNew {ex : List String} (drainKeys : List String) :
    ∀ (s : FlareClusterState), SlavesAvoid ex s →
      NoNewMaster ex s (handleDrainWithPromotion s drainKeys) := by
  unfold handleDrainWithPromotion
  induction drainKeys with
  | nil => intro s _; exact NoNewMaster.refl _ _
  | cons hd tl ih =>
    intro s hav
    rw [List.foldl_cons]
    have h1 := drainSingle_noNew hav hd
    exact NoNewMaster.trans h1.1 (ih _ h1.2)


/-! ## The candidate shaping removes the excluded keys from every slave list -/

theorem shapeSlaves_avoid {ex' : List String} (ex ranked unproven : List String)
    (hsub : ∀ k, k ∈ ex' → k ∈ ex) (part : FlarePartition) :
    ∀ j, j ∈ (shapeSlaves ex ranked unproven part).slaves → j ∉ ex' := by
  intro j hj hjex
  have hex := hsub j hjex
  simp only [shapeSlaves, List.mem_append, List.mem_filter, Bool.not_eq_true', Bool.and_eq_true,
    Bool.not_eq_true', decide_eq_true_eq, Bool.not_eq_false'] at hj
  rcases hj with (⟨_, hk⟩ | ⟨hk, _⟩) | ⟨hk, _⟩
  · -- ranked ∩ kept
    simp [List.contains_iff_mem] at hk
    exact absurd hex (by simpa using hk.2)
  · simp [List.contains_iff_mem] at hk; exact hk.2 hex
  · simp [List.contains_iff_mem] at hk; exact hk.2 hex

theorem shapePromotionCandidates_avoid {ex' : List String} (ex ranked unproven : List String)
    (hsub : ∀ k, k ∈ ex' → k ∈ ex) (s : FlareClusterState) :
    SlavesAvoid ex' (shapePromotionCandidates ex ranked unproven s) := by
  unfold shapePromotionCandidates
  split
  · rename_i hall
    -- nothing is excluded: `ex'` is empty
    simp only [Bool.and_eq_true, List.isEmpty_iff] at hall
    intro i part _ j _ hj
    have := hsub j hj
    simp [hall.1.1] at this
  · intro i part hmem j hj
    simp only [List.mem_map] at hmem
    obtain ⟨⟨idx, p⟩, _, heq⟩ := hmem
    obtain ⟨_, rfl⟩ := Prod.mk.inj heq
    exact shapeSlaves_avoid ex ranked unproven hsub p j hj

theorem deprioritizeStandbySlaves_avoid {ex : List String} (sk : List String) {s : FlareClusterState}
    (h : SlavesAvoid ex s) : SlavesAvoid ex (deprioritizeStandbySlaves sk s) := by
  unfold deprioritizeStandbySlaves
  split
  · exact h
  · intro i part hmem j hj
    simp only [List.mem_map] at hmem
    obtain ⟨⟨idx, p⟩, hp, heq⟩ := hmem
    obtain ⟨_, rfl⟩ := Prod.mk.inj heq
    simp only [List.mem_append, List.mem_filter] at hj
    rcases hj with ⟨hj, _⟩ | ⟨hj, _⟩ <;> exact h idx p hp j hj

theorem deprioritizeStandbySlaves_noNew (ex sk : List String) (s : FlareClusterState) :
    NoNewMaster ex s (deprioritizeStandbySlaves sk s) :=
  NoNewMaster.of_nodeMap_eq (by rw [deprioritizeStandbySlaves_nodeMap])

/-- `failoverCandidates` cannot hand a refused key to the failover. -/
theorem failoverCandidates_avoid (g : SuccessorGates) (st : FlareClusterState) :
    SlavesAvoid (g.excluded st) (failoverCandidates g st) := by
  unfold failoverCandidates
  exact deprioritizeStandbySlaves_avoid _
    (shapePromotionCandidates_avoid _ _ _ (fun _ h => h) _)

theorem failoverCandidates_nodeMap (g : SuccessorGates) (st : FlareClusterState) :
    (failoverCandidates g st).nodeMap = st.nodeMap := by
  unfold failoverCandidates
  rw [deprioritizeStandbySlaves_nodeMap, shapePromotionCandidates_nodeMap]
  rfl


/-- The failover of the pass (`failoverCandidates`), for any dead keys. -/
theorem failoverOfPass_noNew (g : SuccessorGates) (cs : FlareClusterState) (ks : List String) :
    NoNewMaster (g.excluded cs) cs (handleFailoverWithPromotion (failoverCandidates g cs) ks) :=
  NoNewMaster.trans (NoNewMaster.of_nodeMap_eq (failoverCandidates_nodeMap g cs).symm)
    (failover_noNew ks _ (failoverCandidates_avoid g cs))

/-- One pass's `AfterHandleFailover` step (failover, then the one-map drain),
    read off `flareReconcileCore`: a key that the pass lists both as
    promotion-blocked (`PromotionEvidence` class not promotable) and as an
    unfit follower is not a new Master in the state the step leaves. -/
theorem afterHandleFailover_noNew (resp : K8sResponse) (s : FlareReconcileState)
    (cs ns : FlareClusterState) (hstep : s.reconcileStep = .AfterHandleFailover)
    (hns : (flareReconcileCore resp s cs).1.updatedClusterState = some ns) :
    NoNewMaster (s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·)) cs ns := by
  simp only [flareReconcileCore, hstep] at hns
  have hsubF : ∀ k, k ∈ s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·) →
      k ∈ s.successorGates.excluded cs := by
    intro k hk
    simp only [List.mem_filter] at hk
    simp [SuccessorGates.excluded, FlareReconcileState.successorGates, hk.1]
  have hsubD : ∀ k, k ∈ s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·) →
      k ∈ s.followUnfitKeys ++ s.followUnprovenKeys := by
    intro k hk
    simp only [List.mem_filter] at hk
    simp [hk.1]
  have hfail : NoNewMaster (s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·)) cs
      (if (s.failoverTriggered &&
            !(List.filter
                  (fun k ↦ !(unhealthyMastersKept (failoverCandidates s.successorGates cs) s.deadNodeKeys
                          s.unhealthyKeys s.successorGates.lagHeld).contains k)
                  s.deadNodeKeys).isEmpty) = true then
          handleFailoverWithPromotion (failoverCandidates s.successorGates cs)
            (List.filter
              (fun k ↦ !(unhealthyMastersKept (failoverCandidates s.successorGates cs) s.deadNodeKeys
                      s.unhealthyKeys s.successorGates.lagHeld).contains k)
              s.deadNodeKeys)
        else cs) := by
    split
    · exact (failoverOfPass_noNew _ _ _).mono hsubF
    · exact NoNewMaster.refl _ _
  generalize (if (s.failoverTriggered &&
            !(List.filter
                  (fun k ↦ !(unhealthyMastersKept (failoverCandidates s.successorGates cs) s.deadNodeKeys
                          s.unhealthyKeys s.successorGates.lagHeld).contains k)
                  s.deadNodeKeys).isEmpty) = true then
          handleFailoverWithPromotion (failoverCandidates s.successorGates cs)
            (List.filter
              (fun k ↦ !(unhealthyMastersKept (failoverCandidates s.successorGates cs) s.deadNodeKeys
                      s.unhealthyKeys s.successorGates.lagHeld).contains k)
              s.deadNodeKeys)
        else cs) = af at hns hfail
  have hns' := Option.some.inj hns
  split at hns'
  · subst hns'; exact hfail
  · subst hns'
    refine NoNewMaster.trans hfail ?_
    -- af -> af.rebuildPartitionMap -> shaped -> reordered -> drained
    have hav : SlavesAvoid (s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·))
        (deprioritizeStandbySlaves s.standbyNodeKeys
          (shapePromotionCandidates (s.followUnfitKeys ++ s.followUnprovenKeys) s.followRankedKeys []
            af.rebuildPartitionMap)) :=
      deprioritizeStandbySlaves_avoid _ (shapePromotionCandidates_avoid _ _ _ hsubD _)
    refine NoNewMaster.trans ?_ (drain_noNew s.drainNodeKeys _ hav)
    exact NoNewMaster.of_nodeMap_eq (by rw [deprioritizeStandbySlaves_nodeMap, shapePromotionCandidates_nodeMap]; rfl)


/-! ## The masterless refill -/

theorem orElse_nb {blocked : List String} {a : Option (String × FlareNode)}
    {f : Unit → Option (String × FlareNode)}
    (ha : ∀ x, a = some x → x.1 ∉ blocked) (hf : ∀ x, f () = some x → x.1 ∉ blocked)
    {x : String × FlareNode} (h : a.orElse f = some x) : x.1 ∉ blocked := by
  rw [Option.orElse_eq_some_iff] at h
  rcases h with h | ⟨_, h⟩
  · exact ha x h
  · exact hf x h

theorem firstRanked_nb {blocked : List String} (ranked : List String)
    (items : List (String × FlareNode)) (pred : String × FlareNode → Bool)
    (hp : ∀ kv, pred kv = true → kv.1 ∉ blocked) {x : String × FlareNode}
    (h : FailoverOrder.firstRanked ranked items pred = some x) : x.1 ∉ blocked := by
  unfold FailoverOrder.firstRanked at h
  obtain ⟨k, _, hk⟩ := List.exists_of_findSome?_eq_some h
  have hx := List.find?_some hk
  simp only [Bool.and_eq_true] at hx
  exact hp x hx.2

theorem find_nb {blocked : List String} (items : List (String × FlareNode))
    (pred : String × FlareNode → Bool)
    (hp : ∀ kv, pred kv = true → kv.1 ∉ blocked) {x : String × FlareNode}
    (h : items.find? pred = some x) : x.1 ∉ blocked :=
  hp x (List.find?_some h)

set_option hygiene false in
/-- Walks the refill's candidate expression (an `orElse` tree of `firstRanked`,
    `find?` and one `if`) and proves each leaf from its predicate. -/
syntax "nb_tac" : tactic

set_option hygiene false in
macro_rules
  | `(tactic| nb_tac) => `(tactic| first
      | exact firstRanked_nb _ _ _ (by intro kv hkv hb; simp [List.contains_iff_mem, hb] at hkv) h
      | exact find_nb _ _ (by intro kv hkv hb; simp [List.contains_iff_mem, hb] at hkv) h
      | (cases h)
      | (refine orElse_nb ?_ ?_ h <;> (clear h; intro x h; nb_tac))
      | (split at h <;> nb_tac))

theorem refill_noNew (state : FlareClusterState) (pIdx : Nat)
    (live standby dataBearing excluded : List String) (hold : Bool)
    (knownEmpty blocked : List String) (prefer : Option String) (ranked : List String) :
    NoNewMaster blocked state (promoteMasterlessPartition state pIdx live standby dataBearing excluded
      hold knownEmpty blocked prefer ranked) := by
  unfold promoteMasterlessPartition
  split
  · exact NoNewMaster.refl _ _
  · dsimp only
    split
    · rename_i kv hc
      have hQ : kv.1 ∉ blocked := by
        revert hc
        generalize kv = x
        cases prefer <;> dsimp only <;> (intro h; nb_tac)
      intro k hk hm
      rw [isMaster_addNode] at hm
      rcases hm with ⟨hkj, _⟩ | ⟨_, hm⟩
      · exact absurd (hkj ▸ hk) hQ
      · exact hm
    · exact NoNewMaster.refl _ _


/-- The refill over every partition, as `AfterAssignRoles` and the breaker's
    `RecoveryRefill` run it: `blocked` is `promotionBlockedKeys`. The wait
    (`holdEnabled`, `holdExpiredParts`) only decides WHEN the last-resort
    tier may act; the tier has the same `blocked` condition, so an expired
    wait does not seat a blocked copy. -/
theorem refills_noNew (state : FlareClusterState) (crd : FlareClusterView)
    (live standby dataBearing excluded : List String) (holdEnabled : Bool)
    (holdExpiredParts : List Nat) (knownEmpty blocked : List String)
    (holders : List (Nat × String)) (ranked : List String) :
    NoNewMaster blocked state (promoteMasterlessPartitions state crd live standby dataBearing excluded
      holdEnabled holdExpiredParts knownEmpty blocked holders ranked) := by
  unfold promoteMasterlessPartitions
  suffices hgen : ∀ (ps : List Nat) (acc : FlareClusterState),
      NoNewMaster blocked acc (ps.foldl (fun s pIdx => promoteMasterlessPartition s pIdx live standby
        dataBearing excluded (holdEnabled && !holdExpiredParts.contains pIdx) knownEmpty blocked
        (holders.lookup pIdx) ranked) acc) from hgen _ state
  intro ps
  induction ps with
  | nil => intro acc; exact NoNewMaster.refl _ _
  | cons hd tl ih =>
    intro acc
    rw [List.foldl_cons]
    exact NoNewMaster.trans (refill_noNew _ _ _ _ _ _ _ _ _ _ _) (ih _)


/-! ## Proxy assignment (`autoAssign`, `assignProxiesPure`)

  `autoAssign` promotes an Active slave found by `findActiveSlaveForPartition`
  (which skips `excluded`), or seats the proxy itself as master of a partition
  without one — and then only past `excludedKeys.contains nodeKey`. Two
  defensive branches seat the proxy when `lookupNode` disagrees with the entry
  the search found; they cannot be reached when the node map has no duplicate
  key (`KeysNodup`, which `addNode` keeps). -/

def KeysNodup (s : FlareClusterState) : Prop := (s.nodeMap.map Prod.fst).Nodup

theorem keysNodup_addNode {s : FlareClusterState} (h : KeysNodup s) (j : String) (n : FlareNode) :
    KeysNodup (s.addNode j n) := by
  unfold KeysNodup at *
  simp only [FlareClusterState.addNode, List.map_cons, List.nodup_cons, List.mem_map,
    List.mem_filter]
  refine ⟨?_, (List.Nodup.sublist (List.Sublist.map Prod.fst List.filter_sublist) h)⟩
  rintro ⟨⟨a, b⟩, ⟨_, hne⟩, rfl⟩
  simp at hne

theorem find_lookup (l : List (String × FlareNode)) (p : String × FlareNode → Bool)
    (hnd : (l.map Prod.fst).Nodup) {k : String} {n : FlareNode} (h : l.find? p = some (k, n)) :
    l.lookup k = some n := by
  induction l with
  | nil => simp at h
  | cons hd tl ih =>
    obtain ⟨a, b⟩ := hd
    simp only [List.map_cons, List.nodup_cons] at hnd
    simp only [List.find?_cons] at h
    split at h
    · simp at h
      obtain ⟨rfl, rfl⟩ := h
      simp [List.lookup]
    · have hmem := List.mem_of_find?_eq_some h
      have hka : (k == a) = false := by
        have : k ≠ a := fun hk => hnd.1 (hk ▸ List.mem_map.mpr ⟨(k, n), hmem, rfl⟩)
        simpa using this
      simp [List.lookup, hka, ih hnd.2 h]

theorem findActiveSlave_spec (s : FlareClusterState) (pIdx : Nat)
    (live standby excluded : List String) (key : String) (hnd : KeysNodup s)
    (h : Reconciler.findActiveSlaveForPartition s pIdx live standby excluded = some key) :
    key ∉ excluded ∧ ∃ n, s.lookupNode key = some n ∧ n.role = FlareRole.Slave ∧
      n.partition = Int.ofNat pIdx := by
  unfold Reconciler.findActiveSlaveForPartition at h
  have hfin : ∀ (p : String × FlareNode → Bool),
      (∀ kv, p kv = true → kv.2.role = FlareRole.Slave ∧ kv.2.partition = Int.ofNat pIdx ∧
        kv.1 ∉ excluded) →
      ∀ kv, s.nodeMap.find? p = some kv →
        kv.1 ∉ excluded ∧ ∃ n, s.lookupNode kv.1 = some n ∧ n.role = FlareRole.Slave ∧
          n.partition = Int.ofNat pIdx := by
    intro p hp kv hkv
    have hp' := hp kv (List.find?_some hkv)
    exact ⟨hp'.2.2, kv.2, find_lookup _ _ hnd (by simpa using hkv), hp'.1, hp'.2.1⟩
  have hcand : ∀ kv : String × FlareNode,
      (kv.2.role == FlareRole.Slave && kv.2.state == FlareState.Active
        && kv.2.partition == Int.ofNat pIdx && live.contains kv.1 && !excluded.contains kv.1) = true →
      kv.2.role = FlareRole.Slave ∧ kv.2.partition = Int.ofNat pIdx ∧ kv.1 ∉ excluded := by
    intro kv hkv
    simp only [Bool.and_eq_true, Bool.not_eq_true', List.contains_iff_mem] at hkv
    obtain ⟨⟨⟨⟨hr, _⟩, hp⟩, _⟩, hx⟩ := hkv
    refine ⟨?_, by simpa using hp, by simpa [List.contains_iff_mem] using hx⟩
    revert hr
    cases kv.2.role <;> decide
  rw [Option.orElse_eq_some_iff] at h
  rcases h with h | ⟨_, h⟩
  · rw [Option.map_eq_some_iff] at h
    obtain ⟨kv, hkv, rfl⟩ := h
    refine hfin _ (fun kv' h' => hcand kv' ?_) kv hkv
    exact (Bool.and_eq_true _ _ |>.mp h').1
  · rw [Option.map_eq_some_iff] at h
    obtain ⟨kv, hkv, rfl⟩ := h
    exact hfin _ (fun kv' h' => hcand kv' h') kv hkv


def AssignOk (ex : List String) (before after : FlareClusterState) : Prop :=
  NoNewMaster ex before after ∧ KeysNodup after

theorem autoAssign_spec (state : FlareClusterState) (crd : FlareClusterView) (nodeKey : String)
    (node : FlareNode) (live : List String) (zones : List (String × String))
    (excluded : List String) (hnd : KeysNodup state) (hn : node.role ≠ FlareRole.Master) :
    AssignOk excluded state (Reconciler.autoAssign state crd nodeKey node live zones excluded).1 := by
  unfold Reconciler.autoAssign
  dsimp only
  have hclean : NoNewMaster excluded state (state.addNode nodeKey node).rebuildPartitionMap :=
    noNew_addNode_nonMaster _ _ _ _ hn
  have hcnd : KeysNodup (state.addNode nodeKey node).rebuildPartitionMap := keysNodup_addNode hnd _ _
  generalize (state.addNode nodeKey node).rebuildPartitionMap = cs at hcnd hclean
  have hstate : AssignOk excluded state state := ⟨NoNewMaster.refl _ _, hnd⟩
  have hcs : AssignOk excluded state cs := ⟨hclean, hcnd⟩
  have hseatNone : ∀ (d : FlareNode) (hd : d.role ≠ FlareRole.Master) (i : Nat) (q : FlarePartition),
      AssignOk excluded state ((cs.addNode nodeKey d).setPartition i q) := by
    intro d hd i q
    exact ⟨NoNewMaster.trans hclean (noNew_addNode_nonMaster _ _ _ _ hd), keysNodup_addNode hcnd _ _⟩
  split
  · rename_i pIdx hp
    split
    · rename_i slaveKey hs
      obtain ⟨hnot, sn, hsn, hrole, hpart⟩ := findActiveSlave_spec _ _ _ _ _ _ hcnd hs
      rw [hsn]
      dsimp only
      split
      · refine ⟨?_, keysNodup_addNode (keysNodup_addNode hcnd _ _) _ _⟩
        intro k hk hm
        rw [isMaster_rebuild, isMaster_addNode] at hm
        rcases hm with ⟨_, hr⟩ | ⟨_, hm⟩
        · exact absurd hr (by simp)
        · rw [isMaster_addNode] at hm
          rcases hm with ⟨hks, _⟩ | ⟨_, hm⟩
          · exact absurd (hks ▸ hk) hnot
          · exact hclean k hk hm
      · rename_i hne
        exact absurd (by rw [hrole, hpart]; simp only [Bool.and_eq_true]; exact ⟨by decide, beq_self_eq_true _⟩) hne
    · split
      · exact hstate
      · split
        · exact hstate
        · split
          · exact hstate
          · rename_i _ hex _
            refine ⟨?_, keysNodup_addNode hcnd _ _⟩
            intro k hk hm
            rw [isMaster_setPartition, isMaster_addNode] at hm
            rcases hm with ⟨hkn, _⟩ | ⟨_, hm⟩
            · subst hkn
              exact absurd (List.contains_iff_mem.mpr hk) (by simpa using hex)
            · exact hclean k hk hm
  · split
    · exact hseatNone _ (by simp) _ _
    · exact hcs


theorem assignProxies_noNew (state : FlareClusterState) (crd : FlareClusterView)
    (live : List String) (zones : List (String × String)) (term excluded : List String)
    (hnd : KeysNodup state) :
    AssignOk excluded state (assignProxiesPure state crd live zones term excluded) := by
  unfold assignProxiesPure
  suffices hgen : ∀ (l : List (String × FlareNode)) (acc : FlareClusterState),
      AssignOk excluded state acc →
      AssignOk excluded state (l.foldl (fun currentState (kv : String × FlareNode) =>
        if (kv.2.role == FlareRole.Proxy && kv.2.state != FlareState.Down
            && !term.contains kv.1) = true then
          (Reconciler.autoAssign currentState crd kv.1 kv.2 live zones excluded).1
        else currentState) acc) from hgen _ state ⟨NoNewMaster.refl _ _, hnd⟩
  intro l
  induction l with
  | nil => intro acc h; exact h
  | cons hd tl ih =>
    intro acc h
    rw [List.foldl_cons]
    apply ih
    split
    · rename_i hcond
      have hrole : hd.2.role ≠ FlareRole.Master := by
        have := (Bool.and_eq_true _ _ |>.mp ((Bool.and_eq_true _ _ |>.mp hcond).1)).1
        revert this
        cases hd.2.role <;> decide
      have hs := autoAssign_spec acc crd hd.1 hd.2 live zones excluded h.2 hrole
      exact ⟨NoNewMaster.trans h.1 hs.1, hs.2⟩
    · exact h


theorem zoneRepairSwap_noNew (ex : List String) (s : FlareClusterState) (sKey dKey : String) :
    NoNewMaster ex s (Reconciler.applyZoneRepairSwap s sKey dKey) := by
  unfold Reconciler.applyZoneRepairSwap
  split
  · rename_i sN dN _ _
    split
    · rename_i hroles
      have hs : sN.role ≠ FlareRole.Master := by
        have := (Bool.and_eq_true _ _ |>.mp hroles).1
        revert this; cases sN.role <;> decide
      have hd : dN.role ≠ FlareRole.Master := by
        have := (Bool.and_eq_true _ _ |>.mp hroles).2
        revert this; cases dN.role <;> decide
      exact NoNewMaster.trans
        (noNew_addNode_nonMaster ex s sKey
          { sN with partition := dN.partition, state := FlareState.Prepare, balance := 0 } hs)
        (NoNewMaster.trans
          (noNew_addNode_nonMaster ex _ dKey
            { dN with partition := sN.partition, state := FlareState.Prepare, balance := 0 } hd)
          (NoNewMaster.of_nodeMap_eq rfl))
    · exact NoNewMaster.refl _ _
  · exact NoNewMaster.refl _ _

/-- The `AfterAssignRoles` step (proxy assignment, masterless refill, zone
    repair swap): a key listed as unfit AND promotion-blocked is not a new
    Master. `hnd`: the node map of the state the step starts from has no
    duplicate key (`addNode` keeps it). -/
theorem afterAssignRoles_noNew (resp : K8sResponse) (s : FlareReconcileState)
    (cs ns st : FlareClusterState) (hstep : s.reconcileStep = .AfterAssignRoles)
    (hst : s.updatedClusterState = some st) (hnd : KeysNodup st)
    (hns : (flareReconcileCore resp s cs).1.updatedClusterState = some ns) :
    NoNewMaster (s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·)) st ns := by
  cases hcrd : s.cachedCrd with
  | none =>
    simp only [flareReconcileCore, hstep, hst, hcrd] at hns
    have := Option.some.inj hns
    subst this
    exact NoNewMaster.refl _ _
  | some crd =>
    simp only [flareReconcileCore, hstep, hst, hcrd] at hns
    have h1 := (assignProxies_noNew st crd s.livePodKeys s.podZones
      (s.terminatingKeys ++ s.repairHeldKeys) s.followUnfitKeys hnd).1
    have h2 := refills_noNew (assignProxiesPure st crd s.livePodKeys s.podZones
      (s.terminatingKeys ++ s.repairHeldKeys) s.followUnfitKeys) crd s.livePodKeys s.standbyNodeKeys
      s.dataBearingKeys s.followUnfitKeys s.followHoldEnabled s.followHoldExpiredParts s.knownEmptyKeys
      s.promotionBlockedKeys s.historyHolders s.followRankedKeys
    have h12 := NoNewMaster.trans
      (h1.mono (ex' := s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·))
        (fun k hk => (List.mem_filter.mp hk).1))
      (h2.mono (fun k hk => by simpa using (List.mem_filter.mp hk).2))
    have hns' := Option.some.inj hns
    split at hns'
    · rename_i sK dK _
      subst hns'
      exact NoNewMaster.trans h12 (zoneRepairSwap_noNew _ _ _ _)
    · subst hns'
      exact h12


/-- The breaker's `RecoveryRefill` pass (failover of the dead keys, then the
    refill). `hnone`: the pass starts without a computed state, as `reconcileOnce` builds it. -/
theorem recoveryRefill_noNew (resp : K8sResponse) (s : FlareReconcileState)
    (cs ns : FlareClusterState) (hstep : s.reconcileStep = .RecoveryRefill)
    (hnone : s.updatedClusterState = none)
    (hns : (flareReconcileCore resp s cs).1.updatedClusterState = some ns) :
    NoNewMaster (s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·)) cs ns := by
  cases hcrd : s.cachedCrd with
  | none =>
    simp only [flareReconcileCore, hstep, hcrd, hnone] at hns
    cases hns
  | some crd =>
    simp only [flareReconcileCore, hstep, hcrd] at hns
    have hsubF : ∀ k, k ∈ s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·) →
        k ∈ s.successorGates.excluded cs := by
      intro k hk
      simp only [List.mem_filter] at hk
      simp [SuccessorGates.excluded, FlareReconcileState.successorGates, hk.1]
    have h2 := (refills_noNew
      (if (s.deadNodeKeys.filter (fun k => !(unhealthyMastersKept (failoverCandidates s.successorGates cs)
          s.deadNodeKeys s.unhealthyKeys s.successorGates.lagHeld).contains k)).isEmpty = true then cs
       else handleFailoverWithPromotion (failoverCandidates s.successorGates cs)
          (s.deadNodeKeys.filter (fun k => !(unhealthyMastersKept (failoverCandidates s.successorGates cs)
            s.deadNodeKeys s.unhealthyKeys s.successorGates.lagHeld).contains k)))
      crd s.livePodKeys [] s.dataBearingKeys s.followUnfitKeys s.followHoldEnabled s.followHoldExpiredParts
      s.knownEmptyKeys s.promotionBlockedKeys s.historyHolders s.followRankedKeys).mono
        (ex' := s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·))
        (fun k hk => by simpa using (List.mem_filter.mp hk).2)
    have h1 : NoNewMaster (s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·)) cs
        (if (s.deadNodeKeys.filter (fun k => !(unhealthyMastersKept (failoverCandidates s.successorGates cs)
            s.deadNodeKeys s.unhealthyKeys s.successorGates.lagHeld).contains k)).isEmpty = true then cs
         else handleFailoverWithPromotion (failoverCandidates s.successorGates cs)
            (s.deadNodeKeys.filter (fun k => !(unhealthyMastersKept (failoverCandidates s.successorGates cs)
              s.deadNodeKeys s.unhealthyKeys s.successorGates.lagHeld).contains k))) := by
      split
      · exact NoNewMaster.refl _ _
      · exact (failoverOfPass_noNew _ _ _).mono hsubF
    have := Option.some.inj hns
    subst this
    exact NoNewMaster.trans h1 h2


/-! ## The classification and its gates (pure parts) -/

/-- A class that no promotion may seat: `forbidden` (and, as the pass treats
    it identically, `unknown`) — everything not `promotable`. -/
theorem forbidden_not_promotable (w : String) : (Class.forbidden w).promotable = false := rfl
theorem forbidden_not_normal (w : String) : (Class.forbidden w).normal = false := rfl

/-- Markers dominate: a complete, valid reply with a forbidden marker is
    FORBIDDEN, whatever R3 said, whatever the map says (a rebuilding, merging,
    parked, quarantined, corrupted, unresolved-switch copy; R3's re-validation
    or confirmed different history against a present master). -/
theorem classify_marker_forbidden (out : String) (o : Observed) (w : String)
    (hc : (parseStats out).complete = true) (hi : (parseStats out).invalid = [])
    (hm : (parseStats out).forbiddenMarker o.partitionHasMaster = some w) :
    classify (some out) o = .forbidden w := by
  unfold classify
  simp only [hc, hi, hm]
  simp

/-- The converse: a reply `classify` lets through (promotable) is complete,
    valid and carries no forbidden marker. -/
theorem classify_promotable_marker_free (out : String) (o : Observed)
    (h : (classify (some out) o).promotable = true) :
    (parseStats out).complete = true ∧ (parseStats out).invalid = [] ∧
      (parseStats out).forbiddenMarker o.partitionHasMaster = none := by
  refine Classical.byContradiction fun this => ?_
  by_cases hc : (parseStats out).complete = true
  · by_cases hi : (parseStats out).invalid = []
    · cases hm : (parseStats out).forbiddenMarker o.partitionHasMaster with
      | none => exact this ⟨hc, hi, hm⟩
      | some w =>
        rw [classify_marker_forbidden out o w hc hi hm] at h
        simp [Class.promotable] at h
    · have : classify (some out) o = .unknown s!"invalid value(s) reported for {(parseStats out).invalid}" := by
        unfold classify; simp [hc]
        intro hemp; exact absurd hemp hi
      rw [this] at h; simp [Class.promotable] at h
  · have : classify (some out) o = .unknown "stats incomplete" := by
      unfold classify; simp [hc]
    rw [this] at h; simp [Class.promotable] at h

/-- A reading that failed is `unknown`, never promotable. -/
theorem classify_unreadable (o : Observed) : (classify none o).promotable = false := rfl

/-! The commit layer (`commitChecked`, the handover precheck): the pure gates
    refuse a forbidden class. -/

theorem commitTimeAllows_forbidden (w : String) : commitTimeAllows (.forbidden w) = false := rfl
theorem handoverCommitAllows_forbidden (w : String) : handoverCommitAllows (.forbidden w) = false := rfl
theorem handoverAccepts_forbidden (w : String) (b : Binding) :
    handoverAccepts (.forbidden w) b = false := by
  have h : (Class.forbidden w == Class.eligible) = false := rfl
  simp [handoverAccepts, h]

theorem handoverAccepts_eligible (c : Class) (b : Binding) (h : handoverAccepts c b = true) :
    c = .eligible := by
  simp only [handoverAccepts, Bool.and_eq_true] at h
  have h1 := h.1
  cases c with
  | eligible => rfl
  | lagging => exact nomatch h1
  | legacy => exact nomatch h1
  | empty => exact nomatch h1
  | forbidden _ => exact nomatch h1
  | unknown _ => exact nomatch h1

theorem commitAllows_promotable (cls : Option Class) (read now : Binding)
    (h : (commitAllows cls read now).1 = true) : ∃ c, cls = some c ∧ c.promotable = true := by
  unfold commitAllows at h
  cases cls with
  | none => simp at h
  | some c =>
    refine ⟨c, rfl, Classical.byContradiction fun hp => ?_⟩
    have hp' : c.promotable = false := by simpa using hp
    simp [hp'] at h

theorem commitAllows_forbidden (w : String) (read now : Binding) :
    (commitAllows (some (.forbidden w)) read now).1 = false := by
  cases h : (commitAllows (some (.forbidden w)) read now).1 with
  | false => rfl
  | true =>
    obtain ⟨c, hc, hp⟩ := commitAllows_promotable _ _ _ h
    cases hc
    simp [Class.promotable] at hp

theorem reclassifyAllows_promotable (passClass fresh : Class)
    (h : (reclassifyAllows passClass fresh).1 = true) :
    fresh.promotable = true ∧ (fresh == passClass) = true := by
  unfold reclassifyAllows at h
  by_cases hp : fresh.promotable = true
  · refine ⟨hp, ?_⟩
    cases hb : (fresh == passClass) with
    | true => rfl
    | false =>
      have : (fresh != passClass) = true := by simp [bne, hb]
      simp [hp, this] at h
  · simp at hp
    simp [hp] at h

theorem reclassifyAllows_forbidden_fresh (passClass : Class) (w : String) :
    (reclassifyAllows passClass (.forbidden w)).1 = false := by
  cases h : (reclassifyAllows passClass (.forbidden w)).1 with
  | false => rfl
  | true =>
    have := (reclassifyAllows_promotable _ _ h).1
    simp [Class.promotable] at this

/-- A key whose pass class is forbidden cannot pass the commit's re-read
    either: the re-read class must be promotable and equal the pass class. -/
theorem reclassifyAllows_forbidden_pass (w : String) (fresh : Class) :
    (reclassifyAllows (.forbidden w) fresh).1 = false := by
  cases h : (reclassifyAllows (.forbidden w) fresh).1 with
  | false => rfl
  | true =>
    obtain ⟨hp, heq⟩ := reclassifyAllows_promotable _ _ h
    cases fresh with
    | eligible => exact nomatch heq
    | lagging => exact nomatch heq
    | legacy => exact nomatch heq
    | empty => exact nomatch heq
    | forbidden _ => simp [Class.promotable] at hp
    | unknown _ => simp [Class.promotable] at hp

/-! ## The pass's gates carry every not-promotable class -/

theorem mem_blockedKeys {ev : List (String × Class × Binding)} {k : String} {c : Class} {b : Binding}
    (hmem : (k, c, b) ∈ ev) (hc : c.promotable = false) : k ∈ blockedKeys ev := by
  unfold blockedKeys
  rw [List.mem_filterMap]
  exact ⟨(k, c, b), hmem, by simp [hc]⟩

theorem mem_notNormalKeys {ev : List (String × Class × Binding)} {k : String} {c : Class} {b : Binding}
    (hmem : (k, c, b) ∈ ev) (hc : c.normal = false) : k ∈ notNormalKeys ev := by
  unfold notNormalKeys
  rw [List.mem_filterMap]
  exact ⟨(k, c, b), hmem, by simp [hc]⟩

theorem promotable_false_normal_false (c : Class) (h : c.promotable = false) : c.normal = false := by
  cases c <;> simp_all [Class.promotable, Class.normal]

theorem mem_withheldKeys {ev : List (String × Class × Binding)} {k : String} {c : Class} {b : Binding}
    (r3 : List String) (hmem : (k, c, b) ∈ ev) (hc : c.normal = false) :
    k ∈ withheldKeys r3 ev := by
  unfold withheldKeys
  by_cases hk : k ∈ r3
  · exact List.mem_append_left _ hk
  · exact List.mem_append_right _ (List.mem_filter.mpr ⟨mem_notNormalKeys hmem hc, by simpa using hk⟩)

theorem mem_unfitKeys (clsUnfit notReadyActive sourceIneligible : List String) (k : String)
    (hk : k ∈ sourceIneligible) : k ∈ unfitKeys clsUnfit notReadyActive sourceIneligible := by
  unfold unfitKeys
  by_cases h : k ∈ clsUnfit
  · exact List.mem_append_left _ h
  · exact List.mem_append_right _ (List.mem_filter.mpr ⟨List.mem_append_right _ hk, by simpa using h⟩)

/-- What a pass's gates are, as Main builds them from the pass's evidence
    (`PromotionEvidence.blockedKeys`, `unfitKeys`, `withheldKeys` are the very
    functions Main calls for the `PodListResponse`). -/
structure PassGates (s : FlareReconcileState) (ev : List (String × Class × Binding)) : Prop where
  blocked : s.promotionBlockedKeys = blockedKeys ev
  unfit : ∃ clsUnfit notReadyActive r3, s.followUnfitKeys = unfitKeys clsUnfit notReadyActive (withheldKeys r3 ev)

/-- A key the pass's evidence classifies as not promotable (forbidden, in
    particular) is in BOTH gate lists the promotion paths read. -/
theorem notPromotable_gated {s : FlareReconcileState} {ev : List (String × Class × Binding)}
    (hg : PassGates s ev) {k : String} {c : Class} {b : Binding} (hmem : (k, c, b) ∈ ev)
    (hc : c.promotable = false) :
    k ∈ s.followUnfitKeys.filter (s.promotionBlockedKeys.contains ·) := by
  obtain ⟨cu, nra, r3, hu⟩ := hg.unfit
  refine List.mem_filter.mpr ⟨?_, ?_⟩
  · rw [hu]
    exact mem_unfitKeys _ _ _ _ (mem_withheldKeys r3 hmem (promotable_false_normal_false c hc))
  · rw [hg.blocked]
    simpa using mem_blockedKeys hmem hc

/-! ## The one theorem -/

/-- THE THEOREM. Take a pass whose gates are built from its evidence
    (`PassGates`) and a key whose evidence class is `forbidden` (more
    generally, not promotable). In every step of the reconcile FSM that can
    seat a master — failover and the one-map drain (`AfterHandleFailover`),
    proxy assignment, the masterless refill with its wait expired or not, and
    the zone swap (`AfterAssignRoles`), the breaker's `RecoveryRefill` — the
    key is a Master in the state the step produces only if it already was one
    in the state the step started from. -/
theorem forbidden_never_promoted {s : FlareReconcileState} {ev : List (String × Class × Binding)}
    (hg : PassGates s ev) {k : String} {w : String} {b : Binding}
    (hmem : (k, .forbidden w, b) ∈ ev) :
    (∀ (resp : K8sResponse) (cs ns : FlareClusterState), s.reconcileStep = .AfterHandleFailover →
        (flareReconcileCore resp s cs).1.updatedClusterState = some ns →
        IsMaster ns k → IsMaster cs k) ∧
    (∀ (resp : K8sResponse) (cs ns st : FlareClusterState), s.reconcileStep = .AfterAssignRoles →
        s.updatedClusterState = some st → KeysNodup st →
        (flareReconcileCore resp s cs).1.updatedClusterState = some ns →
        IsMaster ns k → IsMaster st k) ∧
    (∀ (resp : K8sResponse) (cs ns : FlareClusterState), s.reconcileStep = .RecoveryRefill →
        s.updatedClusterState = none →
        (flareReconcileCore resp s cs).1.updatedClusterState = some ns →
        IsMaster ns k → IsMaster cs k) := by
  have hk := notPromotable_gated hg hmem (forbidden_not_promotable w)
  refine ⟨?_, ?_, ?_⟩
  · intro resp cs ns hstep hns
    exact afterHandleFailover_noNew resp s cs ns hstep hns k hk
  · intro resp cs ns st hstep hst hnd hns
    exact afterAssignRoles_noNew resp s cs ns st hstep hst hnd hns k hk
  · intro resp cs ns hstep hnone hns
    exact recoveryRefill_noNew resp s cs ns hstep hnone hns k hk


/-! ## The ordered handover's successor -/

/-- The handover leaves `requested` for the demote only when the successor's
    precheck class was accepted (`Obs.successorR3`, which Main sets from
    `PromotionEvidence.handoverAccepts`'s class test `== .eligible`). -/
theorem handover_demote_requires_r3 (cfg : Handover.Config) (e : Handover.Entry) (o : Handover.Obs)
    (hreq : e.phase = .requested) (h : (Handover.step cfg e o).1.phase = .demoting) :
    o.successorR3 = true := by
  unfold Handover.step at h
  simp only [hreq] at h
  split at h
  · exact nomatch h
  · split at h
    · rename_i hready
      simp only [Bool.and_eq_true] at hready
      exact hready.1.1.1.1.2
    · split at h
      · exact nomatch h
      · rw [hreq] at h
        exact nomatch h

end FlareOperator.PromotionForbiddenProofs
