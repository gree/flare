/-
  The destination-master restart, on a destination seeded by the per-key
  (merge) dump — the isolated fixture for the SERVER_ERROR resend (5345666).

  cluster-replication-faults restarts a destination seeded by SNAPSHOT PUSH;
  that destination keeps the source's history identity and its operator
  holds the partition masterless on restart (review-cross-cluster §7.6 —
  an open finding, decision pending). That test stays as it is and keeps
  failing until the decision is made; this suite does NOT replace it.

  Here the destination is pre-filled with more items than the snapshot
  push's fresh-target threshold (4096), so the receiver declines the push
  ("not_fresh") and the seed falls back to the merge dump: the destination
  keeps ITS OWN history, and its master can come back after a restart.
  What this isolates: while the restarted destination master has no role
  yet it answers SERVER_ERROR ("no partition available"); 50f65f1 logged
  that 1 in 100 and lost the write (silent loss, E2E 38120285667). 5345666
  resends it within a 120 s window.

  The destination's operator is held (scaled to 0) from before the delete
  until 45 s after it, so the restarted flared listens without a role.

  Three verdicts, separate tests:
    1. arrived or counted (every acknowledged change on the destination, or
       the drop counter moved by at least that many);
    2. the order was reached: the source logged SERVER_ERROR answers that
       it resent (`cluster_replication[forward_server_error_retried]` > 0)
       — if the destination came back without ever answering SERVER_ERROR
       the resend was not exercised, and this says so as a failure;
    3. final per-key match (a counted drop is not a match).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ClusterReplicationRestartDump

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfgSrc : ClusterConfig := {
  name := "crk-src"
  «namespace» := "flare-crk-src"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crk-src"
  debugPod := "debug-crk"
  storageBackend := "rocksdb"
}

private def cfgDst : ClusterConfig := {
  name := "crk-dst"
  «namespace» := "flare-crk-dst"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crk-dst"
  debugPod := "debug-crk"
  storageBackend := "rocksdb"
  usePvc := true
}

private def dstSvc : String := s!"{cfgDst.name}-nodes.{cfgDst.«namespace»}.svc.cluster.local"

/-- More than op_repl_snapshot_push::fresh_destination_threshold (4096). -/
private def fillKeys : Nat := 4300

private def masterIp (cfg : ClusterConfig) : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  match findMasterPod (parseNodeSync sync) 0 with
  | none => return none
  | some m => getPodIp m cfg.«namespace»

/-- `STAT <name> <value>` lines of a node's `stats`, without the prefix. -/
private def statLines (cfg : ClusterConfig) (ip : String) : IO (Option (List String)) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    return some <| (out.splitOn "\n").filterMap fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith "STAT " then some (t.drop 5) else none

private def statOf (cfg : ClusterConfig) (ip name : String) : IO (Option String) := do
  match ← statLines cfg ip with
  | none => return none
  | some ls => return ls.findSome? fun t =>
      if t.startsWith s!"{name} " then some (t.drop (name.length + 1)).trim else none

private def statNat (cfg : ClusterConfig) (ip name : String) : IO Nat :=
  return ((← statOf cfg ip name).bind (·.toNat?)).getD 0

private def creplSummary (ip : String) : IO String := do
  match ← statLines cfgSrc ip with
  | none => return "(unreadable)"
  | some ls => return ", ".intercalate (ls.filter fun t =>
      t.startsWith "cluster_replication" || t.startsWith "proxy_write_dropped")

private def readKey (cfg : ClusterConfig) (ip key : String) : IO (Option (Option String)) := do
  let cmd := s!"printf 'get {key}\\r\\n' | nc -w 3 {ip} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    let lines := out.splitOn "\n" |>.map (fun l => l.trim.replace "\r" "") |>.filter (· != "")
    if lines.any (fun l => l.startsWith "SERVER_ERROR" || l.startsWith "CLIENT_ERROR" || l.startsWith "ERROR") then
      return none
    match lines with
    | [] => return none
    | ["END"] => return some none
    | first :: dataLine :: _ =>
      if first.startsWith "VALUE " then return some (some dataLine) else return none
    | _ => return none

