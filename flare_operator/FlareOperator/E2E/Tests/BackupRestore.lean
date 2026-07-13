/-
  E2E/Tests/BackupRestore.lean - Logical-destruction recovery via checkpoints

  Replication and PVCs protect against hardware failure, but a bad delete or
  flush_all is replicated faithfully to every replica — the only defense is a
  point-in-time backup. This suite exercises the full tier-1 loop:

    write → `backup` op (RocksDB checkpoint on the PVC) → flush_all on every
    replica (logical destruction) → verify data GONE → RESTORE marker on each
    pod's PVC → delete pods → startup hook swaps the checkpoint in → verify
    every key back with its exact value.

  Uses a 1-partition cluster deliberately: role assignment is
  registration-order based, so with a single partition any restored pod that
  wins the P0 master slot holds the right data. Multi-partition restore needs
  partition pinning — documented as a caveat in docs/BACKUP_RESTORE.md.
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.BackupRestore

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "backup-restore"
  «namespace» := "flare-backup-restore"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-backup-restore"
  storageBackend := "rocksdb"
  usePvc := true
}

private def numPods : Nat := cfg.partitions * cfg.replicas
private def totalKeys : Nat := 50
private def keyPrefix : String := "bak"
private def backupName : String := "e2e-restore-point"
private def dataDir : String := "/data/flare"

/-- Send a raw text-protocol command to a flared node and return the reply. -/
private def flaredCmd (ip : String) (cmd : String) : IO String := do
  let shellCmd := s!"printf '%s\\r\\n' '{cmd}' | nc -w 10 {ip} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» shellCmd with
  | .ok output => return output
  | .error e => return s!"ERROR: {e}"

/-- All flared pod names of this cluster (stable StatefulSet identities). -/
private def allPods : List String :=
  (List.range numPods).map (fun i => s!"{cfg.name}-nodes-{i}")

/-- Read back every key and confirm the exact value. Never skips. -/
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
    return .fail s!"RESTORE FAILED: {missing.length} missing, {mismatched.length} mismatched \
      (missing={missing.take 10}, mismatched={mismatched.take 10})"

private def currentP0Master : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return findMasterPod (parseNodeSync sync) 0

def suite : TestSuite := {
  name := "backup-restore"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      throw (IO.userError "cluster did not stabilize")
  -- Per-suite operators are deleted in teardown, so the CI end-of-run log
  -- dump can never capture a failing suite's logs; grab them here first.
  onFailure := dumpClusterDiagnostics cfg.«namespace»
  teardown := cleanupCluster cfg
  tests := [
    -- Test 1: baseline — write keys through the master and read them back.
    { name := s!"write {totalKeys} keys and verify baseline"
      run := do
        match ← currentP0Master with
        | none => return .fail "no P0 master found"
        | some masterPod =>
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            let stored ← writeKeys cfg.debugPod cfg.«namespace» ip cfg.flarePort keyPrefix totalKeys
            if stored != totalKeys then
              return .fail s!"only {stored}/{totalKeys} keys stored"
            assertAllKeysSurvive ip },

    -- Test 2: take a checkpoint on EVERY replica (each pod restores from its
    -- own PVC-local checkpoint). Skips only if the image lacks the backup op.
    { name := s!"checkpoint '{backupName}' created on every replica"
      run := do
        let mut unsupported := false
        for pod in allPods do
          match ← getPodIp pod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {pod}"
          | some ip =>
            let reply ← flaredCmd ip s!"backup {backupName}"
            IO.eprintln s!"# backup on {pod}: {reply.trim}"
            if containsSubstr reply "not_supported" || containsSubstr reply "ERROR" then
              if containsSubstr reply "not_supported" then unsupported := true
              else return .fail s!"backup failed on {pod}: {reply.trim}"
        if unsupported then
          return .skip "flared image lacks the backup op (not built from this branch)"
        -- Verify the checkpoint directory exists and looks like a RocksDB dir.
        for pod in allPods do
          match ← kubectl ["exec", pod, "-n", cfg.«namespace», "--", "sh", "-c",
                            s!"test -f {dataDir}/backups/{backupName}/CURRENT && echo PRESENT"] with
          | .ok out =>
            if !containsSubstr out "PRESENT" then
              return .fail s!"checkpoint dir on {pod} missing CURRENT file"
          | .error e => return .fail s!"checkpoint verification failed on {pod}: {e}"
        return .pass },

    -- Test 3: logical destruction — flush_all on EVERY replica (a bad flush
    -- or delete is replicated in production; hitting both replicas directly
    -- models the worst case deterministically), then prove the data is gone.
    { name := "flush_all destroys live data on all replicas"
      run := do
        for pod in allPods do
          match ← getPodIp pod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {pod}"
          | some ip =>
            let _ ← flaredCmd ip "flush_all"
        match ← currentP0Master with
        | none => return .fail "no P0 master after flush"
        | some masterPod =>
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip =>
            match ← memcachedGet cfg.debugPod cfg.«namespace» ip cfg.flarePort s!"{keyPrefix}_0" with
            | some v => return .fail s!"expected {keyPrefix}_0 gone after flush_all, still reads '{v}'"
            | none => return .pass },

    -- Test 4: the actual restore — marker + pod deletion; the startup hook
    -- swaps the checkpoint in. Then EVERY key must read back exactly.
    { name := s!"all {totalKeys} keys restored from checkpoint after pod recreation"
      run := do
        for pod in allPods do
          match ← kubectl ["exec", pod, "-n", cfg.«namespace», "--", "sh", "-c",
                            s!"echo {dataDir}/backups/{backupName} > {dataDir}/RESTORE"] with
          | .ok _ => pure ()
          | .error e => return .fail s!"failed to write RESTORE marker on {pod}: {e}"
        let _ ← kubectl (["delete", "pod"] ++ allPods ++
                         ["-n", cfg.«namespace», "--force", "--grace-period=0"])
        let recovered ← waitForCondition "cluster recovered after restore" 180 do
          match ← currentP0Master with
          | none => return false
          | some _ =>
            match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace»
                      "{.status.readyReplicas}" with
            | .ok val => return (val.toNat?.getD 0 >= numPods)
            | .error _ => return false
        if !recovered then
          return .fail "cluster did not recover within 180s after restore"
        match ← currentP0Master with
        | none => return .fail "no P0 master after restore"
        | some masterPod =>
          IO.eprintln s!"# P0 master after restore: {masterPod}"
          match ← getPodIp masterPod cfg.«namespace» with
          | none => return .fail s!"could not get IP for {masterPod}"
          | some ip => assertAllKeysSurvive ip }
  ]
}

end FlareOperator.E2E.Tests.BackupRestore
