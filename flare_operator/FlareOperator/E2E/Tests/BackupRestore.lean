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
  -- T24 reproduction (test 4): a stop point right before the staged
  -- rebuild's size probe; the file is on the PVC, so it survives the
  -- recreation, and is absent in tests 1-3
  flaredEnv := [("FLARE_TEST_STAGED_PROBE_HOLD_FILE", "/data/flare/t24-probe-hold")]
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


/-! T24 reproduction helpers (test 5) -/

private def t24Hold : String := "/data/flare/t24-probe-hold"
/-- A stand-in for a released pod address: TEST-NET-1 (RFC 5737), never a
    pod IP, black-holed on the kind node so a connect to it TIMES OUT (no
    SYN-ACK, RST or ICMP), as the stale address in T24 did. -/
private def t24Blackhole : String := "192.0.2.10"
private def t24KindNode : String := "flare-e2e-control-plane"

private def t24HostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

private def t24Sh (pod cmd : String) : IO (Except String String) :=
  kubectl ["exec", pod, "-n", cfg.«namespace», "-c", "flared", "--", "sh", "-c", cmd]

private def t24Log (pod : String) : IO String := do
  match ← kubectl ["logs", pod, "-n", cfg.«namespace», "-c", "flared", "--tail=-1"] with
  | .ok l => return l
  | .error _ => return ""

private def t24Count (hay needle : String) : Nat := (hay.splitOn needle).length - 1

private def t24Fqdn (pod : String) : String := s!"{pod}.{cfg.name}-nodes.{cfg.«namespace»}.svc.cluster.local"

