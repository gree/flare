/-
  Operator/Handovers.lean - the ordered handover drive (runHandovers),
  history continuation (prepare / arm / release) and the successor
  checks, split out of Main.lean.
-/
import FlareOperator.Operator.Base

namespace FlareOperator

open FlareOperator.K8s
open FlareOperator.K8s.Bridge
open FlareOperator.Flare
open FlareOperator.Reconciler
open FlareOperator.Kubectl
open FlareOperator.Server
open FlareOperator.Metrics.Prometheus
open FlareOperator.Metrics.HttpServer
open FlareOperator.Health.HealthCheck

/-- The recorded (authoritative) history of partition `p`, from the loaded
    store: what "the same history" means for a lagging copy. -/
def recordedHistory (p : Int) : IO (Option (String × String)) := do
  if p < 0 then return none
  match ← historyStoreRef.get with
  | none => return none
  | some st => return (st.recorded p.toNat).map fun h => (h.masterId, h.epoch)

/-- The partition's last master (the map's lastMasterOf, exactly one) when the
    partition is explicitly UNTRACKED: the source a legacy-bound copy must
    name to be `lagging` (PromotionEvidence.legacyCopyOfUntrackedLastMaster). -/
def untrackedLastMaster (cs : FlareClusterState) (p : Int) : IO (Option String) := do
  if p < 0 then return none
  match ← historyStoreRef.get with
  | none => return none
  | some st =>
    if st.tracked p.toNat then return none
    match (cs.nodeMap.filter fun kv => kv.2.lastMasterOf == p).map Prod.fst with
    | [k] => return some k
    | _ => return none

/-- The handover's own precheck of a successor (review of ba85535): the
    promotion path's classification (markers, history, map; the old master is
    still the present master) must be `eligible`, and the binding (pod UID,
    boot id, copy id) complete. The node guard and rolling require the same
    before a master's delete: a successor the handover would refuse is no
    successor (a pre-R3 / pre-copy-identity flared included: fail closed). -/
def handoverSuccessorClass (cs : FlareClusterState) (k : String) (reply : Option String) :
    IO PromotionEvidence.Class := do
  match cs.lookupNode k with
  | none => pure (PromotionEvidence.Class.unknown "not in the map")
  | some n =>
    let part : Int := n.partition
    let nPartsB ← desiredPartitionsRef.get
    let obs : PromotionEvidence.Observed := {
      mapPrepare := n.state == FlareState.Prepare
      mapActive := n.state == FlareState.Active
      podReady := true
      -- an ACTIVE master only: during the demote the partition has the old
      -- master as a Master/Down placeholder, and a copy current to the last
      -- write then reads `revalidating` — `lagging` by design
      -- (handoverCommitAllows), not `forbidden` (42124876046: every copy read
      -- "history being re-validated against the present master" at the
      -- continuation barrier)
      partitionHasMaster := cs.nodeMap.any fun kv =>
        kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active && kv.2.partition == part
      lastMasterHistory := ← recordedHistory part
      isLastMasterHolder := part ≥ 0 && n.lastMasterOf == part
      expectedBinding := if part ≥ 0 then some (PromotionEvidence.bindingFor part.toNat nPartsB cs.partitionSize) else none
      untrackedLastMaster := ← untrackedLastMaster cs part
      attributedRejoin := PromotionEvidence.isAttributedRejoin (n.role == FlareRole.Slave) (n.state == FlareState.Prepare) n.partition n.lastMasterOf n.formerSlaveOf }
    pure (PromotionEvidence.classify reply obs)

def handoverSuccessorOk (cs : FlareClusterState) (k podUid : String) (reply : Option String) : IO Bool := do
  let cls ← handoverSuccessorClass cs k reply
  return PromotionEvidence.handoverAccepts cls (PromotionEvidence.bindingOf (some podUid) reply)

/-- The successor a handover of `oldMaster` takes now: the first Active slave
    of the partition (map order) that the precheck accepts this tick, else
    the first Active slave (the handover then waits on it in `requested`).
    Map order alone picked a slave whose flared had just restarted while the
    other one was ready (1f92e17 copy-identity 2: the old master's pod was
    gone before the restarted one read eligible). -/
def pickHandoverSuccessor (cs : FlareClusterState) (part : FlarePartition) (partIdx : Int)
    (oldMaster : String) (pods : List Bridge.PodInfo) (repairDests : List String) (ns : String) : IO (Option String) := do
  let readyKeys := (pods.filter fun p => p.ready && !p.terminating).map Bridge.PodInfo.toNodeKey
  let cands := Handover.successorCandidates cs part.slaves partIdx oldMaster readyKeys repairDests
  for k in cands do
    let some sp := pods.find? fun p => p.toNodeKey == k | continue
    let .ok out ← Bridge.queryPodStats sp.name ns "stats" | continue
    if ← handoverSuccessorOk cs k sp.uid (some out) then return some k
  -- none accepted now: the first candidate (the handover waits on it in
  -- `requested` and re-picks), else the map's first Active slave
  return cands.head? <|> K8sReconciler.findActiveSuccessor cs part partIdx

/-- The pod UID, boot id and copy id of a reading, as the handover ledger
    records its successor's (Handover.Entry.successorBinding). -/
def handoverBinding (b : PromotionEvidence.Binding) : String :=
  let dash := "-"
  let u := b.podUid.getD dash
  let t := b.bootId.getD dash
  let c := b.copyId.getD dash
  s!"{u}|{t}|{c}"

/-- The ordered handover's commit exception holds only for the successor's
    pod, process and copy that were read eligible when the demote started. -/
def handoverBindingHolds (k : String) (b : PromotionEvidence.Binding) : IO Bool := do
  return (← handoverCommitBindingRef.get).any fun (s, rec) => s == k && !rec.isEmpty
    && rec == handoverBinding b

/-- A complete `stats` reply of the pod behind `key`, or none. -/
def podStatsOf (key ns : String) : IO (Option String) := do
  match ← Bridge.queryPodStats (extractPodName key) ns "stats" with
  | .ok out => pure (if statsReplyComplete out then some out else none)
  | .error _ => pure none

/-- `name[dest]` of a per-destination flared counter. flared always sends the
    total `name` after the per-destination lines, so with the total present
    an absent destination is 0; without it the value is unknown. -/
def statDest (out name dest : String) : Option Nat :=
  match statNat out s!"{name}[{dest}]" with
  | some n => some n
  | none => if (statNat out name).isSome then some 0 else none

