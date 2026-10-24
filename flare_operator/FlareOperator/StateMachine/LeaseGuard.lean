/-
  LeaseGuard.lean — the leader's LOCAL, fail-closed lease deadline.

  Why it exists (review of 4dca9b6): the first lease renewer only retried. A
  renew that stalled (a kubectl whose process timeout is 30 s against a 15 s
  lease), a re-read that was unreadable, or a re-read that named this pod
  without looking at renewTime all counted as "still the leader", while the
  health status, the role=leader label and the index TCP server stayed up. An
  old leader whose API path was cut could therefore keep serving index traffic
  after a new leader had taken the lease.

  Design.
    heldUntil  = SEND point (monotonic ms, taken just BEFORE the request) of
                 the last POSITIVELY CONFIRMED hold + leaseDuration − margin.
    Positively confirmed =
      (a) a renew / create / takeover write that returned success, or
      (b) for an AMBIGUOUS write (timeout, lost response, any error) a
          read-back that shows holderIdentity == this pod AND renewTime ==
          the exact value THIS attempt wrote (unique per attempt, microsecond
          resolution). The deadline then extends from THAT attempt's send
          point.
    Nothing else extends anything: an unreadable lease, our holder with an
    older renewTime, an expired lease that still names us.
    The reconcile loop's own acquire/renew and the background renewer feed the
    same deadline (max of confirmed send points); duplicates are harmless.

    Every API call of the renewer is bounded by min(cap, time left to the
    deadline) (kubectl --request-timeout and the process timeout). Attempts
    start at a fixed cadence (leaseDuration/3 from the previous attempt's
    START) and never overlap.

    FAIL-CLOSED: a watchdog task, independent of API latency, checks the
    monotonic clock every `watchdogMs`. When now ≥ heldUntil with no newer
    confirmation — or a definite loss (another holder seen) — `onExpire` runs
    ONCE: index serving off, health leader=false, best-effort standby label,
    process exit. The authority fences additionally require `holds` locally.

  Safety argument (also in docs/RUNBOOK.md): a new leader can only acquire
  after the lease looks expired on the API server (renewTime + duration, by
  resourceVersion CAS). The renewTime we wrote is taken AFTER our send point
  (`now` first, then the stamp), so server expiry ≥ send + leaseDuration, and
  heldUntil = send + leaseDuration − margin lies `margin` before it. The old
  leader stops serving at heldUntil (+ watchdog period + step-down latency,
  both < margin), i.e. before any new leader can hold the lease.
  Assumptions: bounded clock-RATE drift between our monotonic clock and the
  API server's notion of time (the margin covers a rate error of
  margin/(leaseDuration − margin) ≈ 25 % at 3 s / 15 s) and bounded wall-clock
  offset between the pods' clocks for the expiry judgement (renewTime is a
  wall-clock value compared by the other pod); no wall-clock dependency on
  our side: heldUntil is monotonic only.
-/

namespace FlareOperator.LeaseGuard

structure Config where
  identity : String
  leaseMs : Nat := 15000
  /-- covers clock-rate skew and step-down latency -/
  marginMs : Nat := 3000
  /-- cap of one API call of the renewer -/
  capMs : Nat := 4000
  /-- period of the watchdog check -/
  watchdogMs : Nat := 500
  deriving Repr

/-- attempts start every leaseDuration/3 -/
def Config.cadenceMs (c : Config) : Nat := c.leaseMs / 3

/-- The local deadline a confirmed write sent at `sendMs` buys. -/
def deadlineOf (c : Config) (sendMs : Nat) : Nat := sendMs + c.leaseMs - c.marginMs

/-- Bound of one renewer API call: min(cap, time left to the deadline), at least 1 ms. -/
def callBound (c : Config) (now heldUntil : Nat) : Nat :=
  max 1 (min c.capMs (heldUntil - now))

/-- Held locally: strictly before the deadline (0 = never confirmed). -/
def holdsAt (now heldUntil : Nat) : Bool := now < heldUntil

inductive ReadOutcome where
  | lease (holder renewTime : String)
  | unreadable
  deriving Repr, BEq

inductive RenewOutcome where
  | applied
  /-- refused, timed out, lost response, any error: the write may or may not have landed -/
  | failed (why : String)
  deriving Repr, BEq

