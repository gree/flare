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
        return .pass },
    { name := "WAL_PIN (A4): a pin whose deadline passes is released by the tick (state none, reason the deadline, released +1, deletions enabled again)"
      run := do
        let ns := walPinCfg.«namespace»
        let entries := parseNodeSync (← operatorTcpCmd walPinCfg.debugPod ns walPinCfg.operatorName walPinCfg.operatorPort "node sync")
        let some mFqdn := findMasterFqdn entries 0 | return .fail "no Active P0 master"
        let some sEntry := entries.find? (fun e => e.fqdn != mFqdn && e.role == 1 && e.state == 0) | return .fail "no Active slave"
        let some ip ← podIp (podOf sEntry.fqdn) | return .fail "no replica IP"
        let some s := (← stat ip "rocksdb_latest_sequence_number").bind String.toNat? | return .fail "no latest sequence"
        let rel0 := ((← stat ip "wal_pin_released").bind String.toNat?).getD 0
        let r ← nodeCmd ip s!"wal_pin set hc-e2e-deadline {s} {(← nowMs) + 8000}"
        if !(containsSubstr r "STAT wal_pin_result pinned") then return .fail s!"wal_pin set: {r.trim}"
        let pinnedNow := (← stat ip "wal_pin_state") == some "active" && (← stat ip "wal_pin_deletions_disabled") == some "1"
        let released ← waitForCondition "the pin is released by its deadline" 40 do
          return (← stat ip "wal_pin_state") == some "none"
        let reason := (← stat ip "wal_pin_reason").getD "?"
        let rel1 := ((← stat ip "wal_pin_released").bind String.toNat?).getD 0
        let dis := (← stat ip "wal_pin_deletions_disabled").getD "?"
        IO.eprintln s!"# deadline pin: active while set={pinnedNow}; released={released}; reason {reason}; released {rel0} -> {rel1}; deletions_disabled {dis}"
        if !pinnedNow then return .fail "the pin was not active (deletions disabled) right after the set"
        if !released then return .fail "the pin was not released within 40 s of its 8 s deadline"
        if rel1 != rel0 + 1 then return .fail s!"wal_pin_released {rel0} -> {rel1}, want +1"
        if dis != "0" then return .fail s!"file deletions still disabled after the release ({dis})"
        return .pass },
    { name := "WAL_PIN (A4): an invalid marker is read before DB::Open and fails closed (state invalid, deletions disabled, the deadline does not release it); only release_invalid with this process's boot id releases it"
      run := do
        let ns := walPinCfg.«namespace»
        let entries := parseNodeSync (← operatorTcpCmd walPinCfg.debugPod ns walPinCfg.operatorName walPinCfg.operatorPort "node sync")
        let some mFqdn := findMasterFqdn entries 0 | return .fail "no Active P0 master"
        let some sEntry := entries.find? (fun e => e.fqdn != mFqdn && e.role == 1 && e.state == 0) | return .fail "no Active slave"
        let pod := podOf sEntry.fqdn
        let some ip ← podIp pod | return .fail "no replica IP"
        -- the data dir of the image under test (persistent or tmpfs layout)
        let dir ← match ← kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "sh", "-c", "for d in /data/flare /tmp/flare; do [ -d $d ] && echo $d && break; done"] with
          | .ok o => pure o.trim | .error e => return .fail s!"no data dir: {e}"
        if dir.isEmpty then return .fail "no data dir found in the flared container"
        match ← kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "sh", "-c", s!"printf 'v1 garbage\\n' > {dir}/WAL_PIN && sync"] with
        | .error e => return .fail s!"could not write the invalid marker: {e}"
        | .ok _ => pure ()
        let rc0 ← restartCount pod
        if let .error e ← killFlaredIn pod then return .fail s!"kill: {e}"
        let back ← waitForCondition s!"{pod}'s flared answers after the restart" 300 do
          let some ipNow ← podIp pod | return false
          return (← restartCount pod) > rc0 && (← stat ipNow "wal_pin_state").isSome
        if !back then return .fail "flared did not come back"
        let some ip2 ← podIp pod | return .fail "no IP after the restart"
        let st := (← stat ip2 "wal_pin_state").getD "?"
        let prot := (← stat ip2 "wal_pin_protected_open").getD "?"
        let dis := (← stat ip2 "wal_pin_deletions_disabled").getD "?"
        -- the tick does not release an invalid marker (no trusted deadline)
        IO.sleep 5000
        let stLater := (← stat ip2 "wal_pin_state").getD "?"
        let boot := (← stat ip2 "reconstruction_boot_id").getD ""
        let wrong ← nodeCmd ip2 s!"wal_pin release_invalid {boot}0"
        let ok ← nodeCmd ip2 s!"wal_pin release_invalid {boot}"
        let stAfter := (← stat ip2 "wal_pin_state").getD "?"
        let disAfter := (← stat ip2 "wal_pin_deletions_disabled").getD "?"
        let gone ← match ← kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "sh", "-c", s!"[ -e {dir}/WAL_PIN ] && echo present || echo absent"] with
          | .ok o => pure o.trim | .error _ => pure "?"
        IO.eprintln s!"# invalid marker in {dir}: after restart state {st} protected_open {prot} deletions_disabled {dis}; 5 s later {stLater}; release (wrong boot) {(statOf wrong "wal_pin_result").getD wrong.trim}; release (boot {boot}) {(statOf ok "wal_pin_result").getD ok.trim}; then state {stAfter} deletions_disabled {disAfter}, marker {gone}"
        if st != "invalid" then return .fail s!"after the restart wal_pin_state is {st}, not invalid"
        if prot != "1" || dis != "1" then return .fail s!"an invalid marker did not open protected (protected_open {prot}, deletions_disabled {dis})"
        if stLater != "invalid" then return .fail s!"the invalid marker was released without a request ({stLater})"
        if statOf wrong "wal_pin_result" != some "refused:boot_id" then return .fail s!"release_invalid with another boot id: {wrong.trim}"
        if statOf ok "wal_pin_result" != some "released" then return .fail s!"release_invalid with this boot id: {ok.trim}"
        if stAfter != "none" || disAfter != "0" || gone != "absent" then
          return .fail s!"after the release: state {stAfter}, deletions_disabled {disAfter}, marker {gone}"
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
  -- the node guard refuses the master's first graceful delete and starts
  -- the ordered handover; without it the delete goes through and the
  -- failover rules promote (42117591864: no HANDOVER, a lagging promotion)
  nodeGuard := true
}

