/-
  StateMachine/LeaseFence.lean — the mid-pass lease check (Bridge.holdLeaseNow)
  that gates a broadcast, a history write, a handover step and a delete.

  The leader loop renews the 15 s lease at its top; a pass can outlast it. A
  lapse with no other holder is not a loss (41258283045: judging it one fenced
  every broadcast of every slow pass after it, for good), so the check renews.
  It affirms authority only from that renew (review of fac7410, P1):
   * the lease read names another holder → not held;
   * the renew failed → not held: the read before it may be older than the
     lease by the time the call returns (kubectl waits up to 30 s), and a
     standby may have taken the lease meanwhile;
   * the renew succeeded → held only while a margin of the lease remains,
     counted from BEFORE the renew was sent (its renewTime is no earlier
     than that): a renew answered late leaves too little of the lease for
     the gated action, and the lease may already have looked expired to a
     standby.
  Pure: Bridge measures the elapsed time.
-/

namespace FlareOperator.LeaseFence

/-- What a gated action needs left of the lease after the check: the bound of
    one API call (4 s) and a second of slack. -/
def marginMs : Nat := 5000

/-- The check's verdict. `elapsedMs`: from just before the renew was sent to
    its answer; `durationMs`: the lease's duration. -/
def held (holderIsMe : Bool) (renewOk : Bool) (elapsedMs durationMs : Nat) : Bool :=
  holderIsMe && renewOk && elapsedMs + marginMs ≤ durationMs

end FlareOperator.LeaseFence
