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

namespace FlareOperator.E2E.Tests.ContinuousReplication

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

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

private def droppedByMaster (ip : String) : IO Nat := do
  match ← statsOf ip with
  | none => return 0
  | some o =>
    let mut total := 0
    for line in o.splitOn "\n" do
      let t := (line.trim.replace "\r" "")
      if t.startsWith "STAT proxy_write_dropped[" then
        match (t.splitOn " ").getLast? >>= (·.trim.toNat?) with
        | some n => total := total + n
        | none => pure ()
    return total

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

private def heal (masterIp slaveIp : String) : IO Unit := do
  for spec in [ruleSpec masterIp slaveIp, ruleSpecBack masterIp slaveIp] do
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
          return .pass },

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
          let requested ← waitForCondition "operator requests the rebuild from the follower's declaration" 120 do
            let log ← opLog 4000
            let byLog := containsSubstr log "REPLICA REPAIR requested by the follower" && containsSubstr log sPod
            let byEntry ← do
              match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{range .status.replicaRepairs.entries[*]}{.dest}={.drops}/{.phase} {end}" with
              | .ok out =>
                let mine := (out.trim.splitOn " ").filter (fun e => e.startsWith sPod)
                pure (mine.any (fun e => (e.splitOn "=").getLast? |>.map (·.startsWith "0/") |>.getD false), String.intercalate " " mine)
              | .error _ => pure (false, "")
            if byEntry.2 != "" then seenEntry.set byEntry.2
            return byLog || byEntry.1
          IO.eprintln s!"# request evidence: ledger entry seen={← seenEntry.get}"
          if !declared && !requested then return .fail "the follower never declared needs_rebuild and no request was made"
          let rebuilt ← waitForCondition "follower reconstructed and follows the new epoch" 420 do
            let recon := (← statNat sIp "reconstruction_started").getD 0
            return recon > recon0 && (← statStr sIp "repl_follow_state") == some "following"
              && (← statStr sIp "repl_follow_source_epoch") == some epoch1
          let recon1 := (← statNat sIp "reconstruction_started").getD 0
          IO.eprintln s!"# after the rebuild: reconstruction_started {recon0}→{recon1}; state={← statStr sIp "repl_follow_state"} epoch={← statStr sIp "repl_follow_source_epoch"} (master {epoch1}); requested-by-follower logged={requested}"
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
          if !requested then return .fail "the rebuild happened but not through the follower-declared ledger request"
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
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let withheld ← waitForCondition "cut replica is withheld from reads (balance 0)" 150 do
            return (← balanceOfReplica) == some 0
          let logged := containsSubstr (← opLog 1500) "eligibility"
          IO.eprintln s!"# under the cut: replica balance={← balanceOfReplica} state={← statStr sIp "repl_follow_state"} eligibility-logged={logged}"
          heal mIp sIp
          if !withheld then return .fail "the disconnected replica kept its read balance"
          let restored ← waitForCondition "healed replica is served again (balance 50)" 240 do
            return (← balanceOfReplica) == some 50 && (← statStr sIp "repl_follow_state") == some "following"
          IO.eprintln s!"# after the heal: replica balance={← balanceOfReplica} state={← statStr sIp "repl_follow_state"}"
          discard <| kubectlPatch "flarecluster" cfg.name cfg.«namespace» "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}"
          if !restored then return .fail "the healed, following replica was not restored to balance 50"
          let back ← waitForCondition "spec restored to slave=0" 120 do return (← balanceOfReplica) == some 0
          if !back then return .fail "balance did not return to 0 after restoring the spec"
          return .pass },

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

    -- SAF-10c promotion + T16 (history replacement): the master's pod is
    -- deleted. The follower is the only candidate; whether it was proven
    -- current on the tick the master vanished (ranked) or not (unproven,
    -- logged NOT LOSS-FREE), it is promoted; promotion advances the source
    -- epoch, and the returning ex-master must rebuild and then FOLLOW the
    -- new master's epoch. Last test: it changes the partition's master.
    { name := "failover: the master pod is deleted; the follower is promoted (evidence logged); the returning ex-master rebuilds and follows the new epoch"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (mPod, _, sPod, sIp) =>
          let uid0 := (← podUid sPod).getD "?"
          let epoch0 := (← statStr sIp "repl_follow_source_epoch").getD "?"
          kubectlDelete "pod" mPod cfg.«namespace»
          IO.eprintln s!"# deleted master pod {mPod}; follower {sPod} was following epoch {epoch0}"
          let promoted ← waitForCondition "the follower is promoted to master" 300 do
            let entries ← nodeView
            return (findMasterFqdn entries 0).bind (fun f => (f.splitOn ".").head?) == some sPod
          let log ← opLog 3000
          let notLossFree := containsSubstr log "PROMOTION NOT LOSS-FREE" && containsSubstr log sPod
          IO.eprintln s!"# promotion: follower promoted={promoted}; logged NOT LOSS-FREE={notLossFree}; new master epoch={← statStr sIp "rocksdb_source_epoch"}"
          if !promoted then return .fail "the follower was not promoted"
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
          if stored != 10 then return .fail s!"stored only {stored}/10 on the new master"
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
          let mut newIp : Option String := none
          for i in [0:90] do
            let _ ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort s!"t1_{i}" 20
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
          IO.eprintln s!"# newcomer {newPod}: {batches} batches of 20 written during its copy; state={← statStr nIp "repl_follow_state"} epoch={nEpoch} (master {mEpoch}); items master={← currItems mIp} newcomer={← currItems nIp}; reconstruction_completed={← statNat nIp "reconstruction_completed"} wal_applied={← statNat nIp "repl_wal_applied"}"
          if !following then return .fail s!"the newcomer never followed (state {← statStr nIp "repl_follow_state"}, reason {← statStr nIp "repl_follow_last_reason"})"
          if !caught then return .fail s!"items master={← currItems mIp} newcomer={← currItems nIp}"
          if nEpoch != mEpoch then return .fail s!"newcomer follows epoch {nEpoch}, master is at {mEpoch}"
          -- Sampled content from the LAST batch written (during the copy).
          let last := batches - 1
          match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'get t1_{last}_19\\r\\n' | nc -w 3 {nIp} {cfg.flarePort}" with
          | .ok o => if !(containsSubstr o "VALUE") then return .fail s!"the last key written during the copy is missing on the newcomer: {o.trim.take 80}"
          | .error e => return .fail e
          return .pass }
  ]
}

end FlareOperator.E2E.Tests.ContinuousReplication
