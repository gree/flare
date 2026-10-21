/-
  PromotionRefusal.lean — refusal rules as pure functions. NOT wired into the
  operator or flared. Every number (deadline, lease, margin) is an argument or
  a record field; no default is chosen here.

  Two sides:
  * the SUCCESSOR (R): when it must refuse to resume its promises and when it
    must refuse to be promoted (`mayResume`, `mayPromote`, `onTimer`, `onRead`);
  * the OLD MASTER (M): when it must refuse client writes
    (`masterRefusesWrite`), keeping the solo case serving.
  Clock premise: `now` is the evaluating node's own monotonic clock; the
  comparisons across nodes assume the drift bound is inside `margin`.
-/
import FlareOperator.StateMachine.PromotionIntent

namespace FlareOperator.PromotionRefusal

open FlareOperator.PromotionIntent

/-! ## Successor side -/

inductive Role where
  | following | preparing | promoted
  deriving Repr, DecidableEq, BEq

/-- The successor's local, persisted view. `localOldUntil` is the last promise
    end R itself issued (own record, survives the role changes); it is what R
    checks before activating, independent of what the store says. -/
structure View where
  identity : String
  role : Role := .following
  intent : Option Nat := none
  deadline : Option Nat := none
  localOldUntil : Nat := 0
  activation : Option Nat := none
  deriving Repr, DecidableEq, BEq

inductive Action where
  /-- try the cancel CAS (the timer licenses ONLY this) -/
  | tryCancel
  | resumePromises
  | activate (at_ : Nat)
  deriving Repr, DecidableEq, BEq

inductive Why where
  | notPreparing | noRecord | storeUnreachable | recordUnreadable
  | otherIntent | otherSuccessor | pending | committedNeverResumes
  | notCommitted | oldAuthorityLive | promiseResumed | unprepared
  deriving Repr, DecidableEq, BEq

/-- Resume promises iff the store affirms THIS intent is cancelled. An elapsed
    deadline, an unreachable or unreadable store, an absent record, a pending
    or committed intent never allow it. -/
def mayResume (v : View) (r : ReadResult) : Except Why Unit :=
  if v.role ≠ .preparing then .error .notPreparing
  else match r with
  | .unreachable => .error .storeUnreachable
  | .malformed _ => .error .recordUnreadable
  | .absent => .error .noRecord
  | .present i =>
    if some i.id ≠ v.intent then .error .otherIntent
    else if i.successor ≠ v.identity then .error .otherSuccessor
    else match i.decision with
      | .cancelled => .ok ()
      | .pending => .error .pending
      | .committed => .error .committedNeverResumes

/-- Be promoted iff: still PREPARING this intent; the store affirms it is
    committed to THIS identity; the old authority (the later of the store's
    `oldUntil` and R's own last issued promise) has ended on R's clock plus
    `margin`. -/
def mayPromote (v : View) (r : ReadResult) (now margin : Nat) : Except Why Unit :=
  if v.role ≠ .preparing then .error .notPreparing
  else match r with
  | .unreachable => .error .storeUnreachable
  | .malformed _ => .error .recordUnreadable
  | .absent => .error .noRecord
  | .present i =>
    if some i.id ≠ v.intent then .error .otherIntent
    else if i.successor ≠ v.identity then .error .otherSuccessor
    else match i.decision with
      | .pending => .error .notCommitted
      | .cancelled => .error .unprepared
      | .committed =>
        match i.oldUntil with
        | none => .error .notCommitted  -- decode already rejects; defence in depth
        | some u =>
          if max u v.localOldUntil + margin > now then .error .oldAuthorityLive
          else .ok ()

/-- Prepare received and made durable. A prepare while preparing/promoted is
    ignored (no second intent over a live one). -/
def onPrepared (v : View) (id deadline : Nat) : View :=
  if v.role = .following then
    { v with role := .preparing, intent := some id, deadline := some deadline }
  else v

/-- The deadline timer: NEVER changes the role. It only asks for the cancel CAS. -/
def onTimer (v : View) (now : Nat) : View × List Action :=
  match v.role, v.deadline with
  | .preparing, some d => if d ≤ now then (v, [.tryCancel]) else (v, [])
  | _, _ => (v, [])

/-- A store read arrived while preparing. -/
def onRead (v : View) (r : ReadResult) (now margin : Nat) : View × List Action :=
  match mayResume v r with
  | .ok () => ({ v with role := .following, intent := none, deadline := none }, [.resumePromises])
  | .error _ =>
    match mayPromote v r now margin with
    | .ok () => ({ v with role := .promoted, activation := some now }, [.activate now])
    | .error _ => (v, [])

/-- Promise issuing / renewal: only while following. `end_` is the request-bound
    end; the successor keeps the maximum it ever issued. -/
def renew (v : View) (end_ : Nat) : View × Bool :=
  if v.role = .following then ({ v with localOldUntil := max v.localOldUntil end_ }, true)
  else (v, false)

/-- Safety predicate of one run: the old master's authority (as recorded) ended
    no later than the activation. -/
def noOverlap (v : View) (oldMasterEnd : Nat) : Bool :=
  match v.activation with
  | none => true
  | some t => oldMasterEnd ≤ t

/-! ## Old master side -/

/-- `solo` serves without a lease (R1: no write stop just because it is alone);
    it is decided by the authoritative membership, not by "cannot see a replica".
    `withSuccessor e` may ACK only while its own request-bound authority lasts
    (`e` on M's clock). `fenced` has seen a newer term / generation. -/
inductive MasterMode where
  | solo
  | withSuccessor (authorityEnd : Nat)
  | fenced
  deriving Repr, DecidableEq, BEq

def masterRefusesWrite (m : MasterMode) (now margin : Nat) : Bool :=
  match m with
  | .solo => false
  | .withSuccessor e => e ≤ now + margin
  | .fenced => true

/-- A grant extends the authority only if it answers the outstanding request
    (nonce) and arrives before the request's own end; the end is counted from
    when M SENT the request, so a late grant can only shorten, never extend. -/
def acceptGrant (m : MasterMode) (outstandingNonce grantNonce sentAt now lease : Nat) : MasterMode :=
  match m with
  | .withSuccessor e =>
    if outstandingNonce = grantNonce ∧ now < sentAt + lease then .withSuccessor (max e (sentAt + lease))
    else m
  | _ => m

/-- solo -> withSuccessor only through an approval that already binds M to a
    lease; withSuccessor -> solo only on a confirmed (committed) membership
    removal of the successor — not on "cannot see it". -/
def approveSuccessor (m : MasterMode) (authorityEnd : Nat) : MasterMode :=
  match m with
  | .solo => .withSuccessor authorityEnd
  | _ => m

def membershipRemoved (m : MasterMode) (confirmedCommitted : Bool) : MasterMode :=
  match m with
  | .withSuccessor _ => if confirmedCommitted then .solo else m
  | _ => m

def fence (_ : MasterMode) : MasterMode := .fenced

end FlareOperator.PromotionRefusal