private def setSrc (ip k v : String) : IO Bool :=
  memcachedSet cfgSrc.debugPod cfgSrc.«namespace» ip cfgSrc.flarePort k v

private def deleteKey (ip key : String) : IO Bool := do
  let cmd := s!"printf 'delete {key}\\r\\n' | nc -w 3 {ip} {cfgSrc.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .ok out => return containsSubstr out "DELETED"
  | .error _ => return false

/-- Keys whose value (or absence) differs; an unreadable side is a difference. -/
private def divergent (sIp dIp : String) (keys : List String) : IO (List String) := do
  let mut out : List String := []
  for k in keys do
    let mut same := false
    for _ in [0:2] do
      let sv ← readKey cfgSrc sIp k
      let dv ← readKey cfgDst dIp k
      if sv.isSome && sv == dv then
        same := true
        break
    if !same then out := out ++ [k]
  return out

private def describeKey (sIp dIp k : String) : IO String := do
  let sv ← readKey cfgSrc sIp k
  let dv ← readKey cfgDst dIp k
  let fmt := fun (v : Option (Option String)) => match v with
    | none => "unreadable" | some none => "absent" | some (some x) => s!"'{x}'"
  return s!"{k}: source {fmt sv}, destination {fmt dv}"

/-- Fill the destination with `fillKeys` unrelated keys; STORED count. -/
private def fillDestination (dIp : String) : IO Nat := do
  let cmd := s!"(awk 'BEGIN\{for(i=0;i<{fillKeys};i++) printf \"set fill_%d 0 0 1\\r\\nx\\r\\n\", i}'; sleep 3) | nc -w 120 {dIp} {cfgDst.flarePort} | grep -c STORED"
  match ← execInDebugPod cfgDst.debugPod cfgDst.«namespace» cmd with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

structure RestartOutcome where
  tracked : Nat
  divergent : List String
  details : List String
  droppedDelta : Nat
  serverErrorRetried : Nat
  deriving Inhabited

initialize outcomeRef : IO.Ref (Option RestartOutcome) ← IO.mkRef none

