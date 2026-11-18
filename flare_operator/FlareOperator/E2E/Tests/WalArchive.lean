/-
  E2E/Tests/WalArchive.lean — the continuous WAL archive on kind with an S3-compatible store
  (issue flare-wal-archive-e2e; docs/BACKUP_RESTORE.md, "WAL archive").

  What is real here: SeaweedFS's S3 server (a single pod and Service `minio`, the bucket made with
  aws-cli) is the object storage; the cluster is a REAL `helm install` of the
  chart (deployHelmCluster), so the StatefulSet's `backup-bootstrap` and
  `backup-wal-replay` init containers, the backup CronJob and its RBAC, the
  archiver Deployment (`follow` = flare-wal-follow in the flared image,
  `upload` = flare-wal-upload in the flare-backup image) and the
  `flare-backup-run` runner are the chart's own templates and the product's
  own scripts, not copies. The images `flare-node-rocksdb:test` and
  `flare-backup:test` are loaded into kind by the workflow (Dockerfile.backup
  is built in the legs that run this suite).

  Cluster: 1 partition x 2 replicas (master + slave), rocksdb on tmpfs (a
  deleted pod's data is gone, so deleting every pod is an all-copy loss),
  backupBootstrap on, the archive's segmentSeconds at its default (30). The
  backup CronJob exists (`<cluster>-backup`, suspended: it never fires by
  itself; the uploader and the tests run it with `kubectl create job
  --from=cronjob/...`). The suite starts with the archiver OFF and turns it
  on with `helm upgrade` (which is also what T3 toggles).

  T1  RPO under load: writes with replies (LoadWriter, every write must be
      STORED); a base; the archive runs for 5 minutes; the last ACKed write is
      T; every pod is force-deleted at once; the pods come back through
      backup-bootstrap + backup-wal-replay; every key ACKed before T - 60 s is
      on the new master with its value; the newest lost ACK is at most 60 s
      old; the replay summary says gap=0 conflict=0.
  T2  master switch: the master pod is deleted; the uploader stops the old
      chain (needs_base 1), a backup Job `<cluster>-backup-wal-*` appears, a
      new chain (another incarnation/epoch/master path in the bucket) is
      followed and `synced` advances again.
  T3  on/off without pod restarts: `walArchive.enabled` false then true (the
      Deployment is deleted and created); the flared pods' UIDs, restart
      counts and the StatefulSet's revision do not change; the archive resumes
      after the last uploaded segment (the first new segment starts at the
      last archived sequence + 1: not from the base again, no hole).
  T4  offline replay in a pod with the flared image: base + chain downloaded
      from the store; `flared --wal-replay` with an until time between two known
      writes (keys after it absent, before it present); a replay stopped part
      way (on half the segments, and killed with SIGKILL while running) and
      run again continues (exit 0, the same end state as one full run); a
      database written past the base by something else is refused (exit 3).
  T6  the restored data is exactly what was written: keys written before a
      base, then (only in the archive) overwritten, deleted, deleted and
      written again, and new keys likewise; with the archive synced past the
      last write, every pod is deleted; on EVERY restored copy the test's keys
      are exactly the expected key/value set (none missing, none with another
      value, none deleted that came back), and the replay applied at least
      the writes made after the base (so the archive, not the base alone,
      produced them).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.E2E.LoadWriter
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.WalArchive

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl

def cfg : ClusterConfig :=
  { name := "walarc", «namespace» := "flare-wal-archive", partitions := 1, replicas := 2,
    debugPod := "debug-wal-archive", storageBackend := "rocksdb", useTmpfs := true, usePvc := false,
    -- the release's fullname: its ClusterRole/Binding must not collide with the
    -- operator CI installed from the chart (44290874757: "ClusterRole flare-operator exists")
    operatorName := "flare-operator-walarc" }

private def nsName : String := cfg.«namespace»
private def cluster : String := cfg.name
private def bucket : String := "flare-wal-archive"
private def secretName : String := "wal-archive-s3"
private def accessKey : String := "e2eaccesskey"
private def secretKey : String := "e2esecretkey0123"
private def endpoint : String := s!"http://minio.{nsName}.svc.cluster.local:9000"
private def toolPod : String := "wa-tool"
private def replayPod : String := "wa-replay"
private def extHost : String := s!"{cluster}-nodes-external.{nsName}.svc.cluster.local"
private def backupImage : String := "flare-backup:test"
-- The S3-compatible store: SeaweedFS (`weed server -s3`; no identities
-- configured, so any signed request is accepted). Not MinIO: its images are
-- not pullable without credentials any more (docker.io and quay.io 401, CI
-- 44286248212). Not `rclone serve s3`: it lists keys out of order, and
-- `aws s3 sync` merges the two listings in key order, so the backup's
-- `sync --delete` deleted and re-uploaded the same keys at once and lost
-- CURRENT (CI 44291630641; reproduced locally with aws-cli 2.15.0). Its
-- Service keeps the name `minio`.
private def s3Image : String := "chrislusf/seaweedfs:3.80"

private def ctx (test : String) : Ctx := { cfg := cfg, suite := "wal-archive", test := test }

private def infraYaml : String := s!"apiVersion: v1
kind: Secret
metadata:
  name: {secretName}
  namespace: {nsName}
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: {accessKey}
  AWS_SECRET_ACCESS_KEY: {secretKey}
  AWS_DEFAULT_REGION: us-east-1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: {nsName}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: s3
          image: {s3Image}
          args:
            - server
            - -dir=/data
            - -s3
            - -s3.port=9000
          ports:
            - containerPort: 9000
          readinessProbe:
            tcpSocket:
              port: 9000
            periodSeconds: 3
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: \{}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: {nsName}
spec:
  selector:
    app: minio
  ports:
    - port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Pod
metadata:
  name: {toolPod}
  namespace: {nsName}
spec:
  restartPolicy: Never
  containers:
    - name: tool
      image: {backupImage}
      imagePullPolicy: Never
      command:
        - sleep
        - \"86400\"
      envFrom:
        - secretRef:
            name: {secretName}
"

/-- Offline replay pod: aws-cli (the backup image) downloads, the flared image
    replays; they share /work. -/
private def replayPodYaml : String := s!"apiVersion: v1
kind: Pod
metadata:
  name: {replayPod}
  namespace: {nsName}
spec:
  restartPolicy: Never
  volumes:
    - name: work
      emptyDir: \{}
  containers:
    - name: tool
      image: {backupImage}
      imagePullPolicy: Never
      command:
        - sleep
        - \"86400\"
      envFrom:
        - secretRef:
            name: {secretName}
      volumeMounts:
        - name: work
          mountPath: /work
    - name: flared
      image: {cfg.flaredImage}
      imagePullPolicy: Never
      command:
        - sleep
        - \"86400\"
      volumeMounts:
        - name: work
          mountPath: /work
"

private def applyText (name yaml : String) : IO (Except String String) := do
  let p := s!"/tmp/flare-e2e-walarc-{name}.yaml"
  IO.FS.writeFile p yaml
  hostCmd "kubectl" ["apply", "-f", p]

/-- The chart's values for this suite (after the harness's own `helmSets`).
    walArchive starts OFF: the suite takes the first base itself and turns the
    archive on. -/
private def chartSets : List String :=
  ["cluster.hostnameSpread=soft", "cluster.drainSeconds=20", "nodeReplacement.enabled=false",
   s!"cluster.objectStorage.url=s3://{bucket}", s!"cluster.objectStorage.endpoint={endpoint}",
   s!"cluster.objectStorage.credentialsSecret={secretName}",
   "cluster.backup.enabled=true", "cluster.backup.suspend=true", "cluster.backup.role=master",
   "cluster.backup.keepDays=0", "cluster.backup.image.repository=flare-backup", "cluster.backup.image.tag=test",
   "cluster.backup.walArchive.enabled=false", "cluster.backup.walArchive.rebaseMinIntervalSeconds=60",
   "cluster.backupBootstrap.enabled=true", "cluster.backupBootstrap.maxAgeSeconds=86400",
   "cluster.backupBootstrap.image.repository=flare-backup", "cluster.backupBootstrap.image.tag=test",
   "cluster.rocksdb.backupKeep=1", "cluster.rocksdb.walTtlSeconds=3600", "cluster.rocksdb.walSizeLimitMb=256"]