private def hcCmdIn (cfg : ClusterConfig) (ip cmd : String) : IO String := do
  match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf '{cmd}\\r\\nquit\\r\\n' | nc -w 10 {ip} {cfg.flarePort}" with
  | .ok o => return o
  | .error e => return s!"ERROR {e}"

private def hcStatIn (cfg : ClusterConfig) (ip key : String) : IO (Option String) := do
  return statOf (← hcCmdIn cfg ip "stats") key

private def hcWriteIn (cfg : ClusterConfig) (ip pfx : String) (n : Nat) : IO Nat := do
  let cmd := s!"(awk 'BEGIN\{for(i=0;i<{n};i++) printf \"set {pfx}_%d 0 0 5\\r\\nvalue\\r\\n\", i}'; sleep 2) | nc -w 60 {ip} {cfg.flarePort} | grep -c STORED"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

private def hcStat (ip key : String) : IO (Option String) := hcStatIn hcCfg ip key
private def hcWrite (ip pfx : String) (n : Nat) : IO Nat := hcWriteIn hcCfg ip pfx n

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
        -- refused first (the handover starts), allowed once the master is a
        -- proxy: repeat the graceful delete until the pod is gone
        let mUid ← match ← kubectlGetJsonpath "pod" mPod ns "{.metadata.uid}" with
          | .ok o => pure o.trim | .error _ => pure ""
        let gone ← waitForCondition s!"the master {mPod} is deleted after its handover (graceful deletes repeated)" 240 do
          discard <| kubectl ["delete", "pod", mPod, "-n", ns, "--wait=false"]
          match ← kubectlGetJsonpath "pod" mPod ns "{.metadata.uid}" with
          | .ok o => return o.trim != mUid
          | .error _ => return true
        if !gone then return .fail "the master was not deleted within 240 s (the node guard kept refusing)"
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

-- ─── control: WAL follow off — the replicas rebuild as before (A4) ─────

private def foCfg : ClusterConfig :=
  { hcCfg with
    name := "hist-cont-follow-off"
    «namespace» := "flare-hist-cont-follow-off"
    debugPod := "debug-hist-cont-follow-off"
    walFollow := false }

/-- The negative control of `handoverSuite`: the same planned handover with
    continuation on but WAL follow off (pf-dev's setting). Nothing proves the
    remaining replica holds the old master's history up to L, so the
    operator does not continue it ("is not continued", or no continuation at
    all) and it rebuilds as before (staged switch or snapshot bootstrap),
    ending on the new master's epoch with no write lost. -/
def handoverFollowOffSuite : TestSuite := {
  name := "history-continuation-handover-follow-off"
  setup := do
    deployCluster foCfg
    IO.sleep 50000
  teardown := cleanupCluster foCfg
  onFailure := dumpClusterDiagnostics foCfg.«namespace» s!"app={foCfg.operatorName}"
  tests := [
    { name := "history continuation (A4 control): with WAL follow off a planned handover does not continue the remaining replica — it rebuilds as before, on the new master's epoch, with every key present"
      run := do
        let ns := foCfg.«namespace»
        let stat := hcStatIn foCfg
        let view := fun (_ : Unit) => do
          return parseNodeSync (← operatorTcpCmd foCfg.debugPod ns foCfg.operatorName foCfg.operatorPort "node sync")
        let entries ← view ()
        let some mFqdn := findMasterFqdn entries 0 | return .fail "no Active P0 master"
        let slaves := (entries.filter fun e => e.role == 1 && e.state == 0 && e.partition == 0).map (podOf ·.fqdn)
        let [s1, s2] := slaves | return .fail s!"precondition: want 2 Active slaves, have {slaves}"
        let mPod := podOf mFqdn
        let some mIp ← getPodIp mPod ns | return .fail "no master IP"
        -- the control's premise: follow is off on every pod
        for r in [mPod, s1, s2] do
          let some ip ← getPodIp r ns | return .fail s!"no IP for {r}"
          let st ← stat ip "repl_follow_state"
          if st == some "following" then return .fail s!"precondition: {r} follows the WAL ({st}); this control needs follow off"
        if (← hcWriteIn foCfg mIp "pre" 300) < 300 then return .fail "precondition writes not all STORED"
        IO.sleep 5000
        let mut before : List (String × (Option String × Option String)) := []
        for r in [s1, s2] do
          let some ip ← getPodIp r ns | return .fail s!"no IP for {r}"
          before := before ++ [(r, ((← stat ip "rocksdb_staged_switched"), (← stat ip "rocksdb_snapshot_bootstrap")))]
        let t0 := (← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }).stdout.trim
        let mUid ← match ← kubectlGetJsonpath "pod" mPod ns "{.metadata.uid}" with
          | .ok o => pure o.trim | .error _ => pure ""
        let gone ← waitForCondition s!"the master {mPod} is deleted after its handover (graceful deletes repeated)" 240 do
          discard <| kubectl ["delete", "pod", mPod, "-n", ns, "--wait=false"]
          match ← kubectlGetJsonpath "pod" mPod ns "{.metadata.uid}" with
          | .ok o => return o.trim != mUid
          | .error _ => return true
        if !gone then return .fail "the master was not deleted within 240 s (the node guard kept refusing)"
        let switched ← waitForCondition "a replica is the Active master" 240 do
          let es ← view ()
          return ((findMasterFqdn es 0).map podOf).any (fun x => x == s1 || x == s2)
        if !switched then return .fail "no handover to a replica within 240 s"
        let es ← view ()
        let some newM := (findMasterFqdn es 0).map podOf | return .fail "no master after the switch"
        let other := if newM == s1 then s2 else s1
        let some nIp ← getPodIp newM ns | return .fail "no IP for the new master"
        -- the remaining replica rebuilds and comes back Active
        let rebuilt ← waitForCondition s!"the remaining replica {other} rebuilds and is an Active slave again" 300 do
          let some ip ← getPodIp other ns | return false
          let now := ((← stat ip "rocksdb_staged_switched"), (← stat ip "rocksdb_snapshot_bootstrap"))
          let es ← view ()
          let active := es.any fun e => podOf e.fqdn == other && e.role == 1 && e.state == 0 && e.partition == 0
          return active && before.lookup other != some now
        let some oIp ← getPodIp other ns | return .fail "no IP for the remaining replica"
        let opLog ← match ← kubectl ["logs", "-n", ns, "-l", s!"app={foCfg.operatorName}", "--since-time", t0, "--tail=-1"] with
          | .ok o => pure o | .error _ => pure ""
        let flLog ← match ← kubectl ["logs", "-n", ns, other, "-c", "flared", "--since-time", t0] with
          | .ok o => pure o | .error _ => pure ""
        let committed := containsSubstr flLog "COMMITTED as replica"
        let notContinued := (opLog.splitOn "\n").any fun l =>
          containsSubstr l "HISTORY CONTINUATION" && (containsSubstr l s!"{other}" && containsSubstr l "is not continued"
            || containsSubstr l "no continuation, the replicas rebuild as before")
        let after := ((← stat oIp "rocksdb_staged_switched"), (← stat oIp "rocksdb_snapshot_bootstrap"))
        let eO ← stat oIp "rocksdb_source_epoch"
        let eN ← stat nIp "rocksdb_source_epoch"
        let items := ((← stat oIp "curr_items").bind String.toNat?)
        IO.eprintln s!"# new master {newM}, remaining {other}: rebuilt={rebuilt} (staged/snapshot {before.lookup other} -> {after}); committed={committed}; not-continued logged={notContinued}; epoch remaining {eO} new master {eN}; items {items}"
        if committed then return .fail s!"the remaining replica {other} committed a continued history with follow off"
        if !notContinued then return .fail "the operator did not log that the replica is not continued"
        if !rebuilt then return .fail s!"the remaining replica {other} did not rebuild within 300 s ({before.lookup other} -> {after})"
        if eO.isNone || eO != eN then return .fail s!"epochs differ after the rebuild: remaining {eO}, new master {eN}"
        if items.getD 0 < 300 then return .fail s!"the rebuilt replica has {items} items, want >= 300"
        return .pass }
  ]
}

