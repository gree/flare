/-
  E2E/Tests/ContinuousReplication.lean — SAF-10d, minimal acceptance (T2/T3
  shape) for continuous WAL replication on the RocksDB backend.

  Scenario, in the order the reviewer fixed:
    1. normal following: writes reach the replica and the follower reports
       `following`;
    2. the master→replica link is cut; keys are CREATED, UPDATED and DELETED
       on the master while it is cut; then new writes STOP;
    3. the link is healed and the replica catches up from its applied
       position with NO new write arriving — the whole point;
    4. the drop the master counted was HELD by the operator under the
       follower's ownership and CLOSED without a demotion or a rebuild.
  A separate scenario makes the operator's stats fetch of the replica FAIL
  (pods/exec revoked) while a drop is observed: the request must be held as
  Unknown, never demoted, and closed once the probe works again.

  Evidence discipline: the replica is inspected DIRECTLY (its own stats and
  gets on its own pod). `get` on a replica proxies a MISS to the master, so a
  miss proves nothing; local presence and value do, and `curr_items` equality
  covers deletions (a deletion not applied leaves the replica with MORE keys
  than the master). Each test records the position resumed from, the
  reconstruction counters (must not move), the pod UID (must not change), and
  the ledger's hold and close lines.

  Preconditions checked before anything runs: both flags on EVERY node, and
  the replica's read balance 0 (replica reads disabled).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.TraceMatch

namespace FlareOperator.E2E.Tests.ContinuousReplication

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def utcNow : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }
  return out.stdout.trim

private def cfg : ClusterConfig := {
  name := "cont-repl"
  «namespace» := "flare-cont-repl"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl"
  storageBackend := "rocksdb"
  -- Both flags ON for this suite only. The follower applies through the
  -- common rule, which is why identity forwarding must be on as well.
  extraFlaredConf := "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000"
  -- A repair must be watchable within a test.
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
  -- the acceptance's final copy check attributes each replica answer to
  -- its own copy (review 2026-10-13 finding 3)
  flaredEnv := [("FLARE_TEST_READ_TRACE_PREFIX", "acc")]
  -- PVC-backed data: the crash test (kill -9 of flared) needs the copy to
  -- survive the container restart, and a returning ex-master then carries
  -- its OLD history rather than an empty store (the more realistic case).
  usePvc := true
  -- preStop sleep so a deleted master is Terminating long enough for the
  -- operator's GRACEFUL DRAIN (planned promotion through the eligibility
  -- gate) rather than a race between dead detection and the StatefulSet
  -- recreating the pod (on CI the recreated master was back before it was
  -- ever seen absent, so no failover happened at all).
  drainSeconds := 30
}

private def kindNode : String := "flare-e2e-control-plane"
private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- (masterPod, masterIp, replicaPod, replicaIp) for partition 0. -/
private def pair : IO (Except String (String × String × String × String)) := do
  let mut lastErr := ""
  for _ in [0:6] do
    let entries ← nodeView
    match findMasterFqdn entries 0 with
    | none => lastErr := "no Active P0 master in the operator's map"
    | some mFqdn =>
      match entries.find? (fun e => e.fqdn != mFqdn) with
      | none => lastErr := "no second node in the operator's map"
      | some s =>
        match ← getPodIp (podOf mFqdn) cfg.«namespace», ← getPodIp (podOf s.fqdn) cfg.«namespace» with
        | some mIp, some sIp => return .ok (podOf mFqdn, mIp, podOf s.fqdn, sIp)
        | _, _ => lastErr := "could not resolve pod IPs"
    IO.sleep 5000
  return .error lastErr

private def statsOf (ip : String) : IO (Option String) := do
  match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}" with
  | .ok o => return some o
  | .error _ => return none

private def statVal (out : String) (key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    let t := (line.trim.replace "\r" "")
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

private def statNat (ip key : String) : IO (Option Nat) := do
  match ← statsOf ip with
  | none => return none
  | some o => return (statVal o key).bind (·.toNat?)

private def statStr (ip key : String) : IO (Option String) := do
  match ← statsOf ip with
  | none => return none
  | some o => return statVal o key

private def currItems (ip : String) : IO Nat := return (← statNat ip "curr_items").getD 0

/-- Sum of `proxy_write_dropped[*]`; `none` when the stats could not be read
    or a counter does not parse (never a silent 0). -/
private def droppedByMasterOpt (ip : String) : IO (Option Nat) := do
  match ← statsOf ip with
  | none => return none
  | some o =>
    let mut total := 0
    for line in o.splitOn "\n" do
      let t := (line.trim.replace "\r" "")
      if t.startsWith "STAT proxy_write_dropped[" then
        match (t.splitOn " ").getLast? >>= (·.trim.toNat?) with
        | some n => total := total + n
        | none => return none
    return some total

private def droppedByMaster (ip : String) : IO Nat := return (← droppedByMasterOpt ip).getD 0

private def opLog (tail : Nat := 800) : IO String :=
  kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» tail

private def podUid (pod : String) : IO (Option String) := do
  match ← kubectlGetJsonpath "pod" pod cfg.«namespace» "{.metadata.uid}" with
  | .ok o => return some o.trim
  | .error _ => return none

private def ledgerDests : IO (List String) := do
  match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{.status.replicaRepairs.entries[*].dest}" with
  | .ok out => return (out.trim.splitOn " ").filter (· != "")
  | .error _ => return []

private def ledgerHolds : IO String := do
  match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{.status.replicaRepairs.entries[*].hold}" with
  | .ok out => return out.trim
  | .error _ => return ""

-- ─── the fault ─────────────────────────────────────────────────────────

private def ruleSpec (masterIp slaveIp : String) : List String :=
  ["FORWARD", "-s", masterIp, "-d", slaveIp, "-p", "tcp", "--dport", toString cfg.flarePort,
   "-j", "REJECT", "--reject-with", "tcp-reset"]

/-- Reject master→replica flared traffic on the kind node: forwarded writes
    are dropped after their retries, and the follower's fetches (replica →
    master) still connect but the master's replies… no: the follower connects
    FROM the replica, so cut that direction too, or the follower keeps
    catching up during the cut and there is no gap to recover from. -/
private def ruleSpecBack (masterIp slaveIp : String) : List String :=
  ["FORWARD", "-s", slaveIp, "-d", masterIp, "-p", "tcp", "--dport", toString cfg.flarePort,
   "-j", "REJECT", "--reject-with", "tcp-reset"]

private def cut (masterIp slaveIp : String) : IO (Except String Unit) := do
  match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I"] ++ ["FORWARD", "1"] ++ (ruleSpec masterIp slaveIp).drop 1) with
  | .error e => return .error e
  | .ok _ =>
    match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I"] ++ ["FORWARD", "1"] ++ (ruleSpecBack masterIp slaveIp).drop 1) with
    | .error e => return .error e
    | .ok _ =>
      IO.eprintln s!"# fault: rejecting {masterIp} ⇄ {slaveIp}:{cfg.flarePort} on {kindNode} (both directions)"
      return .ok ()

-- Match only the small protocol request, leaving proxied GET connections
-- usable. If packet matching fails, the test's state/cursor assertions fail;
-- a missing fault must never turn into a passing routing test.
private def readGuardRules (masterIp slaveIp : String) : List (List String) :=
  [ruleSpec masterIp slaveIp,
   ["FORWARD", "-s", slaveIp, "-d", masterIp, "-p", "tcp", "--dport", toString cfg.flarePort,
    "-m", "string", "--algo", "bm", "--string", "repl_sync_wal",
    "-j", "REJECT", "--reject-with", "tcp-reset"],
   ["FORWARD", "-d", slaveIp, "-p", "tcp", "--dport", toString cfg.flarePort,
    "-m", "string", "--algo", "bm", "--string", "node sync",
    "-j", "REJECT", "--reject-with", "tcp-reset"]]

/-- One round on `ip` (pod `pod`): GET `marker` (made unique) then every
    key of `expect`, on ONE connection; the replica's read traces for that
    connection are matched and judged by TraceMatch.judgeLocalCopy. Needs
    FLARE_TEST_READ_TRACE_PREFIX = "acc" (cfg). The problems; empty = every
    key matched from the node's own copy.
    `digest`: every reply line longer than 4096 bytes (a value) is replaced
    in the debug pod by `sha256:<hex>:<bytes>` of that line, so a large
    value is compared by content and size (TraceMatch.digestAnswer) without
    carrying it back. -/
private def localCopyRound (pod ip marker : String) (expect : List (String × String)) (digest : Bool := false) : IO (List String) := do
  let mk := s!"{marker}_{← IO.monoMsNow}"
  let keys := expect.map (·.1)
  IO.sleep 1100
  let since ← utcNow
  IO.sleep 1100
  let cmds := String.join ((mk :: keys).map fun k => s!"get {k}\\r\\n") ++ "quit\\r\\n"
  let fetch := if digest then
      s!"printf '{cmds}' | nc -w 15 {ip} {cfg.flarePort} > /tmp/lr && : > /tmp/lr.sed && " ++
      "for b in $(awk 'length($0) > 4096 {print NR}' /tmp/lr); do " ++
      "h=$(sed -n \"$b\"p /tmp/lr | tr -d '\\r\\n' | sha256sum | cut -d' ' -f1); " ++
      "n=$(sed -n \"$b\"p /tmp/lr | tr -d '\\r\\n' | wc -c | tr -d ' '); " ++
      "echo \"$b\"'s/.*/sha256:'\"$h:$n\"'/' >> /tmp/lr.sed; done && sed -f /tmp/lr.sed /tmp/lr"
    else s!"printf '{cmds}' | nc -w 5 {ip} {cfg.flarePort}"
  let replies ← match ← execInDebugPod cfg.debugPod cfg.«namespace» fetch with
    | .ok out => pure ((FlareOperator.E2E.TraceMatch.parseGetReplies (mk :: keys) out).map (·.tail))
    | .error _ => pure none
  IO.sleep 1000
  let log ← match ← kubectl ["logs", "-n", cfg.«namespace», pod, "-c", "flared", s!"--since-time={since}", "--tail=-1"] with
    | .ok o => pure o
    | .error _ => pure ""
  let tr := FlareOperator.E2E.TraceMatch.tracesAfterMarker (FlareOperator.E2E.TraceMatch.readTraces log) mk
  return FlareOperator.E2E.TraceMatch.judgeLocalCopy expect replies tr

/-- ACCEPTANCE's required observation of one node: ONE stats reply and ONE
    pod read (UID, IP, flared containerID and restartCount together). A
    failed read leaves the fields `none` — judged as missing, never 0. -/
private def observeNode (pod ip : String) : IO FlareOperator.E2E.TraceMatch.NodeObs := do
  let stats ← statsOf ip
  let podOut ← match ← kubectlGetJsonpath "pod" pod cfg.«namespace»
      "{.metadata.uid}|{.status.podIP}|{.status.containerStatuses[?(@.name==\"flared\")].containerID}|{.status.containerStatuses[?(@.name==\"flared\")].restartCount}" with
    | .ok o => pure (some o)
    | .error _ => pure none
  return FlareOperator.E2E.TraceMatch.NodeObs.parse ip stats podOut

private def observePair (mPod mIp sPod sIp : String) : IO FlareOperator.E2E.TraceMatch.AccObs := do
  let replica ← observeNode sPod sIp
  let master ← observeNode mPod mIp
  return { replica, master }

private def heal (masterIp slaveIp : String) : IO Unit := do
  for spec in [ruleSpec masterIp slaveIp, ruleSpecBack masterIp slaveIp] ++ readGuardRules masterIp slaveIp do
    for _ in [0:5] do
      match ← hostCmd "docker" (["exec", kindNode, "iptables", "-D"] ++ spec) with
      | .ok _ => pure ()
      | .error _ => break
  IO.eprintln s!"# fault cleared: {masterIp} ⇄ {slaveIp} forwards again"

