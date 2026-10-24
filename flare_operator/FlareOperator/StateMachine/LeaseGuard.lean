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

/-- Bound of one renewer API call: min(cap, time left to the deadline), at least 1 ms.
    `heldUntil = 0` means "never confirmed yet" (no deadline to bound against):
    the cap applies. (c2a4c51 computed `0 - now = 0` there, i.e. a 1 ms call.) -/
def callBound (c : Config) (now heldUntil : Nat) : Nat :=
  if heldUntil == 0 then c.capMs else max 1 (min c.capMs (heldUntil - now))

/-- Held locally: strictly before the deadline (0 = never confirmed). -/
def holdsAt (now heldUntil : Nat) : Bool := now < heldUntil

inductive ReadOutcome where
  /-- holder, renewTime as stored, metadata.resourceVersion -/
  | lease (holder renewTime rv : String)
  | unreadable
  deriving Repr, BEq

/-! ## The renew patch and what the API server does with it

A JSON patch is applied by the API server to the object it is about to store
(conflicts are retried against the fresh object, every `test` op is evaluated
again), atomically: all ops or none. Killing the local kubectl never retracts a
request the server already accepted, so a renew may LAND LATE — after this
process gave up on it, after this process is gone, after another incarnation of
the SAME identity (the pod name survives a container restart) renewed. The patch
must therefore be unable to mutate any lease state but the one this incarnation
last knew: it tests the resourceVersion of that state. Any later write by anyone
(a new incarnation's renew, a takeover) changes the resourceVersion and the late
patch is refused; it can never move renewTime backwards under a newer holder or
renewal. -/

inductive PatchOp where
  | test (path value : String)
  | replace (path value : String)
  deriving Repr, BEq

/-- The renew patch of one attempt: resourceVersion CAS (the state this incarnation
    last knew), the holder test (defense in depth), then the attempt's stamp. -/
def renewPatch (identity stamp rv : String) : List PatchOp :=
  [.test "/metadata/resourceVersion" rv, .test "/spec/holderIdentity" identity,
   .replace "/spec/renewTime" stamp]

def PatchOp.json : PatchOp → String
  | .test p v => s!"\{\"op\":\"test\",\"path\":\"{p}\",\"value\":\"{v}\"}"
  | .replace p v => s!"\{\"op\":\"replace\",\"path\":\"{p}\",\"value\":\"{v}\"}"

def patchJson (ops : List PatchOp) : String := "[" ++ ",".intercalate (ops.map PatchOp.json) ++ "]"

/-- The lease as the API server stores it (the fields the patches touch). -/
structure LeaseObj where
  holder : String
  renewTime : String
  rv : Nat
  transitions : Nat := 0
  deriving Repr, BEq

/-- The server's application of a test/replace patch: `none` when a test fails
    (HTTP 422, nothing changes); otherwise the new object with the next
    resourceVersion. -/
def applyPatch (o : LeaseObj) (ops : List PatchOp) : Option LeaseObj :=
  let step (acc : Option LeaseObj) (op : PatchOp) : Option LeaseObj :=
    match acc, op with
    | none, _ => none
    | some x, .test "/metadata/resourceVersion" v => if toString x.rv == v then some x else none
    | some x, .test "/spec/holderIdentity" v => if x.holder == v then some x else none
    | some x, .test "/spec/renewTime" v => if x.renewTime == v then some x else none
    | some _, .test _ _ => none
    | some x, .replace "/spec/renewTime" v => some { x with renewTime := v }
    | some x, .replace "/spec/holderIdentity" v => some { x with holder := v }
    | some x, .replace _ _ => some x
  (ops.foldl step (some o)).map fun x => { x with rv := o.rv + 1 }

inductive RenewOutcome where
  /-- applied; the new resourceVersion -/
  | applied (rv : String)
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
  | .lease holder renewTime _ =>
    if holder == identity then (if renewTime == stamp then .confirmed else .nothing)
    else .lost

/-- The API the renewer and the watchdog depend on (injectable). -/
structure Api where
  /-- monotonic clock, ms -/
  now : IO Nat
  /-- a renewTime value unique to this attempt -/
  stamp : IO String
  /-- the renew patch `renewPatch identity stamp rv` (resourceVersion CAS + holder
      test) writing `stamp`, bounded by the given ms -/
  renew : String → String → Nat → IO RenewOutcome
  /-- read the lease, bounded by the given ms -/
  read : Nat → IO ReadOutcome
  sleep : Nat → IO Unit
  /-- one line per renewer outcome (the guard must say why it is about to fire) -/
  log : String → IO Unit := fun _ => pure ()

structure Guard where
  cfg : Config
  heldUntil : IO.Ref Nat
  lost : IO.Ref Bool
  fired : IO.Ref (Option String)
  /-- summary of the renewer's last failed attempt (shown in the FAIL-CLOSED line) -/
  lastFailure : IO.Ref String
  /-- the resourceVersion of the lease state THIS incarnation last knew (its own
      confirmed write, its acquisition, or a read-back); "" = not known yet -/
  knownRv : IO.Ref String
  onExpire : String → IO Unit

def Guard.new (cfg : Config) (onExpire : String → IO Unit) : IO Guard :=
  return { cfg, heldUntil := ← IO.mkRef 0, lost := ← IO.mkRef false, fired := ← IO.mkRef none, lastFailure := ← IO.mkRef "", knownRv := ← IO.mkRef "", onExpire }

/-- This incarnation's own write (create / acquire / phase-1 renew) produced `rv`. -/
def Guard.know (g : Guard) (rv : String) : IO Unit :=
  if rv.isEmpty then pure () else g.knownRv.set rv

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
    let lf ← g.lastFailure.get
    g.fire s!"no confirmed hold: now={now} ms >= heldUntil={hu} ms; last renewer failure: {if lf.isEmpty then "none recorded" else lf}"
  return (← g.fired.get).isSome

/-- One renewal attempt: send point first, then the stamp, then the bounded
    renew; an ambiguous result is settled by a bounded read-back. Logs exactly
    one line (outcome, bounds, durations, deadline). -/
def attempt (api : Api) (g : Guard) : IO Unit := do
  let send ← api.now
  let stamp ← api.stamp
  let b1 := callBound g.cfg send (← g.heldUntil.get)
  let rv0 ← g.knownRv.get
  let r0 ← api.renew stamp rv0 b1
  -- a reply without a resourceVersion is NOT an applied renew (fail closed): it is judged by the read-back
  let r := match r0 with
    | .applied rv1 => if rv1.isEmpty then RenewOutcome.failed "applied reply without a resourceVersion (treated as unconfirmed)" else r0
    | other => other
  let t1 ← api.now
  match r with
  | .applied rv1 =>
    g.knownRv.set rv1
    g.confirm send
    api.log s!"renewer: renew applied in {t1 - send} ms (bound {b1} ms), rv {rv0} -> {rv1}, stamp {stamp}, heldUntil={← g.heldUntil.get} ms, now={t1} ms"
  | .failed why =>
    let b2 := callBound g.cfg t1 (← g.heldUntil.get)
    let rb ← api.read b2
    let t2 ← api.now
    let rbTxt := match rb with
      | .unreadable => "read-back unreadable"
      | .lease holder rt rv => s!"read-back holder={holder} renewTime={rt} rv={rv} (wrote {stamp} over rv {rv0})"
    let v := judgeReadBack g.cfg.identity stamp rb
    let vTxt := match v with
      | .confirmed => "CONFIRMED (extends from this attempt's send point)"
      | .lost => "LOST (another holder)"
      | .nothing => "nothing confirmed"
    g.lastFailure.set s!"renew failed after {t1 - send} ms (bound {b1} ms): {why.take 300}; {rbTxt}; {vTxt}"
    api.log s!"renewer: renew FAILED after {t1 - send} ms (bound {b1} ms): {why.take 300}; {rbTxt} in {t2 - t1} ms (bound {b2} ms): {vTxt}; heldUntil={← g.heldUntil.get} ms, now={t2} ms"
    -- a read-back naming this pod gives the CURRENT resourceVersion: the next attempt CASes on it (an
    -- unconfirmed state is adopted, never trusted: it extends nothing; our next write replaces it)
    match rb with
    | .lease holder _ rv => if holder == g.cfg.identity then g.know rv
    | .unreadable => pure ()
    match v with
    | .confirmed => g.confirm send
    | .lost => g.markLost "renew not applied and the lease names another holder"
    | .nothing => pure ()

/-- Fixed cadence from each attempt's START; attempts never overlap (one task).
    Nothing an attempt throws ends the loop: it is logged, recorded as the last
    failure, and the next attempt follows. -/
partial def renewerLoop (api : Api) (g : Guard) : IO Unit := do
  if (← g.fired.get).isSome then return
  let start ← api.now
  try attempt api g
  catch e =>
    g.lastFailure.set s!"renewer attempt raised: {e}"
    api.log s!"renewer: attempt RAISED: {e}"
  let used := (← api.now) - start
  api.sleep (g.cfg.cadenceMs - min used g.cfg.cadenceMs)
  renewerLoop api g

/-- The watchdog task body: independent of every API call. -/
partial def watchdogLoop (api : Api) (g : Guard) : IO Unit := do
  if ← watchdogTick api g then return
  api.sleep g.cfg.watchdogMs
  watchdogLoop api g

/-- The renewer task: never ends silently. If it ends for any reason that is
    logged and recorded as the last failure (the watchdog then fires at the
    deadline, as designed). -/
def renewerTask (api : Api) (g : Guard) : IO Unit := do
  api.log s!"renewer: task started (cadence {g.cfg.cadenceMs} ms, cap {g.cfg.capMs} ms)"
  try
    renewerLoop api g
    api.log "renewer: task ENDED (the guard has fired)"
  catch e =>
    g.lastFailure.set s!"renewer task DIED: {e}"
    api.log s!"renewer: task DIED: {e} -- no further renewals; the watchdog fails closed at the deadline"

/-- The watchdog task. If it dies the guard fails closed at once: a guard
    nobody watches must not be trusted. -/
def watchdogTask (api : Api) (g : Guard) : IO Unit := do
  try watchdogLoop api g
  catch e =>
    api.log s!"watchdog: task DIED: {e} -- failing closed"
    g.fire s!"watchdog task died: {e}"

end FlareOperator.LeaseGuard
