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
private def seedPvc (c : ClusterConfig) (i : Nat) (mode : String) (srcDir : String := "") : IO (Except String String) := do
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
    | "incomplete" => s!"f=$(ls {dataDir}/backups/{backupName}/*.sst | head -1) && [ -n \"$f\" ] && rm -f $f && [ ! -e $f ] && echo REMOVED $f && echo {dataDir}/backups/{backupName} > {dataDir}/RESTORE"
    | _ => s!"cp -a {dataDir}/backups/{backupName} {dataDir}/flare.rocksdb && echo mismatch-{c.name}:1 > {dataDir}/flare.rocksdb/COPY_ID"
  let out ← match ← kubectl ["exec", "-n", ns, helper, "--", "sh", "-c", script] with
    | .error e => return .error s!"seed script on {helper}: {e}"
    | .ok o => pure o.trim
  IO.eprintln s!"# seeded {pvc} ({mode}): {out}"
  discard <| kubectl ["delete", "pod", helper, "-n", ns, "--wait=true", "--timeout=60s"]
  if mode == "incomplete" && !containsSubstr out "REMOVED " then
    return .error s!"the SST file was not shown removed on {pvc} ({out})"
  return .ok out

private def seedCluster (c : ClusterConfig) (mode : String) (srcDir : String := "") : IO (Except String Unit) := do
  discard <| kubectl ["create", "namespace", c.«namespace»]
  for i in List.range (c.partitions * c.replicas) do
    match ← seedPvc c i mode srcDir with
    | .error e => return .error e
    | .ok _ => pure ()
  return .ok ()


/-- Observe `c` for `secs`: (samples, samples in which the operator's map was
    READ with entries, masters seen). A sample that could not read the map is
    no evidence of "no master" (review: an observation failure is not a pass). -/
private def observeMasters (c : ClusterConfig) (secs : Nat) : IO (Nat × Nat × List String) := do
  let mut seen : List String := []
  let mut samples := 0
  let mut observed := 0
  for _ in [0:secs / 5] do
    samples := samples + 1
    -- a sample slot counts only when the map WAS read in it; a transient read
    -- failure is retried inside the slot (up to 3 reads, CI 37834294217:
    -- 35/36), never skipped — every slot must still be observed
    let mut entries := []
    for _ in [0:3] do
      if entries.isEmpty then
        entries := parseNodeSync (← operatorTcpCmd c.debugPod c.«namespace» c.operatorName c.operatorPort "node sync")
        if entries.isEmpty then IO.sleep 1000
    if !entries.isEmpty then
      observed := observed + 1
      if let some m := findMasterPod entries 0 then
        if !seen.contains m then seen := seen ++ [m]
    IO.sleep 5000
  return (samples, observed, seen)

/-- A replica's OWN copy (the `dump` op reads local storage; never a proxied value). -/
private def localDump (c : ClusterConfig) (ip : String) : IO (Option (List (String × String))) := do
  let out ← IO.Process.output { cmd := "timeout", args := #["-k", "5", "90", "kubectl", "exec", c.debugPod, "-n", c.«namespace», "--", "sh", "-c",
      s!"printf 'dump 0 -1 0 0\\r\\nquit\\r\\n' | nc -w 60 {ip} {c.flarePort}"] }
  if out.exitCode != 0 then return none
  let mut acc : List (String × String) := []
  let mut pending : Option String := none
  let mut ended := false
  for raw in out.stdout.splitOn "\n" do
    let l := (raw.replace "\r" "").trim
    match pending with
    | some k =>
      acc := (k, l) :: acc
      pending := none
    | none =>
      if l.startsWith "VALUE " then
        pending := ((l.splitOn " ").drop 1).head?
      else if l == "END" then ended := true
  return if ended then some acc.reverse else none

/-- Every flared log line (previous and current containers) of `c`'s pods. -/
private def podLogs (c : ClusterConfig) : IO String := do
  let mut acc := ""
  for p in podsOf c do
    for extra in [["--previous"], []] do
      match ← kubectl (["logs", "-n", c.«namespace», p, "-c", "flared", "--tail=-1"] ++ extra) with
      | .ok o => acc := acc ++ o
      | .error _ => pure ()
  return acc