private def setArchive (on : Bool) : IO (Except String String) := do
  helmCmd ["upgrade", helmRelease cfg, ← helmChartDir, "--namespace", nsName, "--reuse-values",
    "--set", s!"cluster.backup.walArchive.enabled={on}"] 300

/-! ## Observation -/

private def tokens (s : String) : List String :=
  (s.split (fun ch => ch == ' ' || ch == '\t' || ch == '\r')).filter (!·.isEmpty)

private def kv (ts : List String) (k : String) : Option String :=
  ts.findSome? fun t => if t.startsWith (k ++ "=") then some (t.drop (k.length + 1)) else none

/-- A command in the tool pod (aws-cli, kubectl, nc), bounded by `secs`. -/
private def toolSh (cmd : String) (secs : Nat := 60) : IO (Except String String) :=
  kubectlLong secs ["exec", toolPod, "-n", nsName, "--", "sh", "-c", cmd]

private def aws (args : String) (secs : Nat := 60) : IO (Except String String) :=
  toolSh s!"aws --endpoint-url {endpoint} {args}" secs

structure Seg where
  chain : String
  first : Nat
  last : Nat
  deriving Repr

private def parseSegLine (ln : String) : Option Seg := do
  let [_, _, _, key] := tokens ln | none
  let [_, "wal", "p0", inc, epo, mid, file] := key.splitOn "/" | none
  let f :: g :: _ := file.splitOn "-" | none
  let a ← f.toNat?
  let b ← g.toNat?
  pure { chain := s!"{inc}/{epo}/{mid}", first := a, last := b }

/-- Every archived segment of partition 0 in the bucket (an unreadable bucket
    reads as empty: the callers expect a non-empty list where it matters). -/
private def listSegs : IO (List Seg) := do
  match ← toolSh s!"aws --endpoint-url {endpoint} s3 ls --recursive s3://{bucket}/{cluster}/wal/p0/ 2>/dev/null || true" with
  | .error _ => return []
  | .ok o => return (o.splitOn "\n").filterMap parseSegLine

private def chainsOf (ss : List Seg) : List String :=
  ss.foldl (fun acc s => if acc.contains s.chain then acc else acc ++ [s.chain]) []

private def segsOf (ss : List Seg) (chain : String) : List Seg := ss.filter (·.chain == chain)

private def maxLast (ss : List Seg) : Nat := (ss.map (·.last)).foldl max 0

/-- The latest base in the bucket: (chain "<incarnation>/<epoch>/<master_id>", seq, time). -/
private def latestBase : IO (Option (String × Nat × Nat)) := do
  match ← aws s!"s3 cp s3://{bucket}/{cluster}/latest/p0/FLARE_BASE -" with
  | .error _ => return none
  | .ok o =>
    let ts := tokens o
    match kv ts "incarnation", kv ts "epoch", kv ts "master_id", (kv ts "seq").bind (·.toNat?) with
    | some i, some e, some m, some s => return some (s!"{i}/{e}/{m}", s, ((kv ts "time").bind (·.toNat?)).getD 0)
    | _, _, _, _ => return none

structure Arch where
  synced : Nat
  needs : Nat
  chain : Nat
  baseTs : Nat
  rebases : Nat
  fails : Nat
  deriving Repr

private def metricNat (txt name : String) : Option Nat :=
  (txt.splitOn "\n").findSome? fun ln =>
    if ln.startsWith (name ++ "{") || ln.startsWith (name ++ " ") then (tokens ln).getLast?.bind (·.toNat?) else none

private def archiverPod : IO (Option String) := do
  match ← kubectl ["get", "pods", "-n", nsName, "-l", "app=flare-wal-archive", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.metadata.deletionTimestamp}{\"\\n\"}{end}"] with
  | .error _ => return none
  | .ok o =>
    return (o.splitOn "\n").findSome? fun ln =>
      match ln.trim.splitOn "|" with
      | [n, d] => if !n.isEmpty && d.isEmpty then some n else none
      | _ => none

/-- The uploader's metrics file (what its port 9151 serves), partition 0. -/
private def readArch : IO (Option Arch) := do
  let some pod ← archiverPod | return none
  match ← kubectl ["exec", pod, "-n", nsName, "-c", "upload", "--", "cat", "/wal/metrics"] with
  | .error _ => return none
  | .ok t =>
    return (do
      let s ← metricNat t "flare_wal_archive_synced_timestamp_seconds"
      let n ← metricNat t "flare_wal_archive_needs_base"
      let c ← metricNat t "flare_wal_archive_chain_active"
      let b ← metricNat t "flare_wal_archive_base_timestamp_seconds"
      let r ← metricNat t "flare_wal_archive_rebase_requests_total"
      let f ← metricNat t "flare_wal_archive_upload_failures_total"
      pure { synced := s, needs := n, chain := c, baseTs := b, rebases := r, fails := f })

/-- A chain is followed and what the master had a moment ago is in the bucket. -/
private def isFollowing (a : Arch) (now : Nat) : Bool :=
  a.chain == 1 && a.needs == 0 && a.synced > 0 && now ≤ a.synced + 150

private def waitFollowing (what : String) (secs : Nat) (newerBase : Nat := 0) : IO Bool :=
  waitForCondition what secs do
    match ← readArch with
    | some a => return isFollowing a (← epochNow) && a.baseTs > newerBase
    | none => return false

private def jobNames : IO (List String) := do
  match ← kubectl ["get", "jobs", "-n", nsName, "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"] with
  | .ok o => return (o.splitOn "\n").map String.trim |>.filter (!·.isEmpty)
  | .error _ => return []

/-- One backup run now (`kubectl create job --from=cronjob/...`, as the
    uploader does), to completion. -/
private def runBase (tag : String) (timeoutSec : Nat := 420) : IO (Except String String) := do
  let name := s!"{cluster}-backup-e2e-{tag}"
  match ← kubectl ["create", "job", name, s!"--from=cronjob/{cluster}-backup", "-n", nsName] with
  | .error e => return .error s!"could not create job {name}: {e.take 200}"
  | .ok _ =>
    let ok ← waitForCondition s!"backup job {name} succeeded" timeoutSec do
      match ← kubectlGetJsonpath "job" name nsName "{.status.succeeded}" with
      | .ok v => return v.trim == "1"
      | .error _ => return false
    let log ← match ← kubectl ["logs", s!"job/{name}", "-n", nsName, "--tail=30"] with
      | .ok l => pure l
      | .error e => pure s!"(no log: {e.take 100})"
    if ok then return .ok log else return .error s!"job {name} did not succeed within {timeoutSec} s: {log.take 600}"

structure FPod where
  name : String
  uid : String
  restarts : String
  ready : Bool
  deleting : Bool
  deriving Repr, BEq

/-- The flared pods only (not the archiver or the backup Jobs, which carry the
    cluster label too). -/
