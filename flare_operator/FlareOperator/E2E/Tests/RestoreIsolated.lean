/-
  E2E/Tests/RestoreIsolated.lean — R8 restore into an ISOLATED new cluster,
  verified in CI only (docs/plan-restore-adoption.md option II; NOT an
  approval of II as the production procedure, and it does not close the
  backup-restore R8 failure).

  WHICH PATH IS EXERCISED: the E2E harness's RESTORE hook (Setup.lean: the
  chart's Case A hook PLUS a RESTORED marker) on PVCs seeded before the first
  boot. NOT the chart's object-storage backupBootstrap (its RESTORED marker,
  manifest and partition checks are not run here): a pass of this suite is
  no evidence for that path.

  restore-isolated: a SOURCE cluster takes a checkpoint; each case restores it
  into a NEW cluster in its own namespace whose PVCs are seeded BEFORE the
  StatefulSet exists (a helper pod writes the checkpoint and the RESTORE
  marker), so flared opens the restored copy on its very first boot and the
  operator builds the cluster for the first time. Required:
    * positive: a master, every key and value, a write after the restore is
      acknowledged and replicated;
    * an INCOMPLETE backup (an SST file missing) is not promoted;
    * an IDENTITY-INCONSISTENT copy (COPY_ID file != the reserved key) does not
      act as a master (not in the map as master, or flared refuses it:
      promotion_refused=1 and no write acknowledged);
    * the source cluster and the source backup are UNCHANGED.
    * a backup of ANOTHER partition (partition 1 of a two-partition source,
      restored into a one-partition cluster) is not promoted. If the product
      does not check the partition, this test FAILS: a product gap reported
      as such (the test is not weakened).
  The negative cases only change the seeded data; flared and the operator do
  the refusing — no harness check stands in for the product.

  promotion-repeat: planned promotions (graceful drain) several times in a
  row; after each, the new master acknowledges writes and its node map
  advances with the cluster's (CI 37770467697: a promoted node stopped
  accepting maps and writes).
-/

import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.RestoreIsolated

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def baseCfg (name ns debug : String) : ClusterConfig := {
  name := name
  «namespace» := ns
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := debug
  storageBackend := "rocksdb"
  usePvc := true
}

private def srcCfg : ClusterConfig := baseCfg "rst-src" "flare-rst-src" "debug-rst-src"
-- a two-partition source: the other-partition backup comes from its P1
private def src2Cfg : ClusterConfig := { baseCfg "rst-src2" "flare-rst-src2" "debug-rst-src2" with partitions := 2, replicas := 1 }
private def partCfg : ClusterConfig := baseCfg "rst-part" "flare-rst-part" "debug-rst-part"
private def posCfg : ClusterConfig := baseCfg "rst-pos" "flare-rst-pos" "debug-rst-pos"
private def incCfg : ClusterConfig := baseCfg "rst-inc" "flare-rst-inc" "debug-rst-inc"
private def idCfg : ClusterConfig := baseCfg "rst-id" "flare-rst-id" "debug-rst-id"

private def backupName : String := "rst-point"
private def dataDir : String := "/data/flare"
private def nKeys : Nat := 50

private def nodeView (c : ClusterConfig) : IO (List NodeSyncEntry) := do
  return parseNodeSync (← operatorTcpCmd c.debugPod c.«namespace» c.operatorName c.operatorPort "node sync")

private def masterPod (c : ClusterConfig) : IO (Option String) := do
  return findMasterPod (← nodeView c) 0

private def statOf (c : ClusterConfig) (ip key : String) : IO (Option String) := do
  match ← execInDebugPod c.debugPod c.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {c.flarePort}" with
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := (l.replace "\r" "").trim
      if t.startsWith s!"STAT {key} " then some (t.drop (s!"STAT {key} ").length) else none
  | .error _ => return none

private def podsOf (c : ClusterConfig) : List String :=
  (List.range (c.partitions * c.replicas)).map fun i => s!"{c.name}-nodes-{i}"

/-- What must not change on the source: items per pod, the master's history,
    pod UIDs, and the backup's content hash on every pod. -/
