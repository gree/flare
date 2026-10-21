/-
  PromotionRefusal.lean — refusal rules as pure functions. NOT wired into the
  operator or flared. Every number (deadline, lease, margin) is an argument or
  a record field; no default is chosen here.

  Two sides:
  * the SUCCESSOR (R): when it must refuse to resume its promises and when it
    must refuse to be promoted (`mayResume`, `mayPromote`, `onTimer`, `onRead`);
  * the OLD MASTER (M): when it must refuse client writes
    (`masterRefusesWrite`), keeping the solo case serving.
  Time: every instant is an `At` (clock = node + boot, see PromotionBinding).
  Nothing here compares instants of different clocks; a mismatch refuses.
  A window of another node reaches this component only as a bound already
  derived on the evaluating node's own clock by the protocol in
  PromotionBinding (`At.fromRequest`); this file does not prove that the
  derivation was done right. `margin` (drift over the window) is an argument.
-/
import FlareOperator.StateMachine.PromotionIntent
import FlareOperator.StateMachine.PromotionBinding

namespace FlareOperator.PromotionRefusal

open FlareOperator.PromotionIntent
open FlareOperator.PromotionBinding

/-! ## Successor side -/

inductive Role where
  | following | preparing | promoted
  deriving Repr, DecidableEq, BEq

/-- The successor's local, persisted view. `identity` + `binding` + `scope` are
    who it is (name, pod uid / flared boot / copy, cluster-partition-generation).
    `clock` is its CURRENT clock (node + boot). `localOldUntil` is the last
    promise end R itself issued, on `clock`; it is what R checks before
    activating, independent of what the store says. -/
structure View where
  identity : String
  binding : Binding
  scope : Scope
  clock : ClockId
  role : Role := .following
  intent : Option Nat := none
  deadline : Option At := none
  localOldUntil : At
  activation : Option At := none
  deriving Repr, DecidableEq, BEq

def View.init (identity : String) (binding : Binding) (scope : Scope) (clock : ClockId) : View :=
  { identity, binding, scope, clock, localOldUntil := { clock, t := 0 } }

/-- The ref this successor answers to for its current intent. -/
def View.ref? (v : View) : Option Ref :=
  v.intent.map fun id => { scope := v.scope, id, successor := v.identity, binding := v.binding }

inductive Action where
  /-- try the cancel CAS (the timer licenses ONLY this) -/
  | tryCancel
  | resumePromises
  | activate (at_ : At)
  deriving Repr, DecidableEq, BEq

inductive Why where
  | notPreparing | noRecord | storeUnreachable | recordUnreadable
  | mismatch (m : Mismatch)
  | pending | committedNeverResumes
  | notCommitted | oldAuthorityLive | promiseResumed | unprepared
  | clockMismatch
  deriving Repr, DecidableEq, BEq

/-- The record must be exactly this view's intent. -/
private def bound (v : View) (i : Intent) : Option Mismatch :=
  match v.ref? with
  | none => some .staleIntent
  | some r => i.ref.check r

/-- Resume promises iff the store affirms THIS exact intent is cancelled. An
    elapsed deadline, an unreachable or unreadable store, an absent record, a
    pending or committed intent never allow it. -/
def mayResume (v : View) (r : ReadResult) : Except Why Unit :=
  if v.role ≠ .preparing then .error .notPreparing
  else match r with
  | .unreachable => .error .storeUnreachable
  | .malformed _ => .error .recordUnreadable
  | .absent => .error .noRecord
  | .present i =>
    match bound v i with
    | some m => .error (.mismatch m)
    | none =>
      match i.decision with
      | .cancelled => .ok ()
      | .pending => .error .pending
      | .committed => .error .committedNeverResumes

