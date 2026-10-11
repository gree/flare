/-
  Cross-cluster forwarding under faults: no write the source acknowledged may
  be lost WITHOUT being counted.

  Audit 2026-10-11 (docs/review-cross-cluster-2026-10-11.md): the live
  cross-cluster stream is best effort — a forward that fails is counted in
  `proxy_write_dropped[dest]` on the source master and NOT repaired. Two paths
  were not even counted: the forwarding thread that could not connect at
  start returned and left the pool while the replication stayed 'started',
  and every later forward then failed to enqueue ("no available thread",
  a log_notice). A destination whose name does not resolve when replication
  is enabled (a Service created a moment later, a DNS hiccup at pod start)
  silently lost every forward until a restart or a disable/enable.

  These tests require, per key the source acknowledged: it is on the
  destination, or the drop counter moved by at least that many. They do NOT
  claim repair — a counted drop stays a divergence (runbook: re-seed).

  Each fault has TWO verdicts, as separate tests: "arrived or counted" (the
  operator can see every loss) and "final per-key match" (source and
  destination agree on every tracked key's value and absence). A drop
  counter only says HOW MANY were lost, not WHICH — it never proves a key is
  correct, so the second verdict reads every key on both sides. Nothing
  repairs a divergence; a failing final match is an open gap, recorded as a
  failure (the cutover must be refused), never as a pass.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ClusterReplicationFaults

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfgSrc : ClusterConfig := {
  name := "crf-src"
  «namespace» := "flare-crf-src"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crf-src"
  debugPod := "debug-crf"
  storageBackend := "rocksdb"
}

private def cfgDst : ClusterConfig := {
  name := "crf-dst"
  «namespace» := "flare-crf-dst"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-crf-dst"
  debugPod := "debug-crf"
  storageBackend := "rocksdb"
  -- the restart test restarts the destination WITH its data (a deleted pod
  -- on the default pod-local directory would come back empty — a different
  -- case, see the empty-return note in the restart test)
  usePvc := true
}

/-- A Service that does NOT exist when replication is enabled. -/
private def lateSvcName : String := "crf-late"
private def lateSvc : String := s!"{lateSvcName}.{cfgDst.«namespace»}.svc.cluster.local"

private def lateServiceYaml : String :=
  s!"apiVersion: v1
kind: Service
metadata:
  name: {lateSvcName}
  namespace: {cfgDst.«namespace»}
spec:
  selector:
    app: flare
    cluster: {cfgDst.name}
  ports:
  - port: {cfgDst.flarePort}
    targetPort: {cfgDst.flarePort}
"

private def applyService : IO (Except String Unit) := do
  let out ← IO.Process.output { cmd := "sh", args := #["-c", s!"cat <<'ENDOFYAML' | kubectl apply -f -\n{lateServiceYaml}\nENDOFYAML"] }
  if out.exitCode == 0 then return .ok () else return .error out.stderr

private def masterIp (cfg : ClusterConfig) : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  match findMasterPod (parseNodeSync sync) 0 with
  | none => return none
  | some m => getPodIp m cfg.«namespace»

private def droppedTotal (ip : String) : IO (Option Nat) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfgSrc.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := (l.trim.replace "\r" "")
      if t.startsWith "STAT proxy_write_dropped " then (t.drop "STAT proxy_write_dropped ".length).trim.toNat?
      else none

private def writeKeys (ip pfx : String) (n : Nat) : IO Nat := do
  let mut ok := 0
  for i in List.range n do
    if ← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» ip cfgSrc.flarePort s!"{pfx}_{i}" s!"v_{i}" then
      ok := ok + 1
  return ok

private def presentOn (ip pfx : String) (n : Nat) : IO Nat := do
  let mut present := 0
  for i in List.range n do
    if (← memcachedGet cfgDst.debugPod cfgDst.«namespace» ip cfgDst.flarePort s!"{pfx}_{i}") == some s!"v_{i}" then
      present := present + 1
  return present

/-- A key's value on a node: `some (some v)` / `some none` (a miss) /
    `none` (no answer, or an explicit error — not a miss). -/
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

private def deleteKey (ip key : String) : IO Bool := do
  let cmd := s!"printf 'delete {key}\\r\\n' | nc -w 3 {ip} {cfgSrc.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .ok out => return containsSubstr out "DELETED"
  | .error _ => return false

/-- Keys whose value (or absence) differs between source and destination.
    A side that cannot be read counts as a difference (it is not shown to
    match); each key is read twice before it is called different. -/
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

/-- Ids of the destination's request threads serving a connection from
    `peerIp`, killed with flared's `kill <id>`: the destination closes the
    source's forwarding connection, as a broken TCP connection would. -/
private def killConnectionsFrom (dIp peerIp : String) : IO (Nat × String) := do
  let cmd := s!"printf 'stats threads\\r\\n' | nc -w 3 {dIp} {cfgDst.flarePort}"
  match ← execInDebugPod cfgDst.debugPod cfgDst.«namespace» cmd with
  | .error e => return (0, s!"stats threads failed: {e}")
  | .ok out =>
    let peers := (out.splitOn "\n").filterMap fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith "STAT " && containsSubstr t ":peer " then
        let rest := t.drop 5
        let id := rest.takeWhile Char.isDigit
        let peer := ((rest.splitOn ":peer ").getLast!).trim
        some (id, peer)
      else none
    let ids := peers.filter (fun (_, peer) => peer.startsWith s!"{peerIp}:") |>.map (·.1)
    let mut n := 0
    for id in ids do
      match ← execInDebugPod cfgDst.debugPod cfgDst.«namespace» s!"printf 'kill {id}\\r\\n' | nc -w 3 {dIp} {cfgDst.flarePort}" with
      | .ok o => if containsSubstr o "OK" then n := n + 1
      | .error _ => pure ()
    return (n, s!"peers {peers.map (·.2)}")

private def creplStats (ip : String) : IO String := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfgSrc.flarePort}"
  match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» cmd with
  | .error _ => return "(unreadable)"
  | .ok out =>
    let ls := (out.splitOn "\n").filterMap fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith "STAT cluster_replication" || t.startsWith "STAT proxy_write_dropped" then some (t.drop 5) else none
    return ", ".intercalate ls

/-- What one fault left behind, for its final-match test. -/
structure FaultOutcome where
  tracked : Nat
  divergent : List String
  details : List String
  droppedDelta : Nat
  deriving Inhabited

initialize breakOutcome : IO.Ref (Option FaultOutcome) ← IO.mkRef none
initialize restartOutcome : IO.Ref (Option FaultOutcome) ← IO.mkRef none

private def finalMatch (name : String) (r : IO.Ref (Option FaultOutcome)) : IO TestResult := do
  match ← r.get with
  | none => return .fail s!"the {name} test did not record an outcome (it failed before the comparison)"
  | some o =>
    if o.divergent.isEmpty then
      IO.eprintln s!"# FINAL MATCH after the {name}: all {o.tracked} tracked keys agree (values and deletions); drops counted {o.droppedDelta}"
      return .pass
    else
      return .fail s!"FINAL MATCH after the {name}: {o.divergent.length} of {o.tracked} tracked keys differ between source and destination (drops counted {o.droppedDelta}); nothing repairs them — the cutover must be refused: {o.details.take 10}"

private def earlyKeys : Nat := 10
private def lateKeys : Nat := 20

def suite : TestSuite := {
  name := "cluster-replication-faults"
  setup := do
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
    discard <| kubectl ["delete", "service", lateSvcName, "-n", cfgDst.«namespace», "--ignore-not-found"]
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
    discard <| kubectl ["delete", "service", lateSvcName, "-n", cfgDst.«namespace», "--ignore-not-found"]
    cleanupCluster cfgSrc
    cleanupCluster cfgDst
  tests := [
    { name := "the destination name does not resolve when replication is enabled: every acknowledged write is on the destination or counted as dropped; once the name resolves, later writes arrive (the forwarding thread did not leave)"
      run := do
        let patchJson := s!"\{\"spec\":\{\"clusterReplication\":\{\"enabled\":true,\"serverName\":\"{lateSvc}\",\"port\":{cfgDst.flarePort},\"mode\":\"duplicate\",\"concurrency\":1}}}"
        match ← kubectlPatch "flarecluster" cfgSrc.name cfgSrc.«namespace» patchJson with
        | .error e => return .fail s!"could not enable replication: {e}"
        | .ok _ => pure ()
        -- the forwarding thread must have TRIED and failed (the name does
        -- not resolve yet), else the window was never opened
        let tried ← waitForCondition "the source tried to connect to the unresolvable destination" 240 do
          let l ← kubectlLogsLabel s!"app=flare,cluster={cfgSrc.name}" cfgSrc.«namespace» 3000
          return containsSubstr l "failed to connect to cluster replication destination server"
        if !tried then return .fail s!"no failed connect to {lateSvc} was logged: the unresolvable-at-start case was not exercised"
        match ← masterIp cfgSrc with
        | none => return .fail "no source master"
        | some sIp =>
          let d0 := (← droppedTotal sIp).getD 0
          let wroteEarly ← writeKeys sIp "early" earlyKeys
          IO.sleep 20000
          let d1 := (← droppedTotal sIp).getD 0
          match ← applyService with
          | .error e => return .fail s!"could not create {lateSvcName}: {e}"
          | .ok _ => pure ()
          let resolvable ← waitForCondition s!"{lateSvc} resolves from the source" 120 do
            match ← execInDebugPod cfgSrc.debugPod cfgSrc.«namespace» s!"nslookup {lateSvc} >/dev/null 2>&1 && echo ok || echo no" with
            | .ok o => return containsSubstr o "ok"
            | .error _ => return false
          if !resolvable then return .fail s!"{lateSvc} never resolved"
          let wroteLate ← writeKeys sIp "late" lateKeys
          match ← masterIp cfgDst with
          | none => return .fail "no destination master"
          | some dIp =>
            let _ ← waitForCondition s!"all {lateKeys} later keys on the destination" 120 do
              return (← presentOn dIp "late" lateKeys) == lateKeys
            let late ← presentOn dIp "late" lateKeys
            let early ← presentOn dIp "early" earlyKeys
            let d2 := (← droppedTotal sIp).getD 0
            IO.eprintln s!"# acknowledged: early {wroteEarly}/{earlyKeys}, late {wroteLate}/{lateKeys}; on the destination: early {early}, late {late}; proxy_write_dropped {d0} → {d1} (unresolvable) → {d2}"
            if wroteEarly != earlyKeys || wroteLate != lateKeys then
              return .fail "the source did not acknowledge every write — the premise (acknowledged writes) does not hold"
            -- every early key: arrived or counted
            if early + (d1 - d0) < earlyKeys then
              return .fail s!"SILENT LOSS: {earlyKeys - early} early writes are neither on the destination nor counted (drops +{d1 - d0}) — the operator cannot see them"
            if late < lateKeys then
              return .fail s!"after the name resolved only {late}/{lateKeys} writes reached the destination (drops now {d2}): the forwarding stayed broken"
            return .pass },

    { name := "the destination breaks the forwarding connection mid-stream, four times (sets, overwrites, deletes): every acknowledged change is on the destination or counted as dropped"
      run := do
        breakOutcome.set none
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let some dIp ← masterIp cfgDst | return .fail "no destination master"
        let preN := 8
        for i in List.range preN do
          if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort s!"brk_pre_{i}" s!"p{i}") then
            return .fail s!"precondition: the source did not acknowledge brk_pre_{i}"
        let preKeys := (List.range preN).map (s!"brk_pre_{·}")
        let flowing ← waitForCondition "the pre-break keys reached the destination" 120 do
          return (← divergent sIp dIp preKeys).isEmpty
        if !flowing then return .fail "precondition: forwarding did not deliver before the break — the break would not be tested"
        let d0 := (← droppedTotal sIp).getD 0
        let mut killed := 0
        let mut seen := ""
        let mut newKeys : List String := []
        let mut unacked : List String := []
        for r in List.range 4 do
          let (n, peers) ← killConnectionsFrom dIp sIp
          killed := killed + n
          seen := peers
          for j in List.range 4 do
            let k := s!"brk_new_{r}_{j}"
            newKeys := newKeys ++ [k]
            if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort k s!"n{r}{j}") then unacked := unacked ++ [k]
          if !(← deleteKey sIp s!"brk_pre_{2 * r}") then unacked := unacked ++ [s!"delete brk_pre_{2 * r}"]
          if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort s!"brk_pre_{2 * r + 1}" s!"u{r}") then unacked := unacked ++ [s!"brk_pre_{2 * r + 1}"]
          IO.sleep 1500
        IO.eprintln s!"# connections from {sIp} closed by the destination: {killed} (last thread list: {seen})"
        if killed == 0 then
          return .fail s!"no forwarding connection from the source master {sIp} was found on the destination ({seen}): the break was not exercised"
        if !unacked.isEmpty then
          return .fail s!"the source did not acknowledge {unacked} — the premise (acknowledged changes) does not hold"
        let tracked := preKeys ++ newKeys
        let _ ← waitForCondition "every tracked key agrees on source and destination" 180 do
          return (← divergent sIp dIp tracked).isEmpty
        let div ← divergent sIp dIp tracked
        let details ← div.mapM (describeKey sIp dIp)
        let d1 := (← droppedTotal sIp).getD 0
        IO.eprintln s!"# break: {tracked.length} tracked keys ({newKeys.length} new, {preN / 2} overwritten, {preN / 2} deleted); differing {div.length}; proxy_write_dropped {d0} → {d1}; {← creplStats sIp}"
        breakOutcome.set (some { tracked := tracked.length, divergent := div, details, droppedDelta := d1 - d0 })
        if div.length > d1 - d0 then
          return .fail s!"SILENT LOSS: {div.length} tracked keys differ but only {d1 - d0} drops were counted: {details.take 10}"
        return .pass },

    { name := "after the connection breaks: final per-key match — every tracked key has the same value (or is absent) on source and destination (a counted drop is NOT a match)"
      run := finalMatch "connection breaks" breakOutcome },

    { name := "the destination master restarts (pod deleted, data kept) while writes continue: every acknowledged change is on the destination or counted, and forwarding resumes after it returns"
      run := do
        restartOutcome.set none
        let some sIp ← masterIp cfgSrc | return .fail "no source master"
        let sync ← operatorTcpCmd cfgDst.debugPod cfgDst.«namespace» cfgDst.operatorName cfgDst.operatorPort "node sync"
        let some dPod := findMasterPod (parseNodeSync sync) 0 | return .fail "no destination master"
        let some dIp ← getPodIp dPod cfgDst.«namespace» | return .fail "no destination master IP"
        let preN := 10
        for i in List.range preN do
          if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort s!"rst_pre_{i}" s!"p{i}") then
            return .fail s!"precondition: the source did not acknowledge rst_pre_{i}"
        let preKeys := (List.range preN).map (s!"rst_pre_{·}")
        let flowing ← waitForCondition "the pre-restart keys reached the destination" 120 do
          return (← divergent sIp dIp preKeys).isEmpty
        if !flowing then return .fail "precondition: forwarding did not deliver before the restart"
        let itemsBefore ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp cfgDst.flarePort
        let d0 := (← droppedTotal sIp).getD 0
        match ← kubectl ["delete", "pod", dPod, "-n", cfgDst.«namespace», "--grace-period=0", "--force", "--wait=false"] with
        | .error e => return .fail s!"could not delete {dPod}: {e}"
        | .ok _ => pure ()
        let t0 ← IO.monoMsNow
        let mut newKeys : List String := []
        let mut unacked : List String := []
        for j in List.range 15 do
          let k := s!"rst_new_{j}"
          newKeys := newKeys ++ [k]
          if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort k s!"n{j}") then unacked := unacked ++ [k]
          if j < 5 then
            if !(← deleteKey sIp s!"rst_pre_{j}") then unacked := unacked ++ [s!"delete rst_pre_{j}"]
          else if j < 10 then
            if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort s!"rst_pre_{j}" s!"u{j}") then unacked := unacked ++ [s!"rst_pre_{j}"]
          IO.sleep 1000
        if !unacked.isEmpty then
          return .fail s!"the source did not acknowledge {unacked} — the premise does not hold"
        let back ← waitForCondition "the destination master answers again" 300 do
          match ← masterIp cfgDst with
          | none => return false
          | some ip => return (← readKey cfgDst ip "rst_pre_9").isSome
        let t1 ← IO.monoMsNow
        if !back then
          -- what the restarted destination did with its data
          let dl ← kubectlLogs dPod cfgDst.«namespace» 3000
          let keep := (dl.splitOn "\n").filter fun l =>
            containsSubstr l "data_dir" || containsSubstr l "snapshot" || containsSubstr l "copy" || containsSubstr l "COPY"
              || containsSubstr l "binding" || containsSubstr l "restored" || containsSubstr l "open" || containsSubstr l "CRITICAL"
              || containsSubstr l "ERR" || containsSubstr l "node map accepted"
          IO.eprintln s!"# restarted destination {dPod} log (filtered, last 60): {keep.reverse.take 60 |>.reverse |>.map String.trim}"
          match ← getPodIp dPod cfgDst.«namespace» with
          | some ip => IO.eprintln s!"# destination stats: {← creplStats ip}; curr_items {← getCurrItems cfgDst.debugPod cfgDst.«namespace» ip cfgDst.flarePort}"
          | none => pure ()
          match ← kubectl ["exec", dPod, "-n", cfgDst.«namespace», "--", "sh", "-c", "ls -la /tmp/flare /tmp/flare/* 2>&1 | head -60; df -h /tmp/flare"] with
          | .ok o => IO.eprintln s!"# destination data dir: {o}"
          | .error e => IO.eprintln s!"# destination data dir unreadable: {e}"
          return .fail "the destination master did not come back within 300 s"
        let some dIp2 ← masterIp cfgDst | return .fail "no destination master after the restart"
        let itemsAfter ← getCurrItems cfgDst.debugPod cfgDst.«namespace» dIp2 cfgDst.flarePort
        IO.eprintln s!"# destination back after ~{(t1 - t0) / 1000} s at {dIp2}; curr_items {itemsBefore} before, {itemsAfter} on return (an EMPTY return would not be detected by anything: no source-side check exists)"
        let mut postKeys : List String := []
        for j in List.range 5 do
          let k := s!"rst_post_{j}"
          postKeys := postKeys ++ [k]
          if !(← memcachedSet cfgSrc.debugPod cfgSrc.«namespace» sIp cfgSrc.flarePort k s!"q{j}") then
            return .fail s!"the source did not acknowledge {k} after the restart"
        let tracked := preKeys ++ newKeys ++ postKeys
        let _ ← waitForCondition "every tracked key agrees on source and destination" 240 do
          return (← divergent sIp dIp2 tracked).isEmpty
        let div ← divergent sIp dIp2 tracked
        let details ← div.mapM (describeKey sIp dIp2)
        let d1 := (← droppedTotal sIp).getD 0
        IO.eprintln s!"# restart: {tracked.length} tracked keys; differing {div.length}; proxy_write_dropped {d0} → {d1}; {← creplStats sIp}"
        restartOutcome.set (some { tracked := tracked.length, divergent := div, details, droppedDelta := d1 - d0 })
        let postMissing := div.filter (fun k => postKeys.contains k)
        if div.length > d1 - d0 then
          return .fail s!"SILENT LOSS: {div.length} tracked keys differ but only {d1 - d0} drops were counted: {details.take 10}"
        if !postMissing.isEmpty then
          return .fail s!"forwarding did not resume after the destination returned: {postMissing} missing"
        return .pass },

    { name := "after the destination restart: final per-key match — every tracked key has the same value (or is absent) on source and destination (a counted drop is NOT a match)"
      run := finalMatch "destination restart" restartOutcome }
  ]
}

end FlareOperator.E2E.Tests.ClusterReplicationFaults