private def sourceFingerprint : IO String := do
  let mut parts : List String := []
  for p in podsOf srcCfg do
    let ip := (← getPodIp p srcCfg.«namespace»).getD ""
    let items ← getCurrItems srcCfg.debugPod srcCfg.«namespace» ip srcCfg.flarePort
    let epoch := (← statOf srcCfg ip "rocksdb_source_epoch").getD "?"
    let uid := match ← kubectlGetJsonpath "pod" p srcCfg.«namespace» "{.metadata.uid}" with
      | .ok u => u.trim
      | .error _ => "?"
    let hash := match ← kubectl ["exec", "-n", srcCfg.«namespace», p, "--", "sh", "-c",
        s!"cd {dataDir}/backups/{backupName} && find . -type f | sort | xargs sha256sum | sha256sum | cut -c1-16"] with
      | .ok h => h.trim
      | .error e => s!"?({e.take 40})"
    parts := parts ++ [s!"{p}: items={items} epoch={epoch} uid={uid} backup={hash}"]
  return String.intercalate "; " parts

private def localCopy : IO String := do
  let pid ← IO.Process.getPID
  return s!"/tmp/flare-rst-{pid}"

/-- Seed one PVC of `c` with the source checkpoint through a helper pod.
    `mode`: "restore" (RESTORE marker: the restore hook swaps it in and marks
    it RESTORED), "incomplete" (the same, one SST removed), "identity" (placed
    directly as the live copy with a COPY_ID that disagrees with its key). -/
private def seedPvc (c : ClusterConfig) (i : Nat) (mode : String) (srcDir : String := "") : IO (Except String Unit) := do
  let ns := c.«namespace»
  let pvc := s!"data-{c.name}-nodes-{i}"
  let helper := s!"seed-{c.name}-{i}"
  let yaml := s!"apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {pvc}
  namespace: {ns}