-- ═══════════════════════════════════════════════════════════════════════
-- HISTORY CONTINUATION (docs/design-handover-history-continuation.md,
-- addenda 1-3; off unless FLARE_OPERATOR_HISTORY_CONTINUATION=on)
-- ═══════════════════════════════════════════════════════════════════════

def historyContinuationOn : IO Bool := do
  return (← IO.getEnv "FLARE_OPERATOR_HISTORY_CONTINUATION") == some "on"

/-- Addendum 11 (ordering hole): the gate every publish of the live map goes
    through. Off = no gate (the map goes out as before). On: while a handover
    entry is in committingReplicas the live map holds V2 and only the armed
    prepared replicas may get it (HandoverDrive.publishGate). -/
def v2Gate (keys : Option (List String)) : IO HandoverDrive.Gate := do
  if !(← historyContinuationOn) then
    return match keys with | none => .all | some ks => .only ks
  return HandoverDrive.publishGate (← handoverLoadedRef.get) (← handoverRef.get).entries keys

/-- A complete reply of a flared command line (`stats` is one of them), or
    none (unreadable is never a value). -/
def podCmdOf (key ns cmd : String) : IO (Option String) := do
  match ← Bridge.queryPodStats (extractPodName key) ns cmd with
  | .ok out => pure (if statsReplyComplete out then some out else none)
  | .error _ => pure none

