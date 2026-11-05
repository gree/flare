/-
  E2E/Tests/HistoryContinuation.lean — history continuation across an
  ordered handover (docs/design-handover-history-continuation.md, Issue
  flare-promotion-forces-rebuild). Suites are added as the parts land:

  * `history-continuation-wal-pin-restart` (A1, design 6th revision): the
    WAL retention marker WAL_PIN outside the DB is read before DB::Open.
    The master's WAL TTL and size cap are made small (30 s, 16 MB) and more
    WAL than that is written, then flared is killed and restarted after the
    TTL (30 s; the pin is 115 s, inside the default 120 s limit): with the marker the WAL from S+1 is still served
    (`repl_sync_wal S+1` answers no `lsn_purged`); without it (the control)
    the same restart purges it and the answer is `lsn_purged` — the control
    shows the test really produces the deletion.

  The pin is storage-level, so it is exercised on a REPLICA (its own WAL
  holds the changes it applied): restarting a replica starts no failover,
  and flared cannot start without the operator (the index server), so the
  operator stays up (42065347622: with the operator at 0 the restarted
  flared never came back).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.HistoryContinuation

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def kindNode : String := "flare-e2e-control-plane"
private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def walPinCfg : ClusterConfig := {
  name := "hist-cont-wal-pin"
  «namespace» := "flare-hist-cont-wal-pin"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-hist-cont-wal-pin"
  storageBackend := "rocksdb"
  useTmpfs := true
  tmpfsSize := "768Mi"
  flaredMemoryLimit := "768Mi"
  flaredMemoryRequest := "256Mi"
  -- small retention so a normal reopen purges the archived WAL; a small
  -- write buffer so the writes below switch WAL files and archive the old
  extraFlaredConf := "rocksdb-write-buffer-size-mb = 1\nrocksdb-wal-ttl-seconds = 30\nrocksdb-wal-size-limit-mb = 16\nrocksdb-max-total-wal-size-mb = 1"
}

private def nodeCmd (ip : String) (cmd : String) : IO String := do
  match ← execInDebugPod walPinCfg.debugPod walPinCfg.«namespace» s!"printf '{cmd}\\r\\nquit\\r\\n' | nc -w 10 {ip} {walPinCfg.flarePort}" with
  | .ok o => return o
  | .error e => return s!"ERROR {e}"

private def statOf (out key : String) : Option String :=
  (out.splitOn "\n").findSome? fun l =>
    let l := (l.replace "\r" "").trim
    if l.startsWith s!"STAT {key} " then some (l.drop (s!"STAT {key} ").length) else none

private def stat (ip key : String) : IO (Option String) := do
  return statOf (← nodeCmd ip "stats") key

private def podIp (pod : String) : IO (Option String) := getPodIp pod walPinCfg.«namespace»

private def podUid (pod : String) : IO (Option String) := do
  match ← kubectlGetJsonpath "pod" pod walPinCfg.«namespace» "{.metadata.uid}" with
  | .ok o => return some o.trim
  | .error _ => return none

private def restartCount (pod : String) : IO Nat := do
  match ← kubectlGetJsonpath "pod" pod walPinCfg.«namespace» "{.status.containerStatuses[0].restartCount}" with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

/-- kill -9 flared in `pod` from the kind node (pid 1 ignores signals from
    inside the pod); the tmpfs (emptyDir) survives a container restart. -/
private def killFlaredIn (pod : String) : IO (Except String String) := do
  match ← podUid pod with
  | none => return .error s!"no UID for {pod}"
  | some uid =>
    let u2 := uid.replace "-" "_"
    let out ← IO.Process.output { cmd := "docker", args := #["exec", kindNode, "sh", "-c",
      s!"n=0; for p in $(pgrep -x flared); do if grep -q -e '{uid}' -e '{u2}' /proc/$p/cgroup 2>/dev/null; then kill -9 $p && n=$((n+1)); fi; done; echo killed=$n"] }
    if out.exitCode == 0 && containsSubstr out.stdout "killed=1" then return .ok out.stdout.trim
    return .error s!"{out.stdout.trim} {out.stderr.trim}"

/-- ~`mb` MB of 50 kB random values on `ip` (STORED count). -/
private def writeMb (ip pfx : String) (mb : Nat) : IO Nat := do
  let count := mb * 20
  let cmd := s!"v=$(head -c 37500 /dev/urandom | base64 | tr -d '\\n'); len=$(printf %s \"$v\" | wc -c); (awk -v m={count} -v v=\"$v\" -v n=\"$len\" 'BEGIN\{for(i=0;i<m;i++) printf \"set {pfx}_%d 0 0 %d\\r\\n%s\\r\\n\", i, n, v}'; sleep 3) | nc -w 300 {ip} {walPinCfg.flarePort} | grep -c STORED"
  match ← execInDebugPod walPinCfg.debugPod walPinCfg.«namespace» cmd with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

/-- The source's answer to a WAL read from `lsn` (master_id / epoch not
    checked: "-"), first line only. -/
private def walReadFrom (ip : String) (lsn : Nat) : IO String := do
  -- the reply carries binary WAL batches after its first line: the first
  -- 160 bytes with every other byte replaced by '?' (42070876131: kubectl
  -- refused the non-UTF-8 output; 42074557368: busybox tr has no [:print:])
  match ← execInDebugPod walPinCfg.debugPod walPinCfg.«namespace» s!"printf 'repl_sync_wal {lsn} - - 1 65536\r\nquit\r\n' | nc -w 10 {ip} {walPinCfg.flarePort} | head -c 160 | tr -c 'A-Za-z0-9 _:.-' '?'" with
  | .ok o => return o.trim
  | .error e => return s!"ERROR {e}"

