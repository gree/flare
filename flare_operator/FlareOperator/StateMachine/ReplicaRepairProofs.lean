/-
  StateMachine/ReplicaRepairProofs.lean — proofs about the replica-repair
  ledger (ReplicaRepair.lean), FORMAL_VERIFICATION §4 #8 / SC-03 6.

  I.  PERSISTENCE ROUND TRIP (of the Json tree). `Phase`, `Entry` and `Ledger`
      survive `toJson` → `fromJson?` EXACTLY (`fromJson? (toJson x) = some x`),
      so every entry field and every counter baseline (`counterKey` ↦ value,
      `initialized`) is what `fromJson?` reads back from the tree `toJson`
      built. Lean's core has no lemma about `Json.mkObj` / `getObjVal?` (an
      `RBNode` red-black tree), so part 1 proves the one that is needed: on an
      object built by `mkObj` from distinct keys, `getObjVal? k` is the
      association-list lookup of `k`.
  II. ACCOUNTING. `observeCore` fed the same cumulative counters twice yields no
      new drops the second time and does not change the ledger.
  III. `observe` (what Main calls) over the boot id coming and going: counters
      are keyed `master|dest|boot` when the boot id reads and `master|dest` when
      it does not. A pass that cannot read the boot id while the ledger holds
      the master's boot-keyed counters is not observed; a boot-less counter is
      the previous value for the same master once the boot id reads
      (`legacyPrev`). A master key or destination containing `|` is not
      accounted, so the keys always split back (`observe_new_keys`).
      `no_repeat_request`: after one accounted pass, any sequence of passes
      reading `none` or the same `some b`, with an operator restart (the Json
      tree round trip) before each, makes no request.

  NOT proved here: the text round trip of `Json.compress`/`Json.parse`, the
  kubectl read/write of the status, and the order and IO of Main's calls
  (Main reads the stats, calls `observe`, then `request` per drop). Each pass
  must name distinct destinations (`Nodup`), as a stats reply does.

  Nothing beyond Lean's standard foundations is used, and nothing is evaluated natively.
-/
import FlareOperator.StateMachine.ReplicaRepair

namespace FlareOperator.ReplicaRepair.Proofs

open Lean
open FlareOperator.ReplicaRepair

-- ═══════════════════════════════════════════════════════════════════════
-- 1. `Json.mkObj` lookup
-- ═══════════════════════════════════════════════════════════════════════

abbrev T := RBNode String (fun _ => Json)

def pairs : T → List (String × Json)
  | .leaf => []
  | .node _ l k v r => pairs l ++ (k, v) :: pairs r

/-- sorted insertion into a strictly sorted association list -/
def insertL (k : String) (v : Json) : List (String × Json) → List (String × Json)
  | [] => [(k, v)]
  | (k', v') :: xs =>
    if k < k' then (k, v) :: (k', v') :: xs
    else if k = k' then (k, v) :: xs
    else (k', v') :: insertL k v xs

def Sorted (l : List (String × Json)) : Prop := l.Pairwise (fun a b => a.1 < b.1)

theorem cmp_lt {a b : String} : compare a b = .lt ↔ a < b := by
  unfold compare instOrdString compareOfLessAndEq
  by_cases h : a < b <;> by_cases h2 : a = b <;> simp [h, h2]

theorem cmp_eq {a b : String} : compare a b = .eq ↔ a = b := by
  unfold compare instOrdString compareOfLessAndEq
  by_cases h : a < b
  · simp [h]; exact String.ne_of_lt h
  · by_cases h2 : a = b <;> simp [h, h2]

theorem cmp_gt {a b : String} : compare a b = .gt ↔ b < a := by
  unfold compare instOrdString compareOfLessAndEq
  by_cases h : a < b
  · simp [h]; exact String.lt_asymm h
  · by_cases h2 : a = b
    · simp [h, h2]
    · simp [h, h2]
      by_cases h3 : b < a
      · exact h3
      · exfalso
        have h4 : a ≤ b := h3
        have h5 : b ≤ a := h
        exact h2 (String.le_antisymm h4 h5)

theorem lookup_append {α β} [BEq α] (a : α) (A B : List (α × β)) :
    (A ++ B).lookup a = (A.lookup a).or (B.lookup a) := by
  induction A with
  | nil => simp [List.lookup]
  | cons p A ih =>
    obtain ⟨k, v⟩ := p
    simp only [List.cons_append, List.lookup]
    cases a == k <;> simp [ih]

theorem lookup_none_of {β} (k : String) (L : List (String × β)) (h : ∀ p ∈ L, p.1 ≠ k) :
    L.lookup k = none :=
  by
  rw [List.lookup_eq_none_iff]
  intro p hp
  have := h p hp
  simp only [bne_iff_ne, ne_eq]
  exact fun he => this he.symm

