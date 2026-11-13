/-
  StateMachine/HandoverRetryProofs.lean — the retry of an aborted ordered
  handover ends after finitely many attempts, and then the one-map drain
  takes the master (the 3dcfc5c S9 liveness defect: a retryable entry that
  held the drain with no end). Nothing assumed.

    (a) `step_attempt`: `step` never changes `attempt`.
    (b) `retryDecision_attempt`: a retry's entry has attempt = prev + 1
        (1 when new); `retryDecision_some_prev` adds: only when retryable.
    (c) `retryable_lt`, `drainHeldKeys_cons_aborted`: an entry at or past
        `maxAttempts` is not retryable, so its old master is not held by it.
        `drainHeldKeys_mem`: the hold is exactly the phases in progress or
        a retryable entry, under the cfg passed (the one `step` and
        `retryDecision` use).
    (d) `Reach` / `reach_retries_le` / `reach_exhausted`: along any
        sequence of `step`s and retries from an aborted entry, at most
        `maxAttempts − attempt` retries happen, and once they are used the
        entry is not retryable.
-/
import FlareOperator.StateMachine.Handover

namespace FlareOperator.Handover

/-! ## (a) step keeps the attempt -/

theorem toPhase_attempt (e : Entry) (p : Phase) (now : Nat) (why : String) :
    (toPhase e p now why).attempt = e.attempt := rfl

theorem halt_attempt (e : Entry) (why : String) : (halt e why).attempt = e.attempt := rfl