/-- Undo every injection (each step on its own; a failure is printed). -/
private def t24Cleanup (slave : Option String) (master : Option String) : IO Unit := do
  match ← t24HostCmd "docker" ["exec", t24KindNode, "iptables", "-t", "raw", "-D", "PREROUTING", "-d", s!"{t24Blackhole}/32", "-j", "DROP"] with
  | .ok _ => pure ()
  | .error e => IO.eprintln s!"# T24 cleanup: blackhole rule: {e}"
  for pod in allPods do
    discard <| t24Sh pod s!"rm -f {t24Hold}"
  match slave, master with
  | some s, some _ => discard <| t24Sh s s!"grep -v '^{t24Blackhole} ' /etc/hosts > /tmp/h.t24 && cat /tmp/h.t24 > /etc/hosts"
  | _, _ => pure ()

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
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
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

    -- Test 4: the restore (marker + pod deletion; the startup hook swaps
    -- the checkpoint in, every key must read back) WITH T24 reproduced in it.
    -- E2E 38250389416 ran the reproduction as a SECOND restore after this
    -- one: the history had moved on, so the operator rightly promoted
    -- neither copy ("partition 0 has NO master … unfit … waiting for the
    -- ex-master") and no staged rebuild started — a test design error. The
    -- first restore is the flow T24 happened in.
    -- (T24, review 2026-10-12 round 8): a CONTROLLED reproduction of
    -- what T24 showed — the replica's WAL-sync lookups reach the current
    -- master, but the staged rebuild's size probe makes its own lookup and
    -- gets an address that black-holes. The stop point holds the attempt
    -- right before that probe; only then is the stale answer put in the
    -- replica's resolver (/etc/hosts, first in nsswitch), and it is taken
    -- out again once the probe has used it. Repeated for 40 s. Then: the
    -- replica must be rebuilt from the CURRENT master, through the normal
    -- identity and history checks (no address pinned, nothing skipped),
    -- within 120 s after the stale answers end — not after the operator's
    -- 5 min resume backoff of a parked rebuild.
    { name := s!"restore: all {totalKeys} keys back after pod recreation, with T24 reproduced: the size probe's own lookup returns a black-holed address for 40 s while the attempt's other lookups stay current — the replica is rebuilt from the current master (identity and history checked) within 120 s after the stale answers end"
      run := do
        for pod in allPods do
          match ← t24Sh pod s!"echo {dataDir}/backups/{backupName} > {dataDir}/RESTORE && touch {t24Hold}" with
          | .ok _ => pure ()
          | .error e => return .fail s!"precondition: RESTORE marker / stop point on {pod}: {e}"
        for pod in allPods do
          match ← getPodIp pod cfg.«namespace» with
          | some ip => IO.eprintln s!"# T24 repro: pod IP BEFORE recreation of {pod}: {ip}"
          | none => pure ()
        match ← t24HostCmd "docker" ["exec", t24KindNode, "iptables", "-t", "raw", "-I", "PREROUTING", "-d", s!"{t24Blackhole}/32", "-j", "DROP"] with
        | .error e => t24Cleanup none none; return .fail s!"precondition: blackhole rule on the kind node: {e}"
        | .ok _ => pure ()
        let _ ← kubectl (["delete", "pod"] ++ allPods ++ ["-n", cfg.«namespace», "--force", "--grace-period=0"])
        -- which pod's staged rebuild reaches the size probe (the replica)
        let heldRef ← IO.mkRef (none : Option String)
        let _ ← waitForCondition "a replica's staged rebuild held at the size probe" 180 do
          for pod in allPods do
            if t24Count (← t24Log pod) "held by FLARE_TEST_STAGED_PROBE_HOLD_FILE" > 0 then
              heldRef.set (some pod)
              return true
          return false
        let some slave := (← heldRef.get) | do
          t24Cleanup none none
          return .fail "precondition: no staged rebuild reached the size probe within 180 s (the reproduction did not happen; nothing about the product is shown)"
        let master ← currentP0Master
        let some m := master | do
          t24Cleanup (some slave) none
          return .fail "precondition: no P0 master while the replica is held"
        if m == slave then
          t24Cleanup (some slave) master
          return .fail s!"precondition: the held pod {slave} is the master"
        let mFqdn := t24Fqdn m
        IO.eprintln s!"# T24 repro: replica {slave} held at the size probe; its source {m} ({mFqdn}); master IP {(← getPodIp m cfg.«namespace»).getD "?"}"
        let staleStart ← IO.monoMsNow
        let mut cycles := 0
        let mut heldSeen := t24Count (← t24Log slave) "held by FLARE_TEST_STAGED_PROBE_HOLD_FILE"
        let mut resolvedSeen := 0
        let mut failure : Option String := none
        repeat
          -- the attempt is held right before the probe: make ONLY that
          -- lookup stale, release, and wait until the probe has used it
          match ← t24Sh slave s!"echo '{t24Blackhole} {mFqdn}' >> /etc/hosts && getent ahostsv4 {mFqdn} | awk 'NR==1\{print $1}'" with
          | .ok out => IO.eprintln s!"# T24 repro cycle {cycles + 1}: {mFqdn} now resolves (from {slave}) to {out.trim}"
          | .error e => failure := some s!"precondition: stale entry on {slave}: {e}"; break
          discard <| t24Sh slave s!"rm -f {t24Hold}"
          let before := resolvedSeen
          let used ← waitForCondition "the size probe connected to the black-holed address" 30 do
            return t24Count (← t24Log slave) s!"(resolved {t24Blackhole})" > before
          resolvedSeen := t24Count (← t24Log slave) s!"(resolved {t24Blackhole})"
          discard <| t24Sh slave s!"grep -v '^{t24Blackhole} ' /etc/hosts > /tmp/h.t24 && cat /tmp/h.t24 > /etc/hosts"
          cycles := cycles + 1
          if !used then
            failure := some s!"precondition: cycle {cycles}: the probe did not connect to {t24Blackhole} within 30 s"
            break
          if (← IO.monoMsNow) - staleStart ≥ 40000 then break
          -- the NEXT attempt's probe is held again (until 40 s have passed)
          discard <| t24Sh slave s!"touch {t24Hold}"
          let hb := heldSeen
          let again ← waitForCondition "the next attempt held at the size probe" (max 1 ((40000 - ((← IO.monoMsNow) - staleStart)) / 1000)) do
            return t24Count (← t24Log slave) "held by FLARE_TEST_STAGED_PROBE_HOLD_FILE" > hb
          heldSeen := t24Count (← t24Log slave) "held by FLARE_TEST_STAGED_PROBE_HOLD_FILE"
          if !again then break
        let staleEnd ← IO.monoMsNow
        t24Cleanup (some slave) master
        IO.eprintln s!"# T24 repro: {cycles} stale cycle(s) over {(staleEnd - staleStart) / 1000}s; probe connects to {t24Blackhole}: {resolvedSeen}"
        if let some f := failure then return .fail f
        let recovered ← waitForCondition "the replica rebuilt and Ready after the stale answers ended" 120 do
          let log ← t24Log slave
          match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» "{.status.readyReplicas}" with
          | .ok val => return (val.toNat?.getD 0 >= numPods) && containsSubstr log "staged rebuild DONE"
          | .error _ => return false
        let tookS := ((← IO.monoMsNow) - staleEnd) / 1000
        let log ← t24Log slave
        let hits := (log.splitOn "\n").filter fun l =>
          containsSubstr l "(resolved " || containsSubstr l "rebuild_blocked" || containsSubstr l "PARKED"
            || containsSubstr l "size probe" || containsSubstr l "staging copy" || containsSubstr l "staged rebuild"
            || containsSubstr l "reconstruction attempt" || containsSubstr l "source did not answer"
        IO.eprintln s!"# T24 repro evidence {slave}: {hits.length} line(s){String.join ((hits.take 60).map ("\n#   " ++ ·))}"
        if !recovered then
          return .fail s!"the replica {slave} was not rebuilt and Ready within 120 s after the stale answers ended ({cycles} stale cycle(s); parks: {t24Count log "reconstruction PARKED"})"
        IO.eprintln s!"# T24 repro: rebuilt and Ready {tookS}s after the stale answers ended; parks: {t24Count log "reconstruction PARKED"}"
        -- rebuilt from the CURRENT master, its identity and history checked
        if !containsSubstr log "verified: lineage" then
          return .fail "no 'staging copy … verified: lineage …, history …' line: the identity/history check is not shown"
        match ← getPodIp m cfg.«namespace» with
        | none => return .fail s!"could not get IP for {m}"
        | some ip => assertAllKeysSurvive ip }
  ]
}

end FlareOperator.E2E.Tests.BackupRestore
