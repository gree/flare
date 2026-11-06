/-
  History continuation across an ordered handover
  (docs/design-handover-history-continuation.md, reviewer-approved 6th
  revision; Issue flare-promotion-forces-rebuild, part A3).

  At the barrier H the old master has applied V1 and writes nothing; its
  last sequence is L. A remaining replica keeps its copy and continues by
  WAL from the new master (instead of a full rebuild) only when, read
  fresh and bound to the same pod / process / copy:

    * its WAL follow cursor equals L (follow on, state `following`, not
      needs_rebuild), with the same source epoch and master_id as the old
      master — everything up to L applied contiguously
      (design-continuous-wal-replication §3.4);
    * nothing is in flight from the old master to it (queue, retry and held
      forwards are counted until done, within one old-master process);
    * it is Active, Ready, R3 eligible, not partial, no quarantine, no
      replica repair pending, and the same process and copy as at the start;
    * L read before and after the replica readings is the same.

  This module is the pure decision; Main reads the stats and sends the
  prepare / release requests.
-/
namespace FlareOperator.HistoryContinuation

/-- The old master at the barrier. `none` = not readable now. -/
structure SourceObs where
  latestSeq : Option Nat := none
  epoch : Option String := none
  masterId : Option String := none
  boot : Option Nat := none
  deriving Repr, BEq

/-- One remaining replica, from one fresh complete stats read. -/
structure ReplicaObs where
  key : String
  /-- the pod, process and copy when the handover started, and now -/
  bindingAtStart : Option String := none
  bindingNow : Option String := none
  cursor : Option Nat := none
  followState : Option String := none
  needsRebuild : Bool := false
  epoch : Option String := none
  masterId : Option String := none
  /-- the old master's proxy_write_in_flight to this replica -/
  inFlightFromOld : Option Nat := none
  activeSlave : Bool := false
  ready : Bool := false
  r3Eligible : Bool := false
  partialCopy : Bool := false
  quarantined : Bool := false
  repairPending : Bool := false
  deriving Repr, BEq

/-- Why a replica is not continued (`none` = it may be prepared). Every
    unreadable value excludes it: it then rebuilds as before. -/
def excluded (src : SourceObs) (lBefore lAfter : Option Nat) (r : ReplicaObs) : Option String :=
  match lBefore, lAfter, src.latestSeq with
  | some lb, some la, some l =>
    if lb != la || la != l then some s!"the old master's last sequence moved during the barrier ({lb} → {la})"
    else if !r.activeSlave then some "not an Active slave"
    else if !r.ready then some "the pod is not Ready"
    else if !r.r3Eligible then some "not R3 eligible"
    else if r.partialCopy then some "the copy is partial"
    else if r.quarantined then some "a quarantined copy is kept"
    else if r.repairPending then some "a replica repair is pending"
    else if r.bindingAtStart.isNone || r.bindingNow.isNone || r.bindingAtStart != r.bindingNow then
      some "another pod, process or copy than at the start (or unreadable)"
    -- at the barrier the follower idles (the partition has only the
    -- Master/Down placeholder, nothing to poll): `idle` with its cursor at L
    -- is the evidence; needs_rebuild or no follower is not (42124876046)
    else if (r.followState != some "following" && r.followState != some "idle") || r.needsRebuild then
      some s!"WAL follow is not following ({r.followState.getD "unreadable"}{if r.needsRebuild then ", needs_rebuild" else ""})"
    else if src.epoch.isNone || r.epoch != src.epoch then some "another source epoch than the old master (or unreadable)"
    else if src.masterId.isNone || r.masterId != src.masterId then some "another master_id than the old master (or unreadable)"
    else if r.inFlightFromOld != some 0 then
      some s!"forwards from the old master are still in flight ({(r.inFlightFromOld.map toString).getD "unreadable"})"
    else match r.cursor with
      | none => some "the follow cursor is unreadable"
      | some c => if c != l then some s!"the follow cursor {c} is not the old master's last sequence {l}" else none
  | _, _, _ => some "the old master's last sequence is unreadable"

/-- The replicas to prepare (map order) and the excluded ones with why. -/
def partition (src : SourceObs) (lBefore lAfter : Option Nat) (rs : List ReplicaObs) :
    List String × List (String × String) :=
  rs.foldl (fun (ok, no) r =>
    match excluded src lBefore lAfter r with
    | none => (ok ++ [r.key], no)
    | some why => (ok, no ++ [(r.key, why)])) ([], [])

/-- The handover id that binds the prepare, the commit and the release:
    partition, attempt and the demote time — unique per handover. -/
def handoverId (partition attempt demotedMs : Nat) : String :=
  s!"p{partition}-a{attempt}-{demotedMs}"

/-- The WAL pin of the new master may be released: every prepared replica
    reports a cursor past S. An unreadable cursor keeps it (the deadline
    and the free-space floor release it anyway). -/
def releaseReady (s : Nat) (prepared : List String) (cursors : List (String × Option Nat)) : Bool :=
  prepared.all fun k => match cursors.lookup k with
    | some (some c) => c > s
    | _ => false

end FlareOperator.HistoryContinuation