/-- The pod UID, boot id and copy id of `key` as read now (`uid|boot|copy`,
    the entry's binding strings); none when the pod or any part is missing. -/
def contBinding (pods : List Bridge.PodInfo) (k : String) (out : Option String) : Option String :=
  match pods.find? (·.toNodeKey == k), out with
  | some p, some o =>
    let b := PromotionEvidence.bindingOf (some p.uid) (some o)
    if b.complete then some (handoverBinding b) else none
  | _, _ => none

/-- One prepared replica read fresh (binding, pending, epoch, master_id,
    node_map_version). -/
def contReading (pods : List Bridge.PodInfo) (k ns : String) : IO HandoverDrive.Reading := do
  let out ← podCmdOf k ns "stats"
  pure { binding := contBinding pods k out, pending := out.bind (statRest · "history_pending"),
         epoch := out.bind (statStr · "rocksdb_source_epoch"),
         masterId := out.bind (statStr · "rocksdb_master_id"),
         version := out.bind (statNat · "node_map_version") }

/-- WAL pins of finished continuations still to release (memory only: the
    pin's own deadline and the free-space floor release it after a restart). -/
initialize releaseDueRef : IO.Ref (List HandoverDrive.ReleaseDue) ← IO.mkRef []

/-- `wal_pin release <hid>` to the new master once every continued replica's
    cursor passed S (idempotent: `already` is as good as `released`). -/
def runWalPinReleases (ns : String) : IO Unit := do
  let due ← releaseDueRef.get
  if due.isEmpty then return
  let now ← IO.monoMsNow
  let mut keep : List HandoverDrive.ReleaseDue := []
  for d in due do
    if now >= d.untilMs then
      IO.eprintln s!"[flare-operator] WAL PIN {d.hid}: not released by the operator in time; flared's own deadline releases it"
      continue
    let mut cursors : List (String × Option Nat) := []
    for k in d.prepared do
      cursors := cursors ++ [(k, (← podCmdOf k ns "stats").bind (statNat · "rocksdb_repl_last_lsn"))]
    if HistoryContinuation.releaseReady d.seq d.prepared cursors then
      match ← podCmdOf d.master ns (HandoverDrive.releaseCmd d.hid) with
      | some r =>
        let res := HandoverDrive.statLine r "wal_pin_result"
        if res == some "released" || res == some "already" then
          IO.eprintln s!"[flare-operator] WAL PIN {d.hid}: released on {d.master} ({res.getD ""}); every continued replica is past S={d.seq}"
        else
          IO.eprintln s!"[flare-operator] WAL PIN {d.hid}: release answered {res.getD "nothing"}; retried"
          keep := keep ++ [d]
      | none => keep := keep ++ [d]
    else keep := keep ++ [d]
  releaseDueRef.set keep

/-- `history discard <hid>` to every pod in `keys` (idempotent; a pending
    that is not there answers a refusal, which is fine). -/
def discardHistory (ns hid : String) (keys : List String) : IO Unit := do
  for k in keys.eraseDups do
    let r ← podCmdOf k ns (HandoverDrive.discardCmd hid)
    IO.eprintln s!"[flare-operator] HISTORY CONTINUATION: discard {hid} on {k}: {(r.bind HandoverDrive.historyResult).getD "unreadable"}"

/-- The prepare of an entry in `preparing` (addendum 2 §2, design §4-2/3):
    reads the old master's last sequence L, then every remaining replica's
    fresh stats (twice: the binding at the start and now), then L again;
    `HistoryContinuation.partition` decides who is eligible; the successor
    gets `promote_prepare` and each eligible replica `prepare`. Returns the
    entry recorded with `afterPrepare` (committingReplicas, or promoting
    without continuation when nothing can be continued), or `none` = not
    decided this tick (a read or send failed: asked again next tick, the
    requests are idempotent per hid; the deadline rolls it back). Nothing
    here changes any active state, and no orphan_purge is ever sent. -/
def continuationPrepare (ns : String) (st : FlareClusterState) (e : Handover.Entry)
    (pods : List Bridge.PodInfo) (repairDests : List String) (now deadlineMono : Nat)
    (lease : IO Bool) : IO (Option Handover.Entry) := do
  let hid := HistoryContinuation.handoverId e.partition e.attempt e.demotedMs
  let tag := s!"HISTORY CONTINUATION p{e.partition} {hid}"
  let fallback : String → List String → IO (Option Handover.Entry) := fun why discard => do
    discardHistory ns hid discard
    IO.eprintln s!"[flare-operator] {tag}: {why}; no continuation, the replicas rebuild as before"
    pure (some (Handover.afterPrepare e now "" 0 "" "" []))
  let slaves := match st.partitionMap.find? (fun (i, _) => i == e.partition) with
    | some (_, part) => part.slaves.filter (· != e.successor)
    | none => []
  let keys := e.successor :: slaves
  let oBefore ← podCmdOf e.oldMaster ns "stats"
  let mut start : List (String × Option String) := []
  for k in keys do
    start := start ++ [(k, contBinding pods k (← podCmdOf k ns "stats"))]
  let mut replies : List (String × Option String) := []
  for k in keys do
    replies := replies ++ [(k, ← podCmdOf k ns "stats")]
  let oAfter ← podCmdOf e.oldMaster ns "stats"
  let readyKeys := (pods.filter fun p => p.ready && !p.terminating).map Bridge.PodInfo.toNodeKey
  let mut obsList : List HistoryContinuation.ReplicaObs := []
  for (k, out) in replies do
    let cls ← handoverSuccessorClass st k out
    let sts := (out.map PromotionEvidence.parseStats).getD {}
    let fs := out.bind (statStr · "repl_follow_state")
    IO.eprintln s!"[flare-operator] {tag}: barrier reading of {k}: R3 {cls.label}, follow {fs.getD "unreadable"}, cursor {(out.bind (statNat · "rocksdb_repl_last_lsn")).map toString |>.getD "?"}, epoch {(out.bind (statStr · "rocksdb_source_epoch")).getD "?"}"
    obsList := obsList ++ [{
      key := k, bindingAtStart := (start.lookup k).getD none, bindingNow := contBinding pods k out,
      cursor := out.bind (statNat · "rocksdb_repl_last_lsn"), followState := fs,
      needsRebuild := fs == some "needs_rebuild",
      epoch := out.bind (statStr · "rocksdb_source_epoch"), masterId := out.bind (statStr · "rocksdb_master_id"),
      inFlightFromOld := oAfter.bind (statDest · "proxy_write_in_flight" k),
      activeSlave := (st.lookupNode k).any fun n =>
        n.role == FlareRole.Slave && n.partition == Int.ofNat e.partition && n.state == FlareState.Active,
      -- at the barrier (after V1) every copy of the partition reads
      -- `lagging` (the partition has only the Master/Down placeholder):
      -- the same reading the handover's own promotion gate accepts
      -- (PromotionEvidence.handoverCommitAllows), never forbidden / unknown
      -- (42120599042: "the successor is not continued (not R3 eligible)")
      ready := readyKeys.contains k, r3Eligible := PromotionEvidence.handoverCommitAllows cls,
      partialCopy := sts.copyPartial == some 1, quarantined := sts.quarantined == some 1,
      repairPending := repairDests.contains k }]
  let src : HistoryContinuation.SourceObs := {
    latestSeq := oAfter.bind (statNat · "rocksdb_latest_sequence_number"),
    epoch := oAfter.bind (statStr · "rocksdb_source_epoch"),
    masterId := oAfter.bind (statStr · "rocksdb_master_id"),
    boot := oAfter.bind (statNat · "reconstruction_boot_id") }
  let lBefore := oBefore.bind (statNat · "rocksdb_latest_sequence_number")
  let lAfter := src.latestSeq
  if src.boot != e.oldBoot then
    return (← fallback "the old master restarted (or its process is unreadable)" [])
  let some succObs := obsList.find? (·.key == e.successor)
    | fallback "the successor could not be read" []
  if let some why := HistoryContinuation.excluded src lBefore lAfter succObs then
    return (← fallback s!"the successor is not continued ({why})" [])
  let (ok, no) := HistoryContinuation.partition src lBefore lAfter (obsList.filter (·.key != e.successor))
  for (k, why) in no do
    IO.eprintln s!"[flare-operator] {tag}: {k} is not continued ({why}); it rebuilds"
  if !(HandoverDrive.safeArg hid && HandoverDrive.safeArg e.successor) then
    return (← fallback "an identifier is not safe to send" [])
  if !(← lease) then
    IO.eprintln s!"[flare-operator] {tag}: the lease was not confirmed; nothing is prepared this tick"
    return none
  let deadline := HandoverDrive.wallDeadline (← Bridge.wallMs) now deadlineMono
  let prOpt ← podCmdOf e.successor ns (HandoverDrive.promotePrepareCmd hid e.partition e.successor deadline)
  let some pr := prOpt
    | IO.eprintln s!"[flare-operator] {tag}: the successor's promote_prepare reply was unreadable; asked again" *> pure none
  let some (toEpoch, seq, masterId) := HandoverDrive.parsePromote pr
    | fallback s!"the successor refused promote_prepare ({(HandoverDrive.historyResult pr).getD "no result"})" [e.successor]
  let mut prepared : List (String × String) := []
  for k in ok do
    let some ob := obsList.find? (·.key == k) | continue
    let out := (replies.lookup k).getD none
    match ob.bindingNow, ob.epoch, out.bind (statStr · "rocksdb_incarnation") with
    | some b, some fromEp, some inc =>
      if !(HandoverDrive.safeArg k && HandoverDrive.safeArg fromEp && HandoverDrive.safeArg toEpoch
            && HandoverDrive.safeArg masterId && HandoverDrive.safeArg inc) then
        IO.eprintln s!"[flare-operator] {tag}: {k} is not prepared (an identifier is not safe to send); it rebuilds"
      else
        let reply ← podCmdOf k ns (HandoverDrive.prepareCmd hid e.partition e.successor fromEp toEpoch seq masterId deadline inc)
        if HandoverDrive.resultOk (reply.bind HandoverDrive.historyResult) then
          prepared := prepared ++ [(k, b)]
        else
          IO.eprintln s!"[flare-operator] {tag}: {k} did not prepare ({((reply.bind HandoverDrive.historyResult)).getD "unreadable"}); it rebuilds"
          let _ ← podCmdOf k ns (HandoverDrive.discardCmd hid)
    | _, _, _ =>
      IO.eprintln s!"[flare-operator] {tag}: {k} is not prepared (binding, epoch or incarnation unreadable); it rebuilds"
  if prepared.isEmpty then
    return (← fallback "no replica could be prepared" [e.successor])
  IO.eprintln s!"[flare-operator] {tag}: prepared {e.successor} (E'={toEpoch}, S={seq}, master_id={masterId}) and {prepared.map (·.1)} (L={lAfter.getD 0}, deadline {deadline})"
  return some (Handover.afterPrepare e now hid seq toEpoch masterId prepared)

/-- One handover pass, BEFORE the FSM (like replica repair part 1): start a
    handover for every Terminating Active master that has an Active slave,
    read the observations, step each handover once and commit the map a step
    asks for directly to stateRef (its version is recorded as V1 / V2 / V1′).
    Returns the successors held out of assignment and the old masters held
    out of the one-map drain while their handover runs. The FSM's own drain leaves the old master alone from V1 on (a
    Down node is not drained; after V2 it is a Proxy). `publish` sends the
    live map at once (the pass's lease, persist and publication fences);
    `commitPromote` commits V2 through the pass's promotion gates (true =
    nothing refused it); `route` points the partition Services at the
    masters of the live map; `renew` renews this pod's lease (the fast loop
    can outlast a lease period: it must not starve the leader loop's
    renewal). -/
