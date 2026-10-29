/-
  StateMachine/Handover.lean — the ordered handover of a planned master
  switch (flare-lossless-handover; design:
  flare-ci-inputs/decisions/HANDOVER-DESIGN-rc68.md).

  A Terminating master used to be switched in ONE map: old master → Proxy,
  successor → Master, sent to every pod in parallel. Nothing ordered the
  two pods' application of it, so a write could be applied by the old master
  after the successor already served as master (two masters, a version
  collision), or the old master could stop with forwards to the successor
  still queued (acknowledged writes missing on the new master).

  Here the switch is three maps, each confirmed before the next:

    requested ── V1: old master Master/Down (the partition keeps no master,
         │       writes wait for one — flared W), successor stays Slave
         ▼
    demoting ── the old master reports node_map_version ≥ V1
         ▼
    draining ── the old master has nothing in flight to the successor and
         │       dropped / failed to it nothing since the start
         ▼
    promoting ── V2: successor Master/Active, old master Proxy; every pod
         │       that can take a write reports ≥ V2 and the successor reports
         ▼       own_role=master
    done

  Abort (only before promoting): the bound passed, the successor stopped
  being eligible, or the old master restarted (its counters are not
  comparable). V1′ puts the old master back as Master/Active; the writes
  waiting for a master go to it.

  Everything here is pure; Main reads the observations and sends the maps.
-/
import Lean.Data.Json
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Handover

open FlareOperator.K8s

inductive Phase where
  | requested
  | demoting
  | draining
  | promoting
  | done
  | aborted
  deriving Repr, BEq, Inhabited

def Phase.toString : Phase → String
  | .requested => "requested"
  | .demoting => "demoting"
  | .draining => "draining"
  | .promoting => "promoting"
  | .done => "done"
  | .aborted => "aborted"

instance : ToString Phase := ⟨Phase.toString⟩

def Phase.fromString? : String → Option Phase
  | "requested" => some .requested
  | "demoting" => some .demoting
  | "draining" => some .draining
  | "promoting" => some .promoting
  | "done" => some .done
  | "aborted" => some .aborted
  | _ => none

/-- A phase in which the old master is master/down in the maps sent. -/
def Phase.oldIsDown : Phase → Bool
  | .demoting | .draining => true
  | _ => false

/-- One handover, per partition. -/
structure Entry where
  partition : Nat
  oldMaster : String
  successor : String
  /-- the old master's pod (UID) when the handover started: a pod replaced
      under the same name is another process, never rolled back to -/
  oldUid : String := ""
  /-- the old master's pod was gone or replaced mid-way: no rollback map (it
      would make the new, possibly empty, process the master) -/
  noRollback : Bool := false
  /-- the promotion follows a drain proven clean (old master at ≥ V1, the
      same process, nothing in flight to the successor, no new drop or
      failure). Only such a promotion may use the lossless exception of the
      promotion gate (PromotionEvidence.handoverCommitAllows); a promotion
      after the old master's pod went away was not drained and takes the
      normal rules. -/
  drainProven : Bool := false
  /-- 1 for the first handover of this old master's pod, +1 for each retry
      after an abort (Config.maxAttempts) -/
  attempt : Nat := 1
  phase : Phase := .requested
  /-- node map versions of the demote / promote / rollback maps once sent -/
  v1 : Option Nat := none
  v2 : Option Nat := none
  vBack : Option Nat := none
  /-- the old master's process (reconstruction_boot_id) when the counters
      below were read: another process = counters not comparable -/
  oldBoot : Option Nat := none
  /-- the old master's proxy_write_dropped / failed to the successor when the
      handover started (the drain must not add to them) -/
  dropped0 : Option Nat := none
  failed0 : Option Nat := none
  /-- the successor's pod UID, process (boot id) and copy id when it was read
      R3 eligible and the demote started: the drain proves currency only for
      this process and copy, so another one aborts the handover and the
      commit accepts the handover exception only for it (review of the
      a8b9793 matrix: SAF-08 / R3 Unknown) -/
  successorBinding : String := ""
  startedMs : Nat := 0
  /-- when the demote started (Th is measured from here) -/
  demotedMs : Nat := 0
  phaseMs : Nat := 0
  reason : String := ""
  deriving Repr, Inhabited, BEq

structure Ledger where
  entries : List Entry := []
  deriving Repr, Inhabited, BEq

