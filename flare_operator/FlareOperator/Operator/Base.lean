/-
  Operator/Base.lean - the shared helpers and process-wide state of the
  operator (split out of Main.lean so the handover drive and the
  reconcile loop compile as separate modules).
-/
import FlareOperator.K8s.FlareCluster
import FlareOperator.StateMachine.TopologyObservation
import FlareOperator.K8s.Bridge
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.ReplicaRepair
import FlareOperator.StateMachine.Handover
import FlareOperator.StateMachine.HandoverDrive
import FlareOperator.StateMachine.HistoryContinuation
import FlareOperator.StateMachine.Rolling
import FlareOperator.StateMachine.NodeGuard
import FlareOperator.StateMachine.NodeMove
import FlareOperator.K8s.Admission
import FlareOperator.Server.WebhookServer
import FlareOperator.StateMachine.SyncEvidence
import FlareOperator.StateMachine.StatsObservation
import FlareOperator.StateMachine.FollowEvidence
import FlareOperator.StateMachine.FailoverOrder
import FlareOperator.StateMachine.UnreachableNode
import FlareOperator.StateMachine.DuplicateMaster
import FlareOperator.StateMachine.NodeMapRecovery
import FlareOperator.Kubectl
import FlareOperator.Server.TcpServer
import FlareOperator.Server.TopologyBroadcast
import FlareOperator.Server.PublicationGate
import FlareOperator.Metrics.Prometheus
import FlareOperator.Metrics.HttpServer
import FlareOperator.Migration.Controller
import FlareOperator.Health.HealthCheck
import FlareOperator.StateMachine.SourceEligibility
import FlareOperator.StateMachine.RebuildConcurrency
import FlareOperator.StateMachine.CopyDiscardApproval
import FlareOperator.StateMachine.PromotionEvidence
import FlareOperator.StateMachine.AuthoritativeHistory

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

/-- The leader lease duration (seconds). -/
def leaseDurationSeconds : Nat := 15


-- ===========================================================================
-- CLI Argument Parsing
-- ===========================================================================

/-- Parse CLI arguments. Returns (namespace, port, reconcileInterval, clusterName). -/
def parseArgs (args : List String) : String × UInt16 × Nat × Option String :=
  let rec go (args : List String) (ns : String) (port : UInt16) (interval : Nat)
      (clusterName : Option String) : String × UInt16 × Nat × Option String :=
    match args with
    | [] => (ns, port, interval, clusterName)
    | "--namespace" :: v :: rest => go rest v port interval clusterName
    | "--port" :: v :: rest =>
      match v.toNat? with
      | some p => go rest ns p.toUInt16 interval clusterName
      | none => go rest ns port interval clusterName
    | "--reconcile-interval" :: v :: rest =>
      match v.toNat? with
      | some i => go rest ns port i clusterName
      | none => go rest ns port interval clusterName
    | "--cluster-name" :: v :: rest => go rest ns port interval (some v)
    | _ :: rest => go rest ns port interval clusterName
  go args "default" 12120 5 none

-- ===========================================================================
-- String helpers
-- ===========================================================================

/-- Check if needle is a substring of haystack. -/
def containsSubstr (haystack needle : String) : Bool :=
  let hLen := haystack.length
  let nLen := needle.length
  if nLen > hLen then false
  else
    let rec go (i : Nat) (fuel : Nat) : Bool :=
      match fuel with
      | 0 => false
      | fuel + 1 =>
        if i + nLen > hLen then false
        else if (haystack.drop i).startsWith needle then true
        else go (i + 1) fuel
    go 0 (hLen + 1)

-- ===========================================================================
-- Dead Node Detection (pure)
-- ===========================================================================

