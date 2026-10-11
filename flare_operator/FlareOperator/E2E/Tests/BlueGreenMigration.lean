/-
  E2E/Tests/BlueGreenMigration.lean — FlareMigration end-to-end.

  The user story this automates (previously a hand-run sequence): shrink a
  2-partition cluster to 1 partition blue/green style —

    FlareMigration CR created
      → operator provisions the target cluster (CR/CM/Services/STS/operator)
      → source duplicates into it (dump re-hashes 2p → 1p + dual-write)
      → counts converge → held: counts, a boolean, a tampered capture, a
        stale MATCH and another attempt's MATCH are all refused
      → verification V (kind-only capture: repl_snapshot + flared
        --dump-checkpoint, comparator) MATCH bound to this attempt and the
        live masters → source flips to mode=forward
      → parks at AwaitingCutover until a human sets approveCutover
      → cutover = client Service selector flip (same Service, same IP)
      → parks again until approveRetire → source STS + CR deleted.

  Also covered: `abort` rolls a second migration back (target resources
  deleted wholesale by label) — the interruptibility half of the design.

  The FSM's gates themselves (paused freezes, cutover/retire need approval,
  no abort past cutover) are PROVEN in Migration/Types.lean; this suite
  checks the IO glue against a real cluster.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.BlueGreenMigration

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "bg-src"
  «namespace» := "flare-bg-migration"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator-bg"
  debugPod := "debug-bg"
  storageBackend := "rocksdb"
  -- the migration target copies the source CR's spec.rocksdb: the rebuild
  -- reserve must be in the CR, or the target's staged rebuilds stop
  reserveInCr := true
}

private def targetName : String := "bg-tgt"
private def migName : String := "shrink-2p-to-1p"
private def entrySvc : String := "bg-entry"
private def totalKeys : Nat := 60

private def entryServiceYaml : String :=
  s!"apiVersion: v1
kind: Service
metadata:
  name: {entrySvc}
  namespace: {cfg.«namespace»}
spec:
  selector:
    app: flare
    cluster: {cfg.name}
  ports:
    - port: {cfg.flarePort}
      targetPort: flare
      name: flare"

private def migrationYaml : String :=
  s!"apiVersion: flare.gree.net/v1alpha1
kind: FlareMigration
metadata:
  name: {migName}
  namespace: {cfg.«namespace»}
spec:
  source: {cfg.name}
  target:
    name: {targetName}
    partitions: 1
    replicas: 2
    persistenceSize: \"1Gi\"
    drainSeconds: 0
  externalService: {entrySvc}"

private def migPhase : IO String := do
  match ← kubectlGetJsonpath "flaremigration" migName cfg.«namespace» "{.status.phase}" with
  | .ok p => return p.trim
  | .error _ => return ""

private def waitForPhase (want : String) (timeoutSec : Nat) : IO Bool := do
  waitForCondition s!"migration phase {want}" timeoutSec do
    return (← migPhase) == want

/-- Local (proxy-marked) presence check of every key on one pod. -/
private def keysHeldLocally (podName : String) : IO Nat := do
  let some ip ← getPodIp podName cfg.«namespace» | return 0
  let mut present := 0
  for i in List.range totalKeys do
    let cmd := s!"printf '<e2e:0>get bg_{i}\\r\\n' | nc -w 3 {ip} {cfg.flarePort}"
    match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
    | .ok out => if containsSubstr out "VALUE" then present := present + 1
    | .error _ => pure ()
  return present

/-! ## Verification V in kind (CI only: flare_v_capture_kind.py refuses any
    other kube context) -/

private def vDir : String := "/tmp/e2e-bg-v"

private def scriptsDir : IO String := do
  if ← System.FilePath.pathExists "../scripts/flare_verify_copy.py" then return "../scripts"
  else return "scripts"

private def runProc (cmd : String) (args : List String) : IO (UInt32 × String × String) := do
  let o ← IO.Process.output { cmd, args := args.toArray }
  return (o.exitCode, o.stdout, o.stderr)

