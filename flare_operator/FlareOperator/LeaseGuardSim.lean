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
import FlareOperator.Kubectl
import FlareOperator.StateMachine.LeaseAbsence

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

/-- apply a renew patch exactly as the server would: the REAL ops (`renewPatch`: resourceVersion
    CAS, holder test, renewTime) through `applyPatch`. Returns the new resourceVersion, or none
    when a test failed (nothing changed). -/
def applyRenew (w : World) (st rv : String) : IO (Option String) := do
  let o : LeaseObj := { holder := ← w.holder.get, renewTime := ← w.stamp.get, rv := ← w.rv.get }
  match applyPatch o (renewPatch "old" st rv) with
  | some o' =>
    w.stamp.set o'.renewTime
    w.stampAt.set (stampTime o'.renewTime)
    w.rv.set o'.rv
    return some (toString o'.rv)
  | none => return none

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
  -- the initial acquisition at t = 0 was a confirmed write sent at 0, leaving rv 1
  g.know "1"
  g.confirm 0
  let wdRef ← IO.mkRef (pure () : IO Unit)
  let api : Api := {
    now := ourNow w
    stamp := do
      let n ← w.ctr.get
      w.ctr.set (n + 1)
      return s!"{← w.t.get}:{n}"
    renew := fun st rv bound => do
      let ts ← w.t.get
      w.renewals.modify (· + 1)
      let wd ← wdRef.get
      let res ← IO.mkRef (none : Option (Option String))
      let act : IO Unit := do res.set (some (← applyRenew w st rv))
      let answer : IO RenewOutcome := do
        match ← res.get with
        | some (some rv1) => return .applied rv1
        | some none => return .failed "test failed (422)"
        | none => return .failed "not applied yet"
      match k.renewB ts with
      | .ok lat =>
        w.events.modify (· ++ [(ts + lat / 2, act)])
        if lat ≤ bound then
          advance w lat wd
          answer
        else
          advance w bound wd
          return .failed "timeout"
      | .slow a r =>
        w.events.modify (· ++ [(ts + a, act)])
        let d := min r bound
        advance w d wd
        if r ≤ bound then answer else return .failed "timeout"
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
          return .lease (← w.holder.get) (← w.stamp.get) (toString (← w.rv.get))
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

/-- A minimal fake Api for the renewer-robustness checks: a virtual clock that
    only `sleep` moves, a renew that follows `script`, and a captured log. -/
def fakeApi (script : Nat → IO RenewOutcome) (nowFails : Bool := false) :
    IO (Api × IO.Ref Nat × IO.Ref (Array String)) := do
  let t ← IO.mkRef 1000
  let n ← IO.mkRef 0
  let logs ← IO.mkRef #[]
  let api : Api := {
    now := do
      if nowFails then throw (IO.userError "clock exploded")
      t.get
    stamp := do return s!"stamp{← n.get}"
    renew := fun _ _ _ => do n.modify (· + 1); script (← n.get)
    read := fun _ => pure .unreadable
    sleep := fun ms => do
      t.modify (· + ms)
      if (← t.get) ≥ 40000 then throw (IO.userError "horizon")
    log := fun m => logs.modify (·.push m) }
  return (api, n, logs)

/-! ## (7) the same-identity restart race

One pod identity, two incarnations. P1 holds (rv 1, renewTime 0, confirmed send 0), sends a renew at 1000
whose response is lost (killed by its wall) and which the server applies at `landAt`; P1's watchdog fires at
12000 and it has stopped serving at 13000. P2 (same identity: a container restart) starts at `restartAt`:
it reads the lease and, holding it by name, renews with a CAS on the resourceVersion it read (Main's phase
1), then every 5 s on its own chain (the guard). A third pod reads the lease every 10 ms and takes it over
(resourceVersion CAS, transitions + 1) once renewTime + 15 s has passed. `fenced = false` replays 477280c:
both incarnations send the holder-only patch. -/

structure RaceResult where
  overlap : Bool
  oldRefused : Bool
  renewTimeMonotone : Bool
  transitionsValid : Bool

def holderOnlyPatch (identity stamp : String) : List PatchOp :=
  [.test "/spec/holderIdentity" identity, .replace "/spec/renewTime" stamp]

def restartRace (fenced : Bool) (landAt restartAt : Nat) : IO RaceResult := do
  let lease ← IO.mkRef ({ holder := "pod", renewTime := "0", rv := 1, transitions := 1 } : LeaseObj)
  let patchOf := fun (stamp rv : String) => if fenced then renewPatch "pod" stamp rv else holderOnlyPatch "pod" stamp
  let p1Patch := patchOf "1000" "1"
  let p1Done ← IO.mkRef false
  let oldRefused ← IO.mkRef false
  -- P2's state
  let p2Started ← IO.mkRef false
  let p2Rv ← IO.mkRef ""
  let p2Until ← IO.mkRef 0
  let p2Stop ← IO.mkRef (none : Option Nat)
  let p2Next ← IO.mkRef 0
  let p2Max ← IO.mkRef 0          -- the newest stamp P2 got applied
  let monotone ← IO.mkRef true
  let thirdAt ← IO.mkRef (none : Option Nat)
  let overlap ← IO.mkRef false
  let mut t := 0
  while t ≤ 80000 do
    -- P1's late patch reaches the server
    if t ≥ landAt && !(← p1Done.get) then
      p1Done.set true
      match applyPatch (← lease.get) p1Patch with
      | some o => lease.set o
      | none => oldRefused.set true
    -- P2: start (phase 1 renew on the rv just read), then its 5 s cadence on its own chain
    if t ≥ restartAt && !(← p2Started.get) then
      p2Started.set true
      let cur ← lease.get
      if cur.holder == "pod" then
        match applyPatch cur (patchOf (toString t) (toString cur.rv)) with
        | some o =>
          lease.set o
          p2Rv.set (toString o.rv)
          p2Until.set (t + 12000)
          p2Max.set t
        | none => pure ()
      p2Next.set (t + 5000)
    if (← p2Started.get) && (← p2Stop.get).isNone && t ≥ (← p2Next.get) then
      p2Next.set (t + 5000)
      let cur ← lease.get
      match applyPatch cur (patchOf (toString t) (← p2Rv.get)) with
      | some o =>
        lease.set o
        p2Rv.set (toString o.rv)
        p2Until.set (t + 12000)
        p2Max.set t
      | none =>
        -- read-back: another holder = definite loss (stop now); ours = adopt the rv, extend nothing
        if cur.holder != "pod" then p2Stop.set (some (t + 1000)) else p2Rv.set (toString cur.rv)
    if (← p2Started.get) && (← p2Stop.get).isNone && t ≥ (← p2Until.get) then p2Stop.set (some (t + 1000))
    -- once P2 has renewed, the lease's renewTime never goes below P2's newest applied stamp while P2 holds it
    let cur ← lease.get
    if cur.holder == "pod" && (← p2Max.get) > 0 && stampTime cur.renewTime < (← p2Max.get) then monotone.set false
    -- the third pod
    if (← thirdAt.get).isNone && cur.holder == "pod" && t ≥ stampTime cur.renewTime + 15000 then
      lease.set { cur with holder := "third", renewTime := toString t, rv := cur.rv + 1, transitions := cur.transitions + 1 }
      thirdAt.set (some t)
    -- serving: P1 until 13000; P2 from its start while not stopped (and only once it renewed)
    let p1Serving := t < 13000
    let p2Serving := (← p2Started.get) && (← p2Max.get) > 0 && match ← p2Stop.get with
      | some s => t < s
      | none => true
    if (← thirdAt.get).isSome && (p1Serving || p2Serving) then overlap.set true
    t := t + 10
  let fin ← lease.get
  return { overlap := ← overlap.get, oldRefused := ← oldRefused.get, renewTimeMonotone := ← monotone.get,
           transitionsValid := fin.transitions == (if (← thirdAt.get).isSome then 2 else 1) }

/-! ## A server for `attempt`: the real patch ops through `applyPatch`

`renew` applies `renewPatch identity stamp rv` (exactly what Bridge sends) to the stored object; `mode`
picks the reply: answer normally, apply but lose the reply (ambiguous), or not apply and time out. -/

inductive ReplyMode where
  | normal
  | appliedReplyLost
  | timeoutNotApplied
  | appliedNoRv
  deriving BEq

def serverApi (identity : String) (lease : IO.Ref LeaseObj) (mode : IO.Ref ReplyMode)
    (readable : IO.Ref Bool) (clock : IO.Ref Nat) (stampN : IO.Ref Nat) : Api := {
  now := clock.get
  stamp := do
    stampN.modify (· + 1)
    return s!"{← clock.get}:{← stampN.get}"
  renew := fun stamp rv _ => do
    let m ← mode.get
    if m == .timeoutNotApplied then return .failed "timeout"
    match applyPatch (← lease.get) (renewPatch identity stamp rv) with
    | none => return .failed "422 test failed"
    | some o =>
      lease.set o
      match m with
      | .appliedReplyLost => return .failed "reply lost"
      | .appliedNoRv => return .applied ""
      | _ => return .applied (toString o.rv)
  read := fun _ => do
    if !(← readable.get) then return .unreadable
    let o ← lease.get
    return .lease o.holder o.renewTime (toString o.rv)
  sleep := fun ms => clock.modify (· + ms)
  -- the SAF-09 marker: a metadata-only write, CAS on the resourceVersion (it moves the rv like any write)
  annotate := fun _ rv _ => do
    match applyPatch (← lease.get) [.test "/metadata/resourceVersion" rv] with
    | none => return .failed "409 conflict"
    | some o =>
      lease.set o
      return .applied (toString o.rv) }

/-- no instant with the new leader holding and the old one serving -/
def noViolation (w : World) : IO Bool := return (← w.violation.get).isNone

/-- (8) the renew CAS through the REAL renewPatch / applyPatch and the REAL `attempt` (same holder identity). -/
def casChecks : IO (List (String × Bool)) := do
  let mut out : List (String × Bool) := []
  -- (8) the renew CAS through the REAL renewPatch/applyPatch and the REAL attempt, same holder identity
  -- (8a) forward order: the old incarnation's patch captured rv N, the new one applies N -> N+1 with a later stamp,
  --      then the old patch is released: refused, new stamp and rv unchanged
  let l8 : LeaseObj := { holder := "pod", renewTime := "s0", rv := 5, transitions := 1 }
  let oldP := renewPatch "pod" "s-old" "5"
  let newP := renewPatch "pod" "s-new" "5"
  let a8 := applyPatch l8 newP
  let b8 := a8.bind (fun o => applyPatch o oldP)
  out := out ++ [("lease CAS (8a): same holder, old patch captured rv N and delayed; the new incarnation applies N -> N+1 with a later stamp; the released old patch is REFUSED (renewTime and rv stay the new ones, transitions unchanged)",
    a8 == some { l8 with renewTime := "s-new", rv := 6 } && b8.isNone &&
    (a8.map (·.transitions)) == some 1)]
  -- (8b) reverse order: the old patch wins first (N -> N+1, old stamp); the new incarnation's CAS on N is refused;
  --      its read-back extends nothing but adopts N+1; its next attempt applies
  let lease ← IO.mkRef l8
  let mode ← IO.mkRef ReplyMode.normal
  let readable8 ← IO.mkRef true
  let clock ← IO.mkRef 1000
  let sn ← IO.mkRef 0
  let api := serverApi "pod" lease mode readable8 clock sn
  let g ← Guard.new { identity := "pod" } (fun _ => pure ())
  g.know "5"
  g.confirm 0
  lease.modify (fun o => (applyPatch o oldP).getD o)          -- the old incarnation's patch lands first
  let hu0 ← g.heldUntil.get
  attempt api g                                                -- CAS on 5: refused
  let afterRefused ← lease.get
  let hu1 ← g.heldUntil.get
  let known1 ← g.knownRv.get
  clock.modify (· + 5000)
  attempt api g                                                -- CAS on the adopted 6: applies
  let afterRetry ← lease.get
  out := out ++ [("lease CAS (8b): reverse order — the old patch applied first; the new incarnation's CAS on N is refused, its read-back (our holder, not our stamp) extends NOTHING and adopts N+1; the next attempt applies over it",
    afterRefused.renewTime == "s-old" && afterRefused.rv == 6 && hu1 == hu0 && known1 == "6" &&
    afterRetry.rv == 7 && afterRetry.renewTime != "s-old" && (← g.heldUntil.get) > hu1)]
  -- (8c) ambiguous: applied but the reply lost -> the read-back shows OUR stamp -> confirmed from this send point,
  --      knownRv advances; the following attempt CASes on it and applies
  let lease3 ← IO.mkRef ({ holder := "pod", renewTime := "s0", rv := 5, transitions := 1 } : LeaseObj)
  let mode3 ← IO.mkRef ReplyMode.appliedReplyLost
  let clock3 ← IO.mkRef 1000
  let api3 := serverApi "pod" lease3 mode3 readable8 clock3 (← IO.mkRef 0)
  let g3 ← Guard.new { identity := "pod" } (fun _ => pure ())
  g3.know "5"
  g3.confirm 0
  attempt api3 g3
  let hu3 ← g3.heldUntil.get
  let k3 ← g3.knownRv.get
  mode3.set .normal
  clock3.modify (· + 5000)
  attempt api3 g3
  out := out ++ [("lease CAS (8c): applied with the reply lost -> read-back shows this attempt's stamp: confirmed from its send point, knownRv advances to the applied rv, the next CAS applies",
    hu3 == deadlineOf g3.cfg 1000 && k3 == "6" && (← lease3.get).rv == 7 && (← g3.knownRv.get) == "7")]
  -- (8d) ambiguous and nothing learned: timeout without applying + an unreadable read-back -> no extension, knownRv kept
  let lease4 ← IO.mkRef ({ holder := "pod", renewTime := "s0", rv := 5, transitions := 1 } : LeaseObj)
  let unread ← IO.mkRef false
  let api4 := serverApi "pod" lease4 (← IO.mkRef ReplyMode.timeoutNotApplied) unread (← IO.mkRef 1000) (← IO.mkRef 0)
  let g4 ← Guard.new { identity := "pod" } (fun _ => pure ())
  g4.know "5"
  g4.confirm 0
  attempt api4 g4
  out := out ++ [("lease CAS (8d): timeout without applying and an unreadable read-back -> no extension, knownRv unchanged, the lease untouched",
    (← g4.heldUntil.get) == deadlineOf g4.cfg 0 && (← g4.knownRv.get) == "5" && (← lease4.get).rv == 5)]
  -- (8e) a reply claiming success WITHOUT a resourceVersion is not an applied renew: judged by the read-back only
  let lease5 ← IO.mkRef ({ holder := "pod", renewTime := "s0", rv := 5, transitions := 1 } : LeaseObj)
  let unread5 ← IO.mkRef false
  let api5 := serverApi "pod" lease5 (← IO.mkRef ReplyMode.appliedNoRv) unread5 (← IO.mkRef 1000) (← IO.mkRef 0)
  let g5 ← Guard.new { identity := "pod" } (fun _ => pure ())
  g5.know "5"
  g5.confirm 0
  attempt api5 g5
  let g5b ← Guard.new { identity := "pod" } (fun _ => pure ())
  g5b.know ""
  out := out ++ [("lease CAS (8e): an 'applied' reply without a resourceVersion is NOT confirmed (unreadable read-back: no extension, knownRv kept); an empty resourceVersion is never adopted as known",
    (← g5.heldUntil.get) == deadlineOf g5.cfg 0 && (← g5.knownRv.get) == "5" && (← g5b.knownRv.get) == "")]
  -- (8f) the SAF-09 marker written BY the renewer task (CAS on its chain) between two renews: no refused renew
  let lease6 ← IO.mkRef ({ holder := "pod", renewTime := "s0", rv := 5, transitions := 1 } : LeaseObj)
  let logs6 ← IO.mkRef (#[] : Array String)
  let clock6 ← IO.mkRef 1000
  let api6 := { serverApi "pod" lease6 (← IO.mkRef ReplyMode.normal) (← IO.mkRef true) clock6 (← IO.mkRef 0) with
                log := fun m => logs6.modify (·.push m) }
  let g6 ← Guard.new { identity := "pod" } (fun _ => pure ())
  g6.know "5"
  g6.confirm 0
  attempt api6 g6
  g6.requestMarker "42"
  markerStep api6 g6
  clock6.modify (· + 5000)
  attempt api6 g6
  let l6 ← logs6.get
  out := out ++ [("lease CAS (8f): the SAF-09 marker written by the renewer task as a CAS on its chain between two renews -> both renews applied, none refused, the marker confirmed, rv 5 -> 6 -> 7 -> 8",
    (← g6.markerDone.get) == some "42" && (← g6.pendingMarker.get).isNone && (← lease6.get).rv == 8 &&
    !(l6.any fun m => (m.splitOn "FAILED").length > 1))]
  -- (8g) CONTROL: the same marker written OUTSIDE the guard (the d5d217a annotate) refuses the next renew once;
  --      the read-back adopts the rv (no extension) and the renew after it applies
  let lease7 ← IO.mkRef ({ holder := "pod", renewTime := "s0", rv := 5, transitions := 1 } : LeaseObj)
  let logs7 ← IO.mkRef (#[] : Array String)
  let clock7 ← IO.mkRef 1000
  let api7 := { serverApi "pod" lease7 (← IO.mkRef ReplyMode.normal) (← IO.mkRef true) clock7 (← IO.mkRef 0) with
                log := fun m => logs7.modify (·.push m) }
  let g7 ← Guard.new { identity := "pod" } (fun _ => pure ())
  g7.know "5"
  g7.confirm 0
  attempt api7 g7
  lease7.modify (fun o => { o with rv := o.rv + 1 })            -- an outside metadata write
  let hu7 ← g7.heldUntil.get
  clock7.modify (· + 5000)
  attempt api7 g7
  let refusedOnce := (← logs7.get).any fun m => (m.splitOn "FAILED").length > 1
  let hu7b ← g7.heldUntil.get
  clock7.modify (· + 5000)
  attempt api7 g7
  out := out ++ [("lease CAS (8g) CONTROL: a metadata write OUTSIDE the guard refuses the next renew once (no extension), the read-back adopts its rv and the following renew applies",
    refusedOnce && hu7b == hu7 && (← g7.heldUntil.get) > hu7)]
  return out

/-- (7) the same-identity restart race and its holder-only control. -/
def raceChecks : IO (List (String × Bool)) := do
  let mut out : List (String × Bool) := []
  -- (7) incarnation fencing: a renew of the killed incarnation lands after the SAME pod restarted and renewed
  let mut fencedOk := true
  let mut oldRefusedSeen := false
  let mut unfencedOverlap := false
  for restartAt in [13000, 14000, 16000, 20000, 30000] do
    for landAt in (List.range 120).map (fun i => 1000 + i * 500) do
      let r ← restartRace true landAt restartAt
      fencedOk := fencedOk && !r.overlap && r.renewTimeMonotone && r.transitionsValid
      if r.oldRefused then oldRefusedSeen := true
      let u ← restartRace false landAt restartAt
      if u.overlap then unfencedOverlap := true
  out := out ++ [("lease guard (7): a renew of the KILLED incarnation (response lost) released after the same pod restarted and the new incarnation renewed -> refused by the resourceVersion CAS; renewTime never moves back, transitions unchanged, no instant where a third pod holds while an incarnation serves (landing 1-60.5 s after the send x restart 13-30 s)",
    fencedOk && oldRefusedSeen)]
  out := out ++ [("lease guard (7) CONTROL: the same race with the holder-only patch of 477280c DOES produce an overlap (a third pod takes the regressed lease while the new incarnation serves): the model can fail",
    unfencedOverlap)]
  return out

/-! ## (9) a deleted Lease: create only after an uninterrupted absence (StateMachine/LeaseAbsence)

Real time in ms. The Lease is deleted at `del`. The old leader's last confirmed renew was sent
`sinceSend` before that; on its own clock (`rateOld` permille) it fires at send + lease − margin
(+ one watchdog period) and stops serving 1000 ms later. Each standby polls every 5 s of its own
clock (`rateS` permille) from its `offset`, applies `observe` / `mayCreate` with the received time
on its clock, and creates atomically (one winner, the other gets AlreadyExists and resets). A
reading inside an `errors` window is unreadable. `oldLeader = false`: a first start (no Lease ever). -/

structure AbsenceResult where
  overlap : Bool
  createdAt : Option Nat
  creators : Nat
  /-- the creator's last unreadable reading before its create (real ms), if any -/
  lastErrorBeforeCreate : Option Nat

def absenceRace (required : Nat) (oldLeader : Bool) (sinceSend : Nat) (rateOld : Nat)
    (standbys : List (Nat × Nat)) (errors : List (Nat × Nat)) (del : Nat := 20000) (horizon : Nat := 90000) :
    IO AbsenceResult := do
  let leaseMs := 15000
  let marginMs := 3000
  -- the old leader's stop (real ms): its local deadline, the watchdog period, the step-down
  let send := del - sinceSend
  let localDeadline := (send * rateOld) / 1000 + (leaseMs - marginMs) + 500
  let fireReal := (localDeadline * 1000 + rateOld - 1) / rateOld
  let stopReal := if oldLeader then fireReal + 1000 else 0
  let present ← IO.mkRef (oldLeader : Bool)       -- before `del` (first start: never existed)
  let createdAt ← IO.mkRef (none : Option Nat)
  let creators ← IO.mkRef 0
  let lastErr ← IO.mkRef (none : Option Nat)
  let states ← IO.mkRef ((standbys.map fun _ => (none : Option Nat)) : List (Option Nat))
  let nextPoll ← IO.mkRef (standbys.map (·.2))   -- local ms of each standby's next poll
  let errSeen ← IO.mkRef ((standbys.map fun _ => (none : Option Nat)) : List (Option Nat))
  let mut t := 0
  while t ≤ horizon do
    if oldLeader && t == del then present.set false
    let mut i := 0
    for (rateS, _) in standbys do
      let localT := (t * rateS) / 1000
      let np ← nextPoll.get
      if localT ≥ np.getD i 0 then
        nextPoll.modify fun l => l.set i (localT + 5000)
        let inErr := errors.any fun (a, b) => a ≤ t && t < b
        let isPresent ← present.get
        let reading : LeaseAbsence.Reading :=
          if inErr then .unreadable else if isPresent then .present else .absent
        if inErr then errSeen.modify fun l => l.set i (some t)
        let prev := (← states.get).getD i none
        let since := LeaseAbsence.observe prev reading localT
        states.modify fun l => l.set i since
        if LeaseAbsence.mayCreate since localT required then
          if !(← present.get) then
            present.set true
            createdAt.set (some t)
            creators.modify (· + 1)
            let es ← errSeen.get
            lastErr.set (es.getD i none)
          states.modify fun l => l.set i none
      i := i + 1
    t := t + 10
  let c ← createdAt.get
  let overlap := oldLeader && match c with
    | some ct => ct < stopReal
    | none => false
  return { overlap, createdAt := c, creators := ← creators.get, lastErrorBeforeCreate := ← lastErr.get }

/-- (9) the deleted-Lease checks. -/
def absenceChecks : IO (List (String × Bool)) := do
  let mut out : List (String × Bool) := []
  let req := LeaseAbsence.requiredMs 15000 3000
  -- pure pieces
  out := out ++ [
    ("lease absence: only the API server's NotFound is an absence; Forbidden, timeouts and a stalled API are unreadable",
      LeaseAbsence.classifyReadError "getLease failed (exit 1): Error from server (NotFound): leases.coordination.k8s.io \"x\" not found" == .absent &&
      LeaseAbsence.classifyReadError "getLease failed (exit 1): Error from server (Forbidden): leases is forbidden" == .unreadable &&
      LeaseAbsence.classifyReadError "kubectl killed at its 4s wall" == .unreadable &&
      LeaseAbsence.classifyReadError "getLease failed: lease API stalled (FLARE_TEST_LEASE_API_STALL_FILE)" == .unreadable),
    ("lease absence: an unreadable or present reading RESETS the observation; only absence starts or continues it",
      LeaseAbsence.observe (some 100) .unreadable 9000 == none && LeaseAbsence.observe (some 100) .present 9000 == none &&
      LeaseAbsence.observe none .absent 500 == some 500 && LeaseAbsence.observe (some 100) .absent 9000 == some 100),
    ("lease absence: create only after lease + margin (18000 ms) of uninterrupted absence",
      req == 18000 && !LeaseAbsence.mayCreate (some 1000) 18999 req && LeaseAbsence.mayCreate (some 1000) 19000 req &&
      !LeaseAbsence.mayCreate none 99999 req)]
  -- deletion while the old leader is inside its local deadline: no create before it stopped, any clock rates
  let mut ok := true
  let mut createdAll := true
  for rateOld in [900, 1000, 1100] do
    for rateS in [900, 1000, 1100] do
      for sinceSend in [0, 2500, 4990] do
        for off in [0, 1250, 2500, 4990] do
          let r ← absenceRace req true sinceSend rateOld [(rateS, off)] []
          ok := ok && !r.overlap
          createdAll := createdAll && r.createdAt.isSome
  out := out ++ [("lease absence (9a): the Lease deleted while its leader is inside its local deadline -> a standby creates it only after that leader stopped serving (clock rates 0.9-1.1 on both sides, last renew 0-5 s before the deletion, any poll phase), and it does create it",
    ok && createdAll)]
  -- two standbys observe the same absence: exactly one creates (atomic create), still after the old leader stopped
  let mut two := true
  for off2 in [0, 10, 2500] do
    let r ← absenceRace req true 0 1000 [(1000, 0), (1000, off2)] []
    two := two && !r.overlap && r.creators == 1
  out := out ++ [("lease absence (9b): two standbys observing the same absence -> exactly one create succeeds (the other gets AlreadyExists and resets), after the old leader stopped",
    two)]
  -- read errors during the absence: the observation restarts after each, so the create is >= required after the last error
  let r3 ← absenceRace req true 0 1000 [(1000, 0)] [(30000, 31000), (40000, 41000)]
  out := out ++ [("lease absence (9c): unreadable readings (Forbidden / timeout / stall) during the absence reset the observation: no create until a full uninterrupted absence after the last unreadable one",
    !r3.overlap && (match r3.createdAt, r3.lastErrorBeforeCreate with
      | some c, some e => c ≥ e + req
      | _, _ => false))]
  -- an API that never becomes readable: never created
  let r4 ← absenceRace req true 0 1000 [(1000, 0)] [(20000, 90001)]
  out := out ++ [("lease absence (9d): the Lease unreadable from the deletion on -> never created (fail closed)", r4.createdAt.isNone)]
  -- first start: no Lease ever existed -> created after the required absence (liveness), by one pod
  let r5 ← absenceRace req false 0 1000 [(1000, 0), (1000, 2500)] []
  out := out ++ [("lease absence (9e): first start (no Lease ever) -> created once, after lease + margin of absence (liveness kept)",
    r5.creators == 1 && (match r5.createdAt with | some c => c ≥ req && c ≤ req + 5000 + 10 | none => false))]
  -- controls: the previous immediate create, and a bare lease duration, DO overlap somewhere in the grid
  let mut immediate := false
  let mut bare := false
  for rateOld in [900, 1000, 1100] do
    for rateS in [900, 1000, 1100] do
      for off in [0, 1250, 2500, 4990] do
        if (← absenceRace 0 true 0 rateOld [(rateS, off)] []).overlap then immediate := true
        if (← absenceRace 15000 true 0 rateOld [(rateS, off)] []).overlap then bare := true
  out := out ++ [("lease absence (9f) CONTROL: creating at once (the code before) and after only the bare lease duration (15 s) both overlap with the old leader in this grid: the model can fail and the margin is needed",
    immediate && bare)]
  return out

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
      judgeReadBack "p" "s1" (.lease "p" "s1" "7") == .confirmed),
    ("lease guard: read-back with our holder and an OLDER stamp extends nothing",
      judgeReadBack "p" "s2" (.lease "p" "s1" "7") == .nothing),
    ("lease guard: read-back with another holder is a definite loss",
      judgeReadBack "p" "s1" (.lease "q" "s1" "7") == .lost),
    ("lease guard: read-back with an empty holder is a definite loss",
      judgeReadBack "p" "s1" (.lease "" "s1" "7") == .lost),
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
  out := out ++ (← casChecks)
  out := out ++ (← raceChecks)
  out := out ++ (← absenceChecks)
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
  -- f18: the renewer must survive whatever one attempt throws (c2a4c51: the exception ended the task, silently)
  let (apiE, nE, logsE) ← fakeApi (fun n => if n == 1 then throw (IO.userError "boom") else pure (.applied "2"))
  let gE ← Guard.new c (fun _ => pure ())
  gE.confirm 1000
  try renewerLoop apiE gE catch _ => pure ()
  let lE ← logsE.get
  out := out ++ [("lease guard (f18): an exception in one renewer attempt is logged and the renewer carries on (later attempts confirm)",
    decide ((← nE.get) ≥ 5) && lE.any (fun l => (l.splitOn "RAISED").length > 1) &&
    lE.any (fun l => (l.splitOn "renew applied").length > 1) && decide ((← gE.heldUntil.get) > 30000))]
  -- f18: a renewer task that ends for any reason says so (and records why)
  let (apiD, _, logsD) ← fakeApi (fun _ => pure (.applied "2")) (nowFails := true)
  let gD ← Guard.new c (fun _ => pure ())
  renewerTask apiD gD
  let lD ← logsD.get
  out := out ++ [("lease guard (f18): a renewer task that dies logs 'task DIED' with the cause and records it as the last failure",
    lD.any (fun l => (l.splitOn "task DIED: clock exploded").length > 1) &&
    ((← gD.lastFailure.get).splitOn "clock exploded").length > 1)]
  -- f18: every failed attempt is logged with its reason, the read-back verdict, and the bound used
  let (apiF, _, logsF) ← fakeApi (fun _ => pure (.failed "kubectl failed (exit 1): forbidden"))
  let gF ← Guard.new c (fun _ => pure ())
  gF.confirm 1000
  try renewerLoop apiF gF catch _ => pure ()
  let lF ← logsF.get
  out := out ++ [("lease guard (f18): a failed attempt logs reason + read-back + verdict (one line per attempt) and the summary reaches the FAIL-CLOSED reason",
    lF.any (fun l => (l.splitOn "forbidden").length > 1 && (l.splitOn "unreadable").length > 1 && (l.splitOn "nothing confirmed").length > 1) &&
    decide ((← gF.lastFailure.get).length > 0))]
  let firedWhy ← IO.mkRef ""
  let gG ← Guard.new c (fun why => firedWhy.set why)
  -- never confirmed (heldUntil 0): the fake clock (1000 ms) is past the deadline at once
  gG.lastFailure.set "renew failed after 12 ms: forbidden"
  let (apiG, _, _) ← fakeApi (fun _ => pure (.applied "2"))
  let _ ← watchdogTick apiG gG
  out := out ++ [("lease guard (f18): the FAIL-CLOSED line carries the renewer's last failure",
    decide (((← firedWhy.get).splitOn "last renewer failure: renew failed after 12 ms: forbidden").length > 1))]
  -- f18: the first attempt of a never-confirmed guard is not bounded to 1 ms (c2a4c51: 0 - now = 0 -> 1 ms)
  out := out ++ [("lease guard (f18): a never-confirmed guard (heldUntil 0) gets the cap, not 1 ms, as its call bound",
    callBound c 5000 0 == 4000)]
  -- the bounded calls' process wall is whole seconds rounded DOWN (never past the bound, no fractional
  -- timeout(1) argument), and a bound under 1 s starts no call
  out := out ++ [("lease guard: the process wall is whole seconds rounded down; under 1 s no call is started",
    Kubectl.wallSeconds 4000 == some 4 && Kubectl.wallSeconds 3999 == some 3 && Kubectl.wallSeconds 1000 == some 1 &&
    Kubectl.wallSeconds 999 == none && Kubectl.wallSeconds 0 == none)]
  return out

end FlareOperator.LeaseGuardSim