-- ─── the operator's OnDelete rolling replaces the master by a handover (A4) ─

private def rlCfg : ClusterConfig :=
  { hcCfg with
    name := "hist-cont-rolling"
    «namespace» := "flare-hist-cont-rolling"
    debugPod := "debug-hist-cont-rolling" }

/-- The pods of the cluster as (name, uid, revision). -/
private def rlPods (cfg : ClusterConfig) : IO (List (String × String × String)) := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"cluster={cfg.name}", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.metadata.uid}|{.metadata.labels.controller-revision-hash}{\"\\n\"}{end}"] with
  | .ok o => return ((o.splitOn "\n").filterMap fun l => match l.trim.splitOn "|" with
      | [n, u, r] => if n.startsWith s!"{cfg.name}-nodes-" then some (n, u, r) else none
      | _ => none)
  | .error _ => return []

/-- A template change rolls the StatefulSet (OnDelete): the operator
    replaces the pods one at a time, the master last by a handover. The
    replica that is not the successor at that handover commits the
    continued history: its flared log shows `COMMITTED as replica` and no
    staged rebuild after it. Every key written before and during the roll
    is on the final master. -/
def handoverRollingSuite : TestSuite := {
  name := "history-continuation-handover-rolling"
  setup := do
    deployCluster rlCfg
    IO.sleep 50000
  teardown := cleanupCluster rlCfg
  onFailure := dumpClusterDiagnostics rlCfg.«namespace» s!"app={rlCfg.operatorName}"
  tests := [
    { name := "history continuation (A4): the operator's OnDelete rolling hands the master over and the replica that is not the successor COMMITS the continued history — no staged rebuild after the commit, every key on the final master"
      run := do
        let ns := rlCfg.«namespace»
        let stat := hcStatIn rlCfg
        let view := fun (_ : Unit) => do
          return parseNodeSync (← operatorTcpCmd rlCfg.debugPod ns rlCfg.operatorName rlCfg.operatorPort "node sync")
        let some mFqdn := findMasterFqdn (← view ()) 0 | return .fail "no Active P0 master"
        let some mIp ← getPodIp (podOf mFqdn) ns | return .fail "no master IP"
        if (← hcWriteIn rlCfg mIp "pre" 300) < 300 then return .fail "precondition writes not all STORED"
        let pods0 ← rlPods rlCfg
        if pods0.length != 3 then return .fail s!"precondition: want 3 pods, have {pods0.map (·.1)}"
        let t0 := (← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }).stdout.trim
        match ← kubectl ["patch", "statefulset", s!"{rlCfg.name}-nodes", "-n", ns, "--type=merge", "-p",
            s!"\{\"spec\":\{\"template\":\{\"metadata\":\{\"annotations\":\{\"e2e.flare.gree.net/roll\":\"{t0}\"}}}}}"] with
        | .error e => return .fail s!"could not change the StatefulSet template: {e}"
        | .ok _ => pure ()
        -- every pod replaced (new uid) and the cluster settled: 1 master, 2 Active slaves
        let rolled ← waitForCondition "every pod is replaced by the operator's rolling and the partition is 1 master + 2 Active slaves" 900 do
          let ps ← rlPods rlCfg
          let replaced := ps.length == 3 && pods0.all fun (n, u, _) => ps.any fun (n', u', _) => n' == n && u' != u
          let es ← view ()
          let slaves := (es.filter fun e => e.role == 1 && e.state == 0 && e.partition == 0).length
          return replaced && (findMasterFqdn es 0).isSome && slaves == 2
        if !rolled then return .fail "the rolling did not replace every pod and settle within 900 s"
        let some newM := (findMasterFqdn (← view ()) 0).map podOf | return .fail "no master after the rolling"
        let some nIp ← getPodIp newM ns | return .fail "no IP for the final master"
        let wrote ← hcWriteIn rlCfg nIp "post" 200
        -- the commit, and no staged rebuild after it, in the committing pod's log
        let mut committer : Option String := none
        let mut rebuiltAfter := false
        for (n, _, _) in ← rlPods rlCfg do
          let lg ← match ← kubectl ["logs", "-n", ns, n, "-c", "flared", "--since-time", t0] with
            | .ok o => pure o | .error _ => pure ""
          match lg.splitOn "COMMITTED as replica" with
          | _ :: rest@(_ :: _) =>
            committer := some n
            let tail := "COMMITTED as replica".intercalate rest
            rebuiltAfter := containsSubstr tail "staged rebuild may start"
          | _ => pure ()
        let items := ((← stat nIp "curr_items").bind String.toNat?)
        let opLog ← match ← kubectl ["logs", "-n", ns, "-l", s!"app={rlCfg.operatorName}", "--since-time", t0, "--tail=-1"] with
          | .ok o => pure o | .error _ => pure ""
        let cont := (opLog.splitOn "\n").filter fun l => containsSubstr l "HISTORY CONTINUATION"
        IO.eprintln s!"# final master {newM}; committer {committer}, staged rebuild after the commit={rebuiltAfter}; post writes {wrote}/200; items on the master {items}\n# continuation: {cont.map (·.trim.take 200)}"
        let some c := committer | return .fail "no replica committed a continued history during the rolling"
        if rebuiltAfter then return .fail s!"{c} started a staged rebuild after it committed the continued history"
        if wrote < 200 then return .fail s!"post-rolling writes {wrote}/200"
        if items.getD 0 < 500 then return .fail s!"the final master has {items} items, want >= 500"
        return .pass }
  ]
}

