/-
  LeaseGuardSim.lean — model checks of the lease guard (StateMachine/LeaseGuard)
  against a SIMULATED API and clock.

  The real renewer and watchdog code runs unchanged on an injected `Api`
  (monotonic clock, renew patch, read, sleep). The world is a virtual-time,
  single-threaded model: while the renewer is blocked inside an API call the
  clock advances in 10 ms steps and, at every step, the watchdog (every
  500 ms), the competing new leader and the property run — so the watchdog is
  as independent of API latency here as the real task is.

  PROPERTY (every scenario): there is no instant at which the new leader
  holds the lease and the old leader still serves (health leader / index
  serving). The old leader's step-down costs `stepDownMs` after the guard
  fires (the real exit waits at most ~1 s for the label).

  The new leader follows the real takeover rule: it reads the lease (holder,
  resourceVersion) and, when the stamp it holds is older than the lease
  duration on ITS clock, applies a patch conditional on that resourceVersion
  (100 ms later: the read→CAS gap). A renew is a patch conditional on the
  holder (the real renewLease). Sending, applying and answering are separate
  instants, so a renew can land after the takeover.
-/
import FlareOperator.StateMachine.LeaseGuard

namespace FlareOperator.LeaseGuardSim

open FlareOperator.LeaseGuard

/-- renew behavior at a send time -/
inductive RB where
  /-- applies after `lat/2`, answers success at `lat` (a `lat` above the bound = a timeout, applied anyway) -/
  | ok (lat : Nat)
  /-- applies after `applyAfter`, the response comes after `respAfter` (a lost response: above any bound) -/
  | slow (applyAfter respAfter : Nat)
  /-- not applied, fails after `lat` -/
  | refused (lat : Nat)
  /-- ignores its bound: blocks for `dur`, never applied -/
  | hang (dur : Nat)

inductive RD where
  | ok (lat : Nat)
  | unreadable (lat : Nat)
  | hang (dur : Nat)