inductive Verdict where
  /-- the attempt's write is positively confirmed: extend from its send point -/
  | confirmed
  /-- another holder: definite loss -/
  | lost
  /-- nothing learned that extends the deadline -/
  | nothing
  deriving Repr, BEq

/-- Judge a read-back after an ambiguous write that wrote `stamp`. -/
def judgeReadBack (identity stamp : String) : ReadOutcome → Verdict
  | .unreadable => .nothing
  | .lease holder renewTime =>
    if holder == identity then (if renewTime == stamp then .confirmed else .nothing)
    else .lost

/-- The API the renewer and the watchdog depend on (injectable). -/
structure Api where
  /-- monotonic clock, ms -/
  now : IO Nat
  /-- a renewTime value unique to this attempt -/
  stamp : IO String
  /-- renew patch (holder test) writing `stamp`, bounded by the given ms -/
  renew : String → Nat → IO RenewOutcome
  /-- read the lease, bounded by the given ms -/
  read : Nat → IO ReadOutcome
  sleep : Nat → IO Unit

structure Guard where
  cfg : Config
  heldUntil : IO.Ref Nat
  lost : IO.Ref Bool
  fired : IO.Ref (Option String)
  onExpire : String → IO Unit

def Guard.new (cfg : Config) (onExpire : String → IO Unit) : IO Guard :=
  return { cfg, heldUntil := ← IO.mkRef 0, lost := ← IO.mkRef false, fired := ← IO.mkRef none, onExpire }

/-- A positively confirmed hold whose request was sent at `sendMs`. -/
def Guard.confirm (g : Guard) (sendMs : Nat) : IO Unit :=
  g.heldUntil.modify fun cur => max cur (deadlineOf g.cfg sendMs)

/-- The local fence: not lost, not fired, and before the deadline. -/
def Guard.holds (g : Guard) (now : Nat) : IO Bool := do
  return (← g.fired.get).isNone && !(← g.lost.get) && holdsAt now (← g.heldUntil.get)

/-- Fail closed, once. -/
def Guard.fire (g : Guard) (why : String) : IO Unit := do
  if (← g.fired.get).isSome then return
  g.fired.set (some why)
  g.onExpire why

/-- A definite loss: another holder was seen. -/
def Guard.markLost (g : Guard) (why : String) : IO Unit := do
  g.lost.set true
  g.fire why

/-- One watchdog check. True once the guard has fired. -/
def watchdogTick (api : Api) (g : Guard) : IO Bool := do
  if (← g.fired.get).isSome then return true
  let now ← api.now
  let hu ← g.heldUntil.get
  if (← g.lost.get) then g.fire "another holder was seen"
  else if !holdsAt now hu then
    g.fire s!"no confirmed hold: now={now} ms >= heldUntil={hu} ms"
  return (← g.fired.get).isSome

/-- One renewal attempt: send point first, then the stamp, then the bounded
    renew; an ambiguous result is settled by a bounded read-back. -/
def attempt (api : Api) (g : Guard) : IO Unit := do
  let send ← api.now
  let stamp ← api.stamp
  let b1 := callBound g.cfg send (← g.heldUntil.get)
  match ← api.renew stamp b1 with
  | .applied => g.confirm send
  | .failed _ =>
    let b2 := callBound g.cfg (← api.now) (← g.heldUntil.get)
    match judgeReadBack g.cfg.identity stamp (← api.read b2) with
    | .confirmed => g.confirm send
    | .lost => g.markLost "renew not applied and the lease names another holder"
    | .nothing => pure ()

/-- Fixed cadence from each attempt's START; attempts never overlap (one task). -/
partial def renewerLoop (api : Api) (g : Guard) : IO Unit := do
  if (← g.fired.get).isSome then return
  let start ← api.now
  attempt api g
  let used := (← api.now) - start
  api.sleep (g.cfg.cadenceMs - min used g.cfg.cadenceMs)
  renewerLoop api g

/-- The watchdog task body: independent of every API call. -/
partial def watchdogLoop (api : Api) (g : Guard) : IO Unit := do
  if ← watchdogTick api g then return
  api.sleep g.cfg.watchdogMs
  watchdogLoop api g

end FlareOperator.LeaseGuard