private def sourceMasters : IO (List String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  let e := parseNodeSync sync
  return [findMasterPod e 0, findMasterPod e 1].filterMap id

private def targetMaster : String := s!"{targetName}-nodes-0"

private def migField (path : String) : IO String := do
  match ← kubectlGetJsonpath "flaremigration" migName cfg.«namespace» path with
  | .ok m => return m.trim
  | .error _ => return ""

/-- Capture both sides and run the comparator. `tamper` flips one byte of the
    first VALUE in the destination capture (same length, same key count).
    Returns (exit code, verdict line, approval line or ""). -/
private def runV (tag : String) (tamper : Bool := false) : IO (Except String (UInt32 × String × String)) := do
  let sd ← scriptsDir
  let dir := s!"{vDir}/{tag}"
  let _ ← runProc "rm" ["-rf", dir]
  let srcM ← sourceMasters
  if srcM.length != 2 then return .error s!"source masters: {srcM}"
  let (c1, o1, e1) ← runProc "python3" ([s!"{sd}/flare_v_capture_kind.py", "--ns", cfg.«namespace», "--out", s!"{dir}/src"] ++ srcM)
  if c1 != 0 then return .error s!"source capture failed ({c1}): {e1.trim}"
  let (c2, o2, e2) ← runProc "python3" [s!"{sd}/flare_v_capture_kind.py", "--ns", cfg.«namespace», "--out", s!"{dir}/dst", targetMaster]
  if c2 != 0 then return .error s!"target capture failed ({c2}): {e2.trim}"
  IO.eprintln s!"# V capture {tag}: source {o1.trim}; target {o2.trim}"
  let dstDump := s!"{dir}/dst/{targetMaster}.dump"
  if tamper then
    let (ct, _, et) ← runProc "python3" ["-c",
      "import sys;p=sys.argv[1];b=bytearray(open(p,'rb').read());i=b.index(b'\\r\\n')+2;b[i]^=1;open(p,'wb').write(b)", dstDump]
    if ct != 0 then return .error s!"tamper failed: {et}"
  let att ← migField "{.status.attemptId}"
  let srcArgs := srcM.foldl (fun acc p => acc ++ ["--src-dump", s!"{dir}/src/{p}.dump"]) []
  let (c, _, err) ← runProc "python3" ([s!"{sd}/flare_verify_copy.py"] ++ srcArgs ++
    ["--dst-dump", dstDump, "--src-pre", s!"{dir}/src/pre.json", "--src-post", s!"{dir}/src/post.json",
     "--dst-pre", s!"{dir}/dst/pre.json", "--dst-post", s!"{dir}/dst/post.json",
     "--attempt-baseline", s!"{vDir}/baseline/stats.json", "--attempt-id", att,
     "--report", s!"{dir}/report.json"])
  let lines := err.splitOn "\n"
  let verdict := (lines.find? (·.startsWith "verdict: ")).getD ""
  let approval := ((lines.find? (·.startsWith "approval: ")).map (·.drop "approval: ".length)).getD ""
  let report ← try IO.FS.readFile s!"{dir}/report.json" catch _ => pure ""
  IO.eprintln s!"# V {tag}: exit {c}; {verdict}; report: {(report.replace "\n" " ").take 1500}"
  return .ok (c, verdict, approval.trim)

private def patchApproval (line : String) : IO (Except String String) :=
  kubectlPatch "flaremigration" migName cfg.«namespace»
    s!"\{\"spec\":\{\"forwardApproval\":{(Lean.Json.str line).compress}}}"

/-- Held in Duplicating with a message containing `needle`, for 20 s. -/
private def heldWith (needle : String) : IO (Option String) := do
  let seen ← waitForCondition s!"held: {needle}" 60 do
    return containsSubstr (← migField "{.status.message}") needle
  let m ← migField "{.status.message}"
  if !seen then return some s!"message never said '{needle}': {m} (phase {← migPhase})"
  IO.sleep 20000
  let p ← migPhase
  if p != "Duplicating" then return some s!"left Duplicating: phase {p} ({m})"
  match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{.spec.clusterReplication.mode}" with
  | .ok md => if md.trim != "duplicate" then return some s!"the source was switched to mode {md.trim}"
  | .error e => return some s!"could not read the source mode: {e}"
  return none

def suite : TestSuite := {
  name := "blue-green-migration"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "source cluster did not stabilize")
    let _ ← kubectlApplyStdin entryServiceYaml
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := do
    let _ ← kubectl ["delete", "flaremigration", "--all", "-n", cfg.«namespace», "--ignore-not-found"]
    -- target resources are labelled; sweep them even on partial failure
    let _ ← kubectl ["delete", "statefulset,deployment,service,configmap,flarecluster",
                     "-n", cfg.«namespace», "-l", "flare.gree.net/migration", "--ignore-not-found"]
    cleanupCluster cfg
  tests := [
    { name := s!"seed {totalKeys} keys across both source partitions"
      run := do
        let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
        match findMasterPod (parseNodeSync sync) 0 with
        | none => return .fail "no P0 master"
        | some m =>
          let some ip ← getPodIp m cfg.«namespace» | return .fail "no master IP"
          let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "bg" totalKeys
          if stored == totalKeys then return .pass
          else return .fail s!"stored {stored}/{totalKeys}" },

    { name := "migration CR accepted; target provisioned and Ready (phase Duplicating)"
      run := do
        -- the attempt baseline for V's whole-attempt loss check: the source
        -- masters' raw stats BEFORE the migration enables duplication
        let srcM ← sourceMasters
        let sd ← scriptsDir
        let _ ← runProc "rm" ["-rf", vDir]
        let (cb, _, eb) ← runProc "python3" ([s!"{sd}/flare_v_capture_kind.py", "--stats-only", "--ns", cfg.«namespace»,
                                               "--out", s!"{vDir}/baseline"] ++ srcM)
        if cb != 0 || srcM.length != 2 then return .fail s!"baseline stats of {srcM} failed ({cb}): {eb}"
        match ← kubectlApplyStdin migrationYaml with
        | .error e => return .fail s!"CR apply failed: {e}"
        | .ok _ =>
          -- target bootstrap: STS + its own operator, sequential OrderedReady
          if ← waitForPhase "Duplicating" 300 then return .pass
          else return .fail s!"stuck before Duplicating (phase={← migPhase})" },

    -- 2026-10-11: equal key counts alone used to switch the source to
    -- forward (the first client-visible step). Now it needs this attempt's
    -- seed completed, no loss since the attempt began, AND a V MATCH
    -- approval bound to this attempt and the live masters.
    { name := "counts converge and the seed completes, but WITHOUT a V approval the source is NOT switched to forward (counts are not a verification)"
      run := do
        let satisfied ← waitForCondition "the automated forward evidence is satisfied (held only for the approval)" 300 do
          return containsSubstr (← migField "{.status.message}") "NOT a verification"
        IO.eprintln s!"# status.message: {← migField "{.status.message}"}; attemptId: {← migField "{.status.attemptId}"}; attemptBaseline: {← migField "{.status.attemptBaseline}"}"
        if !satisfied then
          return .fail s!"the automated forward evidence was never satisfied (phase {← migPhase}): {← migField "{.status.message}"}"
        if (← migField "{.status.attemptId}").isEmpty then return .fail "no status.attemptId"
        match ← heldWith "NOT a verification" with
        | some why => return .fail why
        | none => return .pass },

    { name := "approveForward=true (a boolean) is NOT accepted as a verification: still held"
      run := do
        match ← kubectlPatch "flaremigration" migName cfg.«namespace» "{\"spec\":{\"approveForward\":true}}" with
        | .error e => return .fail s!"patch failed: {e}"
        | .ok _ => pure ()
        match ← heldWith "NOT accepted" with
        | some why => return .fail why
        | none => return .pass },

    { name := "V on a real capture with one target value altered (same key count) → DIFFERENT and no approval line"
      run := do
        match ← runV "tampered" (tamper := true) with
        | .error e => return .fail e
        | .ok (c, verdict, approval) =>
          if c != 1 || !containsSubstr verdict "DIFFERENT" then return .fail s!"want DIFFERENT (exit 1), got exit {c}: {verdict}"
          if !approval.isEmpty then return .fail s!"an approval line was printed for a DIFFERENT result: {approval}"
          return .pass },

    { name := "a MATCH used after a write on the source (stale: position moved) is refused"
      run := do
        match ← runV "stale" with
        | .error e => return .fail e
        | .ok (c, verdict, approval) =>
          if c != 0 || approval.isEmpty then return .fail s!"want MATCH with an approval, got exit {c}: {verdict}"
          -- a write after the verification (writes were supposed to stay stopped)
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
          let some m := findMasterPod (parseNodeSync sync) 0 | return .fail "no P0 master"
          let some ip ← getPodIp m cfg.«namespace» | return .fail "no master IP"
          let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "bgx" 1
          if stored != 1 then return .fail "the post-verification write failed"
          match ← patchApproval approval with
          | .error e => return .fail s!"patch failed: {e}"
          | .ok _ => pure ()
          match ← heldWith "position moved" with
          | some why => return .fail why
          | none => return .pass },

    { name := "a fresh MATCH naming ANOTHER attempt is refused; the same MATCH for this attempt switches the source to forward (AwaitingCutover)"
      run := do
        -- let the extra write reach the target and the counts settle
        IO.sleep 15000
        match ← runV "fresh" with
        | .error e => return .fail e
        | .ok (c, verdict, approval) =>
          if c != 0 || approval.isEmpty then return .fail s!"want MATCH with an approval, got exit {c}: {verdict}"
          let att ← migField "{.status.attemptId}"
          let other := approval.replace s!"attempt={att}|" "attempt=00000000-reused/1|"
          if other == approval then return .fail s!"approval does not name attempt {att}: {approval}"
          match ← patchApproval other with
          | .error e => return .fail s!"patch failed: {e}"
          | .ok _ => pure ()
          if let some why ← heldWith "another attempt" then return .fail why
          match ← patchApproval approval with
          | .error e => return .fail s!"patch failed: {e}"
          | .ok _ => pure ()
          if ← waitForPhase "AwaitingCutover" 300 then return .pass
          else return .fail s!"never reached AwaitingCutover (phase={← migPhase}): {← migField "{.status.message}"}" },

    { name := "every key re-hashed into the 1-partition target (master AND slave)"
      run := do
        let onMaster ← keysHeldLocally s!"{targetName}-nodes-0"
        let onSlave ← keysHeldLocally s!"{targetName}-nodes-1"
        -- relay to the slave is async; give it a moment if short
        if onMaster == totalKeys && onSlave == totalKeys then return .pass
        else
          IO.sleep 10000
          let m2 ← keysHeldLocally s!"{targetName}-nodes-0"
          let s2 ← keysHeldLocally s!"{targetName}-nodes-1"
          if m2 == totalKeys && s2 == totalKeys then return .pass
          else return .fail s!"target holds master={m2}/{totalKeys} slave={s2}/{totalKeys}" },

    { name := "parked at AwaitingCutover until approval (gate honored)"
      run := do
        IO.sleep 15000
        let p ← migPhase
        if p == "AwaitingCutover" then return .pass
        else return .fail s!"advanced without approval: {p}" },

    { name := "approveCutover flips the entry Service to the target"
      run := do
        let patch := "{\"spec\":{\"approveCutover\":true}}"
        match ← kubectlPatch "flaremigration" migName cfg.«namespace» patch with
        | .error e => return .fail s!"approve patch failed: {e}"
        | .ok _ =>
          if !(← waitForPhase "AwaitingRetire" 120) then
            return .fail s!"no cutover (phase={← migPhase})"
          match ← kubectlGetJsonpath "service" entrySvc cfg.«namespace» "{.spec.selector.cluster}" with
          | .ok sel =>
            if sel.trim == targetName then return .pass
            else return .fail s!"entry Service selects '{sel}', want {targetName}"
          | .error e => return .fail s!"cannot read entry Service: {e}" },

    { name := "reads through the entry Service hit the target cluster"
      run := do
        let cmd := s!"printf 'get bg_0\\r\\n' | nc -w 3 {entrySvc}.{cfg.«namespace»}.svc.cluster.local {cfg.flarePort}"
        match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
        | .ok out =>
          if containsSubstr out "VALUE" then return .pass
          else return .fail s!"entry read miss: {out.take 120}"
        | .error e => return .fail s!"entry read failed: {e}" },

    { name := "approveRetire deletes the source StatefulSet (phase Retired)"
      run := do
        let patch := "{\"spec\":{\"approveRetire\":true}}"
        match ← kubectlPatch "flaremigration" migName cfg.«namespace» patch with
        | .error e => return .fail s!"approve patch failed: {e}"
        | .ok _ =>
          if !(← waitForPhase "Retired" 120) then
            return .fail s!"not retired (phase={← migPhase})"
          match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» "{.metadata.name}" with
          | .ok _ => return .fail "source StatefulSet still exists after retire"
          | .error _ => return .pass },

    -- POST-MIGRATION HANDOFF: once a helm-managed successor operator for the
    -- target cluster is Ready, the migration-provisioned operator must
    -- delete its own Deployment (releasing the {cr}-operator-lease). Holding
    -- it kept the successor pair leaderless -> no index Service endpoint ->
    -- the re-pointed StatefulSet crashlooped (observed live). We simulate
    -- the values switch by deploying a successor with the chart's labels.
    { name := "provisioned operator self-retires when a helm successor appears"
      run := do
        let successor := s!"apiVersion: apps/v1
kind: Deployment
metadata:
  name: successor-operator
  namespace: {cfg.«namespace»}
  labels:
    app.kubernetes.io/name: flare-operator
    app.kubernetes.io/instance: bg-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: successor-operator
  template:
    metadata:
      labels:
        app: successor-operator
        app.kubernetes.io/name: flare-operator
        app.kubernetes.io/instance: bg-test
    spec:
      serviceAccountName: flare-operator
      containers:
        - name: flare-operator
          image: flare-operator:test
          imagePullPolicy: Never
          args:
            - \"--namespace\"
            - \"{cfg.«namespace»}\"
            - \"--cluster-name\"
            - \"{targetName}\"
          ports:
            - containerPort: 12120
              name: flare-index"
        match ← kubectlApplyStdin successor with
        | .error e => return .fail s!"successor deploy failed: {e}"
        | .ok _ =>
          let gone ← waitForCondition "provisioned operator deleted itself" 180 do
            match ← kubectlGetJsonpath "deployment" s!"{targetName}-operator" cfg.«namespace» "{.metadata.name}" with
            | .ok _ => return false
            | .error _ => return true
          if gone then return .pass
          else return .fail s!"{targetName}-operator still exists 180s after a Ready successor appeared" },

    -- Interruptibility: a second migration rolled back mid-flight.
    { name := "abort rolls a migration back (target resources deleted)"
      run := do
        let abortMig := s!"apiVersion: flare.gree.net/v1alpha1
kind: FlareMigration
metadata:
  name: abort-me
  namespace: {cfg.«namespace»}
spec:
  source: {targetName}
  target:
    name: bg-tgt2
    partitions: 1
    replicas: 2
    persistenceSize: \"1Gi\"
    drainSeconds: 0"
        -- NOTE: sourced from bg-tgt (the surviving cluster) — its operator
        -- runs the controller now.
        match ← kubectlApplyStdin abortMig with
        | .error e => return .fail s!"abort-mig apply failed: {e}"
        | .ok _ =>
          let started ← waitForCondition "abort-me left Pending" 120 do
            match ← kubectlGetJsonpath "flaremigration" "abort-me" cfg.«namespace» "{.status.phase}" with
            | .ok p => return p.trim != "" && p.trim != "Pending"
            | .error _ => return false
          if !started then return .fail "second migration never started"
          let patch := "{\"spec\":{\"abort\":true}}"
          match ← kubectlPatch "flaremigration" "abort-me" cfg.«namespace» patch with
          | .error e => return .fail s!"abort patch failed: {e}"
          | .ok _ =>
            let aborted ← waitForCondition "abort-me Aborted" 180 do
              match ← kubectlGetJsonpath "flaremigration" "abort-me" cfg.«namespace» "{.status.phase}" with
              | .ok p => return p.trim == "Aborted"
              | .error _ => return false
            if !aborted then return .fail "never reached Aborted"
            -- the labelled sweep must have removed the target STS
            match ← kubectlGetJsonpath "statefulset" "bg-tgt2-nodes" cfg.«namespace» "{.metadata.name}" with
            | .ok _ => return .fail "aborted target StatefulSet still exists"
            | .error _ => return .pass }
  ]
}

end FlareOperator.E2E.Tests.BlueGreenMigration
