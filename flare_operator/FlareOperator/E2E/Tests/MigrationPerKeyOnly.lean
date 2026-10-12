/-
  A FlareMigration from a per-key-only source (`spec.clusterReplication.
  snapshotPush: false`) — review 2026-10-13 finding 1.

  The target must refuse snapshot pushes from its FIRST start: its CR and
  its extra.conf are provisioned with the switch off. The plan reads that
  switch from the source CR; a read that fails (a transient API error, a
  Forbidden) must stop the provision and retry it, never provision a target
  with the default (accepting pushes).

  Verdicts, separate tests:
    1. the source carries the switch (every source pod reports
       `snapshot_push_accept off`) and holds the keys;
    2. while the source CR read fails (test seam
       FLARE_TEST_MIG_SOURCE_READ_FAIL_FILE in the operator), NOTHING of the
       target is applied (no CR, ConfigMap, Deployment, StatefulSet or
       Service with the migration label) and the operator keeps retrying;
    3. once the read works again, the target is provisioned with the switch:
       its CR has snapshotPush false, its ConfigMap renders
       `cluster-replication-snapshot-push = false`, the ConfigMap predates
       the pod, the flared container has not restarted, and it reports
       `snapshot_push_accept off`;
    4. the seed completes by the per-key dump: every source master declined
       the push (`seed_snapshot_push_disabled` moved, seed `completed_dump`),
       the target never bootstrapped from a snapshot, keeps its own master
       id, and holds every key with its value.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.MigrationPerKeyOnly

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "pk-src"
  «namespace» := "flare-pk-migration"
  partitions := 2
  replicas := 1
  operatorName := "flare-operator-pk"
  debugPod := "debug-pk"
  storageBackend := "rocksdb"
  reserveInCr := true
  operatorEnv := [("FLARE_TEST_MIG_SOURCE_READ_FAIL_FILE", "/tmp/mig-src-read-fail")]
}

private def targetName : String := "pk-tgt"
private def targetPod : String := s!"{targetName}-nodes-0"
private def migName : String := "per-key-only-2p-to-1p"
private def totalKeys : Nat := 40
private def failFile : String := "/tmp/mig-src-read-fail"

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
    replicas: 1
    persistenceSize: \"1Gi\"
    drainSeconds: 0"

private def migField (path : String) : IO String := do
  match ← kubectlGetJsonpath "flaremigration" migName cfg.«namespace» path with
  | .ok v => return v.trim
  | .error _ => return ""

private def statOf (ip name : String) : IO (Option String) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith s!"STAT {name} " then some (t.drop s!"STAT {name} ".length).trim else none

private def statNat (ip name : String) : IO Nat :=
  return ((← statOf ip name).bind (·.toNat?)).getD 0

private def sourceMasters : IO (List String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  let nodes := parseNodeSync sync
  return (List.range cfg.partitions).filterMap (findMasterPod nodes ·)

private def sourcePods : IO (List String) :=
  getPodNames s!"app=flare,cluster={cfg.name}" cfg.«namespace»

private def operatorPod : IO (Option String) := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}",
                   "-o", "jsonpath={.items[*].metadata.name}"] with
  | .ok s => return (s.trim.splitOn " ").find? (!·.isEmpty)
  | .error _ => return none

private def opExec (cmd : String) : IO (Except String String) := do
  match ← operatorPod with
  | none => return .error "no operator pod"
  | some pod => kubectl ["exec", "-n", cfg.«namespace», pod, "--", "sh", "-c", cmd]

private def opLogs : IO String := do
  match ← operatorPod with
  | none => return ""
  | some pod =>
    match ← kubectl ["logs", "-n", cfg.«namespace», pod, "--tail=-1"] with
    | .ok s => return s
    | .error _ => return ""

private def countLines (s needle : String) : Nat :=
  ((s.splitOn "\n").filter (containsSubstr · needle)).length

/-- Everything provisioned for the target (all of it carries the label). -/
private def targetObjects : IO (Except String (List String)) := do
  match ← kubectl ["get", "flarecluster,configmap,deployment,statefulset,service", "-n", cfg.«namespace»,
                   "-l", "flare.gree.net/migration", "-o", "name"] with
  | .ok s => return .ok ((s.splitOn "\n").map String.trim |>.filter (!·.isEmpty))
  | .error e => return .error e