-- ─── recovery: the successor stops during committingReplicas (A3b) ─────

private def rcCfg (tag : String) : ClusterConfig :=
  { hcCfg with
    name := s!"hist-cont-{tag}"
    «namespace» := s!"flare-hist-cont-{tag}"
    debugPod := s!"debug-hist-cont-{tag}"
    replicas := 4
    operatorEnv := hcCfg.operatorEnv ++ [("FLARE_TEST_BROADCAST_SKIP_FILE", "/tmp/bskip")] }

private def rcOpExec (cfg : ClusterConfig) (cmd : String) : IO (Except String String) := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.name}"] with
  | .ok o => kubectl ["exec", "-n", cfg.«namespace», o.trim, "--", "sh", "-c", cmd]
  | .error e => return .error e

private def rcOpLog (cfg : ClusterConfig) (since : String) : IO String := do
  match ← kubectl ["logs", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "--since-time", since, "--tail=-1"] with
  | .ok o => return o
  | .error _ => return ""

/-- The successor of the p0 handover once it is committingReplicas: the
    prepare line `HISTORY CONTINUATION p0 <hid>: prepared <succ> (E'=…`
    (the move to committingReplicas is recorded by afterPrepare, with no
    phase line: 42144453260). -/
private def rcSuccessor (log : String) : Option String :=
  (log.splitOn "\n").findSome? fun l =>
    if containsSubstr l "HISTORY CONTINUATION p0 " && containsSubstr l ": prepared " && containsSubstr l "(E'=" then
      match (l.splitOn ": prepared ").drop 1 |>.head? with
      | some rest => some (podOf ((rest.splitOn " ").head?.getD "").trim)
      | none => none
    else none

/-- Every pod's own_role, by pod name (unreadable pods left out). A master
    that is not active (the handover's master/down placeholder: it applies
    no write, 42147154242) reads `master-<state>`, so "master" = an ACTIVE
    master that takes writes. -/
private def rcRoles (cfg : ClusterConfig) (pods : List String) : IO (List (String × String)) := do
  let mut out := []
  for pd in pods do
    if let some ip ← getPodIp pd cfg.«namespace» then
      let st := statOf (← hcCmdIn cfg ip "stats")
      if let some r := st "own_role" then
        let state := (st "own_state").getD "unknown"
        out := out ++ [(pd, if r == "master" && state != "active" then s!"master-{state}" else r)]
  return out

/-- Setup shared by the two recovery suites: 1 master + 3 slaves, 300 keys
    followed by every slave, V2 withheld from the last slave (map order), the
    master's graceful delete asked once (its handover starts), and the wait
    until the handover is committingReplicas. Returns (master pod, successor
    pod, slaves, t0). -/
private def rcStart (cfg : ClusterConfig) : IO (Except String (String × String × List String × String)) := do
  let ns := cfg.«namespace»
  -- 4 pods take longer than the 50 s setup (42145565770: 2 of 3 slaves Active)
  let view := fun (_ : Unit) => do
    return parseNodeSync (← operatorTcpCmd cfg.debugPod ns cfg.operatorName cfg.operatorPort "node sync")
  let settled ← waitForCondition "1 Active P0 master and 3 Active slaves" 240 do
    let es ← view ()
    return (findMasterFqdn es 0).isSome && (es.filter fun e => e.role == 1 && e.state == 0 && e.partition == 0).length == 3
  if !settled then return .error "precondition: the cluster did not reach 1 master + 3 Active slaves within 240 s"
  let es ← view ()
  let some mFqdn := findMasterFqdn es 0 | return .error "no Active P0 master"
  let slaves := (es.filter fun e => e.role == 1 && e.state == 0 && e.partition == 0).map (podOf ·.fqdn)
  if slaves.length != 3 then return .error s!"precondition: want 3 Active slaves, have {slaves}"
  let mPod := podOf mFqdn
  let some mIp ← getPodIp mPod ns | return .error "no master IP"
  if (← hcWriteIn cfg mIp "pre" 300) < 300 then return .error "precondition writes not all STORED"
  let caught ← waitForCondition "every slave's follow cursor reaches the master's last sequence" 180 do
    let some l := (← hcStatIn cfg mIp "rocksdb_latest_sequence_number").bind String.toNat? | return false
    let mut ok := true
    for r in slaves do
      let some ip ← getPodIp r ns | return false
      ok := ok && ((← hcStatIn cfg ip "rocksdb_repl_last_lsn").bind String.toNat?) == some l
    return ok
  if !caught then return .error "precondition: the slaves did not catch up by WAL follow"
  let some withheld := slaves.getLast? | return .error "no slave"
  match ← rcOpExec cfg s!"echo {withheld} > /tmp/bskip" with
  | .error e => return .error s!"could not arm the broadcast skip: {e}"
  | .ok _ => pure ()
  let t0 := (← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }).stdout.trim
  discard <| kubectl ["delete", "pod", mPod, "-n", ns, "--wait=false"]
  let mut succ : Option String := none
  for _ in [0:120] do
    if let some s ← (rcSuccessor <$> rcOpLog cfg t0) then
      if containsSubstr (← rcOpLog cfg t0) "V2 sent to the prepared replicas" then
        succ := some s
        break
    IO.sleep 250
  let some sPod := succ | return .error "the handover did not reach committingReplicas with V2 sent within 30 s (no prepare line and V2 send in the operator log)"
  return .ok (mPod, sPod, slaves, t0)