def suite : TestSuite := {
  name := "cluster-replication-restart-dump"
  setup := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
    deployCluster cfgSrc
    let s1 ← waitForStable cfgSrc 50
    if !s1 then throw (IO.userError "source cluster did not stabilize")
    deploySecondCluster cfgDst
    let s2 ← waitForStable cfgDst 50
    if !s2 then throw (IO.userError "destination cluster did not stabilize")
  onFailure := do
    dumpClusterDiagnostics cfgSrc.«namespace» s!"app={cfgSrc.operatorName}"
    dumpClusterDiagnostics cfgDst.«namespace» s!"app={cfgDst.operatorName}"
  teardown := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
  tests := [
    { name := "per-key-seeded destination (snapshot push declined: not fresh) restarts while writes continue: every acknowledged change is on the destination or counted, and forwarding resumes after it returns"
      run := do
        outcomeRef.set none
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let some dIp0 ← masterIp cfgDst | return .fail "no destination master"
        let filled ← fillDestination dIp0
        let items0 ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp0 cfgDst.flarePort
        if items0 ≤ 4096 then
          return .fail s!"precondition: the destination holds {items0} items after the fill (STORED {filled}) — not above the snapshot push threshold, the per-key seed would not be forced"
        let preN := 10
        for i in List.range preN do
          if !(← setSrc sIp s!"rst_pre_{i}" s!"p{i}") then
            return .fail s!"precondition: the source did not acknowledge rst_pre_{i}"
        let preKeys := (List.range preN).map (s!"rst_pre_{·}")
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{dstSvc}\",\"port\":{cfgDst.flarePort},\"mode\":\"duplicate\",\"concurrency\":1}}}"
        match ← kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» patchJson with
        | .error e => return .fail s!"could not enable replication: {e}"
        | .ok _ => pure ()
        let mut seed : Option String := none
        for _ in [0:100] do
          seed ← statOf cfgSrc sIp "cluster_replication_seed"
          if let some st := seed then
            if st.startsWith "completed" || st.startsWith "failed" || st == "interrupted" then break
          IO.sleep 3000
        IO.eprintln s!"# seed state {seed}; destination snapshot_bootstrap {← statOf cfgDst dIp0 "rocksdb_snapshot_bootstrap"}"
        if seed != some "completed_dump" then
          return .fail s!"precondition: the seed did not complete by per-key dump (state {seed}) — the fixture did not isolate the merge-dump path"
        let flowing ← waitForCondition "the seeded keys are on the destination" 120 do
          return (← divergent sIp dIp0 preKeys).isEmpty
        if !flowing then return .fail "precondition: the per-key seed did not deliver the pre-restart keys"
        let sync ← operatorTcpCmd cfgDst.debugPod cfgDst.«namespace» cfgDst.operatorName cfgDst.operatorPort "node sync"
        let some dPod := findMasterPod (parseNodeSync sync) 0 | return .fail "no destination master pod"
        let itemsBefore ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp0 cfgDst.flarePort
        let d0 ← statNat cfgSrc sIp "proxy_write_dropped"
        let r0 ← statNat cfgSrc sIp "cluster_replication[forward_server_error_retried]"
        -- Hold the destination's operator while its master restarts: the
        -- restarted flared then listens WITHOUT a role (no node map) and
        -- answers forwards SERVER_ERROR "no partition available" until the
        -- operator is back — the window the resend must ride out. Run
        -- 38140445297 without the hold: the destination was back in 22 s and
        -- never answered SERVER_ERROR (resend not exercised).
        match ← kubectl ["scale", "deployment", cfgDst.operatorName, "-n", cfgDst.«namespace», "--replicas=0"] with
        | .error e => return .fail s!"could not hold the destination operator: {e}"
        | .ok _ => pure ()
        let _ ← waitForCondition "the destination operator is down" 90 do
          match ← kubectl ["get", "pods", "-n", cfgDst.«namespace», "-l", s!"app={cfgDst.operatorName}", "-o", "name"] with
          | .ok o => return o.trim.isEmpty
          | .error _ => return false
        match ← kubectl ["delete", "pod", dPod, "-n", cfgDst.«namespace», "--grace-period=0", "--force", "--wait=false"] with
        | .error e =>
          discard <| kubectl ["scale", "deployment", cfgDst.operatorName, "-n", cfgDst.«namespace», "--replicas=1"]
          return .fail s!"could not delete {dPod}: {e}"
        | .ok _ => pure ()
        let t0 ← IO.monoMsNow
        let mut newKeys : List String := []
        let mut unacked : List String := []
        for j in List.range 15 do
          let k := s!"rst_new_{j}"
          newKeys := newKeys ++ [k]
          if !(← setSrc sIp k s!"n{j}") then unacked := unacked ++ [k]
          if j < 5 then
            if !(← deleteKey sIp s!"rst_pre_{j}") then unacked := unacked ++ [s!"delete rst_pre_{j}"]
          else if j < 10 then
            if !(← setSrc sIp s!"rst_pre_{j}" s!"u{j}") then unacked := unacked ++ [s!"rst_pre_{j}"]
          IO.sleep 1000
        -- release the operator 45 s after the delete (well inside the 120 s
        -- resend window, after the restarted flared is listening)
        let held := ((← IO.monoMsNow) - t0) / 1000
        if held < 45 then IO.sleep ((45 - held) * 1000).toUInt32
        let dpLog ← kubectlLogs dPod cfgDst.«namespace» 400
        let roleless := (dpLog.splitOn "\n").filter fun l => containsSubstr l "no partition" || containsSubstr l "SERVER_ERROR"
        IO.eprintln s!"# held the destination operator {((← IO.monoMsNow) - t0) / 1000} s; restarted flared lines about no partition: {roleless.length}"
        match ← kubectl ["scale", "deployment", cfgDst.operatorName, "-n", cfgDst.«namespace», "--replicas=1"] with
        | .error e => return .fail s!"could not release the destination operator: {e}"
        | .ok _ => pure ()
        if !unacked.isEmpty then
          return .fail s!"the source did not acknowledge {unacked} — the premise does not hold"
        let back ← waitForCondition "the destination master answers again" 300 do
          match ← masterIp cfgDst with
          | none => return false
          | some ip => return (← readKey cfgDst ip "fill_0").isSome
        let t1 ← IO.monoMsNow
        if !back then
          let dl ← kubectlLogsLabel s!"app={cfgDst.operatorName}" cfgDst.«namespace» 400
          let keep := (dl.splitOn "\n").filter fun l =>
            containsSubstr l "FORBIDDEN" || containsSubstr l "CRITICAL" || containsSubstr l "history" || containsSubstr l "copy"
          IO.eprintln s!"# destination operator (filtered, last 30): {keep.reverse.take 30 |>.reverse |>.map String.trim}"
          return .fail "the destination master did not come back within 300 s (a per-key-seeded destination keeps its own history; this is not the snapshot-push finding)"
        let some dIp ← masterIp cfgDst | return .fail "no destination master after the restart"
        let itemsAfter ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp cfgDst.flarePort
        IO.eprintln s!"# destination back after ~{(t1 - t0) / 1000} s at {dIp}; curr_items {itemsBefore} before, {itemsAfter} on return"
        let mut postKeys : List String := []
        for j in List.range 5 do
          let k := s!"rst_post_{j}"
          postKeys := postKeys ++ [k]
          if !(← setSrc sIp k s!"q{j}") then
            return .fail s!"the source did not acknowledge {k} after the restart"
        let tracked := preKeys ++ newKeys ++ postKeys
        -- the resend window is 120 s; wait past it before judging
        let _ ← waitForCondition "every tracked key agrees on source and destination" 240 do
          return (← divergent sIp dIp tracked).isEmpty
        let div ← divergent sIp dIp tracked
        let details ← div.mapM (describeKey sIp dIp)
        let d1 ← statNat cfgSrc sIp "proxy_write_dropped"
        let r1 ← statNat cfgSrc sIp "cluster_replication[forward_server_error_retried]"
        IO.eprintln s!"# restart (per-key seed): {tracked.length} tracked; differing {div.length}; proxy_write_dropped {d0} → {d1}; forward_server_error_retried {r0} → {r1}; {← creplSummary sIp}"
        outcomeRef.set (some { tracked := tracked.length, divergent := div, details,
                               droppedDelta := d1 - d0, serverErrorRetried := r1 - r0 })
        if div.length > d1 - d0 then
          return .fail s!"SILENT LOSS: {div.length} tracked keys differ but only {d1 - d0} drops were counted: {details.take 10}"
        let postMissing := div.filter (fun k => postKeys.contains k)
        if !postMissing.isEmpty then
          return .fail s!"forwarding did not resume after the destination returned: {postMissing} missing"
        return .pass },

    { name := "order reached: the restarted destination answered SERVER_ERROR and the source resent it (forward_server_error_retried moved) — otherwise the resend was not exercised by this run"
      run := do
        match ← outcomeRef.get with
        | none => return .fail "the restart test did not record an outcome"
        | some o =>
          if o.serverErrorRetried == 0 then
            return .fail "forward_server_error_retried did not move: the destination never answered SERVER_ERROR during this restart (connection refusals only) — the SERVER_ERROR resend was NOT exercised; the arrived-or-counted verdict above does not cover it"
          IO.eprintln s!"# SERVER_ERROR answers resent: {o.serverErrorRetried}"
          return .pass },

    { name := "after the per-key-seeded destination restart: final per-key match — every tracked key has the same value (or is absent) on source and destination (a counted drop is NOT a match)"
      run := do
        match ← outcomeRef.get with
        | none => return .fail "the restart test did not record an outcome"
        | some o =>
          if o.divergent.isEmpty then
            IO.eprintln s!"# FINAL MATCH: all {o.tracked} tracked keys agree; drops counted {o.droppedDelta}"
            return .pass
          return .fail s!"FINAL MATCH: {o.divergent.length} of {o.tracked} tracked keys differ (drops counted {o.droppedDelta}); nothing repairs them: {o.details.take 10}" }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplicationRestartDump
