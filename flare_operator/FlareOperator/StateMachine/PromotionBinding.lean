/-
  PromotionBinding.lean — what a promotion intent / message is bound to, and
  how time is represented. NOT wired into the operator or flared (imported only
  by PromotionIntent / PromotionRefusal and their checks).

  ## Time
  A time value is `At`: a reading of ONE node's monotonic clock IN ONE BOOT.
  Clock origins differ between nodes and between boots of the same node, so
  two `At` are comparable only when their `ClockId` is identical; otherwise the
  comparison is `none` and every caller refuses (never "safe"). No cross-node
  or cross-boot arithmetic exists in this component.

  A bound that crosses a node is therefore never an `At` of the sender. The
  protocol that yields an `At` on the receiver's own clock (`fromRequest`):
    * the SENDER S sends a request at a point of its own clock and states only
      a DURATION `d` counted from that send point (S's authority / promise /
      prepare window lasts at most `d` after the send);
    * the RECEIVER R stamps the moment it RECEIVES the request with its own
      clock, `recvAt`. The receive is after the send, so on R's clock the end
      of S's window is at most `recvAt + d` (+ the drift of the two clocks
      over `d`, which the caller passes as `margin` and which this component
      does not choose);
    * the derived bound is `At` on R's clock; it is the only form in which
      another node's window is ever recorded.
  Premises (not proved here): `d` is an upper bound that S really honours
  (S stops using the window `d` after its send point on its own clock); the
  clocks run at rates within `margin` over `d`; `recvAt` is read on R's clock
  at the moment of receipt, not later than when R acts on the request.
  A persisted `At` is valid only while the node's boot id is unchanged
  (see `PromotionRefusal.onBoot` for what a new boot may assume).
-/
import FlareOperator.StateMachine.AuthoritativeHistory

namespace FlareOperator.PromotionBinding

structure ClockId where
  node : String
  boot : String
  deriving Repr, DecidableEq, BEq

structure At where
  clock : ClockId
  t : Nat
  deriving Repr, DecidableEq, BEq

/-- `deadline ≤ now`, defined only on one clock. -/
def At.reached? (now deadline : At) : Option Bool :=
  if now.clock = deadline.clock then some (deadline.t ≤ now.t) else none

/-- The receiver-side bound of a window the sender announced as a duration. -/
def At.fromRequest (own : ClockId) (recvAt d : Nat) : At := { clock := own, t := recvAt + d }

/-- Where an intent lives. `generation` is the membership generation. -/
structure Scope where
  cluster : String
  partition : Nat
  generation : Nat
  deriving Repr, DecidableEq, BEq

/-- Existing copy identity (pod uid, flared boot id, copy id), reused. -/
abbrev Binding := FlareOperator.AuthoritativeHistory.Binding

/-- The membership as authoritatively known at the evaluating site. -/
structure Membership where
  scope : Scope
  members : List String
  deriving Repr, DecidableEq, BEq

inductive Mismatch where
  | wrongScope        -- another cluster or partition
  | staleGeneration   -- same partition, another membership generation
  | staleIntent       -- another intent id
  | wrongSuccessor    -- another successor name
  | wrongBinding      -- same name, another pod uid / boot id / copy id
  | notMember         -- successor not in the current membership
  deriving Repr, DecidableEq, BEq

def Scope.check (have_ want : Scope) : Option Mismatch :=
  if have_.cluster ≠ want.cluster ∨ have_.partition ≠ want.partition then some .wrongScope
  else if have_.generation ≠ want.generation then some .staleGeneration
  else none

/-- The exact identity an intent or a message is addressed to. -/
structure Ref where
  scope : Scope
  id : Nat
  successor : String
  binding : Binding
  deriving Repr, DecidableEq, BEq

def Ref.check (have_ want : Ref) : Option Mismatch :=
  match have_.scope.check want.scope with
  | some m => some m
  | none =>
    if have_.id ≠ want.id then some .staleIntent
    else if have_.successor ≠ want.successor then some .wrongSuccessor
    else if have_.binding ≠ want.binding then some .wrongBinding
    else none

/-- The membership read must be of the intent's own scope and contain the successor. -/
def Membership.check (m : Membership) (scope : Scope) (successor : String) : Option Mismatch :=
  match m.scope.check scope with
  | some x => some x
  | none => if successor ∈ m.members then none else some .notMember

/-- The peer an old master granted authority to (grant messages bind to it). -/
structure Peer where
  scope : Scope
  binding : Binding
  deriving Repr, DecidableEq, BEq

end FlareOperator.PromotionBinding