def runHandovers (crName ns : String) (stateRef : IO.Ref FlareClusterState)
    (repairLed : ReplicaRepair.Ledger) (publish : String → IO Bool)
    (commitPromote : Option (String × String) → FlareClusterState → IO Bool)
    (route : IO Unit) (renew : IO Bool) (publishTo : String → List String → IO Bool)
    (leaseName identity : String) : IO (List String) := do
  let contOn ← historyContinuationOn
  -- set below from this pass's pod read; an early return leaves `none` (no
  -- observation: the FSM's drain then leaves every Terminating master)
  handoverSeenAliveRef.set none
  if !(← handoverLoadedRef.get) then
    match ← Bridge.readHandovers crName ns with
    | .ok l =>
      handoverRef.set (l.getD {})
      handoverLoadedRef.set true
      if let some l := l then
        IO.eprintln s!"[flare-operator] handover ledger restored: {l.summary}"
    | .error e =>
      IO.eprintln s!"[flare-operator] WARNING: handover ledger unreadable ({e}); planned master switches take the one-map drain this pass"
      return []
  -- a ledger with a continuation entry is saved only by the guarded CAS
  -- (inside the tick loop below), never by this plain write
  if (← handoverDirtyRef.get) && !(contOn && (← handoverRef.get).entries.any (HandoverDrive.guarded true)) then
    match ← Bridge.writeHandovers crName ns (← handoverRef.get) with
    | .ok _ => handoverDirtyRef.set false
    | .error e => IO.eprintln s!"[flare-operator] WARNING: handover ledger still unsaved ({e})"
  let led0 ← handoverRef.get
  -- TEST SEAM (FLARE_TEST_HANDOVER_PODS_FAIL_FILE, unset in production):
  -- while the named file exists, this read fails as an API error would
  let podsSeam ← match ← IO.getEnv "FLARE_TEST_HANDOVER_PODS_FAIL_FILE" with
    | some f => System.FilePath.pathExists f
    | none => pure false
  let podsRead ← if podsSeam then pure (Except.error "TEST SEAM: FLARE_TEST_HANDOVER_PODS_FAIL_FILE is present")
    else Bridge.listFlaredPodsE crName ns
  let pods ← match podsRead with
    | .ok ps => pure ps
    | .error e =>
      IO.eprintln s!"[flare-operator] handover: pods unreadable ({e}); handovers held this pass"
      return Handover.blockedKeys led0 ++ Handover.drainHeldKeys led0
  let cfg : Handover.Config := { continuation := contOn }
  let now ← IO.monoMsNow
  let state0 ← stateRef.get
  let mut led := led0
  let repairDests0 := repairLed.entries.filterMap (·.nodeKey)
  handoverSeenAliveRef.set (some ((pods.filter fun p => !p.terminating).filterMap fun p =>
    let k := p.toNodeKey
    if (state0.lookupNode k).any (fun n => n.role == FlareRole.Master && n.state == FlareState.Active) then some k else none))
  -- planned handovers still wanted: the same pod, still the Active master,
  -- and its handover not given up
  -- (modify: the node guard adds to it from the webhook's thread)
  plannedHandoverRef.modify fun l => l.filter fun (k, u) =>
    pods.any (fun p => p.toNodeKey == k && p.uid == u && !p.terminating)
      && (state0.lookupNode k).any (fun n => n.role == FlareRole.Master && n.state == FlareState.Active)
      && !(led0.entries.any fun e => e.oldMaster == k && e.oldUid == u && e.phase == .aborted && !Handover.retryable cfg e)
  let planned ← plannedHandoverRef.get
  -- start
  for p in pods do
    if !p.terminating && !(planned.any fun (k, u) => k == p.toNodeKey && u == p.uid) then continue
    let k := p.toNodeKey
    match state0.lookupNode k with
    | some n =>
      -- a master on a flared from before the handover can never be handed
      -- over (no boot id / forward counters): no handover is opened for it,
      -- which would only hold the drain for its three attempts (~105 s)
      let legacy ← if n.role == FlareRole.Master && p.terminating then
          Handover.oldMasterPredatesHandover <$> podStatsOf k ns
        else pure false
      if legacy then
        IO.eprintln s!"[flare-operator] HANDOVER: master {k} runs a flared from before the ordered handover; no handover is opened (the drain takes it, NOT loss-free)"
      else if n.role == FlareRole.Master && n.state == FlareState.Active && n.partition >= 0 then
        let pIdx := n.partition.toNat
        -- a new handover, or the retry of one that aborted and rolled back
        -- (same old master pod, after the retry delay, attempts left): L7 —
        -- the lossless handover is tried again before the one-map drain
        let prev := Handover.find? led pIdx
        let retry := match prev with
          | some e => Handover.retryable cfg e && e.oldMaster == k && e.oldUid == p.uid
                        && now >= e.phaseMs + cfg.retryDelayMs
          | none => false
        if prev.isNone || retry then
          match state0.partitionMap.find? (fun (i, _) => i == pIdx) with
          | some (_, part) =>
            match ← pickHandoverSuccessor state0 part n.partition k pods repairDests0 ns with
            | some succ =>
              let attempt := (prev.map (·.attempt + 1)).getD 1
              led := Handover.upsert led { partition := pIdx, oldMaster := k, successor := succ,
                                           oldUid := p.uid, attempt, startedMs := now, phaseMs := now }
              IO.eprintln s!"[flare-operator] HANDOVER requested: partition {pIdx} master {k} is Terminating; successor {succ}{if retry then s!" (attempt {attempt} of {cfg.maxAttempts}, after: {(prev.map (·.reason)).getD ""})" else ""}"
            | none =>
              -- a due retry with no acceptable successor uses up its attempt
              -- (else the retryable entry holds the drain indefinitely)
              if retry then
                if let some e := prev then
                  let e' := Handover.noSuccessorAttempt e now
                  led := Handover.upsert led e'
                  IO.eprintln s!"[flare-operator] HANDOVER p{pIdx} {k}: retry due, no replica the handover accepts -> aborted after 0 ms without a map (attempt {e'.attempt} of {cfg.maxAttempts}){if Handover.retryable cfg e' then "" else "; attempts used up, the one-map drain applies"}"
          | none => pure ()
    | none => pure ()
  -- step. A handover in transit (V1 sent, not yet promoted or rolled back)
  -- does not wait for the next pass: its maps are published here as soon as
  -- they are committed, and its entries are re-observed every 100 ms until
  -- none is in transit or the bound passes (local kind 2026-10-28: one step
  -- per pass meant one step per ~8 s, and the drain was judged once, after
  -- Th had run out).
  let repairDests := repairLed.entries.filterMap (·.nodeKey)
  let bound := now + cfg.handoverMs + 5000
  let mut pods := pods
  let mut out : Handover.Ledger := {}
  let mut first := true
  let mut routed := false
  let mut renewedMs ← IO.monoMsNow
  let mut lastTargeted : Nat := 0
  if !(← releaseDueRef.get).isEmpty then runWalPinReleases ns
  -- The status write of a continuation phase (design addendum 3 §1): CAS
  -- BEFORE the send, with the lease bound (heldUntil − now ≥ 4 s + 1 s; the
  -- CAS is cut at min(4 s, heldUntil − now − 1 s)), the entry stamped with
  -- this leader's epoch (the lease's transitions), and — after the answer —
  -- the lease re-checked (still the holder, same epoch, time left). Any
  -- failure, refusal or unknown outcome = false = nothing is sent this tick;
  -- the next tick reads the status again (the CAS is idempotent).
  let epochRef ← IO.mkRef (0 : Nat)
  let casSave : Handover.Ledger → Handover.Entry → IO Bool := fun l x => do
    let no := fun (why : String) => do
      IO.eprintln s!"[flare-operator] HANDOVER p{x.partition}: {why}; the {x.phase} step is NOT taken this tick"
      pure false
    match ← Bridge.getLease leaseName ns with
    | .error err => no s!"the lease could not be read ({err})"
    | .ok l1 =>
      let rem : Int := (l1.leaseDurationSeconds : Int) - l1.ageSeconds
      if l1.holderIdentity != identity || l1.expired then no "this operator does not hold the lease"
      else match HandoverDrive.casBound rem with
        | none => no s!"the lease has {rem} s left, less than the {HandoverDrive.casMarginSec} s the status write needs"
        | some bound =>
          let ep := l1.transitions
          let stamp := fun (y : Handover.Entry) => if HandoverDrive.guarded true y then { y with leaderEpoch := ep } else y
          match ← Bridge.casHandovers crName ns (stamp x) { entries := l.entries.map stamp } ep bound with
          | .error err => no s!"the status was not written ({err})"
          | .ok _ =>
            match ← Bridge.getLease leaseName ns with
            | .error err => no s!"the lease could not be confirmed after the write ({err})"
            | .ok l2 =>
              if HandoverDrive.leaseKept identity l2.holderIdentity l2.expired ep l2.transitions
                  ((l2.leaseDurationSeconds : Int) - l2.ageSeconds) then
                epochRef.set ep
                handoverDirtyRef.set false
                pure true
              else no "the lease or the leader epoch changed while the status was written"
  repeat
    if !first then
      IO.sleep 100
      -- local kind 2026-10-28 (S8): an abort, its rollback and the pass
      -- around it outlasted the 15 s lease; the lease expired and the next
      -- maps were fenced. Renew every 2 s; on a lost lease stop here.
      if (← IO.monoMsNow) >= renewedMs + 2000 then
        if !(← renew) then
          IO.eprintln "[flare-operator] HANDOVER: the lease could not be renewed (not the holder, or the API refused); the fast loop stops and the rest of this pass is skipped — the leader loop decides"
          passLeaseLostRef.set true
          break
        renewedMs ← IO.monoMsNow
      match ← Bridge.listFlaredPodsE crName ns with
      | .ok ps => pods := ps
      | .error e =>
        IO.eprintln s!"[flare-operator] handover: pods unreadable ({e}); the next pass continues"
        break
    first := false
    let now ← IO.monoMsNow
    let before := led
    out := {}
    let mut sent := false
    let mut transit := false
    for e in led.entries do
      let st ← stateRef.get
      -- the old master's pod is still the one the handover started with: a
      -- pod replaced under the same name is another process (its counters and
      -- its copy are not the old master's)
      let oldSameProcess := e.oldUid.isEmpty
        || pods.any (fun p => p.toNodeKey == e.oldMaster && p.uid == e.oldUid)
      -- an aborted handover stays as a marker until its old master's pod is
      -- gone (the one-map drain takes over; no second handover is started for it)
      if e.phase == .aborted && !oldSameProcess then
        IO.eprintln s!"[flare-operator] HANDOVER p{e.partition} closed: the old master {e.oldMaster} is gone"
        continue
      -- the one-map drain took it before a map was sent
      if e.phase == .requested && (st.lookupNode e.oldMaster).any (·.role == FlareRole.Proxy) then
        IO.eprintln s!"[flare-operator] HANDOVER p{e.partition} dropped: {e.oldMaster} was drained without it"
        continue
      let oldOut ← podStatsOf e.oldMaster ns
      let succOut ← podStatsOf e.successor ns
      let mut versions : List (String × Option Nat) := []
      -- every pod's version is needed only to confirm a promote or rollback
      let needAll := e.phase == .promoting || e.phase == .aborted || e.phase == .rollingBack
      for p in pods do
        if p.ip.isEmpty || !needAll then continue
        let o ← if p.toNodeKey == e.oldMaster then pure oldOut
                else if p.toNodeKey == e.successor then pure succOut
                else podStatsOf p.toNodeKey ns
        versions := versions ++ [(p.toNodeKey, o.bind (statNat · "node_map_version"))]
      let succPod := pods.find? (·.toNodeKey == e.successor)
      -- history continuation: each prepared replica read fresh and bound
      -- (addendum 3 §2): committed only with the same binding, no pending,
      -- epoch = toEpoch, master_id and a map version ≥ V2
      let mut contReads : List (String × HandoverDrive.Reading) := []
      if contOn && e.phase == .committingReplicas then
        for (k, _) in e.prepared do
          contReads := contReads ++ [(k, ← contReading pods k ns)]
      -- R3 / SAF-08: the successor is judged by the promotion path's own
      -- classification (markers, history, map and pod; review of ba85535:
      -- not just the R3 key), and only `eligible` may start a demote; the
      -- binding (pod, process, copy) must be complete — a pre-R3 or
      -- pre-copy-identity flared cannot prove it is the same copy at the
      -- commit, so it is never handed over losslessly (fail closed)
      let succCls ← if e.phase == .requested then handoverSuccessorClass st e.successor succOut
        else pure (PromotionEvidence.Class.unknown "not read after the demote")
      let succR3 := succCls == .eligible
      let succBinding := match succPod, succOut with
        | some sp, some out =>
          let b := PromotionEvidence.bindingOf (some sp.uid) (some out)
          if b.complete then some (handoverBinding b) else none
        | _, _ => none
      let readyNow := (pods.filter fun p => p.ready && !p.terminating).map Bridge.PodInfo.toNodeKey
      let succEligible := (Handover.successorCandidates st [e.successor] (Int.ofNat e.partition) e.oldMaster
        readyNow repairDests).contains e.successor
      let obs : Handover.Obs := {
        nowMs := now, successorEligible := succEligible, oldSameProcess,
        oldMapVersion := oldOut.bind (statNat · "node_map_version"),
        oldBoot := oldOut.bind (statNat · "reconstruction_boot_id"),
        inFlightToSuccessor := oldOut.bind (statDest · "proxy_write_in_flight" e.successor),
        droppedToSuccessor := oldOut.bind (statDest · "proxy_write_dropped" e.successor),
        failedToSuccessor := oldOut.bind (statDest · "proxy_write_failed" e.successor),
        entryVersions := versions,
        successorOwnRole := succOut.bind (statStr · "own_role"),
        successorR3 := succR3,
        successorBinding := succBinding,
        committedKeys := HandoverDrive.committedKeys e contReads,
        zeroCommitProven := HandoverDrive.zeroProven e contReads }
      -- still requested and this successor is not accepted now: another
      -- Active slave the precheck accepts takes its place (nothing was sent)
      if e.phase == .requested && (!succEligible || !succR3 || succBinding.isNone) then
        if let some (_, part) := st.partitionMap.find? (fun (i, _) => i == e.partition) then
          if let some alt ← pickHandoverSuccessor st part (Int.ofNat e.partition) e.oldMaster pods repairDests ns then
            if alt != e.successor && (← handoverSuccessorOk st alt ((pods.find? (·.toNodeKey == alt)).map (·.uid) |>.getD "") (← podStatsOf alt ns)) then
              IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: successor {e.successor} is not accepted now ({succCls.label}); {alt} is, and takes its place"
              out := { entries := out.entries ++ [{ e with successor := alt }] }
              -- the fast loop ticks again at once (the new successor is ready)
              transit := true
              continue
      let mut heldMsg : Option String := none
      if e.phase == .requested && !succEligible then
        -- not even a candidate (replaced, not Ready, repair pending, not an
        -- Active slave) and no other slave accepted (the re-pick above):
        -- logged like the drain's own safe stop (CI 40858711976, copy-identity 13)
        heldMsg := some s!"[flare-operator] CRITICAL: HANDOVER p{e.partition}: draining master {e.oldMaster} has NO promotable successor yet — {e.successor} is not an Active, Ready slave without a pending repair and no other slave is accepted; the master is kept (no demote)"
      else if e.phase == .requested && succEligible && !succR3 then
        heldMsg := some s!"[flare-operator] CRITICAL: HANDOVER p{e.partition}: draining master {e.oldMaster} has NO promotable successor yet — {e.successor} reads {succCls.label}; the master is kept (no demote) until it reads eligible"
      else if e.phase == .requested && succEligible && succBinding.isNone then
        heldMsg := some s!"[flare-operator] CRITICAL: HANDOVER p{e.partition}: draining master {e.oldMaster} has NO promotable successor yet — {e.successor} does not report a complete identity (pod UID, boot id, copy id); no lossless handover without it"
      -- logged once per change of the reason, per partition
      let prevHeld := ((← handoverHeldLogRef.get).lookup e.partition)
      match heldMsg with
      | some m =>
        if prevHeld != some m then
          IO.eprintln m
          handoverHeldLogRef.modify fun l => (e.partition, m) :: l.filter (·.1 != e.partition)
      | none =>
        if prevHeld.isSome then handoverHeldLogRef.modify (·.filter (·.1 != e.partition))
      let (e1, act) := Handover.step cfg e obs
      if e.phase == .requested && e1.phase == .demoting then
        let demoteBoot := (PromotionEvidence.bindingOf none succOut).bootId.getD "?"
        -- the reading the drain then proves current (SAF-08: the successor's
        -- own process; the commit accepts the handover exception only for it)
        IO.eprintln s!"[flare-operator] PROMOTION EVIDENCE (handover demote, the successor's own R3 reading): {e.successor}={succCls.label} [boot {demoteBoot}] binding {e1.successorBinding}"
      if e1.phase != e.phase then
        IO.eprintln s!"[flare-operator] HANDOVER p{e.partition} {e.oldMaster} -> {e.successor}: {e.phase} -> {e1.phase} after {now - e.phaseMs} ms (since start {now - e.startedMs} ms){if e1.reason.isEmpty || e1.reason == e.reason then "" else s!" — {e1.reason}"}"
        if e1.phase == .aborted then
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition} observed at the abort: successor eligible={succEligible}, old master same pod={oldSameProcess}, old map v={obs.oldMapVersion} (V1 {e.v1}), boot {obs.oldBoot} (start {e.oldBoot}), in flight={obs.inFlightToSuccessor}, dropped={obs.droppedToSuccessor} (start {e.dropped0}), failed={obs.failedToSuccessor} (start {e.failed0})"
      -- V2 promotes an existing copy: it goes through the pass's promotion
      -- commit (fresh evidence, pod identity, the authoritative-history
      -- intent persisted before the map). A refused V2 is not retried
      -- blindly: before promoting the handover rolls back to the old master
      -- (or, with the old master gone, leaves the partition to the failover
      -- rules).
      let mut e1 := e1
      let mut act := act
      -- DURABILITY: a map is committed only after the ledger holds the phase
      -- that asks for it (its version is recorded afterwards; a restart in
      -- between finds the phase with no version and sends the map again).
      -- Not saved = nothing committed this tick: the entry stays as it was.
      let durable := fun (x : Handover.Entry) => do
        let l : Handover.Ledger := { entries := out.entries ++ [x] ++ (led.entries.filter fun y =>
          y.partition != x.partition && !(out.entries.any (·.partition == y.partition))) }
        if HandoverDrive.guarded contOn x then casSave l x else
        -- TEST SEAM (FLARE_TEST_HANDOVER_SAVE_FAIL_FILE, unset in
        -- production): while the named file exists in this container, the
        -- save fails as an API error would (node-ops-switch-*-savefail)
        let seamFail ← match ← IO.getEnv "FLARE_TEST_HANDOVER_SAVE_FAIL_FILE" with
          | some f => System.FilePath.pathExists f
          | none => pure false
        let saved ← if seamFail then pure (Except.error "TEST SEAM: FLARE_TEST_HANDOVER_SAVE_FAIL_FILE is present")
          else Bridge.writeHandovers crName ns l
        match saved with
        | .ok _ =>
          handoverDirtyRef.set false
          pure true
        | .error err =>
          handoverDirtyRef.set true
          IO.eprintln s!"[flare-operator] HANDOVER p{x.partition}: the ledger could not be saved ({err}); its {x.phase} map is NOT committed this tick"
          pure false
      -- history continuation: .prepare — the phase is written first (CAS),
      -- then the reads and sends; nothing active changes
      if act == .prepare then
        if !(← durable e1) then
          e1 := e
          act := .none
        else
          match ← continuationPrepare ns st e1 pods repairDests now (e.demotedMs + cfg.handoverMs + HandoverDrive.pendingGraceMs) renew with
          | some e' =>
            e1 := e'
            act := .none
          | none => act := .none
      -- .sendTargeted — V2 to the prepared replicas only (addendum 1/2/3):
      -- their binding is read again first; a replica that changed is dropped
      -- (CAS) and, in the same process, told to discard; V2 is committed
      -- through the promotion gates like the promoting path and recorded
      -- (CAS) before it is sent to the replicas not yet confirmed committed
      if act == .sendTargeted then
        let hid := e.hid
        let mut nowB : List (String × Option String) := []
        for (k, _) in e1.prepared do
          nowB := nowB ++ [(k, contBinding pods k (← podCmdOf k ns "stats"))]
        let (eDrop, dropped) := HandoverDrive.dropChanged e1 nowB
        let mut proceed := true
        if !dropped.isEmpty then
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: prepared replica(s) {dropped.map (·.1)} changed pod, process or copy (or are unreadable) since the prepare: dropped from the continuation (they rebuild)"
          if (← durable eDrop) then
            e1 := eDrop
            for (k, same) in dropped do
              if same then
                discardHistory ns hid [k]
            if e1.prepared.isEmpty then
              discardHistory ns hid [e1.successor]
              act := .send
              proceed := false
          else
            e1 := e
            act := .none
            proceed := false
        if proceed then
          let mut justCommitted := false
          if e1.v2.isNone then
            if !(← durable e1) then
              e1 := e
              act := .none
              proceed := false
            else
              let before ← stateRef.get
              handoverCommitBindingRef.set [(e1.successor, e1.successorBinding)]
              let ok ← commitPromote (if e1.drainProven then some (e1.successor, (succPod.map (·.uid)).getD "") else none) (Handover.apply before e1)
              let after ← stateRef.get
              let promoted := (after.lookupNode e1.successor).any (·.role == FlareRole.Master)
                && after.nodeMapVersion != before.nodeMapVersion
              if ok && promoted then
                IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: V2 committed as v{after.nodeMapVersion} (promotion gates passed); it goes to the prepared replicas first"
                e1 := Handover.recordSent e1 after.nodeMapVersion
                justCommitted := true
              else
                IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: the promotion of {e1.successor} was REFUSED by the promotion gates (before any replica committed)"
                discardHistory ns hid (e1.successor :: e1.prepared.map (·.1))
                if oldSameProcess then
                  e1 := { e1 with phase := .rollingBack, phaseMs := now, committed := [],
                                  reason := "the promotion gates refused the successor: back to the old master" }
                  act := .send
                else
                  e1 := { e1 with phase := .aborted, phaseMs := now, noRollback := true,
                                  reason := "the promotion gates refused the successor and the old master is gone: the failover rules apply" }
                  act := .finish
                proceed := false
          let mut targets := (e1.prepared.map (·.1)).filter fun k => !e1.committed.contains k
          if proceed then
            -- addendum 11: each prepared replica not yet committed is armed
            -- for this exact V2 (idempotent) BEFORE the map goes to it; one
            -- whose arm fails is dropped by CAS (it rebuilds) — unless a
            -- fresh read shows it committed
            if !targets.isEmpty && e1.v2.isSome && contOn && (justCommitted || now >= lastTargeted + 1000) then
              if let some v2 := e1.v2 then
                let mut failed : List String := []
                for k in targets do
                  let r ← podCmdOf k ns (HandoverDrive.armCmd hid v2)
                  let res := r.bind HandoverDrive.historyResult
                  if !HandoverDrive.armOk res then
                    let rd ← contReading pods k ns
                    match e1.prepared.lookup k with
                    | some b =>
                      if rd.committed e1 b v2 then
                        e1 := { e1 with committed := (e1.committed ++ [k]).eraseDups }
                      else
                        IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: arm of {hid} for v{v2} on {k} answered {res.getD "nothing"}: dropped from the continuation (it rebuilds)"
                        failed := failed ++ [k]
                    | none => pure ()
                if !failed.isEmpty then
                  let eArm := HandoverDrive.dropPrepared e1 failed
                  if (← durable eArm) then
                    e1 := eArm
                    discardHistory ns hid failed
                    if e1.phase != .committingReplicas then
                      act := .send
                      proceed := false
                  else
                    proceed := false
                    act := .none
                targets := (e1.prepared.map (·.1)).filter fun k => !e1.committed.contains k
          if proceed then
            if !targets.isEmpty && e1.v2.isSome && (justCommitted || now >= lastTargeted + 1000) then
              if (← durable e1) then
                lastTargeted := now
                let okSend ← publishTo "handover (prepared replicas)" targets
                IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: V2 sent to the prepared replicas {targets}: reply-confirmed={okSend}"
              else
                IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: V2 is recorded; it is sent to the prepared replicas once the status write succeeds"
            act := .none
      if act == .send && e1.phase == .promoting && e1.v2.isNone && !(← durable e1) then
        e1 := e
        act := .none
      if act == .send && e1.phase == .promoting && e1.v2.isNone then
        let before ← stateRef.get
        -- the lossless exception only after a drain proven clean
        handoverCommitBindingRef.set [(e1.successor, e1.successorBinding)]
        let ok ← commitPromote (if e1.drainProven then some (e1.successor, (succPod.map (·.uid)).getD "") else none) (Handover.apply before e1)
        let after ← stateRef.get
        let promoted := (after.lookupNode e1.successor).any (·.role == FlareRole.Master)
          && after.nodeMapVersion != before.nodeMapVersion
        if ok && promoted then
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: promoting map committed as v{after.nodeMapVersion} (promotion gates passed)"
          sent := true
          e1 := Handover.recordSent e1 after.nodeMapVersion
          act := .none
        else
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: the promotion of {e1.successor} was REFUSED by the promotion gates"
          if oldSameProcess then
            e1 := { e1 with phase := .aborted, phaseMs := now, reason := "the promotion gates refused the successor" }
            act := .send
          else
            e1 := { e1 with phase := .aborted, phaseMs := now, noRollback := true,
                            reason := "the promotion gates refused the successor and the old master is gone: the failover rules apply" }
            act := .finish
      if act == .send && !(← durable e1) then
        e1 := e
        act := .none
      -- rolling back a continuation: the pending records go with V1'
      if act == .send && e1.phase == .rollingBack && e1.vBack.isNone && contOn then
        let slaves := match st.partitionMap.find? (fun (i, _) => i == e.partition) with
          | some (_, part) => part.slaves
          | none => []
        discardHistory ns (HistoryContinuation.handoverId e1.partition e1.attempt e1.demotedMs)
          (e1.successor :: slaves ++ e1.prepared.map (·.1))
      -- addendum 11: before the promoting full send that follows a
      -- continuation, the successor is armed for V2 (a refusal is logged and
      -- the ordinary promotion goes on: it advances its epoch, the committed
      -- replicas rebuild, no data is lost). That send carries V2 itself (no
      -- new version) while the live map is still V2: the successor commits
      -- only on the exact version it was armed for.
      let contFull := act == .send && contOn && e1.phase == .promoting && !e1.hid.isEmpty && !e1.fullSent
      let liveV := (← stateRef.get).nodeMapVersion
      let fixedV : Option Nat := if contFull then
          (match e1.v2 with
            | some v2 => if liveV == v2 then some v2 else none
            | none => none)
        else none
      if contFull then
        if let some v2 := e1.v2 then
          let sendV := match fixedV with | some v => v | none => liveV + 1
          let r ← podCmdOf e1.successor ns (HandoverDrive.armCmd e1.hid sendV)
          let res := r.bind HandoverDrive.historyResult
          if HandoverDrive.armOk res then
            IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: successor {e1.successor} armed for v{sendV} (V2 = v{v2}; {res.getD ""})"
          else
            IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: arm of {e1.hid} for v{sendV} on the successor {e1.successor} answered {res.getD "nothing"}: the ordinary promotion goes on (it advances its epoch; committed replicas rebuild)"
      let e2 ← if act == .send then do
          let v ← stateRef.modifyGet fun cur =>
            let v := match fixedV with
              | some fv => if cur.nodeMapVersion == fv then fv else cur.nodeMapVersion + 1
              | none => cur.nodeMapVersion + 1
            (v, { Handover.apply cur e1 with nodeMapVersion := v })
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: {e1.phase} map committed as v{v}"
          sent := true
          pure (Handover.recordSent e1 v)
        else pure e1
      if act == .finish then
        if e2.phase == .done then
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition} done in {now - e.startedMs} ms: {e.successor} is the master; {e.oldMaster} is a proxy"
          -- the new master still holds the WAL pin: released once the
          -- continued replicas passed S (see runWalPinReleases)
          if contOn && !e2.hid.isEmpty then
            if let some sq := e2.contSeq then
              let keysDue := if e2.committed.isEmpty then e2.prepared.map Prod.fst else e2.committed
              let due : HandoverDrive.ReleaseDue :=
                { hid := e2.hid, master := e2.successor, seq := sq, prepared := keysDue, untilMs := now + 300000 }
              releaseDueRef.modify (· ++ [due])
          continue
        -- a planned handover (the pod not Terminating) that gave up: the old
        -- master keeps serving; its delete stays refused (no marker kept)
        let oldTerminating := pods.any fun p => p.toNodeKey == e2.oldMaster && p.uid == e2.oldUid && p.terminating
        if e2.phase == .aborted && !oldTerminating && !Handover.retryable cfg e2 then
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition}: the planned handover of {e2.oldMaster} gave up ({e2.reason}); it stays the master and is not deleted"
          continue
        if e2.v1.isNone then
          IO.eprintln s!"[flare-operator] HANDOVER p{e.partition} not started ({e2.reason}); the one-map drain applies"
      else if e2.phase != .requested then
        transit := true
      -- the leader epoch the guarded write carried (casSave stamps it too)
      let ep ← epochRef.get
      let e2 := if ep > 0 && HandoverDrive.guarded contOn e2 then { e2 with leaderEpoch := ep } else e2
      out := { entries := out.entries ++ [e2] }
    led := out
    -- the node guard reads the ledger between ticks (a promote map committed
    -- here shows the old master as a proxy before the handover is done)
    handoverRef.set out
    -- the versions just sent and the other phase changes (the phase that
    -- asked for each map was saved before it was committed)
    if out != before || (← handoverDirtyRef.get) then
      -- a ledger with a continuation entry is saved by the guarded CAS
      let saved ← match out.entries.find? (HandoverDrive.guarded contOn) with
        | some gx => do
          let ok ← casSave out gx
          pure (if ok then (Except.ok () : Except String Unit) else .error "the guarded status write did not complete")
        | none => Bridge.writeHandovers crName ns out
      match saved with
      | .ok _ => handoverDirtyRef.set false
      | .error e =>
        handoverDirtyRef.set true
        IO.eprintln s!"[flare-operator] WARNING: could not persist the handover ledger ({e}); will retry: {out.summary}"
    if sent then
      let _ ← publish "handover"
      -- a promotion published: the partition Service goes to the new master
      -- now, not a pass later (local kind 2026-10-28: per-request clients got
      -- ECONNREFUSED for ~1.3 s after the old master's preStop ended)
      if !routed && out.entries.any (fun x => x.phase == .promoting && x.v2.isSome) then
        route
        routed := true
    if !transit || now >= bound then break
  handoverRef.set out
  handoverActiveRef.set (out.entries.any fun e => e.phase != .aborted)
  return Handover.blockedKeys out ++ Handover.drainHeldKeys out

initialize rollingStablePassesRef : IO.Ref Nat ← IO.mkRef 0
initialize rollingLastRef : IO.Ref String ← IO.mkRef ""


end FlareOperator