theorem find_eq : ∀ (t : T) (k : String), Sorted (pairs t) →
    t.find compare k = (pairs t).lookup k := by
  intro t
  induction t with
  | leaf => intro k _; simp [RBNode.find, pairs]
  | node c l k' v r ihl ihr =>
    intro k hs
    simp only [pairs, Sorted, List.pairwise_append, List.pairwise_cons, List.mem_cons] at hs
    obtain ⟨hl, ⟨hk, hr⟩, hlr⟩ := hs
    simp only [RBNode.find, pairs, lookup_append]
    have hl' : Sorted (pairs l) := hl
    have hr' : Sorted (pairs r) := hr
    split
    next h =>
      have hlt : k < k' := cmp_lt.mp h
      rw [ihl k hl']
      have : ((k', v) :: pairs r).lookup k = none := by
        apply lookup_none_of
        intro p hp
        simp only [List.mem_cons] at hp
        rcases hp with rfl | hp
        · exact (String.ne_of_lt hlt).symm
        · exact fun he => (String.lt_asymm hlt) (he ▸ hk p hp)
      rw [this]; simp
    next h =>
      have hgt : k' < k := cmp_gt.mp h
      rw [ihr k hr']
      have : (pairs l).lookup k = none := by
        apply lookup_none_of
        intro p hp he
        exact String.lt_asymm hgt (he ▸ hlr p hp (k', v) (Or.inl rfl))
      rw [this]
      have : (k == k') = false := by simpa using (String.ne_of_lt hgt).symm
      simp [List.lookup, this]
    next h =>
      have heq : k = k' := cmp_eq.mp h
      subst heq
      have : (pairs l).lookup k = none := by
        apply lookup_none_of
        intro p hp he
        exact String.lt_irrefl _ (he ▸ hlr p hp (k, v) (Or.inl rfl))
      rw [this]; simp [List.lookup]


theorem insertL_mem (k : String) (v : Json) (l : List (String × Json)) (p : String × Json)
    (h : p ∈ insertL k v l) : p = (k, v) ∨ p ∈ l := by
  induction l with
  | nil => simp [insertL] at h; exact Or.inl h
  | cons q l ih =>
    obtain ⟨k', v'⟩ := q
    unfold insertL at h
    split at h
    · simp at h; rcases h with h | h | h <;> simp [h]
    · split at h
      · simp at h; rcases h with h | h <;> simp [h]
      · simp at h
        rcases h with h | h
        · simp [h]
        · rcases ih h with h | h <;> simp [h]

theorem insertL_sorted (k : String) (v : Json) : ∀ (l : List (String × Json)),
    Sorted l → Sorted (insertL k v l) := by
  intro l
  induction l with
  | nil => intro _; simp [insertL, Sorted]
  | cons q l ih =>
    obtain ⟨k', v'⟩ := q
    intro hs
    simp only [Sorted, List.pairwise_cons] at hs
    obtain ⟨hq, hl⟩ := hs
    unfold insertL
    split
    next hlt =>
      refine List.pairwise_cons.mpr ⟨?_, List.pairwise_cons.mpr ⟨hq, hl⟩⟩
      intro a ha
      rcases List.mem_cons.mp ha with rfl | ha
      · exact hlt
      · exact String.lt_trans hlt (hq a ha)
    next hnlt =>
      split
      next heq =>
        subst heq
        simp only [Sorted, List.pairwise_cons]
        exact ⟨hq, hl⟩
      next hne =>
        have hgt : k' < k := by
          by_cases h3 : k' < k
          · exact h3
          · exfalso
            have h4 : k ≤ k' := h3
            have h5 : k' ≤ k := hnlt
            exact hne (String.le_antisymm h4 h5)
        simp only [Sorted, List.pairwise_cons]
        refine ⟨?_, ih hl⟩
        intro a ha
        rcases insertL_mem k v l a ha with rfl | ha
        · exact hgt
        · exact hq a ha


theorem lookup_insertL_self (k : String) (v : Json) : ∀ (l : List (String × Json)),
    (insertL k v l).lookup k = some v := by
  intro l
  induction l with
  | nil => simp [insertL]
  | cons q l ih =>
    obtain ⟨k', v'⟩ := q
    unfold insertL
    split
    · simp
    · split
      · simp
      · next hne =>
        have : (k == k') = false := by simpa using hne
        simp [List.lookup, this, ih]

theorem lookup_insertL_ne (k : String) (v : Json) (k2 : String) (h : k2 ≠ k) :
    ∀ (l : List (String × Json)), (insertL k v l).lookup k2 = l.lookup k2 := by
  have hb : (k2 == k) = false := by simpa using h
  intro l
  induction l with
  | nil => simp [insertL, List.lookup, hb]
  | cons q l ih =>
    obtain ⟨k', v'⟩ := q
    unfold insertL
    split
    · simp [List.lookup, hb]
    · split
      · next heq => subst heq; simp [List.lookup, hb]
      · simp [List.lookup, ih]

theorem insertL_append_lt (k : String) (v : Json) (ky : String) (vy : Json) (hk : k < ky)
    (B : List (String × Json)) : ∀ (A : List (String × Json)),
    insertL k v (A ++ (ky, vy) :: B) = insertL k v A ++ (ky, vy) :: B := by
  intro A
  induction A with
  | nil => simp [insertL, hk]
  | cons q A ih =>
    obtain ⟨k', v'⟩ := q
    simp only [List.cons_append, insertL]
    split
    · rfl
    · split
      · rfl
      · simp [ih]

theorem insertL_append_gt (k : String) (v : Json) (ky : String) (vy : Json) (hk : ky < k)
    (B : List (String × Json)) : ∀ (A : List (String × Json)), (∀ p ∈ A, p.1 < k) →
    insertL k v (A ++ (ky, vy) :: B) = A ++ (ky, vy) :: insertL k v B := by
  intro A
  induction A with
  | nil =>
    intro _
    have h1 : ¬ k < ky := String.lt_asymm hk
    have h2 : k ≠ ky := fun h => String.lt_irrefl _ (h ▸ hk)
    simp [insertL, h1, h2]
  | cons q A ih =>
    intro hA
    obtain ⟨k', v'⟩ := q
    have h0 : k' < k := hA (k', v') (by simp)
    have h1 : ¬ k < k' := String.lt_asymm h0
    have h2 : k ≠ k' := fun h => String.lt_irrefl _ (h ▸ h0)
    simp only [List.cons_append, insertL, h1, h2, if_false]
    rw [ih (fun p hp => hA p (by simp [hp]))]

theorem insertL_append_eq (k : String) (v : Json) (vy : Json)
    (B : List (String × Json)) : ∀ (A : List (String × Json)), (∀ p ∈ A, p.1 < k) →
    insertL k v (A ++ (k, vy) :: B) = A ++ (k, v) :: B := by
  intro A
  induction A with
  | nil => intro _; simp [insertL]
  | cons q A ih =>
    intro hA
    obtain ⟨k', v'⟩ := q
    have h0 : k' < k := hA (k', v') (by simp)
    have h1 : ¬ k < k' := String.lt_asymm h0
    have h2 : k ≠ k' := fun h => String.lt_irrefl _ (h ▸ h0)
    simp only [List.cons_append, insertL, h1, h2, if_false]
    rw [ih (fun p hp => hA p (by simp [hp]))]

theorem pairs_balance1 (l : T) (k : String) (v : Json) (r : T) :
    pairs (RBNode.balance1 l k v r) = pairs l ++ (k, v) :: pairs r := by
  unfold RBNode.balance1
  split <;> simp [pairs]

theorem pairs_balance2 (l : T) (k : String) (v : Json) (r : T) :
    pairs (RBNode.balance2 l k v r) = pairs l ++ (k, v) :: pairs r := by
  unfold RBNode.balance2
  split <;> simp [pairs]

theorem pairs_setBlack (t : T) : pairs t.setBlack = pairs t := by
  cases t <;> simp [RBNode.setBlack, pairs]


theorem sorted_node {c : RBColor} {l : T} {k : String} {v : Json} {r : T}
    (h : Sorted (pairs (.node c l k v r))) :
    Sorted (pairs l) ∧ Sorted (pairs r) ∧ (∀ p ∈ pairs l, p.1 < k) ∧ (∀ p ∈ pairs r, k < p.1) := by
  simp only [pairs, Sorted, List.pairwise_append, List.pairwise_cons, List.mem_cons] at h
  obtain ⟨hl, ⟨hk, hr⟩, hlr⟩ := h
  exact ⟨hl, hr, fun p hp => hlr p hp (k, v) (Or.inl rfl), hk⟩

theorem pairs_ins : ∀ (t : T) (k : String) (v : Json), Sorted (pairs t) →
    pairs (t.ins compare k v) = insertL k v (pairs t) := by
  intro t k v
  induction t with
  | leaf => intro _; simp [RBNode.ins, pairs, insertL]
  | node c l ky vy r ihl ihr =>
    intro hs
    obtain ⟨hl, hr, hlk, hrk⟩ := sorted_node hs
    have hlt : ∀ (h : compare k ky = .lt), 
        insertL k v (pairs l ++ (ky, vy) :: pairs r) = insertL k v (pairs l) ++ (ky, vy) :: pairs r :=
      fun h => insertL_append_lt k v ky vy (cmp_lt.mp h) _ _
    have hgt : ∀ (h : compare k ky = .gt),
        insertL k v (pairs l ++ (ky, vy) :: pairs r) = pairs l ++ (ky, vy) :: insertL k v (pairs r) := by
      intro h
      have h' := cmp_gt.mp h
      exact insertL_append_gt k v ky vy h' _ _ (fun p hp => String.lt_trans (hlk p hp) h')
    have heq : ∀ (h : compare k ky = .eq),
        insertL k v (pairs l ++ (ky, vy) :: pairs r) = pairs l ++ (k, v) :: pairs r := by
      intro h
      have h' := cmp_eq.mp h
      subst h'
      exact insertL_append_eq k v vy _ _ (fun p hp => hlk p hp)
    cases c
    · simp only [RBNode.ins]
      split
      next h => rw [pairs, ihl hl, pairs, hlt h]
      next h => rw [pairs, ihr hr, pairs, hgt h]
      next h => rw [pairs, pairs, heq h]
    · simp only [RBNode.ins]
      split
      next h => rw [pairs_balance1, ihl hl, pairs, hlt h]
      next h => rw [pairs_balance2, ihr hr, pairs, hgt h]
      next h => rw [pairs, pairs, heq h]


theorem pairs_insert (t : T) (k : String) (v : Json) (hs : Sorted (pairs t)) :
    pairs (t.insert compare k v) = insertL k v (pairs t) := by
  unfold RBNode.insert
  split
  · rw [pairs_setBlack, pairs_ins t k v hs]
  · exact pairs_ins t k v hs

def foldIns (acc : List (String × Json)) (L : List (String × Json)) : List (String × Json) :=
  L.foldl (fun a p => insertL p.1 p.2 a) acc

theorem fold_ok : ∀ (L : List (String × Json)) (t : T), Sorted (pairs t) →
    Sorted (pairs (L.foldl (fun t p => t.insert compare p.1 p.2) t)) ∧
    pairs (L.foldl (fun t p => t.insert compare p.1 p.2) t) = foldIns (pairs t) L := by
  intro L
  induction L with
  | nil => intro t h; exact ⟨h, rfl⟩
  | cons p L ih =>
    intro t h
    have h1 : pairs (t.insert compare p.1 p.2) = insertL p.1 p.2 (pairs t) := pairs_insert t _ _ h
    have h2 : Sorted (pairs (t.insert compare p.1 p.2)) := by
      rw [h1]; exact insertL_sorted _ _ _ h
    obtain ⟨a, b⟩ := ih _ h2
    refine ⟨a, ?_⟩
    simp only [List.foldl_cons]
    rw [b, h1]; rfl

theorem lookup_foldIns (k : String) : ∀ (L acc : List (String × Json)),
    (L.map (·.1)).Nodup → (foldIns acc L).lookup k = (L.lookup k).or (acc.lookup k) := by
  intro L
  induction L with
  | nil => intro acc _; simp [foldIns]
  | cons p L ih =>
    intro acc hnd
    obtain ⟨k0, v0⟩ := p
    simp only [List.map_cons, List.nodup_cons] at hnd
    obtain ⟨hn, hnd⟩ := hnd
    have := ih (insertL k0 v0 acc) hnd
    simp only [foldIns, List.foldl_cons] at this ⊢
    rw [this]
    by_cases hk : k = k0
    · subst hk
      have : L.lookup k = none := by
        apply lookup_none_of
        intro q hq he
        exact hn (List.mem_map.mpr ⟨q, hq, he⟩)
      simp [this, lookup_insertL_self, List.lookup]
    · rw [lookup_insertL_ne k0 v0 k hk]
      have : (k == k0) = false := by simpa using hk
      simp [List.lookup, this]

theorem mkObj_eq (L : List (String × Json)) :
    Json.mkObj L = Json.obj (L.foldl (fun t p => t.insert compare p.1 p.2) .leaf) := by
  unfold Json.mkObj
  congr 1
  generalize (RBNode.leaf : T) = init
  induction L generalizing init with
  | nil => simp [Id.run]
  | cons p L ih => simp [Id.run] at ih ⊢

theorem getObjVal?_mkObj (L : List (String × Json)) (hnd : (L.map (·.1)).Nodup) (k : String) :
    (Json.mkObj L).getObjVal? k = match L.lookup k with
      | some v => .ok v
      | none => .error s!"property not found: {k}" := by
  obtain ⟨hs, hp⟩ := fold_ok L .leaf (by simp [Sorted, pairs])
  rw [mkObj_eq]
  have := find_eq (L.foldl (fun t p => t.insert compare p.1 p.2) .leaf) k hs
  rw [hp, lookup_foldIns k L _ hnd] at this
  simp only [Json.getObjVal?, this, pairs]
  cases h : L.lookup k <;> simp [h, pairs, throw, throwThe, MonadExceptOf.throw, pure, Except.pure]

theorem getObjValD_mkObj (L : List (String × Json)) (hnd : (L.map (·.1)).Nodup) (k : String) :
    (Json.mkObj L).getObjValD k = (L.lookup k).getD Json.null := by
  unfold Json.getObjValD
  rw [getObjVal?_mkObj L hnd k]
  cases L.lookup k <;> simp [Except.toOption]


-- ═══════════════════════════════════════════════════════════════════════
-- 2. Round trip: Phase, Entry, Ledger
-- ═══════════════════════════════════════════════════════════════════════

theorem natJson (n : Nat) : (fromJson? (Json.num n) : Except String Nat) = .ok n := rfl

theorem natJson_opt (o : Option Nat) :
    (fromJson? ((o.map fun n => Json.num n).getD Json.null) : Except String Nat).toOption = o := by
  cases o <;> simp [natJson] <;> rfl

/-- The optional fields of `Entry.toJson`, as three small helpers; each is
    definitionally the `match`/`if` written in the serializer. -/
def fStr (k : String) (o : Option String) : List (String × Json) :=
  match o with | some v => [(k, Json.str v)] | none => []
def fNat (k : String) (o : Option Nat) : List (String × Json) :=
  match o with | some v => [(k, Json.num v)] | none => []
def fFlag (k : String) (b : Bool) : List (String × Json) :=
  if b then [(k, Json.bool true)] else []

theorem fStr_lookup_self (k : String) (o : Option String) :
    (fStr k o).lookup k = o.map Json.str := by cases o <;> simp [fStr, List.lookup]
theorem fNat_lookup_self (k : String) (o : Option Nat) :
    (fNat k o).lookup k = o.map fun n => Json.num n := by cases o <;> simp [fNat, List.lookup]
theorem fFlag_lookup_self (k : String) (b : Bool) :
    (fFlag k b).lookup k = if b then some (Json.bool true) else none := by
  cases b <;> simp [fFlag, List.lookup]
theorem fStr_lookup_ne (k k0 : String) (h : k ≠ k0) (o : Option String) :
    (fStr k0 o).lookup k = none := by
  have : (k == k0) = false := by simpa using h
  cases o <;> simp [fStr, List.lookup, this]
theorem fNat_lookup_ne (k k0 : String) (h : k ≠ k0) (o : Option Nat) :
    (fNat k0 o).lookup k = none := by
  have : (k == k0) = false := by simpa using h
  cases o <;> simp [fNat, List.lookup, this]
theorem fFlag_lookup_ne (k k0 : String) (h : k ≠ k0) (b : Bool) :
    (fFlag k0 b).lookup k = none := by
  have : (k == k0) = false := by simpa using h
  cases b <;> simp [fFlag, List.lookup, this]

theorem fStr_keys (k : String) (o : Option String) :
    List.Sublist ((fStr k o).map (·.1)) [k] := by
  cases o <;> simp [fStr]
theorem fNat_keys (k : String) (o : Option Nat) :
    List.Sublist ((fNat k o).map (·.1)) [k] := by
  cases o <;> simp [fNat]
theorem fFlag_keys (k : String) (b : Bool) :
    List.Sublist ((fFlag k b).map (·.1)) [k] := by
  cases b <;> simp [fFlag]

/-- Everything `Entry.toJson` writes, in its order. -/
def entryFields (e : Entry) : List (String × Json) :=
  ([("dest", Json.str e.dest), ("masterKey", Json.str e.masterKey),
    ("phase", e.phase.toJson), ("drops", Json.num e.drops)] : List (String × Json))
  ++ fStr "nodeKey" e.nodeKey
  ++ fNat "bootIdAtReseat" e.bootIdAtReseat
  ++ fNat "currentIdAtReseat" e.currentIdAtReseat
  ++ [("dropsAtReseat", Json.num e.dropsAtReseat)]
  ++ fStr "hold" e.hold
  ++ fFlag "owned" e.owned
  ++ fNat "mustReach" e.mustReach
  ++ fStr "barEpoch" e.barEpoch
  ++ fFlag "adoptable" e.adoptable
  ++ fNat "bootAtRequest" e.bootAtRequest
  ++ fNat "currentIdAtRequest" e.currentIdAtRequest
  ++ fStr "podAtRequest" e.podAtRequest

theorem entry_toJson_eq (e : Entry) : e.toJson = Json.mkObj (entryFields e) := rfl

/-- The 17 keys, once each. -/
def entryKeys : List String :=
  ["dest", "masterKey", "phase", "drops"] ++ ["nodeKey"] ++ ["bootIdAtReseat"]
  ++ ["currentIdAtReseat"] ++ ["dropsAtReseat"] ++ ["hold"] ++ ["owned"] ++ ["mustReach"]
  ++ ["barEpoch"] ++ ["adoptable"] ++ ["bootAtRequest"] ++ ["currentIdAtRequest"]
  ++ ["podAtRequest"]

theorem entryFields_nodup (e : Entry) : ((entryFields e).map (·.1)).Nodup := by
  have : List.Sublist ((entryFields e).map (·.1)) entryKeys := by
    unfold entryFields entryKeys
    simp only [List.map_append]
    refine List.Sublist.append ?_ (fStr_keys _ _)
    refine List.Sublist.append ?_ (fNat_keys _ _)
    refine List.Sublist.append ?_ (fNat_keys _ _)
    refine List.Sublist.append ?_ (fFlag_keys _ _)
    refine List.Sublist.append ?_ (fStr_keys _ _)
    refine List.Sublist.append ?_ (fNat_keys _ _)
    refine List.Sublist.append ?_ (fFlag_keys _ _)
    refine List.Sublist.append ?_ (fStr_keys _ _)
    refine List.Sublist.append ?_ (List.Sublist.refl _)
    refine List.Sublist.append ?_ (fNat_keys _ _)
    refine List.Sublist.append ?_ (fNat_keys _ _)
    refine List.Sublist.append ?_ (fStr_keys _ _)
    exact List.Sublist.refl _
  exact this.nodup (by decide)

/-- Reading a key of a `mkObj` object as any type: the lookup, or `null`. -/
theorem getObjValAs_mkObj {α : Type} [FromJson α] (L : List (String × Json))
    (hnd : (L.map (·.1)).Nodup) (k : String) :
    (Json.mkObj L).getObjValAs? α k = fromJson? ((L.lookup k).getD Json.null) := by
  unfold Json.getObjValAs?
  rw [getObjValD_mkObj L hnd k]

theorem strJson (s : String) : (fromJson? (Json.str s) : Except String String) = .ok s := rfl
theorem boolJson (b : Bool) : (fromJson? (Json.bool b) : Except String Bool) = .ok b := rfl

theorem phase_roundtrip (p : Phase) : Phase.fromJson? p.toJson = some p := by
  cases p with
  | requested =>
    unfold Phase.toJson Phase.fromJson?
    rw [getObjValAs_mkObj _ (by decide)]
    simp [List.lookup, strJson]
  | reseated =>
    unfold Phase.toJson Phase.fromJson?
    rw [getObjValAs_mkObj _ (by decide)]
    simp [List.lookup, strJson]
  | adopted =>
    unfold Phase.toJson Phase.fromJson?
    rw [getObjValAs_mkObj _ (by decide)]
    simp [List.lookup, strJson]
  | demoted v =>
    unfold Phase.toJson Phase.fromJson?
    rw [getObjValAs_mkObj _ (by simp), getObjValAs_mkObj _ (by simp)]
    simp [List.lookup, strJson, natJson]

theorem getOpt_str (o : Option String) :
    (fromJson? ((o.map Json.str).getD Json.null) : Except String String).toOption = o := by
  cases o <;> simp [strJson] <;> rfl

theorem getOpt_flag (b : Bool) :
    ((fromJson? (((if b then some (Json.bool true) else none : Option Json)).getD Json.null)
      : Except String Bool).toOption.getD false) = b := by
  cases b <;> simp [boolJson] <;> rfl

theorem entry_roundtrip (e : Entry) : Entry.fromJson? e.toJson = some e := by
  have hnd := entryFields_nodup e
  have hv : (Json.mkObj (entryFields e)).getObjVal? "phase" = .ok e.phase.toJson := by
    rw [getObjVal?_mkObj _ hnd]
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne]
  have l_dest : (entryFields e).lookup "dest" = some (Json.str e.dest) := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_masterKey : (entryFields e).lookup "masterKey" = some (Json.str e.masterKey) := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_drops : (entryFields e).lookup "drops" = some (Json.num e.drops) := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_dropsAtReseat : (entryFields e).lookup "dropsAtReseat" = some (Json.num e.dropsAtReseat) := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_nodeKey : (entryFields e).lookup "nodeKey" = e.nodeKey.map Json.str := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_hold : (entryFields e).lookup "hold" = e.hold.map Json.str := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_barEpoch : (entryFields e).lookup "barEpoch" = e.barEpoch.map Json.str := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_podAtRequest : (entryFields e).lookup "podAtRequest" = e.podAtRequest.map Json.str := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_bootIdAtReseat : (entryFields e).lookup "bootIdAtReseat" = e.bootIdAtReseat.map fun n => Json.num n := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_currentIdAtReseat : (entryFields e).lookup "currentIdAtReseat" = e.currentIdAtReseat.map fun n => Json.num n := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_mustReach : (entryFields e).lookup "mustReach" = e.mustReach.map fun n => Json.num n := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_bootAtRequest : (entryFields e).lookup "bootAtRequest" = e.bootAtRequest.map fun n => Json.num n := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_currentIdAtRequest : (entryFields e).lookup "currentIdAtRequest" = e.currentIdAtRequest.map fun n => Json.num n := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_owned : (entryFields e).lookup "owned" = if e.owned then some (Json.bool true) else none := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  have l_adoptable : (entryFields e).lookup "adoptable" = if e.adoptable then some (Json.bool true) else none := by
    simp [entryFields, lookup_append, List.lookup, fStr_lookup_ne, fNat_lookup_ne, fFlag_lookup_ne,
      fStr_lookup_self, fNat_lookup_self, fFlag_lookup_self]
  rw [entry_toJson_eq]
  unfold Entry.fromJson?
  simp only [getObjValAs_mkObj _ hnd, hv, l_dest, l_masterKey, l_drops, l_dropsAtReseat, l_nodeKey,
    l_hold, l_barEpoch, l_podAtRequest, l_bootIdAtReseat, l_currentIdAtReseat, l_mustReach,
    l_bootAtRequest, l_currentIdAtRequest, l_owned, l_adoptable,
    getOpt_str, natJson_opt, getOpt_flag, Option.getD_some]
  simp only [Option.getD, strJson, natJson, Except.toOption, Option.bind]
  simp [phase_roundtrip]

theorem mapM_map_some {α β : Type} (g : β → Option α) (f : α → β) :
    ∀ (l : List α), (∀ x ∈ l, g (f x) = some x) → (l.map f).mapM g = some l := by
  intro l
  induction l with
  | nil => intro _; rfl
  | cons x l ih =>
    intro h
    simp only [List.map_cons, List.mapM_cons, h x (by simp), ih (fun y hy => h y (by simp [hy]))]
    rfl

/-- One counter, as `Ledger.toJson` writes it and `Ledger.fromJson?` reads it. -/
def counterJson (c : String × Nat) : Json :=
  Json.mkObj [("key", Json.str c.1), ("count", Json.num c.2)]

def counterOf (c : Json) : Option (String × Nat) :=
  match c.getObjValAs? String "key", c.getObjValAs? Nat "count" with
  | .ok k, .ok n => some (k, n)
  | _, _ => none

theorem counter_roundtrip (c : String × Nat) : counterOf (counterJson c) = some c := by
  obtain ⟨k, n⟩ := c
  unfold counterOf counterJson
  rw [getObjValAs_mkObj _ (by simp), getObjValAs_mkObj _ (by simp)]
  simp [List.lookup, strJson, natJson]

theorem ledger_roundtrip (l : Ledger) : Ledger.fromJson? l.toJson = some l := by
  have hnd : ([("initialized", Json.bool l.initialized),
      ("counters", Json.arr (l.counters.map counterJson).toArray),
      ("entries", Json.arr (l.entries.map Entry.toJson).toArray)].map (·.1)).Nodup := by simp
  have hc : (Json.mkObj [("initialized", Json.bool l.initialized),
      ("counters", Json.arr (l.counters.map counterJson).toArray),
      ("entries", Json.arr (l.entries.map Entry.toJson).toArray)]).getObjVal? "counters"
        = .ok (Json.arr (l.counters.map counterJson).toArray) := by
    rw [getObjVal?_mkObj _ hnd]; simp [List.lookup]
  have he : (Json.mkObj [("initialized", Json.bool l.initialized),
      ("counters", Json.arr (l.counters.map counterJson).toArray),
      ("entries", Json.arr (l.entries.map Entry.toJson).toArray)]).getObjVal? "entries"
        = .ok (Json.arr (l.entries.map Entry.toJson).toArray) := by
    rw [getObjVal?_mkObj _ hnd]; simp [List.lookup]
  have hi := getObjValAs_mkObj (α := Bool) _ hnd "initialized"
  have ht : l.toJson = Json.mkObj [("initialized", Json.bool l.initialized),
      ("counters", Json.arr (l.counters.map counterJson).toArray),
      ("entries", Json.arr (l.entries.map Entry.toJson).toArray)] := rfl
  rw [ht]
  unfold Ledger.fromJson?
  simp only [hi, hc, he, List.toList_toArray]
  have h1 : (l.counters.map counterJson).mapM counterOf = some l.counters :=
    mapM_map_some counterOf counterJson _ (fun c _ => counter_roundtrip c)
  have h2 : (l.entries.map Entry.toJson).mapM Entry.fromJson? = some l.entries :=
    mapM_map_some Entry.fromJson? Entry.toJson _ (fun e _ => entry_roundtrip e)
  have h3 : (fromJson? ((List.lookup "initialized"
      [("initialized", Json.bool l.initialized),
       ("counters", Json.arr (l.counters.map counterJson).toArray),
       ("entries", Json.arr (l.entries.map Entry.toJson).toArray)]).getD Json.null)
        : Except String Bool).toOption.getD false = l.initialized := by
    simp [List.lookup, boolJson, Except.toOption]
  rw [h3]
  change (do let y ← (l.counters.map counterJson).mapM counterOf
             let y_1 ← (l.entries.map Entry.toJson).mapM Entry.fromJson?
             pure { initialized := l.initialized, counters := y, entries := y_1 : Ledger }) = some l
  rw [h1, h2]
  rfl

-- ═══════════════════════════════════════════════════════════════════════
-- 2b. Counter keys split back into their parts
-- ═══════════════════════════════════════════════════════════════════════

theorem digitChar_ne (n : Nat) : Nat.digitChar n ≠ '|' := by
  rcases Nat.lt_or_ge n 16 with hn | hn
  · exact (by decide : ∀ n, n < 16 → Nat.digitChar n ≠ '|') n hn
  · have e : Nat.digitChar n = '*' := by
      unfold Nat.digitChar
      rw [if_neg (show ¬ (n = 0) by omega)]
      rw [if_neg (show ¬ (n = 1) by omega)]
      rw [if_neg (show ¬ (n = 2) by omega)]
      rw [if_neg (show ¬ (n = 3) by omega)]
      rw [if_neg (show ¬ (n = 4) by omega)]
      rw [if_neg (show ¬ (n = 5) by omega)]
      rw [if_neg (show ¬ (n = 6) by omega)]
      rw [if_neg (show ¬ (n = 7) by omega)]
      rw [if_neg (show ¬ (n = 8) by omega)]
      rw [if_neg (show ¬ (n = 9) by omega)]
      rw [if_neg (show ¬ (n = 10) by omega)]
      rw [if_neg (show ¬ (n = 11) by omega)]
      rw [if_neg (show ¬ (n = 12) by omega)]
      rw [if_neg (show ¬ (n = 13) by omega)]
      rw [if_neg (show ¬ (n = 14) by omega)]
      rw [if_neg (show ¬ (n = 15) by omega)]
    rw [e]; decide

theorem toDigitsCore_ne : ∀ (fuel n : Nat) (ds : List Char), (∀ c ∈ ds, c ≠ '|') →
    ∀ c ∈ Nat.toDigitsCore 10 fuel n ds, c ≠ '|' := by
  intro fuel
  induction fuel with
  | zero => intro n ds h; simpa [Nat.toDigitsCore] using h
  | succ f ih =>
    intro n ds h
    have h' : ∀ c ∈ (Nat.digitChar (n % 10) :: ds), c ≠ '|' := by
      intro c hc
      rcases List.mem_cons.mp hc with rfl | hc
      · exact digitChar_ne _
      · exact h c hc
    intro c hc
    unfold Nat.toDigitsCore at hc
    simp only [] at hc
    by_cases hn : n / 10 = 0
    · rw [if_pos hn] at hc
      exact h' c hc
    · rw [if_neg hn] at hc
      exact ih _ _ h' c hc

theorem toString_nat_ne (b : Nat) : ∀ c ∈ (toString b).data, c ≠ '|' := by
  intro c hc
  have e : (toString b).data = Nat.toDigits 10 b := rfl
  rw [e] at hc
  exact toDigitsCore_ne (b + 1) b [] (by simp) c hc

theorem barFree_iff (s : String) : barFree s = true ↔ ∀ c ∈ s.data, c ≠ '|' := by
  simp [barFree, List.all_eq_true]

theorem splitBar_nobar (cs : List Char) (h : ∀ c ∈ cs, c ≠ '|') : splitBar cs = [cs] := by
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    have hc := h c (by simp)
    simp [splitBar, hc, ih (fun x hx => h x (by simp [hx]))]

theorem splitBar_bar (r : List Char) : ∀ (a : List Char), (∀ c ∈ a, c ≠ '|') →
    splitBar (a ++ '|' :: r) = a :: splitBar r := by
  intro a
  induction a with
  | nil => intro _; simp [splitBar]
  | cons c a ih =>
    intro h
    have hc := h c (by simp)
    simp [splitBar, hc, ih (fun x hx => h x (by simp [hx]))]

theorem keyParts_some (m d : String) (b : Nat) (hm : barFree m = true) (hd : barFree d = true) :
    keyParts (counterKey m d (some b)) = [m, d, toString b] := by
  rw [barFree_iff] at hm hd
  have e : (counterKey m d (some b)).data = m.data ++ '|' :: (d.data ++ '|' :: (toString b).data) := by
    simp [counterKey, String.data_append]
  unfold keyParts
  rw [e, splitBar_bar _ _ hm, splitBar_bar _ _ hd, splitBar_nobar _ (toString_nat_ne b)]
  rfl

theorem keyParts_none (m d : String) (hm : barFree m = true) (hd : barFree d = true) :
    keyParts (counterKey m d none) = [m, d] := by
  rw [barFree_iff] at hm hd
  have e : (counterKey m d none).data = m.data ++ '|' :: d.data := by
    simp [counterKey, String.data_append]
  unfold keyParts
  rw [e, splitBar_bar _ _ hm, splitBar_nobar _ hd]
  rfl

-- ═══════════════════════════════════════════════════════════════════════
-- 3. `observeCore`: the same cumulative counter is never attributed twice
-- ═══════════════════════════════════════════════════════════════════════

/-- Two destinations of one master (in one boot) never share a counter key. -/
theorem counterKey_inj (m : String) (boot : Option Nat) (d d' : String)
    (h : counterKey m d boot = counterKey m d' boot) : d = d' := by
  cases boot with
  | none =>
    simp only [counterKey] at h
    have := congrArg String.data h
    simp [String.data_append] at this
    exact String.ext this
  | some b =>
    simp only [counterKey] at h
    have := congrArg String.data h
    simp [String.data_append] at this
    exact String.ext this

/-- What one step of `observeCore` does to the counters, whatever the delta. -/
def upd (cs : List (String × Nat)) (p : String × Nat) : List (String × Nat) :=
  cs.filter (·.1 != p.1) ++ [p]

def dropKeys (ks : List String) (cs : List (String × Nat)) : List (String × Nat) :=
  cs.filter fun c => !ks.contains c.1

theorem upd_fold (K : List (String × Nat)) (hK : (K.map (·.1)).Nodup) :
    ∀ cs, K.foldl upd cs = dropKeys (K.map (·.1)) cs ++ K := by
  induction K with
  | nil => intro cs; simp [dropKeys]; exact (List.filter_eq_self.mpr (by simp)).symm
  | cons p K ih =>
    intro cs
    simp only [List.map_cons, List.nodup_cons] at hK
    obtain ⟨hp, hK⟩ := hK
    simp only [List.foldl_cons, ih hK]
    have hp' : ((K.map (·.1)).contains p.1) = false := by
      cases h : (K.map (·.1)).contains p.1
      · rfl
      · exact absurd (List.mem_of_elem_eq_true h) hp
    simp only [dropKeys, upd, List.filter_append, List.filter_filter, List.map_cons, List.contains_cons,
      List.append_assoc]
    have hpl : List.filter (fun c : String × Nat => !(K.map (·.1)).contains c.1) [p] = [p] := by
      simp only [List.filter, hp', Bool.not_false]
    rw [hpl]
    have hf : ∀ a : String × Nat, (!(K.map (·.1)).contains a.1 && a.1 != p.1)
        = !(a.1 == p.1 || (K.map (·.1)).contains a.1) := by
      intro a
      cases (K.map (·.1)).contains a.1 <;> cases h : a.1 == p.1 <;> simp [h, bne]
    simp only [hf]
    rfl

theorem lookup_upd_ne (cs : List (String × Nat)) (p : String × Nat) (k : String) (h : k ≠ p.1) :
    (upd cs p).lookup k = cs.lookup k := by
  unfold upd
  rw [lookup_append]
  have hb : (k == p.1) = false := by simpa using h
  have h2 : ([p] : List (String × Nat)).lookup k = none := by simp [List.lookup, hb]
  rw [h2, Option.or_none]
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    obtain ⟨k', v'⟩ := c
    by_cases hk : k' = p.1
    · have : (k == k') = false := by rw [hk]; exact hb
      simp [List.filter, hk, List.lookup, this, hb, ih]
    · have hne : (k' != p.1) = true := by simpa using hk
      simp [List.filter, hne, List.lookup, ih]

/-- `observeCore`'s per-destination step, as written in ReplicaRepair.lean. -/
def obsStep (init : Bool) (masterKey : String) (boot : Option Nat) (fb : String → Option Nat)
    (acc : Ledger × List (String × Nat) × List String) (p : String × Nat) :
    Ledger × List (String × Nat) × List String :=
  let (led, drops, first) := acc
  let (dest, n) := p
  let key := counterKey masterKey dest boot
  let delta := classify ((led.counters.lookup key).or (fb dest)) init n
  let led' := { led with counters := (led.counters.filter (·.1 != key)) ++ [(key, n)] }
  match delta with
  | .increased d => (led', drops ++ [(dest, d)], first)
  | .reset now => if now > 0 then (led', drops ++ [(dest, now)], first) else (led', drops, first)
  | .firstSighting n => if n > 0 then (led', drops ++ [(dest, n)], first ++ [dest]) else (led', drops, first)
  | .unchanged => (led', drops, first)

theorem observe_eq (l : Ledger) (masterKey : String) (observed : List (String × Nat))
    (boot : Option Nat) :
    observeCore l masterKey observed boot =
      (let l0 := { l with counters := l.counters.filter (fun (k, _) => !otherProcess masterKey boot k) }
       let r := observed.foldl (obsStep l.initialized masterKey boot (legacyPrev l masterKey boot)) (l0, [], [])
       ({ r.1 with initialized := true }, r.2.1, r.2.2)) := rfl

/-- The drops and first sightings a classified delta contributes. -/
def dropsOf (d : String) : DropDelta → List (String × Nat)
  | .increased x => [(d, x)]
  | .reset now => if now > 0 then [(d, now)] else []
  | .firstSighting n => if n > 0 then [(d, n)] else []
  | .unchanged => []

def firstOf (d : String) : DropDelta → List String
  | .firstSighting n => if n > 0 then [d] else []
  | _ => []

theorem obsStep_eq (init : Bool) (m : String) (boot : Option Nat) (fb : String → Option Nat) (acc : Ledger × List (String × Nat) × List String)
    (p : String × Nat) :
    obsStep init m boot fb acc p =
      ({ acc.1 with counters := upd acc.1.counters (counterKey m p.1 boot, p.2) },
       acc.2.1 ++ dropsOf p.1 (classify ((acc.1.counters.lookup (counterKey m p.1 boot)).or (fb p.1)) init p.2),
       acc.2.2 ++ firstOf p.1 (classify ((acc.1.counters.lookup (counterKey m p.1 boot)).or (fb p.1)) init p.2)) := by
  obtain ⟨led, drops, first⟩ := acc
  obtain ⟨d, n⟩ := p
  unfold obsStep
  cases hc : classify ((led.counters.lookup (counterKey m d boot)).or (fb d)) init n <;>
    simp [dropsOf, firstOf, upd, hc] <;> split <;> simp

theorem flatMap_cong {α β : Type} (f g : α → List β) :
    ∀ (l : List α), (∀ q ∈ l, f q = g q) → l.flatMap f = l.flatMap g := by
  intro l
  induction l with
  | nil => intro _; rfl
  | cons a l ih =>
    intro h
    simp only [List.flatMap_cons, h a (by simp), ih (fun q hq => h q (by simp [hq]))]

/-- The whole fold, for distinct destinations: counters are rewritten key by key,
    and every destination is classified against the counters AS THEY WERE before
    the pass (an earlier destination's update never touches a later one's key). -/
theorem fold_spec (init : Bool) (m : String) (boot : Option Nat) (fb : String → Option Nat) :
    ∀ (obs : List (String × Nat)) (acc : Ledger × List (String × Nat) × List String),
    (obs.map (·.1)).Nodup →
    obs.foldl (obsStep init m boot fb) acc =
      ({ acc.1 with counters := (obs.map fun p => (counterKey m p.1 boot, p.2)).foldl upd acc.1.counters },
       acc.2.1 ++ obs.flatMap (fun p =>
         dropsOf p.1 (classify ((acc.1.counters.lookup (counterKey m p.1 boot)).or (fb p.1)) init p.2)),
       acc.2.2 ++ obs.flatMap (fun p =>
         firstOf p.1 (classify ((acc.1.counters.lookup (counterKey m p.1 boot)).or (fb p.1)) init p.2))) := by
  intro obs
  induction obs with
  | nil => intro acc _; simp
  | cons p obs ih =>
    intro acc hnd
    simp only [List.map_cons, List.nodup_cons] at hnd
    obtain ⟨hp, hnd⟩ := hnd
    simp only [List.foldl_cons, obsStep_eq, ih _ hnd, List.map_cons, List.flatMap_cons,
      List.append_assoc]
    have hlk : ∀ q ∈ obs, (upd acc.1.counters (counterKey m p.1 boot, p.2)).lookup
        (counterKey m q.1 boot) = acc.1.counters.lookup (counterKey m q.1 boot) := by
      intro q hq
      apply lookup_upd_ne
      intro he
      exact hp (List.mem_map.mpr ⟨q, hq, (counterKey_inj m boot _ _ he)⟩)
    have e1 : obs.flatMap (fun q => dropsOf q.1 (classify
        (((upd acc.1.counters (counterKey m p.1 boot, p.2)).lookup (counterKey m q.1 boot)).or (fb q.1)) init q.2))
        = obs.flatMap (fun q => dropsOf q.1 (classify
        ((acc.1.counters.lookup (counterKey m q.1 boot)).or (fb q.1)) init q.2)) :=
      flatMap_cong _ _ obs (fun q hq => by rw [hlk q hq])
    have e2 : obs.flatMap (fun q => firstOf q.1 (classify
        (((upd acc.1.counters (counterKey m p.1 boot, p.2)).lookup (counterKey m q.1 boot)).or (fb q.1)) init q.2))
        = obs.flatMap (fun q => firstOf q.1 (classify
        ((acc.1.counters.lookup (counterKey m q.1 boot)).or (fb q.1)) init q.2)) :=
      flatMap_cong _ _ obs (fun q hq => by rw [hlk q hq])
    rw [e1, e2]

/-- The (key, count) pairs one pass writes. -/
def keyed (m : String) (boot : Option Nat) (obs : List (String × Nat)) : List (String × Nat) :=
  obs.map fun p => (counterKey m p.1 boot, p.2)

/-- The counters a pass starts from: the other-process keys are forgotten first. -/
def startCounters (l : Ledger) (m : String) (boot : Option Nat) : List (String × Nat) :=
  l.counters.filter (fun (k, _) => !otherProcess m boot k)

theorem nodup_map_on {α β : Type} (f : α → β) (l : List α)
    (inj : ∀ x ∈ l, ∀ y ∈ l, f x = f y → x = y) (h : l.Nodup) : (l.map f).Nodup := by
  unfold List.Nodup at h ⊢
  rw [List.pairwise_map]
  exact h.imp_of_mem (fun {a b} ha hb hne hfe => hne (inj a ha b hb hfe))

theorem keyed_keys_nodup (m : String) (boot : Option Nat) (obs : List (String × Nat))
    (h : (obs.map (·.1)).Nodup) : ((keyed m boot obs).map (·.1)).Nodup := by
  have : (keyed m boot obs).map (·.1) = (obs.map (·.1)).map (counterKey m · boot) := by
    simp [keyed, List.map_map, Function.comp_def]
  rw [this]
  exact nodup_map_on _ _ (fun x _ y _ hxy => counterKey_inj m boot x y hxy) h

theorem lookup_keyed (m : String) (boot : Option Nat) :
    ∀ (obs : List (String × Nat)), (obs.map (·.1)).Nodup → ∀ p ∈ obs,
    (keyed m boot obs).lookup (counterKey m p.1 boot) = some p.2 := by
  intro obs
  induction obs with
  | nil => intro _ p hp; simp at hp
  | cons q obs ih =>
    intro hnd p hp
    simp only [List.map_cons, List.nodup_cons] at hnd
    obtain ⟨hq, hnd⟩ := hnd
    simp only [keyed, List.map_cons, List.lookup]
    rcases List.mem_cons.mp hp with rfl | hp
    · simp
    · have hne : counterKey m p.1 boot ≠ counterKey m q.1 boot := by
        intro he
        exact hq (List.mem_map.mpr ⟨p, hp, counterKey_inj m boot _ _ he⟩)
      have hb : (counterKey m p.1 boot == counterKey m q.1 boot) = false := by simpa using hne
      simp only [hb]
      exact ih hnd p hp

/-- The previous value a destination is compared with: its counter under this pass's key
    (after the other processes' keys are forgotten), else the boot-less counter. -/
def prevOf (l : Ledger) (m : String) (boot : Option Nat) (d : String) : Option Nat :=
  ((startCounters l m boot).lookup (counterKey m d boot)).or (legacyPrev l m boot d)

/-- The pass in closed form (distinct destinations). -/
theorem observe_spec (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup) :
    observeCore l m obs boot =
      ({ l with initialized := true, counters := (keyed m boot obs).foldl upd (startCounters l m boot) },
       obs.flatMap (fun p => dropsOf p.1 (classify (prevOf l m boot p.1) l.initialized p.2)),
       obs.flatMap (fun p => firstOf p.1 (classify (prevOf l m boot p.1) l.initialized p.2))) := by
  rw [observe_eq]
  simp only []
  rw [fold_spec _ _ _ _ obs _ hnd]
  simp [keyed, startCounters, prevOf]

theorem classify_same (i : Bool) (n : Nat) : classify (some n) i n = .unchanged := by
  simp [classify]

/-- `classify`, one rule at a time (the code's rules, read back). -/
theorem dropsOf_some (d : String) (i : Bool) (q n : Nat) :
    dropsOf d (classify (some q) i n) =
      if q < n then [(d, n - q)] else if n < q then (if n > 0 then [(d, n)] else []) else [] := by
  unfold classify
  by_cases h1 : q < n
  · simp [h1, dropsOf]
  · by_cases h2 : n < q
    · simp [h1, h2, dropsOf]
    · simp [h1, h2, dropsOf]

theorem dropsOf_none (d : String) (i : Bool) (n : Nat) :
    dropsOf d (classify none i n) = if n > 0 then [(d, n)] else [] := by
  cases i <;> by_cases h : n > 0 <;> simp [classify, h, dropsOf]

/-- Same cumulative value as the ledger holds: nothing is attributed, the first
    sighting list stays empty too. -/
theorem observe_quiet (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup)
    (hsame : ∀ p ∈ obs, prevOf l m boot p.1 = some p.2) :
    (observeCore l m obs boot).2 = ([], []) := by
  rw [observe_spec l m obs boot hnd]
  have h1 : ∀ p ∈ obs, dropsOf p.1 (classify (prevOf l m boot p.1)
      l.initialized p.2) = [] := by
    intro p hp
    rw [hsame p hp, classify_same]; rfl
  have h2 : ∀ p ∈ obs, firstOf p.1 (classify (prevOf l m boot p.1)
      l.initialized p.2) = [] := by
    intro p hp
    rw [hsame p hp, classify_same]; rfl
  rw [flatMap_cong _ (fun _ => []) obs h1, flatMap_cong _ (fun _ => []) obs h2]
  simp

theorem dropKeys_idem (ks : List String) (cs : List (String × Nat)) :
    dropKeys ks (dropKeys ks cs) = dropKeys ks cs := by
  unfold dropKeys
  rw [List.filter_filter]
  apply List.filter_congr
  intro c _
  cases ks.contains c.1 <;> simp

theorem dropKeys_keyed (m : String) (boot : Option Nat) (obs : List (String × Nat)) :
    dropKeys ((keyed m boot obs).map (·.1)) (keyed m boot obs) = [] := by
  unfold dropKeys
  rw [List.filter_eq_nil_iff]
  intro c hc
  have : ((keyed m boot obs).map (·.1)).contains c.1 = true := by
    apply List.elem_eq_true_of_mem
    exact List.mem_map.mpr ⟨c, hc, rfl⟩
  show ¬ ((!((keyed m boot obs).map (·.1)).contains c.1) = true)
  rw [this]; simp

/-- The keys `observeCore` writes are never taken for another process's keys: for a known
    boot id, the key splits back into its three parts. This holds exactly when the
    master key and the destination contain no `|` (`keysSplit_of_barFree`: what `observe`
    checks before it accounts). -/
def KeysSplit (m : String) (boot : Option Nat) (obs : List (String × Nat)) : Prop :=
  ∀ b, boot = some b → ∀ p ∈ obs, keyParts (counterKey m p.1 (some b)) = [m, p.1, toString b]

theorem keyed_not_other (m : String) (boot : Option Nat) (obs : List (String × Nat))
    (hks : KeysSplit m boot obs) : ∀ c ∈ keyed m boot obs, (!otherProcess m boot c.1) = true := by
  intro c hc
  obtain ⟨p, hp, rfl⟩ := List.mem_map.mp hc
  cases boot with
  | none => simp [otherProcess]
  | some b =>
    have := hks b rfl p hp
    simp [otherProcess, this]

/-- A ledger that already holds this pass's counters, whatever else it holds:
    observing again attributes nothing and keeps the counters. -/
theorem observeCore_fixed (L : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup) (hks : KeysSplit m boot obs)
    (C0 : List (String × Nat)) (hC0 : ∀ c ∈ C0, (!otherProcess m boot c.1) = true)
    (hL : L.counters = (keyed m boot obs).foldl upd C0) :
    observeCore L m obs boot = ({ L with initialized := true }, [], []) := by
  have hK := keyed_keys_nodup m boot obs hnd
  have hLc : L.counters = dropKeys ((keyed m boot obs).map (·.1)) C0 ++ keyed m boot obs := by
    rw [hL, upd_fold _ hK]
  -- nothing in the ledger is another process's key, so the pass starts from it whole
  have hstart : startCounters L m boot = L.counters := by
    unfold startCounters
    apply List.filter_eq_self.mpr
    intro c hc
    rw [hLc] at hc
    rcases List.mem_append.mp hc with hc | hc
    · exact hC0 c (List.mem_filter.mp hc).1
    · exact keyed_not_other m boot obs hks c hc
  -- and every destination's counter is exactly the observed value
  have hsame0 : ∀ p ∈ obs, (startCounters L m boot).lookup (counterKey m p.1 boot) = some p.2 := by
    intro p hp
    rw [hstart, hLc, lookup_append]
    have h0 : (dropKeys ((keyed m boot obs).map (·.1)) C0).lookup (counterKey m p.1 boot) = none := by
      apply lookup_none_of
      intro c hc he
      have hc' := (List.mem_filter.mp hc).2
      have hmem : counterKey m p.1 boot ∈ (keyed m boot obs).map (·.1) :=
        List.mem_map.mpr ⟨(counterKey m p.1 boot, p.2), List.mem_map.mpr ⟨p, hp, rfl⟩, rfl⟩
      have ht : ((keyed m boot obs).map (·.1)).contains (counterKey m p.1 boot) = true :=
        List.elem_eq_true_of_mem hmem
      rw [he, ht] at hc'
      exact absurd hc' (by decide)
    rw [h0, lookup_keyed m boot obs hnd p hp]
    rfl
  have hsame : ∀ p ∈ obs, prevOf L m boot p.1 = some p.2 := by
    intro p hp
    unfold prevOf
    rw [hsame0 p hp]
    rfl
  have hq := observe_quiet L m obs boot hnd hsame
  have hs := observe_spec L m obs boot hnd
  rw [hstart] at hs
  have hcount : (keyed m boot obs).foldl upd L.counters = L.counters := by
    rw [upd_fold _ hK, hLc]
    unfold dropKeys
    rw [List.filter_append]
    have := dropKeys_keyed m boot obs
    have h2 := dropKeys_idem ((keyed m boot obs).map (·.1)) C0
    unfold dropKeys at this h2
    rw [this, h2]
    simp
  rw [hcount] at hs
  rw [hs] at hq ⊢
  simp only [Prod.mk.injEq] at hq
  obtain ⟨h1, h2⟩ := hq
  rw [h1, h2]

/-- THEOREM (idempotence of the counter accounting). Observing the same cumulative
    counters of one master a second time attributes nothing, reports no first
    sighting, and leaves the ledger exactly as the first observation left it. -/
theorem observeCore_idempotent (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup) (hks : KeysSplit m boot obs) :
    observeCore (observeCore l m obs boot).1 m obs boot = ((observeCore l m obs boot).1, [], []) := by
  have h1 := observe_spec l m obs boot hnd
  rw [h1]
  simp only []
  exact observeCore_fixed _ m obs boot hnd hks (startCounters l m boot)
    (fun c hc => (List.mem_filter.mp hc).2) rfl

/-- THEOREM (the counters that make a request). What the first rule of the ledger
    says, in both directions: a destination is attributed drops only when its
    counter rose (by exactly the rise), restarted at a non-zero value (all of it is
    new), or was first seen non-zero; an unchanged counter attributes nothing; a
    counter that restarted at 0 attributes nothing. -/
theorem dropsOf_mem_fst (d' : String) (dl : DropDelta) (d : String) (x : Nat)
    (h : (d, x) ∈ dropsOf d' dl) : d = d' := by
  cases dl with
  | increased y => simp [dropsOf] at h; exact h.1
  | unchanged => simp [dropsOf] at h
  | reset now =>
    by_cases hn : now > 0
    · simp [dropsOf, hn] at h; exact h.1
    · simp [dropsOf, hn] at h
  | firstSighting now =>
    by_cases hn : now > 0
    · simp [dropsOf, hn] at h; exact h.1
    · simp [dropsOf, hn] at h

theorem observe_drops_mem (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (d : String) (x : Nat) (hnd : (obs.map (·.1)).Nodup)
    (h : (d, x) ∈ (observeCore l m obs boot).2.1) :
    ∃ n, (d, n) ∈ obs ∧
      ((prevOf l m boot d = none ∧ 0 < n ∧ x = n) ∨
       ∃ q, prevOf l m boot d = some q ∧
         ((q < n ∧ x = n - q) ∨ (n < q ∧ 0 < n ∧ x = n))) := by
  rw [observe_spec l m obs boot hnd] at h
  obtain ⟨p, hp, hx⟩ := List.mem_flatMap.mp h
  obtain ⟨d', n⟩ := p
  have : d' = d := (dropsOf_mem_fst d' _ d x hx).symm
  subst this
  refine ⟨n, hp, ?_⟩
  · cases hl : prevOf l m boot d' with
    | none =>
      left
      rw [hl, dropsOf_none] at hx
      by_cases hn : n > 0
      · simp [hn] at hx; exact ⟨rfl, hn, by omega⟩
      · simp [hn] at hx
    | some q =>
      right
      refine ⟨q, rfl, ?_⟩
      rw [hl, dropsOf_some] at hx
      by_cases h1 : q < n
      · simp [h1] at hx; exact Or.inl ⟨h1, by omega⟩
      · by_cases h2 : n < q
        · by_cases h3 : n > 0
          · simp [h1, h2, h3] at hx; exact Or.inr ⟨h2, h3, by omega⟩
          · simp [h1, h2, h3] at hx
        · simp [h1, h2] at hx

theorem observe_drops_of_rise (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (d : String) (n q : Nat) (hnd : (obs.map (·.1)).Nodup) (hmem : (d, n) ∈ obs)
    (hq : prevOf l m boot d = some q) (hlt : q < n) :
    (d, n - q) ∈ (observeCore l m obs boot).2.1 := by
  rw [observe_spec l m obs boot hnd]
  apply List.mem_flatMap.mpr
  refine ⟨(d, n), hmem, ?_⟩
  simp only []
  rw [hq, dropsOf_some]
  simp [hlt]

-- ═══════════════════════════════════════════════════════════════════════
-- 4. `request` and `requestRebuild`
-- ═══════════════════════════════════════════════════════════════════════

theorem request_counters (l : Ledger) (m d : String) (n : Nat) (sight : RequestSight) :
    (request l m d n sight).counters = l.counters ∧
    (request l m d n sight).initialized = l.initialized := by
  unfold request
  split <;> exact ⟨rfl, rfl⟩

/-- `request` never removes or renames an entry: the destinations after are the
    destinations before, plus `dest` when it was new. -/
theorem request_dests (l : Ledger) (m d : String) (n : Nat) (sight : RequestSight) :
    (request l m d n sight).entries.map (·.dest) =
      if l.entries.any (·.dest == d) then l.entries.map (·.dest) else l.entries.map (·.dest) ++ [d] := by
  unfold request
  cases hf : l.entries.find? (·.dest == d) with
  | none =>
    have hany : l.entries.any (·.dest == d) = false := by
      cases h : l.entries.any (·.dest == d)
      · rfl
      · obtain ⟨x, hx, hxd⟩ := List.any_eq_true.mp h
        exact absurd hxd (by simpa using List.find?_eq_none.mp hf x hx)
    simp [hany]
  | some e =>
    have hany : l.entries.any (·.dest == d) = true :=
      List.any_eq_true.mpr ⟨e, List.mem_of_find?_eq_some hf, List.find?_some (p := fun (x : Entry) => x.dest == d) hf⟩
    simp only [hany, if_true, List.map_map]
    apply List.map_congr_left
    intro x _
    simp only [Function.comp]
    split
    · next h => simp at h; simp [h]
    · split <;> simp_all

/-- THEOREM (a destination is one entry). Requesting the same destination twice
    opens no second entry: after the first call the destination is present, and
    the second call leaves the list of destinations as it found it. -/
theorem request_twice_dests (l : Ledger) (m d : String) (n n' : Nat) (s s' : RequestSight) :
    (request (request l m d n s) m d n' s').entries.map (·.dest) =
      (request l m d n s).entries.map (·.dest) := by
  have h1 := request_dests l m d n s
  have hany : (request l m d n s).entries.any (·.dest == d) = true := by
    have : d ∈ (request l m d n s).entries.map (·.dest) := by
      rw [h1]
      split
      · next h =>
        obtain ⟨x, hx, hxd⟩ := List.any_eq_true.mp h
        exact List.mem_map.mpr ⟨x, hx, by simpa using hxd⟩
      · simp
    obtain ⟨e, he, hed⟩ := List.mem_map.mp this
    exact List.any_eq_true.mpr ⟨e, he, by simp [hed]⟩
  rw [request_dests, if_pos hany]

/-- THEOREM (`requestRebuild` is idempotent). -/
theorem requestRebuild_idem (l l' : Ledger) (m k : String) (b : Bool)
    (h : requestRebuild l m k = (l', b)) : requestRebuild l' m k = (l', false) := by
  unfold requestRebuild at h ⊢
  split at h
  · simp at h; obtain ⟨rfl, _⟩ := h; simp_all
  · simp at h
    obtain ⟨rfl, _⟩ := h
    simp

-- ═══════════════════════════════════════════════════════════════════════
-- 5. One pass of `observeCore` (no checks), fixed point
-- ═══════════════════════════════════════════════════════════════════════

/-- Main's `observeDrops` (Main.lean, "for (dest, d) in newDrops"), without the logging
    and without the ownership hold that follows a request: the master's counters are
    folded into the ledger and every new drop becomes (or extends) a request. -/
def applyDrops (l : Ledger) (m : String) (drops : List (String × Nat))
    (sight : String → RequestSight) : Ledger :=
  drops.foldl (fun l p => request l m p.1 p.2 (sight p.1)) l

def corePass (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (sight : String → RequestSight) : Ledger :=
  applyDrops (observeCore l m obs boot).1 m (observeCore l m obs boot).2.1 sight

theorem applyDrops_keeps (m : String) (sight : String → RequestSight) :
    ∀ (drops : List (String × Nat)) (l : Ledger),
    (applyDrops l m drops sight).counters = l.counters ∧
    (applyDrops l m drops sight).initialized = l.initialized := by
  intro drops
  induction drops with
  | nil => intro l; exact ⟨rfl, rfl⟩
  | cons p drops ih =>
    intro l
    simp only [applyDrops, List.foldl_cons] at ih ⊢
    obtain ⟨h1, h2⟩ := ih (request l m p.1 p.2 (sight p.1))
    obtain ⟨h3, h4⟩ := request_counters l m p.1 p.2 (sight p.1)
    exact ⟨h1.trans h3, h2.trans h4⟩

/-- The ledger a pass leaves already holds the counters it observed, so observing again
    asks for nothing and changes nothing. -/
theorem observeCore_after_pass (l : Ledger) (m : String) (obs : List (String × Nat))
    (boot : Option Nat) (sight : String → RequestSight)
    (hnd : (obs.map (·.1)).Nodup) (hks : KeysSplit m boot obs) :
    observeCore (corePass l m obs boot sight) m obs boot = (corePass l m obs boot sight, [], []) := by
  have hspec := observe_spec l m obs boot hnd
  have hk := applyDrops_keeps m sight (observeCore l m obs boot).2.1 (observeCore l m obs boot).1
  have hc : (corePass l m obs boot sight).counters =
      (keyed m boot obs).foldl upd (startCounters l m boot) := by
    show (applyDrops (observeCore l m obs boot).1 m (observeCore l m obs boot).2.1 sight).counters = _
    rw [hk.1, hspec]
  have hi : (corePass l m obs boot sight).initialized = true := by
    show (applyDrops (observeCore l m obs boot).1 m (observeCore l m obs boot).2.1 sight).initialized = true
    rw [hk.2, hspec]
  have hfix := observeCore_fixed (corePass l m obs boot sight) m obs boot hnd hks
    (startCounters l m boot) (fun c hc => (List.mem_filter.mp hc).2) hc
  have hself : { corePass l m obs boot sight with initialized := true } = corePass l m obs boot sight := by
    generalize corePass l m obs boot sight = L at hi
    cases L; simp_all
  rw [hself] at hfix
  exact hfix

/-- THEOREM (a whole observation pass is a fixed point). Running the pass a second
    time with the same cumulative counters yields exactly the ledger the first
    pass produced: no new entry, no extra drops, the same counters. -/
theorem corePass_idempotent (l : Ledger) (m : String) (obs : List (String × Nat))
    (boot : Option Nat) (sight : String → RequestSight)
    (hnd : (obs.map (·.1)).Nodup) (hks : KeysSplit m boot obs) :
    corePass (corePass l m obs boot sight) m obs boot sight = corePass l m obs boot sight := by
  have hfix := observeCore_after_pass l m obs boot sight hnd hks
  unfold corePass at hfix ⊢
  rw [hfix]
  rfl


-- ═══════════════════════════════════════════════════════════════════════
-- 6. `observe` (what Main calls): the checks, and the boot id coming and going
-- ═══════════════════════════════════════════════════════════════════════

/-- The master key and every destination can be carried in a counter key. -/
def Valid (m : String) (obs : List (String × Nat)) : Prop :=
  barFree m = true ∧ ∀ p ∈ obs, barFree p.1 = true

theorem keysSplit_of_valid (m : String) (boot : Option Nat) (obs : List (String × Nat))
    (hv : Valid m obs) : KeysSplit m boot obs := by
  intro b _ p hp
  exact keyParts_some m p.1 b hv.1 (hv.2 p hp)

/-- A master key with a `|` in it accounts nothing. -/
theorem observe_bar_master (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (h : barFree m = false) : observe l m obs boot = (l, [], []) := by
  unfold observe
  simp [h]

/-- No boot id while the ledger holds this master's boot-keyed counters: not observed. -/
theorem observe_skip (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (h : (boot.isNone && hasBootKey l m) = true) : observe l m obs boot = (l, [], []) := by
  unfold observe
  simp [h]

theorem observe_valid (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hv : Valid m obs) (hb : (boot.isNone && hasBootKey l m) = false) :
    observe l m obs boot = observeCore l m obs boot := by
  unfold observe
  rw [hv.1, hb]
  have : obs.filter (fun p => barFree p.1) = obs := List.filter_eq_self.mpr hv.2
  simp [this]

/-- A destination with a `|` in it is not accounted: `observe` is `observe` of the rest. -/
theorem observe_ignores_bar_dest (l : Ledger) (m : String) (obs : List (String × Nat))
    (boot : Option Nat) :
    observe l m obs boot = observe l m (obs.filter fun p => barFree p.1) boot := by
  unfold observe
  simp only [List.filter_filter, Bool.and_self]

/-- Every destination `observe` attributes a drop to is a destination that can be carried in a
    counter key. -/
theorem observe_drops_barFree (l : Ledger) (m : String) (obs : List (String × Nat))
    (boot : Option Nat) (hnd : (obs.map (·.1)).Nodup) (d : String) (x : Nat)
    (h : (d, x) ∈ (observe l m obs boot).2.1) : barFree d = true := by
  unfold observe at h
  split at h
  · simp at h
  · have hnd' : ((obs.filter fun p => barFree p.1).map (·.1)).Nodup :=
      (List.filter_sublist).map _ |>.nodup hnd |> fun h => h
    obtain ⟨n, hn, _⟩ := observe_drops_mem l m _ boot d x hnd' h
    exact (List.mem_filter.mp hn).2

theorem keyParts_some_of (m d : String) (b : Nat) (hm : barFree m = true) (hd : barFree d = true) :
    isBootKey m (counterKey m d (some b)) = true := by
  simp [isBootKey, keyParts_some m d b hm hd]

theorem keyParts_none_not_boot (m d : String) (hm : barFree m = true) (hd : barFree d = true) :
    isBootKey m (counterKey m d none) = false := by
  simp [isBootKey, keyParts_none m d hm hd]

-- lookups -----------------------------------------------------------------

theorem lookup_some_mem {β} (k : String) (L : List (String × β)) (v : β)
    (h : L.lookup k = some v) : (k, v) ∈ L := by
  induction L with
  | nil => simp [List.lookup] at h
  | cons p L ih =>
    obtain ⟨k', v'⟩ := p
    simp only [List.lookup] at h
    by_cases hk : k == k'
    · simp [hk] at h
      have : k = k' := by simpa using hk
      subst this; subst h; simp
    · simp [hk] at h
      exact List.mem_cons_of_mem _ (ih h)

theorem lookup_filter_same {β} (f : String × β → Bool) (k : String) :
    ∀ (L : List (String × β)), (∀ c ∈ L, c.1 = k → f c = true) →
    (L.filter f).lookup k = L.lookup k := by
  intro L
  induction L with
  | nil => intro _; rfl
  | cons p L ih =>
    intro h
    obtain ⟨k', v'⟩ := p
    have ih' := ih (fun c hc => h c (List.mem_cons_of_mem _ hc))
    by_cases hk : k == k'
    · have : k = k' := by simpa using hk
      subst this
      have hf := h (k, v') (by simp) rfl
      simp [List.filter, hf, List.lookup]
    · have hk' : ¬ k = k' := by simpa using hk
      cases hf : f (k', v') <;> simp [List.filter, hf, List.lookup, hk, ih']

theorem lookup_filter_none {β} (f : String × β → Bool) (k : String) :
    ∀ (L : List (String × β)), L.lookup k = none → (L.filter f).lookup k = none := by
  intro L
  induction L with
  | nil => intro _; rfl
  | cons p L ih =>
    intro h
    obtain ⟨k', v'⟩ := p
    by_cases hk : k == k'
    · simp [List.lookup, hk] at h
    · have h' : L.lookup k = none := by simpa [List.lookup, hk] using h
      cases hf : f (k', v') <;> simp [List.filter, hf, List.lookup, hk, ih h']

-- the invariant -------------------------------------------------------------

/-- The ledger holds every observed value under this boot id's key. -/
def HoldBoot (L : Ledger) (m : String) (obs : List (String × Nat)) (b : Nat) : Prop :=
  ∀ p ∈ obs, L.counters.lookup (counterKey m p.1 (some b)) = some p.2

/-- The ledger holds every observed value under the boot-less key, and no boot-keyed counter of
    this master (a master accounted before its boot id could be read). -/
def HoldLegacy (L : Ledger) (m : String) (obs : List (String × Nat)) : Prop :=
  hasBootKey L m = false ∧ ∀ p ∈ obs, L.counters.lookup (counterKey m p.1 none) = some p.2

/-- The ledger's baseline for this master's process (boot id `b`, or not read yet). -/
def Hold (L : Ledger) (m : String) (obs : List (String × Nat)) (b : Nat) : Prop :=
  HoldBoot L m obs b ∨ HoldLegacy L m obs

theorem hasBootKey_of_lookup (L : Ledger) (m d : String) (b v : Nat)
    (hm : barFree m = true) (hd : barFree d = true)
    (h : L.counters.lookup (counterKey m d (some b)) = some v) : hasBootKey L m = true := by
  have hmem := lookup_some_mem _ _ _ h
  unfold hasBootKey
  apply List.any_eq_true.mpr
  exact ⟨_, hmem, keyParts_some_of m d b hm hd⟩

theorem lookup_boot_none (L : Ledger) (m d : String) (b : Nat)
    (hm : barFree m = true) (hd : barFree d = true) (h : hasBootKey L m = false) :
    L.counters.lookup (counterKey m d (some b)) = none := by
  cases hl : L.counters.lookup (counterKey m d (some b)) with
  | none => rfl
  | some v => rw [hasBootKey_of_lookup L m d b v hm hd hl] at h; exact absurd h (by decide)

/-- After `observeCore` every observed destination's value is under this pass's key. -/
theorem core_lookup (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup) :
    ∀ p ∈ obs, (observeCore l m obs boot).1.counters.lookup (counterKey m p.1 boot) = some p.2 := by
  intro p hp
  rw [observe_spec l m obs boot hnd]
  simp only []
  have hK := keyed_keys_nodup m boot obs hnd
  rw [upd_fold _ hK, lookup_append]
  have h0 : (dropKeys ((keyed m boot obs).map (·.1)) (startCounters l m boot)).lookup
      (counterKey m p.1 boot) = none := by
    apply lookup_none_of
    intro c hc he
    have hc' := (List.mem_filter.mp hc).2
    have hmem : counterKey m p.1 boot ∈ (keyed m boot obs).map (·.1) :=
      List.mem_map.mpr ⟨(counterKey m p.1 boot, p.2), List.mem_map.mpr ⟨p, hp, rfl⟩, rfl⟩
    have ht : ((keyed m boot obs).map (·.1)).contains (counterKey m p.1 boot) = true :=
      List.elem_eq_true_of_mem hmem
    rw [he, ht] at hc'
    exact absurd hc' (by decide)
  rw [h0, lookup_keyed m boot obs hnd p hp]
  rfl

theorem core_entries (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup) : (observeCore l m obs boot).1.entries = l.entries := by
  rw [observe_spec l m obs boot hnd]

/-- A boot-less pass over a ledger with no boot-keyed counters of the master leaves none. -/
theorem core_noBootKey (l : Ledger) (m : String) (obs : List (String × Nat))
    (hnd : (obs.map (·.1)).Nodup) (hv : Valid m obs) (h : hasBootKey l m = false) :
    hasBootKey (observeCore l m obs none).1 m = false := by
  cases hh : hasBootKey (observeCore l m obs none).1 m
  · rfl
  · exfalso
    obtain ⟨c, hc, hb⟩ := List.any_eq_true.mp (show (observeCore l m obs none).1.counters.any _ = true from hh)
    rw [observe_spec l m obs none hnd] at hc
    simp only [] at hc
    rw [upd_fold _ (keyed_keys_nodup m none obs hnd)] at hc
    rcases List.mem_append.mp hc with hc | hc
    · have hc := (List.mem_filter.mp (List.mem_filter.mp hc).1).1
      have : hasBootKey l m = true := by
        unfold hasBootKey
        exact List.any_eq_true.mpr ⟨c, hc, hb⟩
      rw [this] at h; exact absurd h (by decide)
    · obtain ⟨p, hp, rfl⟩ := List.mem_map.mp hc
      have hb' : isBootKey m (counterKey m p.1 none) = true := hb
      rw [keyParts_none_not_boot m p.1 hv.1 (hv.2 p hp)] at hb'
      exact absurd hb' (by decide)

/-- THEOREM (one pass, whichever way the boot id reads). From a ledger that holds this process's
    baseline, a pass whose boot id is unreadable (`none`) or the same one (`some b`) attributes
    nothing, keeps the entries, and leaves a ledger that still holds the baseline. -/
theorem step_hold (L : Ledger) (m : String) (obs : List (String × Nat)) (b : Nat) (β : Option Nat)
    (hv : Valid m obs) (hnd : (obs.map (·.1)).Nodup) (hβ : β = none ∨ β = some b)
    (h : Hold L m obs b) :
    (observe L m obs β).2 = ([], []) ∧ Hold (observe L m obs β).1 m obs b ∧
      (observe L m obs β).1.entries = L.entries := by
  by_cases hs : (β.isNone && hasBootKey L m) = true
  · rw [observe_skip L m obs β hs]
    exact ⟨rfl, h, rfl⟩
  · have hs' : (β.isNone && hasBootKey L m) = false := by simpa using hs
    rw [observe_valid L m obs β hv hs']
    have hent := core_entries L m obs β hnd
    have hstart_some : ∀ (k : String) (v : Nat), L.counters.lookup k = some v →
        (∀ c ∈ L.counters, c.1 = k → (!otherProcess m (some b) c.1) = true) →
        (startCounters L m (some b)).lookup k = some v := by
      intro k v hk hc
      unfold startCounters
      rw [lookup_filter_same _ k L.counters (fun c hc' he => by simpa using hc c hc' he)]
      exact hk
    have hstart_none : ∀ (k : String) (v : Nat), L.counters.lookup k = some v →
        (startCounters L m none).lookup k = some v := by
      intro k v hk
      unfold startCounters
      rw [lookup_filter_same _ k L.counters (fun c _ _ => by simp [otherProcess])]
      exact hk
    rcases h with hB | ⟨hNo, hL⟩
    · rcases hβ with rfl | rfl
      · -- no boot id read, yet the ledger holds boot-keyed counters: only possible with nothing observed
        have hbk : hasBootKey L m = false := by simpa using hs'
        have hobs : obs = [] := by
          cases obs with
          | nil => rfl
          | cons p _ =>
            exfalso
            have := hasBootKey_of_lookup L m p.1 b p.2 hv.1 (hv.2 p (by simp)) (hB p (by simp))
            rw [hbk] at this
            exact absurd this (by decide)
        subst hobs
        exact ⟨rfl, Or.inl (by intro p hp; simp at hp), hent⟩
      · have hq : ∀ p ∈ obs, prevOf L m (some b) p.1 = some p.2 := by
          intro p hp
          unfold prevOf
          rw [hstart_some _ _ (hB p hp)]
          · rfl
          · intro c _ he
            rw [he]
            simp [otherProcess, keyParts_some m p.1 b hv.1 (hv.2 p hp)]
        exact ⟨observe_quiet L m obs (some b) hnd hq, Or.inl (core_lookup L m obs (some b) hnd), hent⟩
    · rcases hβ with rfl | rfl
      · have hq : ∀ p ∈ obs, prevOf L m none p.1 = some p.2 := by
          intro p hp
          unfold prevOf
          rw [hstart_none _ _ (hL p hp)]
          rfl
        exact ⟨observe_quiet L m obs none hnd hq,
          Or.inr ⟨core_noBootKey L m obs hnd hv hNo, core_lookup L m obs none hnd⟩, hent⟩
      · have hq : ∀ p ∈ obs, prevOf L m (some b) p.1 = some p.2 := by
          intro p hp
          unfold prevOf startCounters
          rw [lookup_filter_none _ _ _ (lookup_boot_none L m p.1 b hv.1 (hv.2 p hp) hNo)]
          exact hL p hp
        exact ⟨observe_quiet L m obs (some b) hnd hq, Or.inl (core_lookup L m obs (some b) hnd), hent⟩

/-- A first pass that is accounted (not the unreadable-boot skip) leaves the baseline, whichever
    boot id it read. -/
theorem first_hold (L : Ledger) (m : String) (obs : List (String × Nat)) (b : Nat) (β : Option Nat)
    (hv : Valid m obs) (hnd : (obs.map (·.1)).Nodup) (hβ : β = none ∨ β = some b)
    (hacc : (β.isNone && hasBootKey L m) = false) :
    Hold (observe L m obs β).1 m obs b := by
  rw [observe_valid L m obs β hv hacc]
  rcases hβ with rfl | rfl
  · exact Or.inr ⟨core_noBootKey L m obs hnd hv (by simpa using hacc), core_lookup L m obs none hnd⟩
  · exact Or.inl (core_lookup L m obs (some b) hnd)

/-- Main's pass: the drops `observe` attributes become requests. -/
def pass (L : Ledger) (m : String) (obs : List (String × Nat)) (β : Option Nat)
    (sight : String → RequestSight) : Ledger :=
  applyDrops (observe L m obs β).1 m (observe L m obs β).2.1 sight

theorem Hold_counters {L L' : Ledger} (m : String) (obs : List (String × Nat)) (b : Nat)
    (hc : L.counters = L'.counters) (h : Hold L m obs b) : Hold L' m obs b := by
  unfold Hold HoldBoot HoldLegacy hasBootKey at h ⊢
  rw [← hc]
  exact h

theorem pass_counters (L : Ledger) (m : String) (obs : List (String × Nat)) (β : Option Nat)
    (sight : String → RequestSight) :
    (pass L m obs β sight).counters = (observe L m obs β).1.counters :=
  (applyDrops_keeps m sight _ _).1

theorem pass_step (L : Ledger) (m : String) (obs : List (String × Nat)) (b : Nat) (β : Option Nat)
    (sight : String → RequestSight)
    (hv : Valid m obs) (hnd : (obs.map (·.1)).Nodup) (hβ : β = none ∨ β = some b)
    (h : Hold L m obs b) :
    Hold (pass L m obs β sight) m obs b ∧ (pass L m obs β sight).entries = L.entries := by
  obtain ⟨hq, hh, he⟩ := step_hold L m obs b β hv hnd hβ h
  have hd : (observe L m obs β).2.1 = [] := by rw [hq]
  have hp : pass L m obs β sight = (observe L m obs β).1 := by unfold pass; rw [hd]; rfl
  rw [hp]
  exact ⟨hh, he⟩

/-- A restart: the ledger an operator reads back from its status. -/
def restart (L : Ledger) : Ledger := (Ledger.fromJson? L.toJson).getD L

theorem restart_id (L : Ledger) : restart L = L := by
  unfold restart
  rw [ledger_roundtrip]
  rfl

/-- Passes with the given boot-id readings, the operator restarting before each one. -/
def runPasses (m : String) (obs : List (String × Nat)) (sight : String → RequestSight) :
    Ledger → List (Option Nat) → Ledger
  | L, [] => L
  | L, β :: bs => runPasses m obs sight (pass (restart L) m obs β sight) bs

theorem runPasses_hold (m : String) (obs : List (String × Nat)) (sight : String → RequestSight)
    (b : Nat) (hv : Valid m obs) (hnd : (obs.map (·.1)).Nodup) :
    ∀ (bs : List (Option Nat)) (L : Ledger), (∀ β ∈ bs, β = none ∨ β = some b) → Hold L m obs b →
      Hold (runPasses m obs sight L bs) m obs b ∧ (runPasses m obs sight L bs).entries = L.entries := by
  intro bs
  induction bs with
  | nil => intro L _ h; exact ⟨h, rfl⟩
  | cons β bs ih =>
    intro L hbs h
    simp only [runPasses, restart_id]
    obtain ⟨h1, e1⟩ := pass_step L m obs b β sight hv hnd (hbs β (by simp)) h
    obtain ⟨h2, e2⟩ := ih _ (fun x hx => hbs x (by simp [hx])) h1
    exact ⟨h2, e2.trans e1⟩

/-- THEOREM (a repair is not requested again for the same cumulative counters, whether the master's
    boot id reads or not). Observe a master's destinations once, with the boot id readable
    (`some b`) or not (`none`) — the pass not being the unreadable-boot skip. Then, however
    the boot id reads in the passes that follow — any sequence of `none` and `some b` — and
    however often the operator restarts in between, observing the same cumulative values leaves
    the ledger's entries as they were: no request is made or extended.

    `restart` is the `Ledger.toJson`/`fromJson?` round trip of the Json tree. Compressing that to
    text, parsing it, the write to the FlareCluster status, and the order Main calls
    these in, are not part of it. -/
theorem no_repeat_request (L : Ledger) (m : String) (obs : List (String × Nat))
    (sight : String → RequestSight) (b : Nat) (β1 : Option Nat) (bs : List (Option Nat))
    (hv : Valid m obs) (hnd : (obs.map (·.1)).Nodup)
    (hβ1 : β1 = none ∨ β1 = some b) (hbs : ∀ β ∈ bs, β = none ∨ β = some b)
    (hacc : (β1.isNone && hasBootKey L m) = false) :
    (runPasses m obs sight (pass L m obs β1 sight) bs).entries = (pass L m obs β1 sight).entries ∧
    Hold (runPasses m obs sight (pass L m obs β1 sight) bs) m obs b := by
  have h1 : Hold (pass L m obs β1 sight) m obs b :=
    Hold_counters m obs b (pass_counters L m obs β1 sight).symm (first_hold L m obs b β1 hv hnd hβ1 hacc)
  obtain ⟨h2, e2⟩ := runPasses_hold m obs sight b hv hnd bs _ hbs h1
  exact ⟨e2, h2⟩

-- ═══════════════════════════════════════════════════════════════════════
-- 7. What the keys are, and concrete runs (by kernel evaluation)
-- ═══════════════════════════════════════════════════════════════════════

/-- THEOREM (keys). Every counter `observe` writes is `master|dest` or `master|dest|boot` for a
    master key and a destination that contain no `|`, and splits back to `[master, dest]` or
    `[master, dest, boot]`: the master is recovered as the first part, so a counter is never
    taken for another master's or another process's. -/
theorem observe_new_keys (l : Ledger) (m : String) (obs : List (String × Nat)) (boot : Option Nat)
    (hnd : (obs.map (·.1)).Nodup)
    (c : String × Nat) (hc : c ∈ (observe l m obs boot).1.counters) :
    c ∈ l.counters ∨
      (barFree m = true ∧ ∃ d, barFree d = true ∧ c.1 = counterKey m d boot ∧
        keyParts c.1 = (match boot with | some b => [m, d, toString b] | none => [m, d])) := by
  unfold observe at hc
  split at hc
  · exact Or.inl hc
  · next hcond =>
    have hbm : barFree m = true := by
      cases hb : barFree m
      · exfalso; apply hcond; simp [hb]
      · rfl
    have hnd' : ((obs.filter fun p => barFree p.1).map (·.1)).Nodup :=
      (List.filter_sublist).map _ |>.nodup hnd |> fun h => h
    rw [observe_spec l m _ boot hnd'] at hc
    simp only [] at hc
    rw [upd_fold _ (keyed_keys_nodup m boot _ hnd')] at hc
    rcases List.mem_append.mp hc with hc | hc
    · exact Or.inl (List.mem_filter.mp (List.mem_filter.mp hc).1).1
    · obtain ⟨p, hp, rfl⟩ := List.mem_map.mp hc
      have hpd := (List.mem_filter.mp hp).2
      refine Or.inr ⟨hbm, p.1, hpd, rfl, ?_⟩
      cases boot with
      | none => exact keyParts_none m p.1 hbm hpd
      | some b => exact keyParts_some m p.1 b hbm hpd

-- Concrete runs. The boot id is read, then not, then read again: one request.
#guard (observe {} "m" [("d", 3)] (some 1)).2.1 == [("d", 3)]
#guard
  let l1 := (observe {} "m" [("d", 3)] (some 1)).1
  let l2 := (observe l1 "m" [("d", 3)] none).1
  (observe l1 "m" [("d", 3)] none).2.1 == [] && (observe l2 "m" [("d", 3)] (some 1)).2.1 == [] && l2 == l1
-- none, then read: the boot-less value is the previous one (the counter has not moved)
#guard
  let l1 := (observe {} "m" [("d", 3)] none).1
  let l2 := (observe l1 "m" [("d", 3)] (some 1)).1
  (observe l1 "m" [("d", 3)] (some 1)).2.1 == [] && (observe l2 "m" [("d", 3)] none).2.1 == []
    && l2.counters == [(counterKey "m" "d" (some 1), 3)]
-- a destination or master key with a `|` is not accounted, so it cannot be requested twice
#guard (observe {} "m" [("a|b", 3)] (some 1)).2.1 == [] && (observe {} "m" [("a|b", 3)] (some 1)).1.counters == []
#guard (observe {} "m|x" [("d", 3)] (some 1)).2.1 == []

end FlareOperator.ReplicaRepair.Proofs
