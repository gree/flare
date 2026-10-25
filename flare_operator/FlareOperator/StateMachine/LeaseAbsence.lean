/-
  LeaseAbsence.lean — when a pod that does not hold the leader Lease may CREATE it.

  A missing Lease is not evidence that nobody leads: it may have been deleted
  while the leader still serves until its local deadline (StateMachine/LeaseGuard:
  last confirmed renew send + lease − margin, then watchdog + step-down). Its
  renews after the deletion get NotFound and confirm nothing, so it stops serving
  by deletion + (lease − margin) + watchdog + step-down. A pod that creates the
  Lease must therefore have observed it ABSENT, without interruption, for longer
  than that, measured on its own monotonic clock from the first absent reading.

  Only a NotFound reading counts as absent. A read error (Forbidden, timeout, an
  unreadable or stalled API) proves nothing: it neither starts nor continues the
  observation — the observation is RESET (fail closed). A Lease that is present
  (reappeared, any holder, any resourceVersion) resets it as well. The create
  itself is atomic on the API server (kubectl create): of several pods that all
  observed the absence one wins, the others get AlreadyExists and reset.

  The observation start is the moment the absent reply was RECEIVED (never
  earlier than the deletion it reflects), not the moment the request was sent.
-/

namespace FlareOperator.LeaseAbsence

/-- One reading of the leader Lease by a pod that does not run a lease guard. -/
inductive Reading where
  /-- the API server answered NotFound -/
  | absent
  /-- the Lease exists (any holder, any resourceVersion) -/
  | present
  /-- no answer that proves anything: Forbidden, timeout, stalled or unreadable -/
  | unreadable
  deriving Repr, BEq

/-- How long the Lease must have been observed absent before this pod may create it:
    the lease duration plus the lease guard's margin, so that a deleted Lease's last
    leader (which stops at most lease − margin + watchdog + step-down after the
    deletion) is gone even with the monotonic clocks of the two pods running at
    different rates (±10 % is checked in LeaseGuardSim). -/
def requiredMs (leaseMs marginMs : Nat) : Nat := leaseMs + marginMs

/-- The observation after one reading received at `now` (monotonic ms):
    `some since` = absent without interruption since `since`. -/
def observe (since : Option Nat) (r : Reading) (now : Nat) : Option Nat :=
  match r with
  | .absent => some (since.getD now)
  | .present => none
  | .unreadable => none

/-- May this pod create the Lease now? Only after an uninterrupted absence of `required` ms. -/
def mayCreate (since : Option Nat) (now required : Nat) : Bool :=
  match since with
  | some s => now ≥ s + required
  | none => false

/-- Classify a failed lease read from kubectl's error text: only the API server's NotFound
    is an absence; everything else (Forbidden, timeouts, a stalled API, a parse failure)
    is unreadable. -/
def classifyReadError (err : String) : Reading :=
  if (err.splitOn "(NotFound)").length > 1 then .absent else .unreadable

end FlareOperator.LeaseAbsence
