/-
  E2E/Tests/BlueGreenMigration.lean — FlareMigration end-to-end.

  The user story this automates (previously a hand-run sequence): shrink a
  2-partition cluster to 1 partition blue/green style —

    FlareMigration CR created
      → operator provisions the target cluster (CR/CM/Services/STS/operator)
      → source duplicates into it (dump re-hashes 2p → 1p + dual-write)
      → counts converge → source flips to mode=forward
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
  s!"apiVersion: flare.gree.net/v1
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
        match ← kubectlApplyStdin migrationYaml with
        | .error e => return .fail s!"CR apply failed: {e}"
        | .ok _ =>
          -- target bootstrap: STS + its own operator, sequential OrderedReady
          if ← waitForPhase "Duplicating" 300 then return .pass
          else return .fail s!"stuck before Duplicating (phase={← migPhase})" },

    { name := "counts converge and source flips to forward (phase AwaitingCutover)"
      run := do
        if ← waitForPhase "AwaitingCutover" 300 then return .pass
        else return .fail s!"never reached AwaitingCutover (phase={← migPhase})" },

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

    -- Interruptibility: a second migration rolled back mid-flight.
    { name := "abort rolls a migration back (target resources deleted)"
      run := do
        let abortMig := s!"apiVersion: flare.gree.net/v1
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