structure Knobs where
  renewB : Nat → RB := fun _ => .ok 50
  readB : Nat → RD := fun _ => .ok 50
  /-- our monotonic clock in permille of real time (1000 = exact) -/
  ratePermille : Nat := 1000
  competitor : Bool := true
  /-- a second renewer (the reconcile loop's renew), every 5 s at an offset of 2.5 s -/
  withLoop : Bool := false
  loopBlockedFrom : Nat := 1000000
  stepDownMs : Nat := 1000
  horizon : Nat := 90000

structure World where
  k : Knobs
  t : IO.Ref Nat
  holder : IO.Ref String
  stamp : IO.Ref String
  /-- the stamp's time as the lease expiry judge sees it -/
  stampAt : IO.Ref Nat
  rv : IO.Ref Nat
  events : IO.Ref (List (Nat × IO Unit))
  newHoldsAt : IO.Ref (Option Nat)
  casPending : IO.Ref (Option (Nat × Nat))
  stopAt : IO.Ref (Option Nat)
  firedAt : IO.Ref (Option Nat)
  serving : IO.Ref Bool
  violation : IO.Ref (Option Nat)
  ctr : IO.Ref Nat
  renewals : IO.Ref Nat
  lastWd : IO.Ref Nat
  lastLoop : IO.Ref Nat
  guard : IO.Ref (Option Guard)

def leaseMs : Nat := 15000

def stampTime (s : String) : Nat := ((s.splitOn ":").head!).toNat!

/-- apply a renew patch: the holder test -/
def applyRenew (w : World) (st : String) : IO Unit := do
  if (← w.holder.get) == "old" then
    w.stamp.set st
    w.stampAt.set (stampTime st)
    w.rv.modify (· + 1)

def step (w : World) (dt : Nat) : IO Unit := do
  let now := (← w.t.get) + dt
  w.t.set now
  -- due events (apply of a renew)
  let ev ← w.events.get
  let (due, rest) := ev.partition (fun (at_, _) => at_ ≤ now)
  w.events.set rest
  for (_, act) in due do act
  -- the new leader: read at the first instant the stamp is older than the lease, CAS 100 ms later
  if w.k.competitor && (← w.newHoldsAt.get).isNone then
    match ← w.casPending.get with
    | none =>
      if now ≥ (← w.stampAt.get) + leaseMs then
        w.casPending.set (some (now + 100, ← w.rv.get))
    | some (at_, rv0) =>
      if now ≥ at_ then
        w.casPending.set none
        if (← w.rv.get) == rv0 then
          w.holder.set "new"
          w.newHoldsAt.set (some now)
  -- the step-down completes `stepDownMs` after the guard fired
  if let some s := ← w.stopAt.get then
    if now ≥ s then w.serving.set false
  -- the reconcile loop's own renew (a second renewer feeding the same deadline)
  if w.k.withLoop && now ≥ (← w.lastLoop.get) + 5000 && now < w.k.loopBlockedFrom then
    w.lastLoop.set now
    if let some g := ← w.guard.get then
      let send := (now * w.k.ratePermille) / 1000
      let st := s!"{now}:L{← w.ctr.get}"
      w.ctr.modify (· + 1)
      w.events.modify (· ++ [(now + 30, do
        applyRenew w st
        if (← w.holder.get) == "old" then g.confirm send)])
  -- the property
  if (← w.newHoldsAt.get).isSome && (← w.serving.get) && (← w.violation.get).isNone then
    w.violation.set (some now)

def advance (w : World) (d : Nat) (wd : IO Unit) : IO Unit := do
  let mut left := d
  while left > 0 do
    let dt := min 10 left
    step w dt
    left := left - dt
    if (← w.t.get) ≥ (← w.lastWd.get) + 500 then
      w.lastWd.set (← w.t.get)
      wd
  pure ()

def ourNow (w : World) : IO Nat := do return ((← w.t.get) * w.k.ratePermille) / 1000

/-- Build the world, run the real renewer loop against it until the horizon. -/
def run (k : Knobs) : IO World := do
  let w : World := {
    k, t := ← IO.mkRef 0, holder := ← IO.mkRef "old", stamp := ← IO.mkRef "0:init",
    stampAt := ← IO.mkRef 0, rv := ← IO.mkRef 1, events := ← IO.mkRef [],
    newHoldsAt := ← IO.mkRef none, casPending := ← IO.mkRef none, stopAt := ← IO.mkRef none,
    firedAt := ← IO.mkRef none, serving := ← IO.mkRef true, violation := ← IO.mkRef none,
    ctr := ← IO.mkRef 0, renewals := ← IO.mkRef 0, lastWd := ← IO.mkRef 0, lastLoop := ← IO.mkRef 2500,
    guard := ← IO.mkRef none }
  let g ← Guard.new { identity := "old" } (fun _ => do
    w.firedAt.set (some (← w.t.get))
    w.stopAt.set (some ((← w.t.get) + k.stepDownMs)))
  w.guard.set (some g)
  -- the initial acquisition at t = 0 was a confirmed write sent at 0
  g.confirm 0
  let wdRef ← IO.mkRef (pure () : IO Unit)
  let api : Api := {
    now := ourNow w
    stamp := do
      let n ← w.ctr.get
      w.ctr.set (n + 1)
      return s!"{← w.t.get}:{n}"
    renew := fun st bound => do
      let ts ← w.t.get
      w.renewals.modify (· + 1)
      let wd ← wdRef.get
      match k.renewB ts with
      | .ok lat =>
        w.events.modify (· ++ [(ts + lat / 2, applyRenew w st)])
        if lat ≤ bound then
          advance w lat wd
          return .applied
        else
          advance w bound wd
          return .failed "timeout"
      | .slow a r =>
        w.events.modify (· ++ [(ts + a, applyRenew w st)])
        let d := min r bound
        advance w d wd
        if r ≤ bound then return .applied else return .failed "timeout"
      | .refused lat =>
        advance w (min lat bound) wd
        return .failed "refused"
      | .hang dur =>
        advance w dur wd
        return .failed "hung"
    read := fun bound => do
      let wd ← wdRef.get
      match k.readB (← w.t.get) with
      | .ok lat =>
        if lat ≤ bound then
          advance w lat wd
          return .lease (← w.holder.get) (← w.stamp.get)
        else
          advance w bound wd
          return .unreadable
      | .unreadable lat =>
        advance w (min lat bound) wd
        return .unreadable
      | .hang dur =>
        advance w dur wd
        return .unreadable
    sleep := fun ms => do
      if (← w.t.get) ≥ k.horizon then throw (IO.userError "horizon")
      advance w ((ms * 1000) / k.ratePermille) (← wdRef.get) }
  -- the watchdog check, run from `advance` (independent of the renewer's blocking)
  wdRef.set (do let _ ← watchdogTick api g; pure ())
  try renewerLoop api g catch _ => pure ()
  -- after the guard fired the renewer is gone: time still runs to the horizon
  let wd ← wdRef.get
  while (← w.t.get) < k.horizon do advance w 100 wd
  return w

/-- no instant with the new leader holding and the old one serving -/
def noViolation (w : World) : IO Bool := return (← w.violation.get).isNone

/-- the whole check list: (name, ok) -/
def results : IO (List (String × Bool)) := do
  let mut out : List (String × Bool) := []
  -- pure pieces
  let c : Config := { identity := "p" }
  out := out ++ [
    ("lease guard: cadence is a third of the lease (5000 ms)", c.cadenceMs == 5000),
    ("lease guard: deadline = send + lease - margin (send 100 -> 12100)", deadlineOf c 100 == 12100),
    ("lease guard: call bound = min(cap, time left): far deadline -> cap 4000", callBound c 0 12000 == 4000),
    ("lease guard: call bound = time left when below the cap", callBound c 10000 12000 == 2000),
    ("lease guard: call bound is at least 1 ms once the deadline passed", callBound c 13000 12000 == 1),
    ("lease guard: holds strictly before the deadline", holdsAt 11999 12000 && !holdsAt 12000 12000),
    ("lease guard: never confirmed (0) holds nothing", !holdsAt 0 0),
    ("lease guard: read-back with our holder and OUR stamp confirms",
      judgeReadBack "p" "s1" (.lease "p" "s1") == .confirmed),
    ("lease guard: read-back with our holder and an OLDER stamp extends nothing",
      judgeReadBack "p" "s2" (.lease "p" "s1") == .nothing),
    ("lease guard: read-back with another holder is a definite loss",
      judgeReadBack "p" "s1" (.lease "q" "s1") == .lost),
    ("lease guard: read-back with an empty holder is a definite loss",
      judgeReadBack "p" "s1" (.lease "" "s1") == .lost),
    ("lease guard: an unreadable lease extends nothing", judgeReadBack "p" "s1" .unreadable == .nothing)]
  -- duplicate confirmations: max of the send points, never decreasing
  let g ← Guard.new c (fun _ => pure ())
  g.confirm 1000
  g.confirm 500
  let a ← g.heldUntil.get
  g.confirm 2000
  g.confirm 1500
  let b ← g.heldUntil.get
  out := out ++ [("lease guard: duplicate confirmations keep the max send point (an older one never shortens or extends)", a == 13000 && b == 14000)]
  -- (0) healthy: 90 s, no spurious step-down, deadline always ahead
  let w0 ← run { horizon := 300000 }
  out := out ++ [("lease guard: healthy API for 300 s -> never fires, still serving, no new leader",
    (← w0.firedAt.get).isNone && (← w0.serving.get) && (← w0.newHoldsAt.get).isNone && (← w0.renewals.get) ≥ 55)]
  -- (1) an API call hangs > 15 s (ignoring its bound) from 20 s on
  let w1 ← run { renewB := fun t => if t ≥ 20000 then .hang 20000 else .ok 50,
                 readB := fun t => if t ≥ 20000 then .hang 20000 else .ok 50 }
  out := out ++ [("lease guard (1): a call hangs 20 s, bound ignored -> the watchdog fires at the deadline while the call is still blocked, before the new leader holds",
    (← noViolation w1) && (← w1.firedAt.get).isSome && (← w1.newHoldsAt.get).isSome &&
    ((← w1.firedAt.get).getD 0) ≤ 27500 &&
    ((← w1.firedAt.get).getD 0) + 1000 < ((← w1.newHoldsAt.get).getD 0))]
  -- (1b) one hang then recovery: the watchdog still fires (no resurrection after fail-closed)
  let w1b ← run { renewB := fun t => if t ≥ 10000 && t < 10100 then .hang 20000 else .ok 50 }
  out := out ++ [("lease guard (1b): one 20 s hang -> fail-closed at the deadline, not resurrected, no overlap",
    (← noViolation w1b) && (← w1b.firedAt.get).isSome && !(← w1b.serving.get))]
  -- (1c) bound-respecting stall: every call returns failed at its bound
  let w1c ← run { renewB := fun t => if t ≥ 20000 then .ok 60000 else .ok 50,
                  readB := fun t => if t ≥ 20000 then .ok 60000 else .ok 50 }
  out := out ++ [("lease guard (1c): API stalls (calls return failed at their bound) -> fired at the deadline, no overlap",
    (← noViolation w1c) && (← w1c.firedAt.get).isSome && (← w1c.newHoldsAt.get).isSome)]
  -- (2) renew refused + lease unreadable
  let w2 ← run { renewB := fun t => if t ≥ 10000 then .refused 100 else .ok 50,
                 readB := fun t => if t ≥ 10000 then .unreadable 100 else .ok 50 }
  out := out ++ [("lease guard (2): renew refused and the lease unreadable -> no extension, fail-closed at the deadline, no overlap",
    (← noViolation w2) && (← w2.firedAt.get).isSome && ((← w2.firedAt.get).getD 0) ≤ 22500)]
  -- (3) our holder but the renewTime is not ours (nobody takes over: the old reading must not extend)
  let w3 ← run { renewB := fun t => if t ≥ 10000 then .refused 100 else .ok 50, competitor := false }
  out := out ++ [("lease guard (3): lease still names this pod but with an OLDER renewTime (also expired) -> not held, fail-closed at the deadline even with no new leader",
    (← noViolation w3) && (← w3.firedAt.get).isSome && ((← w3.firedAt.get).getD 0) ≤ 22500 && (← w3.newHoldsAt.get).isNone)]
  -- (4a) patch applied, response lost, read-back confirms -> extends
  let w4 ← run { renewB := fun t => if t ≥ 10000 then .slow 30 1000000 else .ok 50, horizon := 120000 }
  out := out ++ [("lease guard (4a): patch applied but the response lost; the read-back shows our renewTime -> extends, never fires over 120 s",
    (← noViolation w4) && (← w4.firedAt.get).isNone && (← w4.serving.get) && (← w4.newHoldsAt.get).isNone)]
  -- (4b) response lost and the read-back fails
  let w4b ← run { renewB := fun t => if t ≥ 10000 then .slow 30 1000000 else .ok 50,
                  readB := fun t => if t ≥ 10000 then .unreadable 100 else .ok 50 }
  out := out ++ [("lease guard (4b): response lost and the read-back fails -> no extension, fail-closed in time (even though the server holds us)",
    (← noViolation w4b) && (← w4b.firedAt.get).isSome && ((← w4b.firedAt.get).getD 0) ≤ 22500)]
  -- (5) old and new racing: a grid of slow renews (apply / response delays) with readable and unreadable read-backs
  let mut raceOk := true
  let mut landedAfter := false
  for a in [0, 1000, 2000, 4000, 6000, 8000, 12000, 16000] do
    for r in [a, 1000000] do
      for rd in [true, false] do
        let w ← run { renewB := fun t => if t ≥ 5000 then .slow a r else .ok 50,
                      readB := fun _ => if rd then .ok 50 else .unreadable 100, horizon := 70000 }
        raceOk := raceOk && (← noViolation w)
        if (← w.holder.get) == "new" then landedAfter := true
  out := out ++ [("lease guard (5): old and new racing (renews applied 0-16 s after the send, with and without a readable read-back; takeover CAS by resourceVersion, renew by holder test) -> no instant of overlap in any combination",
    raceOk && landedAfter)]
  -- (5b) the old renew lands after the takeover: the holder test refuses it, the lease stays with the new leader
  let w5 ← run { renewB := fun t => if t ≥ 20000 then .slow 12000 1000000 else .ok 50, horizon := 80000 }
  out := out ++ [("lease guard (5b): a renew sent before the takeover lands after it -> refused by the holder test; the lease stays with the new leader, old not serving",
    (← noViolation w5) && (← w5.holder.get) == "new" && !(← w5.serving.get))]
  -- (6) loop renew + background renewer: duplicates and interleavings
  let w6 ← run { withLoop := true, horizon := 300000 }
  out := out ++ [("lease guard (6): reconcile-loop renew and background renewer both running for 300 s -> no spurious step-down",
    (← w6.firedAt.get).isNone && (← w6.serving.get))]
  let w6b ← run { withLoop := true, loopBlockedFrom := 20000,
                  renewB := fun t => if t ≥ 20000 then .hang 20000 else .ok 50,
                  readB := fun t => if t ≥ 20000 then .hang 20000 else .ok 50 }
  out := out ++ [("lease guard (6b): both renewers stall from 20 s -> fail-closed before the new leader holds",
    (← noViolation w6b) && (← w6b.firedAt.get).isSome && (← w6b.newHoldsAt.get).isSome)]
  -- clock-rate skew: slow (900 permille) and fast clocks stay inside the margin; a 25 %-slow clock is the control that breaks it
  let stall : Nat → RB := fun t => if t ≥ 20000 then .refused 100 else .ok 50
  let stallR : Nat → RD := fun t => if t ≥ 20000 then .unreadable 100 else .ok 50
  let wf ← run { renewB := stall, readB := stallR, ratePermille := 1100 }
  let ws ← run { renewB := stall, readB := stallR, ratePermille := 900 }
  let wx ← run { renewB := stall, readB := stallR, ratePermille := 700, stepDownMs := 0 }
  out := out ++ [("lease guard: a 10 % fast and a 10 % slow monotonic clock stay inside the margin (no overlap)",
    (← noViolation wf) && (← noViolation ws))]
  out := out ++ [("lease guard: CONTROL — a 30 % slow clock exceeds the margin and the model DOES see an overlap (the model can fail)",
    (← wx.violation.get).isSome)]
  return out

end FlareOperator.LeaseGuardSim