structure Config where
  /-- Th: demote → promote must be reached within this (else abort) -/
  handoverMs : Nat := 10000
  /-- how long `requested` may wait for its preconditions -/
  startMs : Nat := 30000
  /-- handovers of one old master pod, the first included: an abort that
      rolled back (the old master serves again) is retried after
      `retryDelayMs` while attempts remain (L7: the one-map drain is not
      the fallback while a lossless handover can still be tried) -/
  maxAttempts : Nat := 3
  retryDelayMs : Nat := 5000
  deriving Repr

/-- What Main observed this pass for one entry. `none` = not readable now;
    an unreadable value never advances a phase. -/
structure Obs where
  nowMs : Nat
  /-- the old master's pod is still the one the handover started with (same
      UID); false once it is gone or replaced under the same name -/
  oldSameProcess : Bool := true
  /-- the successor is still an eligible successor: an Active Slave of the
      partition, its pod Ready and not Terminating, no replica repair pending -/
  successorEligible : Bool
  oldMapVersion : Option Nat := none
  oldBoot : Option Nat := none
  inFlightToSuccessor : Option Nat := none
  droppedToSuccessor : Option Nat := none
  failedToSuccessor : Option Nat := none
  /-- node_map_version reported by every pod that can take a client write
      (including the old master and the successor) -/
  entryVersions : List (String × Option Nat) := []
  successorOwnRole : Option String := none
  /-- the successor's own R3 reading this tick is eligible (or a complete
      pre-R3 reply): required before the demote, never inferred -/
  successorR3 : Bool := true
  /-- the successor's binding (pod UID, boot id, copy id) read this tick;
      none = unreadable -/
  successorBinding : Option String := none
  deriving Repr

/-- What Main does after a step. -/
inductive Action where
  | none
  /-- send the map with this entry's current phase applied (and record the
      version it got with `recordSent`) -/
  | send
  | finish
  deriving Repr, BEq

/-- The counters to the successor have not grown since the start, and the
    process is the same one. Unknown = not proven. -/
def drainClean (e : Entry) (o : Obs) : Bool :=
  match e.oldBoot, o.oldBoot, e.dropped0, o.droppedToSuccessor, e.failed0, o.failedToSuccessor with
  | some b0, some b, some d0, some d, some f0, some f => b0 == b && d <= d0 && f <= f0
  | _, _, _, _, _, _ => false

/-- The slaves of a partition that may succeed `oldMaster` before their own
    precheck (R3 eligible, complete binding) is read: an Active Slave of the
    partition in the map, its pod Ready and not Terminating, no replica
    repair pending. Map order. The handover's per-tick successor check and
    the successor picker share it (review of 92a73e6: the picker ignored the
    repair ledger and kept choosing a slave the check refused). -/
def successorCandidates (s : FlareClusterState) (slaves : List String) (partIdx : Int) (oldMaster : String)
    (readyKeys repairDests : List String) : List String :=
  slaves.filter fun k =>
    k != oldMaster && readyKeys.contains k && !repairDests.contains k
      && (s.lookupNode k).any fun n => n.role == FlareRole.Slave && n.partition == partIdx && n.state == FlareState.Active

