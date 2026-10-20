/-
  WriteLeaseModel.lean — a DESIGN MODEL, not product code (nothing in the
  operator or flared uses it). It checks candidate rules for revoking a
  partition master's write authority during a network partition
  (docs/design-node-operations-2026-10-19.md §11) against concrete
  counterexamples, on one real-time axis with perfect clocks (drift is a
  separate margin, discussed in the doc, not modelled here).

  Terms (§11.2):
  * an AUTHORITY interval of a node = the real times at which it may COMMIT
    a client write it will acknowledge;
  * S1 = the authority intervals of the old and the new master of a
    partition do not overlap;
  * an acknowledged write must have been COMMITTED inside its node's
    authority interval (the client may receive the ACK later — delivery time
    is not authority time).

  Rules modelled:
  * RX (rejected): the lease runs L from when the master RECEIVES a grant;
    the operator promotes L (+ margin) after it last SENT a grant. A grant
    delayed in the network extends the old authority past the promotion.
  * RQ (candidate): the master asks; the lease runs L from when the master
    SENT that request (its own clock), the grant carries the request's nonce,
    only the outstanding nonce is accepted (once), and a grant arriving at or
    after request + L is discarded. A late grant can only shorten the lease,
    never extend it. The new master may start only after L (+ margin) from
    the last moment ANY leader could still issue a grant (this leader's
    persisted stop, and the end of every earlier leader's authority to
    grant).
  * commit check: admission-time check only (rejected) vs. a check AFTER the
    commit, before the ACK is sent (candidate): a pause between admission
    and commit can then commit late, but that commit is never acknowledged.
-/

namespace FlareOperator.WriteLeaseModel

/-- A half-open real-time interval [start, stop). -/
structure Interval where
  start : Nat
  stop : Nat
  deriving Repr, BEq

def Interval.overlaps (a b : Interval) : Bool := a.start < b.stop && b.start < a.stop

/-! ## RX: receive-bound lease, send-bound wait (rejected) -/

/-- The old master's authority under RX for a grant received at `recv`. -/
def rxAuthority (recv L : Nat) : Interval := { start := recv, stop := recv + L }

/-- When RX lets the new master start: L + margin after the last grant SENT. -/
def rxNewStart (lastSent L margin : Nat) : Nat := lastSent + L + margin

/-! ## RQ: request-bound lease with a nonce (candidate) -/

structure Request where
  nonce : Nat
  /-- when the master sent it (its clock) -/
  sentAt : Nat
  deriving Repr, BEq

structure Grant where
  nonce : Nat
  /-- when it reached the master -/
  recvAt : Nat
  deriving Repr, BEq

/-- The master's state: the one outstanding request, and the lease end. -/
structure MasterLease where
  outstanding : Option Request := none
  /-- authority ends here (exclusive); 0 = none -/
  expiry : Nat := 0
  deriving Repr, BEq

/-- Apply a grant under RQ: only the outstanding nonce, only once, only if it
    arrived before request + L; the lease ends at request + L. -/
def rqApply (m : MasterLease) (g : Grant) (L : Nat) : MasterLease :=
  match m.outstanding with
  | some r =>
    if g.nonce != r.nonce then m
    else if g.recvAt ≥ r.sentAt + L then { m with outstanding := none }
    else { outstanding := none, expiry := max m.expiry (r.sentAt + L) }
  | none => m

/-- The authority interval a grant gives under RQ (`none` = discarded). -/
def rqAuthority (r : Request) (g : Grant) (L : Nat) : Option Interval :=
  let m := rqApply { outstanding := some r } g L
  if m.expiry == 0 then none else some { start := g.recvAt, stop := m.expiry }

/-- When RQ lets the new master start: L + margin after the last moment any
    leader could still issue a grant — this leader's persisted stop, and the
    end of every earlier leader's authority to grant. -/
def rqNewStart (thisStop earlierLeadersEnd L margin : Nat) : Nat := max thisStop earlierLeadersEnd + L + margin

/-! ## The commit check -/

/-- A write admitted at `admit`, committed at `commit` (after any pause),
    checked again at `postCheck` (≥ commit) when `checkAfterCommit`. Is it
    acknowledged? -/
def acked (admit commit postCheck expiry : Nat) (checkAfterCommit : Bool) : Bool :=
  admit < expiry && (!checkAfterCommit || postCheck < expiry)

/-- The safety condition for one write: acknowledged → committed inside the
    authority. -/
def ackSafe (admit commit postCheck expiry : Nat) (checkAfterCommit : Bool) : Bool :=
  !acked admit commit postCheck expiry checkAfterCommit || commit < expiry


/-! ## The post-commit check is bound to the SAME grant (review of 9124993)

A write remembers the grant (term, lease generation) it was admitted under.
The lease generation moves on every lapse -> valid transition (like the
planned-eviction fence generation); a renewal without a lapse keeps it. The
post-commit check passes only if that same grant is still valid: a grant
received meanwhile by another thread (a new term, or the same term after a
lapse) does not acknowledge a commit made outside it. -/

structure GrantId where
  term : Nat
  gen : Nat
  deriving Repr, BEq