/-- Revoke / restore the operator's pods/exec (its stats probe runs `kubectl
    exec` into the pod). The rule index is looked up, not assumed. -/
private def execRuleIndex : IO (Option Nat) := do
  match ← hostCmd "sh" ["-c", "kubectl get clusterrole flare-operator -o json | jq -r '[.rules[] | (.resources // []) | index(\"pods/exec\") != null] | index(true)'"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- Make the operator unable to exec into the REPLICA while it can still
    exec into the master (whose stats carry the drop counter): pods/exec in
    the granting rule is replaced by an inert name (a rule with no resources
    is invalid), and a new rule re-grants pods/exec restricted by
    `resourceNames` to the master pod only. Restore puts the exact original
    list back and drops the added rule. -/
private def revokeExec (masterPod : String) : IO (Except String (Nat × String)) := do
  match ← execRuleIndex with
  | none => return .error "no ClusterRole rule grants pods/exec (nothing to revoke)"
  | some i =>
    match ← hostCmd "sh" ["-c", s!"kubectl get clusterrole flare-operator -o json | jq -c '.rules[{i}].resources'"] with
    | .error e => return .error e
    | .ok original =>
      match ← hostCmd "sh" ["-c", s!"kubectl get clusterrole flare-operator -o json | jq -c '.rules[{i}].resources | map(if . == \"pods/exec\" then \"pods/e2e-revoked-exec\" else . end)'"] with
      | .error e => return .error e
      | .ok res =>
        match ← kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
            ("[{\"op\":\"replace\",\"path\":\"/rules/" ++ toString i ++ "/resources\",\"value\":" ++ res.trim ++ "}]")] with
        | .error e => return .error e
        | .ok _ =>
          let verbs := (← hostCmd "sh" ["-c", s!"kubectl get clusterrole flare-operator -o json | jq -c '.rules[{i}].verbs'"]).toOption.getD "[\"create\",\"get\"]"
          match ← kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
              ("[{\"op\":\"add\",\"path\":\"/rules/-\",\"value\":{\"apiGroups\":[\"\"],\"resources\":[\"pods/exec\"],\"resourceNames\":[\"" ++ masterPod ++ "\"],\"verbs\":" ++ verbs.trim ++ "}}]")] with
          | .error e => return .error e
          | .ok _ =>
            IO.eprintln s!"# fault: the operator may exec only into the master {masterPod} (rule {i}: {original.trim} → {res.trim}; added a resourceNames-restricted pods/exec rule)"
            return .ok (i, original.trim)

private def restoreExec (i : Nat) (original : String) : IO Unit := do
  -- The restricted rule was appended last: remove it, then put rule i back.
  match ← hostCmd "sh" ["-c", "kubectl get clusterrole flare-operator -o json | jq -r '.rules | length'"] with
  | .ok n =>
    match n.trim.toNat? with
    | some len => if len > 0 then discard <| kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p", ("[{\"op\":\"remove\",\"path\":\"/rules/" ++ toString (len - 1) ++ "\"}]")]
    | none => pure ()
  | .error _ => pure ()
  discard <| kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
    ("[{\"op\":\"replace\",\"path\":\"/rules/" ++ toString i ++ "/resources\",\"value\":" ++ original ++ "}]")]
  IO.eprintln "# fault cleared: pods/exec restored"

/-- kill -9 the flared process of `pod` FROM THE KIND NODE (inside the pod
    flared is pid 1 of its namespace, which ignores signals sent from within).
    The process is found by its cgroup, which names the pod UID. -/
private def killFlared (uid : String) : IO (Except String String) := do
  let uidUnderscore := uid.replace "-" "_"
  hostCmd "docker" ["exec", kindNode, "sh", "-c",
    s!"n=0; for p in $(pgrep -x flared); do if grep -q -e '{uid}' -e '{uidUnderscore}' /proc/$p/cgroup 2>/dev/null; then kill -9 $p && n=$((n+1)); fi; done; echo killed=$n"]

private def restartCountOf (pod : String) : IO Nat := do
  match ← kubectlGetJsonpath "pod" pod cfg.«namespace» "{.status.containerStatuses[0].restartCount}" with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

-- ─── the suite ─────────────────────────────────────────────────────────

def suite : TestSuite := {
  name := "continuous-replication"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then throw (IO.userError "cluster did not stabilize")
  teardown := do
    -- every fault healed in every exit path
    match ← pair with
    | .ok (_, mIp, _, sIp) => heal mIp sIp
    | .error _ => pure ()
    match ← execRuleIndex with
    | some _ => pure ()
    | none => pure ()
    cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "precondition: both flags are on for every node and the replica's read balance is 0"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{cfg.name}-config" cfg.«namespace» "{.data.extra\\.conf}" with
        | .error e => return .fail s!"could not read the flared extra.conf: {e}"
        | .ok conf =>
          if !(containsSubstr conf "repl-identity-forward = true") || !(containsSubstr conf "repl-follow-enabled = true") then
            return .fail s!"extra.conf does not carry both flags: {conf}"
        let ips ← getPodIps s!"app=flare,cluster={cfg.name}" cfg.«namespace»
        if ips.length < 2 then return .fail s!"expected 2 flared pods, found {ips.length}"
        for ip in ips do
          match ← statNat ip "repl_follow_enabled" with
          | some 1 => pure ()
          | other => return .fail s!"node {ip} does not report repl_follow_enabled=1 (got {other}): the mode is not on everywhere"
        let entries ← nodeView
        match entries.find? (fun e => e.role == 1 && e.partition == 0) with
        | none => return .fail "no P0 slave in the operator's map"
        | some s =>
          if s.balance != 0 then return .fail s!"the replica's read balance is {s.balance}, not 0: replica reads must be disabled for this suite"
        return .pass },

    { name := "normal following: writes reach the replica and its follower reports following"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "base" 30
          if stored != 30 then return .fail s!"stored only {stored}/30 on the master"
          let following ← waitForCondition "replica's follower is following" 120 do
            return (← statStr sIp "repl_follow_state") == some "following"
          if !following then return .fail s!"the follower never reported following (state {← statStr sIp "repl_follow_state"}, reason {← statStr sIp "repl_follow_last_reason"})"
          let caught ← waitForCondition "replica's local items match the master's" 60 do
            return (← currItems sIp) == (← currItems mIp)
          if !caught then return .fail s!"local items master={← currItems mIp} replica={← currItems sIp}"
          let fwd := (← statNat sIp "repl_forward_applied").getD 0
          IO.eprintln s!"# following: replica applied {fwd} forwarded change(s); applied_lsn={← statNat sIp "repl_applied_lsn"} master latest={← statNat mIp "rocksdb_latest_sequence_number"} source_epoch={← statStr sIp "repl_follow_source_epoch"}"
          if fwd == 0 then return .fail "no forwarded change was applied through the common rule (repl_forward_applied is 0): identity forwarding is not in effect"
          let audited ← waitForCondition "operator observes applied topology with Pod identity" 90 do
            let log ← opLog 800
            return (log.splitOn "\n").any fun line =>
              containsSubstr line "[TopologyAudit] node=" &&
              containsSubstr line "uid=(some " && containsSubstr line "verdict=current"
          if !audited then return .fail "no UID-bound current topology observation reached the operator"
          return .pass },

    -- pf-dev 2026-10-14 (rc66): one value larger than the follower's slice
    -- budget (repl-follow-max-bytes, 4 MB by default) stopped the follower
    -- for good. Its position sat at the end of that batch; every slice began
    -- by re-sending it, spent the budget on it alone and ended with MORE, and
    -- the follower retried at once — applied position frozen, ~0.45 core per
    -- node with no writes, until the source purged the WAL.
    { name := "a value larger than the follow budget: on the SAME history and without a rebuild the follower's cursor passes it to the master's head; the replica's OWN copy holds the value (content and size), the 10 later writes, and then its delete"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          -- Required observations (review of d311227, P1): every observation
          -- is an Option checked explicitly; a read failure is never 0, a
          -- count is never the copy, and a catch-up by a rebuild is excluded
          -- (TraceMatch.judgeNoRebuild across the whole test).
          let ready ← waitForCondition "replica following and caught up" 120 do
            let o ← observePair mPod mIp sPod sIp
            return (← statStr sIp "repl_follow_state") == some "following" && FlareOperator.E2E.TraceMatch.caughtUp o
          if !ready then return .fail s!"precondition: replica not following/caught up (state {← statStr sIp "repl_follow_state"})"
          let obs0 ← observePair mPod mIp sPod sIp
          let miss0 := obs0.missing "before"
          if !miss0.isEmpty then return .fail s!"precondition: the required observation is incomplete: {miss0}"
          -- the value: random hex (printable, one line), its size and sha256
          -- as generated in the debug pod
          let size := 5 * 1024 * 1024
          let gen ← execInDebugPod cfg.debugPod cfg.«namespace»
            s!"head -c {size / 2} /dev/urandom | od -An -v -tx1 | tr -d ' \\n' > /tmp/accbig && wc -c < /tmp/accbig | tr -d ' ' && sha256sum /tmp/accbig"
          let some (bytes, hash) := (gen.toOption).bind FlareOperator.E2E.TraceMatch.parseDigestReport
            | return .fail s!"precondition: the large value's size and sha256 could not be read: {gen}"
          if bytes != size then return .fail s!"precondition: generated {bytes} bytes, not {size}"
          let stored ← execInDebugPod cfg.debugPod cfg.«namespace»
            s!"(printf 'set accbig_value 0 0 {size}\\r\\n'; cat /tmp/accbig; printf '\\r\\n') | nc -w 15 {mIp} {cfg.flarePort}"
          if !FlareOperator.E2E.TraceMatch.acked "STORED" stored.toOption then
            return .fail s!"the master did not answer STORED for the {size}-byte value: {stored}"
          let some bigSeq ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "the master's head could not be read after the large value"
          let later := (List.range 10).map fun i => (s!"accbig_{i}", s!"later_{i}")
          for (k, v) in later do
            if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort k v) then return .fail s!"the master did not store {k} after the large value"
          let some head ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "the master's head could not be read after the later writes"
          let reached ← waitForCondition s!"the replica's cursor reaches the master's head {head}" 60 do
            return FlareOperator.E2E.TraceMatch.reachedHead (← observePair mPod mIp sPod sIp) head
          let obs1 ← observePair mPod mIp sPod sIp
          IO.eprintln s!"# large value {bytes} bytes sha256 {hash}: batch {bigSeq}, head {head}; replica applied {obs0.replica.applied} -> {obs1.replica.applied}; state {← statStr sIp "repl_follow_state"}; reconstruction_started {obs0.replica.recon} -> {obs1.replica.recon}"
          if !reached then return .fail s!"the follower did not reach the head {head} within 60 s (applied {obs1.replica.applied}, state {← statStr sIp "repl_follow_state"})"
          let crossed := FlareOperator.E2E.TraceMatch.crossedBatch obs0 obs1 bigSeq
          if !crossed.isEmpty then return .fail s!"the cursor did not pass the large batch: {crossed}"
          let nr1 := FlareOperator.E2E.TraceMatch.judgeNoRebuild "before" "at the head" obs0 obs1
          if !nr1.isEmpty then return .fail s!"caught up, but not on the same process, copy and history without a rebuild: {nr1}"
          -- the replica's OWN copy: reads routed to the replica only and each
          -- answer attributed to its local copy by the read trace
          let balanceOnReplica : IO (Option Nat) := do
            return ((← nodeView).find? (fun e => podOf e.fqdn == sPod)).map (·.balance)
          try
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}"
            let routed ← waitForCondition "the replica's map entry has balance 100" 180 do
              return (← balanceOnReplica) == some 100
            if !routed then return .fail s!"reads could not be routed to the replica (its balance {← balanceOnReplica}): the copy cannot be verified"
            let expect1 := ("accbig_value", FlareOperator.E2E.TraceMatch.digestAnswer hash bytes) :: later.map fun (k, v) => (k, s!"={v}")
            let p1 ← localCopyRound sPod sIp "accbig_mark_held" expect1 (digest := true)
            IO.eprintln s!"# replica's own copy with the value: problems {p1.length}: {p1.take 5}"
            if !p1.isEmpty then return .fail s!"the replica's own copy does not hold the large value and the later writes: {p1.take 5}"
            let del ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete accbig_value\\r\\n' | nc -w 5 {mIp} {cfg.flarePort}"
            if !FlareOperator.E2E.TraceMatch.acked "DELETED" del.toOption then return .fail s!"the master did not answer DELETED: {del}"
            let some head2 ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "the master's head could not be read after the delete"
            let reached2 ← waitForCondition s!"the replica's cursor reaches the delete at {head2}" 60 do
              return FlareOperator.E2E.TraceMatch.reachedHead (← observePair mPod mIp sPod sIp) head2
            if !reached2 then return .fail s!"the follower did not follow the delete (head {head2}, applied {(← observePair mPod mIp sPod sIp).replica.applied})"
            let expect2 := ("accbig_value", "miss") :: later.map fun (k, v) => (k, s!"={v}")
            let p2 ← localCopyRound sPod sIp "accbig_mark_deleted" expect2 (digest := true)
            IO.eprintln s!"# replica's own copy after the delete: problems {p2.length}: {p2.take 5}"
            if !p2.isEmpty then return .fail s!"the replica's own copy after the delete is not as expected: {p2.take 5}"
            -- CONTROL: with reads proxied (slave balance 0) the same round must
            -- fail on every key as not-local, although every answer is correct
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}"
            let withheld ← waitForCondition "the replica's map entry has balance 0" 180 do
              return (← balanceOnReplica) == some 0
            if !withheld then return .fail s!"control precondition: the replica's balance did not go to 0 ({← balanceOnReplica})"
            let ctl ← localCopyRound sPod sIp "accbig_mark_ctl_proxy" expect2 (digest := true)
            let ctlProxied := ctl.length == expect2.length && ctl.all (containsSubstr · "NOT from the replica's own copy")
            IO.eprintln s!"# control (reads proxied): problems {ctl.length}/{expect2.length}, all 'not from the own copy' = {ctlProxied}: {ctl.take 3}"
            if !ctlProxied then return .fail s!"control: with every read proxied the check did not fail on every key as not-local: {ctl.take 5}"
            -- the observation interval ends after the last round
            let obs2 ← observePair mPod mIp sPod sIp
            let nr2 := FlareOperator.E2E.TraceMatch.judgeNoRebuild "before" "after the last round" obs0 obs2 ++
              FlareOperator.E2E.TraceMatch.judgeNoRebuild "at the head" "after the last round" obs1 obs2
            if !nr2.isEmpty then return .fail s!"same process, copy and history without a rebuild not shown through the last round: {nr2}"
            if obs2.master.head != some head2 then return .fail s!"a write reached the master during the check ({head2} -> {obs2.master.head})"
            return .pass
          finally
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}" },

    { name := "cut: create, update and delete on the master while the replica is unreachable; then new writes stop"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let uid0 := (← podUid sPod).getD "?"
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let applied0 := (← statNat sIp "repl_applied_lsn").getD 0
          let d0 ← droppedByMaster mIp
          match ← cut mIp sIp with
          | .error e => return .fail s!"could not inject the fault: {e}"
          | .ok _ => pure ()
          IO.sleep 2000
          -- CREATE 10, UPDATE 5 existing, DELETE 5 existing — all on the master.
          let created ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "cut" 10
          let mut updated := 0
          for i in [0:5] do
            if ← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"base_{i}" s!"updated_{i}" then updated := updated + 1
          let mut deleted := 0
          for i in [20:25] do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete base_{i}\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}" with
            | .ok o => if containsSubstr o "DELETED" then deleted := deleted + 1
            | .error _ => pure ()
          let dropped ← waitForCondition s!"master counts dropped forwarded writes (was {d0})" 120 do
            return (← droppedByMaster mIp) > d0
          -- Let the forwarding retries EXHAUST before healing, so that the
          -- gap is carried by the WAL path rather than by late forwarding
          -- landing after the heal (the first run recovered only the 2 writes
          -- that had given up; the other 18 were still retrying).
          let mut lastDrops ← droppedByMaster mIp
          for _ in [0:12] do
            IO.sleep 10000
            let now ← droppedByMaster mIp
            if now == lastDrops then break
            lastDrops := now
          IO.eprintln s!"# forwarding retries settled at {lastDrops - d0} dropped write(s)"
          let mLatest := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
          let mItems ← currItems mIp
          let sItems ← currItems sIp
          let sState ← statStr sIp "repl_follow_state"
          -- NEW WRITES STOP HERE. Everything below must happen with none.
          IO.eprintln s!"# under the cut: created {created}/10, updated {updated}/5, deleted {deleted}/5; master dropped {(← droppedByMaster mIp) - d0}; master latest={mLatest} items={mItems}; replica items={sItems} applied_lsn={← statNat sIp "repl_applied_lsn"} (was {applied0}) state={sState}; replica pod uid={uid0} reconstruction_started={recon0}"
          if !dropped then heal mIp sIp; return .fail "the master never counted a dropped forwarded write while the link was cut: no divergence was staged"
          if created != 10 || updated != 5 || deleted != 5 then heal mIp sIp; return .fail s!"the master did not accept the staged operations (created {created}, updated {updated}, deleted {deleted})"
          if sItems == mItems then heal mIp sIp; return .fail "the replica's local item count did not diverge while cut: nothing to recover"
          -- Persist the bar for the next tests in a ConfigMap-free way: a file
          -- on the harness host.
          IO.FS.writeFile "/tmp/cont-repl-bar" s!"{mLatest} {mItems} {uid0} {recon0} {applied0}"
          return .pass },

    { name := "heal: with NO new writes the replica catches up from its position — no rebuild, no pod recreation"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let bar ← IO.FS.readFile "/tmp/cont-repl-bar"
          let parts := (bar.trim.splitOn " ")
          let mLatest := (parts.get? 0 >>= (·.toNat?)).getD 0
          let mItems := (parts.get? 1 >>= (·.toNat?)).getD 0
          let uid0 := (parts.get? 2).getD "?"
          let recon0 := (parts.get? 3 >>= (·.toNat?)).getD 0
          let applied0 := (parts.get? 4 >>= (·.toNat?)).getD 0
          let appliedBeforeHeal := (← statNat sIp "repl_applied_lsn").getD 0
          heal mIp sIp
          let caught ← waitForCondition s!"replica applied past the master's position at the cut ({mLatest}) while following" 240 do
            return ((← statNat sIp "repl_applied_lsn").getD 0 ≥ mLatest) && (← statStr sIp "repl_follow_state") == some "following"
          let appliedNow := (← statNat sIp "repl_applied_lsn").getD 0
          let sItems ← currItems sIp
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          let uid1 := (← podUid sPod).getD "?"
          IO.eprintln s!"# after heal: resumed from applied_lsn={appliedBeforeHeal} (cut started at {applied0}) → {appliedNow} (bar {mLatest}); state={← statStr sIp "repl_follow_state"} reason={← statStr sIp "repl_follow_last_reason"}; wal_applied={← statNat sIp "repl_wal_applied"} wal_skipped={← statNat sIp "repl_wal_skipped"}; items master={mItems} replica={sItems}; reconstruction_started {recon0}→{recon1}; pod uid {uid0}→{uid1}"
          if !caught then return .fail s!"the replica did not catch up from its position with no new writes (applied {appliedNow} < {mLatest}, state {← statStr sIp "repl_follow_state"}, reason {← statStr sIp "repl_follow_last_reason"})"
          if appliedBeforeHeal < applied0 then return .fail "the applied position went BACKWARDS across the cut"
          if sItems != mItems then return .fail s!"local items differ after catch-up: master {mItems}, replica {sItems} — a created or deleted key did not make it"
          -- Values: the 5 UPDATED keys must read the new value ON THE REPLICA
          -- (present locally, so this is the local copy, not a proxied miss).
          for i in [0:5] do
            match ← memcachedGet cfg.debugPod cfg.«namespace» sIp cfg.flarePort s!"base_{i}" with
            | some v => if v != s!"updated_{i}" then return .fail s!"base_{i} on the replica is '{v}', expected 'updated_{i}': the update did not apply (an older value survived)"
            | none => return .fail s!"base_{i} is missing on the replica"
          -- Created keys present locally.
          for i in [0:10] do
            match ← memcachedGet cfg.debugPod cfg.«namespace» sIp cfg.flarePort s!"cut_{i}" with
            | some _ => pure ()
            | none => return .fail s!"cut_{i} is missing on the replica"
          if recon1 != recon0 then return .fail s!"a RECONSTRUCTION ran ({recon0}→{recon1}): the blip cost a rebuild, which is the failure this design removes"
          if uid1 != uid0 then return .fail s!"the replica pod was RECREATED ({uid0}→{uid1})"
          if (← statStr sIp "repl_follow_last_reason") == some "needs_rebuild" then return .fail "the follower declared needs_rebuild"
          return .pass },

    { name := "ledger: the counted drop was HELD under the follower's ownership and CLOSED without a demotion"
      run := do
        let held ← waitForCondition "operator held the drop as owned by continuous replication" 60 do
          return containsSubstr (← opLog) "owns the repair"
        if !held then return .fail "the operator never recorded the drop as owned by the follower (no 'owns the repair' line)"
        let closed ← waitForCondition "operator closed the owned request by position" 240 do
          return containsSubstr (← opLog) "REPLICA REPAIR CLOSED by continuous replication"
        let log ← opLog 2000
        if !closed then
          IO.eprintln s!"# ledger holds: {← ledgerHolds}; dests: {← ledgerDests}"
          return .fail "the owned request was never closed by position"
        if containsSubstr log "REPLICA REPAIR: demoting" then return .fail "the ledger DEMOTED the replica although the follower owned the repair"
        if containsSubstr log "REPLICA REPAIR handed over" then return .fail "ownership was handed over during a plain blip"
        let empty ← waitForCondition "ledger persisted as empty" 60 do return (← ledgerDests).isEmpty
        if !empty then return .fail s!"status.replicaRepairs still lists {← ledgerDests} after the close"
        return .pass },

    { name := "operator stats fetch failure: a drop whose follower cannot be probed is held as Unknown, never demoted, and closes when the probe returns"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let uid0 := (← podUid sPod).getD "?"
          match ← revokeExec mPod with
          | .error e => return .fail s!"could not revoke pods/exec: {e}"
          | .ok (ruleIdx, originalRes) =>
            let d0 ← droppedByMaster mIp
            match ← cut mIp sIp with
            | .error e => restoreExec ruleIdx originalRes; return .fail s!"could not inject the fault: {e}"
            | .ok _ => pure ()
            IO.sleep 2000
            let _ ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "unk" 10
            let dropped ← waitForCondition s!"master counts dropped writes (was {d0})" 120 do
              return (← droppedByMaster mIp) > d0
            let mLatest := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
            if !dropped then heal mIp sIp; restoreExec ruleIdx originalRes; return .fail "no drop was counted"
            let unknownHeld ← waitForCondition "operator holds the drop as follower-state-unknown" 150 do
              return containsSubstr (← opLog) "follower state could not be read"
            let holds ← ledgerHolds
            IO.eprintln s!"# with pods/exec revoked: held-as-unknown={unknownHeld}; ledger holds: {holds}"
            -- Heal the link now; the FOLLOWER (flared→flared, not the operator's
            -- probe) catches up regardless of the operator's blindness.
            heal mIp sIp
            if !unknownHeld then restoreExec ruleIdx originalRes; return .fail "the drop was not held as Unknown while the operator could not probe the replica"
            let caught ← waitForCondition "replica catches up (follower does not depend on the operator's probe)" 240 do
              return (← statNat sIp "repl_applied_lsn").getD 0 ≥ mLatest
            -- Still blind: the operator must NOT have demoted anything meanwhile.
            let logBlind ← opLog 2000
            let demotedBlind := containsSubstr logBlind "REPLICA REPAIR: demoting"
            restoreExec ruleIdx originalRes
            if !caught then return .fail "the follower did not catch up after the heal"
            if demotedBlind then return .fail "the operator DEMOTED the replica while it could not read its follower state: Unknown became a decision"
            let closed ← waitForCondition "once the probe works again the owned request closes by position" 300 do
              return containsSubstr (← opLog) "REPLICA REPAIR CLOSED by continuous replication"
            let recon1 := (← statNat sIp "reconstruction_started").getD 0
            let uid1 := (← podUid sPod).getD "?"
            IO.eprintln s!"# after restoring pods/exec: closed={closed}; reconstruction_started {recon0}→{recon1}; pod uid {uid0}→{uid1}"
            if !closed then return .fail s!"the request held as Unknown was not closed once the probe returned (holds: {← ledgerHolds})"
            if recon1 != recon0 then return .fail "a reconstruction ran during the operator's blindness"
            if uid1 != uid0 then return .fail "the replica pod was recreated"
            return .pass },

    -- SAF-10c / T14 + T16: a BULK operation on the master (flush_all →
    -- truncate) advances the source epoch. The follower must refuse the old
    -- stream (needs_rebuild, epoch_mismatch), the operator must put it
    -- through the rebuild path from the FOLLOWER'S OWN declaration (no drop
    -- counter is involved), and afterwards the follower must be following
    -- the NEW epoch with new writes arriving. The pod is not recreated.
    { name := "bulk operation: flush_all on the master advances the epoch; the follower declares needs_rebuild; the operator rebuilds it; it follows the new epoch"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          -- Precondition: no repair entry is pending (a leftover request from
          -- an earlier scenario would rebuild the node by the drop path and
          -- mask the follower-declared path this test is about).
          let clean ← waitForCondition "no repair entry pending before the bulk operation" 180 do
            return (← ledgerDests).isEmpty
          if !clean then return .fail s!"a repair entry is still pending from an earlier scenario: {← ledgerDests} ({← ledgerHolds})"
          let epoch0 := (← statStr mIp "rocksdb_source_epoch").getD "?"
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let uid0 := (← podUid sPod).getD "?"
          match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'flush_all\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}" with
          | .error e => return .fail s!"flush_all failed: {e}"
          | .ok o => if !containsSubstr o "OK" then return .fail s!"flush_all did not answer OK: {o.trim}"
          let epoch1 := (← statStr mIp "rocksdb_source_epoch").getD "?"
          IO.eprintln s!"# flush_all on the master: source_epoch {epoch0} → {epoch1}; master items={← currItems mIp}"
          if epoch1 == epoch0 then return .fail "the master's source epoch did not advance on flush_all"
          let declared ← waitForCondition "follower declares needs_rebuild" 90 do
            return (← statStr sIp "repl_follow_state") == some "needs_rebuild"
          IO.eprintln s!"# follower: state={← statStr sIp "repl_follow_state"} reason={← statStr sIp "repl_follow_last_reason"}"
          -- Evidence that the request came from the FOLLOWER's declaration,
          -- not from a drop counter: the persisted ledger entry for this node
          -- carries drops = 0 (a drop-path request carries the count), or
          -- the operator's own line. The entry is short-lived (requested →
          -- demoted → reseated → completed), so poll for either.
          let seenEntry ← IO.mkRef ""
          -- Two paths can request this rebuild and they race: the follower's
          -- own declaration (entry with drops = 0, or the operator's line) and
          -- the drop path — after the epoch change the master's forwarded
          -- ops are REFUSED by the stale-session replica, retried and counted
          -- as drops (observed: 2 within seconds). Either is a ledger request
          -- that takes the node through demote → reseat → reconstruction;
          -- the follower-declared path alone is pinned by flare_unit
          -- (requestRebuild). Record which one was seen.
          let byFollower ← IO.mkRef false
          let requested ← waitForCondition "operator requests the rebuild (ledger entry for the follower)" 120 do
            let log ← opLog 4000
            let byLog := containsSubstr log "REPLICA REPAIR requested by the follower" && containsSubstr log sPod
            match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{range .status.replicaRepairs.entries[*]}{.dest}={.drops}/{.phase} {end}" with
            | .ok out =>
              let mine := (out.trim.splitOn " ").filter (fun e => e.startsWith sPod)
              if !mine.isEmpty then seenEntry.set (String.intercalate " " mine)
              let zeroDrops := mine.any (fun e => (e.splitOn "=").getLast? |>.map (·.startsWith "0/") |>.getD false)
              if byLog || zeroDrops then byFollower.set true
              return byLog || !mine.isEmpty
            | .error _ => return byLog
          IO.eprintln s!"# request evidence: ledger entry seen={← seenEntry.get}; follower-declared path={← byFollower.get} (false = the drop path won the race); master drops now={← droppedByMaster mIp}"
          if !declared && !requested then return .fail "the follower never declared needs_rebuild and no request was made"
          let rebuilt ← waitForCondition "follower reconstructed and follows the new epoch" 420 do
            let recon := (← statNat sIp "reconstruction_started").getD 0
            return recon > recon0 && (← statStr sIp "repl_follow_state") == some "following"
              && (← statStr sIp "repl_follow_source_epoch") == some epoch1
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          IO.eprintln s!"# after the rebuild: reconstruction_started {recon0}→{recon1}; state={← statStr sIp "repl_follow_state"} epoch={← statStr sIp "repl_follow_source_epoch"} (master {epoch1}); ledger request observed={requested}"
          if !rebuilt then
            -- Diagnostics: the replica's own view of the role shifts and any
            -- reconstruction attempt, and the operator's repair lines.
            match ← hostCmd "sh" ["-c", s!"kubectl logs -n {cfg.«namespace»} {sPod} --tail=800 | grep -E 'shift|reconstruct|proxy|follow|deactivat|snapshot|truncate|prepare' | grep -v _reconstruct_node_partition | tail -40"] with
            | .ok o => IO.eprintln s!"# --- replica flared log (filtered) ---\n{o}"
            | .error e => IO.eprintln s!"# (could not read the replica's log: {e})"
            match ← hostCmd "sh" ["-c", s!"kubectl logs -n {cfg.«namespace»} -l app={cfg.operatorName} --tail=3000 | grep -E 'REPLICA REPAIR|NodeState|re-seat|autoAssign|assigned' | tail -30"] with
            | .ok o => IO.eprintln s!"# --- operator log (filtered) ---\n{o}"
            | .error e => IO.eprintln s!"# (could not read the operator's log: {e})"
            return .fail s!"the follower did not come back following the new epoch (state {← statStr sIp "repl_follow_state"}, epoch {← statStr sIp "repl_follow_source_epoch"}, reason {← statStr sIp "repl_follow_last_reason"}); nodes: {(← nodeView).map (fun e => s!"{(e.fqdn.splitOn ".").head?.getD e.fqdn}:r{e.role}/s{e.state}/p{e.partition}/b{e.balance}")}"
          if !requested then return .fail "the rebuild happened without a repair-ledger request being observed"
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "post_flush" 10
          if stored != 10 then return .fail s!"stored only {stored}/10 after the flush"
          let caught ← waitForCondition "new writes reach the rebuilt follower" 90 do
            return (← currItems sIp) == (← currItems mIp) && (← currItems mIp) == 10
          if !caught then return .fail s!"items master={← currItems mIp} replica={← currItems sIp}"
          let empty ← waitForCondition "ledger persisted as empty" 180 do return (← ledgerDests).isEmpty
          let uid1 := (← podUid sPod).getD "?"
          IO.eprintln s!"# post-flush writes: master={← currItems mIp} replica={← currItems sIp}; ledger empty={empty}; pod uid {uid0}→{uid1}"
          if !empty then return .fail s!"the ledger still holds {← ledgerDests}"
          if uid1 != uid0 then return .fail "the replica pod was recreated (the rebuild must be in place)"
          return .pass },

    -- SAF-10c read eligibility: with spec.readBalance.slave = 50 the
    -- FOLLOWING replica serves reads; while cut it is WITHHELD (balance 0,
    -- whatever the spec says); after healing it is restored.
    { name := "read eligibility: a following replica gets the spec's slave balance; a cut replica is withheld to 0; healing restores it"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let balanceOfReplica : IO (Option Nat) := do
            let entries ← nodeView
            return (entries.find? (fun e => (e.fqdn.splitOn ".").head? == some sPod)).map (·.balance)
          match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":50}}}" with
          | .error e => return .fail s!"patch failed: {e}"
          | .ok _ => pure ()
          let served ← waitForCondition "following replica gets balance 50" 150 do
            return (← balanceOfReplica) == some 50
          IO.eprintln s!"# with slave=50: replica balance={← balanceOfReplica} state={← statStr sIp "repl_follow_state"}"
          if !served then return .fail s!"the following replica never received balance 50 (got {← balanceOfReplica})"
          if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort "read_guard" "before_cut") then
            return .fail "could not seed the read-guard control key"
          let control ← waitForCondition "read control succeeds before the cut" 120 do
            return (← memcachedGet cfg.debugPod cfg.«namespace» sIp cfg.flarePort "read_guard") == some "before_cut"
          if !control then return .fail "the read control did not succeed before the fault"
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let withheld ← waitForCondition "cut replica is withheld from reads (balance 0)" 150 do
            return (← balanceOfReplica) == some 0
          let logged := containsSubstr (← opLog 1500) "eligibility"
          let updated ← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort "read_guard" "after_cut"
          -- Both directions are cut: forwarding to the master may fail, but
          -- returning the old locally stored value is never acceptable.
          let duringCut ← memcachedGet cfg.debugPod cfg.«namespace» sIp cfg.flarePort "read_guard"
          IO.eprintln s!"# under the cut: replica balance={← balanceOfReplica} state={← statStr sIp "repl_follow_state"} eligibility-logged={logged}"
          heal mIp sIp
          if !updated then return .fail "the master did not accept the update during the cut"
          if duringCut == some "before_cut" then return .fail "the disconnected replica served its stale local value"
          if !withheld then return .fail "the disconnected replica kept its read balance"
          let restored ← waitForCondition "healed replica is served again (balance 50)" 240 do
            return (← balanceOfReplica) == some 50 && (← statStr sIp "repl_follow_state") == some "following"
          IO.eprintln s!"# after the heal: replica balance={← balanceOfReplica} state={← statStr sIp "repl_follow_state"}"
          discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}"
          if !restored then return .fail "the healed, following replica was not restored to balance 50"
          let fresh ← memcachedGet cfg.debugPod cfg.«namespace» sIp cfg.flarePort "read_guard"
          if fresh != some "after_cut" then return .fail "reads did not return the updated value after healing"
          let back ← waitForCondition "spec restored to slave=0" 120 do return (← balanceOfReplica) == some 0
          if !back then return .fail "balance did not return to 0 after restoring the spec"
          return .pass },

    { name := "local read guard: stale positive balance proxies a missing value to the master while WAL remains blocked"
      run := do
        -- R4: the fixed start of this test's observation window
        let testStart ← utcNow
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let entries ← nodeView
          let some slave := entries.find? (fun e => podOf e.fqdn == sPod)
            | return .fail "replica missing from map"
          let operatorIps ← getPodIps s!"app={cfg.operatorName}" cfg.«namespace»
          if operatorIps.isEmpty then return .fail "no operator IP to isolate topology delivery"
          -- Block both pushed maps and replies to replica-initiated index
          -- requests. Matching only 'node sync' misses the latter path.
          let topologyRules := operatorIps.flatMap fun opIp =>
            [["FORWARD", "-s", opIp, "-d", sIp, "-p", "tcp", "-j", "REJECT", "--reject-with", "tcp-reset"],
             ["FORWARD", "-s", sIp, "-d", opIp, "-p", "tcp", "-j", "REJECT", "--reject-with", "tcp-reset"]]
          let localBalance : IO (Option String) := do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats nodes\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
            | .error _ => return none
            | .ok out => return statVal out s!"{slave.fqdn}:{cfg.flarePort}:balance"
          try
            match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":50}}}" with
            | .error e => return .fail e
            | .ok _ => pure ()
            let ready ← waitForCondition "replica itself has balance 50 and a caught-up follower" 150 do
              return (← localBalance) == some "50" &&
                (← statStr sIp "repl_follow_state") == some "following" &&
                (← statNat sIp "repl_applied_lsn") == (← statNat mIp "rocksdb_latest_sequence_number")
            if !ready then return .fail "positive local balance / caught-up precondition not reached"
            -- R4 (CI 37740298550): the replica accepted a balance-0 map (an
            -- unconfirmed send being retried) BETWEEN the balance read and the
            -- rules. The precondition is a STABLE snapshot — version, balance
            -- 50, the same version — and it is confirmed again once the rules
            -- are in force; otherwise the run says nothing about the guard.
            let snapshot : IO (Option Nat) := do
              let v1 ← statNat sIp "node_map_version"
              let b ← localBalance
              let v2 ← statNat sIp "node_map_version"
              return if v1.isSome && v1 == v2 && b == some "50" then v1 else none
            -- keep the snapshot the wait confirmed; a second read could see a
            -- later version and lose a precondition that held (CI 38791047421)
            let seenVer ← IO.mkRef (none : Option Nat)
            let stable ← waitForCondition "a stable snapshot: the same map version around a balance-50 read" 60 do
              let s ← snapshot
              seenVer.set s
              return s.isSome
            let verAtReady ← seenVer.get
            let readyAt ← utcNow
            if !stable || verAtReady.isNone then return .fail "PRECONDITION NOT MET: no stable balance-50 snapshot of the replica's own map"
            for spec in topologyRules ++ readGuardRules mIp sIp do
              match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ spec.drop 1) with
              | .error e => return .fail e
              | .ok _ => pure ()
            let rulesAt ← utcNow
            -- confirmed AFTER the rules are in force: the same version, still 50
            let verAfterRules ← snapshot
            if verAfterRules != verAtReady then
              return .fail s!"PRECONDITION NOT MET (not a guard result): the replica's map changed around the moment the rules took effect (version {verAtReady} at the precondition, snapshot after the rules {verAfterRules}); a map in flight before the fault"
            let disconnected ← waitForCondition "WAL requests actually rejected" 90 do
              return (← statStr sIp "repl_follow_state") == some "disconnected"
            if !disconnected then return .fail "selective WAL fault did not reach disconnected state"
            let some cursor ← statNat sIp "repl_applied_lsn" | return .fail "missing cursor"
            let some forwarded ← statNat sIp "repl_forward_applied" | return .fail "missing forward counter"
            let drops ← droppedByMaster mIp
            let key := s!"guard_missing_{cursor}"
            if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort key "from_master") then
              return .fail "master did not accept the test value"
            let dropped ← waitForCondition "forwarded test write is dropped" 90 do
              return (← droppedByMaster mIp) > drops
            if !dropped then return .fail "write fault did not cause a dropped forward"
            let some head ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "missing master head"
            if head <= cursor then return .fail "no WAL backlog was staged"
            let balNow ← localBalance
            if balNow != some "50" then
              -- CI 37414948177: the replica's own map changed although topology
              -- delivery was blocked both ways. Unexplained: print what the
              -- replica holds and what the operator did, do not guess.
              let nodesOut := match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats nodes\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
                | .ok o => o
                | .error e => s!"(unreadable: {e})"
              -- R4: every relevant line since the test started (no tail cut)
              let opSince := match ← kubectl ["logs", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", s!"--since-time={testStart}", "--timestamps", "--tail=-1"] with
                | .ok o => o
                | .error e => s!"(operator log unreadable: {e})"
              let opTail := (opSince.splitOn "\n").filter (fun l => containsSubstr l "broadcast" || containsSubstr l "topology" || containsSubstr l "withh" || containsSubstr l "eligib" || containsSubstr l "balance" || containsSubstr l "node map" || containsSubstr l "unconfirmed")
              IO.eprintln s!"# replica local balance now {balNow}; its stats nodes:\n{nodesOut}\n# operator topology/eligibility lines since {testStart} ({opTail.length}):\n{String.intercalate "\n" opTail}"
              -- RECEIVER side: an 'unconfirmed' send may have been APPLIED with
              -- only the reply lost. The replica's own log shows every map it
              -- applied (and any balance change), with times.
              let sPodName := (slave.fqdn.splitOn ".").headD ""
              let recv := match ← kubectl ["logs", "-n", cfg.«namespace», sPodName, "-c", "flared", s!"--since-time={testStart}", "--timestamps", "--tail=-1"] with
                | .ok o => (o.splitOn "\n").filter FlareOperator.E2E.TraceMatch.receiverMapLine
                | .error e => [s!"(replica log unreadable: {e})"]
              IO.eprintln s!"# replica {sPodName}: maps applied / role, balance, read-source changes since {testStart} (receiver side, {recv.length} line(s), all):\n{String.intercalate "\n" recv}"
              let counters := match ← hostCmd "docker" ["exec", kindNode, "iptables", "-L", "FORWARD", "-v", "-n", "-x"] with
                | .ok o => ((o.splitOn "\n").filter fun l => operatorIps.any (containsSubstr l ·)) |> String.intercalate "\n"
                | .error e => s!"(unreadable: {e})"
              IO.eprintln s!"# R4 timeline: stable precondition snapshot at {readyAt}: replica map version {verAtReady}; operator<->replica rules in force from {rulesAt}; snapshot right after the rules: version {verAfterRules} (balance 50); replica map version now {← statNat sIp "node_map_version"}\n# operator<->replica REJECT rule counters (packets bytes):\n{counters}"
              return .fail s!"map changed ({balNow}) although topology delivery to the replica was blocked: this would only test operator withholding"
            let value ← memcachedGet cfg.debugPod cfg.«namespace» sIp cfg.flarePort key
            let after ← statNat sIp "repl_applied_lsn"
            let forwardedAfter ← statNat sIp "repl_forward_applied"
            IO.eprintln s!"# isolated read guard: local balance={← localBalance}, cursor={cursor}→{after}, head={head}, forwards={forwarded}→{forwardedAfter}, read={value}"
            if value != some "from_master" then return .fail "slave did not return the master's new value"
            if after != some cursor || forwardedAfter != some forwarded then
              return .fail "replication advanced: successful GET does not isolate the proxy path"
            if (← localBalance) != some "50" then return .fail "positive balance was not retained through the GET"
            -- Hold desired balance at 0 BEFORE healing: recovery must not
            -- depend on the old harness's forced 50→0 map change.
            match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}" with
            | .error e => return .fail e
            | .ok _ => pure ()
            let pending ← waitForCondition "blocked topology is retained for retry" 90 do
              let current ← nodeView
              return (current.find? (fun e => podOf e.fqdn == sPod)).map (·.balance) == some 0 &&
                containsSubstr (← opLog 500) "topology delivery unconfirmed"
            if !pending then return .fail "operator never recorded unconfirmed delivery of the withheld map"
            return .pass
          finally
            for spec in topologyRules do
              discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D"] ++ spec)
            heal mIp sIp
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}"
            -- The failed transport now stays pending through the lease
            -- fence. No explicit 50→0 recovery transition is needed.
            let recovered ← waitForCondition "isolated read-guard fault is fully restored" 240 do
              return (← localBalance) == some "0" &&
                (← statStr sIp "repl_follow_state") == some "following" &&
                (← statNat sIp "repl_applied_lsn") == (← statNat mIp "rocksdb_latest_sequence_number")
            if !recovered then throw (IO.userError "read-guard cleanup did not restore balance and catch-up")
    },

    -- read-unavailable-error (user decision 2026-10-02, item 5): when a
    -- replica cannot serve a get — its local read is withheld (follower
    -- disconnected) AND the forward to the master fails — it answers a miss
    -- by default, and SERVER_ERROR with the option on. Each switch is
    -- confirmed by flared's own reload notice, not by timing.
    { name := "read-unavailable-error: with the forward to the master cut, a replica answers SERVER_ERROR with the option on and the legacy miss with it off"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let key := "rue_probe"
          if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort key "present") then
            return .fail "precondition: master did not accept the probe key"
          let settle ← waitForCondition "replica following and the key replicated" 120 do
            return (← statStr sIp "repl_follow_state") == some "following"
          if !settle then return .fail "precondition: replica not following"
          let reloadSeen := fun (needle : String) => do
            match ← hostCmd "kubectl" ["logs", "-n", cfg.«namespace», sPod, "--tail=3000"] with
            | .ok o => return containsSubstr o needle
            | .error _ => return false
          -- The follow flags are declared with the option: the operator
          -- rewrites the whole extra.conf from spec.rocksdb, and the flags
          -- baked into this suite's initial config would otherwise vanish
          -- from the file (a later restart would come up without follow).
          let setOpt := fun (on : Bool) => kubectlPatch "flarecluster" cfg.name cfg.«namespace»
            s!"\{\"spec\":\{\"rocksdb\":\{\"replIdentityForward\":true,\"replFollowEnabled\":true,\"replFollowPollIntervalUsec\":200000,\"readUnavailableError\":{if on then "true" else "false"}}}}"
          let rule := ["FORWARD", "-s", sIp, "-d", mIp, "-p", "tcp", "--dport", toString cfg.flarePort, "-j", "REJECT", "--reject-with", "tcp-reset"]
          -- The forward to the master retries with reconnects before it is
          -- given up, which outlasted a 5 s nc idle timeout (CI 36938834526:
          -- empty reply). Wait up to 40 s and report how long it took.
          let rawGet : IO String := do
            let t0 ← IO.monoMsNow
            let r ← match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {key}\\r\\n' | nc -w 40 {sIp} {cfg.flarePort}" with
              | .ok o => pure o.trim
              | .error e => pure s!"(error {e})"
            return s!"{r} [{((← IO.monoMsNow) - t0) / 1000}s]"
          let replicaLines : IO String := do
            match ← hostCmd "sh" ["-c", s!"kubectl logs -n {cfg.«namespace»} {sPod} --tail=400 | grep -E 'rue_probe|read-unavailable|could not be served|pretending not found|proxy' | tail -8"] with
            | .ok o => return o
            | .error _ => return ""
          try
            match ← setOpt true with
            | .error e => return .fail s!"patch failed: {e}"
            | .ok _ => pure ()
            let on ← waitForCondition "replica flared reloads read-unavailable-error = true" 240 do
              reloadSeen "read_unavailable_error: 0 -> 1"
            if !on then return .fail "the replica never reported read_unavailable_error 0 -> 1 (config not applied)"
            match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ rule.drop 1) with
            | .error e => return .fail e
            | .ok _ => pure ()
            let disconnected ← waitForCondition "the replica's follower is disconnected (its local read is withheld)" 90 do
              return (← statStr sIp "repl_follow_state") == some "disconnected"
            if !disconnected then return .fail "precondition: the follower did not disconnect under the cut"
            let withOpt ← rawGet
            IO.eprintln s!"# option on, forward cut: get on the replica -> {withOpt}"
            if !containsSubstr withOpt "SERVER_ERROR" then
              IO.eprintln s!"# replica flared lines:\n{← replicaLines}"
              return .fail s!"with read-unavailable-error on, a get the replica cannot serve did not answer SERVER_ERROR: {withOpt}"
            match ← setOpt false with
            | .error e => return .fail s!"patch failed: {e}"
            | .ok _ => pure ()
            let off ← waitForCondition "replica flared reloads read-unavailable-error = false" 240 do
              reloadSeen "read_unavailable_error: 1 -> 0"
            if !off then return .fail "the replica never reported read_unavailable_error 1 -> 0"
            let withoutOpt ← rawGet
            IO.eprintln s!"# option off, forward cut: get on the replica -> {withoutOpt}"
            if containsSubstr withoutOpt "SERVER_ERROR" || containsSubstr withoutOpt "VALUE" then
              return .fail s!"with the option off the legacy reply is a miss (END); got {withoutOpt}"
            return .pass
          finally
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D"] ++ rule)
            discard <| setOpt false
            let back ← waitForCondition "replica follows again after the cut" 240 do
              return (← statStr sIp "repl_follow_state") == some "following"
            if !back then throw (IO.userError "read-unavailable-error cleanup: the replica did not follow again")
    },

    -- PRODUCTION ACCEPTANCE (fixed by the user 2026-10-13, item 4), in ONE
    -- run: the same master and history, the WAL still retained; BOTH
    -- replication paths cut (the forward master→replica and the follower's
    -- repl_sync_wal replica→master); creates, updates and deletes during
    -- the cut; writes then STOP (the harness issues none; the master's head
    -- is only observed, not used as the stop); connectivity restored; the
    -- replica resumes from its APPLIED cursor with no reconstruction (no
    -- dump, no snapshot reseed, no WAL fallback to dump), no container
    -- restart and no pod recreation; every key matches. Before it catches up
    -- no client read on the replica returns its stale copy: with the master
    -- reachable (phase 1: only the replication paths cut) the read is the
    -- master's value; with the master unreachable (phase 2: everything
    -- cut) it is an explicit SERVER_ERROR (read-unavailable-error on,
    -- production policy R2) — never END and never the old value.
    -- A kind iptables cut, not an AZ failure: evidence for the network
    -- partition only.
    { name := "ACCEPTANCE: both replication paths cut, create/update/delete, writes stopped, healed: resume from the applied cursor with no rebuild / restart / recreation, every key matches; while lagging a replica read is the master's value or SERVER_ERROR, never stale or END"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let setOpt := fun (on : Bool) (slave : Nat) => do
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» s!"\{\"spec\":\{\"readBalance\":\{\"master\":100,\"slave\":{slave}}}}"
            kubectlPatch "flarecluster" cfg.name cfg.«namespace»
              s!"\{\"spec\":\{\"rocksdb\":\{\"replIdentityForward\":true,\"replFollowEnabled\":true,\"replFollowPollIntervalUsec\":200000,\"readUnavailableError\":{if on then "true" else "false"}}}}"
          -- one raw get: (kind, value, seconds); kind = value | miss | error | other
          let rawGet := fun (ip key : String) => do
            let t0 ← IO.monoMsNow
            let out ← match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {key}\\r\\n' | nc -w 40 {ip} {cfg.flarePort}" with
              | .ok o => pure o
              | .error e => pure s!"(exec error {e})"
            let lines := (out.splitOn "\n").map (fun l => (l.replace "\r" "").trim) |>.filter (· != "")
            let secs := ((← IO.monoMsNow) - t0) / 1000
            let r : String × String :=
              if lines.any (·.startsWith "SERVER_ERROR") then ("error", lines.headD "")
              else match lines with
                | h :: v :: _ => if h.startsWith s!"VALUE {key} " then ("value", v) else ("other", out.trim)
                | ["END"] => ("miss", "")
                | _ => ("other", out.trim)
            return (r.1, r.2, secs)
          let balanceOnReplica : IO (Option Nat) := do
            return ((← nodeView).find? (fun e => podOf e.fqdn == sPod)).map (·.balance)
          let reloadSeen := fun (needle : String) => do
            match ← hostCmd "kubectl" ["logs", "-n", cfg.«namespace», sPod, "--tail=5000"] with
            | .ok o => return containsSubstr o needle
            | .error _ => return false
          try
            -- ── precondition: production read policy on, replica served (50), following, caught up
            match ← setOpt true 50 with
            | .error e => return .fail s!"patch failed: {e}"
            | .ok _ => pure ()
            let on ← waitForCondition "replica flared reloads read-unavailable-error = true" 240 do
              reloadSeen "read_unavailable_error: 0 -> 1"
            if !on then return .fail "precondition: the replica never reported read_unavailable_error 0 -> 1"
            -- the base set: acc_0..19 = base_i
            for i in [0:20] do
              if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"acc_{i}" s!"base_{i}") then
                return .fail s!"precondition: the master did not store acc_{i}"
            -- Required observations (review 2026-10-13 round 11): every field of
            -- AccObs must be obtained, at every instant, or the test fails —
            -- a read failure is never "unchanged" / "no rebuild" / "same
            -- history"; a number 0 is a value. Observed before the cut,
            -- after the heal, and after the FINAL local-copy round.
            let ready ← waitForCondition "replica following, caught up, balance 50" 180 do
              let o ← observePair mPod mIp sPod sIp
              return (← statStr sIp "repl_follow_state") == some "following" &&
                FlareOperator.E2E.TraceMatch.caughtUp o &&
                (← balanceOnReplica) == some 50
            if !ready then return .fail s!"precondition: replica not following/caught up with balance 50 (state {← statStr sIp "repl_follow_state"}, balance {← balanceOnReplica})"
            let obs0 ← observePair mPod mIp sPod sIp
            let miss0 := obs0.missing "before"
            IO.eprintln s!"# observation before: {repr obs0}"
            if !miss0.isEmpty then return .fail s!"precondition: the required observation is incomplete: {miss0}"
            let applied0 := obs0.replica.applied.getD 0
            let some d0 ← droppedByMasterOpt mIp | return .fail "precondition: the master's proxy_write_dropped counters could not be read"
            -- expected final content (key → some value | none = deleted)
            let mut expect : List (String × Option String) := (List.range 20).map fun i => (s!"acc_{i}", some s!"base_{i}")
            let setExp := fun (xs : List (String × Option String)) (k : String) (v : Option String) =>
              (xs.filter (·.1 != k)) ++ [(k, v)]
            -- ── phase 1: replication paths cut, the master still reachable for reads
            for spec in readGuardRules mIp sIp do
              match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ spec.drop 1) with
              | .error e => return .fail e
              | .ok _ => pure ()
            let disc ← waitForCondition "phase 1: the follower is disconnected (repl_sync_wal rejected)" 90 do
              return (← statStr sIp "repl_follow_state") == some "disconnected"
            if !disc then return .fail "phase 1 precondition: the follower did not disconnect"
            for i in [0:5] do
              if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"acc_{i}" s!"p1_{i}") then return .fail s!"master did not take the update of acc_{i}"
              expect := setExp expect s!"acc_{i}" (some s!"p1_{i}")
            for i in [10:13] do
              match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete acc_{i}\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}" with
              | .ok o => if !containsSubstr o "DELETED" then return .fail s!"master did not delete acc_{i}: {o.trim}"
              | .error e => return .fail e
              expect := setExp expect s!"acc_{i}" none
            for i in [0:5] do
              if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"accn_{i}" s!"new_{i}") then return .fail s!"master did not create accn_{i}"
              expect := setExp expect s!"accn_{i}" (some s!"new_{i}")
            let p1Drop ← waitForCondition "phase 1: a forwarded write is counted dropped" 120 do
              return ((← droppedByMasterOpt mIp).map (fun n => decide (n > d0))) == some true
            if !p1Drop then return .fail "phase 1: no dropped forward — the forward path was not cut"
            let some cur1 ← statNat sIp "repl_applied_lsn" | return .fail "phase 1: the replica's applied cursor could not be read"
            let some head1 ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "phase 1: the master's head could not be read"
            if head1 <= cur1 then return .fail s!"phase 1: no backlog (head {head1} <= applied {cur1})"
            let mut bad : List String := []
            for (k, want) in [("acc_0", some "p1_0"), ("acc_4", some "p1_4"), ("acc_10", none), ("accn_0", some "new_0")] do
              let (kind, v, s) ← rawGet sIp k
              IO.eprintln s!"# phase 1 (master reachable, replica lagging: applied {cur1} < head {head1}; replica balance {← balanceOnReplica}): get {k} on the replica -> {kind} {v} [{s}s]"
              match want, kind with
              | some w, "value" => if v != w then bad := bad ++ [s!"{k}: {v} (want the master's {w})"]
              | none, "miss" => pure ()
              | _, _ => bad := bad ++ [s!"{k}: {kind} {v} (want {want.getD "a miss"})"]
            if !bad.isEmpty then return .fail s!"phase 1: a lagging replica's read with the master reachable was not the master's answer: {bad}"
            -- ── phase 2: everything cut (the master unreachable from the replica)
            match ← cut mIp sIp with
            | .error e => return .fail e
            | .ok _ => pure ()
            for i in [5:10] do
              if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"acc_{i}" s!"p2_{i}") then return .fail s!"master did not take the update of acc_{i}"
              expect := setExp expect s!"acc_{i}" (some s!"p2_{i}")
            for i in [13:15] do
              match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete acc_{i}\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}" with
              | .ok o => if !containsSubstr o "DELETED" then return .fail s!"master did not delete acc_{i}: {o.trim}"
              | .error e => return .fail e
              expect := setExp expect s!"acc_{i}" none
            -- an update of a key created in phase 1, and a delete of one
            if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort "accn_1" "p2_new_1") then return .fail "master did not update accn_1"
            expect := setExp expect "accn_1" (some "p2_new_1")
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete accn_2\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}" with
            | .ok o => if !containsSubstr o "DELETED" then return .fail s!"master did not delete accn_2: {o.trim}"
            | .error e => return .fail e
            expect := setExp expect "accn_2" none
            for i in [5:8] do
              if !(← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"accn_{i}" s!"new_{i}") then return .fail s!"master did not create accn_{i}"
              expect := setExp expect s!"accn_{i}" (some s!"new_{i}")
            -- forwarding retries exhausted before the heal (as in "cut"), so
            -- the gap is carried by the WAL path
            let some lastDrops0 ← droppedByMasterOpt mIp | return .fail "phase 2: the master's proxy_write_dropped counters could not be read"
            let mut lastDrops := lastDrops0
            for _ in [0:12] do
              IO.sleep 10000
              let some now ← droppedByMasterOpt mIp | return .fail "phase 2: the master's proxy_write_dropped counters could not be read"
              if now == lastDrops then break
              lastDrops := now
            for (k, stale) in [("acc_5", "base_5"), ("acc_0", "base_0")] do
              let (kind, v, s) ← rawGet sIp k
              IO.eprintln s!"# phase 2 (master unreachable): get {k} on the replica -> {kind} {v} [{s}s]"
              if kind == "value" && v == stale then bad := bad ++ [s!"{k}: the STALE local value {v}"]
              else if kind != "error" then bad := bad ++ [s!"{k}: {kind} {v} (want SERVER_ERROR)"]
            if !bad.isEmpty then return .fail s!"phase 2: a lagging replica with the master unreachable did not answer an explicit error: {bad}"
            -- ── writes STOP here (none issued below). The head is observed only.
            let some mLatest ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "at the stop: the master's head could not be read"
            let some appliedAtHeal ← statNat sIp "repl_applied_lsn" | return .fail "at the heal: the replica's applied cursor could not be read"
            IO.eprintln s!"# writes stopped: master head {mLatest}; replica applied {applied0} -> {cur1} (phase 1) -> {appliedAtHeal} (at the heal); dropped forwards {lastDrops - d0}"
            if appliedAtHeal < applied0 then return .fail "the applied cursor went BACKWARDS under the cut"
            heal mIp sIp
            let caught ← waitForCondition s!"replica applied >= {mLatest}, following, items equal" 300 do
              let o ← observePair mPod mIp sPod sIp
              return FlareOperator.E2E.TraceMatch.caughtUp o && (o.replica.applied.map (fun a => decide (a ≥ mLatest))) == some true &&
                (← statStr sIp "repl_follow_state") == some "following"
            let obs1 ← observePair mPod mIp sPod sIp
            let mNow := (← pair).toOption.map (·.1)
            IO.eprintln s!"# after the heal: caught={caught} state={← statStr sIp "repl_follow_state"} reason={← statStr sIp "repl_follow_last_reason"}; master {mPod}->{mNow}; head at the stop {mLatest}; observation {repr obs1}"
            if !caught then return .fail s!"the replica did not catch up from its cursor (state {← statStr sIp "repl_follow_state"}, reason {← statStr sIp "repl_follow_last_reason"})"
            if mNow != some mPod then return .fail "precondition broken: the master changed (this case is the SAME master and history)"
            let nr1 := FlareOperator.E2E.TraceMatch.judgeNoRebuild "before" "after the heal" obs0 obs1
            if !nr1.isEmpty then return .fail s!"no-rebuild / same-history not shown (before -> after the heal): {nr1}"
            if obs1.master.head != some mLatest then return .fail s!"a write reached the master after the stop ({mLatest} -> {obs1.master.head}): the run is not a stopped-write convergence"
            if (← statStr sIp "repl_follow_last_reason") == some "needs_rebuild" then return .fail "the follower declared needs_rebuild"
            -- every key on the master (a master answers from its own copy)
            for (k, want) in expect do
              let (kind, v, _) ← rawGet mIp k
              match want, kind with
              | some w, "value" => if v != w then bad := bad ++ [s!"master {k}: {v} (want {w})"]
              | none, "miss" => pure ()
              | _, _ => bad := bad ++ [s!"master {k}: {kind} {v} (want {want.getD "absent"})"]
            if !bad.isEmpty then return .fail s!"the master does not hold the expected content: {bad}"
            -- every key on the REPLICA, from its OWN copy (review 2026-10-13
            -- finding 3): a GET on the replica may be proxied to the master,
            -- so a correct answer alone says nothing about the copy. Reads go
            -- to the replica only (readBalance master 0 / slave 100, waited
            -- for in its map entry), on one connection, and each answer must
            -- be attributed to the replica's local copy by the read trace
            -- (TraceMatch.judgeLocalCopy: proxied, refused, untraced or
            -- ambiguous answers fail, an absent key needs a local miss).
            let expectR := expect.map fun (k, w) => (k, match w with | some v => s!"={v}" | none => "miss")
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}"
            let routed ← waitForCondition "the replica's map entry has balance 100" 180 do
              return (← balanceOnReplica) == some 100
            if !routed then return .fail s!"reads could not be routed to the replica (its balance {← balanceOnReplica}): the copy cannot be verified"
            let problems ← localCopyRound sPod sIp "acc_mark_final" expectR
            IO.eprintln s!"# per-key: {expect.length} keys ({(expect.filter (·.2.isNone)).length} deleted): master matches; replica problems {problems.length}: {problems.take 10}"
            if !problems.isEmpty then return .fail s!"the replica's own copy is not verified to match ({problems.length}): {problems.take 5}"
            -- CONTROL: with reads proxied (slave balance 0) the same check
            -- must FAIL although every answer is correct — otherwise it
            -- could not tell a proxied answer from the copy
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}"
            let withheld ← waitForCondition "the replica's map entry has balance 0" 180 do
              return (← balanceOnReplica) == some 0
            if !withheld then return .fail s!"control precondition: the replica's balance did not go to 0 ({← balanceOnReplica})"
            let ctl ← localCopyRound sPod sIp "acc_mark_ctl_proxy" expectR
            let ctlProxied := ctl.length == expect.length && ctl.all (containsSubstr · "NOT from the replica's own copy")
            IO.eprintln s!"# control (reads proxied): problems {ctl.length}/{expect.length}, all 'not from the own copy' = {ctlProxied}: {ctl.take 3}"
            if !ctlProxied then return .fail s!"control: with every read proxied the check did not fail on every key as not-local ({ctl.length}/{expect.length}): {ctl.take 5}"
            -- the observation interval ends AFTER the final local-copy round
            -- (and its control): same process, copy and history throughout,
            -- and still no write reached the master
            let obs2 ← observePair mPod mIp sPod sIp
            IO.eprintln s!"# observation after the final round: {repr obs2}"
            let nr2 := FlareOperator.E2E.TraceMatch.judgeNoRebuild "before" "after the final round" obs0 obs2 ++
              FlareOperator.E2E.TraceMatch.judgeNoRebuild "after the heal" "after the final round" obs1 obs2
            if !nr2.isEmpty then return .fail s!"no-rebuild / same-history not shown through the final round: {nr2}"
            if obs2.master.head != some mLatest then return .fail s!"a write reached the master before the final round ended ({mLatest} -> {obs2.master.head})"
            let empty ← waitForCondition "ledger closes the counted drops by position" 300 do return (← ledgerDests).isEmpty
            if !empty then return .fail s!"the ledger still holds {← ledgerDests} ({← ledgerHolds})"
            return .pass
          finally
            heal mIp sIp
            discard <| setOpt false 0
            let back ← waitForCondition "acceptance cleanup: the replica follows again" 240 do
              return (← statStr sIp "repl_follow_state") == some "following"
            if !back then throw (IO.userError "acceptance cleanup: the replica did not follow again")
    },

    -- T5: repeated disconnections — no loss, no rollback, no resurrection,
    -- and never a rebuild. Three cut/write/heal cycles; after each the
    -- replica converges from its position; sampled keys read locally.
    { name := "repeated cuts: three cut/write/heal cycles converge from the position each time; no rebuild, no pod recreation"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let uid0 := (← podUid sPod).getD "?"
          for cyc in [0:3] do
            match ← cut mIp sIp with
            | .error e => return .fail e
            | .ok () => pure ()
            let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"cyc{cyc}" 10
            -- also overwrite one key from the previous cycle and delete one
            if cyc > 0 then
              discard <| memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"cyc{cyc - 1}_0" s!"rewritten_{cyc}"
              discard <| execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete cyc{cyc - 1}_1\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}"
            let d ← waitForCondition s!"cycle {cyc}: master counts a dropped forwarded write" 90 do
              return (← droppedByMaster mIp) > 0
            let applied := (← statNat sIp "repl_applied_lsn").getD 0
            heal mIp sIp
            let caught ← waitForCondition s!"cycle {cyc}: replica converges while following" 180 do
              return (← statStr sIp "repl_follow_state") == some "following"
                && (← currItems sIp) == (← currItems mIp)
            IO.eprintln s!"# cycle {cyc}: stored {stored}/10, drop counted={d}, replica resumed from {applied} → {(← statNat sIp "repl_applied_lsn").getD 0}; items master={← currItems mIp} replica={← currItems sIp}; converged={caught}"
            if stored != 10 then return .fail s!"cycle {cyc}: stored only {stored}/10"
            if !caught then return .fail s!"cycle {cyc}: replica did not converge (state {← statStr sIp "repl_follow_state"}, items master={← currItems mIp} replica={← currItems sIp})"
          -- Sampled content, read on the replica: a HIT is local. The
          -- rewritten key must carry the last value; the deleted key must
          -- be absent locally (a miss is proxied to the master, where it is
          -- also gone, so END without VALUE is the expected answer).
          let mut bad : List String := []
          for (k, v) in [("cyc0_0", "rewritten_1"), ("cyc1_0", "rewritten_2"), ("cyc2_5", "cyc2_5")] do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {k}\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
            | .ok o => if !(containsSubstr o v) then bad := bad ++ [s!"{k} (want {v}, got {o.trim.take 60})"]
            | .error e => bad := bad ++ [s!"{k}: {e}"]
          for k in ["cyc0_1", "cyc1_1"] do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {k}\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
            | .ok o => if containsSubstr o "VALUE" then bad := bad ++ [s!"{k} resurrected"]
            | .error e => bad := bad ++ [s!"{k}: {e}"]
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          let uid1 := (← podUid sPod).getD "?"
          IO.eprintln s!"# after 3 cycles: content mismatches={bad}; reconstruction_started {recon0}→{recon1}; pod uid {uid0}→{uid1}; wal_applied={← statNat sIp "repl_wal_applied"} forward_applied={← statNat sIp "repl_forward_applied"}"
          if !bad.isEmpty then return .fail s!"replica content wrong: {bad}"
          if recon1 != recon0 then return .fail "a reconstruction ran during the cycles"
          if uid1 != uid0 then return .fail "the replica pod was recreated"
          let empty ← waitForCondition "ledger closes every counted drop by position" 300 do return (← ledgerDests).isEmpty
          if !empty then return .fail s!"the ledger still holds {← ledgerDests} ({← ledgerHolds})"
          return .pass },

    -- T8: the OPERATOR restarts while the link is cut and a drop is held
    -- under the follower's ownership. The persisted ledger must come back
    -- with the owned hold, replication progress must not be disturbed, and
    -- the entry must close by position after the heal — no rebuild.
    { name := "operator restart during a cut: the owned hold survives the restart; the follower catches up; the entry closes; no rebuild"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let uid0 := (← podUid sPod).getD "?"
          let d0 ← droppedByMaster mIp
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "oprestart" 10
          let dropped ← waitForCondition "master counts a dropped forwarded write" 90 do
            return (← droppedByMaster mIp) > d0
          let held ← waitForCondition "operator holds the drop as owned" 120 do
            return containsSubstr (← ledgerHolds) "owned"
          IO.eprintln s!"# before the restart: stored {stored}/10, drop counted={dropped}, ledger holds: {← ledgerHolds}"
          if !dropped || !held then heal mIp sIp; return .fail s!"no owned hold to carry across the restart (dropped={dropped}, holds={← ledgerHolds})"
          let oldPod ← hostCmd "kubectl" ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.name}"]
          discard <| hostCmd "kubectl" ["delete", "pod", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "--wait=false"]
          let back ← waitForCondition "a new operator pod is Ready" 180 do
            match ← hostCmd "kubectl" ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={range .items[*]}{.metadata.name}={.status.containerStatuses[0].ready} {end}"] with
            | .ok o =>
              let old := (oldPod.toOption.getD "").trim
              return (o.splitOn " ").any (fun e => e.endsWith "=true" && !(e.startsWith old))
                && !(o.splitOn " ").any (fun e => e.startsWith old && e != "")
            | .error _ => return false
          IO.eprintln s!"# operator restarted (old pod {oldPod.toOption.getD "?"}); ready={back}; ledger after restart: dests={← ledgerDests} holds={← ledgerHolds}"
          if !back then heal mIp sIp; return .fail "the operator did not come back Ready"
          let stillHeld := containsSubstr (← ledgerHolds) "owned" || containsSubstr (← ledgerHolds) "unknown"
          heal mIp sIp
          if !stillHeld then return .fail s!"the owned hold did not survive the restart (holds: {← ledgerHolds})"
          let caught ← waitForCondition "replica converges while following" 180 do
            return (← statStr sIp "repl_follow_state") == some "following" && (← currItems sIp) == (← currItems mIp)
          let closed ← waitForCondition "the restarted operator closes the entry by position" 400 do
            return (← ledgerDests).isEmpty
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          let uid1 := (← podUid sPod).getD "?"
          IO.eprintln s!"# after the heal: converged={caught}; ledger empty={closed}; reconstruction_started {recon0}→{recon1}; pod uid {uid0}→{uid1}"
          if !caught then return .fail "the replica did not converge after the heal"
          if !closed then return .fail s!"the entry was not closed after the restart (holds: {← ledgerHolds})"
          if recon1 != recon0 then return .fail "a reconstruction ran across the operator restart"
          if uid1 != uid0 then return .fail "the replica pod was recreated"
          return .pass },

    -- Operator restart while the replica's stats cannot be read (handoff
    -- §3). The fresh process has no reading of the replica, so it must not
    -- treat the copy as eligible: reads withheld (Unknown), and no demotion,
    -- promotion or rebuild may come out of the blindness. When stats return,
    -- the replica is served again. The follower itself (flared→flared) does
    -- not depend on the operator and keeps following throughout.
    { name := "operator restart while the replica's stats cannot be read: the fresh operator withholds its reads (Unknown) and demotes, promotes and rebuilds nothing; once stats return the replica is served again"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let balanceOfReplica : IO (Option Nat) := do
            let entries ← nodeView
            return (entries.find? (fun e => (e.fqdn.splitOn ".").head? == some sPod)).map (·.balance)
          let resetSpec : IO Unit := do
            discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}"
          let recon0 := (← statNat sIp "reconstruction_started").getD 0
          let uid0 := (← podUid sPod).getD "?"
          match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":50}}}" with
          | .error e => return .fail s!"patch failed: {e}"
          | .ok _ => pure ()
          let served ← waitForCondition "precondition: following replica gets balance 50" 150 do
            return (← balanceOfReplica) == some 50
          if !served then resetSpec; return .fail s!"precondition: the following replica never received balance 50 (got {← balanceOfReplica})"
          match ← revokeExec mPod with
          | .error e => resetSpec; return .fail s!"could not revoke pods/exec: {e}"
          | .ok (ruleIdx, originalRes) =>
          let oldPod := ((← hostCmd "kubectl" ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.name}"]).toOption.getD "").trim
          discard <| hostCmd "kubectl" ["delete", "pod", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "--wait=false"]
          let back ← waitForCondition "a new operator pod is Ready and the old one is gone" 180 do
            match ← hostCmd "kubectl" ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={range .items[*]}{.metadata.name}={.status.containerStatuses[0].ready} {end}"] with
            | .ok o =>
              return (o.splitOn " ").any (fun e => e.endsWith "=true" && !(e.startsWith oldPod))
                && !(o.splitOn " ").any (fun e => e.startsWith oldPod && e != "")
            | .error _ => return false
          if !back then restoreExec ruleIdx originalRes; resetSpec; return .fail "the operator did not come back Ready"
          -- The fresh process cannot read the replica: its reads must be
          -- withheld, whatever balance the reloaded map carried.
          let withheld ← waitForCondition "the fresh operator withholds the unreadable replica (balance 0)" 150 do
            return (← balanceOfReplica) == some 0
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "blindrestart" 10
          let mLatest := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
          let follows ← waitForCondition "the follower keeps following without the operator" 120 do
            return (← statNat sIp "repl_applied_lsn").getD 0 ≥ mLatest
          let logBlind ← opLog 3000
          let masterNow := (findMasterFqdn (← nodeView) 0).bind (fun f => (f.splitOn ".").head?)
          IO.eprintln s!"# blind fresh operator: replica balance={← balanceOfReplica} withheld={withheld}; stored {stored}/10; follower caught up={follows}; master={masterNow}"
          restoreExec ruleIdx originalRes
          if !withheld then resetSpec; return .fail s!"the fresh operator kept a read balance for a replica it could not read (balance {← balanceOfReplica})"
          if containsSubstr logBlind "REPLICA REPAIR: demoting" then resetSpec; return .fail "the blind operator demoted the replica"
          if masterNow != some mPod then resetSpec; return .fail s!"the master changed while the operator was blind ({masterNow})"
          if !follows then resetSpec; return .fail "the follower stopped following while the operator was blind"
          let restored ← waitForCondition "once stats return the replica is served again (balance 50)" 240 do
            return (← balanceOfReplica) == some 50 && (← statStr sIp "repl_follow_state") == some "following"
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          let uid1 := (← podUid sPod).getD "?"
          IO.eprintln s!"# after restoring pods/exec: balance={← balanceOfReplica} restored={restored}; reconstruction_started {recon0}→{recon1}; pod uid {uid0}→{uid1}"
          resetSpec
          if !restored then return .fail "the replica was not served again after its stats became readable"
          if recon1 != recon0 then return .fail "a reconstruction ran because of the blindness"
          if uid1 != uid0 then return .fail "the replica pod was recreated"
          let zero ← waitForCondition "spec restored to slave=0" 120 do return (← balanceOfReplica) == some 0
          if !zero then return .fail "balance did not return to 0 after restoring the spec"
          return .pass },

    -- T4/T16: the REPLICA PROCESS CRASHES (kill -9 from the node) right after
    -- a heal, with a backlog of created/updated/deleted keys pending. Its
    -- data is on a PVC, so the container restarts on the same copy. It must
    -- converge to the master's content with no duplicate, no missing and no
    -- resurrected key, without a full dump, and without the pod being
    -- recreated. (The restart goes through the operator's rejoin: the node
    -- re-registers, is seated Slave/Prepare, reconstructs INCREMENTALLY from
    -- its cursor over the WAL, activates, and the follower resumes — not a
    -- bare in-process resume; recorded as such.)
    { name := "replica crash with a backlog pending: flared killed -9 after the heal; restarts on its PVC, converges without a full dump; pod not recreated"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let uid0 := (← podUid sPod).getD "?"
          let rc0 ← restartCountOf sPod
          let applied0 := (← statNat sIp "repl_applied_lsn").getD 0
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "crash" 300
          let mut updated := 0
          for i in [0:5] do
            if ← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"crash_{i}" s!"crash_updated_{i}" then updated := updated + 1
          let mut deleted := 0
          for i in [10:15] do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'delete crash_{i}\\r\\n' | nc -w 3 {mIp} {cfg.flarePort}" with
            | .ok o => if containsSubstr o "DELETED" then deleted := deleted + 1
            | .error _ => pure ()
          let mLatest := (← statNat mIp "rocksdb_latest_sequence_number").getD 0
          heal mIp sIp
          IO.sleep 300
          let killed ← killFlared uid0
          IO.eprintln s!"# backlog: stored {stored}/300, updated {updated}/5, deleted {deleted}/5 under the cut (master latest {mLatest}, replica applied {applied0}); healed; {killed.toOption.getD "kill failed"}"
          match killed with
          | .error e => return .fail s!"could not kill flared on the replica: {e}"
          | .ok o => if !(containsSubstr o "killed=1") then return .fail s!"expected exactly one flared process for the replica's pod UID: {o.trim}"
          let restarted ← waitForCondition "replica container restarted (restartCount +1) and Ready" 240 do
            return (← restartCountOf sPod) == rc0 + 1
              && (match ← kubectlGetJsonpath "pod" sPod cfg.«namespace» "{.status.containerStatuses[0].ready}" with
                  | .ok o => o.trim == "true" | .error _ => false)
          IO.eprintln s!"# after the kill: restartCount {rc0}→{← restartCountOf sPod}; ready-again={restarted}; pod uid {uid0}→{(← podUid sPod).getD "?"}"
          if !restarted then return .fail "the replica container did not come back Ready once"
          let caught ← waitForCondition "replica follows again and matches the master's items" 420 do
            return (← statStr sIp "repl_follow_state") == some "following" && (← currItems sIp) == (← currItems mIp)
          let dump := (← statNat sIp "rocksdb_wal_fallback_to_dump").getD 0
          let recon := (← statNat sIp "reconstruction_completed").getD 0
          IO.eprintln s!"# after the restart: state={← statStr sIp "repl_follow_state"} applied={← statNat sIp "repl_applied_lsn"} (master latest {← statNat mIp "rocksdb_latest_sequence_number"}); items master={← currItems mIp} replica={← currItems sIp}; new process: reconstruction_completed={recon} wal_fallback_to_dump={dump} wal_applied={← statNat sIp "repl_wal_applied"}"
          if !caught then
            -- Diagnostics: which sampled keys are missing on the replica (a
            -- key is checked by a local HIT), the crashed container's last
            -- lines and the restarted process's replication lines.
            let mut missing : List String := []
            for i in [0:300:10] do
              match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get crash_{i}\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
              | .ok o => if !(containsSubstr o "VALUE") then missing := missing ++ [s!"crash_{i}"]
              | .error _ => missing := missing ++ [s!"crash_{i}?"]
            IO.eprintln s!"# sampled keys missing on the replica (every 10th of 300): {missing}"
            match ← hostCmd "sh" ["-c", s!"kubectl logs -n {cfg.«namespace»} {sPod} --previous 2>/dev/null | tail -12"] with
            | .ok o => IO.eprintln s!"# --- crashed container, last lines ---\n{o}"
            | .error e => IO.eprintln s!"# (no previous log: {e})"
            match ← hostCmd "sh" ["-c", s!"kubectl logs -n {cfg.«namespace»} {sPod} | grep -iE 'curr_items seeded|recover|reconstruct|snapshot|truncate|follow|WAL' | grep -vE '_reconstruct_node_partition|reconstructing node map' | head -40"] with
            | .ok o => IO.eprintln s!"# --- restarted replica (filtered) ---\n{o}"
            | .error e => IO.eprintln s!"# (could not read the replica's log: {e})"
            return .fail s!"the replica did not converge after the crash (state {← statStr sIp "repl_follow_state"}, reason {← statStr sIp "repl_follow_last_reason"}, items master={← currItems mIp} replica={← currItems sIp})"
          if dump > 0 then return .fail "the restart fell back to a FULL DUMP: the crashed copy was not resumed from its position"
          let mut bad : List String := []
          for (k, v) in [("crash_0", "crash_updated_0"), ("crash_4", "crash_updated_4"), ("crash_299", "crash_299"), ("crash_150", "crash_150")] do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {k}\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
            | .ok o => if !(containsSubstr o v) then bad := bad ++ [s!"{k} (want {v}, got {o.trim.take 60})"]
            | .error e => bad := bad ++ [s!"{k}: {e}"]
          for k in ["crash_10", "crash_14"] do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {k}\\r\\n' | nc -w 3 {sIp} {cfg.flarePort}" with
            | .ok o => if containsSubstr o "VALUE" then bad := bad ++ [s!"{k} resurrected"]
            | .error e => bad := bad ++ [s!"{k}: {e}"]
          if !bad.isEmpty then return .fail s!"replica content wrong after the crash: {bad}"
          if (← podUid sPod).getD "?" != uid0 then return .fail "the replica pod was recreated"
          let empty ← waitForCondition "ledger closes the drops counted under the cut" 300 do return (← ledgerDests).isEmpty
          if !empty then return .fail s!"the ledger still holds {← ledgerDests} ({← ledgerHolds})"
          return .pass },

    -- SAF-10c planned promotion + T16 (history replacement): the master's
    -- pod is deleted and stays Terminating for the preStop window, so the
    -- operator DRAINS it: the follower is promoted only if the eligibility
    -- gate proves it current (following, same epoch, fresh, within the
    -- promotion bound) — an unproven follower would leave the master kept
    -- with a CRITICAL "no promotable successor". Promotion advances the
    -- source epoch; the returning ex-master (PVC, old history) must rebuild
    -- and FOLLOW the new master's epoch. Changes the partition's master.
    { name := "planned promotion: the master pod is deleted (graceful drain); the proven follower is promoted through the gate, its epoch advances; the returning ex-master rebuilds and follows the new epoch"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, _, sPod, sIp) =>
          let uid0 := (← podUid sPod).getD "?"
          let epoch0 := (← statStr sIp "repl_follow_source_epoch").getD "?"
          -- Async delete: the pod is Terminating for drainSeconds while the
          -- operator drains it.
          -- The operator skips BOTH graceful drain and dead detection during
          -- its 120 s startup grace period, and the operator-restart test two
          -- tests earlier leaves a freshly started operator behind. On CI
          -- (run 36748059941) the master was deleted ~2 min after that
          -- restart: no drain, no failover, the StatefulSet recreated the
          -- master and it re-registered as master — "not promoted". Wait
          -- until the operator is past its grace period first.
          let jp := "{.items[0].status.startTime}"
          let opAge : IO (Option Nat) := do
            match ← hostCmd "sh" ["-c", s!"st=$(kubectl get pod -n {cfg.«namespace»} -l app={cfg.operatorName} -o jsonpath='{jp}'); now=$(date +%s); t=$(date -d \"$st\" +%s 2>/dev/null || date -j -f %Y-%m-%dT%H:%M:%SZ \"$st\" +%s); echo $((now - t))"] with
            | .ok o => return o.trim.toNat?
            | .error _ => return none
          -- The grace period is 24 reconcile CYCLES, not 120 s: each cycle is
          -- the 5 s interval plus the pass itself, and passes here take 2-3 s
          -- (stats probes), so 24 cycles last ~190 s. The earlier wait for a
          -- 150 s-old pod still deleted the master inside the grace: no drain
          -- line on any CI run, and the follower was promoted ~35 s later by
          -- dead-node failover once grace ended (EV-04 caveat). Wait for the
          -- operator's own end-of-grace line instead, then one more cycle. (The
          -- grace is wall-clock since 2026-10-02; the line is still the signal.)
          let pastGrace ← waitForCondition "operator logged the end of its startup grace period" 360 do
            return containsSubstr (← opLog 200000) "grace period over after"
          if pastGrace then IO.sleep 10000
          IO.eprintln s!"# operator pod age before the delete: {← opAge}s (grace ended per its log={pastGrace})"
          if !pastGrace then
            return .fail "precondition: the operator never logged the end of its startup grace period within 360 s; a delete now would skip the drain"
          discard <| kubectl ["delete", "pod", mPod, "-n", cfg.«namespace», "--wait=false"]
          IO.eprintln s!"# deleted master pod {mPod} (graceful, preStop {cfg.drainSeconds}s); follower {sPod} was following epoch {epoch0}"
          let promoted ← waitForCondition "the follower is promoted to master (drain)" 180 do
            let entries ← nodeView
            return (findMasterFqdn entries 0).bind (fun f => (f.splitOn ".").head?) == some sPod
          let log ← opLog 3000
          let drained := containsSubstr log "graceful drain"
          let blocked := containsSubstr log "NO promotable successor"
          let notLossFree := containsSubstr log "PROMOTION NOT LOSS-FREE" && containsSubstr log sPod
          IO.eprintln s!"# promotion: follower promoted={promoted}; drain logged={drained}; drain blocked (guard refused)={blocked}; NOT LOSS-FREE logged={notLossFree}; new master epoch={← statStr sIp "rocksdb_source_epoch"}"
          if !promoted then return .fail s!"the follower was not promoted (drain logged={drained}, guard refused={blocked})"
          if notLossFree then return .fail "a PLANNED promotion went through as not loss-free: the eligibility gate did not prove the follower"
          -- The promotion must come from the drain path (inside the preStop
          -- window), not from dead-node failover after the pod is gone; that
          -- is what makes it PLANNED. Before the grace wait above was fixed,
          -- every CI run promoted by failover and this was only a caveat.
          if !drained then return .fail "the follower was promoted, but not by the graceful drain (no drain line): this was dead-node failover after the pod was gone"
          -- The drain must also SUCCEED: a refused drain keeps the master
          -- until its grace expires and failover then promotes the follower,
          -- which is not a planned promotion (CI 36841064685: the master's
          -- head was not read while it was Terminating, so the follower was
          -- never proven current and every drain was refused).
          if blocked then return .fail "the drain guard refused the proven follower (NO promotable successor); the promotion came from failover after the grace, not from the drain"
          if (← podUid sPod).getD "?" != uid0 then return .fail "the promoted pod was recreated"
          -- flared applies the promotion on its next accepted map; the epoch
          -- advances inside that role shift.
          let advanced ← waitForCondition "the promoted node advances its source epoch" 120 do
            return ((← statStr sIp "rocksdb_source_epoch").getD "?") != epoch0
          let epoch1 := (← statStr sIp "rocksdb_source_epoch").getD "?"
          if !advanced then return .fail s!"promotion did not advance the source epoch (still {epoch1})"
          let rejoined ← waitForCondition "ex-master returns, rebuilds and follows the new epoch" 480 do
            match ← getPodIp mPod cfg.«namespace» with
            | none => return false
            | some ip =>
              return (← statStr ip "repl_follow_state") == some "following"
                && (← statStr ip "repl_follow_source_epoch") == some epoch1
          let mIp2 := (← getPodIp mPod cfg.«namespace»).getD "?"
          IO.eprintln s!"# ex-master {mPod}: state={← statStr mIp2 "repl_follow_state"} epoch={← statStr mIp2 "repl_follow_source_epoch"} (new master {epoch1}); items new-master={← currItems sIp} ex-master={← currItems mIp2}"
          if !rejoined then return .fail "the ex-master did not come back following the new master's epoch"
          let stored ← writeKeys cfg.debugPod cfg.«namespace» sIp cfg.flarePort "post_failover" 10
          if stored != 10 then
            -- CI 37770467697: 0/10 and the new master stopped confirming maps.
            -- Record the raw reply, its own state and each flared thread's
            -- kernel wait (a lock wait shows as futex)
            let raw := match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'set post_failover_probe 0 0 1\\r\\nx\\r\\n' | nc -w 5 {sIp} {cfg.flarePort}" with
              | .ok o => o.trim
              | .error e => s!"(error: {e})"
            let st := fun (k : String) => do return (← statStr sIp k).getD "?"
            IO.eprintln s!"# new master {sPod} after {stored}/10: raw set reply [{raw}]; node_map_version {← st "node_map_version"}; rocksdb_source_epoch {← st "rocksdb_source_epoch"}; promotion_refused {← st "promotion_refused"}; repl_follow_state {← st "repl_follow_state"}; reconstruction_current_state {← st "reconstruction_current_state"}"
            let threads := match ← kubectl ["exec", "-n", cfg.«namespace», sPod, "-c", "flared", "--", "sh", "-c",
                "for t in /proc/1/task/*; do echo \"$(basename $t) $(cat $t/comm) $(awk '{print $3}' $t/stat) $(cat $t/wchan 2>/dev/null)\"; done"] with
              | .ok o => o
              | .error e => s!"(error: {e})"
            IO.eprintln s!"# {sPod} flared threads (tid comm state wchan):\n{threads}"
            return .fail s!"stored only {stored}/10 on the new master"
          let caught ← waitForCondition "new writes reach the ex-master as a follower" 90 do
            return (← currItems mIp2) == (← currItems sIp)
          if !caught then return .fail s!"items new-master={← currItems sIp} ex-master={← currItems mIp2}"
          return .pass },

    -- T1: a NEW replica joins (replicas 2 → 3) while writes continue on the
    -- master. Its initial copy is snapshot + WAL; after the hand-off it must
    -- be following the master's epoch and hold exactly the master's items.
    { name := "initial copy under load: a third replica joins by snapshot while writes flow, then follows and matches"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, _) =>
          let newPod := s!"{cfg.name}-nodes-2"
          match ← kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"replicas\":3}}" with
          | .error e => return .fail s!"patch failed: {e}"
          | .ok _ => pure ()
          match ← kubectlScale "statefulset" s!"{cfg.name}-nodes" cfg.«namespace» 3 with
          | .error e => return .fail s!"scale failed: {e}"
          | .ok _ => pure ()
          -- Write continuously until the newcomer reports following (or the
          -- budget runs out), so the copy is taken under load.
          let mut batches := 0
          -- only ACKNOWLEDGED writes count (CI 37770467697: the master
          -- acknowledged none, its items stayed 356, and the test still
          -- sampled an unacknowledged key as "missing")
          let mut acked := 0
          let mut lastAcked : Option String := none
          let mut newIp : Option String := none
          for i in [0:90] do
            for j in List.range 20 do
              let key := s!"t1_{i}_{j}"
              if ← memcachedSet cfg.debugPod cfg.«namespace» mIp cfg.flarePort key s!"val_{j}" then
                acked := acked + 1
                lastAcked := some key
            batches := batches + 1
            match ← getPodIp newPod cfg.«namespace» with
            | none => pure ()
            | some ip =>
              newIp := some ip
              if (← statStr ip "repl_follow_state") == some "following" then break
          let some nIp := newIp | return .fail s!"{newPod} never got an IP"
          let following ← waitForCondition "newcomer follows" 300 do
            return (← statStr nIp "repl_follow_state") == some "following"
          -- Writes stopped; the newcomer must reach the master's item count
          -- and epoch by itself.
          let caught ← waitForCondition "newcomer's local items match the master's" 180 do
            return (← currItems nIp) == (← currItems mIp) && (← currItems mIp) > 0
          let mEpoch ← statStr mIp "rocksdb_source_epoch"
          let nEpoch ← statStr nIp "repl_follow_source_epoch"
          IO.eprintln s!"# newcomer {newPod}: {batches} batches of 20 attempted during its copy, {acked} acknowledged by the master (last {lastAcked}); state={← statStr nIp "repl_follow_state"} epoch={nEpoch} (master {mEpoch}); items master={← currItems mIp} newcomer={← currItems nIp}; reconstruction_completed={← statNat nIp "reconstruction_completed"} wal_applied={← statNat nIp "repl_wal_applied"}"
          if !following then return .fail s!"the newcomer never followed (state {← statStr nIp "repl_follow_state"}, reason {← statStr nIp "repl_follow_last_reason"})"
          if !caught then return .fail s!"items master={← currItems mIp} newcomer={← currItems nIp}"
          if nEpoch != mEpoch then return .fail s!"newcomer follows epoch {nEpoch}, master is at {mEpoch}"
          -- Sampled content: the LAST key the master ACKNOWLEDGED during the copy
          let some lastKey := lastAcked
            | return .fail s!"PRECONDITION NOT MET: the master acknowledged none of the {batches * 20} writes during the copy (no write to check on the newcomer)"
          match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get {lastKey}\\r\\n' | nc -w 3 {nIp} {cfg.flarePort}" with
          | .ok o => if !(containsSubstr o "VALUE") then return .fail s!"the last ACKNOWLEDGED key written during the copy ({lastKey}) is missing on the newcomer: {o.trim.take 80}"
          | .error e => return .fail e
          return .pass }
  ]
}

end FlareOperator.E2E.Tests.ContinuousReplication