/-- The old master's flared reports what the drain proof needs: its process
    (reconstruction_boot_id) and the per-destination forward counters (a
    `proxy_write_failed` line is always present since they exist). A complete
    reply without them is a flared from a release before the handover (rc68
    and older): it can never be handed over losslessly (CI 40846298380: the
    rc56 master's handover asked for them on every attempt). `none` /
    incomplete = not known (false). -/
def oldMasterCanHandOver (reply : Option String) : Bool :=
  match reply with
  | none => false
  | some out =>
    let lines := (out.splitOn "\n").map fun l => (l.replace "\r" "").trim
    lines.contains "END" && lines.any (·.startsWith "STAT reconstruction_boot_id ")
      && lines.any (·.startsWith "STAT proxy_write_failed ")
      && lines.any (·.startsWith "STAT proxy_write_in_flight ")

/-- The old master's reply is complete and has NEITHER of the two forward
    gauges this release always reports (proxy_write_in_flight,
    proxy_write_failed): a flared from an older release. A reply with only
    one of them, or without END, is not classified as older (it is a modern
    reply that is incomplete: fail closed, wait) (review of 7ae666c). -/
def oldMasterPredatesHandover (reply : Option String) : Bool :=
  match reply with
  | none => false
  | some out =>
    let lines := (out.splitOn "\n").map fun l => (l.replace "\r" "").trim
    lines.contains "END" && !lines.any (·.startsWith "STAT proxy_write_failed ")
      && !lines.any (·.startsWith "STAT proxy_write_in_flight ")

/-- The Terminating masters the FSM's one-map drain must leave to the next
    pass. `seenAlive` = the Active masters the handover step saw not
    Terminating this pass; `none` = that step had no pod observation (ledger
    or pods unreadable): then every Terminating Active master is left, fail
    closed (review of 67e27eb: an empty list let the FSM's own later read
    drain a master the handover never saw). -/
def drainDeferred (seenAlive : Option (List String)) (terminating activeMasters : List String) : List String :=
  match seenAlive with
  | some seen => terminating.filter seen.contains
  | none => terminating.filter activeMasters.contains

def allApplied (vs : List (String × Option Nat)) (v : Nat) : Bool :=
  !vs.isEmpty && vs.all fun (_, r) => match r with | some x => x >= v | none => false

/-- The successor read now is another pod, process or copy than the one the
    demote was started for. Unreadable is not a change (it does not advance
    anything either). -/
def successorChanged (e : Entry) (o : Obs) : Bool :=
  match o.successorBinding with
  | some b => !e.successorBinding.isEmpty && b != e.successorBinding
  | none => false

private def toPhase (e : Entry) (p : Phase) (now : Nat) (why : String := "") : Entry :=
  { e with phase := p, phaseMs := now, reason := if why.isEmpty then e.reason else why }

/-- One step of one entry. Pure: the caller sends a map for `.send` and then
    records its version with `recordSent`. -/
def step (cfg : Config) (e : Entry) (o : Obs) : Entry × Action :=
  match e.phase with
  | .requested =>
    if !o.oldSameProcess then
      (toPhase e .aborted o.nowMs "the old master pod went away before the handover started", .finish)
    else
    let ready := o.successorEligible && o.successorR3 && o.successorBinding.isSome && o.oldBoot.isSome
                   && o.droppedToSuccessor.isSome && o.failedToSuccessor.isSome
    if ready then
      ({ toPhase e .demoting o.nowMs with
          demotedMs := o.nowMs, successorBinding := o.successorBinding.getD "",
          oldBoot := o.oldBoot, dropped0 := o.droppedToSuccessor, failed0 := o.failedToSuccessor }, .send)
    else if o.nowMs >= e.startedMs + cfg.startMs then
      -- never demoted: nothing to roll back; the old drain path takes over
      (toPhase e .aborted o.nowMs "the successor did not become eligible (or the old master's counters were unreadable) in time", .finish)
    else (e, .none)
  | .demoting | .draining =>
    let expired := o.nowMs >= e.demotedMs + cfg.handoverMs
    let restarted := match e.oldBoot, o.oldBoot with
      | some b0, some b => b0 != b
      | _, _ => false
    if !o.oldSameProcess then
      -- the old master is gone (or replaced): nothing is left to drain and
      -- nothing may be rolled back to. Its unsent forwards are lost with it.
      if o.successorEligible then
        (toPhase e .promoting o.nowMs "the old master pod went away mid-handover: the successor is promoted without the drain (NOT loss-free)", .send)
      else
        ({ toPhase e .aborted o.nowMs "the old master pod went away mid-handover and the successor is not eligible: no rollback (the failover rules apply)" with noRollback := true }, .finish)
    else if !o.successorEligible then
      (toPhase e .aborted o.nowMs "the successor is no longer eligible", .send)
    else if successorChanged e o then
      (toPhase e .aborted o.nowMs "the successor's pod, process or copy changed since the demote", .send)
    else if restarted then
      (toPhase e .aborted o.nowMs "the old master restarted (its counters are not comparable)", .send)
    -- progress before the bound: a step observed complete is taken even when
    -- the observation came after Th (local kind 2026-10-28: under load one
    -- tick took ~3 s, the drain was clean at the first read past 10 s, and
    -- the handover aborted into the one-map drain)
    else if e.phase == .demoting then
      match e.v1, o.oldMapVersion with
      | some v1, some ov =>
        if ov >= v1 then (toPhase e .draining o.nowMs, .none)
        else if expired then (toPhase e .aborted o.nowMs s!"not drained within {cfg.handoverMs} ms ({e.phase})", .send)
        else (e, .none)
      | none, _ => (e, .send)       -- V1 not recorded as sent yet: send it
      | _, none =>
        if expired then (toPhase e .aborted o.nowMs s!"not drained within {cfg.handoverMs} ms ({e.phase})", .send)
        else (e, .none)
    else
      if o.inFlightToSuccessor == some 0 && drainClean e o then
        ({ toPhase e .promoting o.nowMs with drainProven := true }, .send)
      else if expired then (toPhase e .aborted o.nowMs s!"not drained within {cfg.handoverMs} ms ({e.phase})", .send)
      else (e, .none)
  | .promoting =>
    match e.v2 with
    | none =>
      if successorChanged e o then
        (toPhase e .aborted o.nowMs "the successor's pod, process or copy changed before the promote", .send)
      else (e, .send)
    | some v2 =>
      if allApplied o.entryVersions v2 && o.successorOwnRole == some "master" then
        (toPhase e .done o.nowMs, .finish)
      else (e, .none)
  | .aborted =>
    -- a rollback map was due (V1 was sent, the old master still the same
    -- process): wait until every pod has it
    if e.v1.isNone || e.noRollback then (e, .finish)
    else match e.vBack with
      | none => (e, .send)
      | some vb => if allApplied o.entryVersions vb then (e, .finish) else (e, .none)
  | .done => (e, .finish)

/-- Record the version a `.send` was published with. -/
def recordSent (e : Entry) (version : Nat) : Entry :=
  match e.phase with
  | .demoting | .draining => if e.v1.isNone then { e with v1 := some version } else e
  | .promoting => if e.v2.isNone then { e with v2 := some version } else e
  | .aborted => if e.v1.isSome && e.vBack.isNone && !e.noRollback then { e with vBack := some version } else e
  | _ => e

/-- The map an entry's phase asks for, applied to `s`. Requested / aborted
    without V1 change nothing. -/
def apply (s : FlareClusterState) (e : Entry) : FlareClusterState :=
  match s.lookupNode e.oldMaster, s.lookupNode e.successor with
  | some old, some succ =>
    match e.phase with
    | .demoting | .draining =>
      -- the partition keeps the old master as its master/down placeholder:
      -- flared preserves the partition with no master, writes wait (W)
      s.addNode e.oldMaster { old with role := FlareRole.Master, state := FlareState.Down,
                                       partition := Int.ofNat e.partition }
    | .promoting | .done =>
      let s := s.addNode e.oldMaster { old with role := FlareRole.Proxy, state := FlareState.Active,
                                                partition := -1, formerSlaveOf := -1 }
      let s := s.addNode e.successor { succ with role := FlareRole.Master, state := FlareState.Active,
                                                 partition := Int.ofNat e.partition, balance := 100 }
      let slaves := match s.partitionMap.find? (fun (i, _) => i == e.partition) with
        | some (_, p) => p.slaves.filter (· != e.successor)
        | none => []
      s.setPartition e.partition { master := some e.successor, slaves := slaves }
    | .aborted =>
      if e.v1.isSome && !e.noRollback then
        s.addNode e.oldMaster { old with role := FlareRole.Master, state := FlareState.Active,
                                         partition := Int.ofNat e.partition }
      else s
    | .requested => s
  | _, _ => s

/-- Keys the masterless refill / failover must not promote while a handover
    runs: the successor waits for the drain, then the handover promotes it. -/
def blockedKeys (l : Ledger) : List String :=
  (l.entries.filter fun e => e.phase == .requested || e.phase.oldIsDown).map (·.successor)

/-- An aborted handover that rolled back (or never sent a map) and may be
    tried again for the same old master pod. -/
def retryable (cfg : Config) (e : Entry) : Bool :=
  e.phase == .aborted && !e.noRollback && e.attempt < cfg.maxAttempts
    && (e.v1.isNone || e.vBack.isSome)

/-- A retry that is due finds no successor the handover accepts: the attempt
    is used up as aborted without sending a map (3dcfc5c S9: the cut kept
    the replica's history unvalidated, no attempt 3 was opened, and the
    retryable entry held the drain with no end). After the last attempt the
    one-map drain takes the master, as after any exhausted handover. -/
def noSuccessorAttempt (e : Entry) (now : Nat) : Entry :=
  { e with attempt := e.attempt + 1, phase := .aborted, v1 := none, v2 := none, vBack := none,
           drainProven := false, successorBinding := "", startedMs := now, phaseMs := now,
           reason := s!"attempt {e.attempt + 1}: no replica the handover accepts (eligible, complete binding) when the retry was due" }

/-- Old masters the one-map drain must leave alone: their handover is in
    progress (requested … promoting), or aborted and still to be retried.
    Once the attempts are used up the drain gets the master back (the old
    behaviour, logged as not loss-free). -/
def drainHeldKeys (l : Ledger) (cfg : Config := {}) : List String :=
  (l.entries.filter fun e => e.phase == .requested || e.phase.oldIsDown || e.phase == .promoting
      || retryable cfg e).map (·.oldMaster)

/-- Old masters a running handover owns: the plain drain path leaves them. -/
def ownedMasters (l : Ledger) : List String :=
  (l.entries.filter fun e => e.phase != .done && !(e.phase == .aborted && e.v1.isNone)).map (·.oldMaster)

def find? (l : Ledger) (partition : Nat) : Option Entry :=
  l.entries.find? (·.partition == partition)

def upsert (l : Ledger) (e : Entry) : Ledger :=
  { entries := e :: l.entries.filter (·.partition != e.partition) }

def remove (l : Ledger) (partition : Nat) : Ledger :=
  { entries := l.entries.filter (·.partition != partition) }

/-- An ordered handover from pod `uid` at `key` is still running (not done,
    not aborted): the node guard refuses its delete although the map may
    already show it as a proxy. An entry without an old UID (an older or a
    damaged ledger: `Entry.fromJson?` defaults it to "") or a request
    without one matches every pod at `key` — fail closed (review of
    3dcfc5c); only a KNOWN different UID (a recreated pod) is not held. -/
def Ledger.unfinishedFor (l : Ledger) (key uid : String) : Bool :=
  l.entries.any fun e =>
    e.oldMaster == key && (e.oldUid.isEmpty || uid.isEmpty || e.oldUid == uid)
      && e.phase != .done && e.phase != .aborted

-- ═══════════════════════════════════════════════════════════════════════
-- Persistence (FlareCluster status.handovers)
-- ═══════════════════════════════════════════════════════════════════════

open Lean in
private def optNat (k : String) (v : Option Nat) : List (String × Json) :=
  match v with | some n => [(k, Json.num n)] | none => []

open Lean in
def Entry.toJson (e : Entry) : Json :=
  Json.mkObj <|
    ([("partition", Json.num e.partition), ("oldMaster", Json.str e.oldMaster),
      ("successor", Json.str e.successor), ("phase", Json.str e.phase.toString),
      ("oldUid", Json.str e.oldUid), ("noRollback", Json.bool e.noRollback),
      ("drainProven", Json.bool e.drainProven), ("attempt", Json.num e.attempt),
      ("startedMs", Json.num e.startedMs), ("demotedMs", Json.num e.demotedMs),
      ("phaseMs", Json.num e.phaseMs), ("successorBinding", Json.str e.successorBinding),
      ("reason", Json.str e.reason)] : List (String × Json))
    ++ optNat "v1" e.v1 ++ optNat "v2" e.v2 ++ optNat "vBack" e.vBack
    ++ optNat "oldBoot" e.oldBoot ++ optNat "dropped0" e.dropped0 ++ optNat "failed0" e.failed0

open Lean in
def Entry.fromJson? (j : Json) : Option Entry := do
  let partition ← (j.getObjValAs? Nat "partition").toOption
  let oldMaster ← (j.getObjValAs? String "oldMaster").toOption
  let successor ← (j.getObjValAs? String "successor").toOption
  let phase ← (j.getObjValAs? String "phase").toOption >>= Phase.fromString?
  let o := fun (k : String) => (j.getObjValAs? Nat k).toOption
  pure { partition, oldMaster, successor, phase,
         oldUid := (j.getObjValAs? String "oldUid").toOption.getD "",
         noRollback := (j.getObjValAs? Bool "noRollback").toOption.getD false,
         drainProven := (j.getObjValAs? Bool "drainProven").toOption.getD false,
         attempt := (o "attempt").getD 1,
         v1 := o "v1", v2 := o "v2", vBack := o "vBack",
         oldBoot := o "oldBoot", dropped0 := o "dropped0", failed0 := o "failed0",
         startedMs := (o "startedMs").getD 0, demotedMs := (o "demotedMs").getD 0,
         phaseMs := (o "phaseMs").getD 0,
         successorBinding := (j.getObjValAs? String "successorBinding").toOption.getD "",
         reason := (j.getObjValAs? String "reason").toOption.getD "" }

open Lean in
def Ledger.toJson (l : Ledger) : Json :=
  Json.mkObj [("entries", Json.arr (l.entries.map Entry.toJson).toArray)]

open Lean in
/-- Strict: one malformed entry fails the whole ledger (the caller then holds
    the handovers unavailable instead of forgetting one mid-way). -/
def Ledger.fromJson? (j : Json) : Option Ledger := do
  let entries ← match j.getObjVal? "entries" with
    | .ok (Json.arr a) => a.toList.mapM Entry.fromJson?
    | .ok _ => none
    | .error _ => some []
  pure { entries }

def Ledger.summary (l : Ledger) : String :=
  if l.entries.isEmpty then "no handovers"
  else String.intercalate "; " <| l.entries.map fun e =>
    s!"p{e.partition} {e.oldMaster} -> {e.successor} {e.phase}{if e.reason.isEmpty then "" else s!" ({e.reason})"}"

end FlareOperator.Handover
