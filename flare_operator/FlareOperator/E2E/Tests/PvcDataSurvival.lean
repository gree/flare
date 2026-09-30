/-
  E2E/Tests/PvcDataSurvival.lean - Data survival with persistent volumes

  Replica promotion (data-survival-failover suite) protects a partition only
  while at least one replica stays alive. If the master AND all its slaves die
  at once (AZ outage, simultaneous eviction), the only remaining copy of the
  partition's data is on disk — which emptyDir throws away with the pod. This
  suite deploys the cluster with usePvc (volumeClaimTemplates, no startup
  wipe) and asserts the case emptyDir can never survive: kill BOTH P0 nodes
  simultaneously, then read every key back with its exact value. Any missing
  or mismatched key is `.fail` — never `.skip`.

  Uses the rocksdb backend: the production motivation for PVCs is RocksDB
  (WAL retention + LSN markers also only make sense on storage that outlives
  the pod).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.PvcDataSurvival

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "pvc-survival"
  «namespace» := "flare-pvc-survival"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-pvc-survival"
  storageBackend := "rocksdb"
  usePvc := true
}

private def numPods : Nat := cfg.partitions * cfg.replicas
private def totalKeys : Nat := 100
private def keyPrefix : String := "pvc"

/-- Read back every key `{keyPrefix}_{i}` and confirm the exact value
    (same assertion discipline as data-survival-failover: never skip). -/
private def assertAllKeysSurvive (ip : String) : IO TestResult := do
  let mut missing : List Nat := []
  let mut mismatched : List Nat := []
  for i in List.range totalKeys do
    let key := s!"{keyPrefix}_{i}"
    let expected := s!"val_{i}"
    match ← memcachedGet cfg.debugPod cfg.«namespace» ip cfg.flarePort key with
    | none => missing := missing ++ [i]
    | some got => if got != expected then mismatched := mismatched ++ [i]
  if missing.isEmpty && mismatched.isEmpty then
    return .pass
  else
    return .fail s!"DATA LOSS: {missing.length} missing, {mismatched.length} mismatched \
      (missing={missing.take 10}, mismatched={mismatched.take 10})"

/-- Current node-sync view from the operator. -/
private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- Pod name of the P0 master, or none. -/
private def currentP0Master : IO (Option String) := do
  return findMasterPod (← nodeView) 0

/-- Pod names of every node assigned to partition 0 (master and slaves),
    derived from an already-fetched node-sync view.
    Role codes in node-sync lines: 0 = Master, 1 = Slave, 2 = Proxy. -/
private def currentP0PodsFrom (entries : List NodeSyncEntry) : List String :=
  entries.filter (fun e => e.partition == 0 && (e.role == 0 || e.role == 1))
    |>.map (fun e => (e.fqdn.splitOn ".").headD e.fqdn)

/-- Pod names of every node assigned to partition 0 (master and slaves). -/
private def currentP0Pods : IO (List String) := do
  return currentP0PodsFrom (← nodeView)