private def operatorLog (c : ClusterConfig) : IO String := do
  match ← kubectl ["logs", "-n", c.«namespace», "-l", s!"app={c.operatorName}", "--tail=-1"] with
  | .ok o => return o
  | .error _ => return ""

private def deployOrFail (c : ClusterConfig) : IO (Except String Unit) := do
  try
    deployCluster c
    return .ok ()
  catch e => return .error s!"deploying {c.name} failed: {e}"

/-- The observation of a negative case: complete (every sample read the map)
    or a failure. -/
private def negativeObservation (c : ClusterConfig) (secs : Nat) : IO (Except String (List String)) := do
  let (samples, observed, seen) ← observeMasters c secs
  IO.eprintln s!"# {c.name}: {observed}/{samples} samples read the operator's map; masters seen {seen}"
  if samples == 0 || observed != samples then
    return .error s!"the operator's map was read in only {observed}/{samples} samples: no evidence either way (not a pass)"
  return .ok seen

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
        if let .error e ← deployOrFail posCfg then return .fail e
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
        -- every key and value on the replica's OWN copy (dump reads local
        -- storage; a GET there may be proxied to the master)
        let expected := (List.range nKeys).map (fun i => (s!"rst_{i}", s!"val_{i}")) ++ (List.range 10).map (fun i => (s!"after_{i}", s!"val_{i}"))
        let mut lastMissing : List String := []
        let replicated ← waitForCondition "every key and value, including the writes after the restore, on the other copy's own storage" 180 do
          let oip := (← getPodIp other posCfg.«namespace»).getD ""
          match ← localDump posCfg oip with
          | none => return false
          | some d =>
            let miss := expected.filterMap fun (k, v) => if d.lookup k == some v then none else some s!"{k}={(d.lookup k).getD "(absent)"}"
            return miss.isEmpty
        if !replicated then
          let oip := (← getPodIp other posCfg.«namespace»).getD ""
          let d ← localDump posCfg oip
          lastMissing := match d with
            | none => ["(the local dump could not be read)"]
            | some d => expected.filterMap fun (k, v) => if d.lookup k == some v then none else some s!"{k}={(d.lookup k).getD "(absent)"}"
          return .fail s!"the other copy {other} does not hold every key and value locally: {lastMissing.take 8}"
        return .pass },

    { name := "[harness RESTORE hook path] an INCOMPLETE backup (an SST file missing) restored into an isolated new cluster is not promoted"
      run := do
        if let .error e ← seedCluster incCfg "incomplete" then return .fail s!"precondition: {e}"
        if let .error e ← deployOrFail incCfg then return .fail e
        let seen ← match ← negativeObservation incCfg 180 with
          | .error e => return .fail e
          | .ok s => pure s
        if !seen.isEmpty then
          let mut detail : List String := []
          for p in seen do
            let ip := (← getPodIp p incCfg.«namespace»).getD ""
            -- a REAL read (none = flared did not answer; getCurrItems turned a
            -- failed read into 0, CI f37a5b4/807ae59) and the restarts
            let restarts := ((← kubectlGetJsonpath "pod" p incCfg.«namespace» "{.status.containerStatuses[0].restartCount}").toOption.getD "?").trim
            detail := detail ++ [s!"{p} items={← statOf incCfg ip "curr_items"} restarts={restarts}"]
          -- CI f37a5b4: an EMPTY master (items=0) after two passing runs. Say
          -- whether the restored copy was ever refused (the seed took effect)
          -- or flared opened a fresh DB (the seed did not: a harness failure)
          let logs ← podLogs incCfg
          let refusedOpen := containsSubstr logs "RocksDB::Open() failed"
          let freshDb := containsSubstr logs "replication generations (source_epoch=1:"
          return .fail s!"a copy restored from an incomplete backup was made master: {detail}; flared refused the restored copy at some point={refusedOpen}; a FRESH DB was minted (generation 1)={freshDb}"
        -- the product's own reason: flared refused to open the restored copy
        let logs ← podLogs incCfg
        -- the product's reason: the restore hook refused the unreadable backup
        -- before replacing anything (no live copy: the pod does not start),
        -- or flared refused to open it
        if !(containsSubstr logs "RESTORE REFUSED" || containsSubstr logs "RocksDB::Open() failed") then
          return .fail "not promoted, but neither the restore hook ('RESTORE REFUSED') nor flared ('RocksDB::Open() failed') logged a refusal of the incomplete copy: the reason is not shown"
        return .pass },

    { name := "[copy placed directly, no hook] an IDENTITY-INCONSISTENT restored copy (COPY_ID != the reserved key) does not act as a master: never mapped as master, or flared refuses it (promotion_refused=1) and acknowledges no write"
      run := do
        if let .error e ← seedCluster idCfg "identity" then return .fail s!"precondition: {e}"
        if let .error e ← deployOrFail idCfg then return .fail e
        -- the tamper took effect: flared itself reports the identity inconsistent
        let inconsistent ← waitForCondition "both restored copies report their identity inconsistent" 180 do
          let mut all := true
          for p in podsOf idCfg do
            let ip := (← getPodIp p idCfg.«namespace»).getD ""
            if (← statOf idCfg ip "rocksdb_copy_identity_consistent") != some "0" then all := false
          return all
        if !inconsistent then return .fail "precondition: the restored copies do not report rocksdb_copy_identity_consistent 0"
        let seen ← match ← negativeObservation idCfg 120 with
          | .error e => return .fail e
          | .ok s => pure s
        for p in seen do
          let ip := (← getPodIp p idCfg.«namespace»).getD ""
          let refused ← statOf idCfg ip "promotion_refused"
          let acked ← memcachedSet idCfg.debugPod idCfg.«namespace» ip idCfg.flarePort "probe" "x"
          IO.eprintln s!"# {p}: promotion_refused={refused}; rocksdb_copy_identity_consistent={← statOf idCfg ip "rocksdb_copy_identity_consistent"}; write acknowledged={acked}"
          if refused != some "1" || acked then
            return .fail s!"{p} acts as a master over an identity-inconsistent copy (promotion_refused={refused}, write acknowledged={acked})"
        -- the product's own reason, from the operator or flared
        let reason := containsSubstr (← operatorLog idCfg) "copy identity records disagree"
          || containsSubstr (← podLogs idCfg) "PROMOTION REFUSED"
        if !reason then return .fail "not acting as master, but neither the operator ('copy identity records disagree') nor flared ('PROMOTION REFUSED') logged the reason"
        return .pass },

    { name := "[harness RESTORE hook path] a backup of ANOTHER partition (P1 of a two-partition source) restored into a one-partition cluster does not act as its master (never mapped, or flared refuses it for its partition binding) — a failure here is a PRODUCT GAP"
      run := do
        if let .error e ← deployOrFail src2Cfg then return .fail s!"precondition: {e}"
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
        if let .error e ← deployOrFail partCfg then return .fail e
        let seen ← match ← negativeObservation partCfg 180 with
          | .error e => return .fail e
          | .ok s => pure s
        -- the provenance travelled with the backup: every restored copy
        -- reports P1-of-2's binding and is an UNVERIFIED restored copy
        for p in podsOf partCfg do
          let ip := (← getPodIp p partCfg.«namespace»).getD ""
          let b ← statOf partCfg ip "rocksdb_partition_binding"
          IO.eprintln s!"# {p}: rocksdb_partition_binding={b}; rocksdb_restored_unverified={← statOf partCfg ip "rocksdb_restored_unverified"}; promotion_refused={← statOf partCfg ip "promotion_refused"}"
          if !((b.getD "").startsWith "v1 partition=1 partitions=2 ") then
            return .fail s!"precondition: {p} does not report the backup's binding (P1 of 2): {b} — the provenance did not travel with the backup"
        -- the PRODUCT decision (same criterion as the identity-inconsistent
        -- case): never mapped as master, or — the first master of a new
        -- cluster is mapped by `node add` without a read — flared refuses to
        -- act as master over it (promotion_refused=1, no write acknowledged)
        -- and says why (restore provenance)
        for p in seen do
          let ip := (← getPodIp p partCfg.«namespace»).getD ""
          let refused ← statOf partCfg ip "promotion_refused"
          let acked ← memcachedSet partCfg.debugPod partCfg.«namespace» ip partCfg.flarePort "probe" "x"
          IO.eprintln s!"# {p} mapped as master: promotion_refused={refused}; write acknowledged={acked}"
          if refused != some "1" || acked then
            return .fail s!"PRODUCT GAP: {p}, holding only partition 1's slice ({p1Items} of {nKeys} keys) of a two-partition cluster, ACTS as the master of a one-partition cluster (promotion_refused={refused}, write acknowledged={acked})"
        let logs ← podLogs partCfg
        let opLog ← operatorLog partCfg
        let reason := (containsSubstr logs "PROMOTION REFUSED" && containsSubstr logs "RESTORED copy bound to")
          || containsSubstr opLog "restore provenance"
        if !reason then return .fail "not acting as master, but neither flared ('PROMOTION REFUSED … RESTORED copy bound to') nor the operator ('restore provenance') logged the partition reason: UNEXPLAINED"
        return .pass },

    { name := "[product RESTORE hook, in place] a RESTORE marker naming ANOTHER partition's backup (P1's checkpoint on P0's pod) is refused BEFORE the live copy is replaced: the pod comes back serving its own data, the marker is renamed RESTORE.refused with the reason"
      run := do
        let ns2 := src2Cfg.«namespace»
        let entries ← nodeView src2Cfg
        let some p0 := findMasterPod entries 0 | return .fail "precondition: no P0 master in the two-partition source (test 5 deploys it)"
        let p0Ip := (← getPodIp p0 ns2).getD ""
        let some before := (← statOf src2Cfg p0Ip "curr_items").bind String.toNat? | return .fail "precondition: P0's items could not be read"
        let live ← statOf src2Cfg p0Ip "rocksdb_partition_binding"
        if !((live.getD "").startsWith "v1 partition=0 ") then return .fail s!"precondition: P0 is not bound to partition 0 ({live})"
        -- P1's checkpoint (copied out by test 5) placed on P0's PVC, and the marker
        match ← kubectl ["cp", s!"{← localCopy}/p1/{backupName}", s!"{ns2}/{p0}:{dataDir}/backups/other-p1", "-c", "flared"] with
        | .error e => return .fail s!"precondition: placing P1's checkpoint on {p0}: {e}"
        | .ok _ => pure ()
        if let .error e ← kubectl ["exec", "-n", ns2, p0, "-c", "flared", "--", "sh", "-c", s!"echo {dataDir}/backups/other-p1 > {dataDir}/RESTORE"] then
          return .fail s!"precondition: writing the RESTORE marker: {e}"
        discard <| kubectl ["delete", "pod", p0, "-n", ns2, "--wait=false"]
        let back ← waitForCondition s!"{p0} is back and answers stats" 240 do
          match ← getPodIp p0 ns2 with
          | some ip => return (← statOf src2Cfg ip "curr_items").isSome
          | none => return false
        if !back then return .fail s!"{p0} did not come back after the refused restore"
        let ip := (← getPodIp p0 ns2).getD ""
        let after := (← statOf src2Cfg ip "curr_items").bind String.toNat?
        let bound ← statOf src2Cfg ip "rocksdb_partition_binding"
        let restored ← statOf src2Cfg ip "rocksdb_restored_unverified"
        let files ← kubectl ["exec", "-n", ns2, p0, "-c", "flared", "--", "sh", "-c", s!"ls {dataDir}; cat {dataDir}/RESTORE.refused.reason 2>/dev/null"]
        let logs ← kubectl ["logs", "-n", ns2, p0, "-c", "flared", "--tail=-1"]
        IO.eprintln s!"# after the refused restore: items {before} -> {after}; binding {bound}; restored_unverified {restored}; data dir: {files.toOption.getD "?"}"
        if after != some before then return .fail s!"the live copy changed (items {before} -> {after}): the restore was not refused before the replacement"
        if !((bound.getD "").startsWith "v1 partition=0 ") || restored != some "0" then
          return .fail s!"the live copy is not the one it was (binding {bound}, restored_unverified {restored})"
        let entriesNow := ((files.toOption.getD "").splitOn "\n").map String.trim
        if !entriesNow.contains "RESTORE.refused" || entriesNow.contains "RESTORE" then
          return .fail s!"the marker was not renamed RESTORE.refused: {files.toOption.getD "?"}"
        if !containsSubstr (logs.toOption.getD "") "RESTORE REFUSED" then
          return .fail "the hook's refusal ('RESTORE REFUSED') is not in the pod log"
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

private def localDumpRep (ip : String) : IO (Option (List (String × String))) := localDump repCfg ip

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
        -- the operator's committed map version (fresh each time it is read):
        -- the `version=` line of the PERSISTED node map. CI 37834294217 read a
        -- FlareCluster annotation that is never written (vnone); the Lease's
        -- node-map-persisted marker is set once, at the first persist, so it
        -- is not the current version either.
        let desired : IO (Option Nat) := do
          match ← kubectlGetJsonpath "configmap" s!"{repCfg.name}-node-map" ns "{.data.nodeMap}" with
          | .ok d => return ((d.splitOn "\n").findSome? fun l =>
              let t := l.trim
              if t.startsWith "version=" then (t.drop "version=".length).toNat? else none)
          | .error _ => return none
        let ver := fun (ip : String) => do return ((← statOf repCfg ip "node_map_version").bind String.toNat?)
        let mut acked : List (String × String) := []
        for round in List.range 4 do
          let some m ← masterPod repCfg | return .fail s!"round {round}: no master"
          let s := ((podsOf repCfg).filter (· != m)).head?.getD ""
          let mIp := (← getPodIp m ns).getD ""
          let pre := (List.range 10).map fun i => (s!"r{round}_pre_{i}", s!"v{round}p{i}")
          for (k, v) in pre do
            if !(← memcachedSet repCfg.debugPod ns mIp repCfg.flarePort k v) then
              return .fail s!"round {round}: the master {m} did not acknowledge {k} before the promotion"
          acked := acked ++ pre
          let caught ← waitForCondition s!"round {round}: {s} holds every key" 120 do
            let sIp := (← getPodIp s ns).getD ""
            return (← getCurrItems repCfg.debugPod ns sIp repCfg.flarePort) == (← getCurrItems repCfg.debugPod ns mIp repCfg.flarePort)
          if !caught then return .fail s!"round {round}: {s} did not catch up before the promotion"
          let sIp := (← getPodIp s ns).getD ""
          let some v0 ← ver sIp | return .fail s!"round {round}: precondition: {s}'s node_map_version could not be read"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let promoted ← waitForCondition s!"round {round}: {s} is promoted" 180 do
            return (← masterPod repCfg) == some s
          if !promoted then return .fail s!"round {round}: {s} was not promoted after {m} was deleted"
          let post := (List.range 10).map fun i => (s!"r{round}_post_{i}", s!"v{round}q{i}")
          for (k, v) in post do
            if !(← memcachedSet repCfg.debugPod ns sIp repCfg.flarePort k v) then
              return .fail s!"round {round}: the NEW master {s} did not acknowledge {k} (node_map_version {← statOf repCfg sIp "node_map_version"}, promotion_refused {← statOf repCfg sIp "promotion_refused"})"
          acked := acked ++ post
          -- both nodes on the operator's committed version (read fresh), past
          -- the promotion, and the ex-master following the new master
          let converged ← waitForCondition s!"round {round}: both nodes on the operator's committed map, past the promotion; the ex-master follows {s}" 480 do
            match ← getPodIp m ns, ← desired with
            | some ip, some d =>
              let vs ← ver sIp
              let vm ← ver ip
              return vs == some d && vm == some d && d > v0 && (← statOf repCfg ip "repl_follow_state") == some "following"
            | _, _ => return false
          if !converged then
            let mIp2 := (← getPodIp m ns).getD ""
            return .fail s!"round {round}: maps did not converge (operator committed v{← desired}; new master {s} v{← ver sIp} (was v{v0}); ex-master {m} v{← ver mIp2}, follow {← statOf repCfg mIp2 "repl_follow_state"})"
          -- every acknowledged value so far, on BOTH copies' own storage
          for p in [s, m] do
            let pip := (← getPodIp p ns).getD ""
            let ok ← waitForCondition s!"round {round}: {p} holds every acknowledged value locally" 120 do
              match ← localDumpRep pip with
              | none => return false
              | some d => return acked.all fun (k, v) => d.lookup k == some v
            if !ok then
              let missing := match ← localDumpRep pip with
                | none => ["(the local dump could not be read)"]
                | some d => acked.filterMap fun (k, v) => if d.lookup k == some v then none else some s!"{k}={(d.lookup k).getD "(absent)"}"
              return .fail s!"round {round}: {p} lacks acknowledged values locally: {missing.take 8}"
          IO.eprintln s!"# round {round}: {m} -> {s}; 10/10 acknowledged before and after; both nodes on the committed map (past v{v0}); {acked.length} acknowledged values on both copies"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.RestoreIsolated
