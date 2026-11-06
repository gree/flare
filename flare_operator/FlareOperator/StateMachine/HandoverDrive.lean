/-
  StateMachine/HandoverDrive.lean — the pure helpers Main's handover drive
  uses for the history continuation (docs/design-handover-history-
  continuation.md addenda 2–3): the lease bound and the checks around the
  `status.handovers` compare-and-swap that comes BEFORE every send, the
  binding / commit readings of the prepared replicas, the flared command
  lines and reply parsing. Handover and HistoryContinuation stay as they are;
  everything here is a function of its arguments.
-/
import FlareOperator.StateMachine.Handover

namespace FlareOperator.HandoverDrive

open FlareOperator.Handover

-- ═══════════════════════════════════════════════════════════════════════
-- the CAS before a send (addendum 3 §1)
-- ═══════════════════════════════════════════════════════════════════════

/-- The API call's bound (kubectl, 4 s) plus 1 s: the lease must have at
    least this much left before the CAS starts. -/
def casMarginSec : Nat := 5

/-- The CAS' own time bound: `min(4 s, remaining − 1 s)`; `none` = not enough
    lease left, nothing is written (and nothing sent). -/
def casBound (remaining : Int) : Option Nat :=
  if remaining < (casMarginSec : Int) then none
  else some (min (4 : Int) (remaining - 1)).toNat

