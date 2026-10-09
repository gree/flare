/-
  WSTR-0 baseline: replica-visibility latency, Redis vs current flare.

  EVALUATION ONLY (FLARE_E2E_VISBENCH=1, workflow evaluation `visibility`);
  without it the suite deploys nothing and its tests skip. One harness
  (bench/visibility/visibility_bench.py, one monotonic clock, open-loop load)
  measures write SEND → first observation in the replica's data, for:

    * flare legacy forwarding (today's production default),
    * flare hybrid forwarding + WAL polling (follow on),
    * Redis asynchronous primary/replica, AOF appendfsync no (the profile
      closest to flare's RocksDB WAL without per-write sync), and
    * Redis memory-only (no AOF, no RDB) as an additional reference only,
    * plus a floor control per protocol (write and read the SAME node).

  Same kind node, same CPU/memory limits, same value size, writers,
  observers and offered rates. A flare replica read counts as LOCAL only if
  the master's cmd_get did not move across the run and the master and
  replica kept their pod UID and flared boot id; otherwise the run is
  recorded as INVALID for replica visibility (its numbers are kept, marked).
  Redis replica reads are local by construction (the replica serves reads);
  its role, link status and run_id are recorded before and after.

  Results land in ci-results/visbench/*.json and a comparison table in
  ci-results/visbench/report.md. CI kind numbers establish relative
  behaviour only; they approve no production latency target.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.VisibilityBench

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def benchOn : IO Bool := return (← IO.getEnv "FLARE_E2E_VISBENCH").isSome

private def benchCfg : ClusterConfig := {
  name := "vis-bench"
  «namespace» := "flare-vis-bench"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-vis-bench"
  storageBackend := "rocksdb"
  usePvc := true
}

private def ns : String := benchCfg.«namespace»
private def outDir : String := "../ci-results/visbench"
private def redisImage : String := "redis:7.2.5"
private def pythonImage : String := "python:3.12-slim"

/-- Profiles and repeats (env-overridable for a quick manual run). -/
private def profiles : IO String := return (← IO.getEnv "FLARE_E2E_VISBENCH_PROFILES").getD "idle,low,normal,peak,burst,sat-4000,sat-8000"
private def repeats : IO String := return (← IO.getEnv "FLARE_E2E_VISBENCH_REPEAT").getD "2"
private def valueSize : IO String := return (← IO.getEnv "FLARE_E2E_VISBENCH_VALUE_SIZE").getD "100"

private def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

/-- Redis primary + replica, each with the flared pod's CPU/memory limits and
    a PVC. `aof` = appendonly yes + appendfsync no; `mem` = no persistence. -/
private def redisYaml (profile : String) : String :=
  let persist := if profile == "aof" then "\"--appendonly\", \"yes\", \"--appendfsync\", \"no\", \"--save\", \"\"" else "\"--appendonly\", \"no\", \"--save\", \"\""
  let one := fun (name : String) (extra : String) => s!"apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {name}
  namespace: {ns}
spec:
  serviceName: {name}
  replicas: 1
  selector:
    matchLabels:
      app: {name}
  template:
    metadata:
      labels:
        app: {name}
        bench: redis
    spec:
      containers:
        - name: redis
          image: {redisImage}
          imagePullPolicy: IfNotPresent
          args: [\"--port\", \"6379\", \"--protected-mode\", \"no\", {persist}{extra}]
          ports:
            - containerPort: 6379
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: {benchCfg.flaredCpuLimit}
              memory: {benchCfg.flaredMemoryLimit}
          volumeMounts:
            - name: data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [\"ReadWriteOnce\"]
        resources:
          requests:
            storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {ns}
spec:
  clusterIP: None
  selector:
    app: {name}
  ports:
    - port: 6379
"
  one "redis-primary" "" ++ "---\n" ++ one "redis-replica" s!", \"--replicaof\", \"redis-primary-0.redis-primary.{ns}.svc.cluster.local\", \"6379\""

private def harnessYaml : String := s!"apiVersion: v1
kind: Pod
metadata:
  name: vis-harness
  namespace: {ns}
spec:
  containers:
    - name: harness
      image: {pythonImage}
      imagePullPolicy: IfNotPresent
      command: [\"sleep\", \"infinity\"]
      resources:
        requests:
          cpu: 500m
          memory: 256Mi
        limits:
          cpu: \"1\"
          memory: 512Mi
      volumeMounts:
        - name: script
          mountPath: /bench
  volumes:
    - name: script
      configMap:
        name: vis-bench-script
"

/-- `kubectl exec` into the harness pod WITHOUT the shared kubectl wrapper's
    30 s wall (CI 37376718731: every measurement was killed at 30 s); bounded
    by its own one-hour wall instead. -/
private def harnessExec (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := "timeout", args := (#["-k", "10", "3600", "kubectl", "exec", "-n", ns, "vis-harness", "--"] ++ args.toArray) }
  if out.stderr.trim != "" then IO.eprintln out.stderr.trim
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"kubectl exec failed ({out.exitCode}): {out.stderr.trim}"

private def deployRedis (profile : String) : IO Bool := do
  discard <| kubectl ["delete", "statefulset", "redis-primary", "redis-replica", "-n", ns, "--ignore-not-found", "--wait=true"]
  discard <| kubectl ["delete", "pvc", "-n", ns, "-l", "bench=redis", "--ignore-not-found"]
  discard <| kubectl ["delete", "pvc", "data-redis-primary-0", "data-redis-replica-0", "-n", ns, "--ignore-not-found", "--wait=true"]
  match ← kubectlApplyStdin (redisYaml profile) with
  | .error e => IO.eprintln s!"# redis apply failed: {e}"; return false
  | .ok _ => pure ()
  waitForCondition s!"redis ({profile}) primary and replica linked" 300 do
    match ← kubectl ["exec", "-n", ns, "redis-replica-0", "--", "redis-cli", "info", "replication"] with
    | .ok o => return containsSubstr o "role:slave" && containsSubstr o "master_link_status:up"
    | .error _ => return false

private def redisInfo (pod : String) : IO String := do
  match ← kubectl ["exec", "-n", ns, pod, "--", "redis-cli", "info", "server"] with
  | .ok o =>
    let pick := fun (k : String) => ((o.splitOn "\n").find? (·.startsWith s!"{k}:")).map (fun l => l.trim) |>.getD s!"{k}:?"
    let r ← kubectl ["exec", "-n", ns, pod, "--", "redis-cli", "info", "replication"]
    let repl := match r with
      | .ok ro => ((ro.splitOn "\n").filter fun l => l.startsWith "role:" || l.startsWith "master_link_status:" || l.startsWith "connected_slaves:").map String.trim
      | .error _ => []
    return s!"{pick "redis_version"} {pick "run_id"} {String.intercalate " " repl}"
  | .error e => return s!"unreadable ({e})"

private def flareStat (ip key : String) : IO (Option String) := do
  match ← execInDebugPod benchCfg.debugPod ns s!"printf 'stats\\r\\n' | nc -w 3 {ip} {benchCfg.flarePort}" with
  | .ok o => return (o.splitOn "\n").findSome? fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none
  | .error _ => return none

private def podUid (pod : String) : IO (Option String) := do
  match ← kubectlGetJsonpath "pod" pod ns "{.metadata.uid}" with
  | .ok o => return some o.trim
  | .error _ => return none

/-- (master pod, master ip, replica pod, replica ip) from the operator's map. -/
private def flarePair : IO (Option (String × String × String × String)) := do
  for _ in [0:30] do
    let sync ← operatorTcpCmd benchCfg.debugPod ns benchCfg.operatorName benchCfg.operatorPort "node sync"
    let entries := parseNodeSync sync
    match findMasterPod entries 0 with
    | some m =>
      match (entries.filter (fun e => e.role == 1 && e.state == 0 && e.partition == 0)).head? with
      | some s =>
        let sPod := (s.fqdn.splitOn ".").head?.getD s.fqdn
        match ← getPodIp m ns, ← getPodIp sPod ns with
        | some mi, some si => return some (m, mi, sPod, si)
        | _, _ => pure ()
      | none => pure ()
    | none => pure ()
    IO.sleep 4000
  return none

/-- Run the harness; save its JSON with a validity record appended. -/
private def runHarness (label proto write read : String) (validity : IO String) (profs reps : String) : IO (Except String String) := do
  let vs ← valueSize
  let out := s!"/tmp/{label}.json"
  match ← harnessExec ["python3", "/bench/visibility_bench.py", "--proto", proto, "--write", write, "--read", read,
                       "--label", label, "--profiles", profs, "--repeat", reps, "--value-size", vs, "--out", out] with
  | .error e => return .error s!"harness failed: {e}"
  | .ok _ => pure ()
  let v ← validity
  match ← harnessExec ["cat", out] with
  | .error e => return .error s!"could not read the result: {e}"
  | .ok json =>
    IO.FS.createDirAll outDir
    IO.FS.writeFile s!"{outDir}/{label}.json" json
    IO.FS.writeFile s!"{outDir}/{label}.validity.txt" v
    IO.eprintln s!"# {label}: saved; validity: {v}"
    return .ok v

/-- Run one flare arm: reads routed to the replica, evidence that every
    replica GET was served locally (master cmd_get unchanged, identities
    unchanged). -/
private def flareArm (label : String) (floor : Bool := false) : IO TestResult := do
  let some (m, mIp, s, sIp) ← flarePair | return .fail "no master/replica pair in the operator's map"
  let readIp := if floor then mIp else sIp
  let mUid0 ← podUid m
  let sUid0 ← podUid s
  let mBoot0 ← flareStat mIp "reconstruction_boot_id"
  let sBoot0 ← flareStat sIp "reconstruction_boot_id"
  let gets0 ← flareStat mIp "cmd_get"
  let mode0 := s!"follow={← flareStat sIp "repl_follow_enabled"} state={← flareStat sIp "repl_follow_state"}"
  let validity : IO String := do
    let gets1 ← flareStat mIp "cmd_get"
    let mUid1 ← podUid m
    let sUid1 ← podUid s
    let mBoot1 ← flareStat mIp "reconstruction_boot_id"
    let sBoot1 ← flareStat sIp "reconstruction_boot_id"
    let same := mUid0.isSome && mUid0 == mUid1 && sUid0 == sUid1 && mBoot0.isSome && mBoot0 == mBoot1 && sBoot0 == sBoot1
    let proxied := match gets0.bind (·.toNat?), gets1.bind (·.toNat?) with
      | some a, some b => some (b - a)
      | _, _ => none
    let verdict :=
      if floor then "FLOOR CONTROL (write and read the master)"
      else if !same then "INVALID: a pod or flared process changed during the run"
      else match proxied with
        | some 0 => "VALID: every replica GET served locally (master cmd_get unchanged)"
        | some n => s!"INVALID for replica visibility: {n} GET(s) reached the master (proxied)"
        | none => "INVALID: the master's cmd_get could not be read before and after"
    return s!"{verdict}; master {m} uid {mUid0}->{mUid1} boot {mBoot0}->{mBoot1}; replica {s} uid {sUid0}->{sUid1} boot {sBoot0}->{sBoot1}; master cmd_get {gets0}->{gets1}; replica {mode0}"
  let (profs, reps) ← if floor then pure ("idle,normal,peak", "1") else pure ((← profiles), (← repeats))
  match ← runHarness label "memcache" s!"{mIp}:{benchCfg.flarePort}" s!"{readIp}:{benchCfg.flarePort}" validity profs reps with
  | .error e => return .fail e
  | .ok v => if floor || containsSubstr v "VALID: every" then return .pass else return .fail s!"{label}: {v}"

private def redisArm (label profile : String) (floor : Bool := false) : IO TestResult := do
  if !(← deployRedis profile) then return .fail s!"redis ({profile}) did not come up linked"
  let some pIp ← getPodIp "redis-primary-0" ns | return .fail "no redis primary IP"
  let some rIp ← getPodIp "redis-replica-0" ns | return .fail "no redis replica IP"
  let before := s!"primary [{← redisInfo "redis-primary-0"}] replica [{← redisInfo "redis-replica-0"}]"
  let validity : IO String := do
    let after := s!"primary [{← redisInfo "redis-primary-0"}] replica [{← redisInfo "redis-replica-0"}]"
    let verdict := if floor then "FLOOR CONTROL (write and read the primary)"
      else if before == after && containsSubstr after "master_link_status:up" then "VALID: replica linked, identities unchanged"
      else "INVALID: replication identity or link changed during the run"
    return s!"{verdict}; profile {profile} (appendfsync {if profile == "aof" then "no" else "n/a, no persistence"}); before {before}; after {after}"
  let (profs, reps) ← if floor then pure ("idle,normal,peak", "1") else pure ((← profiles), (← repeats))
  match ← runHarness label "redis" s!"{pIp}:6379" s!"{if floor then pIp else rIp}:6379" validity profs reps with
  | .error e => return .fail e
  | .ok v => if floor || containsSubstr v "VALID: replica" then return .pass else return .fail s!"{label}: {v}"

private def skipUnlessOn (t : IO TestResult) : IO TestResult := do
  if !(← benchOn) then return .skip "FLARE_E2E_VISBENCH unset (evaluation only)"
  t

def visibilityBenchSuite : TestSuite := {
  name := "visibility-bench"
  setup := do
    if ← benchOn then
      deployCluster benchCfg
      IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
      IO.sleep 50000
      discard <| kubectl ["delete", "configmap", "vis-bench-script", "-n", ns, "--ignore-not-found"]
      discard <| kubectl ["create", "configmap", "vis-bench-script", "-n", ns, "--from-file=visibility_bench.py=../bench/visibility/visibility_bench.py"]
      discard <| kubectlApplyStdin harnessYaml
      discard <| kubectlWaitReady "pod/vis-harness" ns 300
      -- reads routed to the replica for every flare arm (the master is read
      -- only by the floor control)
      discard <| kubectlPatch "flarecluster" benchCfg.name ns "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}"
      IO.sleep 20000
    else IO.eprintln "# FLARE_E2E_VISBENCH unset: the visibility benchmark deploys nothing and its tests are skipped"
  teardown := do
    if ← benchOn then
      discard <| kubectl ["delete", "statefulset", "redis-primary", "redis-replica", "-n", ns, "--ignore-not-found"]
      discard <| kubectl ["delete", "pod", "vis-harness", "-n", ns, "--ignore-not-found", "--wait=false"]
      cleanupCluster benchCfg
  onFailure := dumpClusterDiagnostics ns s!"app={benchCfg.operatorName}"
  tests := [
    { name := "harness self-test (fake primary/replica with a known delay; a frozen replica yields timeouts, not samples)"
      run := skipUnlessOn do
        match ← harnessExec ["python3", "/bench/visibility_bench.py", "--self-test"] with
        | .ok o => IO.eprintln o; return .pass
        | .error e => return .fail e },
    { name := "flare floor control: write and read the master (harness + network floor)"
      run := skipUnlessOn (flareArm "flare-floor" true) },
    { name := "flare legacy forwarding (production default): replica-local visibility"
      run := skipUnlessOn (flareArm "flare-legacy") },
    { name := "flare hybrid forwarding + WAL polling (follow on): replica-local visibility"
      run := skipUnlessOn do
        match ← kubectlPatch "flarecluster" benchCfg.name ns "{\"spec\":{\"rocksdb\":{\"replIdentityForward\":true,\"replFollowEnabled\":true,\"replFollowPollIntervalUsec\":200000}}}" with
        | .error e => return .fail s!"patch failed: {e}"
        | .ok _ => pure ()
        let following ← waitForCondition "the replica follows" 420 do
          match ← flarePair with
          | some (_, _, _, sIp) => return (← flareStat sIp "repl_follow_state") == some "following"
          | none => return false
        if !following then return .fail "the replica never reached following"
        IO.sleep 15000
        flareArm "flare-hybrid-poll" },
    { name := "redis floor control: write and read the primary"
      run := skipUnlessOn (redisArm "redis-floor" "aof" true) },
    { name := "redis async replication, AOF appendfsync no: replica visibility"
      run := skipUnlessOn (redisArm "redis-aof" "aof") },
    { name := "redis async replication, memory only (reference, not an equivalent durability profile)"
      run := skipUnlessOn (redisArm "redis-mem" "mem") },
    { name := "comparison report (absolute values and deltas; no tolerance applied)"
      run := skipUnlessOn do
        match ← hostCmd "sh" ["-c", s!"mkdir -p {outDir} && python3 ../bench/visibility/report.py {outDir} > {outDir}/report.md && cat {outDir}/report.md"] with
        | .ok o => IO.eprintln o; return .pass
        | .error e => return .fail e }
  ]
}

end FlareOperator.E2E.Tests.VisibilityBench