spec:
  accessModes: [\"ReadWriteOnce\"]
  resources:
    requests:
      storage: {c.pvcSize}
---
apiVersion: v1
kind: Pod
metadata:
  name: {helper}
  namespace: {ns}
spec:
  restartPolicy: Never
  containers:
    - name: seed
      image: {c.debugImage}
      command: [\"sleep\", \"3600\"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: {pvc}"
  match ← kubectlApplyStdin yaml with
  | .error e => return .error s!"seed objects for {pvc}: {e}"
  | .ok _ => pure ()
  if !(← kubectlWaitReady s!"pod/{helper}" ns 120) then return .error s!"helper {helper} not ready"
  let local_ ← localCopy
  discard <| kubectl ["exec", "-n", ns, helper, "--", "mkdir", "-p", s!"{dataDir}/backups"]
  let srcPath := if srcDir.isEmpty then s!"{local_}/{backupName}" else s!"{local_}/{srcDir}/{backupName}"
  match ← kubectl ["cp", srcPath, s!"{ns}/{helper}:{dataDir}/backups/{backupName}"] with
  | .error e => return .error s!"copy into {helper}: {e}"
  | .ok _ => pure ()
  let script := match mode with
    | "restore" => s!"echo {dataDir}/backups/{backupName} > {dataDir}/RESTORE"
    | "incomplete" => s!"f=$(ls {dataDir}/backups/{backupName}/*.sst | head -1) && rm -f $f && echo removed $f && echo {dataDir}/backups/{backupName} > {dataDir}/RESTORE"
    | _ => s!"cp -a {dataDir}/backups/{backupName} {dataDir}/flare.rocksdb && echo mismatch-{c.name}:1 > {dataDir}/flare.rocksdb/COPY_ID"
  match ← kubectl ["exec", "-n", ns, helper, "--", "sh", "-c", script] with
  | .error e => return .error s!"seed script on {helper}: {e}"
  | .ok o => IO.eprintln s!"# seeded {pvc} ({mode}): {o.trim}"
  discard <| kubectl ["delete", "pod", helper, "-n", ns, "--wait=true", "--timeout=60s"]
  return .ok ()

private def seedCluster (c : ClusterConfig) (mode : String) (srcDir : String := "") : IO (Except String Unit) := do
  discard <| kubectl ["create", "namespace", c.«namespace»]
  for i in List.range (c.partitions * c.replicas) do
    match ← seedPvc c i mode srcDir with
    | .error e => return .error e
    | .ok _ => pure ()
  return .ok ()

/-- Observe `c` for `secs`: every master seen in the operator's map. -/
private def mastersSeen (c : ClusterConfig) (secs : Nat) : IO (List String) := do
  let mut seen : List String := []
  for _ in [0:secs / 5] do
    if let some m ← masterPod c then
      if !seen.contains m then seen := seen ++ [m]
    IO.sleep 5000
  return seen

def suite : TestSuite := {
  name := "restore-isolated"
  setup := do
    deployCluster srcCfg
    IO.sleep 30000
  teardown := do
    for c in [posCfg, incCfg, idCfg, partCfg, src2Cfg, srcCfg] do
      cleanupCluster c
    discard <| IO.Process.output { cmd := "rm", args := #["-rf", ← localCopy] }
  onFailure := dumpClusterDiagnostics srcCfg.«namespace» s!"app={srcCfg.operatorName}"
  tests := [
    { name := "source: keys written, a checkpoint taken on the master and copied out (fingerprint recorded)"
      run := do
        let some m ← masterPod srcCfg | return .fail "precondition: no source master"
        let ip := (← getPodIp m srcCfg.«namespace»).getD ""
        let stored ← writeKeys srcCfg.debugPod srcCfg.«namespace» ip srcCfg.flarePort "rst" nKeys
        if stored != nKeys then return .fail s!"precondition: stored {stored}/{nKeys}"
        let caught ← waitForCondition "the source replica holds every key" 120 do
          let others := (podsOf srcCfg).filter (· != m)
          let mut ok := true
          for p in others do
            let pip := (← getPodIp p srcCfg.«namespace»).getD ""
            if (← getCurrItems srcCfg.debugPod srcCfg.«namespace» pip srcCfg.flarePort) != nKeys then ok := false
          return ok
        if !caught then return .fail "precondition: the source replica did not converge"
        for p in podsOf srcCfg do
          let pip := (← getPodIp p srcCfg.«namespace»).getD ""
          match ← execInDebugPod srcCfg.debugPod srcCfg.«namespace» s!"printf 'backup {backupName}\\r\\n' | nc -w 10 {pip} {srcCfg.flarePort}" with
          | .ok o => IO.eprintln s!"# backup on {p}: {o.trim}"
          | .error e => return .fail s!"backup on {p}: {e}"
        let local_ ← localCopy
        discard <| IO.Process.output { cmd := "mkdir", args := #["-p", local_] }
        match ← kubectl ["cp", s!"{srcCfg.«namespace»}/{m}:{dataDir}/backups/{backupName}", s!"{local_}/{backupName}"] with
        | .error e => return .fail s!"copying the checkpoint out of {m}: {e}"
        | .ok _ => pure ()
        IO.FS.writeFile s!"{local_}/fingerprint" (← sourceFingerprint)
        IO.eprintln s!"# source fingerprint: {← IO.FS.readFile s!"{local_}/fingerprint"}"
        return .pass },

    { name := "[harness RESTORE hook path, not backupBootstrap] restore into an ISOLATED new cluster (PVCs seeded before its first boot): a master, every key and value, and a write after the restore acknowledged and replicated"
      run := do
        if let .error e ← seedCluster posCfg "restore" then return .fail s!"precondition: {e}"
        deployCluster posCfg
        let mastered ← waitForCondition "the restored cluster has a master" 300 do
          return (← masterPod posCfg).isSome
        if !mastered then return .fail "the restored cluster got no master"
        let some m ← masterPod posCfg | return .fail "no master"
        let ip := (← getPodIp m posCfg.«namespace»).getD ""
        let mut wrong : List String := []
        for i in List.range nKeys do
          let v ← memcachedGet posCfg.debugPod posCfg.«namespace» ip posCfg.flarePort s!"rst_{i}"
          if v != some s!"val_{i}" then wrong := wrong ++ [s!"rst_{i}={v}"]
        if !wrong.isEmpty then return .fail s!"{wrong.length} key(s) wrong or missing on the restored master: {wrong.take 5}"
        let stored ← writeKeys posCfg.debugPod posCfg.«namespace» ip posCfg.flarePort "after" 10
        if stored != 10 then return .fail s!"the restored master acknowledged {stored}/10 writes after the restore"
        let other := ((podsOf posCfg).filter (· != m)).head?.getD ""
        let replicated ← waitForCondition "the write after the restore reaches the other copy" 180 do
          let oip := (← getPodIp other posCfg.«namespace»).getD ""
          return (← getCurrItems posCfg.debugPod posCfg.«namespace» oip posCfg.flarePort) == nKeys + 10
        if !replicated then return .fail s!"the write after the restore did not reach {other}"
        return .pass },

    { name := "[harness RESTORE hook path] an INCOMPLETE backup (an SST file missing) restored into an isolated new cluster is not promoted"
      run := do
        if let .error e ← seedCluster incCfg "incomplete" then return .fail s!"precondition: {e}"
        deployCluster incCfg
        let seen ← mastersSeen incCfg 180
        IO.eprintln s!"# incomplete backup: masters seen in 180 s {seen}"
        if !seen.isEmpty then
          let mut detail : List String := []
          for p in seen do
            let ip := (← getPodIp p incCfg.«namespace»).getD ""
            detail := detail ++ [s!"{p} items={← getCurrItems incCfg.debugPod incCfg.«namespace» ip incCfg.flarePort}"]
          return .fail s!"a copy restored from an incomplete backup was made master: {detail}"
        return .pass },

    { name := "[copy placed directly, no hook] an IDENTITY-INCONSISTENT restored copy (COPY_ID != the reserved key) does not act as a master: never mapped as master, or flared refuses it (promotion_refused=1) and acknowledges no write"
      run := do
        if let .error e ← seedCluster idCfg "identity" then return .fail s!"precondition: {e}"
        deployCluster idCfg
        let seen ← mastersSeen idCfg 120
        IO.eprintln s!"# identity-inconsistent copies: masters seen {seen}"
        for p in seen do
          let ip := (← getPodIp p idCfg.«namespace»).getD ""
          let refused ← statOf idCfg ip "promotion_refused"
          let acked ← memcachedSet idCfg.debugPod idCfg.«namespace» ip idCfg.flarePort "probe" "x"
          IO.eprintln s!"# {p}: promotion_refused={refused}; rocksdb_copy_identity_consistent={← statOf idCfg ip "rocksdb_copy_identity_consistent"}; write acknowledged={acked}"
          if refused != some "1" || acked then
            return .fail s!"{p} acts as a master over an identity-inconsistent copy (promotion_refused={refused}, write acknowledged={acked})"
        return .pass },

    { name := "[harness RESTORE hook path] a backup of ANOTHER partition (P1 of a two-partition source) restored into a one-partition cluster is not promoted — a failure here is a PRODUCT GAP (no partition check), not weakened"
      run := do
        deployCluster src2Cfg
        IO.sleep 30000
        let ns2 := src2Cfg.«namespace»
        let entries ← nodeView src2Cfg
        let some p0 := findMasterPod entries 0 | return .fail "precondition: no P0 master in the two-partition source"
        let some p1 := findMasterPod entries 1 | return .fail "precondition: no P1 master in the two-partition source"
        let p0Ip := (← getPodIp p0 ns2).getD ""
        let stored ← writeKeys src2Cfg.debugPod ns2 p0Ip src2Cfg.flarePort "part" nKeys
        if stored != nKeys then return .fail s!"precondition: stored {stored}/{nKeys} in the two-partition source"
        let p1Ip := (← getPodIp p1 ns2).getD ""
        let p1Items ← getCurrItems src2Cfg.debugPod ns2 p1Ip src2Cfg.flarePort
        if p1Items == 0 || p1Items == nKeys then return .fail s!"precondition: P1 holds {p1Items} of {nKeys} keys (not a partial slice)"
        match ← execInDebugPod src2Cfg.debugPod ns2 s!"printf 'backup {backupName}\\r\\n' | nc -w 10 {p1Ip} {src2Cfg.flarePort}" with
        | .ok o => IO.eprintln s!"# backup on {p1} (P1, {p1Items} keys): {o.trim}"
        | .error e => return .fail s!"precondition: backup on {p1}: {e}"
        let local_ ← localCopy
        discard <| IO.Process.output { cmd := "mkdir", args := #["-p", s!"{local_}/p1"] }
        match ← kubectl ["cp", s!"{ns2}/{p1}:{dataDir}/backups/{backupName}", s!"{local_}/p1/{backupName}"] with
        | .error e => return .fail s!"precondition: copying P1's checkpoint out: {e}"
        | .ok _ => pure ()
        if let .error e ← seedCluster partCfg "restore" "p1" then return .fail s!"precondition: {e}"
        deployCluster partCfg
        let seen ← mastersSeen partCfg 180
        IO.eprintln s!"# other-partition backup: masters seen {seen}"
        if !seen.isEmpty then
          return .fail s!"PRODUCT GAP: a copy holding only partition 1's slice ({p1Items} of {nKeys} keys) of a two-partition cluster was made the master of a one-partition cluster ({seen}); the restore does not check the partition"
        return .pass },

    { name := "the SOURCE cluster and its backup are unchanged by every restore (items, history, pod UIDs, backup content hash)"
      run := do
        let before ← IO.FS.readFile s!"{← localCopy}/fingerprint"
        let after ← sourceFingerprint
        IO.eprintln s!"# source before: {before}\n# source after:  {after}"
        if before != after then return .fail s!"the source changed: before [{before}] after [{after}]"
        return .pass }
  ]
}

-- ─── repeated planned promotions ──────────────────────────────────────────

private def repCfg : ClusterConfig := {
  name := "prom-repeat"
  «namespace» := "flare-prom-repeat"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-prom-repeat"
  storageBackend := "rocksdb"
  extraFlaredConf := "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000"
  usePvc := true
  drainSeconds := 30
}

def repeatSuite : TestSuite := {
  name := "promotion-repeat"
  setup := do
    deployCluster repCfg
    IO.sleep 30000
  teardown := cleanupCluster repCfg
  onFailure := dumpClusterDiagnostics repCfg.«namespace» s!"app={repCfg.operatorName}"
  tests := [
    { name := "four planned promotions in a row: after each the new master acknowledges 10/10 writes, its node map advances past the promotion and matches the returning ex-master's, and the ex-master follows it"
      run := do
        let ns := repCfg.«namespace»
        let graceOver ← waitForCondition "operator past its startup grace period" 360 do
          return containsSubstr (← kubectlLogsLabel s!"app={repCfg.operatorName}" ns 200000) "grace period over"
        if !graceOver then return .fail "precondition: the operator never ended its startup grace period"
        IO.sleep 10000
        for round in List.range 4 do
          let some m ← masterPod repCfg | return .fail s!"round {round}: no master"
          let s := ((podsOf repCfg).filter (· != m)).head?.getD ""
          let mIp := (← getPodIp m ns).getD ""
          let pre ← writeKeys repCfg.debugPod ns mIp repCfg.flarePort s!"r{round}_pre" 10
          if pre != 10 then return .fail s!"round {round}: the master {m} acknowledged {pre}/10 before the promotion"
          let caught ← waitForCondition s!"round {round}: {s} holds every key" 120 do
            let sIp := (← getPodIp s ns).getD ""
            return (← getCurrItems repCfg.debugPod ns sIp repCfg.flarePort) == (← getCurrItems repCfg.debugPod ns mIp repCfg.flarePort)
          if !caught then return .fail s!"round {round}: {s} did not catch up before the promotion"
          let sIp := (← getPodIp s ns).getD ""
          let v0 := ((← statOf repCfg sIp "node_map_version").bind String.toNat?).getD 0
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let promoted ← waitForCondition s!"round {round}: {s} is promoted" 180 do
            return (← masterPod repCfg) == some s
          if !promoted then return .fail s!"round {round}: {s} was not promoted after {m} was deleted"
          let post ← writeKeys repCfg.debugPod ns sIp repCfg.flarePort s!"r{round}_post" 10
          if post != 10 then
            return .fail s!"round {round}: the NEW master {s} acknowledged {post}/10 writes (node_map_version {← statOf repCfg sIp "node_map_version"}, promotion_refused {← statOf repCfg sIp "promotion_refused"})"
          let converged ← waitForCondition s!"round {round}: the maps converge and the ex-master follows {s}" 480 do
            match ← getPodIp m ns with
            | none => return false
            | some ip =>
              let vs := ((← statOf repCfg sIp "node_map_version").bind String.toNat?).getD 0
              let vm := ((← statOf repCfg ip "node_map_version").bind String.toNat?).getD 0
              return vs > v0 && vs == vm && (← statOf repCfg ip "repl_follow_state") == some "following"
          if !converged then
            let mIp2 := (← getPodIp m ns).getD ""
            return .fail s!"round {round}: maps did not converge (new master {s} v{← statOf repCfg sIp "node_map_version"} (was v{v0}), ex-master {m} v{← statOf repCfg mIp2 "node_map_version"} follow {← statOf repCfg mIp2 "repl_follow_state"})"
          IO.eprintln s!"# round {round}: {m} -> {s}; 10/10 acknowledged on the new master; maps converged past v{v0}"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.RestoreIsolated