/-- After the CAS answered: still the holder, not expired, the same leader
    epoch (the lease's transitions) and time left. Anything else = no send. -/
def leaseKept (identity holder : String) (expired : Bool) (epoch1 epoch2 : Nat) (remaining2 : Int) : Bool :=
  holder == identity && !expired && epoch1 == epoch2 && remaining2 > 0

/-- An entry whose phase (or whose continuation fields) the leader must write
    with the CAS before it sends. With the continuation off nothing is
    guarded: the plain write of the one-map handover is unchanged. -/
def guarded (on : Bool) (x : Entry) : Bool :=
  on && (x.phase == .preparing || x.phase == .committingReplicas || x.phase == .rollingBack
    || !x.hid.isEmpty || x.contSeq.isSome)

/-- The phases only go one way (`preparing → committingReplicas → promoting →
    done`; `rollingBack → aborted`). A stored phase ahead of the one being
    written is never written back (a CAS whose answer was lost, re-tried). -/
def canAdvance (stored next : Phase) : Bool :=
  stored == next ||
  match stored with
  | .requested | .demoting | .draining => true
  | .preparing => next == .committingReplicas || next == .promoting || next == .rollingBack
  | .committingReplicas => next == .promoting || next == .rollingBack || next == .aborted
  | .promoting => next == .done || next == .aborted
  | .rollingBack => next == .aborted
  | .done | .aborted => false

/-- A stored entry may be followed by ANOTHER handover of its partition
    (another attempt, or another old master pod) only once it is over:
    done, or aborted. The next one is then another old master pod, or the
    next attempt (attempt + 1) of the same pod after an abort. Anything else
    — a lower or skipped attempt, or a stored handover still running — is a
    stale writer (review of 0cf92ba: an older leader's delayed CAS read the
    new attempt and overwrote the whole ledger with the old one). -/
def startsAfter (s x : Entry) : Bool :=
  (s.phase == .done || s.phase == .aborted)
    && (if s.oldUid != x.oldUid then true
        else s.phase == .aborted && x.attempt == s.attempt + 1)

/-- May `x` (written by the leader of `epoch`) replace what is stored? A
    stored entry written by a newer leader refuses, whichever handover it
    is. The same handover (old pod and attempt) may only move its phase
    forward; another one only start after the stored one is over
    (`startsAfter`). Nothing stored for the partition: allowed. -/
def casAllowed (stored : Ledger) (x : Entry) (epoch : Nat) : Except String Unit :=
  match Handover.find? stored x.partition with
  | none => .ok ()
  | some s =>
    if s.leaderEpoch > epoch then
      .error s!"the stored entry was written by a newer leader (epoch {s.leaderEpoch} > {epoch})"
    else if s.oldUid != x.oldUid || s.attempt != x.attempt then
      if startsAfter s x then .ok ()
      else .error s!"the stored entry is another handover (old pod {s.oldUid}, attempt {s.attempt}, {s.phase}) that {x.oldUid}/attempt {x.attempt} may not follow"
    else if !canAdvance s.phase x.phase then
      .error s!"the stored phase {s.phase} is ahead of {x.phase}"
    else .ok ()

-- ═══════════════════════════════════════════════════════════════════════
-- the prepared replicas' readings (addendum 3 §2)
-- ═══════════════════════════════════════════════════════════════════════

/-- One prepared replica read fresh this tick (`none` = not readable). -/
structure Reading where
  binding : Option String := none
  /-- `history_pending` ("-" = none) -/
  pending : Option String := none
  epoch : Option String := none
  masterId : Option String := none
  version : Option Nat := none
  deriving Repr, BEq

/-- The `from` epoch of a pending record of `hid` (`v1 <role> <hid> <partition>
    <successor> <from> <to> …`); `none` = no pending, or another handover's. -/
def pendingFrom (pending hid : String) : Option String :=
  match (pending.splitOn " ").filter (· != "") with
  | "v1" :: _ :: h :: _ :: _ :: fromEpoch :: _ => if h == hid then some fromEpoch else none
  | _ => none

/-- Counted as committed only when ALL hold: the binding is the recorded one,
    no pending, epoch = toEpoch, master_id = the entry's, and the map version
    is at least V2. -/
def Reading.committed (e : Entry) (recorded : String) (v2 : Nat) (r : Reading) : Bool :=
  r.binding == some recorded && r.pending == some "-" && r.epoch == some e.toEpoch
    && r.masterId == some e.contMasterId && (match r.version with | some v => v >= v2 | none => false)

/-- Read fresh, same binding, and still holding its pending of this handover
    with the epoch it had (the commit did not happen). -/
def Reading.stillPending (e : Entry) (recorded : String) (r : Reading) : Bool :=
  r.binding == some recorded &&
    match r.pending with
    | some p => (pendingFrom p e.hid).isSome && r.epoch == pendingFrom p e.hid
    | none => false

/-- The prepared replicas confirmed committed (needs V2 recorded). -/
def committedKeys (e : Entry) (rs : List (String × Reading)) : List String :=
  match e.v2 with
  | none => []
  | some v2 => e.prepared.filterMap fun (k, b) =>
      match rs.lookup k with
      | some r => if r.committed e b v2 then some k else none
      | none => none

/-- EVERY prepared replica was read fresh, bound the same, and still pending
    (an unreadable replica is never zero). -/
def zeroProven (e : Entry) (rs : List (String × Reading)) : Bool :=
  !e.prepared.isEmpty && e.prepared.all fun (k, b) =>
    match rs.lookup k with
    | some r => r.stillPending e b
    | none => false

/-- The pod UID and boot id of two bindings (`uid|boot|copy`) are the same:
    the same process, so its pending can be discarded. -/
def sameProcess (recorded now : String) : Bool :=
  match recorded.splitOn "|", now.splitOn "|" with
  | [u1, b1, _], [u2, b2, _] => u1 == u2 && b1 == b2
  | _, _ => false

/-- Before V2 goes out: a prepared replica whose binding now differs (another
    pod, process or copy) or is unreadable is dropped from `prepared` (and
    `committed`); with a same-process one named for a `history discard`.
    Nothing left = no continuation: promote as before (the handover id is
    kept only when V2 already went to someone). -/
def dropChanged (e : Entry) (now : List (String × Option String)) : Entry × List (String × Bool) :=
  let cur := fun k => (now.lookup k).getD none
  let bad := e.prepared.filter fun (k, b) => cur k != some b
  if bad.isEmpty then (e, [])
  else
    let good := e.prepared.filter fun (k, b) => cur k == some b
    let dropped := bad.map fun (k, b) => (k, (cur k).any (sameProcess b))
    let e' := { e with prepared := good, committed := e.committed.filter fun k => good.any (·.1 == k) }
    if good.isEmpty then
      ({ e' with phase := .promoting, hid := if e.v2.isNone then "" else e.hid, fullSent := false,
                 reason := "no prepared replica kept its pod, process and copy: they rebuild" }, dropped)
    else (e', dropped)

/-- Drop `bad` replicas whose arm failed from `prepared` / `committed`
    (nothing else is recorded). No prepared replica left = no continuation:
    promoting with the handover id kept (V2 is already out) and `fullSent`
    false, so the promoting step arms and sends to the successor. -/
def dropPrepared (e : Entry) (bad : List String) : Entry :=
  let good := e.prepared.filter fun (k, _) => !bad.contains k
  let e' := { e with prepared := good, committed := e.committed.filter fun k => good.any (·.1 == k) }
  if good.isEmpty then
    { e' with phase := .promoting, fullSent := false,
              reason := "no prepared replica could be armed for V2: they rebuild" }
  else e'

-- ═══════════════════════════════════════════════════════════════════════
-- the V2 publication gate (addendum 11, ordering hole)
-- ═══════════════════════════════════════════════════════════════════════

/-- While an entry is in `committingReplicas` (V2 recorded or about to be,
    `fullSent` false) the live map holds V2 and only the prepared replicas,
    armed for it, may be sent it. -/
def holdsV2 (e : Entry) : Bool := e.phase == .committingReplicas

/-- What a publish of the live map may do: everything (`all`), only the
    listed node keys (`only`), or nothing (`skip`, kept pending). -/
inductive Gate
  | all
  | only (keys : List String)
  | skip
  deriving Repr, BEq

/-- The gate decision for a publish. `keys` = the targets it asks for
    (`none` = the whole fleet). Without a held entry a publish is as before.
    With one: a fleet-wide publish is skipped; a targeted one keeps only the
    prepared replicas of the held entries (never the successor or any other
    pod). `known` false (the ledger was never read) fails closed. -/
def publishGate (known : Bool) (ents : List Entry) (keys : Option (List String)) : Gate :=
  let held := ents.filter holdsV2
  if known && held.isEmpty then
    match keys with
    | none => .all
    | some ks => .only ks
  else
    match keys with
    | none => .skip
    | some ks =>
      if !known then .skip
      else .only (ks.filter fun k => held.any fun e => e.prepared.any (·.1 == k))

-- ═══════════════════════════════════════════════════════════════════════
-- flared commands and replies
-- ═══════════════════════════════════════════════════════════════════════

/-- A value that may be put on a flared command line as it is. -/
def safeArg (s : String) : Bool :=
  !s.isEmpty && s.all fun c => c.isAlphanum || "-_.:/+=@,".contains c

def promotePrepareCmd (hid : String) (partition : Nat) (successor : String) (deadlineMs : Nat) : String :=
  s!"history promote_prepare {hid} {partition} {successor} {deadlineMs}"

def prepareCmd (hid : String) (partition : Nat) (successor fromEpoch toEpoch : String) (seq : Nat)
    (masterId : String) (deadlineMs : Nat) (incarnation : String) : String :=
  s!"history prepare {hid} {partition} {successor} {fromEpoch} {toEpoch} {seq} {masterId} {deadlineMs} {incarnation}"

def discardCmd (hid : String) : String := s!"history discard {hid}"

/-- Addendum 11: binds the pending record to the exact V2 map before it is
    sent (replicas commit only on that version). -/
def armCmd (hid : String) (version : Nat) : String := s!"history arm {hid} {version}"

/-- An arm that took (`armed`) or had already (`already`); anything else
    (refused / failed / no reply) did not. -/
def armOk (r : Option String) : Bool := r == some "armed" || r == some "already"

def releaseCmd (hid : String) : String := s!"wal_pin release {hid}"

/-- The value of `STAT key value` in a reply (the rest of the line). -/
def statLine (out key : String) : Option String :=
  (out.splitOn "\n").findSome? fun l =>
    let t := (l.replace "\r" "").trim
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

/-- `prepared` / `already` (or what flared refused with); `none` = no such
    line (an incomplete or foreign reply). -/
def historyResult (out : String) : Option String := statLine out "history_result"

def resultOk (r : Option String) : Bool := r == some "prepared" || r == some "already"

/-- The successor's reply to `promote_prepare`: E', S and master_id; only a
    `prepared` / `already` reply with all three is taken. -/
def parsePromote (out : String) : Option (String × Nat × String) :=
  if !resultOk (historyResult out) then none
  else match statLine out "history_to_epoch", (statLine out "history_seq").bind (·.toNat?), statLine out "history_master_id" with
    | some e, some s, some m => if e.isEmpty || m.isEmpty then none else some (e, s, m)
    | _, _, _ => none

/-- The pending's deadline on flared's wall clock: the handover's remaining
    time (operator monotonic clock) from now. -/
def wallDeadline (wallNow nowMono deadlineMono : Nat) : Nat :=
  wallNow + (deadlineMono - nowMono)

-- ═══════════════════════════════════════════════════════════════════════
-- the WAL pin release after `done`
-- ═══════════════════════════════════════════════════════════════════════

/-- A finished continuation whose new master still holds the WAL pin: kept in
    memory until every prepared replica's cursor passed S (then `wal_pin
    release <hid>`), or until `untilMs` (flared's own deadline and floor
    release it anyway). -/
structure ReleaseDue where
  hid : String
  master : String
  seq : Nat
  prepared : List String
  untilMs : Nat
  deriving Repr, BEq

/-- How long a prepared (pending) history outlives the handover's own
    deadline before flared drops it by itself. The pending deadline is only
    the safety net for a handover that was abandoned; it must not expire
    while the V2 the record is armed for is still on its way (42128038045:
    the replica's record was dropped 0.8 s before V2 arrived, the
    successor's before its arm, both by the handover's 10 s budget). A
    commit after the operator gave up is still safe: it happens only on the
    exact armed map. -/
def pendingGraceMs : Nat := 30000

end FlareOperator.HandoverDrive