/-- Be promoted iff: still PREPARING this intent; the store affirms it is
    committed to exactly this successor (name, pod uid, boot, copy, scope);
    `members` (the evaluator's current membership) is of the same scope and
    still contains it; the old authority — the later of the store's `oldUntil`
    and R's own last issued promise, BOTH on R's current clock — has ended at
    `now` (R's clock) plus `margin`. A bound on another clock or another boot
    is not comparable and refuses. -/
def mayPromote (v : View) (r : ReadResult) (members : Membership) (now margin : Nat) :
    Except Why Unit :=
  if v.role ≠ .preparing then .error .notPreparing
  else match r with
  | .unreachable => .error .storeUnreachable
  | .malformed _ => .error .recordUnreadable
  | .absent => .error .noRecord
  | .present i =>
    match bound v i with
    | some m => .error (.mismatch m)
    | none =>
      match i.decision with
      | .pending => .error .notCommitted
      | .cancelled => .error .unprepared
      | .committed =>
        match members.check v.scope v.identity with
        | some m => .error (.mismatch m)
        | none =>
          match i.oldUntil with
          | none => .error .notCommitted  -- decode already rejects; defence in depth
          | some u =>
            if u.clock ≠ v.clock ∨ v.localOldUntil.clock ≠ v.clock then .error .clockMismatch
            else if max u.t v.localOldUntil.t + margin > now then .error .oldAuthorityLive
            else .ok ()

/-- Prepare received (and made durable) at `recvAt` on R's clock. The message
    must be addressed to exactly this successor (scope, name, pod uid, boot,
    copy); otherwise it is ignored. A prepare while preparing/promoted is
    ignored (no second intent over a live one). The local deadline is the
    announced duration counted from R's receive point (later or equal to the
    store's, which is harmless: it only times a cancel TRY). -/
def onPrepared (v : View) (ref : Ref) (recvAt dur : Nat) : View :=
  if v.role = .following ∧ ref.scope = v.scope ∧ ref.successor = v.identity ∧
      ref.binding = v.binding then
    { v with role := .preparing, intent := some ref.id,
             deadline := some (At.fromRequest v.clock recvAt dur) }
  else v

/-- The deadline timer: NEVER changes the role. It only asks for the cancel CAS.
    A deadline stamped in another boot cannot be compared: the cancel TRY is
    still safe (the store decides on its own clock), so it is asked. -/
def onTimer (v : View) (now : Nat) : View × List Action :=
  match v.role, v.deadline with
  | .preparing, some d =>
    if d.clock ≠ v.clock then (v, [.tryCancel])
    else if d.t ≤ now then (v, [.tryCancel]) else (v, [])
  | _, _ => (v, [])

/-- A store read arrived while preparing. -/
def onRead (v : View) (r : ReadResult) (members : Membership) (now margin : Nat) :
    View × List Action :=
  match mayResume v r with
  | .ok () => ({ v with role := .following, intent := none, deadline := none }, [.resumePromises])
  | .error _ =>
    match mayPromote v r members now margin with
    | .ok () =>
      let a : At := { clock := v.clock, t := now }
      ({ v with role := .promoted, activation := some a }, [.activate a])
    | .error _ => (v, [])

/-- Promise issuing / renewal: only while following. The promise lasts `lease`
    from the request's receive point `recvAt` on R's clock; R keeps the maximum
    it ever issued. -/
def renew (v : View) (recvAt lease : Nat) : View × Bool :=
  if v.role = .following then
    ({ v with localOldUntil :=
        { clock := v.clock, t := max (if v.localOldUntil.clock = v.clock then v.localOldUntil.t else 0)
                                     (At.fromRequest v.clock recvAt lease).t } }, true)
  else (v, false)

/-- A new boot of R's node: a new clock. What R persisted as `At` of the old
    boot (`localOldUntil`, `deadline`, the store's `oldUntil`) is not comparable
    any more. Premise: every promise R issued in an earlier boot lasts at most
    `maxLease` from a receive point that is before this boot's time 0, so on the
    new clock they all ended by `bootAt + maxLease` (`bootAt` = this boot's
    reading when the service resumed). `maxLease` is an argument, not chosen
    here. The role and intent are kept (persisted). -/
def onBoot (v : View) (newClock : ClockId) (bootAt maxLease : Nat) : View :=
  { v with clock := newClock, localOldUntil := { clock := newClock, t := bootAt + maxLease } }

/-- Safety predicate of one run: the old master's authority (as recorded) ended
    no later than the activation, both on the same clock (else not established). -/
def noOverlap (v : View) (oldMasterEnd : At) : Bool :=
  match v.activation with
  | none => true
  | some t => oldMasterEnd.clock == t.clock && oldMasterEnd.t ≤ t.t

/-! ## Old master side -/

/-- `solo` serves without a lease (R1: no write stop just because it is alone);
    it is decided by the authoritative membership, not by "cannot see a replica".
    `withSuccessor p e` may ACK only while its own request-bound authority lasts
    (`e` on M's clock), granted by exactly the peer `p`. `fenced` has seen a
    newer term / generation. -/
inductive MasterMode where
  | solo
  | withSuccessor (peer : Peer) (authorityEnd : At)
  | fenced
  deriving Repr, DecidableEq, BEq

/-- An authority end on another clock / boot than `now` (M restarted) is not
    comparable: refuse. -/
def masterRefusesWrite (m : MasterMode) (now : At) (margin : Nat) : Bool :=
  match m with
  | .solo => false
  | .withSuccessor _ e => e.clock ≠ now.clock || e.t ≤ now.t + margin
  | .fenced => true

/-- A grant extends the authority only if it comes from the bound peer (scope,
    pod uid, boot, copy), answers the outstanding request (nonce), arrives
    before the request's own end, and all instants are on M's current clock; the
    end is counted from when M SENT the request, so a late grant can only
    shorten, never extend. -/
def acceptGrant (m : MasterMode) (from_ : Peer) (outstandingNonce grantNonce : Nat)
    (sentAt now : At) (lease : Nat) : MasterMode :=
  match m with
  | .withSuccessor p e =>
    if from_ = p ∧ outstandingNonce = grantNonce ∧ sentAt.clock = now.clock ∧ e.clock = now.clock ∧
        now.t < sentAt.t + lease then
      .withSuccessor p { e with t := max e.t (sentAt.t + lease) }
    else m
  | _ => m

/-- solo -> withSuccessor only through an approval that already binds M to a
    peer and a lease; withSuccessor -> solo only on a confirmed (committed)
    membership removal of the successor — not on "cannot see it". -/
def approveSuccessor (m : MasterMode) (peer : Peer) (authorityEnd : At) : MasterMode :=
  match m with
  | .solo => .withSuccessor peer authorityEnd
  | _ => m

def membershipRemoved (m : MasterMode) (confirmedCommitted : Bool) : MasterMode :=
  match m with
  | .withSuccessor _ _ => if confirmedCommitted then .solo else m
  | _ => m

def fence (_ : MasterMode) : MasterMode := .fenced

end FlareOperator.PromotionRefusal
