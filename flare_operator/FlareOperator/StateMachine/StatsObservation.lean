/-
  StateMachine/StatsObservation.lean — SAF-04 / SAF-06, SC-05 / EV-05.

  "Delete only a revalidated target when independent current evidence
  supports the surviving copy."

  The empty-master self-heal deletes a master's pod when it holds 0 keys and
  a data-bearing slave can take over. The danger is entirely in the word
  "0": the old reader turned a `stats` reply with no readable `curr_items`
  line — a truncated response, a connection that returned partial data, a
  future flared that renamed the field — into the number 0, which reads as
  "empty master, delete it". A missing observation is not zero.

  This module types that away and states the delete precondition as one pure
  function over typed observations:

  * `Items` is `unknown` OR `known n`. Parsing a `stats` reply yields
    `unknown` unless a well-formed `curr_items` line is present.
  * `emptyMasterVerdict` says DELETE only when the master is `known 0`, the
    successor slave is `known` and greater than 0, and both readings are
    from THIS observation. `unknown` on either side is `Skip`, never delete.

  SAF-06 (arbitration) is enforced at the call site with `revalidate`: the
  cluster the delete would act on is re-read immediately before the delete,
  and the delete proceeds only if the SAME target is still an empty master
  and a data-bearing Active successor still exists in its partition — so a
  resync that demoted the successor, a re-registration, or a leadership loss
  between the streak decision and the delete aborts it. That check is stated
  here as `successorStillValid` over the live node map.

  Pure; Main.lean reads the stats and the map and calls these. The unit
  checks in UnitTests.lean pin the parse and the verdict.
-/
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.StatsObservation

open FlareOperator.K8s

/-- A count that may be unknown. `unknown` is NOT zero and never satisfies a
    delete precondition. -/
inductive Items where
  | unknown
  | known (n : Nat)
  deriving Repr, BEq, DecidableEq

def Items.toString : Items → String
  | .unknown => "unknown"
  | .known n => s!"{n}"

instance : ToString Items := ⟨Items.toString⟩

/-- Parse one `STAT <key> <value>` numeric field out of a flared `stats`
    reply. `unknown` when the reply has no well-formed line for `key` —
    absent, non-numeric, or truncated before it. A blank reply (a dropped or
    reset connection) is therefore `unknown`, not `known 0`. -/
def parseStat (out : String) (key : String) : Items :=
  let found := (out.splitOn "\n").findSome? fun line =>
    match (line.trim.replace "\r" "" |>.splitOn " ").filter (· != "") with
    | ["STAT", k, v] => if k == key then some v.trim else none
    | _ => none
  match found with
  | none => .unknown
  | some v => match v.toNat? with
    | some n => .known n
    | none => .unknown

def parseCurrItems (out : String) : Items := parseStat out "curr_items"

/-- What to do about a (master, slave) item comparison for the empty-master
    self-heal. -/
inductive EmptyMasterVerdict where
  /-- The master is a confirmed empty while the slave holds data: candidate
      for the drain-based heal (still subject to revalidation at delete). -/
  | act
  /-- Do nothing, with the reason. -/
  | skip (reason : String)
  deriving Repr, BEq

/-- The delete precondition, stated once. DELETE only when the master is
    KNOWN 0 and the slave is KNOWN and nonzero. Any `unknown` is `skip`:
    a stats read that did not clearly say "this master has zero keys" must
    never cause a deletion. -/
def emptyMasterVerdict (master slave : Items) : EmptyMasterVerdict :=
  match master with
  | .unknown => .skip "master item count is unknown (unreadable/truncated stats); not treating as empty"
  | .known m =>
    if m != 0 then .skip s!"master holds {m} keys; not empty"
    else match slave with
      | .unknown => .skip "master reads empty but the slave's item count is unknown; refusing to delete without a confirmed data-bearing successor"
      | .known 0 => .skip "master and slave both read empty; nothing to hand over"
      | .known s => .act

/-- Is `slaveKey` a data-bearing Active successor for `master`'s partition in
    the CURRENT map — the SAF-06 revalidation predicate. `dataBearing` is the
    set of keys whose live stats read a nonzero item count THIS pass. The
    successor must still be a Slave, Active, in the same partition, live, and
    data-bearing; the master must still be the same Active master of that
    partition. -/
def successorStillValid (state : FlareClusterState) (masterKey slaveKey : String)
    (dataBearing : List String) : Bool :=
  match state.nodeMap.lookup masterKey, state.nodeMap.lookup slaveKey with
  | some m, some s =>
    m.role == FlareRole.Master && m.state == FlareState.Active &&
    s.role == FlareRole.Slave && s.state == FlareState.Active &&
    s.partition == m.partition &&
    dataBearing.contains slaveKey
  | _, _ => false

/-- The final gate before deleting an empty master's pod (SAF-06). Every
    input is a re-check made AFTER the fresh stats reads, so the decision
    rests on the state the delete will act on, not on the streak's snapshot:
    * `verdictNow`   — the empty-master verdict from the FRESH stats;
    * `successorOk`  — successorStillValid on the map read AFTER those stats;
    * `survivorFollowOk` — SAF-10c: if the successor is a continuous-
                       replication follower, FollowEvidence judged it
                       eligible to SURVIVE (following the master's current
                       history, fresh, within the promotion lag bound) from
                       the same fresh stats; `true` also when it is not in
                       that mode. Unknown is `false`;
    * `uidStable`    — the target pod's UID was the same before and after the
                       stats read and matches the pod about to be deleted (the
                       pod was not replaced under the name);
    * `holdsLease`   — this operator still holds the leader lease.
    Refuses with the first failing reason. -/
def deleteGate (verdictNow : EmptyMasterVerdict) (successorOk survivorFollowOk uidStable holdsLease : Bool)
    : Except String Unit :=
  match verdictNow with
  | .skip reason => .error s!"target no longer reads as an empty master with a data-bearing successor: {reason}"
  | .act =>
    if !holdsLease then .error "this operator no longer holds the leader lease; not deleting"
    else if !uidStable then .error "the target pod's UID changed across the observation (pod replaced); not deleting"
    else if !successorOk then .error "the successor is no longer a data-bearing Active slave of the same partition in the live map; not deleting"
    else if !survivorFollowOk then .error "the successor is a continuous-replication follower whose currency could not be proven (following the master's current history, fresh observation, within the promotion lag bound); not deleting"
    else .ok ()

end FlareOperator.StatsObservation
