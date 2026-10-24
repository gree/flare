/-
  LeaseRenewal.lean — what the background lease renewer does with the result
  of one renewal.

  The leader lease lasts 15 s and the reconcile loop renews it once per
  iteration, while a pass can take 15-18 s. Every authority write (history,
  authority pass, topology broadcast, node map) is fenced by "this pod holds
  the lease AND it is not expired", so a long pass made the operator fence
  ITSELF mid-pass (e2f2f2f targeted runs: "the authoritative history is NOT
  written: this pod does not hold a valid lease" for ~14 min). A renewer task
  renews every leaseDuration/3 while the pod is the leader; the fences stay as
  they are and trip only if renewal itself stalls.

  The decision is pure. `renewLease` is a holder-test CAS, so a refused renew
  does not say WHY: the holder changed (the lease is lost — the same exit as
  the loop's LOST LEASE) or the API failed (transient — the next tick
  retries). The renewer therefore re-reads the lease after a refusal; only a
  read that shows ANOTHER holder is a loss. An unreadable lease is never read
  as lost (the per-iteration renew and the fences keep their own judgement).
-/

namespace FlareOperator.LeaseRenewal

/-- The renewal interval: a third of the lease duration, in milliseconds. -/
def renewIntervalMs (leaseDurationSeconds : Nat) : Nat :=
  leaseDurationSeconds * 1000 / 3

/-- What a re-read of the lease after a refused renew showed. -/
inductive LeaseRead where
  | holder (identity : String)
  | unreadable
  deriving Repr, BEq

inductive Decision where
  /-- keep running; renew again on the next tick -/
  | continue_
  /-- the lease belongs to another holder: take the loop's LOST LEASE path -/
  | lost
  deriving Repr, BEq

/-- `renewed`: the renewLease CAS succeeded. Otherwise `reread` is the lease
    read after the refusal. -/
def decide (identity : String) (renewed : Bool) (reread : LeaseRead) : Decision :=
  if renewed then .continue_
  else match reread with
    | .holder h => if h == identity then .continue_ else .lost
    | .unreadable => .continue_

end FlareOperator.LeaseRenewal
