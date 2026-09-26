/-
  StateMachine/FollowEvidence.lean — SAF-10c: purpose-specific eligibility of
  a continuous-replication (WAL-mode) replica. SC-04 / EV-04 (promotion),
  SC-05 / EV-05 (deleting another copy), read set (design §5.3), UCA-26.

  "A lagging or unobservable replica is treated as safe for reads, promotion
  or deletion" is the unsafe control action. This module states, once and
  purely, what the operator may conclude from a follower's own stats:

  * A replica in WAL mode is OUT of the read set unless it is `following` the
    master's CURRENT history (same source epoch), the master's position was
    observed recently BY THE NODE'S OWN CLOCK (both timestamps come from the
    same stats reply, so operator/node clock skew cancels), and its applied
    position is within the read lag bound of the master's head as read from
    the master THIS pass.
  * Planned promotion (drain) and "another copy survives, so this one may be
    deleted" require the same, under the (tighter) promotion bound.
  * Failover when the master is gone: nothing can be proven — the design says
    so (§5.3: "it can never be proven that the replica held everything the
    master acknowledged"). The FSM still promotes for availability, but this
    module (a) EXCLUDES a follower known to hold an incomplete or foreign copy
    (`needs_rebuild`, `initial_sync`, `idle`, another epoch) and (b) ORDERS the
    proven-current followers first, highest applied position first. The FSM
    logs such a promotion as NOT loss-free.
  * Unknown is Unknown. An unreadable or incomplete reply is `unknown`, never
    "healthy": it withholds reads and blocks planned promotion/deletion, but
    it never makes a node `unfit` — a stats hiccup must not remove the last
    failover candidate (that would be UCA-26's mirror image).

  Nodes that are NOT in WAL mode (`repl_follow_enabled` 0, or a flared that
  has no such stat) are `notInMode`: this module has no say and every
  pre-existing rule stands unchanged. The mode is remembered per node so a
  node once seen in WAL mode whose stats then become unreadable is treated as
  Unknown (withheld), not as "not in mode". A node NEVER yet read is also
  withheld until a complete reply establishes its mode. This can temporarily
  route reads to masters at start-up, including in non-WAL clusters, but an
  operator restart must not re-admit a disconnected WAL replica.

  Pure. Main.lean reads the stats and applies the lists to the FSM
  (K8sReconciler.shapePromotionCandidates / promoteMasterlessPartition's
  exclusion), to the commit path (K8sReconciler.withholdReads) and to the
  delete gate (StatsObservation.deleteGate's `survivorFollowOk`).
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.FollowEvidence

/-- One replica's own `stats` reply, typed. Every `none` means "not
    readable", never zero or false. -/
structure Reading where
  /-- The reply carried END (a truncated reply must not be read as "the key
      is absent, so the mode is off"). -/
  complete : Bool := false
  /-- repl_follow_enabled. -/
  enabled : Option Bool := none
  /-- repl_follow_state: idle / initial_sync / following / disconnected /
      needs_rebuild / error. -/
  state : Option String := none
  /-- repl_follow_source_epoch: the history the position belongs to. -/
  sourceEpoch : Option String := none
  /-- repl_applied_lsn: contiguously applied position. -/
  appliedLsn : Option Nat := none
  /-- repl_source_lsn: the master's position as the follower last saw it. -/
  sourceLsn : Option Nat := none
  /-- repl_source_lsn_observed_at: when that was seen (node clock, seconds). -/
  sourceObservedAt : Option Nat := none
  /-- repl_last_progress_at: when the applied position last moved. -/
  lastProgressAt : Option Nat := none
  /-- STAT time: the node's clock at reply time (same reply ⇒ no skew). -/
  nodeTime : Option Nat := none
  /-- repl_follow_last_reason. -/
  lastReason : Option String := none
  deriving Repr, BEq

/-- The partition master's own `stats` reply, typed. -/
structure MasterReading where
  complete : Bool := false
  /-- rocksdb_source_epoch: the master's current history. -/
  epoch : Option String := none
  /-- rocksdb_latest_sequence_number: the master's head THIS pass. -/
  head : Option Nat := none
  deriving Repr, BEq

/-- Bounds. Configured from the environment by Main (FLARE_FOLLOW_FRESH_SECS,
    FLARE_FOLLOW_READ_LAG, FLARE_FOLLOW_PROMOTE_LAG). -/
structure Bounds where
  /-- Max age, in the node's own seconds, of the follower's last observation
      of the master's position. The follower polls every
      repl-follow-poll-interval-usec (default 200 ms), so 5 s means "the
      stream has been quiet for 25 polls". -/
  freshSecs : Nat := 5
  /-- Max (master head − applied position) for serving reads. -/
  readLag : Nat := 1000
  /-- Max lag for a planned promotion and for a copy that must survive a
      deletion. -/
  promoteLag : Nat := 100
  deriving Repr, BEq

inductive Purpose where
  | read
  | promote
  | survive
  deriving Repr, BEq, DecidableEq

def Purpose.name : Purpose → String
  | .read => "read"
  | .promote => "promotion"
  | .survive => "survival"

inductive Verdict where
  /-- The node is not a WAL-mode follower: this module has no say. -/
  | notInMode (why : String)
  | eligible (why : String)
  | ineligible (why : String)
  /-- Nothing can be concluded from what was readable. -/
  | unknown (why : String)
  deriving Repr, BEq

def Verdict.isEligible : Verdict → Bool
  | .eligible _ => true
  | _ => false

def Verdict.isUnknown : Verdict → Bool
  | .unknown _ => true
  | _ => false

def Verdict.reason : Verdict → String
  | .notInMode w | .eligible w | .ineligible w | .unknown w => w

def Verdict.label : Verdict → String
  | .notInMode _ => "not-in-mode"
  | .eligible _ => "eligible"
  | .ineligible _ => "ineligible"
  | .unknown _ => "unknown"

/-- The mode as THIS reading tells it. `none` = unreadable. A complete reply
    without the key is a flared without a follower: mode off. -/
def Reading.mode (r : Reading) : Option Bool :=
  if r.complete then some (r.enabled.getD false) else none

def lagBound (p : Purpose) (b : Bounds) : Nat :=
  match p with
  | .read => b.readLag
  | .promote | .survive => b.promoteLag

private def reasonNote (r : Reading) : String :=
  match r.lastReason with
  | some why => if why.isEmpty then "" else s!" (last reason: {why})"
  | none => ""

/-- The eligibility judgement for one purpose. Read top to bottom: mode →
    stream state → same history as the master → fresh observation → lag. -/
def judge (p : Purpose) (b : Bounds) (r : Reading) (m : MasterReading) : Verdict :=
  match r.mode with
  | none => .unknown "the node's stats could not be read (no complete reply)"
  | some false => .notInMode "continuous replication is off for this node"
  | some true =>
    match r.state with
    | none => .unknown "repl_follow_state is missing from a complete reply"
    | some st =>
      if st != "following" then
        .ineligible s!"follower state is {st}, not following{reasonNote r}"
      else
        match m.epoch, r.sourceEpoch with
        | none, _ =>
          .unknown (if m.complete then "the master reports no source epoch"
                    else "the master's stats could not be read, so the current history is unknown")
        | _, none => .unknown "the follower reports no source epoch"
        | some me, some se =>
          if me != se then
            .ineligible s!"following epoch {se} while the master's history is {me}: another history"
          else
            match r.nodeTime, r.sourceObservedAt with
            | some now, some seen =>
              let age := now - seen
              if seen > now then
                .unknown "the source observation is in the future of the node clock"
              else if age > b.freshSecs then
                .ineligible s!"the master's position was last observed {age}s ago (bound {b.freshSecs}s): stale"
              else
                match m.head, r.appliedLsn with
                | some head, some applied =>
                  if applied > head then
                    .ineligible s!"applied position {applied} is ahead of the master's head {head}: another sequence space"
                  else
                    let lag := head - applied
                    let bound := lagBound p b
                    if lag > bound then
                      .ineligible s!"lag {lag} (head {head}, applied {applied}) exceeds the {p.name} bound {bound}"
                    else
                      .eligible s!"following epoch {me}; position observed {age}s ago; lag {lag} ≤ {bound} ({p.name})"
                | none, _ => .unknown "the master's head is unreadable"
                | _, none => .unknown "the follower's applied position is unreadable"
            | _, _ => .unknown "the follower's observation time is unreadable"

/-- A follower whose copy is KNOWN not to be a usable copy of the master's
    current history. This is deliberately narrower than "not eligible": a
    disconnected or stale follower is unproven, not unfit. -/
def unfitReason (r : Reading) (masterEpoch : Option String) : Option String :=
  match r.state with
  | some "needs_rebuild" => some s!"the follower declared needs_rebuild{reasonNote r}"
  | some "initial_sync" => some "the initial copy is not complete"
  | some "idle" => some "the follower is idle: not following anyone"
  | _ =>
    match masterEpoch, r.sourceEpoch with
    | some me, some se => if me != se then some s!"epoch {se} differs from the master's {me}" else none
    | _, _ => none

/-- Which nodes were seen in WAL mode (`true`) or explicitly not (`false`).
    Unreadable readings leave the memory unchanged. -/
abbrev ModeMemory := List (String × Bool)

def remember (mem : ModeMemory) (key : String) (mode : Option Bool) : ModeMemory :=
  match mode with
  | none => mem
  | some b => (key, b) :: mem.filter (·.1 != key)

def knownInMode (mem : ModeMemory) (key : String) : Bool :=
  mem.lookup key == some true

/-- Probe policy: a node in WAL mode is probed every tick; a node known to
    be out of the mode is re-probed every `interval` ticks (to notice a
    configuration change); a never-read node is probed. -/
def shouldProbe (mem : ModeMemory) (key : String) (tick interval : Nat) : Bool :=
  match mem.lookup key with
  | some true => true
  | some false => interval == 0 || tick % interval == 0
  | none => true

/-- The lists the FSM and the commit path consume. -/
structure Classified where
  /-- WAL-mode followers proven current for promotion, best first (highest
      applied position first). -/
  ranked : List String := []
  /-- WAL-mode followers (or nodes remembered in the mode) NOT proven: no
      planned promotion, last resort for failover. -/
  unproven : List String := []
  /-- WAL-mode followers known to hold an unusable copy: no promotion at all. -/
  unfit : List String := []
  /-- WAL-mode followers (or remembered) not eligible to serve reads:
      balance 0 at commit. -/
  readWithheld : List String := []
  /-- Followers that DECLARED `needs_rebuild` this pass, with flared's
      reason. The only follower state that hands a node to the rebuild path
      (design §5.4); Main turns each into a repair-ledger request. -/
  needsRebuild : List (String × String) := []
  deriving Repr, BEq

/-- What one node was judged this pass (for change-only logging). -/
structure Judged where
  key : String
  read : Verdict
  promote : Verdict
  unfit : Option String := none
  deriving Repr, BEq

def Judged.summary (j : Judged) : String :=
  match j.unfit with
  | some why => s!"UNFIT ({why}); reads {j.read.label}"
  | none => s!"reads {j.read.label}: {j.read.reason}; promotion {j.promote.label}: {j.promote.reason}"

private def insertByApplied (k : String) (applied : Nat) (acc : List (String × Nat))
    : List (String × Nat) :=
  match acc with
  | [] => [(k, applied)]
  | (k', a') :: rest =>
    if applied ≥ a' then (k, applied) :: (k', a') :: rest
    else (k', a') :: insertByApplied k applied rest

/-- Fold accumulator for `classify`: the ranked list carries the applied
    position until the end so insertion keeps "highest applied first". -/
private structure Acc where
  rankedApplied : List (String × Nat) := []
  unproven : List String := []
  unfit : List String := []
  readWithheld : List String := []
  needsRebuild : List (String × String) := []
  mem : ModeMemory := []
  judged : List Judged := []

private def Acc.unknownFor (a : Acc) (key why : String) : Acc :=
  { a with unproven := a.unproven ++ [key], readWithheld := a.readWithheld ++ [key],
           judged := a.judged ++ [{ key, read := .unknown why, promote := .unknown why }] }

/-- Classify one pass. `nodes` are the (key, partition, reading-if-probed)
    of every non-Down Slave; `masters` the master readings by partition. -/
def classify (b : Bounds) (mem : ModeMemory)
    (nodes : List (String × Int × Option Reading))
    (masters : List (Int × MasterReading))
    : Classified × ModeMemory × List Judged :=
  let acc := nodes.foldl (init := ({ mem } : Acc)) fun a (key, part, r?) =>
    let m : MasterReading := (masters.lookup part).getD {}
    match r? with
    | none =>
      -- Only a previously observed non-WAL node may retain legacy policy.
      -- Never-observed nodes must not regain reads on operator restart.
      if a.mem.lookup key == some false then a
      else a.unknownFor key "not probed this pass"
    | some r =>
      let wasInMode := knownInMode a.mem key
      let a := { a with mem := remember a.mem key r.mode }
      match r.mode with
      | none =>
        if wasInMode || a.mem.lookup key != some false then
          a.unknownFor key "stats unreadable (no complete reply)"
        else a
      | some false => a
      | some true =>
        let rv := judge .read b r m
        let pv := judge .promote b r m
        let unfit := unfitReason r m.epoch
        let a := if rv.isEligible then a else { a with readWithheld := a.readWithheld ++ [key] }
        let a := if r.state == some "needs_rebuild"
          then { a with needsRebuild := a.needsRebuild ++ [(key, (r.lastReason.getD "").trim)] } else a
        let a :=
          match unfit with
          | some _ => { a with unfit := a.unfit ++ [key] }
          | none =>
            if pv.isEligible then
              { a with rankedApplied := insertByApplied key (r.appliedLsn.getD 0) a.rankedApplied }
            else { a with unproven := a.unproven ++ [key] }
        { a with judged := a.judged ++ [{ key, read := rv, promote := pv, unfit }] }
  ({ ranked := acc.rankedApplied.map Prod.fst, unproven := acc.unproven,
     unfit := acc.unfit, readWithheld := acc.readWithheld, needsRebuild := acc.needsRebuild },
   acc.mem, acc.judged)

/-- Per-tick tracker kept by Main between passes. -/
structure Tracker where
  mem : ModeMemory := []
  tick : Nat := 0
  classified : Classified := {}
  /-- Last logged summary per node, to log only changes. -/
  lastSummary : List (String × String) := []
  deriving Repr

/-- Which judgements changed since the last pass (to log), and the updated
    summaries. -/
def changedSummaries (last : List (String × String)) (judged : List Judged)
    : List (String × String) × List (String × String) :=
  let now := judged.map fun j => (j.key, j.summary)
  let changed := now.filter fun (k, s) => last.lookup k != some s
  (changed, now)

end FlareOperator.FollowEvidence