theorem replaceSuccessor_attempt (e e' : Entry) (now : Nat)
    (h : replaceSuccessor e now = some e') : e'.attempt = e.attempt := by
  unfold replaceSuccessor at h
  split at h
  · obtain rfl := Option.some.inj h
    rfl
  · cases h

set_option maxHeartbeats 4000000 in
theorem step_attempt (cfg : Config) (e : Entry) (o : Obs) :
    (step cfg e o).1.attempt = e.attempt := by
  unfold step
  dsimp only
  split
  all_goals
    repeat' split
    all_goals first
      | (have h := replaceSuccessor_attempt _ _ _ ‹replaceSuccessor _ _ = some _›
         exact h)
      | simp only [toPhase_attempt, halt_attempt]
      | skip

/-! ## (b) a retry's attempt -/

theorem noSuccessorAttempt_attempt (e : Entry) (now : Nat) :
    (noSuccessorAttempt e now).attempt = e.attempt + 1 := rfl

/-- Whatever entry `retryDecision` returns has attempt = previous + 1
    (1 when there was no previous entry). -/
theorem retryDecision_attempt (cfg : Config) (prev : Option Entry) (k uid : String)
    (now pIdx : Nat) (succ? : Option String) (e' : Entry)
    (h : retryDecision cfg prev k uid now pIdx succ? = some e') :
    e'.attempt = (prev.map (·.attempt + 1)).getD 1 := by
  unfold retryDecision at h
  cases hs : succ? with
  | some s =>
    rw [hs] at h
    simp only at h
    split at h
    · obtain rfl := Option.some.inj h
      rfl
    · cases h
  | none =>
    rw [hs] at h
    simp only at h
    split at h
    · split at h
      · cases prev with
        | none => cases h
        | some p =>
          simp only [Option.map_some] at h
          obtain rfl := Option.some.inj h
          rfl
      · cases h
    · cases h

/-- A retry (a previous entry exists) happens only for a retryable entry
    of the same old master pod, and its attempt is the previous + 1. -/
theorem retryDecision_some_prev (cfg : Config) (p : Entry) (k uid : String)
    (now pIdx : Nat) (succ? : Option String) (e' : Entry)
    (h : retryDecision cfg (some p) k uid now pIdx succ? = some e') :
    retryable cfg p = true ∧ e'.attempt = p.attempt + 1 := by
  refine ⟨?_, by simpa using retryDecision_attempt cfg (some p) k uid now pIdx succ? e' h⟩
  unfold retryDecision retryDue at h
  simp only [Option.isNone_some, Bool.false_or] at h
  split at h
  · rename_i hr
    simp only [Bool.and_eq_true] at hr
    exact hr.1.1.1
  · cases h

/-- A new entry (no previous one) starts at attempt 1. -/
theorem retryDecision_none_attempt (cfg : Config) (k uid : String) (now pIdx : Nat)
    (succ? : Option String) (e' : Entry)
    (h : retryDecision cfg none k uid now pIdx succ? = some e') : e'.attempt = 1 :=
  retryDecision_attempt cfg none k uid now pIdx succ? e' h

/-! ## (c) the attempts bound and the drain hold -/

theorem retryable_lt (cfg : Config) (e : Entry) (h : retryable cfg e = true) :
    e.attempt < cfg.maxAttempts := by
  unfold retryable at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  exact h.1.2

theorem not_retryable_of_ge (cfg : Config) (e : Entry) (h : cfg.maxAttempts ≤ e.attempt) :
    retryable cfg e = false := by
  cases hr : retryable cfg e
  · rfl
  · have := retryable_lt cfg e hr
    omega

/-- The drain holds an old master exactly for an entry in progress
    (requested … promoting) or retryable under `cfg`. -/
theorem drainHeldKeys_mem (l : Ledger) (cfg : Config) (k : String) :
    k ∈ drainHeldKeys l cfg ↔
      ∃ e ∈ l.entries, e.oldMaster = k ∧
        (e.phase == .requested || e.phase.oldIsDown || e.phase == .promoting
          || retryable cfg e) = true := by
  unfold drainHeldKeys
  simp only [List.mem_map, List.mem_filter]
  constructor
  · rintro ⟨e, ⟨he, hp⟩, rfl⟩
    exact ⟨e, he, rfl, hp⟩
  · rintro ⟨e, he, rfl, hp⟩
    exact ⟨e, ⟨he, hp⟩, rfl⟩

/-- An aborted entry holds its old master from the drain exactly when it is
    retryable under `cfg` (the same `cfg` as `step` and `retryDecision`). -/
theorem drainHeldKeys_cons_aborted (e : Entry) (es : List Entry) (cfg : Config)
    (h : e.phase = .aborted) :
    drainHeldKeys { entries := e :: es } cfg =
      (if retryable cfg e = true then [e.oldMaster] else []) ++ drainHeldKeys { entries := es } cfg := by
  unfold drainHeldKeys
  simp only [List.filter_cons, h]
  have h1 : (Phase.aborted == Phase.requested) = false := rfl
  have h2 : (Phase.aborted == Phase.promoting) = false := rfl
  cases hr : retryable cfg e <;> simp [Phase.oldIsDown, h1, h2]

/-- At or past `maxAttempts` an aborted entry does not hold its old master:
    the one-map drain takes it (other entries of the ledger are separate). -/
theorem drainHeldKeys_exhausted (e : Entry) (es : List Entry) (cfg : Config)
    (h : e.phase = .aborted) (hn : cfg.maxAttempts ≤ e.attempt) :
    drainHeldKeys { entries := e :: es } cfg = drainHeldKeys { entries := es } cfg := by
  rw [drainHeldKeys_cons_aborted e es cfg h, not_retryable_of_ge cfg e hn]
  simp

/-! ## (d) liveness: finitely many retries, then the drain

`Reach cfg e n e'`: from `e`, a sequence of `step`s (any observation) and
retries (`n` of them, each a `retryDecision` on the current entry) reaches
`e'`. The retries' arguments (pod, uid, time, successor choice) are free. -/

inductive Reach (cfg : Config) : Entry → Nat → Entry → Prop where
  | refl (e : Entry) : Reach cfg e 0 e
  | step {e : Entry} {n : Nat} {e' : Entry} (o : Obs) :
      Reach cfg e n e' → Reach cfg e n (step cfg e' o).1
  | retry {e : Entry} {n : Nat} {e' e'' : Entry} (k uid : String) (now pIdx : Nat)
      (succ? : Option String) :
      Reach cfg e n e' → retryDecision cfg (some e') k uid now pIdx succ? = some e'' →
      Reach cfg e (n + 1) e''

/-- Each retry adds one to the attempt; steps add nothing. -/
theorem reach_attempt {cfg : Config} {e : Entry} {n : Nat} {e' : Entry}
    (h : Reach cfg e n e') : e'.attempt = e.attempt + n := by
  induction h with
  | refl => rfl
  | step o _ ih => rw [step_attempt]; exact ih
  | retry k uid now pIdx succ? _ hd ih =>
    rw [(retryDecision_some_prev _ _ _ _ _ _ _ _ hd).2, ih]; omega

/-- A retry is made only from a retryable entry, so the attempt never passes
    `maxAttempts` by retrying. -/
theorem reach_le {cfg : Config} {e : Entry} {n : Nat} {e' : Entry}
    (h : Reach cfg e n e') : n = 0 ∨ e'.attempt ≤ cfg.maxAttempts := by
  induction h with
  | refl => exact Or.inl rfl
  | step o _ ih => rw [step_attempt]; exact ih
  | retry k uid now pIdx succ? hr hd ih =>
    right
    obtain ⟨hret, hat⟩ := retryDecision_some_prev _ _ _ _ _ _ _ _ hd
    have := retryable_lt cfg _ hret
    omega

/-- At most `maxAttempts − attempt` retries happen along any such sequence. -/
theorem reach_retries_le {cfg : Config} {e : Entry} {n : Nat} {e' : Entry}
    (h : Reach cfg e n e') : n ≤ cfg.maxAttempts - e.attempt := by
  have h1 := reach_attempt h
  rcases reach_le h with h2 | h2
  · omega
  · omega

/-- Once the retries are used up (attempt reached `maxAttempts`), the entry
    is not retryable ... -/
theorem reach_exhausted {cfg : Config} {e : Entry} {n : Nat} {e' : Entry}
    (h : Reach cfg e n e') (hn : cfg.maxAttempts - e.attempt ≤ n) (hle : e.attempt ≤ cfg.maxAttempts) :
    retryable cfg e' = false := by
  apply not_retryable_of_ge
  have := reach_attempt h
  omega

/-- ... and, being aborted, it does not hold the drain: the one-map drain
    takes the master (liveness; the 3dcfc5c S9 defect cannot recur). -/
theorem reach_drain_free {cfg : Config} {e : Entry} {n : Nat} {e' : Entry} (es : List Entry)
    (h : Reach cfg e n e') (hn : cfg.maxAttempts - e.attempt ≤ n) (hle : e.attempt ≤ cfg.maxAttempts)
    (hab : e'.phase = .aborted) :
    drainHeldKeys { entries := e' :: es } cfg = drainHeldKeys { entries := es } cfg := by
  apply drainHeldKeys_exhausted e' es cfg hab
  have := reach_attempt h
  omega

/-- A `noSuccessorAttempt` (the retry found no successor) is such a retry:
    `retryDecision` with no successor returns it, attempt + 1. -/
theorem retryDecision_no_successor (cfg : Config) (p : Entry) (k uid : String) (now pIdx : Nat)
    (hdue : retryDue cfg (some p) k uid now = true) :
    retryDecision cfg (some p) k uid now pIdx none = some (noSuccessorAttempt p now) := by
  unfold retryDecision
  simp [hdue]

end FlareOperator.Handover