/-- A3b (addendum 2 §3 / 5): V2 reaches one prepared replica (the other is
    withheld); the successor is then deleted gracefully (override) and its
    kubelet confirms the stop. The committed replica replaces it (V3), at
    most one pod answers master at any time, the old successor never again,
    and every key is on the new master. -/
def recoveryReplaceSuite : TestSuite :=
  let cfg := rcCfg "rc-replace"
  { name := "history-continuation-recovery-replace"
    setup := do
      deployCluster cfg
      IO.sleep 50000
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    tests := [
      { name := "history continuation recovery (A3b): the successor's kubelet-confirmed stop during committingReplicas -> the committed replica becomes the master (V3), never two masters, the old successor fenced, every key kept"
        run := do
          let ns := cfg.«namespace»
          let (mPod, sPod, slaves, t0) ← match ← rcStart cfg with
            | .ok x => pure x
            | .error e => return .fail e
          let all := mPod :: slaves
          -- the successor stops: override + graceful delete; its kubelet confirms
          let sUid ← match ← kubectlGetJsonpath "pod" sPod ns "{.metadata.uid}" with
            | .ok o => pure o.trim | .error e => return .fail s!"no successor uid: {e}"
          discard <| kubectl ["annotate", "pod", sPod, "-n", ns, "--overwrite", s!"flare.gree.net/delete-override={sUid}"]
          discard <| kubectl ["delete", "pod", sPod, "-n", ns, "--grace-period=1", "--wait=false"]
          -- sample every pod's own_role until the replacement is the master
          let mut twoMasters : List (List (String × String)) := []
          let mut succAgain := false
          let mut replaced := false
          for _ in [0:90] do
            let rs ← rcRoles cfg all
            let ms := rs.filter (·.2 == "master")
            if ms.length > 1 then twoMasters := twoMasters ++ [rs]
            let log ← rcOpLog cfg t0
            if containsSubstr log "replaces it" then replaced := true
            if replaced && ms.any (·.1 == sPod) then
              -- a NEW pod under the successor's name as master would be the fault
              succAgain := true
            if replaced && ms.length == 1 && ms.any (·.1 != sPod) then break
            IO.sleep 1000
          discard <| rcOpExec cfg "rm -f /tmp/bskip"
          let log ← rcOpLog cfg t0
          let some newM := ((← rcRoles cfg all).find? (·.2 == "master")).map (·.1)
            | return .fail s!"no master after the recovery (replaced={replaced})"
          let flLog ← match ← kubectl ["logs", "-n", ns, newM, "-c", "flared", "--since-time", t0] with
            | .ok o => pure o | .error _ => pure ""
          let some nIp ← getPodIp newM ns | return .fail "no IP for the new master"
          let items := ((← hcStatIn cfg nIp "curr_items").bind String.toNat?)
          let wrote ← hcWriteIn cfg nIp "post" 200
          let lines := (log.splitOn "\n").filter fun l => containsSubstr l "HANDOVER p0" || containsSubstr l "NODE GUARD: the kubelet"
          IO.eprintln s!"# master {mPod}, successor {sPod}, new master {newM}; replaced={replaced}; two-master samples {twoMasters.length}; successor master again={succAgain}; items {items}; post {wrote}/200\n# {lines.map (·.trim.take 200)}"
          if !replaced then return .fail "the committed replica did not replace the stopped successor"
          if !containsSubstr log "NODE GUARD: the kubelet" then return .fail "the kubelet's stop was not recorded by the node guard"
          if !twoMasters.isEmpty then return .fail s!"two pods answered master: {twoMasters}"
          if succAgain then return .fail s!"the stopped successor's name {sPod} answered master after the replacement"
          if newM == sPod || newM == mPod then return .fail s!"the new master is {newM}, not a committed replica"
          if !containsSubstr flLog "COMMITTED as replica" then return .fail s!"the new master {newM} had not committed the continued history"
          if items.getD 0 < 300 then return .fail s!"the new master has {items} items, want >= 300"
          if wrote < 200 then return .fail s!"post-recovery writes {wrote}/200"
          return .pass }
    ] }

/-- A3b (addendum 5 §2-3): the successor is force-deleted (no kubelet
    confirm reaches the guard). The handover HALTS with CRITICAL and the
    Event FlareHandoverSuccessorUnfenced; no other replica is promoted and no
    pod answers master in the window. -/
