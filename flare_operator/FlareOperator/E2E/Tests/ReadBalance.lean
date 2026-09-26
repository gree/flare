/-
  E2E/Tests/ReadBalance.lean — declarative read-routing policy.

  spec.readBalance drives flared's read distribution: the operator
  normalizes every committed node map to {master, slave} balance weights
  (level-triggered — manual flare-admin balance edits are reverted), and
  `standby` selectors force chosen nodes to balance 0 and make them the
  promotion choice of LAST resort (availability still wins when only a
  standby slave remains).

  1p×3r so there are two slaves: one regular, one marked standby by pod
  name. Verifies policy convergence, standby exclusion from promotion on
  master kill, and re-convergence after a policy patch.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ReadBalance

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "rb-test"
  «namespace» := "flare-readbalance"
  partitions := 1
  replicas := 3
  operatorName := "flare-operator-rb"
  debugPod := "debug-rb"
}

private def standbyPod : String := s!"{cfg.name}-nodes-2"

/-- balance of the entry whose fqdn starts with the given pod name. -/
private def balanceOf (entries : List NodeSyncEntry) (pod : String) : Option Nat :=
  entries.find? (fun e => (e.fqdn.splitOn ".").head? == some pod) |>.map (·.balance)

private def roleOf (entries : List NodeSyncEntry) (pod : String) : Option Nat :=
  entries.find? (fun e => (e.fqdn.splitOn ".").head? == some pod) |>.map (·.role)

private def nodeSync : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

def suite : TestSuite := {
  name := "read-balance"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 60
    if !stable then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    { name := "default policy converges (master=100, slaves=0)"
      run := do
        let ok ← waitForCondition "default balances" 60 do
          let entries ← nodeSync
          return entries.length >= 3 && entries.all fun e =>
            (e.role != 0 || e.balance == 100) && (e.role != 1 || e.balance == 0)
        if ok then return .pass
        else
          let entries ← nodeSync
          return .fail s!"balances: {entries.map (fun e => (e.fqdn.splitOn "." |>.headD "?", e.role, e.balance))}" },

    { name := "policy patch (slave=100 + standby by podName) converges"
      run := do
        let patch := "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":100,\"standby\":[{\"podName\":\"" ++ standbyPod ++ "\"}]}}}"
        match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» patch with
        | .error e => return .fail s!"patch failed: {e}"
        | .ok _ =>
          let ok ← waitForCondition "patched balances" 90 do
            let entries ← nodeSync
            let standbyOk := balanceOf entries standbyPod == some 0
            let others := entries.filter fun e =>
              (e.fqdn.splitOn ".").head? != some standbyPod
            let othersOk := others.all fun e =>
              (e.role != 0 || e.balance == 100) && (e.role != 1 || e.balance == 100)
            return entries.length >= 3 && standbyOk && othersOk
          if ok then return .pass
          else
            let entries ← nodeSync
            return .fail s!"balances after patch: {entries.map (fun e => (e.fqdn.splitOn "." |>.headD "?", e.role, e.balance))}" },

    { name := "master kill promotes the NON-standby slave"
      run := do
        let entries ← nodeSync
        match findMasterPod entries 0 with
        | none => return .fail "no P0 master"
        | some master =>
          if master == standbyPod then
            return .fail "precondition broken: standby is master before the kill"
          IO.eprintln s!"# Killing master {master} (standby={standbyPod})"
          let _ ← kubectl ["delete", "pod", master, "-n", cfg.«namespace»,
                            "--force", "--grace-period=0"]
          let ok ← waitForCondition "new non-standby master" 90 do
            let entries ← nodeSync
            match findMasterPod entries 0 with
            | some m => return m != master
            | none => return false
          if !ok then return .fail "no replacement master within 90s"
          let entries ← nodeSync
          match findMasterPod entries 0 with
          | some m =>
            if m == standbyPod then
              return .fail s!"standby {standbyPod} was promoted although a regular slave existed"
            else
              IO.eprintln s!"# Promoted: {m} (standby correctly skipped)"
              return .pass
          | none => return .fail "master vanished" },

    { name := "standby stays balance=0 across the failover"
      run := do
        let ok ← waitForCondition "standby balance 0" 90 do
          let entries ← nodeSync
          return balanceOf entries standbyPod == some 0
            && (roleOf entries standbyPod != some 0)
        if ok then return .pass
        else
          let entries ← nodeSync
          return .fail s!"standby state: role={roleOf entries standbyPod} balance={balanceOf entries standbyPod}" }
  ]
}

end FlareOperator.E2E.Tests.ReadBalance