def suite : TestSuite := {
  name := "pvc-data-survival"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  -- Per-suite operators are deleted in teardown, so the CI end-of-run log
  -- dump can never capture a failing suite's logs; grab them here first.
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: baseline — write and read back through the P0 master.
    { name := s!"write {totalKeys} keys and verify baseline integrity (PVC, rocksdb)"
      run := do
        match ← currentP0Master with
        | none => return .fail "no P0 master found"
        | some masterPod =>
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort keyPrefix totalKeys
            IO.eprintln s!"# Wrote via {masterPod}: stored {stored}/{totalKeys}"
            if stored != totalKeys then
              return .fail s!"only {stored}/{totalKeys} keys stored"
            assertAllKeysSurvive ip },

    -- Test 2: the emptyDir-impossible case — kill the P0 master AND its
    -- slave in the same instant, so no live replica exists to promote. The
    -- StatefulSet recreates both pods on their PVCs; whichever re-registers
    -- first is re-assigned P0 master and must serve the data from its
    -- persisted RocksDB directory.
    { name := s!"all {totalKeys} keys survive SIMULTANEOUS death of P0 master and slave"
      run := do
        let p0Pods ← currentP0Pods
        if p0Pods.length < 2 then
          return .fail s!"expected P0 master+slave, found {p0Pods}"
        IO.eprintln s!"# Killing ALL P0 nodes simultaneously: {p0Pods}"
        -- Pod UIDs before the kill: the recovery wait below must see NEW
        -- pods. Right after a --force delete the StatefulSet's
        -- status.readyReplicas and the operator's map are still the
        -- pre-kill values for several seconds, so a wait on those alone
        -- returned after 15 s (CI run 36707861123) and the exact-value
        -- readback hit a flared that was still booting: the first ten GETs
        -- in sequence missed, the rest passed, and the P0 item count matched
        -- the passing run — a precondition fault reported as DATA LOSS.
        let mut uidsBefore : List (String × String) := []
        for p in p0Pods do
          match ← kubectlGetJsonpath "pod" p cfg.«namespace» "{.metadata.uid}" with
          | .ok u => uidsBefore := uidsBefore ++ [(p, u.trim)]
          | .error _ => pure ()
        let _ ← kubectl (["delete", "pod"] ++ p0Pods ++
                         ["-n", cfg.«namespace», "--force", "--grace-period=0"])
        -- 420s: readiness is sync-gated (Ready = state=active) and the STS is
        -- OrderedReady, so recovery is SERIAL — pod-0 must fully re-activate
        -- (register + promote + probe) before pod-2 is even recreated, and
        -- pod-2 then needs a full prepare->active reseed. The old 180s budget
        -- assumed Ready = "port open" and parallel recreation.
        let t0 ← IO.monoMsNow
        let recovered ← waitForCondition "P0 master available after total P0 loss (every killed pod recreated with a new UID, all pods Ready, P0 master serving stats)" 420 do
          -- (1) every killed pod has been REPLACED (new UID)
          let mut replaced := true
          for (p, u0) in uidsBefore do
            match ← kubectlGetJsonpath "pod" p cfg.«namespace» "{.metadata.uid}" with
            | .ok u => if u.trim == u0 then replaced := false
            | .error _ => replaced := false
          if !replaced then return false
          -- (2) the StatefulSet reports every pod Ready
          let rr ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» "{.status.readyReplicas}"
          let ready := match rr with
            | .ok val => val.trim.toNat?.getD 0 >= numPods
            | .error _ => false
          if !ready then return false
          -- (3) the operator names a P0 master and that node answers stats
          match ← currentP0Master with
          | none => return false
          | some m =>
            match ← getPodIp m cfg.«namespace» with
            | none => return false
            | some ip =>
              match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}" with
              | .ok o => return containsSubstr o "STAT curr_items"
              | .error _ => return false
        IO.eprintln s!"# recovery wait ended after {((← IO.monoMsNow) - t0) / 1000}s (recovered={recovered})"
        if !recovered then
          return .fail s!"P0 master not re-established within 420s after killing {p0Pods}"
        match ← currentP0Master with
        | none => return .fail "P0 master missing after recovery"
        | some newMaster =>
          IO.eprintln s!"# P0 master after total-P0 restart: {newMaster}"
          match ← getPodIp newMaster cfg.«namespace» with
          | none => return .fail s!"could not get IP for {newMaster}"
          | some ip => assertAllKeysSurvive ip },

    -- Test 3: count-level guard against a wholesale wipe.
    { name := "P0 master holds data after total-P0 restart"
      run := do
        let items ← getPartitionMasterItems cfg.debugPod cfg.«namespace»
          cfg.operatorName cfg.operatorPort 0 cfg.flarePort
        IO.eprintln s!"# P0 curr_items: {items}"
        if items > 0 then return .pass
        else return .fail "P0 master reports 0 curr_items — PVC data did not survive" },

    -- Test 4: convergence — every replica returns to Active, not just the
    -- reinstated master. A rejoined node re-registers as Slave/Prepare and
    -- must reconstruct its way back to Active; a flared that boots straight
    -- into an assigned prepare role used to skip reconstruction entirely
    -- (cluster.cc reconstruct_node only fired role shifts on DIFFS, and the
    -- very first map already carried the role) and sat in Prepare forever —
    -- seen on a live deployment while every earlier test here passed.
    { name := "all replicas return to Active after total-P0 restart"
      run := do
        let converged ← waitForCondition "all nodes Active" 180 do
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace»
            cfg.operatorName cfg.operatorPort "node sync"
          let entries := parseNodeSync sync
          return entries.length == numPods && countActiveNodes entries == numPods
        if converged then return .pass
        else
          let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace»
            cfg.operatorName cfg.operatorPort "node sync"
          return .fail s!"not all replicas Active after 180s: {sync.trim}" },

    -- Test 5: a GRACEFUL restart of P0's SLAVE must not lose data. Two
    -- real production incidents share this path:
    --   * #14 — a slave rebuilding from a master that was itself just
    --     rebuilt EMPTY truncated its own copy and the emptiness cascaded
    --     (the pre-dump truncate checked peer_reachable, not peer_has_data);
    --   * #15 — graceful shutdown (SIGTERM → ~flared destructors) aborted
    --     with "pure virtual method called" tearing down cluster_replication
    --     over an already-freed thread pool.
    -- The simultaneous-kill test (test 2) uses --grace-period=0 (SIGKILL),
    -- which never runs the destructor path, so ONLY a graceful delete
    -- exercises #15 — and #15 fires on ANY pod's graceful termination
    -- regardless of role. #14's truncate gate is a SLAVE-side concern (a
    -- slave reconstructing from its master). Restarting just the P0 SLAVE
    -- therefore covers both bugs while leaving the master up the whole time
    -- — no failover/masterless churn, bounded (~1 reconstruction), and the
    -- master's IP stays stable for the readback. (Restarting both P0 pods
    -- sequentially re-creates the total-partition-loss window that test 2
    -- already covers and made the final master lookup flap.)
    { name := s!"all {totalKeys} keys survive a graceful restart of the P0 slave"
      run := do
        let entries0 ← nodeView
        match findMasterPod entries0 0 with
        | none => return .fail "no P0 master before restart"
        | some masterPod =>
          -- the P0 slave = the P0 data-bearing pod that is not the master
          let slavePod? := (currentP0PodsFrom entries0).filter (· != masterPod) |>.head?
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort keyPrefix totalKeys
            if stored != totalKeys then return .fail s!"only {stored}/{totalKeys} stored pre-restart"
            match slavePod? with
            | none => return .fail "no P0 slave found to restart"
            | some slavePod =>
              IO.eprintln s!"# Gracefully restarting P0 slave {slavePod} (master {masterPod} stays up)"
              -- default grace period = SIGTERM → runs ~flared destructors (#15)
              let _ ← kubectl ["delete", "pod", slavePod, "-n", cfg.«namespace»]
              let back ← waitForCondition "cluster all-Active after slave restart" 240 do
                let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace»
                  cfg.operatorName cfg.operatorPort "node sync"
                let e := parseNodeSync sync
                return e.length == numPods && countActiveNodes e == numPods
              if !back then
                return .fail s!"cluster did not reconverge within 240s after restarting {slavePod}"
              -- Master never moved; read back through it.
              match ← getPodIp masterPod cfg.«namespace» with
              | none => return .fail s!"could not get IP for {masterPod} after restart"
              | some ip2 => assertAllKeysSurvive ip2 }
  ]
}

end FlareOperator.E2E.Tests.PvcDataSurvival