def recoveryUnfencedSuite : TestSuite :=
  let cfg := rcCfg "rc-unfenced"
  { name := "history-continuation-recovery-unfenced"
    setup := do
      deployCluster cfg
      IO.sleep 50000
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    tests := [
      { name := "history continuation recovery (A3b): a force-deleted successor (no kubelet confirm) halts the handover — CRITICAL + Event, nothing promoted, no pod answers master"
        run := do
          let ns := cfg.«namespace»
          let (mPod, sPod, slaves, t0) ← match ← rcStart cfg with
            | .ok x => pure x
            | .error e => return .fail e
          let all := mPod :: slaves
          let sUid ← match ← kubectlGetJsonpath "pod" sPod ns "{.metadata.uid}" with
            | .ok o => pure o.trim | .error e => return .fail s!"no successor uid: {e}"
          discard <| kubectl ["annotate", "pod", sPod, "-n", ns, "--overwrite", s!"flare.gree.net/delete-override={sUid}"]
          discard <| kubectl ["delete", "pod", sPod, "-n", ns, "--force", "--grace-period=0", "--wait=false"]
          let mut masters : List (List (String × String)) := []
          let mut halted := false
          for _ in [0:60] do
            let rs ← rcRoles cfg all
            if rs.any (·.2 == "master") then masters := masters ++ [rs]
            if containsSubstr (← rcOpLog cfg t0) "HALTED" then halted := true
            IO.sleep 1000
          -- the old master (the master/down placeholder) applies no write
          -- while halted: a write waits for a master and is not STORED
          let oldStored ← match ← getPodIp mPod ns with
            | some ip => hcWriteIn cfg ip "halted" 1
            | none => pure 0
          let log ← rcOpLog cfg t0
          let ev ← match ← kubectl ["get", "events", "-n", ns, "--field-selector", "reason=FlareHandoverSuccessorUnfenced", "-o", "name"] with
            | .ok o => pure (!o.trim.isEmpty) | .error _ => pure false
          let lines := (log.splitOn "\n").filter fun l => containsSubstr l "HANDOVER p0" || containsSubstr l "NODE GUARD"
          IO.eprintln s!"# master {mPod}, successor {sPod}: halted={halted}, event={ev}, active-master samples {masters.length} ({masters.take 2}), write to the old master STORED={oldStored}\n# {lines.map (·.trim.take 200)}"
          discard <| rcOpExec cfg "rm -f /tmp/bskip"
          if !halted then return .fail "the handover did not halt (no HALTED reason in the operator log)"
          if !containsSubstr log "CRITICAL: HANDOVER p0" then return .fail "no CRITICAL line for the halted handover"
          if !ev then return .fail "no FlareHandoverSuccessorUnfenced Event"
          if containsSubstr log "replaces it" then return .fail "a replica replaced the successor without a kubelet-confirmed stop"
          if !masters.isEmpty then return .fail s!"a pod answered as an ACTIVE master while the successor's stop was unconfirmed: {masters.take 3}"
          if oldStored != 0 then return .fail "the old master (the master/down placeholder) STORED a write while the handover was halted"
          return .pass }
    ] }

-- ─── break-glass of a halted handover (A3c, addenda 6–10) ─────

/-- `kubectl apply` of a manifest (stdin through a temp file). -/
private def bgApply (manifest : String) : IO (Except String String) := do
  let path := s!"/tmp/flare-e2e-bg-{← IO.monoNanosNow}.yaml"
  IO.FS.writeFile path manifest
  let r ← kubectl ["apply", "-f", path]
  try IO.FS.removeFile path catch _ => pure ()
  return r

/-- A3c: the handover halts (the successor force-deleted); a user who may
    update the FlareCluster but not break-glass is refused by the webhook;
    an approver's value for another hid is receipted but not used; the
    right value is consumed once (fencedBy, Event), the committed replica
    replaces the successor, the annotations are removed, and the same value
    applied again changes nothing. -/