private def flaredPods : IO (Option (List FPod)) := do
  match ← kubectl ["get", "pods", "-n", nsName, "-l", s!"app=flare,cluster={cluster}", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.metadata.uid}|{.status.containerStatuses[*].restartCount}|{.status.initContainerStatuses[*].restartCount}|{.status.conditions[?(@.type==\"Ready\")].status}|{.metadata.deletionTimestamp}{\"\\n\"}{end}"] with
  | .error _ => return none
  | .ok o =>
    return some ((o.splitOn "\n").filterMap fun ln =>
      match ln.trim.splitOn "|" with
      | [n, u, r1, r2, rd, del] =>
        if n.isEmpty then none else some { name := n, uid := u, restarts := s!"{r1}/{r2}", ready := rd == "True", deleting := !del.isEmpty }
      | _ => none)

private def masterPod : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod nsName cfg.operatorName cfg.operatorPort "node sync"
  return findMasterPod (parseNodeSync sync) 0

private def masterIp : IO (Option String) := do
  let some m ← masterPod | return none
  getPodIp m nsName

private def initLog (pod container : String) : IO String := do
  match ← kubectl ["logs", pod, "-n", nsName, "-c", container, "--tail=200"] with
  | .ok o => return o
  | .error e => return s!"(no log: {e.take 100})"

private def stsRevision : IO String := do
  match ← kubectlGetJsonpath "statefulset" s!"{cluster}-nodes" nsName "{.status.updateRevision}" with
  | .ok o => return o.trim
  | .error _ => return ""

/-- Stop a load, once more after 30 s if the workers had not all ended. -/
private def stopLoadRetry (c : Ctx) (name : String) (workers : Nat) : IO (Option LoadResult) := do
  match ← c.stopLoad name workers with
  | some r => return some r
  | none =>
    IO.sleep 30000
    c.stopLoad name workers

private def fieldOf (line key : String) : Option String := kv (tokens line) key

/-! ## T1: RPO under load -/

private def rpoTest : IO TestResult := do
  let c := ctx "rpo-under-load"
  c.conditions ["T1: 4 writers x 40/s with replies via the all-pods Service; base; archive on for 5 min; all pods deleted at once; segmentSeconds 30"]
  match ← c.ensureLoadWriter with
  | .error e => return .fail (notSetUp e)
  | .ok () => pure ()
  let some pods0 ← flaredPods | return .fail (notSetUp "the flared pods cannot be read")
  if pods0.length != 2 then return .fail (notSetUp s!"{pods0.length} flared pods, not 2")
  if !(← c.startLoad "rpo" extHost 4 40) then return .fail (notSetUp "the write load did not start")
  IO.sleep 20000
  -- the base (archive still off)
  match ← runBase "t1" with
  | .error e => return .fail (notSetUp s!"the first base: {e}")
  | .ok l => c.event s!"base uploaded: {(l.trim.take 200)}"
  match ← setArchive true with
  | .error e => return .fail (notSetUp s!"helm upgrade (archive on): {e.take 300}")
  | .ok _ => pure ()
  if !(← kubectlRolloutStatus s!"deployment/{cluster}-wal-archive" nsName 300) then
    return .fail (notSetUp "the archiver Deployment did not roll out")
  if !(← waitFollowing "the archiver follows the base's chain and has uploaded" 300) then
    return .fail (notSetUp s!"the archive did not start following: {repr (← readArch)}")
  -- several minutes of archive under load; sample how far behind it is
  let mut lags : List Nat := []
  for _ in [0:20] do
    IO.sleep 15000
    match ← readArch with
    | some a => lags := lags ++ [(← epochNow) - a.synced]
    | none => pure ()
  let lagMax := lags.foldl max 0
  c.event s!"archive lag (now - synced) over 5 min: max {lagMax} s, samples {lags}"
  let some a1 ← readArch | return .fail (unobservable "the archiver's metrics cannot be read")
  -- all-copy loss
  let oldUids := pods0.map (·.uid)
  let _ ← kubectl (["delete", "pod"] ++ pods0.map (·.name) ++ ["-n", nsName, "--force", "--grace-period=0", "--wait=false"])
  let tKill ← epochNow
  c.event s!"every flared pod deleted at {tKill} (archive synced {a1.synced}, lag {tKill - a1.synced} s)"
  let res? ← stopLoadRetry c "rpo" 4
  let some res := res? | return .fail (unobservable "the load log could not be read or failed its integrity check")
  let st := loadStats res
  c.event (st.summary "rpo")
  let acked := res.recs.filter (·.ack)
  let tLast := (acked.map (·.t1)).foldl max 0
  if acked.isEmpty then return .fail (unobservable "no write was acknowledged")
  -- the pods come back through backup-bootstrap + backup-wal-replay
  let renewed ← waitForCondition "every flared pod is a new pod (new UID), none deleting" 300 do
    match ← flaredPods with
    | some ps => return ps.length == 2 && ps.all (fun p => !oldUids.contains p.uid && !p.deleting)
    | none => return false
  if !renewed then return .fail "the flared pods were not recreated within 300 s"
  let t0 ← nowSec
  let settled ← waitClusterSettled cfg 900 15
  c.event s!"cluster settled={settled} {(← nowSec) - t0} s after the pods were recreated"
  if !settled then return .fail s!"the cluster did not settle (one master, an Active replica) within 900 s of the restore: {repr (← readArch)}"
  -- the replay lines of the init containers
  let mut replayLines : List String := []
  let mut noteLines : List String := []
  for p in (← flaredPods).getD [] do
    let b ← initLog p.name "backup-bootstrap"
    let r ← initLog p.name "backup-wal-replay"
    c.art "init-logs.txt" s!"== {p.name} backup-bootstrap\n{b}\n== {p.name} backup-wal-replay\n{r}"
    for ln in (b ++ "\n" ++ r).splitOn "\n" do
      if containsSubstr ln "replay base_seq=" then replayLines := replayLines ++ [ln.trim]
      if containsSubstr ln "WAL segment(s) after it" || containsSubstr ln "WARNING" then noteLines := noteLines ++ [ln.trim]
  for ln in replayLines ++ noteLines do c.event s!"restore: {ln}"
  let mut fails : List String := []
  if replayLines.isEmpty then fails := fails ++ ["no `replay base_seq=...` summary line in any pod's backup-wal-replay log"]
  for ln in replayLines do
    if fieldOf ln "gap" != some "0" then fails := fails ++ [s!"replay not gap=0: {ln.take 200}"]
    if fieldOf ln "conflict" != some "0" then fails := fails ++ [s!"replay not conflict=0: {ln.take 200}"]
  let appliedMax := (replayLines.filterMap fun ln => (fieldOf ln "applied").bind (·.toNat?)).foldl max 0
  if !replayLines.isEmpty && appliedMax == 0 then fails := fails ++ ["the replay applied no batch (the archive was not used)"]
  -- every key ACKed before T - 60 s, with its value, on the new master
  let some ip ← masterIp | return .fail (unobservable "no master's address after the restore")
  let some copy ← c.ownCopy ip | return .fail (unobservable s!"the master's copy at {ip} cannot be read")
  let lost := missingAcks (acked.map (·.toWrite)) copy
  let lostOld := (acked.filter fun r => r.t1 + 60000000 ≤ tLast).map (·.toWrite) |> fun ws => missingAcks ws copy
  let lostT := (acked.filter fun r => lost.any (·.key == r.key)).map (·.t1)
  let newestLostAge := match lostT.foldl max 0 with | 0 => 0 | m => (tLast - m) / 1000000
  for w in lost.take 200 do c.art "missing.txt" s!"{w.key}={w.value} acked at {w.t}"
  c.event s!"SUMMARY T1: acked {acked.length} of {res.recs.length}; last ACK T={tLast / 1000000}; keys on the new master {copy.length}; ACKed writes missing {lost.length}; newest lost ACK {if lost.isEmpty then "none" else s!"{newestLostAge} s before T"}; missing older than 60 s: {lostOld.length}; replay applied(max) {appliedMax}; archive lag max {lagMax} s"
  if !lostOld.isEmpty then
    fails := fails ++ [s!"{lostOld.length} write(s) ACKed more than 60 s before T are missing (first: {(lostOld.head?.map (·.key)).getD ""})"]
  if !lost.isEmpty && newestLostAge > 60 then
    fails := fails ++ [s!"the newest lost ACK is {newestLostAge} s older than T (limit 60 s)"]
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-! ## T2: master switch -/

private def switchTest : IO TestResult := do
  let c := ctx "master-switch"
  c.conditions ["T2: the master pod is deleted under a light load; the archiver stops the old chain, asks for a base, follows the new chain"]
  if !(← waitFollowing "a chain is followed (after T1's restore the archive takes a new base)" 900) then
    return .fail (notSetUp s!"the archive is not following a chain: {repr (← readArch)}")
  match ← c.ensureLoadWriter with
  | .error e => return .fail (notSetUp e)
  | .ok () => pure ()
  let some a0 ← readArch | return .fail (unobservable "the archiver's metrics cannot be read")
  let segs0 ← listSegs
  let chains0 := chainsOf segs0
  let jobs0 ← jobNames
  let some m0 ← masterPod | return .fail (notSetUp "no master")
  c.event s!"before: master {m0}, chains {chains0}, base ts {a0.baseTs}, rebase requests {a0.rebases}, synced {a0.synced}"
  if !(← c.startLoad "sw" extHost 2 30) then return .fail (notSetUp "the write load did not start")
  let _ ← kubectl ["delete", "pod", m0, "-n", nsName, "--wait=false"]
  let t0 ← nowSec
  let mut needsSeen : Option Nat := none
  let mut inactiveSeen := false
  let mut jobSeen : Option String := none
  let mut followed : Option Nat := none
  let mut segsAtNeeds : List Seg := []
  for _ in [0:300] do
    if followed.isNone then
      match ← readArch with
      | some a =>
        if a.needs == 1 && needsSeen.isNone then
          needsSeen := some ((← nowSec) - t0)
          segsAtNeeds ← listSegs
        if a.needs == 1 && a.chain == 0 then inactiveSeen := true
        if needsSeen.isSome && isFollowing a (← epochNow) && a.baseTs > a0.baseTs then
          followed := some ((← nowSec) - t0)
      | none => pure ()
      if jobSeen.isNone then
        jobSeen := (← jobNames).find? fun j => containsSubstr j "-backup-wal-" && !jobs0.contains j
      if followed.isNone then IO.sleep 2000
  let m1 ← masterPod
  c.event s!"switch: master {m0} -> {m1}; needs_base seen at {needsSeen}, chain stopped seen {inactiveSeen}, backup job {jobSeen}, new chain followed at {followed} s"
  let mut fails : List String := []
  if m1 == some m0 || m1.isNone then fails := fails ++ [s!"the master did not change ({m0} -> {m1})"]
  if needsSeen.isNone then fails := fails ++ ["flare_wal_archive_needs_base never went to 1 after the master moved"]
  if !inactiveSeen then fails := fails ++ ["the old chain was never seen stopped (needs_base 1 with chain_active 0)"]
  if jobSeen.isNone then fails := fails ++ [s!"no new Job `{cluster}-backup-wal-*` appeared"]
  if followed.isNone then
    return .fail (String.intercalate "; " (fails ++ [s!"no new chain was followed within 600 s: {repr (← readArch)}"]))
  -- the new chain has segments in the bucket, under another path
  let gotNew ← waitForCondition "a segment of a NEW chain is in the bucket" 150 do
    return !((chainsOf (← listSegs)).filter (!chains0.contains ·)).isEmpty
  let segs1 ← listSegs
  let newChains := (chainsOf segs1).filter (!chains0.contains ·)
  c.event s!"chains after: {chainsOf segs1}; new: {newChains}"
  if !gotNew then fails := fails ++ ["no segment under a new incarnation/epoch/master path"]
  -- the old chain is not appended to after it stopped (at most the segment the follower closes on its stop)
  for ch in chains0 do
    let before := (segsOf segsAtNeeds ch).length
    let after := (segsOf segs1 ch).length
    if after > before + 1 then fails := fails ++ [s!"old chain {ch} grew from {before} to {after} segments after it was stopped"]
  -- synced advances again
  let some a2 ← readArch | return .fail (unobservable "the archiver's metrics cannot be read")
  IO.sleep 45000
  let some a3 ← readArch | return .fail (unobservable "the archiver's metrics cannot be read")
  c.event s!"synced {a2.synced} -> {a3.synced}; exception window (needs_base 1) {needsSeen} .. {followed} s after the delete"
  if a3.synced <= a2.synced then fails := fails ++ [s!"synced did not advance ({a2.synced} -> {a3.synced})"]
  if a3.needs != 0 || a3.chain != 1 then fails := fails ++ [s!"after the new base needs_base={a3.needs} chain_active={a3.chain}"]
  if a3.rebases <= a0.rebases then fails := fails ++ ["rebase_requests_total did not increase"]
  let _ ← stopLoadRetry c "sw" 2
  c.event s!"SUMMARY T2: old master {m0}, new master {m1}; needs_base seen {needsSeen} s after the delete, new base followed after {followed} s; backup job {jobSeen}; new chain {newChains}; rebase requests {a0.rebases} -> {a3.rebases}"
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-! ## T3: on/off without pod restarts -/

private def toggleTest : IO TestResult := do
  let c := ctx "on-off"
  c.conditions ["T3: helm upgrade walArchive.enabled false, then true, under a 2 x 20/s load; flared pods untouched"]
  if !(← waitFollowing "a chain is followed" 600) then
    return .fail (notSetUp s!"the archive is not following a chain: {repr (← readArch)}")
  match ← c.ensureLoadWriter with
  | .error e => return .fail (notSetUp e)
  | .ok () => pure ()
  let some pods0 ← flaredPods | return .fail (notSetUp "the flared pods cannot be read")
  let rev0 ← stsRevision
  let depUid := fun (_ : Unit) => do
    match ← kubectlGetJsonpath "deployment" s!"{cluster}-wal-archive" nsName "{.metadata.uid}" with
    | .ok u => pure (some u.trim)
    | .error _ => pure none
  let dep0 ← depUid ()
  c.event s!"before: pods {repr pods0}, sts revision {rev0}, archiver Deployment {dep0}"
  if !(← c.startLoad "t3" extHost 2 20) then return .fail (notSetUp "the write load did not start")
  IO.sleep 10000
  -- off
  match ← setArchive false with
  | .error e => return .fail s!"helm upgrade (archive off) failed: {e.take 300}"
  | .ok _ => pure ()
  let gone ← waitForCondition "the archiver Deployment and its pods are gone" 180 do
    let d ← depUid ()
    let p ← archiverPod
    let lst ← kubectl ["get", "pods", "-n", nsName, "-l", "app=flare-wal-archive", "-o", "name"]
    return d.isNone && p.isNone && (match lst with | .ok o => o.trim.isEmpty | .error _ => false)
  if !gone then return .fail "the archiver was not removed within 180 s of walArchive.enabled=false"
  IO.sleep 25000
  let some (chain, baseSeq, _) ← latestBase | return .fail (unobservable "the latest base cannot be read")
  let segsOff ← listSegs
  let oldMax := max baseSeq (maxLast (segsOf segsOff chain))
  c.event s!"archive off: chain {chain}, base seq {baseSeq}, last archived {oldMax}, {(segsOf segsOff chain).length} segment(s)"
  let podsOff ← flaredPods
  -- on
  match ← setArchive true with
  | .error e => return .fail s!"helm upgrade (archive on) failed: {e.take 300}"
  | .ok _ => pure ()
  if !(← kubectlRolloutStatus s!"deployment/{cluster}-wal-archive" nsName 300) then
    return .fail "the archiver Deployment did not roll out after walArchive.enabled=true"
  let backOn ← waitFollowing "the archive follows again" 300
  let resumed ← waitForCondition s!"a segment after {oldMax} of the base's chain is in the bucket" 240 do
    return !((segsOf (← listSegs) chain).filter (·.last > oldMax)).isEmpty
  let segsOn ← listSegs
  let newSegs := (segsOf segsOn chain).filter (·.last > oldMax)
  let firstNew := (newSegs.map (·.first)).foldl min (oldMax + 1000000000)
  let dep1 ← depUid ()
  let _ ← stopLoadRetry c "t3" 2
  let some pods1 ← flaredPods | return .fail (unobservable "the flared pods cannot be read")
  let rev1 ← stsRevision
  c.event s!"after: pods {repr pods1}, sts revision {rev1}, archiver Deployment {dep1}; first new segment starts at {firstNew} (last archived before: {oldMax})"
  let mut fails : List String := []
  if pods1 != pods0 then fails := fails ++ [s!"the flared pods changed: {repr pods0} -> {repr pods1}"]
  if podsOff != some pods0 then fails := fails ++ [s!"the flared pods changed while the archive was off: {repr podsOff}"]
  if rev1 != rev0 then fails := fails ++ [s!"the StatefulSet's pod template changed ({rev0} -> {rev1})"]
  if dep0.isNone || dep1.isNone || dep0 == dep1 then fails := fails ++ [s!"the archiver Deployment was not deleted and created (uid {dep0} -> {dep1})"]
  if !backOn then fails := fails ++ ["the archive did not follow again within 300 s"]
  if !resumed then fails := fails ++ [s!"no segment after {oldMax} appeared within 240 s"]
  else if firstNew != oldMax + 1 then
    fails := fails ++ [s!"the archive did not resume after the last uploaded segment: the first new segment starts at {firstNew}, expected {oldMax + 1}"]
  c.event s!"SUMMARY T3: flared pods unchanged={pods1 == pods0}, sts revision unchanged={rev1 == rev0}, Deployment uid {dep0} -> {dep1}, resumed at {firstNew} (expected {oldMax + 1})"
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-! ## T4: offline replay, time-bounded restore, interruption, refusal -/

/-- Downloads the latest base and its chain's segments after the base's seq
    into /work/<dir>/{base,seg} (the same selection as backup-bootstrap). -/
private def downloadScript (dir : String) : String :=
  r##"set -e
EP="--endpoint-url @ENDPOINT@"
ROOT=s3://@BUCKET@/@CLUSTER@
D=/work/@DIR@
rm -rf "$D"; mkdir -p "$D/base" "$D/seg"
aws s3 cp --recursive $EP --no-progress "$ROOT/latest/p0" "$D/base" >/dev/null
B="$D/base/FLARE_BASE"
B_SEQ=$(sed -n 's/.* seq=\([0-9]*\).*/\1/p' "$B")
CHAIN="$ROOT/wal/p0/$(sed -n 's/.* incarnation=\([^ ]*\).*/\1/p' "$B")/$(sed -n 's/.* epoch=\([^ ]*\).*/\1/p' "$B")/$(sed -n 's/.* master_id=\([^ ]*\).*/\1/p' "$B")"
N=0
for n in $(aws s3 ls $EP "$CHAIN/" | awk '{print $4}'); do
  last=$(echo "$n" | sed -n 's/^[0-9]*-0*\([0-9][0-9]*\)-.*\.wal$/\1/p')
  [ -n "$last" ] && [ "$last" -gt "$B_SEQ" ] || continue
  aws s3 cp $EP --no-progress "$CHAIN/$n" "$D/seg/$n" >/dev/null
  N=$((N + 1))
done
echo "DL @DIR@ base_seq=$B_SEQ segments=$N"
"##
  |>.replace "@ENDPOINT@" endpoint |>.replace "@BUCKET@" bucket |>.replace "@CLUSTER@" cluster |>.replace "@DIR@" dir

/-- The replays, run in the flared image on /work/d1 (see the claims in the
    header). Prints `CHK <name> PASS|FAIL <detail>` lines. -/
private def replayScript (untilT markersA markersB : String) : String :=
  r##"W=/work/d1
chk() { echo "CHK $1 $2 $3"; }
fresh() { rm -rf "$W/$1"; cp -a "$W/base" "$W/$1"; }
# rows are `"<key>",expire,ttl,size` (the key quoted)
csv() { flared --analyze-checkpoint "$1" 2>/dev/null | cut -d, -f1,4 | sort; }
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }
NSEG=$(ls "$W/seg" | wc -l)
echo "INFO segments=$NSEG base=$(head -1 $W/base/FLARE_BASE)"

# R1: time-bounded (until a time between the A writes and the B writes)
fresh r_until
OUT=$(flared --wal-replay "$W/r_until" "$W/seg" @UNTIL@ 2>"$W/err_until"); RC=$?
echo "REPLAY until rc=$RC $OUT"
csv "$W/r_until" > "$W/k_until"
A=$(grep -c '^"walt_a_' "$W/k_until"); B=$(grep -c '^"walt_b_' "$W/k_until")
if [ "$RC" = 0 ] && [ "$A" = @NA@ ] && [ "$B" = 0 ] && [ "$(field "$OUT" until)" = 1 ]; then
  chk until PASS "a=$A b=$B $OUT"
else chk until FAIL "rc=$RC a=$A (want @NA@) b=$B (want 0) $OUT"; fi

# R2: one full replay (the reference)
fresh r_full
OUT=$(flared --wal-replay "$W/r_full" "$W/seg" 2>"$W/err_full"); RC=$?
echo "REPLAY full rc=$RC $OUT"
APP_FULL=$(field "$OUT" applied); LAST_FULL=$(field "$OUT" last_lsn)
csv "$W/r_full" > "$W/c_full"
A=$(grep -c '^"walt_a_' "$W/c_full"); B=$(grep -c '^"walt_b_' "$W/c_full")
if [ "$RC" = 0 ] && [ "$(field "$OUT" gap)" = 0 ] && [ "$(field "$OUT" conflict)" = 0 ] && [ "$(field "$OUT" until)" = 0 ] \
   && [ "$A" = @NA@ ] && [ "$B" = @NB@ ] && [ "${APP_FULL:-0}" -gt 0 ]; then
  chk full PASS "a=$A b=$B $OUT"
else chk full FAIL "rc=$RC a=$A b=$B $OUT"; fi

# R3a: the first half of the segments, then all of them: it continues
H=$((NSEG / 2))
mkdir -p "$W/seg_half"; rm -f "$W/seg_half"/*
ls "$W/seg" | sort | head -n "$H" | while read -r f; do cp "$W/seg/$f" "$W/seg_half/"; done
fresh r_part
OUT1=$(flared --wal-replay "$W/r_part" "$W/seg_half" 2>/dev/null); RC1=$?
OUT2=$(flared --wal-replay "$W/r_part" "$W/seg" 2>/dev/null); RC2=$?
echo "REPLAY half rc=$RC1 $OUT1"
echo "REPLAY rest rc=$RC2 $OUT2"
a1=$(field "$OUT1" applied); a2=$(field "$OUT2" applied)
csv "$W/r_part" > "$W/c_part"
if [ "$RC1" = 0 ] && [ "$RC2" = 0 ] && [ "${a1:-0}" -gt 0 ] && [ $((${a1:-0} + ${a2:-0})) = "${APP_FULL:-x}" ] \
   && [ "$(field "$OUT2" last_lsn)" = "$LAST_FULL" ] && cmp -s "$W/c_full" "$W/c_part"; then
  chk half PASS "first run applied=$a1, second run applied=$a2, total=$APP_FULL, same keys as the full run"
else chk half FAIL "rc=$RC1/$RC2 applied=$a1+$a2 (full $APP_FULL) last_lsn $(field "$OUT2" last_lsn)/$LAST_FULL same_keys=$(cmp -s "$W/c_full" "$W/c_part" && echo yes || echo no)"; fi

# R3b: killed (SIGKILL) while replaying, then run again
KILLED=no; JL=0
for d in 0.5 0.3 0.2 0.12 0.08 0.05 0.03; do
  fresh r_kill
  timeout -s KILL "$d" flared --wal-replay "$W/r_kill" "$W/seg" >/dev/null 2>&1; RK=$?
  JL=0; [ -f "$W/r_kill/FLARE_REPLAY" ] && JL=$(wc -l < "$W/r_kill/FLARE_REPLAY")
  if [ "$RK" = 137 ] && [ "$JL" -gt 1 ]; then KILLED=yes; KD=$d; break; fi
done
OUTK=$(flared --wal-replay "$W/r_kill" "$W/seg" 2>/dev/null); RCK=$?
echo "REPLAY kill killed=$KILLED after=${KD:-none}s journal_lines=$JL rc=$RCK $OUTK"
csv "$W/r_kill" > "$W/c_kill"
if [ "$RCK" = 0 ] && cmp -s "$W/c_full" "$W/c_kill"; then
  chk kill PASS "killed=$KILLED after=${KD:-none}s journal_lines=$JL, rerun applied=$(field "$OUTK" applied), same keys as the full run"
else chk kill FAIL "killed=$KILLED rc=$RCK $OUTK same_keys=$(cmp -s "$W/c_full" "$W/c_kill" && echo yes || echo no)"; fi

# R4a: the LAST segment corrupt (no gap shows for it): exit 4, the contiguous part applied
rm -rf "$W/seg_tail"; cp -a "$W/seg" "$W/seg_tail"
LASTSEG=$(ls "$W/seg_tail" | sort | tail -1)
SZ=$(stat -c %s "$W/seg_tail/$LASTSEG")
printf 'Z' | dd of="$W/seg_tail/$LASTSEG" bs=1 seek=$((SZ - 12)) conv=notrunc 2>/dev/null
fresh r_tail
OUT=$(flared --wal-replay "$W/r_tail" "$W/seg_tail" 2>/dev/null); RC=$?
echo "REPLAY tailcorrupt rc=$RC $OUT"
if [ "$RC" = 4 ] && [ "$(field "$OUT" gap)" = 0 ] && [ "$(field "$OUT" corrupt_beyond)" = 1 ] && [ "$(field "$OUT" complete)" = 0 ] \
   && [ "$(field "$OUT" last_lsn)" -lt "$LAST_FULL" ]; then
  chk tailcorrupt PASS "$OUT"
else chk tailcorrupt FAIL "rc=$RC (want 4) $OUT"; fi

# R4b: a middle segment missing: exit 4 with gap=1
if [ "$NSEG" -ge 3 ]; then
  rm -rf "$W/seg_gap"; cp -a "$W/seg" "$W/seg_gap"
  MID=$(ls "$W/seg_gap" | sort | sed -n "$((NSEG / 2 + 1))p")
  rm -f "$W/seg_gap/$MID"
  fresh r_gap
  OUT=$(flared --wal-replay "$W/r_gap" "$W/seg_gap" 2>/dev/null); RC=$?
  echo "REPLAY midgap rc=$RC $OUT"
  if [ "$RC" = 4 ] && [ "$(field "$OUT" gap)" = 1 ] && [ "$(field "$OUT" complete)" = 0 ]; then
    chk midgap PASS "$OUT"
  else chk midgap FAIL "rc=$RC (want 4) $OUT"; fi
else chk midgap FAIL "only $NSEG segment(s): need 3 to remove a middle one"; fi
"##
  |>.replace "@UNTIL@" untilT |>.replace "@NA@" markersA |>.replace "@NB@" markersB

/-- A database written past the base by something else: the files of a LATER
    base under the earlier base's FLARE_BASE. -/
private def refuseScript : String :=
  r##"W=/work/d1
rm -rf "$W/r_past"; cp -a /work/d2/base "$W/r_past"; cp "$W/base/FLARE_BASE" "$W/r_past/FLARE_BASE"
OUT=$(flared --wal-replay "$W/r_past" "$W/seg" 2>/dev/null); RC=$?
echo "REPLAY past rc=$RC $OUT"
case "$OUT" in *base_mismatch*) M=yes ;; *) M=no ;; esac
if [ "$RC" = 3 ] && [ "$M" = yes ]; then echo "CHK past PASS rc=3 $OUT"; else echo "CHK past FAIL rc=$RC $OUT"; fi
"##

private def chkLines (out : String) : List (String × String × String) :=
  (out.splitOn "\n").filterMap fun ln =>
    match (ln.trim.splitOn " ") with
    | "CHK" :: name :: verdict :: rest => some (name, verdict, " ".intercalate rest)
    | _ => none

private def replayTest : IO TestResult := do
  let c := ctx "offline-replay"
  c.conditions ["T4: offline in a pod with the flared image: until time, interruption + continue, refusal"]
  if !(← waitFollowing "a chain is followed" 600) then
    return .fail (notSetUp s!"the archive is not following a chain: {repr (← readArch)}")
  match ← c.ensureLoadWriter with
  | .error e => return .fail (notSetUp e)
  | .ok () => pure ()
  -- a longer chain first (so a replay takes long enough to be interrupted), then the known writes
  if !(← c.startLoad "t4" extHost 4 50) then return .fail (notSetUp "the write load did not start")
  IO.sleep 60000
  let _ ← stopLoadRetry c "t4" 4
  let some ip ← masterIp | return .fail (notSetUp "no master's address")
  let nMark := 20
  let mut stored := 0
  for i in List.range nMark do
    if (← memcachedSet cfg.debugPod nsName ip cfg.flarePort s!"walt_a_{i}" s!"a{i}") then stored := stored + 1
  IO.sleep 5000
  let untilT ← epochNow
  IO.sleep 4000
  for i in List.range nMark do
    if (← memcachedSet cfg.debugPod nsName ip cfg.flarePort s!"walt_b_{i}" s!"b{i}") then stored := stored + 1
  let tB ← epochNow
  if stored != 2 * nMark then return .fail (notSetUp s!"only {stored} of {2 * nMark} marker writes were STORED")
  c.event s!"markers: A written, until = {untilT}, B written (last at {tB})"
  let synced ← waitForCondition "the B writes are in the bucket (synced past them)" 180 do
    match ← readArch with
    | some a => return a.synced > tB
    | none => return false
  if !synced then return .fail (notSetUp s!"the archive did not sync past the markers: {repr (← readArch)}")
  -- the offline pod
  match ← applyText "replay-pod" replayPodYaml with
  | .error e => return .fail (notSetUp s!"the replay pod: {e.take 300}")
  | .ok _ => pure ()
  if !(← kubectlWaitReady s!"pod/{replayPod}" nsName 180) then return .fail (notSetUp "the replay pod did not become Ready")
  let dl1 ← kubectlLong 300 ["exec", replayPod, "-n", nsName, "-c", "tool", "--", "sh", "-c", downloadScript "d1"]
  let dl1Out := match dl1 with | .ok o => o | .error e => s!"ERROR {e.take 400}"
  c.event s!"download: {dl1Out.trim}"
  if !containsSubstr dl1Out "DL d1 " then return .fail (notSetUp s!"the download of the base and chain failed: {dl1Out.take 400}")
  let run1 ← kubectlLong 900 ["exec", replayPod, "-n", nsName, "-c", "flared", "--", "sh", "-c",
    replayScript (toString untilT) (toString nMark) (toString nMark)]
  let out1 := match run1 with | .ok o => o | .error e => s!"ERROR {e.take 600}"
  c.art "replay-output.txt" out1
  for ln in out1.splitOn "\n" do
    if !ln.trim.isEmpty then c.event s!"offline: {ln.trim.take 400}"
  -- a later base, for the refusal
  match ← runBase "t4b" with
  | .error e => return .fail (notSetUp s!"the second base: {e}")
  | .ok _ => pure ()
  let dl2 ← kubectlLong 300 ["exec", replayPod, "-n", nsName, "-c", "tool", "--", "sh", "-c", downloadScript "d2"]
  let dl2Out := match dl2 with | .ok o => o | .error e => s!"ERROR {e.take 400}"
  c.event s!"download (later base): {dl2Out.trim}"
  let run2 ← kubectlLong 300 ["exec", replayPod, "-n", nsName, "-c", "flared", "--", "sh", "-c", refuseScript]
  let out2 := match run2 with | .ok o => o | .error e => s!"ERROR {e.take 600}"
  c.art "replay-output.txt" out2
  for ln in out2.splitOn "\n" do
    if !ln.trim.isEmpty then c.event s!"offline: {ln.trim.take 400}"
  let chks := chkLines out1 ++ chkLines out2
  let mut fails : List String := []
  for want in ["until", "full", "half", "kill", "tailcorrupt", "midgap", "past"] do
    match chks.find? (·.1 == want) with
    | none => fails := fails ++ [s!"check `{want}` did not run (script output: {(out1 ++ out2).take 300})"]
    | some (_, v, d) => if v != "PASS" then fails := fails ++ [s!"{want}: {d.take 400}"]
  c.event s!"SUMMARY T4: {chks.map fun (n, v, _) => s!"{n}={v}"}"
  discard <| kubectl ["delete", "pod", replayPod, "-n", nsName, "--force", "--grace-period=0", "--ignore-not-found"]
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-! ## T5: the restore refuses an incomplete archive -/

/-- Corrupts the newest segment of the latest base's chain in the bucket (a
    byte of its trailer), as a damaged upload would. Prints the key. -/
private def corruptNewestScript (chain : String) : String :=
  r##"set -e
EP="--endpoint-url @ENDPOINT@"
P=s3://@BUCKET@/@CLUSTER@/wal/p0/@CHAIN@
N=$(aws s3 ls $EP "$P/" | awk '{print $4}' | sort | tail -1)
aws s3 cp $EP --no-progress "$P/$N" /tmp/seg >/dev/null
SZ=$(stat -c %s /tmp/seg)
printf 'Z' | dd of=/tmp/seg bs=1 seek=$((SZ - 12)) conv=notrunc 2>/dev/null
aws s3 cp $EP --no-progress /tmp/seg "$P/$N" >/dev/null
echo "CORRUPTED $N"
"##
  |>.replace "@ENDPOINT@" endpoint |>.replace "@BUCKET@" bucket |>.replace "@CLUSTER@" cluster |>.replace "@CHAIN@" chain

private def setAcceptIncomplete (on : Bool) : IO (Except String String) :=
  kubectlPatch "configmap" s!"{cluster}-flags" nsName
    s!"\{\"data\":\{\"backup-bootstrap-wal-accept-incomplete\":\"{on}\"}}"

private def refuseTest : IO TestResult := do
  let c := ctx "restore-refuses-incomplete"
  c.conditions ["T5: the newest archived segment corrupted in the bucket; every pod deleted; the restore must be refused until accept-incomplete is set"]
  if !(← waitFollowing "a chain is followed" 900) then
    return .fail (notSetUp s!"the archive is not following a chain: {repr (← readArch)}")
  let some ip ← masterIp | return .fail (notSetUp "no master's address")
  let mut stored := 0
  for i in List.range 20 do
    if (← memcachedSet cfg.debugPod nsName ip cfg.flarePort s!"walt5_{i}" s!"v{i}") then stored := stored + 1
  let tW ← epochNow
  if stored != 20 then return .fail (notSetUp s!"only {stored} of 20 writes were STORED")
  let synced ← waitForCondition "the writes are in the bucket (synced past them)" 180 do
    match ← readArch with
    | some a => return a.synced > tW
    | none => return false
  if !synced then return .fail (notSetUp s!"the archive did not sync past the writes: {repr (← readArch)}")
  let some (chain, _, _) ← latestBase | return .fail (unobservable "the latest base cannot be read")
  -- stop the archiver first: it must not upload a later, intact segment
  match ← setArchive false with
  | .error e => return .fail (notSetUp s!"helm upgrade (archive off): {e.take 300}")
  | .ok _ => pure ()
  let _ ← waitForCondition "the archiver is gone" 180 do return (← archiverPod).isNone
  let cor ← toolSh (corruptNewestScript chain) 120
  let corOut := match cor with | .ok o => o.trim | .error e => s!"ERROR {e.take 300}"
  c.event s!"bucket: {corOut}"
  if !containsSubstr corOut "CORRUPTED " then return .fail (notSetUp s!"could not corrupt the newest segment: {corOut}")
  let some pods0 ← flaredPods | return .fail (notSetUp "the flared pods cannot be read")
  let oldUids := pods0.map (·.uid)
  let _ ← kubectl (["delete", "pod"] ++ pods0.map (·.name) ++ ["-n", nsName, "--force", "--grace-period=0", "--wait=false"])
  -- refused: backup-wal-replay says so, and no new flared pod becomes Ready
  let mut refusedSeen := false
  let mut readySeen := false
  for _ in [0:60] do
    IO.sleep 5000
    for p in (← flaredPods).getD [] do
      if !oldUids.contains p.uid then
        if p.ready then readySeen := true
        if containsSubstr (← initLog p.name "backup-wal-replay") "REFUSED" then refusedSeen := true
    if refusedSeen then break
  -- hold a little longer: still nothing Ready while refused
  IO.sleep 30000
  for p in (← flaredPods).getD [] do
    if !oldUids.contains p.uid && p.ready then readySeen := true
  c.event s!"refused seen {refusedSeen}, a new pod Ready while refused {readySeen}"
  -- accept explicitly: published up to where the archive continues
  match ← setAcceptIncomplete true with
  | .error e => return .fail s!"could not set accept-incomplete: {e.take 300}"
  | .ok _ => pure ()
  let settled ← waitClusterSettled cfg 900 15
  let mut lines : List String := []
  for p in (← flaredPods).getD [] do
    for ln in (← initLog p.name "backup-wal-replay").splitOn "\n" do
      if containsSubstr ln "replay base_seq=" || containsSubstr ln "INCOMPLETE" then lines := lines ++ [ln.trim]
  for ln in lines do c.event s!"restore: {ln}"
  discard <| setAcceptIncomplete false
  discard <| setArchive true
  let mut fails : List String := []
  if !refusedSeen then fails := fails ++ ["backup-wal-replay never logged REFUSED for the corrupt newest segment"]
  if readySeen then fails := fails ++ ["a flared pod became Ready while the restore was refused"]
  if !settled then fails := fails ++ ["the cluster did not settle after accept-incomplete was set"]
  if !(lines.any fun ln => containsSubstr ln "corrupt_beyond=1" && containsSubstr ln "complete=0") then
    fails := fails ++ [s!"no accepted replay with corrupt_beyond=1 complete=0: {lines.take 3}"]
  if !(lines.any (containsSubstr · "INCOMPLETE archive accepted")) then
    fails := fails ++ ["the accepted restore did not log the INCOMPLETE warning"]
  c.event s!"SUMMARY T5: refused {refusedSeen}, Ready while refused {readySeen}, settled after accept {settled}, replay lines {lines.length}"
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-! ## T6: the restored data is exactly what was written -/

private def t6Prefix : String := "wr6_"

/-- A deterministic value of varied length (letters, digits and `-` only). -/
private def t6Val (tag : String) (i : Nat) : String :=
  s!"{tag}-{i}-" ++ String.mk (List.replicate ((i * 37) % 300) (Char.ofNat (97 + i % 26)))

/-- (key, some value) = set, (key, none) = delete. -/
private abbrev Op := String × Option String

private def t6Before : List Op :=
  (List.range 200).map fun i => (s!"{t6Prefix}a_{i}", some (t6Val "a1" i))

/-- After the base: only the archive has these. -/
private def t6After : List Op :=
  ((List.range 50).map fun i => (s!"{t6Prefix}a_{i}", some (t6Val "a2" i)))
  ++ ((List.range 50).map fun i => (s!"{t6Prefix}a_{50 + i}", none))
  ++ ((List.range 10).map fun i => (s!"{t6Prefix}a_{90 + i}", some (t6Val "a3" (90 + i))))
  ++ ((List.range 200).map fun i => (s!"{t6Prefix}b_{i}", some (t6Val "b1" i)))
  ++ ((List.range 50).map fun i => (s!"{t6Prefix}b_{150 + i}", none))
  ++ ((List.range 50).map fun i => (s!"{t6Prefix}b_{i}", some (t6Val "b2" i)))

private def t6Expected (ops : List Op) : Std.HashMap String String :=
  ops.foldl (fun m (k, v) => match v with | some x => m.insert k x | none => m.erase k) {}

private def t6Chunks (ops : List Op) : List (List Op) :=
  (List.range ((ops.length + 99) / 100)).map fun j => (ops.drop (j * 100)).take 100

/-- Sends `ops` in order on one connection per chunk of 100 to `ip`; returns how many
    were answered STORED (set) or DELETED (delete). -/
private def t6Apply (ip : String) (ops : List Op) : IO Nat := do
  let mut ok := 0
  for chunk in t6Chunks ops do
    let body := String.join (chunk.map fun (k, v) => match v with
      | some x => s!"set {k} 0 0 {x.length}\\r\\n{x}\\r\\n"
      | none => s!"delete {k}\\r\\n")
    match ← execInDebugPod cfg.debugPod nsName s!"printf '{body}quit\\r\\n' | nc -w 10 {ip} {cfg.flarePort}" with
    | .ok o =>
      ok := ok + ((o.splitOn "\n").map (fun l => (l.replace "\r" "").trim)).countP (fun l => l == "STORED" || l == "DELETED")
    | .error _ => pure ()
  return ok

/-- Compares the test's keys in `copy` with `want`: (missing, wrong value, extra). -/
private def t6Diff (want : Std.HashMap String String) (copy : List (String × String)) :
    List String × List String × List String :=
  let mine := copy.filter (·.1.startsWith t6Prefix)
  let have_ : Std.HashMap String String := mine.foldl (fun m (k, v) => m.insert k v) {}
  let missing := want.toList.filterMap fun (k, _) => if have_.contains k then none else some k
  let wrong := want.toList.filterMap fun (k, v) => match have_.get? k with
    | some x => if x == v then none else some k
    | none => none
  let extra := mine.filterMap fun (k, _) => if want.contains k then none else some k
  (missing, wrong, extra)

private def exactRestoreTest : IO TestResult := do
  let c := ctx "exact-restore"
  c.conditions ["T6: 200 keys before a base; after it (archive only) overwrites, deletes, delete+rewrite, 200 new keys with deletes and overwrites; every pod deleted; every restored copy must hold exactly the expected keys and values"]
  if !(← waitFollowing "a chain is followed" 900) then
    return .fail (notSetUp s!"the archive is not following a chain: {repr (← readArch)}")
  let some a0 ← readArch | return .fail (unobservable "the archiver's metrics cannot be read")
  let some ip ← masterIp | return .fail (notSetUp "no master's address")
  -- before the base
  let nA ← t6Apply ip t6Before
  if nA != t6Before.length then return .fail (notSetUp s!"only {nA} of {t6Before.length} writes before the base were answered")
  match ← runBase "t6" with
  | .error e => return .fail (notSetUp s!"the base: {e}")
  | .ok l => c.event s!"base uploaded: {(l.trim.take 200)}"
  if !(← waitFollowing "the archiver follows the new base's chain" 300 a0.baseTs) then
    return .fail (notSetUp s!"the archive did not bind to the new base: {repr (← readArch)}")
  let some base0 ← latestBase | return .fail (unobservable "the latest base cannot be read")
  -- after the base: only in the archive
  let some ip2 ← masterIp | return .fail (notSetUp "no master's address")
  if ip2 != ip then return .fail (notSetUp s!"the master moved during the test ({ip} -> {ip2})")
  let nB ← t6Apply ip t6After
  if nB != t6After.length then return .fail (notSetUp s!"only {nB} of {t6After.length} writes after the base were answered")
  let tLast ← epochNow
  let want := t6Expected (t6Before ++ t6After)
  c.event s!"writes: {t6Before.length} before the base {base0.1} seq {base0.2.1}, {t6After.length} after it (last at {tLast}); expected {want.size} keys"
  let synced ← waitForCondition "the archive synced past the last write" 180 do
    match ← readArch with
    | some a => return a.synced > tLast
    | none => return false
  if !synced then return .fail (notSetUp s!"the archive did not sync past the writes: {repr (← readArch)}")
  -- the restore must start from THIS base (a newer one would hold the writes itself)
  let some base1 ← latestBase | return .fail (unobservable "the latest base cannot be read")
  if base1 != base0 then return .fail (notSetUp s!"a newer base was taken during the test ({base0.1} seq {base0.2.1} -> {base1.1} seq {base1.2.1})")
  -- all-copy loss
  let some pods0 ← flaredPods | return .fail (notSetUp "the flared pods cannot be read")
  let oldUids := pods0.map (·.uid)
  let _ ← kubectl (["delete", "pod"] ++ pods0.map (·.name) ++ ["-n", nsName, "--force", "--grace-period=0", "--wait=false"])
  let renewed ← waitForCondition "every flared pod is a new pod (new UID), none deleting" 300 do
    match ← flaredPods with
    | some ps => return ps.length == 2 && ps.all (fun p => !oldUids.contains p.uid && !p.deleting)
    | none => return false
  if !renewed then return .fail "the flared pods were not recreated within 300 s"
  let settled ← waitClusterSettled cfg 900 15
  if !settled then return .fail s!"the cluster did not settle within 900 s of the restore: {repr (← readArch)}"
  let mut fails : List String := []
  let mut replayLines : List String := []
  for p in (← flaredPods).getD [] do
    for ln in (← initLog p.name "backup-wal-replay").splitOn "\n" do
      if containsSubstr ln "replay base_seq=" then replayLines := replayLines ++ [ln.trim]
  for ln in replayLines do c.event s!"restore: {ln}"
  if replayLines.isEmpty then fails := fails ++ ["no `replay base_seq=...` summary line in any pod's backup-wal-replay log"]
  for ln in replayLines do
    if fieldOf ln "gap" != some "0" || fieldOf ln "conflict" != some "0" || fieldOf ln "complete" != some "1" then
      fails := fails ++ [s!"replay not gap=0 conflict=0 complete=1: {ln.take 200}"]
    if fieldOf ln "base_seq" != some (toString base0.2.1) then
      fails := fails ++ [s!"the replay did not start from the test's base (seq {base0.2.1}): {ln.take 200}"]
  let appliedMax := (replayLines.filterMap fun ln => (fieldOf ln "applied").bind (·.toNat?)).foldl max 0
  if appliedMax < t6After.length then
    fails := fails ++ [s!"the replay applied {appliedMax} batch(es), fewer than the {t6After.length} writes after the base"]
  -- every copy, the master and the replica
  let mut checked := 0
  for p in (← flaredPods).getD [] do
    let copy? ← match ← getPodIp p.name nsName with
      | some pip => c.ownCopy pip
      | none => pure none
    match copy? with
    | none => fails := fails ++ [s!"{p.name}: the copy cannot be read (no address or no dump)"]
    | some copy =>
      checked := checked + 1
      let (missing, wrong, extra) := t6Diff want copy
      for k in missing.take 50 do c.art "diff.txt" s!"{p.name} missing {k}"
      for k in wrong.take 50 do c.art "diff.txt" s!"{p.name} wrong {k}"
      for k in extra.take 50 do c.art "diff.txt" s!"{p.name} extra {k}"
      c.event s!"{p.name}: {(copy.filter (·.1.startsWith t6Prefix)).length} test keys; missing {missing.length}, wrong value {wrong.length}, deleted but present {extra.length}"
      if !missing.isEmpty || !wrong.isEmpty || !extra.isEmpty then
        fails := fails ++ [s!"{p.name}: missing {missing.length} (first {missing.head?}), wrong value {wrong.length} (first {wrong.head?}), deleted but present {extra.length} (first {extra.head?})"]
  if checked != 2 then fails := fails ++ [s!"{checked} of 2 copies were checked"]
  c.event s!"SUMMARY T6: base seq {base0.2.1}; {t6Before.length} writes before, {t6After.length} after; expected {want.size} keys; replay applied(max) {appliedMax}; copies checked {checked}; failures {fails.length}"
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-! ## The suite -/

private def setupInfra : IO Unit := do
  let _ ← waitForCondition s!"namespace {nsName} not Terminating" 60 do
    match ← kubectl ["get", "namespace", nsName, "-o", "jsonpath={.status.phase}"] with
    | .ok phase => return phase.trim != "Terminating"
    | .error _ => return true
  let _ ← kubectl ["create", "namespace", nsName]
  match ← applyText "infra" infraYaml with
  | .ok _ => pure ()
  | .error e => throw (IO.userError s!"S3 store / Secret / tool pod: {e}")
  if !(← kubectlRolloutStatus "deployment/minio" nsName 300) then
    throw (IO.userError "the S3 store (SeaweedFS) did not become ready")
  if !(← kubectlWaitReady s!"pod/{toolPod}" nsName 180) then
    throw (IO.userError s!"the tool pod ({backupImage}) did not become Ready: is the flare-backup image loaded into kind?")
  let made ← waitForCondition s!"bucket {bucket} created" 120 do
    match ← aws s!"s3 mb s3://{bucket}" 30 with
    | .ok _ => return true
    | .error e => return containsSubstr e "BucketAlreadyOwnedByYou"
  if !made then throw (IO.userError "the bucket could not be created")

def suite : TestSuite :=
  { name := "wal-archive"
    setup := do
      setupInfra
      deployHelmCluster cfg (← helmChartDir) chartSets
      if !(← waitForStable cfg 30) then throw (IO.userError "the cluster did not stabilize")
    teardown := do
      cleanupHelmCluster cfg
      cleanupCluster cfg
      discard <| kubectl ["delete", "namespace", nsName, "--ignore-not-found", "--wait=false"]
    onFailure := do
      dumpClusterDiagnostics nsName s!"app={cfg.operatorName}"
      for sel in ["app=flare-wal-archive", "app=flare-backup"] do
        for cn in ["follow", "upload", "backup"] do
          let l ← match ← kubectl ["logs", "-l", sel, "-n", nsName, "-c", cn, "--tail=200", "--prefix"] with
            | .ok o => pure o
            | .error _ => pure ""
          if !l.trim.isEmpty then IO.eprintln s!"# --- {sel} {cn} ---\n{l}"
    tests := [
      { name := "T1 RPO under load: every ACK older than 60 s survives the loss of every pod (base + archive + replay)", run := rpoTest },
      { name := "T2 master switch: the old chain stops, needs_base, a backup Job, a new chain is followed and synced advances", run := switchTest },
      { name := "T3 on/off: walArchive false/true recreates only the archiver; flared pods untouched; the archive resumes after the last segment", run := toggleTest },
      { name := "T4 offline replay: until time, interrupted replay continues, an incomplete archive exits 4, a database past the base is refused", run := replayTest },
      { name := "T5 the restore refuses an incomplete archive (corrupt newest segment) until accept-incomplete is set", run := refuseTest },
      { name := "T6 exact restore: base + archive give back exactly the written keys and values (overwrites, deletes, rewrites) on every copy", run := exactRestoreTest }
    ] }

end FlareOperator.E2E.Tests.WalArchive
