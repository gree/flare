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

end FlareOperator.WriteLeaseModel