/-- The lease the node holds at check time: its grant and expiry. -/
structure Held where
  id : GrantId
  expiry : Nat
  deriving Repr, BEq

/-- Naive: ACK if ANY lease is valid at the check. -/
def ackedNaive (admitted : GrantId) (atCheck : Held) (postCheck : Nat) : Bool :=
  let _ := admitted
  postCheck < atCheck.expiry

/-- Bound: ACK only if the lease valid at the check is the one admitted under. -/
def ackedBound (admitted : GrantId) (atCheck : Held) (postCheck : Nat) : Bool :=
  atCheck.id == admitted && postCheck < atCheck.expiry

/-! ## Membership: solo, replicated, and the authority handover

The authoritative membership (persisted by the operator, compare-and-swap,
term-numbered) says per partition whether a SUCCESSOR exists: a replica that
passed the existing eligibility checks (copy / history / not rebuilding)
and that the master has ACKNOWLEDGED as a successor.

* solo: no successor in the membership. Nothing can be promoted without a
  membership change, and a successor can only be added with the master's
  acknowledgement, so the master writes WITHOUT a lease (requirement 1: not
  stopped for nothing). "I cannot see a slave" is never solo: only the
  authoritative membership is.
* replicated: the master writes only while it holds authority from the
  operator (a request-bound lease) OR a promise from EVERY successor (each
  successor refuses promotion until the promise ends). An operator outage
  alone does not stop it while it reaches its successors (no control-plane
  single point of failure for writes).
* promotion of successor r: the operator has stopped granting (persisted),
  waited L + margin after the last moment any leader could grant, r holds no
  unexpired promise to the old master, and r passes the existing checks.
* solo -> replicated: r is made a successor (promotable) only AFTER the master
  acknowledged the change (it is then lease / promise bound).
* replicated -> solo: the membership commit removing r comes FIRST; the
  master drops the lease requirement only after it learns of that commit. -/

inductive Mode where
  | solo
  | replicated
  deriving Repr, BEq

/-- The old master's authority end under the membership rule. `none` =
    unbounded (solo). `leaseEnd` = its operator lease (0 = none), `promises`
    = each successor's promise end. -/
def masterAuthorityEnd (mode : Mode) (leaseEnd : Nat) (promises : List Nat) : Option Nat :=
  match mode with
  | .solo => none
  | .replicated => some (max leaseEnd (if promises.isEmpty then 0 else promises.foldl min promises.head!))

/-- When successor r may start as the new master (`none` = never): only in
    replicated mode, after the operator's wait and after r's own promise to
    the old master ended. -/
def promotionStart (mode : Mode) (operatorStop earlierLeadersEnd L margin rPromiseEnd : Nat) : Option Nat :=
  match mode with
  | .solo => none
  | .replicated => some (max (rqNewStart operatorStop earlierLeadersEnd L margin) rPromiseEnd)

/-- S1 for one handover: the old master's authority [from, end) and the new
    master's [start, ∞) do not overlap. -/
def handoverSafe (oldFrom : Nat) (oldEnd : Option Nat) (newStart : Option Nat) : Bool :=
  match newStart with
  | none => true
  | some st => match oldEnd with
    | none => false          -- unbounded old authority and a promotion: overlap
    | some e => !({ start := oldFrom, stop := e } : Interval).overlaps { start := st, stop := st + 1000000 }


/-! ## Event model of the successor promise (review of a6ba116)