/-- Detect dead nodes: nodes in the nodeMap whose pod has completely disappeared
    from the K8s pod list.

    **Production design considerations**:

    The following nodes are EXCLUDED from dead detection:
    - Proxy / Down: already inactive; re-detecting them causes noise.
    - Prepare: actively reconstructing data from a peer.  A 100 GB dataset can
      take hours to reconstruct and the node stays in Prepare the whole time.
      Marking it dead during reconstruction would trigger an unnecessary
      failover and waste the work already done.  If the pod genuinely crashes,
      K8s will restart it and it will re-register via `node add`.

    Only Active Masters and Active Slaves are eligible for dead detection,
    because losing one of those affects data availability.

    The `pods` list comes from `kubectl get pods -l app=flare,cluster=<name>`
    and includes ALL pods (Ready or not).  A pod in CrashLoopBackOff still
    appears in this list, so its node key stays in `liveKeys` and the node is
    not prematurely marked dead.  Only a pod that has been completely deleted
    (e.g., StatefulSet scale-down, manual delete, or node eviction) disappears
    from the list and triggers dead detection.

    See ROCKSDB_REPLICATION.md §S1 (slave recovery) and §S4 (zombie master)
    for the interaction between dead detection and replication recovery. -/
def detectDeadNodes (state : FlareClusterState) (pods : List PodInfo)
    : List String :=
  let liveKeys := liveNodeKeys pods
  state.nodeMap.filter (fun (key, node) =>
    !liveKeys.contains key
    && node.role != FlareRole.Proxy
    && node.state != FlareState.Down
    && node.state != FlareState.Prepare
  ) |>.map Prod.fst

-- ===========================================================================
-- Failover Handler (pure state + IO for K8s patches)
-- ===========================================================================

/-- Handle failover: mark dead nodes Down, promote a Slave if master died.
    Pure state transition — no K8s I/O.
    Returns (newState, log messages) so the IO caller can print them. -/
