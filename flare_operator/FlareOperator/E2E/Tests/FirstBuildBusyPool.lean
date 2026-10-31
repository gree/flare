/-
  E2E/Tests/FirstBuildBusyPool.lean — the first build of a new cluster while
  the operator's shared task pool is busy (flare-bug-first-build-node-add-timeout).

  On a fresh helm install (CI 41186795576) a flared's first `node add` sat
  unread ~1 s while the operator ran its first pass: the TCP server's handlers
  ran on the shared task pool, whose workers the servers' accept loops held
  for good. flared gave up at its 1 s read timeout, exited and registered
  again; the first build had seated it as the master and its history was
  never recorded, so the partition stayed masterless (PROMOTION ABORTED).

  The seam FLARE_TEST_POOL_BUSY fills the shared pool at the operator's start
  with tasks that sleep 60 s, so a handler on that pool cannot run while the
  flared pods register. The servers run on dedicated threads: registration
  must not notice — the partition gets a master and an Active slave, and no
  flared pod restarts.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.FirstBuildBusyPool

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "fb-busy"
  «namespace» := "flare-fb-busy"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-fb-busy"
  storageBackend := "rocksdb"
  -- more sleeping tasks than CI's cores: the pool stays full ~2 rounds of 60 s
  operatorEnv := [("FLARE_TEST_POOL_BUSY", "16")]
}

private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

/-- restart counts of the cluster's flared pods ("name=count" each) -/
private def restarts : IO (List (String × Nat)) := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"cluster={cfg.name}", "-o",
      "jsonpath={range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount}{\"\\n\"}{end}"] with
  | .ok o => return (o.splitOn "\n").filterMap fun l =>
      match l.trim.splitOn "=" with
      | [n, c] => c.toNat?.map (n, ·)
      | _ => none
  | .error _ => return []

def suite : TestSuite := {
  name := "first-build-busy-pool"
  setup := deployCluster cfg
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "first build with the operator's shared task pool full (FLARE_TEST_POOL_BUSY): every flared registers at its first node add (no pod restarts), partition 0 gets an Active master and an Active slave"
      run := do
        let logs ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400000
        if !containsSubstr logs "TEST SEAM: occupying the shared task pool" then
          return .fail "precondition: the operator did not arm the busy-pool seam"
        let built ← waitForCondition "partition 0 has an Active master and an Active slave" 300 do
          let es := parseNodeSync (← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync")
          let p0 := es.filter (·.partition == 0)
          return p0.any (fun e => e.role == 0 && e.state == 0) && p0.any (fun e => e.role == 1 && e.state == 0)
        let rs ← restarts
        IO.eprintln s!"# flared restarts: {rs}"
        if !built then return .fail s!"partition 0 never got an Active master and an Active slave (restarts {rs})"
        if rs.length != cfg.partitions * cfg.replicas then return .fail s!"precondition: expected {cfg.partitions * cfg.replicas} flared pods, saw {rs}"
        if rs.any (·.2 > 0) then return .fail s!"a flared pod restarted during the first build (its node add went unanswered?): {rs}"
        let late := (logs.splitOn "\n").filter (containsSubstr · "failed to add node")
        if !late.isEmpty then return .fail s!"a flared failed to add itself: {late.take 2}"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.FirstBuildBusyPool
