/-
  TemporalLogic.lean - Temporal logic definitions for verified Kubernetes operators

  This module provides TLA-style temporal logic definitions following the Lentil/LeanLTL
  pattern. An Execution is an infinite sequence of states (Nat -> State), and temporal
  predicates (TempPred) are properties of executions.

  Operators defined:
  - always ([] / box): property holds at every suffix
  - eventually (<> / diamond): property holds at some suffix
  - leads_to (~>): always(P => eventually(Q))
  - weak_fairness: if an action is always enabled, it eventually happens
  - stable: once true, stays true forever
  - lift_state: lift a state predicate to a temporal predicate
  - lift_action: lift an action predicate (on state pairs) to a temporal predicate

  Reference: anvil/src/temporal_logic/defs.rs, Lentil (verse-lab), LeanLTL (ITP'25)
  Ported verbatim from Gungnir/StateMachine/TemporalLogic.lean
-/

namespace FlareOperator.TemporalLogic

-- An Execution is an infinite sequence of states indexed by natural numbers.
-- In TLA+ this corresponds to a behavior.
structure Execution (T : Type) where
  /-- Map from time step to state -/
  stateAt : Nat -> T

-- Access the head (current state) of an execution.
def Execution.head {T : Type} (ex : Execution T) : T :=
  ex.stateAt 0

-- Access the next state (head of the tail).
def Execution.headNext {T : Type} (ex : Execution T) : T :=
  ex.stateAt 1

-- The suffix of an execution starting at position `pos`.
def Execution.suffix {T : Type} (ex : Execution T) (pos : Nat) : Execution T :=
  { stateAt := fun i => ex.stateAt (i + pos) }

-- A state predicate: a property of a single state.
abbrev StatePred (T : Type) := T -> Prop

-- An action predicate: a property of a pair of consecutive states.
abbrev ActionPred (T : Type) := T -> T -> Prop

-- A temporal predicate: a property of an entire execution.
-- This is the central type for expressing temporal logic formulas.
structure TempPred (T : Type) where
  /-- The predicate on executions -/
  pred : Execution T -> Prop

-- Check whether a temporal predicate is satisfied by a given execution.
def TempPred.satisfiedBy {T : Type} (tp : TempPred T) (ex : Execution T) : Prop :=
  tp.pred ex

-- Conjunction of temporal predicates (/\ in TLA+)
def TempPred.and {T : Type} (p q : TempPred T) : TempPred T :=
  { pred := fun ex => p.satisfiedBy ex ∧ q.satisfiedBy ex }

-- Disjunction of temporal predicates (\/ in TLA+)
def TempPred.or {T : Type} (p q : TempPred T) : TempPred T :=
  { pred := fun ex => p.satisfiedBy ex ∨ q.satisfiedBy ex }

-- Implication of temporal predicates (=> in TLA+)
def TempPred.implies {T : Type} (p q : TempPred T) : TempPred T :=
  { pred := fun ex => p.satisfiedBy ex -> q.satisfiedBy ex }

-- Negation of temporal predicates (~ in TLA+)
def TempPred.not {T : Type} (p : TempPred T) : TempPred T :=
  { pred := fun ex => ¬ p.satisfiedBy ex }

-- Lift a state predicate to a temporal predicate.
-- The temporal predicate is satisfied iff the state predicate holds at the current state.
def liftState {T : Type} (sp : StatePred T) : TempPred T :=
  { pred := fun ex => sp ex.head }

-- Lift a state predicate applied to the next state (prime / ').
def liftStatePrime {T : Type} (sp : StatePred T) : TempPred T :=
  { pred := fun ex => sp ex.headNext }

-- Lift an action predicate to a temporal predicate.
-- The temporal predicate holds iff the action predicate holds for the current
-- and next states.
def liftAction {T : Type} (ap : ActionPred T) : TempPred T :=
  { pred := fun ex => ap ex.head ex.headNext }

-- Always ([] / box): the temporal predicate holds on every suffix of the execution.
-- Formally: [](P) iff forall i, P holds on ex.suffix(i).
def always {T : Type} (tp : TempPred T) : TempPred T :=
  { pred := fun ex => ∀ i : Nat, tp.satisfiedBy (ex.suffix i) }

-- Eventually (<> / diamond): the temporal predicate holds on at least one suffix.
-- Formally: <>(P) iff exists i, P holds on ex.suffix(i).
def eventually {T : Type} (tp : TempPred T) : TempPred T :=
  { pred := fun ex => ∃ i : Nat, tp.satisfiedBy (ex.suffix i) }

-- Later (prime / '): the temporal predicate holds starting from the next state.
def later {T : Type} (tp : TempPred T) : TempPred T :=
  { pred := fun ex => tp.satisfiedBy (ex.suffix 1) }

-- Leads-to (~> in TLA+): it is always the case that if P holds, then Q eventually holds.
-- Formally: P ~> Q iff [](P => <>Q)
def TempPred.leadsTo {T : Type} (p q : TempPred T) : TempPred T :=
  always (p.implies (eventually q))

-- Entailment (|= in TLA+): P entails Q iff every execution satisfying P also satisfies Q.
def TempPred.entails {T : Type} (p q : TempPred T) : Prop :=
  ∀ ex : Execution T, p.satisfiedBy ex -> q.satisfiedBy ex

-- Validity: a temporal predicate is valid iff it holds on all executions.
def valid {T : Type} (tp : TempPred T) : Prop :=
  ∀ ex : Execution T, tp.satisfiedBy ex

-- Enabled: a state predicate that holds iff some transition from the given action
-- predicate is possible.
def enabled {T : Type} (ap : ActionPred T) : StatePred T :=
  fun s => ∃ s' : T, ap s s'

-- Weak fairness (WF): if the action is always enabled, it eventually happens.
-- WF(A) = []([]Enabled(A)) ~> A
-- Equivalently: []([]Enabled(A) => <>A)
def weakFairness {T : Type} (ap : ActionPred T) : TempPred T :=
  (always (liftState (enabled ap))).leadsTo (liftAction ap)

-- Stable: once the predicate becomes true, it remains true forever.
-- stable(P) = P => [](P)
def stable {T : Type} (tp : TempPred T) : TempPred T :=
  tp.implies (always tp)

-- Universal quantification over temporal predicates (\A in TLA+)
def tlaForall {T A : Type} (f : A -> TempPred T) : TempPred T :=
  { pred := fun ex => ∀ a : A, (f a).satisfiedBy ex }

-- Existential quantification over temporal predicates (\E in TLA+)
def tlaExists {T A : Type} (f : A -> TempPred T) : TempPred T :=
  { pred := fun ex => ∃ a : A, (f a).satisfiedBy ex }

-- True and false temporal predicates
def truePred {T : Type} : TempPred T :=
  liftState (fun _ : T => True)

def falsePred {T : Type} : TempPred T :=
  (truePred).not

-- Notation-like helpers for readability in theorem statements

-- Spec |= Property
notation:25 spec " ⊨ " prop => TempPred.entails spec prop

-- P ~> Q
notation:30 p " ~~> " q => TempPred.leadsTo p q

-- [] P
prefix:40 "□" => always

-- <> P
prefix:40 "◇" => eventually

-- ===========================================================================
-- Temporal Logic Lemmas for Liveness Proofs
-- ===========================================================================

/-- WF1 rule: if weak fairness holds for an action, and the action is always
    enabled, then the action eventually happens.
    WF(A) ∧ □(Enabled(A)) → ◇(A) -/
theorem wf1_rule {T : Type} (ap : ActionPred T) :
    ∀ ex, (weakFairness ap).satisfiedBy ex →
          (always (liftState (enabled ap))).satisfiedBy ex →
          (eventually (liftAction ap)).satisfiedBy ex := by
  intro ex hWF hEnabled
  have h0 := hWF 0
  simp only [TempPred.satisfiedBy, TempPred.implies, Execution.suffix] at h0
  apply h0
  intro i
  exact hEnabled (i + 0)

/-- Leads-to transitivity: if P ~> Q and Q ~> R, then P ~> R.
    (P ~> Q) ∧ (Q ~> R) → (P ~> R) -/
theorem leadsTo_trans {T : Type} (p q r : TempPred T) :
    ∀ ex, (p.leadsTo q).satisfiedBy ex →
          (q.leadsTo r).satisfiedBy ex →
          (p.leadsTo r).satisfiedBy ex := by
  intro ex hPQ hQR i hP
  obtain ⟨j, hQ⟩ := hPQ i hP
  simp only [TempPred.leadsTo, always, TempPred.implies, TempPred.satisfiedBy,
             eventually, Execution.suffix, liftAction, Execution.head, Execution.headNext] at *
  have hQ' : q.pred ⟨fun n => ex.stateAt (n + i + j)⟩ := by
    have eq : (⟨fun n => ex.stateAt (n + j + i)⟩ : Execution T) =
              ⟨fun n => ex.stateAt (n + i + j)⟩ := by congr 1; funext n; congr 1; omega
    rw [eq] at hQ; exact hQ
  have hQ'' : q.pred ⟨fun n => ex.stateAt (n + (i + j))⟩ := by
    have eq : (⟨fun n => ex.stateAt (n + i + j)⟩ : Execution T) =
              ⟨fun n => ex.stateAt (n + (i + j))⟩ := by congr 1; funext n; congr 1; omega
    rw [eq] at hQ'; exact hQ'
  obtain ⟨k, hR⟩ := hQR (i + j) hQ''
  exact ⟨j + k, by
    have eq : (⟨fun n => ex.stateAt (n + k + (i + j))⟩ : Execution T) =
              ⟨fun n => ex.stateAt (n + (j + k) + i)⟩ := by congr 1; funext n; congr 1; omega
    rw [eq] at hR; exact hR⟩

/-- Eventually monotonicity: if P → Q (pointwise), then ◇P → ◇Q. -/
theorem eventually_mono {T : Type} (p q : TempPred T) :
    (∀ ex, p.satisfiedBy ex → q.satisfiedBy ex) →
    ∀ ex, (eventually p).satisfiedBy ex → (eventually q).satisfiedBy ex := by
  intro hImpl ex ⟨i, hP⟩
  exact ⟨i, hImpl _ hP⟩

/-- Always strengthening: □P at a suffix implies □P at a later suffix. -/
theorem always_suffix {T : Type} (p : TempPred T) :
    ∀ ex (i : Nat), (always p).satisfiedBy ex → (always p).satisfiedBy (ex.suffix i) := by
  intro ex i hAlways j
  simp only [Execution.suffix, TempPred.satisfiedBy, always] at *
  have h := hAlways (j + i)
  have eq : (⟨fun i_1 => ex.stateAt (i_1 + (j + i))⟩ : Execution T) =
            ⟨fun i_1 => ex.stateAt (i_1 + j + i)⟩ := by
    congr 1; funext n; congr 1; omega
  rw [eq] at h; exact h

end FlareOperator.TemporalLogic