private def nowMs : IO Nat := do
  let out ← IO.Process.output { cmd := "date", args := #["+%s%3N"] }
  return out.stdout.trim.toNat?.getD 0

/-- One cycle on the replica `pod`: S = its latest sequence; optionally pin
    from S; write past the caps on the master (the replica applies them into
    its own WAL); wait out the TTL; kill -9 the replica and wait until it
    answers again; read its WAL from S+1. -/
private def cycle (pod ip mIp : String) (pin : Option String) : IO (Except String (String × String)) := do
  let some s := (← stat ip "rocksdb_latest_sequence_number").bind String.toNat? | return .error "no rocksdb_latest_sequence_number"
  if let some hid := pin then
    -- within the default pin limit (120 s): writes + 40 s + the restart
    let r ← nodeCmd ip s!"wal_pin set {hid} {s} {(← nowMs) + 115000}"
    if !(containsSubstr r "STAT wal_pin_result pinned") then return .error s!"wal_pin set: {r.trim}"
  let stored ← writeMb mIp (pin.getD "ctl") 40
  if stored < 700 then return .error s!"stored {stored}/800 values"
  IO.sleep 40000
  let rc0 ← restartCount pod
  if let .error e ← killFlaredIn pod then return .error s!"kill: {e}"
  let back ← waitForCondition s!"{pod}'s flared answers after the restart" 300 do
    let some ipNow ← podIp pod | return false
    return (← restartCount pod) > rc0 && (← stat ipNow "wal_pin_state").isSome
  if !back then return .error "flared did not come back"
  let some ipNow ← podIp pod | return .error "no IP after the restart"
  let state := (← stat ipNow "wal_pin_state").getD "?"
  return .ok (← walReadFrom ipNow (s + 1), state)

def walPinRestartSuite : TestSuite := {
  name := "history-continuation-wal-pin-restart"
  setup := do
    deployCluster walPinCfg
    IO.sleep 50000
  teardown := cleanupCluster walPinCfg
  onFailure := dumpClusterDiagnostics walPinCfg.«namespace» s!"app={walPinCfg.operatorName}"
  tests := [
    { name := "WAL_PIN (design 6th rev.): with the marker, a kill -9 restart after the WAL TTL still serves the WAL from S+1; without it (control) the same restart purges it (lsn_purged)"
      run := do
        let ns := walPinCfg.«namespace»
        let sync ← operatorTcpCmd walPinCfg.debugPod ns walPinCfg.operatorName walPinCfg.operatorPort "node sync"
        let entries := parseNodeSync sync
        let some mFqdn := findMasterFqdn entries 0 | return .fail "no Active P0 master in the operator's map"
        let some sEntry := entries.find? (fun e => e.fqdn != mFqdn && e.role == 1 && e.state == 0) | return .fail "no Active slave"
        let some mIp ← podIp (podOf mFqdn) | return .fail "no master IP"
        let pod := podOf sEntry.fqdn
        let some ip ← podIp pod | return .fail "no replica IP"
        let pinned ← cycle pod ip mIp (some "hc-e2e-1")
        let (pinnedRead, pinnedState) ← match pinned with
          | .error e => return .fail s!"pinned cycle: {e}"
          | .ok r => pure r
        let some ip2 ← podIp pod | return .fail "no replica IP after the first cycle"
        let rel ← nodeCmd ip2 "wal_pin release hc-e2e-1"
        let control ← cycle pod ip2 mIp none
        let (ctlRead, ctlState) ← match control with
          | .error e => return .fail s!"control cycle: {e}"
          | .ok r => pure r
        IO.eprintln s!"# pinned: state after restart {pinnedState}; repl_sync_wal S+1 -> {pinnedRead.take 160}\n# release: {(statOf rel "wal_pin_result").getD rel.trim}\n# control: state after restart {ctlState}; repl_sync_wal S+1 -> {ctlRead.take 160}"
        if pinnedState != "active" then return .fail s!"after the pinned restart wal_pin_state is {pinnedState}, not active"
        if containsSubstr pinnedRead "lsn_purged" || containsSubstr pinnedRead "SERVER_ERROR" || containsSubstr pinnedRead "ERROR" then
          return .fail s!"with the marker the WAL from S+1 was not served: {pinnedRead}"
        if (statOf rel "wal_pin_result") != some "released" then return .fail s!"release: {rel.trim}"
        if !(containsSubstr ctlRead "lsn_purged") then
          return .fail s!"control: without the marker the restart did not purge the WAL (answer {ctlRead}) — the test did not produce the deletion"
        return .pass }
  ]
}

-- ─── a planned master switch keeps the remaining replica's copy (A4) ─────

private def hcCfg : ClusterConfig := {
  name := "hist-cont-handover"
  «namespace» := "flare-hist-cont-handover"
  partitions := 1
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-hist-cont-handover"
  storageBackend := "rocksdb"
  useTmpfs := true
  tmpfsSize := "512Mi"
  flaredMemoryLimit := "512Mi"
  flaredMemoryRequest := "256Mi"
  operatorEnv := [("FLARE_OPERATOR_HISTORY_CONTINUATION", "on")]
}

private def hcCmd (ip cmd : String) : IO String := do
  match ← execInDebugPod hcCfg.debugPod hcCfg.«namespace» s!"printf '{cmd}\\r\\nquit\\r\\n' | nc -w 10 {ip} {hcCfg.flarePort}" with
  | .ok o => return o
  | .error e => return s!"ERROR {e}"

private def hcStat (ip key : String) : IO (Option String) := do
  return statOf (← hcCmd ip "stats") key

private def hcWrite (ip pfx : String) (n : Nat) : IO Nat := do
  let cmd := s!"(awk 'BEGIN\{for(i=0;i<{n};i++) printf \"set {pfx}_%d 0 0 5\\r\\nvalue\\r\\n\", i}'; sleep 2) | nc -w 60 {ip} {hcCfg.flarePort} | grep -c STORED"
  match ← execInDebugPod hcCfg.debugPod hcCfg.«namespace» cmd with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

def handoverSuite : TestSuite := {
  name := "history-continuation-handover"
  setup := do
    deployCluster hcCfg
    IO.sleep 50000
  teardown := cleanupCluster hcCfg
  onFailure := dumpClusterDiagnostics hcCfg.«namespace» s!"app={hcCfg.operatorName}"
  tests := [
    { name := "history continuation (A4): a graceful delete of the master hands over and the remaining replica COMMITS the continued history — no staged rebuild, no snapshot bootstrap, same epoch as the new master, it follows the new master's writes"
      run := do
        let ns := hcCfg.«namespace»
        let view := fun (_ : Unit) => do
          return parseNodeSync (← operatorTcpCmd hcCfg.debugPod ns hcCfg.operatorName hcCfg.operatorPort "node sync")
        let entries ← view ()
        let some mFqdn := findMasterFqdn entries 0 | return .fail "no Active P0 master"
        let slaves := (entries.filter fun e => e.role == 1 && e.state == 0 && e.partition == 0).map (podOf ·.fqdn)
        let [s1, s2] := slaves | return .fail s!"precondition: want 2 Active slaves, have {slaves}"
        let mPod := podOf mFqdn
        let some mIp ← getPodIp mPod ns | return .fail "no master IP"
        if (← hcWrite mIp "pre" 300) < 300 then return .fail "precondition writes not all STORED"
        -- both replicas follow the master's WAL up to its last sequence
        let caught ← waitForCondition "both replicas' follow cursor reaches the master's last sequence" 180 do
          let some l := (← hcStat mIp "rocksdb_latest_sequence_number").bind String.toNat? | return false
          let mut ok := true
          for r in [s1, s2] do
            let some ip ← getPodIp r ns | return false
            let c := (← hcStat ip "rocksdb_repl_last_lsn").bind String.toNat?
            let st := (← hcStat ip "repl_follow_state")
            ok := ok && c == some l && st == some "following"
          return ok
        if !caught then return .fail "precondition: the replicas did not catch up by WAL follow (is follow on?)"
        let mut before : List (String × (Option String × Option String)) := []
        for r in [s1, s2] do
          let some ip ← getPodIp r ns | return .fail s!"no IP for {r}"
          before := before ++ [(r, ((← hcStat ip "rocksdb_staged_switched"), (← hcStat ip "rocksdb_snapshot_bootstrap")))]
        let t0 := (← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }).stdout.trim
        discard <| kubectl ["delete", "pod", mPod, "-n", ns, "--wait=false"]
        -- the new master is one of the replicas; the other stays Slave/Active
        let switched ← waitForCondition "a replica is the Active master and the other an Active slave" 240 do
          let es ← view ()
          let m := (findMasterFqdn es 0).map podOf
          return m.any (fun x => x == s1 || x == s2)
            && (es.filter fun e => e.role == 1 && e.state == 0 && e.partition == 0 && (podOf e.fqdn == s1 || podOf e.fqdn == s2)).length == 1
        if !switched then return .fail "no handover to a replica within 240 s"
        let es ← view ()
        let some newM := (findMasterFqdn es 0).map podOf | return .fail "no master after the switch"
        let other := if newM == s1 then s2 else s1
        let some oIp ← getPodIp other ns | return .fail "no IP for the remaining replica"
        let some nIp ← getPodIp newM ns | return .fail "no IP for the new master"
        let opLog ← match ← kubectl ["logs", "-n", ns, "-l", s!"app={hcCfg.operatorName}", "--since-time", t0, "--tail=-1"] with
          | .ok o => pure o | .error _ => pure ""
        let flLog ← match ← kubectl ["logs", "-n", ns, other, "-c", "flared", "--since-time", t0] with
          | .ok o => pure o | .error _ => pure ""
        let committed := containsSubstr flLog "COMMITTED as replica"
        let after := ((← hcStat oIp "rocksdb_staged_switched"), (← hcStat oIp "rocksdb_snapshot_bootstrap"))
        let eO := (← hcStat oIp "rocksdb_source_epoch")
        let eN := (← hcStat nIp "rocksdb_source_epoch")
        let wrote ← hcWrite nIp "post" 200
        let follows ← waitForCondition "the remaining replica follows the new master" 120 do
          let some l := (← hcStat nIp "rocksdb_latest_sequence_number").bind String.toNat? | return false
          return ((← hcStat oIp "rocksdb_repl_last_lsn").bind String.toNat?) == some l
        let phases := (opLog.splitOn "\n").filter (fun l => containsSubstr l "HANDOVER p0" && containsSubstr l " -> ")
        IO.eprintln s!"# new master {newM}, remaining {other}: committed={committed}; staged/snapshot before {before.lookup other} after {after}; epoch remaining {eO} new master {eN}; post writes {wrote}/200; follows={follows}\n# phases: {phases.map (·.trim.take 160)}"
        if !committed then return .fail s!"the remaining replica {other} did not commit the continued history (no 'COMMITTED as replica' in its log)"
        if before.lookup other != some after then return .fail s!"the remaining replica rebuilt (staged/snapshot {before.lookup other} -> {after})"
        if eO.isNone || eO != eN then return .fail s!"epochs differ: remaining {eO}, new master {eN}"
        if wrote < 200 then return .fail s!"post-switch writes {wrote}/200"
        if !follows then return .fail "the remaining replica does not follow the new master's WAL"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.HistoryContinuation