def recoveryBreakGlassSuite : TestSuite :=
  let cfg := rcCfg "rc-bglass"
  { name := "history-continuation-recovery-breakglass"
    setup := do
      deployCluster cfg
      IO.sleep 50000
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    tests := [
      { name := "history continuation break-glass (A3c): refused without the break-glass permission, another hid not used, the right value consumed once, the committed replica replaces the silent successor"
        run := do
          let ns := cfg.«namespace»
          let cr := cfg.name
          -- an updater (update only) and an approver (update + break-glass)
          let rbac := s!"apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: \{name: fc-updater, namespace: {ns}}
rules:
- apiGroups: [flare.gree.net]
  resources: [flareclusters]
  verbs: [get, list, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: \{name: fc-updater, namespace: {ns}}
subjects:
- \{kind: User, name: updater, apiGroup: rbac.authorization.k8s.io}
- \{kind: User, name: approver, apiGroup: rbac.authorization.k8s.io}
roleRef: \{kind: Role, name: fc-updater, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: \{name: fc-approver, namespace: {ns}}
subjects:
- \{kind: User, name: approver, apiGroup: rbac.authorization.k8s.io}
roleRef: \{kind: Role, name: flare-operator-handover-fence, apiGroup: rbac.authorization.k8s.io}
"
          if let .error e ← bgApply rbac then return .fail s!"could not create the test RBAC: {e}"
          let (mPod, sPod, slaves, t0) ← match ← rcStart cfg with
            | .ok x => pure x
            | .error e => return .fail e
          let sUid ← match ← kubectlGetJsonpath "pod" sPod ns "{.metadata.uid}" with
            | .ok o => pure o.trim | .error e => return .fail s!"no successor uid: {e}"
          discard <| kubectl ["annotate", "pod", sPod, "-n", ns, "--overwrite", s!"flare.gree.net/delete-override={sUid}"]
          discard <| kubectl ["delete", "pod", sPod, "-n", ns, "--force", "--grace-period=0", "--wait=false"]
          let halted ← waitForCondition "the handover halts (CRITICAL … HALTED)" 60 do
            return containsSubstr (← rcOpLog cfg t0) "HALTED"
          if !halted then return .fail "the handover did not halt after the successor's force delete"
          let log0 ← rcOpLog cfg t0
          -- the hid and the successor's binding from the operator's log
          let hid := ((log0.splitOn "\n").findSome? fun l =>
            if containsSubstr l "HISTORY CONTINUATION p0 " && containsSubstr l ": prepared " then
              ((l.splitOn "HISTORY CONTINUATION p0 ").drop 1).head?.bind fun x => (x.splitOn ":").head?
            else none).getD ""
          let binding := ((log0.splitOn "\n").findSome? fun l =>
            if containsSubstr l "PROMOTION EVIDENCE (handover demote" && containsSubstr l s!"{sPod}." then
              ((l.splitOn " binding ").drop 1).head?.map (·.trim)
            else none).getD ""
          let parts := binding.splitOn "|"
          if hid.isEmpty || parts.length != 3 then return .fail s!"could not read the hid ({hid}) or the successor binding ({binding})"
          let value := fun (ap h : String) => s!"{ap}/{h}/{"/".intercalate parts}"
          let anno := fun (who v : String) => kubectl ["annotate", "flarecluster", cr, "-n", ns, "--overwrite", "--as", who, s!"flare.gree.net/handover-fenced={v}"]
          -- 1. update permission only: refused by the webhook
          let r1 ← anno "updater" (value "E2E-1" hid)
          let refused := match r1 with | .error e => containsSubstr e "break-glass" | .ok _ => false
          -- 2. the approver, another hid: receipted, not used
          let r2 ← anno "approver" (value "E2E-2" "p0-a9-1")
          IO.sleep 5000
          let log2 ← rcOpLog cfg t0
          let notUsed := containsSubstr log2 "is not used: the value names handover p0-a9-1"
          let replacedEarly := containsSubstr log2 "replaces it"
          let rcptOf := fun (_ : Unit) => do
            match ← kubectlGetJsonpath "flarecluster" cr ns "{.metadata.annotations.flare\\.gree\\.net/handover-fenced-receipt}" with
            | .ok o => pure o.trim | .error _ => pure ""
          -- 2b. an authorized requester rewrites only the receipt: the webhook
          -- puts the stored one back
          let rcpt0 ← rcptOf ()
          let tLog0 ← rcOpLog cfg t0
          let rw ← kubectl ["annotate", "flarecluster", cr, "-n", ns, "--overwrite", "--as", "approver",
            s!"flare.gree.net/handover-fenced-receipt=E2E-2/p0-a9-1/r/approver/u/{String.mk (List.replicate 64 'a')}"]
          let rcpt1 ← rcptOf ()
          IO.sleep 2000
          -- the UPDATE was admitted (not refused) AND the webhook said it
          -- replaced the requester's receipt (review of e4b53c4: a refused
          -- update would also leave the stored receipt)
          let replacedLogged : Bool := (((← rcOpLog cfg t0).splitOn "a receipt written by approver was replaced with the stored one").length) >
            ((tLog0.splitOn "a receipt written by approver was replaced with the stored one").length)
          let restored := rw.isOk && replacedLogged && !rcpt0.isEmpty && rcpt1 == rcpt0
          -- 2c. the webhook removed: a value for THIS hid with a forged
          -- receipt goes in unchecked — the operator must not use it
          let mwc := s!"flare-handover-fence-{ns}"
          let saved := s!"/tmp/flare-e2e-mwc-{ns}.json"
          let sv ← IO.Process.output { cmd := "sh", args := #["-c",
            s!"kubectl get mutatingwebhookconfiguration {mwc} -o json | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.generation,.metadata.managedFields)' > {saved}"] }
          if sv.exitCode != 0 then return .fail s!"could not save the mutating webhook: {sv.stderr.trim}"
          discard <| kubectl ["delete", "mutatingwebhookconfiguration", mwc]
          IO.sleep 3000
          let forgedValue := value "E2E-F" hid
          discard <| kubectl ["annotate", "flarecluster", cr, "-n", ns, "--overwrite",
            s!"flare.gree.net/handover-fenced={forgedValue}",
            s!"flare.gree.net/handover-fenced-receipt=E2E-F/{hid}/r/admin/u/{String.mk (List.replicate 64 '0')}"]
          IO.sleep 8000
          let logF ← rcOpLog cfg t0
          let forgedRefused := containsSubstr logF s!"the handover-fenced value {forgedValue} is not used: the receipt is not the webhook's"
          let forgedUsed := containsSubstr logF "break-glass E2E-F/"
          discard <| kubectl ["annotate", "flarecluster", cr, "-n", ns, "flare.gree.net/handover-fenced-", "flare.gree.net/handover-fenced-receipt-"]
          let rs ← IO.Process.output { cmd := "kubectl", args := #["create", "-f", saved] }
          if rs.exitCode != 0 then return .fail s!"could not restore the mutating webhook: {rs.stderr.trim}"
          IO.sleep 3000
          -- 3. the right value, applied twice at once: consumed once, the
          -- committed replica takes over
          let tA ← IO.asTask (anno "approver" (value "E2E-3" hid))
          let tB ← IO.asTask (anno "approver" (value "E2E-3" hid))
          let r3 := match ← IO.wait tA, ← IO.wait tB with
            | .ok (.ok a), _ => Except.ok a
            | _, .ok (.ok b) => .ok b
            | .ok (.error e), _ => .error e
            | .error e, _ => .error s!"{e}"
          let consumed ← waitForCondition "the break-glass is consumed and a committed replica replaces the successor" 90 do
            let l ← rcOpLog cfg t0
            return containsSubstr l "break-glass E2E-3/" && containsSubstr l "replaces it"
          let annGone ← waitForCondition "the consumed annotations are removed" 60 do
            match ← kubectlGetJsonpath "flarecluster" cr ns "{.metadata.annotations}" with
            | .ok o => return !containsSubstr o "handover-fenced"
            | .error _ => return false
          let fencedBy ← match ← kubectlGetJsonpath "flarecluster" cr ns "{.status.handovers.entries[0].fencedBy}" with
            | .ok o => pure o | .error _ => pure ""
          let approvals ← match ← kubectlGetJsonpath "flarecluster" cr ns "{.status.handoverApprovals}" with
            | .ok o => pure o | .error _ => pure ""
          let ev ← match ← kubectl ["get", "events", "-n", ns, "--field-selector", "reason=FlareHandoverFenced", "-o", "name"] with
            | .ok o => pure (!o.trim.isEmpty) | .error _ => pure false
          -- 4. the same value again: nothing more (one consume)
          discard <| anno "approver" (value "E2E-3" hid)
          IO.sleep 5000
          let logEnd ← rcOpLog cfg t0
          let consumes := ((logEnd.splitOn "break-glass E2E-3/").length) - 1
          discard <| rcOpExec cfg "rm -f /tmp/bskip"
          let all := mPod :: slaves
          let roles ← rcRoles cfg all
          IO.eprintln s!"# successor {sPod} binding {binding}, hid {hid}; updater refused={refused} ({r1}); other hid: {r2.isOk} not used={notUsed}; receipt rewrite restored={restored}; forged receipt without the webhook: refused={forgedRefused} used={forgedUsed}; right value (twice at once): {r3.isOk} consumed={consumed}, annotations removed={annGone}, fencedBy={fencedBy.take 200}, approvals {approvals}, event={ev}; consumes {consumes}; roles {roles}"
          if !refused then return .fail s!"the updater (no break-glass permission) was not refused by the webhook: {r1}"
          if replacedEarly then return .fail "the successor was replaced before the right value"
          if !notUsed then return .fail "a value for another hid was not reported as not used"
          if !restored then return .fail s!"a receipt rewritten by the requester was not put back by the webhook (update admitted={rw.isOk}, webhook log={replacedLogged}, {rcpt0.take 60} -> {rcpt1.take 60})"
          if forgedUsed then return .fail "a forged receipt (the webhook removed) was CONSUMED"
          if !forgedRefused then return .fail "a forged receipt (the webhook removed) was not reported as not the webhook's"
          if !consumed then return .fail "the right value was not consumed (no replacement)"
          if !annGone then return .fail "the consumed annotations were not removed"
          if !containsSubstr fencedBy "approver" then return .fail s!"fencedBy does not name the approver: {fencedBy}"
          if !containsSubstr approvals "E2E-3" then return .fail s!"the approval id was not recorded: {approvals}"
          if !ev then return .fail "no FlareHandoverFenced Event"
          if consumes != 1 then return .fail s!"the value was consumed {consumes} times"
          if (roles.filter (·.2 == "master")).length != 1 then return .fail s!"not exactly one master after the replacement: {roles}"
          return .pass }
    ] }

-- ─── the operator restarts while the replicas commit (A4) ─────

/-- A4: the operator pod is deleted while the handover is committingReplicas
    (V2 withheld from one prepared replica keeps it there). The new operator
    resumes from status.handovers: the successor becomes the one active
    master, the committed replica keeps its copy (no staged rebuild after its
    commit), every key is kept. -/
def recoveryOperatorRestartSuite : TestSuite :=
  let cfg := rcCfg "rc-oprestart"
  { name := "history-continuation-recovery-operator-restart"
    setup := do
      deployCluster cfg
      IO.sleep 50000
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    tests := [
      { name := "history continuation (A4): an operator restart during committingReplicas resumes from status.handovers — the successor is the one active master, the committed replica keeps its copy, every key kept"
        run := do
          let ns := cfg.«namespace»
          let (mPod, sPod, slaves, t0) ← match ← rcStart cfg with
            | .ok x => pure x
            | .error e => return .fail e
          let all := mPod :: slaves
          let opUid ← match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.uid}"] with
            | .ok o => pure o.trim | .error e => return .fail s!"no operator pod: {e}"
          match ← kubectl ["delete", "pods", "-n", ns, "-l", s!"app={cfg.operatorName}", "--wait=false"] with
          | .error e => return .fail s!"could not delete the operator pod: {e}"
          | .ok _ => pure ()
          -- the withheld replica gets the maps again once a new operator runs
          let back ← waitForCondition "a new operator pod is Running" 180 do
            match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={range .items[*]}{.metadata.uid} {.status.phase}{\"\\n\"}{end}"] with
            | .ok o => return (o.splitOn "\n").any fun l => !containsSubstr l opUid && containsSubstr l "Running"
            | .error _ => return false
          if !back then return .fail "no new operator pod within 180 s"
          discard <| rcOpExec cfg "rm -f /tmp/bskip"
          let mut twoMasters : List (List (String × String)) := []
          let mut settled := false
          for _ in [0:240] do
            let rs ← rcRoles cfg all
            let ms := rs.filter (·.2 == "master")
            if ms.length > 1 then twoMasters := twoMasters ++ [rs]
            if ms.length == 1 && ms.any (·.1 == sPod) then
              settled := true
              break
            IO.sleep 1000
          let rs ← rcRoles cfg all
          let some newM := (rs.find? (·.2 == "master")).map (·.1) | return .fail s!"no active master after the restart: {rs}"
          let some nIp ← getPodIp newM ns | return .fail "no IP for the master"
          let items := ((← hcStatIn cfg nIp "curr_items").bind String.toNat?)
          let wrote ← hcWriteIn cfg nIp "post" 200
          -- the replica that committed before the restart: no staged rebuild after it
          let mut committer : Option String := none
          let mut rebuiltAfter := false
          for n in slaves do
            if n == sPod then continue
            let lg ← match ← kubectl ["logs", "-n", ns, n, "-c", "flared", "--since-time", t0] with
              | .ok o => pure o | .error _ => pure ""
            match lg.splitOn "COMMITTED as replica" with
            | _ :: rest@(_ :: _) =>
              committer := some n
              rebuiltAfter := containsSubstr ("COMMITTED as replica".intercalate rest) "staged rebuild may start"
            | _ => pure ()
          let opLog ← rcOpLog cfg t0
          let resumed := (opLog.splitOn "\n").filter fun l => containsSubstr l "HANDOVER p0" && containsSubstr l " -> "
          IO.eprintln s!"# successor {sPod}, master now {newM} (settled={settled}); committer {committer} rebuilt after={rebuiltAfter}; two-master samples {twoMasters.length}; items {items}; post {wrote}/200\n# new operator: {resumed.map (·.trim.take 200)}"
          if !settled then return .fail s!"the successor {sPod} is not the one active master after the restart ({rs})"
          if !twoMasters.isEmpty then return .fail s!"two active masters: {twoMasters.take 2}"
          let some c := committer | return .fail "no replica committed the continued history"
          if rebuiltAfter then return .fail s!"{c} started a staged rebuild after its commit"
          if items.getD 0 < 300 then return .fail s!"the master has {items} items, want >= 300"
          if wrote < 200 then return .fail s!"post-restart writes {wrote}/200"
          return .pass }
    ] }

end FlareOperator.E2E.Tests.HistoryContinuation
