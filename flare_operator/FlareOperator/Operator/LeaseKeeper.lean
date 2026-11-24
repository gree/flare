/-
  Operator/LeaseKeeper.lean - the leader lease renewed on its own clock, not
  once per reconcile pass (flare-operator-slow-reconcile).

  The lease lasts 15 s. The loop used to renew it once at the top of each
  pass, so a pass longer than 15 s let it lapse: the standby took it over
  (generation + 1) and this process saw another holder and exited
  (`LOST LEASE -- exiting`, every 10-15 min under a production bulk fill, passes of
  18-31 s). The keeper renews every `periodMs` (a third of the lease) while a
  pass runs.

  Safety (what is NOT changed):
  * the keeper only RENEWS, and only when the holder is still this identity
    (`renewLease` tests `spec.holderIdentity`; a standby's takeover tests the
    resourceVersion, so they cannot both succeed). It never acquires and never
    touches `leaseTransitions`, the leadership generation that fences every
    broadcast version. Another holder seen = lost = the process exits, as it
    always did.
  * the broadcast fences stay: `holdLeaseNow` before every topology send and
    commit still renews and confirms with a margin, on the pass's own thread.
  * a transient API failure is not a loss while the last renewal is younger
    than the lease; after that the lease may be someone else's, so the keeper
    reports lost (fail closed) as the old loop did on the first failure.
  * a pass that never ends must not keep leadership for ever: once the pass
    has run longer than `passDeadlineMs` the keeper stops and reports lost.
-/

namespace FlareOperator.LeaseKeeper

inductive Renewal where
  /-- This identity holds the lease and the renew was accepted. -/
  | renewed
  /-- Another identity holds it (or the lease is not ours any more). -/
  | otherHolder
  /-- The lease could not be read or the renew failed (API slow or down). -/
  | failed
  deriving BEq, Repr

inductive Verdict where
  | keep
  | lost (why : String)
  deriving BEq, Repr

/-- One keeper decision. `sinceOkMs` = time since the last accepted renewal;
    `passAgeMs` = how long the running pass has been going (0 when none). -/
def decide (r : Renewal) (sinceOkMs leaseMs passAgeMs passDeadlineMs : Nat) : Verdict :=
  if passDeadlineMs > 0 && passAgeMs > passDeadlineMs then
    .lost s!"the pass has run {passAgeMs}ms, past its {passDeadlineMs}ms deadline; leadership is not held for a pass that does not end"
  else match r with
    | .renewed => .keep
    | .otherHolder => .lost "another holder has the lease"
    | .failed =>
      if sinceOkMs ≥ leaseMs then .lost s!"no renew was accepted for {sinceOkMs}ms (the lease is {leaseMs}ms)"
      else .keep

/-- The keeper loop. `renew` makes one renew attempt; `now` is a monotonic
    clock (ms); `passStart` is the start of the running pass (none = between
    passes); `sleep` waits; `done` ends the loop (tests); `onLost` is told once
    and the loop ends. `lastOk` is the time of the last accepted renewal (the
    caller renewed just before starting the keeper). -/
partial def run (renew : IO Renewal) (now : IO Nat) (passStart : IO (Option Nat))
    (sleep : Nat → IO Unit) (done : IO Bool) (onLost : String → IO Unit)
    (leaseMs periodMs passDeadlineMs : Nat) (lastOk : Nat) : IO Unit := do
  if ← done then return
  sleep periodMs
  if ← done then return
  let r ← renew
  let t ← now
  let lastOk := if r == .renewed then t else lastOk
  let passAge := match ← passStart with
    | some s => t - s
    | none => 0
  match decide r (t - lastOk) leaseMs passAge passDeadlineMs with
  | .keep => run renew now passStart sleep done onLost leaseMs periodMs passDeadlineMs lastOk
  | .lost why => onLost why

end FlareOperator.LeaseKeeper