def handleFailover (state : FlareClusterState) (deadKeys : List String)
    : FlareClusterState × List String :=
  deadKeys.foldl (fun (s, logs) key =>
    match s.lookupNode key with
    | none => (s, logs)
    | some node =>
      let roleName := match node.role with | .Master => "Master" | .Slave => "Slave" | .Proxy => "Proxy"
      let stateName := match node.state with | .Active => "Active" | .Prepare => "Prepare" | .Down => "Down" | .Ready => "Ready"
      let downNode := { node with state := FlareState.Down, role := FlareRole.Proxy, partition := -1,
                                  formerSlaveOf := K8sReconciler.deadSlaveOf node }
      let s' := s.addNode key downNode
      let logs := logs ++ [s!"[NodeState] {key}: {roleName}/{stateName} P{node.partition} → Proxy/Down (dead)"]
      -- If dead node was a Master, try to promote a Slave in the same partition
      if node.role == FlareRole.Master then
        let partIdx := node.partition
        match s'.partitionMap.find? (fun (idx, _) => Int.ofNat idx == partIdx) with
        | none => (s', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. No partition entry found."])
        | some (_, part) =>
          match part.slaves.head? with
          | none => (s', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. No Slave available for promotion."])
          | some slaveKey =>
            match s'.lookupNode slaveKey with
            | none => (s', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. Slave {slaveKey} not found in nodeMap."])
            | some slaveNode =>
              let promoted := { slaveNode with role := FlareRole.Master, state := FlareState.Active, balance := 100 }
              let newPart := { part with master := some slaveKey, slaves := part.slaves.tail }
              let s'' := (s'.addNode slaveKey promoted).setPartition partIdx.toNat newPart
              (s'', logs ++ [s!"[RECONCILER] Master for P{partIdx} ({key}) is gone. Promoting Slave {slaveKey} to Master."])
      else (s', logs)
  ) (state, [])

-- ===========================================================================
-- Service Routing
-- ===========================================================================

/-- Extract pod name from FQDN (e.g., "pod-0.svc.ns.cluster.local" -> "pod-0").
    Kubernetes selector values must be ≤63 chars, so we can't use full FQDNs. -/
def extractPodName (fqdn : String) : String :=
  match fqdn.splitOn "." with
  | podName :: _ => podName
  | [] => fqdn

/-- One numeric value out of a flared `stats` reply (`STAT <key> <value>`). -/
def statNat (out key : String) : Option Nat :=
  (out.splitOn "\n").findSome? fun line =>
    match (line.trim.splitOn " ").filter (· != "") with
    | ["STAT", k, v] => if k == key then v.trim.toNat? else none
    | _ => none

/-- The rest of a `STAT key ...` line (values that contain spaces, e.g. a
    reason). -/
def statRest (out key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    let t := line.trim.replace "\r" ""
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

/-- A flared `stats` reply is complete only if the END terminator arrived;
    a reply cut short (timeout, reset) lacks it and must not be read as "the
    backend has no such field". -/
def statsReplyComplete (out : String) : Bool :=
  (out.splitOn "\n").any fun l => (l.trim.replace "\r" "") == "END"

def hasSubstr (h needle : String) : Bool := (h.splitOn needle).length > 1

/-- One string value out of a flared `stats` reply. -/
def statStr (out key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    match (line.trim.splitOn " ").filter (· != "") with
    | ["STAT", k, v] => if k == key then some v.trim else none
    | _ => none

/-- SAF-10c readings from a flared `stats` reply (StateMachine/FollowEvidence).
    Every missing key stays `none`; the node's own clock (`STAT time`) is
    read from the SAME reply as the observation time it is compared with. -/
def followReadingFrom (out : String) : FollowEvidence.Reading :=
  { complete := statsReplyComplete out,
    enabled := (statNat out "repl_follow_enabled").map (· == 1),
    state := statStr out "repl_follow_state",
    sourceEpoch := statStr out "repl_follow_source_epoch",
    appliedLsn := statNat out "repl_applied_lsn",
    sourceLsn := statNat out "repl_source_lsn",
    sourceObservedAt := statNat out "repl_source_lsn_observed_at",
    lastProgressAt := statNat out "repl_last_progress_at",
    nodeTime := statNat out "time",
    lastReason := statStr out "repl_follow_last_reason",
    readSourceState := statStr out "repl_read_source_state",
    readSourceReason := statRest out "repl_read_source_reason",
    bootId := statNat out "reconstruction_boot_id" }

def masterReadingFrom (out : String) : FollowEvidence.MasterReading :=
  { complete := statsReplyComplete out,
    epoch := statStr out "rocksdb_source_epoch",
    head := statNat out "rocksdb_latest_sequence_number" }

def followBoundsFromEnv : IO FollowEvidence.Bounds := do
  let envNat : String → Nat → IO Nat := fun name dflt => do
    pure (((← IO.getEnv name).bind (·.toNat?)).getD dflt)
  pure { freshSecs := ← envNat "FLARE_FOLLOW_FRESH_SECS" 5,
         readLag := ← envNat "FLARE_FOLLOW_READ_LAG" 1000,
         promoteLag := ← envNat "FLARE_FOLLOW_PROMOTE_LAG" 100,
         failoverMaxLag := ← envNat "FLARE_FOLLOW_FAILOVER_MAX_LAG" 100000 }

/-- SAF-10c tracker between ticks: mode memory, tick counter, this tick's
    classification (consumed by the commit path and the delete gate) and the
    last logged judgement per node. -/
instance : Inhabited FollowEvidence.Tracker := ⟨{}⟩
initialize followRef : IO.Ref FollowEvidence.Tracker ← IO.mkRef {}
/-- The follow mode the spec asks for (`spec.rocksdb.replFollowEnabled`,
    unset = off), refreshed every pass from the CR; `none` until read. -/
initialize followDesiredRef : IO.Ref (Option Bool) ← IO.mkRef none
/-- TEST SEAM (`FLARE_TEST_CONF_WRITE_DELAY_SECONDS`): the extra.conf content
    whose write is being held back, and since when (monotonic ms). Simulates
    a slow ConfigMap propagation deterministically: the pods keep the OLD
    file while the operator already wants the new mode. -/
initialize confWriteDelayRef : IO.Ref (Option (String × Nat)) ← IO.mkRef none

/-- SAF-09: the highest node-map version known to be in the persisted
    `{cr}-node-map` ConfigMap (the durable authority record). Set from the
    reload at startup and after every successful write; a version above it
    is persisted before it is sent (TopologyBroadcast.persistedCovers). -/
initialize persistedVersionRef : IO.Ref Nat ← IO.mkRef 0

/-- Monotonic time (ms) at which this process entered leader mode; the
    startup grace is measured from it in wall-clock seconds. -/
initialize leaderSinceMsRef : IO.Ref Nat ← IO.mkRef 0

/-- SAF-09: the Lease already carries the persisted-map marker. -/
initialize nodeMapMarkedRef : IO.Ref Bool ← IO.mkRef false

/-- SAF-09: the first-build approval was read back as absent (consumed). -/
initialize approvalConsumedRef : IO.Ref Bool ← IO.mkRef false

/-- SAF-08: the incarnation (pod UID, flared container restart count) of
    every flared pod as observed at this pass's pod list, by node key. -/
initialize podIdentityRef : IO.Ref (List (String × (String × Option Nat))) ← IO.mkRef []

/-- SAF-08: this pass's promotion was aborted because a promoted node's
    incarnation changed after it was observed; nothing from this pass is
    committed or persisted. Reset at the start of every pass. -/
initialize promotionAbortedRef : IO.Ref Bool ← IO.mkRef false
/-- The successor(s) of an ordered handover whose drain was proven clean,
    set only while the handover commits its promotion (commitChecked). -/
initialize handoverProvenRef : IO.Ref (List String) ← IO.mkRef []

/-- Copy retention §10: the assignments held last time (logged on change). -/
initialize rebuildHeldRef : IO.Ref (List String) ← IO.mkRef []
/-- Decision 2026-10-07 (1): the candidates whose R3 reading was UNKNOWN on
    THIS pass (read failed or incomplete). No promotion of them is committed. -/
initialize r3WithheldRef : IO.Ref (List String) ← IO.mkRef []
/-- Decision 2026-10-08: this pass's promotion evidence per candidate — its
    class (by reason) and what it was read from (pod UID, boot id, copy id). -/
initialize promotionEvidenceRef : IO.Ref (List (String × PromotionEvidence.Class × PromotionEvidence.Binding)) ← IO.mkRef []
/-- Whether this pass read and classified the candidates (a promotion-risk pass). -/
initialize promotionRiskPassRef : IO.Ref Bool ← IO.mkRef false
/-- What the operator observed of each candidate on that pass (to classify it again at commit). -/
initialize promotionObservedRef : IO.Ref (List (String × PromotionEvidence.Observed)) ← IO.mkRef []
/-- FLARE_TEST_STALE_FIRST_BUILD_EVIDENCE was applied (once per process). -/
initialize staleFirstBuildSeamUsedRef : IO.Ref Bool ← IO.mkRef false
/-- Copy retention §10 (decision 2026-10-07, item 3): rebuilding nodes whose
    stats say parked with nothing in flight (no transfer, serve or switch). -/
initialize parkedIdleRef : IO.Ref (List String) ← IO.mkRef []
/-- When each node was last resumed (monotonic ms): at most once per 5 min,
    so a node whose cause did not change is not resumed every pass. -/
initialize resumedAtRef : IO.Ref (List (String × Nat)) ← IO.mkRef []

/-- The masterless CRITICAL's last line per partition (summary, ms): logged
    on change or every 60 s, not every pass (decision 2026-10-16). -/
initialize masterlessLogRef : IO.Ref (List (Nat × (String × Nat))) ← IO.mkRef []
/-- (live, data-bearing, read-empty) keys the last reconcile pass's refill saw. -/
initialize refillSeenRef : IO.Ref (List String × List String × List String) ← IO.mkRef ([], [], [])
/-- SAF-08: a successor the empty-master self-heal validated before deleting
    the master, pinned with its incarnation for the drain that follows:
    (node key, (uid, restarts), passes left). -/
initialize pinnedSuccessorRef : IO.Ref (List (String × (String × Option Nat) × Nat)) ← IO.mkRef []

/-- SAF-09 evidence of a previous incarnation (StateMachine/NodeMapRecovery):
    the Lease's persisted-map marker and each flared pod's own node map
    version and item count. A failed or incomplete observation stays
    unobserved (never 0). Also returns whether a first build of THIS
    FlareCluster is approved (annotation equal to its metadata.uid). -/
def nodeMapHistory (crName ns leaseName : String) : IO (NodeMapRecovery.History × Bool) := do
  let marker : Except String (Option String) ← match ← kubectl ["get", "lease", leaseName, "-n", ns, "-o",
      "jsonpath={.metadata.annotations.flare\\.gree\\.net/node-map-persisted}"] with
    | .ok v => pure (.ok (if v.trim.isEmpty then none else some v.trim))
    | .error e =>
      IO.eprintln s!"[flare-operator] node map history: the Lease could not be read ({e})"
      pure (.error e)
  -- uid | approval | partitions | replicas, in one read
  let (expected, approved, clusterMissing) ← match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o",
      "jsonpath={.metadata.uid}|{.metadata.annotations.flare\\.gree\\.net/first-build-approved}|{.spec.partitions}|{.spec.replicas}"] with
    | .ok out =>
      match out.trim.splitOn "|" with
      | [uid, appr, p, r] =>
        pure ((p.trim.toNat?.getD 0) * (r.trim.toNat?.getD 0), !uid.trim.isEmpty && appr.trim == uid.trim, false)
      | _ =>
        IO.eprintln s!"[flare-operator] node map history: unexpected FlareCluster read [{out.trim}]"
        pure (0, false, false)
    | .error e =>
      let missing : Bool := decide ((e.splitOn "(NotFound)").length > 1)
      IO.eprintln s!"[flare-operator] node map history: FlareCluster {crName} {if missing then "does not exist" else s!"could not be read ({e})"}"
      pure (0, false, missing)
  match ← Bridge.listFlaredPodsE crName ns with
  | .error e =>
    IO.eprintln s!"[flare-operator] node map history: flared pods could not be listed ({e})"
    return (NodeMapRecovery.history marker false [] expected clusterMissing, approved)
  | .ok pods =>
    let mut ev : List NodeMapRecovery.PodEvidence := []
    for p in pods do
      match ← Bridge.queryPodStats p.name ns "stats" with
      | .ok out =>
        ev := ev ++ [{ name := p.name, ready := p.ready,
                       nodeMapVersion := statNat out "node_map_version",
                       currItems := statNat out "curr_items" }]
      | .error _ => ev := ev ++ [{ name := p.name, ready := p.ready }]
    let h := NodeMapRecovery.history marker true ev expected clusterMissing
    IO.eprintln s!"[flare-operator] node map history: {repr h}; first build approved for this FlareCluster: {approved}"
    return (h, approved)

/-- Record on the Lease that a node map has been persisted, and consume a
    first-build approval, each retried on every persist until it is
    CONFIRMED. A later leader that finds the ConfigMap missing reads the
    marker as "the cluster ran before" (SAF-09); an approval left behind
    would re-authorize a fresh start after a later loss, so "consumed" means
    the annotation was read back as absent, not that a removal was sent. -/
def markNodeMapPersisted (crName ns : String) (version : Nat) : IO Unit := do
  if !(← nodeMapMarkedRef.get) then
    match ← kubectl ["annotate", "lease", s!"{crName}-operator-lease", "-n", ns, "--overwrite",
        s!"flare.gree.net/node-map-persisted={version}"] with
    | .ok _ => nodeMapMarkedRef.set true
    | .error e => IO.eprintln s!"[flare-operator] warning: could not mark the Lease with the persisted node map ({e}); retried on the next persist"
  if !(← approvalConsumedRef.get) then
    let readApproval : IO (Except String String) :=
      kubectl ["get", "flarecluster", crName, "-n", ns, "-o",
        "jsonpath={.metadata.annotations.flare\\.gree\\.net/first-build-approved}"]
    match ← readApproval with
    | .ok v =>
      if v.trim.isEmpty then approvalConsumedRef.set true
      else
        discard <| kubectl ["annotate", "flarecluster", crName, "-n", ns, "flare.gree.net/first-build-approved-"]
        match ← readApproval with
        | .ok v2 =>
          if v2.trim.isEmpty then
            approvalConsumedRef.set true
            IO.eprintln s!"[flare-operator] first-build approval on {crName} consumed (a node map now exists)"
          else IO.eprintln s!"[flare-operator] CRITICAL: the first-build approval on {crName} is still present after removal; it would authorize a fresh start after a later loss — retried on the next persist (RUNBOOK #node-map-lost)"
        | .error e => IO.eprintln s!"[flare-operator] warning: could not confirm the first-build approval was consumed ({e}); retried on the next persist"
    | .error e => IO.eprintln s!"[flare-operator] warning: could not read the first-build approval ({e}); retried on the next persist"

/-- When each partition was first seen without a master (monotonic ms),
    for the failover-lag hold's wait budget. Cleared once it has one. -/
initialize masterlessSinceRef : IO.Ref (List (Nat × Nat)) ← IO.mkRef []

/-- How long a partition stays masterless waiting for its ex-master when the
    only data-bearing copy left is an unfit follower
    (FLARE_FOLLOW_FAILOVER_WAIT_SECONDS, default 300; 0 = do not wait). -/
def failoverWaitSeconds : IO Nat := do
  return ((← IO.getEnv "FLARE_FOLLOW_FAILOVER_WAIT_SECONDS").bind (·.toNat?)).getD 300

/-- Update the masterless clock from the committed map and return the
    partitions whose wait is over. The pass that kills a master still sees it
    in the committed map, so the clock starts on the next pass: the hold
    lasts at least the budget. -/
def masterlessExpired (cs : FlareClusterState) (waitS : Nat) : IO (List Nat) := do
  let now ← IO.monoMsNow
  let parts := (cs.nodeMap.filterMap fun (_, n) =>
      if n.partition ≥ 0 then some n.partition.toNat
      else if n.lastMasterOf ≥ 0 then some n.lastMasterOf.toNat else none).eraseDups
  let masterless := parts.filter (fun p => !FlareOperator.Reconciler.hasMasterForPartition cs p)
  let prev ← masterlessSinceRef.get
  let next := masterless.map fun p => (p, (prev.lookup p).getD now)
  masterlessSinceRef.set next
  return (next.filter (fun (_, t0) => now - t0 ≥ waitS * 1000)).map Prod.fst

/-- Startup grace in seconds (FLARE_STARTUP_GRACE_SECONDS, default 120).
    It used to be 24 reconcile CYCLES, which stretched with slow passes to
    ~190 s in the continuous-replication suite (user decision 2026-10-02). -/
def startupGraceSeconds : IO Nat := do
  return ((← IO.getEnv "FLARE_STARTUP_GRACE_SECONDS").bind (·.toNat?)).getD 120

/-- Persist the replica-repair ledger when it changed (SC-03 / SAF-05) and
    keep the pending gauge current. Loud on failure: an unpersisted ledger is
    exactly what an operator restart would lose. -/
def persistLedger (crName ns : String) (before after : ReplicaRepair.Ledger)
    (metrics : OperatorMetrics) (dirtyRef : IO.Ref Bool) : IO Unit := do
  if before != after then
    metrics.replicaRepairsPending.set after.entries.length.toFloat
    match ← Bridge.writeRepairLedger crName ns after with
    | .ok _ => dirtyRef.set false
    | .error e =>
      -- Item 4: the in-memory ledger is already updated, so a later pass
      -- with no further change would never re-save. Mark it DIRTY; the
      -- top of every pass retries the write until it lands.
      dirtyRef.set true
      IO.eprintln s!"[flare-operator] WARNING: could not persist the replica repair ledger ({e}); marked unsaved and will retry every pass — an operator restart before that lands would lose: {after.summary}"

-- ═══════════════════════════════════════════════════════════════════════
-- ORDERED HANDOVER of a planned master switch (flare-lossless-handover;
-- StateMachine/Handover.lean, flare-ci-inputs/decisions/HANDOVER-DESIGN-rc68.md)
-- ═══════════════════════════════════════════════════════════════════════

initialize handoverRef : IO.Ref Handover.Ledger ← IO.mkRef {}
/-- The successor and its recorded binding of the handover whose V2 is being
    committed now (set right before commitPromote; the ledger in
    handoverRef is written only at the end of runHandovers). -/
initialize handoverCommitBindingRef : IO.Ref (List (String × String)) ← IO.mkRef []
/-- Masters (node key, pod UID) to hand over now although their pod is not
    Terminating (review of 9756855: a delete is irreversible, so the switch
    comes first): asked by a refused delete in the node guard or by rolling.
    Pruned when the pod is another one, no longer the Active master (handed
    over), or its handover gave up. -/
initialize plannedHandoverRef : IO.Ref (List (String × String)) ← IO.mkRef []
/-- Old masters rolling asked to hand over: rolling deletes them once their
    handover is done (they are a proxy then, holding no data). -/
initialize rollingHandoverRef : IO.Ref (List (String × String)) ← IO.mkRef []
/-- The last "NO promotable successor" line per partition: a handover held
    in `requested` logs it when it changes, not on every tick (review of
    644b3b8). -/
initialize handoverHeldLogRef : IO.Ref (List (Nat × String)) ← IO.mkRef []
/-- Active masters whose pod was NOT Terminating when this pass's handover
    step read the pods. The FSM reads the pods again later in the pass; a
    master deleted in between must not be taken by the one-map drain before
    the handover has seen it (CI 40862342948, S8: the delete landed between
    the two reads and the drain promoted the successor with no handover). -/
initialize handoverSeenAliveRef : IO.Ref (Option (List String)) ← IO.mkRef none
/-- Set when the FSM left a Terminating master to the next pass's handover
    (it became Terminating after this pass's handover step): the leader loop
    starts that pass at once instead of after its interval (698d77b
    40976376890 forward-window 8: the handover started ~9 s after the delete,
    its drain then ran into the old master's SIGTERM and aborted, and the
    partition waited for the 5-minute last-resort refill). -/
initialize handoverWakeRef : IO.Ref Bool ← IO.mkRef false
initialize handoverLoadedRef : IO.Ref Bool ← IO.mkRef false
initialize handoverDirtyRef : IO.Ref Bool ← IO.mkRef false
/-- a handover is running: the leader loop does not wait the full interval -/
initialize handoverActiveRef : IO.Ref Bool ← IO.mkRef false
/-- the handover's fast loop could not renew the lease: the rest of the
    pass (FSM, rolling, the send) is skipped and the leader loop decides
    (review of 262fde9: only the fast loop stopped) -/
initialize passLeaseLostRef : IO.Ref Bool ← IO.mkRef false
/-- the node guard may judge: a full pass on the persisted map completed -/
initialize nodeGuardInitRef : IO.Ref Bool ← IO.mkRef false
/-- replicas with a replica repair pending, as of the last pass -/
initialize nodeGuardRepairRef : IO.Ref (List String) ← IO.mkRef []

/-- The partition's AUTHORITATIVE history (docs/design-authoritative-history.md),
    reloaded from its ConfigMap at every use: an operator restart or a new
    leader decides from what is persisted, never from memory. -/
initialize historyStoreRef : IO.Ref (Option AuthoritativeHistory.Store) ← IO.mkRef none
/-- The partition count the CR asks for (restore provenance: the layout a
    candidate's binding must match). -/
initialize desiredPartitionsRef : IO.Ref Nat ← IO.mkRef 0

end FlareOperator