def suite : TestSuite := {
  name := "migration-per-key-only"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "source cluster did not stabilize")
  onFailure := do
    dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    dumpClusterDiagnostics cfg.«namespace» s!"app={targetName}-operator"
  teardown := do
    let _ ← opExec s!"rm -f {failFile}"
    let _ ← kubectl ["delete", "flaremigration", "--all", "-n", cfg.«namespace», "--ignore-not-found"]
    let _ ← kubectl ["delete", "statefulset,deployment,service,configmap,flarecluster",
                     "-n", cfg.«namespace», "-l", "flare.gree.net/migration", "--ignore-not-found"]
    cleanupCluster cfg
  tests := [
    { name := s!"the source carries snapshotPush false (every source pod reports snapshot_push_accept off) and holds {totalKeys} keys"
      run := do
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"clusterReplication\":{\"snapshotPush\":false}}}" with
        | .error e => return .fail s!"source CR patch failed: {e}"
        | .ok _ => pure ()
        let pods ← sourcePods
        if pods.length != cfg.partitions * cfg.replicas then return .fail s!"source pods {pods}"
        let off ← waitForCondition "every source pod refuses pushes" 300 do
          let mut all := true
          for p in pods do
            let some ip ← getPodIp p cfg.«namespace» | return false
            if (← statOf ip "snapshot_push_accept") != some "off" then all := false
          return all
        if !off then return .fail "the source's switch did not reach every source flared within 300 s"
        let masters ← sourceMasters
        let some m := masters.head? | return .fail "no source master"
        let some ip ← getPodIp m cfg.«namespace» | return .fail "no master IP"
        let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort "pk" totalKeys
        if stored != totalKeys then return .fail s!"stored {stored}/{totalKeys}"
        return .pass },

    { name := "while the source CR cannot be read, NOTHING of the target is applied and the provision is retried (no default that accepts pushes)"
      run := do
        if let .error e ← opExec s!"touch {failFile}" then return .fail s!"cannot arm the seam: {e}"
        match ← kubectlApplyStdin migrationYaml with
        | .error e => return .fail s!"FlareMigration apply failed: {e}"
        | .ok _ => pure ()
        -- the seam fires once per provisioning attempt: two attempts = a retry
        let retried ← waitForCondition "two provisioning attempts with the source read failing" 180 do
          return countLines (← opLogs) "TEST SEAM: the source FlareCluster read is forced to fail" ≥ 2
        let logs ← opLogs
        IO.eprintln s!"# seam attempts: {countLines logs "TEST SEAM: the source FlareCluster read is forced to fail"}; action failed lines: {countLines logs "action failed"}; phase {← migField "{.status.phase}"}"
        for l in (logs.splitOn "\n").filter (fun l => containsSubstr l "[migration]") |>.reverse |>.take 6 |>.reverse do
          IO.eprintln s!"#   {l}"
        match ← targetObjects with
        | .error e => return .fail s!"cannot list the target's objects: {e}"
        | .ok objs =>
          if !objs.isEmpty then
            return .fail s!"target objects were applied while the source CR could not be read: {objs}"
        if !retried then return .fail "the provision was not attempted twice within 180 s (the seam line never repeated)"
        return .pass },

    { name := "after the read recovers, the target is provisioned with the switch and refuses pushes from its FIRST start (CR, ConfigMap before the pod, no restart, snapshot_push_accept off)"
      run := do
        if let .error e ← opExec s!"rm -f {failFile}" then return .fail s!"cannot disarm the seam: {e}"
        let up ← waitForCondition "the target pod is Ready" 300 do
          match ← kubectlGetJsonpath "pod" targetPod cfg.«namespace» "{.status.conditions[?(@.type==\"Ready\")].status}" with
          | .ok s => return s.trim == "True"
          | .error _ => return false
        if !up then return .fail s!"the target pod was not Ready within 300 s (phase {← migField "{.status.phase}"})"
        let crPush ← kubectlGetJsonpath "flarecluster" targetName cfg.«namespace» "{.spec.clusterReplication.snapshotPush}"
        let conf ← kubectlGetJsonpath "configmap" s!"{targetName}-config" cfg.«namespace» "{.data.extra\\.conf}"
        let cmAt ← kubectlGetJsonpath "configmap" s!"{targetName}-config" cfg.«namespace» "{.metadata.creationTimestamp}"
        let podAt ← kubectlGetJsonpath "pod" targetPod cfg.«namespace» "{.metadata.creationTimestamp}"
        let restarts ← kubectlGetJsonpath "pod" targetPod cfg.«namespace» "{.status.containerStatuses[?(@.name==\"flared\")].restartCount}"
        let some tIp ← getPodIp targetPod cfg.«namespace» | return .fail "no target IP"
        let accept ← statOf tIp "snapshot_push_accept"
        IO.eprintln s!"# target CR snapshotPush={crPush.toOption.getD "?"}; ConfigMap at {cmAt.toOption.getD "?"}, pod at {podAt.toOption.getD "?"}; flared restarts={restarts.toOption.getD "?"}; snapshot_push_accept={accept.getD "?"}; extra.conf: {(conf.toOption.getD "?").replace "\n" " | "}"
        if crPush.toOption.map String.trim != some "false" then return .fail s!"target CR snapshotPush is {crPush.toOption.getD "(unreadable)"}, want false"
        if !containsSubstr (conf.toOption.getD "") "cluster-replication-snapshot-push = false" then
          return .fail "the target's extra.conf does not carry cluster-replication-snapshot-push = false"
        -- RFC 3339 UTC timestamps of one format compare as strings
        match cmAt, podAt with
        | .ok c, .ok p => if c.trim > p.trim then return .fail s!"the ConfigMap ({c.trim}) is newer than the pod ({p.trim})"
        | _, _ => return .fail "cannot read the creation timestamps"
        if restarts.toOption.map String.trim != some "0" then return .fail s!"the target flared restarted ({restarts.toOption.getD "?"}): not its first start"
        if accept != some "off" then return .fail s!"target snapshot_push_accept={accept.getD "(none)"}, want off"
        return .pass },

    { name := "the seed completes by the per-key dump: the sources declined the push, the target never bootstrapped from a snapshot, keeps its own master id and holds every key"
      run := do
        let masters ← sourceMasters
        if masters.length != cfg.partitions then return .fail s!"source masters {masters}"
        let mut ips : List String := []
        for m in masters do
          let some ip ← getPodIp m cfg.«namespace» | return .fail s!"no IP for {m}"
          ips := ips ++ [ip]
        let done ← waitForCondition "every source master completed its seed" 600 do
          let mut all := true
          for ip in ips do
            if (← statOf ip "cluster_replication_seed") != some "completed_dump" then all := false
          return all
        let some tIp ← getPodIp targetPod cfg.«namespace» | return .fail "no target IP"
        let mut srcIds : List String := []
        for ip in ips do
          let declined ← statNat ip "cluster_replication[seed_snapshot_push_disabled]"
          let seed := (← statOf ip "cluster_replication_seed").getD "(none)"
          let mid := (← statOf ip "rocksdb_master_id").getD "?"
          srcIds := srcIds ++ [mid]
          IO.eprintln s!"# source {ip}: seed={seed} seed_snapshot_push_disabled={declined} master_id={mid}"
          if declined == 0 then return .fail s!"source {ip} did not decline the snapshot push (seed_snapshot_push_disabled 0, seed {seed})"
        if !done then return .fail s!"the seeds did not complete by dump within 600 s (phase {← migField "{.status.phase}"})"
        let boot ← statNat tIp "rocksdb_snapshot_bootstrap"
        let tMid := (← statOf tIp "rocksdb_master_id").getD "?"
        IO.eprintln s!"# target: rocksdb_snapshot_bootstrap={boot} master_id={tMid} snapshot_push_accept={(← statOf tIp "snapshot_push_accept").getD "?"}"
        if boot != 0 then return .fail s!"the target bootstrapped from a snapshot ({boot})"
        if tMid == "?" || srcIds.contains tMid then return .fail s!"the target's master id {tMid} is a source's ({srcIds}): a pushed history"
        let mut missing : List String := []
        for i in List.range totalKeys do
          match ← memcachedGet cfg.debugPod cfg.«namespace» tIp cfg.flarePort s!"pk_{i}" with
          | some v => if v != s!"val_{i}" then missing := missing ++ [s!"pk_{i}={v}"]
          | none => missing := missing ++ [s!"pk_{i}"]
        if !missing.isEmpty then return .fail s!"{missing.length}/{totalKeys} keys missing or different on the target: {missing.take 10}"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.MigrationPerKeyOnly
