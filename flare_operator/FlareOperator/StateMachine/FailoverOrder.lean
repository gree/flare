/-
  StateMachine/FailoverOrder.lean — which copy a masterless partition promotes
  first (spec 4/12, user decision 2026-10-27).

  The promotion target is the slave reachable from the operator that holds the
  NEWEST data: among the slaves that followed the LAST master, the one with the
  largest position (sequence) applied from that master. Positions are
  comparable only inside one source epoch, so the comparison is made only
  between copies whose `repl_follow_source_epoch` equals the partition's last
  master history (the recorded epoch). A copy of another history is never
  ranked: it is a candidate only when no follower of the last master remains
  (the caller's existing tiers decide that; this module only ORDERS).

  This module never admits a candidate. Known-bad copies (forbidden markers,
  corruption, partial copy, quarantine, rebuild in flight, empty) are removed
  by the existing gates (R3, PromotionEvidence, history holder rules, the
  follow-unfit list); the caller passes only copies those gates accept, and
  K8sReconciler.promoteMasterlessPartition still applies them to whatever this
  module returns. When the order cannot be proven (the last master's epoch
  unknown, or a follower of it whose applied position was unreadable) the
  verdict says so and the caller's fallback (map order) is allowed only as NOT
  LOSS-FREE, logged like the existing last resort.
-/

namespace FlareOperator.FailoverOrder

/-- One live copy of the partition as read this pass. -/
structure Copy where
  key : String
  /-- repl_follow_source_epoch: the history the applied position belongs to. -/
  epoch : Option String := none
  /-- repl_applied_lsn. -/
  applied : Option Nat := none
  deriving Repr, BEq

inductive Proof where
  /-- At least one follower of the last master has a readable position and no
      follower of it is unreadable: the first ranked key holds the newest data
      among the followers. -/
  | proven
  /-- A follower of the last master exists but a position is unreadable, so the
      newest cannot be told: the fallback is NOT LOSS-FREE. -/
  | unreadable
  /-- No copy is known to have followed the last master (or its epoch is
      unknown): the existing tiers (other histories, holders) decide, not
      ranked. -/
  | noFollower
  deriving Repr, BEq, DecidableEq

structure Order where
  /-- Followers of the last master with a readable position, largest first
      (equal positions keep input order). -/
  ranked : List String := []
  proof : Proof := .noFollower
  deriving Repr, BEq

private def insertDesc (c : String × Nat) : List (String × Nat) → List (String × Nat)
  | [] => [c]
  | d :: rest => if c.2 > d.2 then c :: d :: rest else d :: insertDesc c rest

/-- Order `copies` for a partition whose last master history is `lastEpoch`. -/
def order (lastEpoch : Option String) (copies : List Copy) : Order :=
  match lastEpoch with
  | none => {}
  | some ep =>
    let followers := copies.filter fun c => c.epoch == some ep
    let readable := followers.filterMap fun c => c.applied.map (c.key, ·)
    let sorted := readable.foldl (fun acc c => insertDesc c acc) []
    let unreadable := followers.length != readable.length
    { ranked := sorted.map Prod.fst,
      proof := if followers.isEmpty then .noFollower
               else if unreadable then .unreadable else .proven }

/-- One line for the log of a masterless partition's order. -/
def Order.describe (o : Order) : String :=
  match o.proof with
  | .proven => s!"promotion order proven by applied position in the last master's epoch: {o.ranked}"
  | .unreadable => s!"promotion order NOT proven (a follower of the last master has no readable applied position; ranked readable ones {o.ranked}): a fallback is NOT LOSS-FREE"
  | .noFollower => "no follower of the last master is known: other copies are candidates only through the existing tiers"

/-- The first of `ranked` (best first) that `pred` accepts; none if no ranked
    key qualifies, so the caller's own order applies. Never adds a candidate:
    `pred` is the caller's gate. -/
def firstRanked {α : Type} (ranked : List String) (items : List (String × α))
    (pred : String × α → Bool) : Option (String × α) :=
  ranked.findSome? fun k => items.find? fun kv => kv.1 == k && pred kv

end FlareOperator.FailoverOrder
