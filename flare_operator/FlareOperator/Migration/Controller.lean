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
      approveCutover := getBool spec "approveCutover"
      approveRetire := getBool spec "approveRetire"
      abort := getBool spec "abort"
      externalService := getStr spec "externalService" ""
    }
    phase := ((status.getObjValD "phase" |>.getStr?.toOption).bind MigPhase.fromString).getD .Pending
    convergedTicks := getNat status "convergedTicks" 0
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
    (obs : MigObs) (message : String) : IO Unit := do
  let progress := s!"{obs.targetKeys}/{obs.sourceKeys} keys on target"
  let patch := s!"\{\"status\":\{\"phase\":\"{phase.toString}\",\"message\":\"{message}\",\"progress\":\"{progress}\",\"sourceKeys\":{obs.sourceKeys},\"targetKeys\":{obs.targetKeys},\"convergedTicks\":{obs.convergedTicks}}}"
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

def gatherObs (mig : MigCR) (crName ns : String) : IO MigObs := do
  let ready ← targetReady mig.spec.target ns
  let srcKeys ← totalMasterKeys crName ns
  let tgtKeys ← totalMasterKeys mig.spec.target.name ns
  let converged : Bool := match srcKeys, tgtKeys with
    | some s, some t => decide (t ≥ s)
    | _, _ => false
  let forwardApplied ← do
    match ← readFlaredExtraConf crName ns with
    | .ok conf => pure (containsSubstr conf "cluster-replication-mode = forward")
    | .error _ => pure false
  return {
    targetReady := ready
    sourceKeys := srcKeys.getD 0
    targetKeys := tgtKeys.getD 0
    convergedTicks := if converged then mig.convergedTicks + 1 else 0
    sourceForwardApplied := forwardApplied
  }

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
      let obs ← gatherObs mig crName ns
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
      patchStatus mig ns publishPhase obs msg

end FlareOperator.Migration.Controller