The functions above compare deadlines they are GIVEN; they say nothing about
how promises are issued, renewed, stopped, forgotten, or bound to a
membership. This part replays EVENT SEQUENCES (one master M, one successor
R, the membership store, the operator) and checks the invariant

  INV: if R becomes master at s, then M is not solo and every promise M
       holds ended by s (M's authority from promises ⊆ [·, s)).

It is still one real-time axis with no clock drift and no message loss
other than what the sequence says: concrete counterexamples and their fixes,
NOT a proof for two clocks, drift or arbitrary delays.

Rules (each can be switched off to show its counterexample):
* stopOnPrepare — R enters PREPARING atomically on the operator's prepare
  (persisted before acknowledging it): it issues no new promise and rejects
  renewals from then on. Without it, an M that still reaches R renews for
  ever and R2 (finite switchover) fails.
* waitAfterRestart — R may forget promises on a restart / replacement
  (tmpfs, a new pod): it accepts promotion only P + margin after it started.
* genCheck — every config / promise carries the membership generation; a
  node keeps the highest it has seen (persisted) and ignores anything older.
* recordBeforeReply — R records the promise end BEFORE it replies. -/

structure Rules where
  stopOnPrepare : Bool := true
  waitAfterRestart : Bool := true
  genCheck : Bool := true
  recordBeforeReply : Bool := true
  deriving Repr

structure Params where
  /-- promise duration -/
  P : Nat := 10
  margin : Nat := 1
  deriving Repr

inductive Ev where
  /-- M asks R for a promise (nonce `n`) at `t`, bound to its generation -/
  | mAsk (t n : Nat)
  /-- R receives M's request `n` (sent at `q`, generation `g`) at `t` -/
  | rRecv (t n q g : Nat)
  /-- M receives R's promise for request `n` (generation `g`) at `t` -/
  | mRecv (t n g : Nat)
  /-- the operator's prepare reaches R at `t` (generation `g`) -/
  | prepare (t g : Nat)
  /-- R restarts at `t`; `durable` = its promise record survives -/
  | rRestart (t : Nat) (durable : Bool)
  /-- the membership store commits generation `g` at `t` (`solo` = no successor) -/
  | commit (t g : Nat) (solo : Bool)
  /-- a config of generation `g` reaches M at `t` -/
  | mConfig (t g : Nat) (solo : Bool)
  /-- the operator tries to promote R at `t` under generation `g` -/
  | promote (t g : Nat)
  deriving Repr

structure St where
  mGen : Nat := 1
  mSolo : Bool := false
  /-- outstanding requests: nonce, sent at -/
  mAsked : List (Nat × Nat) := []
  mPromiseEnd : Nat := 0
  rGen : Nat := 1
  rPreparing : Bool := false
  rPromisedUntil : Nat := 0
  rStartedAt : Nat := 0
  /-- requests R actually answered (M can only receive those) -/
  rReplied : List Nat := []
  storeGen : Nat := 1
  storeSolo : Bool := false
  newStart : Option Nat := none
  log : List String := []
  deriving Repr

def stepEv (ru : Rules) (pa : Params) (s : St) : Ev → St
  | .mAsk t n => { s with mAsked := s.mAsked ++ [(n, t)] }
  | .rRecv t n q g =>
    if ru.stopOnPrepare && s.rPreparing then { s with log := s.log ++ [s!"R rejects the request sent at {q}: preparing"] }
    else if ru.genCheck && g < s.rGen then { s with log := s.log ++ ["R rejects a request of an older generation"] }
    else if ru.recordBeforeReply then { s with rPromisedUntil := max s.rPromisedUntil (t + pa.P + pa.margin), rReplied := s.rReplied ++ [n] }
    else { s with rReplied := s.rReplied ++ [n] }
  | .mRecv t n g =>
    match s.mAsked.lookup n with
    | none => s
    | some _ => if !s.rReplied.contains n then { s with mAsked := s.mAsked.filter (·.1 != n) } else
    match s.mAsked.lookup n with
    | none => s
    | some q =>
      let asked := s.mAsked.filter (·.1 != n)
      if t ≥ q + pa.P || (ru.genCheck && g != s.mGen) then { s with mAsked := asked }
      else { s with mAsked := asked, mPromiseEnd := max s.mPromiseEnd (q + pa.P) }
  | .prepare _ g =>
    if ru.genCheck && g < s.rGen then s else { s with rPreparing := true, rGen := max s.rGen g }
  | .rRestart t durable =>
    { s with rStartedAt := t, rPromisedUntil := if durable then s.rPromisedUntil else 0 }
  | .commit _ g solo => { s with storeGen := g, storeSolo := solo }
  | .mConfig _ g solo =>
    if ru.genCheck && g ≤ s.mGen then { s with log := s.log ++ [s!"M ignores the config of generation {g} (has {s.mGen})"] }
    else { s with mGen := max s.mGen g, mSolo := solo }
  | .promote t g =>
    if s.newStart.isSome then s
    else if s.storeSolo || g != s.storeGen then { s with log := s.log ++ [s!"promotion at {t} refused: the membership (generation {s.storeGen}) has no such successor"] }
    else if ru.stopOnPrepare && !s.rPreparing then { s with log := s.log ++ [s!"promotion at {t} refused: R is not preparing"] }
    else if t < s.rPromisedUntil then { s with log := s.log ++ [s!"promotion at {t} refused: R's promise runs to {s.rPromisedUntil}"] }
    else if ru.waitAfterRestart && t < s.rStartedAt + pa.P + pa.margin then { s with log := s.log ++ [s!"promotion at {t} refused: R restarted at {s.rStartedAt}"] }
    else { s with newStart := some t }

def Ev.time : Ev → Nat
  | .mAsk t _ | .rRecv t _ _ _ | .mRecv t _ _ | .prepare t _ | .rRestart t _ | .commit t _ _ | .mConfig t _ _ | .promote t _ => t

/-- Replay in time order (stable: events at the same second keep their
    listed order). -/
def run (ru : Rules) (pa : Params) (init : St) (evs : List Ev) : St :=
  (evs.mergeSort (fun a b => decide (a.time ≤ b.time))).foldl (stepEv ru pa) init

/-- INV (see above). -/
def inv (s : St) : Bool :=
  match s.newStart with
  | none => true
  | some st => !s.mSolo && s.mPromiseEnd ≤ st

/-- M renews every 5 s from `from` to `upto`; R receives 1 s later, M gets
    the promise 1 s after that (both reachable). -/
def renewals (fr upto : Nat) (g : Nat := 1) : List Ev :=
  ((List.range ((upto - fr) / 5 + 1)).map fun i => fr + i * 5).flatMap fun q =>
    [Ev.mAsk q q, Ev.rRecv (q + 1) q q g, Ev.mRecv (q + 2) q g]

end FlareOperator.WriteLeaseModel
