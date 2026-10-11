/-
  Migration/Controller.lean — IO glue around the pure migration FSM.

  Once per reconcile tick the SOURCE cluster's operator (and only it: a
  FlareMigration is acted on by the operator whose --cluster-name equals
  spec.source) does:

    read CR → gather observations → migStep (pure, proven gates) →
    execute the single returned action → patch status.

  Every action is idempotent, so a crash between "execute" and "patch
  status" merely repeats the action next tick. `paused` freezes the loop
  (proven), `abort` rolls back by deleting everything carrying the
  migration's label, and the two destructive transitions (cutover, source
  retirement) sit behind explicit spec approvals (proven).
-/

import FlareOperator.Migration.Types
import FlareOperator.Migration.Provision
import FlareOperator.K8s.Bridge
import FlareOperator.Kubectl

namespace FlareOperator.Migration.Controller

open FlareOperator.Migration
open FlareOperator.Migration.Provision
open FlareOperator.K8s
open FlareOperator.K8s.Bridge
open FlareOperator.Kubectl

private def containsSubstr (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length > 1

/-! ## CR read / status write -/

structure MigCR where
  name : String
  spec : MigSpec
  phase : MigPhase
  convergedTicks : Nat
  /-- status.attemptBaseline: the source masters' counters read at the tick
      that enabled duplication (before it), serialized. -/
  attemptBaseline : String := ""
  /-- status.attemptId: `<CR uid>/<hash of the baseline>`, minted with the
      baseline; a V approval names it (another attempt's approval is
      refused). -/
  attemptId : String := ""
  uid : String := ""
  /-- status.forwardApprovalConsumed (one use). -/
  consumedApproval : String := ""

private def parseMigJson (j : Lean.Json) : Option MigCR := do
  let name ← (j.getObjVal? "metadata" |>.toOption) >>= fun m =>
    (m.getObjVal? "name" |>.toOption) >>= fun n => n.getStr?.toOption
  let spec ← j.getObjVal? "spec" |>.toOption
  let source ← (spec.getObjVal? "source" |>.toOption) >>= (·.getStr?.toOption)
  let targetObj ← spec.getObjVal? "target" |>.toOption
  let targetName ← (targetObj.getObjVal? "name" |>.toOption) >>= (·.getStr?.toOption)
  let getNat (o : Lean.Json) (k : String) (d : Nat) : Nat :=
    (o.getObjValD k |>.getNat?.toOption).getD d
  let getBool (o : Lean.Json) (k : String) : Bool :=
    (o.getObjValD k |>.getBool?.toOption).getD false
  let getStr (o : Lean.Json) (k : String) (d : String) : String :=
    (o.getObjValD k |>.getStr?.toOption).getD d
  let status := j.getObjValD "status"
  return {
    name := name
    spec := {
      source := source
      target := {
        name := targetName
        partitions := getNat targetObj "partitions" 1
        replicas := getNat targetObj "replicas" 2
        persistenceSize := getStr targetObj "persistenceSize" "10Gi"
        drainSeconds := getNat targetObj "drainSeconds" 60
      }
      paused := getBool spec "paused"
      approveForward := getBool spec "approveForward"
      forwardApproval := getStr spec "forwardApproval" ""
      approveCutover := getBool spec "approveCutover"
      approveRetire := getBool spec "approveRetire"
      abort := getBool spec "abort"
      externalService := getStr spec "externalService" ""
    }
    phase := ((status.getObjValD "phase" |>.getStr?.toOption).bind MigPhase.fromString).getD .Pending
    convergedTicks := getNat status "convergedTicks" 0
    attemptBaseline := getStr status "attemptBaseline" ""
    attemptId := getStr status "attemptId" ""
    consumedApproval := getStr status "forwardApprovalConsumed" ""
    uid := ((j.getObjVal? "metadata" |>.toOption) >>= fun m =>
      (m.getObjVal? "uid" |>.toOption) >>= fun u => u.getStr?.toOption).getD ""
  }

/-- List FlareMigrations in the namespace whose spec.source is `crName`. -/
def listMigrations (crName ns : String) : IO (List MigCR) := do
  match ← kubectl ["get", "flaremigrations", "-n", ns, "-o", "json"] with
  | .error _ => return []
  | .ok out =>
    match Lean.Json.parse out with
    | .error _ => return []
    | .ok j =>
      let items := (j.getObjValD "items").getArr?.toOption.getD #[]
      return items.toList.filterMap parseMigJson |>.filter (·.spec.source == crName)

def patchStatus (mig : MigCR) (ns : String) (phase : MigPhase)
    (obs : MigObs) (message : String) (baseline attemptId consumed : String) : IO Unit := do
  let progress := s!"{obs.targetKeys}/{obs.sourceKeys} keys on target"
  let esc := fun (x : String) => (Lean.Json.str x).compress
  let patch := s!"\{\"status\":\{\"phase\":\"{phase.toString}\",\"message\":{esc message},\"progress\":\"{progress}\",\"sourceKeys\":{obs.sourceKeys},\"targetKeys\":{obs.targetKeys},\"convergedTicks\":{obs.convergedTicks},\"attemptBaseline\":{esc baseline},\"attemptId\":{esc attemptId},\"forwardApprovalConsumed\":{esc consumed}}}"
  match ← kubectl ["patch", "flaremigration", mig.name, "-n", ns,
                   "--subresource=status", "--type=merge", "-p", patch] with
  | .error e => IO.eprintln s!"[migration] warning: status patch failed: {e}"
  | .ok _ => pure ()

/-! ## Observations -/

/-- All partition masters (podName) of a cluster, from its node-map CM. -/
private def clusterMasters (cluster ns : String) : IO (List String) := do
  match ← kubectl ["get", "configmap", s!"{cluster}-node-map", "-n", ns,
                   "-o", "jsonpath={.data.nodeMap}"] with
  | .error _ => return []
  | .ok data =>
    let state := FlareClusterState.fromNodeMapData data
    return state.nodeMap.filterMap fun (key, n) =>
      if n.role == FlareRole.Master && n.state == FlareState.Active then
        some ((key.splitOn ".").headD key)
      else none

/-- Target readiness: node map has exactly `partitions` Active masters and
    `partitions*replicas` Active entries in total. -/
private def targetReady (t : MigTargetSpec) (ns : String) : IO Bool := do
  match ← kubectl ["get", "configmap", s!"{t.name}-node-map", "-n", ns,
                   "-o", "jsonpath={.data.nodeMap}"] with
  | .error _ => return false
  | .ok data =>
    let state := FlareClusterState.fromNodeMapData data
    let entries := state.nodeMap
    let masters := entries.filter (fun kv =>
      kv.2.role == FlareRole.Master && kv.2.state == FlareState.Active)
    let active := entries.filter (fun kv => kv.2.state == FlareState.Active)
    return masters.length == t.partitions && active.length ≥ t.partitions * t.replicas

/-- Sum curr_items over a cluster's partition masters. Returns none when any
    master is unreadable (so a blip never counts as "converged at 0"). -/
private def totalMasterKeys (cluster ns : String) : IO (Option Nat) := do
  let masters ← clusterMasters cluster ns
  if masters.isEmpty then return none
  let mut total := 0
  for pod in masters do
    match ← queryPodStats pod ns "stats" with
    | .error _ => return none
    | .ok out =>
      let v := out.splitOn "\n" |>.findSome? fun line =>
        let t := line.trim.replace "\r" ""
        if t.startsWith "STAT curr_items " then
          (t.splitOn " ").getLast?.bind (·.toNat?)
        else none
      match v with
      | none => return none
      | some n => total := total + n
  return some total

/-- One source master's gate counters; `none` when anything is unreadable. -/
private def srcCountersOf (pod ns : String) : IO (Option SrcCounters) := do
  let uid ← match ← kubectl ["get", "pod", pod, "-n", ns, "-o", "jsonpath={.metadata.uid}"] with
    | .ok u => pure u.trim
    | .error _ => pure ""
  if uid.isEmpty then return none
  match ← queryPodStats pod ns "stats" with
  | .error _ => return none
  | .ok out =>
    let lines := (out.splitOn "\n").map (fun l => l.trim.replace "\r" "")
    if !lines.contains "END" then return none
    let stat := fun (name : String) => lines.findSome? fun t =>
      if t.startsWith s!"STAT {name} " then some (t.drop s!"STAT {name} ".length).trim else none
    let nat := fun (name : String) => (stat name).bind (·.toNat?)
    -- every cluster_replication[...] counter that means a write did not land
    let crLoss := lines.foldl (fun acc t =>
      if t.startsWith "STAT cluster_replication[" then
        let inner := ((t.drop "STAT cluster_replication[".length).splitOn "]").headD ""
        let v := ((t.splitOn " ").getLast?.bind (·.toNat?)).getD 0
        if inner.startsWith "forward_dropped_" || inner.startsWith "forward_failed_"
            || inner.startsWith "forward_missing_" || inner == "seed_failed" then acc + v else acc
      else acc) 0
    match nat "time", nat "uptime", nat "proxy_write_dropped", stat "cluster_replication" with
    | some t, some up, some dropped, some rep =>
      return some {
        pod, podUid := uid, boot := t - up, replicating := rep == "on"
        loss := dropped + crLoss
        seedCompleted := ((stat "cluster_replication[seed_completed]").bind (·.toNat?)).getD 0
        seedState := (stat "cluster_replication_seed").getD "none" }
    | _, _, _, _ => return none

/-- One partition master's identity and position, read the way V binds it
    (scripts/flare_verify_copy.py node_binding), plus its clock. -/
private def nodeIdentOf (pod ns : String) : IO (Option (NodeIdent × Nat)) := do
  let uid ← match ← kubectl ["get", "pod", pod, "-n", ns, "-o", "jsonpath={.metadata.uid}"] with
    | .ok u => pure u.trim
    | .error _ => pure ""
  if uid.isEmpty then return none
  match ← queryPodStats pod ns "stats" with
  | .error _ => return none
  | .ok out =>
    let lines := (out.splitOn "\n").map (fun l => l.trim.replace "\r" "")
    if !lines.contains "END" then return none
    let stat := fun (name : String) => lines.findSome? fun t =>
      if t.startsWith s!"STAT {name} " then some (t.drop s!"STAT {name} ".length).trim else none
    let epoch := match stat "rocksdb_rebuilt_from_epoch" with
      | some e => if e.isEmpty then stat "rocksdb_source_epoch" else some e
      | none => stat "rocksdb_source_epoch"
    match (stat "time").bind (·.toNat?), (stat "uptime").bind (·.toNat?),
          stat "rocksdb_master_id", stat "rocksdb_copy_id", stat "rocksdb_latest_sequence_number" with
    | some t, some up, some mid, some copy, some seq =>
      return some ({ pod, podUid := uid, boot := t - up, masterId := mid, copyId := copy,
                     epoch := epoch.getD "", seq }, t)
    | _, _, _, _, _ => return none

/-- Identities of every partition master of a cluster and the largest clock;
    `none` when any is unreadable or there is no master. -/
def clusterIdents (cluster ns : String) : IO (Option (List NodeIdent × Nat)) := do
  let masters ← clusterMasters cluster ns
  if masters.isEmpty then return none
  let mut out : List NodeIdent := []
  let mut now := 0
  for pod in masters do
    match ← nodeIdentOf pod ns with
    | none => return none
    | some (n, t) => out := out ++ [n]; now := max now t
  return some (out, now)

/-- Counters of every source partition master; `none` if any is unreadable
    or there is no master. -/
def sourceCounters (crName ns : String) : IO (Option (List SrcCounters)) := do
  let masters ← clusterMasters crName ns
  if masters.isEmpty then return none
  let mut out : List SrcCounters := []
  for pod in masters do
    match ← srcCountersOf pod ns with
    | none => return none
    | some c => out := out ++ [c]
  return some out

def gatherObs (mig : MigCR) (crName ns : String) : IO (MigObs × Option (List SrcCounters)) := do
  let ready ← targetReady mig.spec.target ns
  let srcKeys ← totalMasterKeys crName ns
  let tgtKeys ← totalMasterKeys mig.spec.target.name ns
  let counters ← sourceCounters crName ns
  let baseline := (parseBaseline mig.attemptBaseline).getD []
  -- identities only where an approval can be checked (switch, post-apply)
  let idents? := mig.phase == .Duplicating || mig.phase == .Forwarding
  let srcId ← if idents? then clusterIdents crName ns else pure none
  let dstId ← if idents? then clusterIdents mig.spec.target.name ns else pure none
  let forwardApplied ← do
    match ← readFlaredExtraConf crName ns with
    | .ok conf => pure (containsSubstr conf "cluster-replication-mode = forward")
    | .error _ => pure false
  return ({
    targetReady := ready
    sourceKeys := srcKeys.getD 0
    targetKeys := tgtKeys.getD 0
    convergedTicks := nextConvergedTicks mig.phase mig.convergedTicks srcKeys tgtKeys
    sourceForwardApplied := forwardApplied
    seedCompleted := seedCompletedSince baseline counters
    loss := lossVerdict baseline counters
    attemptId := mig.attemptId
    consumedApproval := mig.consumedApproval
    srcIdent := srcId.map (·.1)
    dstIdent := dstId.map (·.1)
    now := srcId.map (·.2)
  }, counters)

/-! ## Actions -/

private def buildPlan (mig : MigCR) (crName ns : String) : IO (Except String TargetPlan) := do
  -- flared image: whatever the live source StatefulSet runs
  let flaredImage ← do
    match ← kubectl ["get", "statefulset", s!"{crName}-nodes", "-n", ns,
                     "-o", "jsonpath={.spec.template.spec.containers[0].image}"] with
    | .ok img => pure img.trim
    | .error e => return .error s!"cannot read source StatefulSet image: {e}"
  -- operator image + serviceAccount: this very pod's
  let hostname := (← IO.getEnv "HOSTNAME").getD ""
  let operatorImage ← do
    match ← kubectl ["get", "pod", hostname, "-n", ns,
                     "-o", "jsonpath={.spec.containers[0].image}"] with
    | .ok img => pure img.trim
    | .error e => return .error s!"cannot read own operator image: {e}"
  let sa ← do
    match ← kubectl ["get", "pod", hostname, "-n", ns,
                     "-o", "jsonpath={.spec.serviceAccountName}"] with
    | .ok s => pure s.trim
    | .error e => return .error s!"cannot read own serviceAccount: {e}"
  -- helm release owning this operator (empty when not helm-managed, e.g. E2E):
  -- baked into the target resources as adoption metadata so the eventual
  -- values switch adopts them instead of erroring on ownership metadata.
  let helmRelease ← do
    match ← kubectl ["get", "pod", hostname, "-n", ns,
                     "-o", "jsonpath={.metadata.labels.app\\.kubernetes\\.io/instance}"] with
    | .ok s => pure (if s.trim.isEmpty then none else some s.trim)
    | .error _ => pure (none : Option String)
  -- rocksdb tuning: inherited from the source CR
  let rocksdb ← do
    match ← getFlareCluster crName ns with
    | .ok crd => pure crd.spec.rocksdb
    | .error _ => pure {}
  return .ok {
    migName := mig.name
    ns := ns
    helmRelease := helmRelease
    targetName := mig.spec.target.name
    partitions := mig.spec.target.partitions
    replicas := mig.spec.target.replicas
    persistenceSize := mig.spec.target.persistenceSize
    drainSeconds := mig.spec.target.drainSeconds
    flaredImage := flaredImage
    operatorImage := operatorImage
    serviceAccount := sa
    rocksdb := rocksdb
  }

private def applyManifest (yaml : String) : IO (Except String Unit) := do
  match ← kubectlApplyManifest yaml with
  | .error e => return .error e
  | .ok _ => return .ok ()

private def execAction (mig : MigCR) (crName ns : String) (act : MigAction)
    : IO (Except String String) := do
  let target := mig.spec.target.name
  match act with
  | .none => return .ok ""
  | .provisionTarget =>
    match ← buildPlan mig crName ns with
    | .error e => return .error e
    | .ok plan =>
      for m in allManifests plan do
        match ← applyManifest m with
        | .error e => return .error s!"target provisioning failed: {e}"
        | .ok () => pure ()
      -- SAF-09: provisioning IS the decision to build a new cluster, so it
      -- approves the target's first build — bound to the target
      -- FlareCluster's own UID (a recreated CR is not approved).
      match ← kubectl ["get", "flarecluster", target, "-n", ns, "-o", "jsonpath={.metadata.uid}"] with
      | .ok uid =>
        if !uid.trim.isEmpty then
          discard <| kubectl ["annotate", "flarecluster", target, "-n", ns, "--overwrite",
            s!"flare.gree.net/first-build-approved={uid.trim}"]
      | .error e => IO.eprintln s!"[flare-operator] migration: could not approve the first build of {target} ({e}); its operator will wait for approval"
      return .ok s!"target cluster {target} provisioned ({plan.partitions}p x {plan.replicas}r, image {plan.flaredImage})"
  | .startDuplicate =>
    let dest := s!"{target}-nodes.{ns}.svc.cluster.local"
    let patch := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{dest}\",\"port\":12121,\"mode\":\"duplicate\",\"concurrency\":2}}}"
    match ← kubectl ["patch", "flarecluster", crName, "-n", ns, "--type=merge", "-p", patch] with
    | .error e => return .error s!"enable duplicate failed: {e}"
    | .ok _ => return .ok s!"duplicating {crName} -> {dest}"
  | .switchForward =>
    let patch := "{\"spec\":{\"clusterReplication\":{\"mode\":\"forward\"}}}"
    match ← kubectl ["patch", "flarecluster", crName, "-n", ns, "--type=merge", "-p", patch] with
    | .error e => return .error s!"switch to forward failed: {e}"
    | .ok _ => return .ok "source switched to mode=forward"
  | .doCutover =>
    if mig.spec.externalService.isEmpty then
      return .ok "no externalService configured; cutover is a marker only"
    else
      let patch := s!"\{\"spec\":\{\"selector\":\{\"app\":\"flare\",\"cluster\":\"{target}\"}}}"
      match ← kubectl ["patch", "service", mig.spec.externalService, "-n", ns,
                       "--type=merge", "-p", patch] with
      | .error e => return .error s!"cutover selector flip failed: {e}"
      | .ok _ => return .ok s!"external Service {mig.spec.externalService} now selects cluster={target}"
  | .doRetire =>
    -- PVCs are deliberately left behind (last-resort recovery material).
    let _ ← kubectl ["delete", "statefulset", s!"{crName}-nodes", "-n", ns, "--ignore-not-found"]
    let _ ← kubectl ["delete", "flarecluster", crName, "-n", ns, "--ignore-not-found"]
    -- Self-documenting handoff: the ONE remaining manual step is the GitOps
    -- values switch; everything else (helm adoption metadata, provisioned-
    -- operator retirement) is already automatic. Shown in `kubectl get fmig`.
    return .ok s!"source {crName} retired (PVCs kept). NEXT: set clusterName/cluster.name={target} (+partitions/replicas) in the helm values and upgrade; the provisioned {target}-operator then retires itself"
  | .doAbort =>
    -- stop the stream first, then delete everything the migration created
    let patch := "{\"spec\":{\"clusterReplication\":{\"enabled\":false}}}"
    let _ ← kubectl ["patch", "flarecluster", crName, "-n", ns, "--type=merge", "-p", patch]
    let sel := s!"flare.gree.net/migration={mig.name}"
    let _ ← kubectl ["delete", "statefulset,deployment,service,configmap,flarecluster",
                     "-n", ns, "-l", sel, "--ignore-not-found"]
    return .ok s!"aborted: replication disabled, target resources ({sel}) deleted (target PVCs kept)"

/-! ## Tick entry point -/

/-- Run one migration tick for every FlareMigration sourcing from `crName`.
    Called from the operator's leader loop. Best-effort: errors are surfaced
    in the CR status and retried next tick. -/
def tick (crName ns : String) : IO Unit := do
  for mig in ← listMigrations crName ns do
    if mig.phase.terminal && !mig.spec.abort then
      pure ()  -- nothing to do, and don't spam status
    else
      let (obs, counters) ← gatherObs mig crName ns
      let (phase', action) := migStep mig.spec mig.phase obs
      let msg ← do
        match ← execAction mig crName ns action with
        | .ok m => pure m
        | .error e =>
          IO.eprintln s!"[migration] {mig.name}: action failed: {e}"
          pure s!"action failed (will retry): {e}"
      if phase' != mig.phase || action != .none then
        IO.eprintln s!"[migration] {mig.name}: {mig.phase.toString} -> {phase'.toString} ({repr action}) {msg}"
      -- A failed action must not advance the phase, or the FSM skips work
      -- (e.g. Provisioning marked done with nothing created). Stay put and
      -- retry next tick; only publish the observation refresh.
      let publishPhase := if msg.startsWith "action failed" then mig.phase else phase'
      -- The attempt baseline is read in the tick that enables duplication,
      -- BEFORE the enable, and kept once recorded (a retried enable must not
      -- move it past writes already forwarded). Unreadable → empty → the
      -- loss verdict stays Unknown for this attempt (held; recreate it).
      let baseline :=
        if action == .startDuplicate && mig.attemptBaseline.isEmpty then
          (counters.map serializeBaseline).getD ""
        else mig.attemptBaseline
      -- the attempt id is minted with the baseline and never changes for
      -- this CR's attempt; a V approval must name it
      let attemptId :=
        if mig.attemptId.isEmpty && action == .startDuplicate then
          s!"{mig.uid}/{(hash baseline).toNat}"
        else mig.attemptId
      let msg := if msg.isEmpty && mig.spec.abort && mig.phase.abortRefused && !mig.phase.terminal then
          "abort REFUSED: the forward switch was issued — the target holds acknowledged writes the source does not; deleting it would lose them (RUNBOOK #migration-forward-abort)"
        else msg
      let msg := if msg.isEmpty && publishPhase == .Duplicating then
          ((forwardHold mig.spec obs).map (s!"holding before the forward switch: " ++ ·)).getD ""
        else msg
      let msg := if msg.isEmpty && publishPhase == .Forwarding then
          ((forwardAppliedHold mig.spec obs).map (s!"holding in Forwarding: " ++ ·)).getD ""
        else msg
      if publishPhase == .Duplicating && action == .none && phase' == mig.phase then
        if let some why := forwardHold mig.spec obs then
          if mig.convergedTicks < convergenceDwellTicks && obs.convergedTicks ≥ convergenceDwellTicks then
            IO.eprintln s!"[migration] {mig.name}: counts converged but the forward switch is held: {why}"
      -- one use: the approval a switch was issued with is recorded with the
      -- phase change (a failed action does not consume it)
      let consumed :=
        if action == .switchForward && !msg.startsWith "action failed" then mig.spec.forwardApproval
        else mig.consumedApproval
      patchStatus mig ns publishPhase obs msg baseline attemptId consumed

end FlareOperator.Migration.Controller
