/-
  Resource behaviour of the V capture (`repl_snapshot` checkpoint stream,
  scripts/flare_v_capture_kind.py — kind only). A checkpoint is logically
  read-only but not free: a forced memtable flush, file deletions pinned for
  the serve, hard links that pin space (memory on tmpfs) until the stream
  ends, and ONE serve slot per node (a concurrent replica reseed waits
  "busy"). What this suite pins down on a small kind cluster:

    1. while a (throttled) serve runs: the slot is taken
       (`rocksdb_snapshot_serving` 1, one snapshot.serve.* directory) and a
       capture started meanwhile is refused "busy" — it fails, it does not
       wait or share;
    2. a serve whose reader goes away mid-stream is cleaned up (slot
       released, directory removed) — the cleanup is driven by the failed
       write when the connection closes. A reader that stays connected but
       stops reading is NOT bounded by flared (connection_tcp write poll
       loops without a deadline): only the client side bounds it (the kind
       driver runs `timeout 120` in the pod);
    3. a capture under client write load: every write is acknowledged, the
       write time with and without a concurrent capture is printed (kind,
       one node, small data — not a capacity measurement), and the slot and
       directory are released afterwards.
  No space reserve is consulted before a checkpoint (not implemented); on
  tmpfs the pin grows with compaction during a long transfer.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.VCaptureResources

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "vcr"
  «namespace» := "flare-vcr"
  partitions := 1
  replicas := 1
  operatorName := "flare-operator-vcr"
  debugPod := "debug-vcr"
  storageBackend := "rocksdb"
  -- a capture needs the reserve (unset = refused); in the CR so the
  -- no-space test can raise it through the operator
  reserveInCr := true
}

private def kindNode : String := "flare-e2e-control-plane"


private def dataDir : String := "/tmp/flare"

private def execInPod (pod ns : String) (cmd : List String) : IO (Except String String) :=
  kubectl (["exec", pod, "-n", ns, "--"] ++ cmd)

private def masterPod : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return findMasterPod (parseNodeSync sync) 0

private def podStat (pod name : String) : IO (Option String) := do
  match ← execInPod pod cfg.«namespace» ["bash", "-c", "exec 3<>/dev/tcp/localhost/12121; printf 'stats\\r\\n' >&3; timeout 5 bash -c 'while IFS= read -r l; do printf \"%s\\n\" \"$l\"; case \"$l\" in END*) break;; esac; done' <&3"] with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let t := l.trim.replace "\r" ""
      if t.startsWith s!"STAT {name} " then some (t.drop s!"STAT {name} ".length).trim else none

private def serveDirs (pod : String) : IO Nat := do
  match ← execInPod pod cfg.«namespace» ["bash", "-c", s!"ls -d {dataDir}/snapshot.serve.* 2>/dev/null | wc -l"] with
  | .ok o => return o.trim.toNat?.getD 99
  | .error _ => return 99

private def scriptsDir : IO String := do
  if ← System.FilePath.pathExists "../scripts/flare_v_capture_kind.py" then return "../scripts"
  else return "scripts"

/-- Store `n` keys of `len` random letters (not compressible to nothing) in
    one pipeline; (STORED count, ms). -/
private def bulkWriteLen (ip keyPrefix : String) (n len : Nat) : IO (Nat × Nat) := do
  let t0 ← IO.monoMsNow
  let cmd := s!"(awk 'BEGIN\{srand(); for(i=0;i<{n};i++)\{v=\"\"; for(j=0;j<{len};j++) v=v sprintf(\"%c\", 97+int(rand()*26)); printf \"set {keyPrefix}_%d 0 0 {len}\\r\\n%s\\r\\n\", i, v}}'; sleep 2) | nc -w 120 {ip} {cfg.flarePort} | grep -c STORED"
  let stored ← match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
    | .ok o => pure (o.trim.toNat?.getD 0)
    | .error _ => pure 0
  return (stored, (← IO.monoMsNow) - t0)

private def bulkWrite (ip keyPrefix : String) (n : Nat) : IO (Nat × Nat) :=
  bulkWriteLen ip keyPrefix n 200

private def released (pod : String) : IO Bool :=
  waitForCondition "serve slot released and directory removed" 90 do
    return (← podStat pod "rocksdb_snapshot_serving") == some "0" && (← serveDirs pod) == 0

private def captureStat (pod : String) : IO String := do
  let l ← podStat pod "rocksdb_capture_last"
  let a ← podStat pod "rocksdb_capture_aborted"
  let r ← podStat pod "rocksdb_capture_refused"
  let s ← podStat pod "rocksdb_capture_served"
  return s!"last={l.getD "?"} served={s.getD "?"} refused={r.getD "?"} aborted={a.getD "?"}"

/-- A raw capture request in the pod; `reader` is the shell that holds fd 3
    afterwards (e.g. `sleep 90` = connected, never reads). -/
private def spawnRaw (pod req reader : String) :
    IO (IO.Process.Child { stdout := .null, stderr := .null : IO.Process.StdioConfig }) := do
  let c := s!"exec 3<>/dev/tcp/localhost/12121; printf '{req}\\r\\n' >&3; {reader}"
  IO.Process.spawn { cmd := "kubectl", args := #["exec", pod, "-n", cfg.«namespace», "--", "bash", "-c", c],
                     stdout := .null, stderr := .null }

private def waitLast (pod want : String) (sec : Nat) : IO Bool :=
  waitForCondition s!"rocksdb_capture_last = {want}" sec do
    return (← podStat pod "rocksdb_capture_last") == some want

private def setReserve (n : Nat) : IO Bool := do
  let patch := s!"\{\"spec\":\{\"rocksdb\":\{\"rebuildReserveBytes\":{n}}}}"
  let _ ← kubectl ["patch", "flarecluster", cfg.name, "-n", cfg.«namespace», "--type", "merge", "-p", patch]
  -- the operator rewrites extra.conf and SIGHUPs; the ConfigMap reaches the
  -- pod within ~2 min (kubelet sync)
  waitForCondition s!"rocksdb_rebuild_reserve_bytes = {n} on every pod" 300 do
    let some pod ← masterPod | return false
    return (← podStat pod "rocksdb_rebuild_reserve_bytes") == some (toString n)

/-- kill -9 flared in `pod` from the kind node (pid 1 in the pod ignores
    signals from inside); found by the pod UID in its cgroup. -/
private def killFlared (pod : String) : IO String := do
  let uid ← match ← kubectlGetJsonpath "pod" pod cfg.«namespace» "{.metadata.uid}" with
    | .ok u => pure u.trim
    | .error _ => pure ""
  if uid.isEmpty then return "no uid"
  let u2 := uid.replace "-" "_"
  let out ← IO.Process.output { cmd := "docker", args := #["exec", kindNode, "sh", "-c",
    s!"n=0; for p in $(pgrep -x flared); do if grep -q -e '{uid}' -e '{u2}' /proc/$p/cgroup 2>/dev/null; then kill -9 $p && n=$((n+1)); fi; done; echo killed=$n"] }
  return out.stdout.trim

def suite : TestSuite := {
  name := "v-capture-resources"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let ok ← waitForStable cfg 50
    if !ok then throw (IO.userError "cluster did not stabilize")
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  teardown := cleanupCluster cfg
  tests := [
    { name := "while a serve runs the single slot is taken and a capture started meanwhile is refused busy; a serve whose reader goes away is cleaned up (slot released, directory removed)"
      run := do
        let some pod ← masterPod | return .fail "no master"
        let some ip ← getPodIp pod cfg.«namespace» | return .fail "no master IP"
        let (stored, _) ← bulkWrite ip "vcr_seed" 3000
        if stored != 3000 then return .fail s!"seed data: {stored}/3000 STORED"
        -- a throttled serve (20 KB/s requested) whose reader leaves after 15 s.
        -- The sender sleeps after each chunk for the throttle, so the cleanup
        -- happens at its NEXT write: the release can lag the reader by up to
        -- one chunk's sleep (printed).
        let slowCmd := "exec 3<>/dev/tcp/localhost/12121; printf 'repl_snapshot 20\\r\\n' >&3; timeout 15 cat <&3 >/dev/null"
        let slowArgs : Array String := #["exec", pod, "-n", cfg.«namespace», "--", "bash", "-c", slowCmd]
        let slow ← IO.Process.spawn { cmd := "kubectl", args := slowArgs, stdout := .null, stderr := .null }
        let serving ← waitForCondition "the serve took the slot" 15 do
          return (← podStat pod "rocksdb_snapshot_serving") == some "1"
        let dirs ← serveDirs pod
        let sd ← scriptsDir
        let busyArgs : Array String := #[s!"{sd}/flare_v_capture_kind.py", "--ns", cfg.«namespace», "--out", "/tmp/e2e-vcr/busy", pod]
        let busy ← IO.Process.output { cmd := "python3", args := busyArgs }
        IO.eprintln s!"# during the serve: serving {serving}, serve dirs {dirs}; concurrent capture exit {busy.exitCode}: {busy.stderr.trim.take 300}"
        let _ ← slow.wait
        let tLeft ← IO.monoMsNow
        let rel ← released pod
        IO.eprintln s!"# release took ~{((← IO.monoMsNow) - tLeft) / 1000} s after the reader left"
        IO.eprintln s!"# after the reader left: serving {← podStat pod "rocksdb_snapshot_serving"}, serve dirs {← serveDirs pod}"
        if !serving then return .fail "the throttled serve never took the slot (rocksdb_snapshot_serving stayed 0)"
        if dirs != 1 then return .fail s!"{dirs} snapshot.serve.* directories during the serve, want 1"
        if busy.exitCode == 0 then return .fail "a capture during another serve SUCCEEDED (want refused busy)"
        if !containsSubstr busy.stderr "busy" then return .fail s!"the concurrent capture failed for another reason: {busy.stderr.trim.take 300}"
        if !rel then return .fail "the slot / directory was not released within 90 s after the reader went away"
        return .pass },

    { name := "a capture under client write load: every write acknowledged; write time with and without a concurrent capture printed; slot and directory released afterwards"
      run := do
        let some pod ← masterPod | return .fail "no master"
        let some ip ← getPodIp pod cfg.«namespace» | return .fail "no master IP"
        let (s0, ms0) ← bulkWrite ip "vcr_base" 3000
        let sd ← scriptsDir
        let capArgs : Array String := #[s!"{sd}/flare_v_capture_kind.py", "--ns", cfg.«namespace», "--out", "/tmp/e2e-vcr/load", pod]
        let cap ← IO.Process.spawn { cmd := "python3", args := capArgs, stdout := .piped, stderr := .piped }
        let tc ← IO.monoMsNow
        let (s1, ms1) ← bulkWrite ip "vcr_load" 3000
        let capOut ← cap.stdout.readToEnd
        let capErr ← cap.stderr.readToEnd
        let capCode ← cap.wait
        let capMs := (← IO.monoMsNow) - tc
        let rel ← released pod
        IO.eprintln s!"# load: 3000 sets without capture {ms0} ms ({s0} STORED); with a concurrent capture {ms1} ms ({s1} STORED); capture exit {capCode} in ~{capMs} ms: {capOut.trim.take 400} {capErr.trim.take 200}"
        if s0 != 3000 || s1 != 3000 then return .fail s!"writes not all acknowledged: {s0}/3000 without, {s1}/3000 with a capture"
        if capCode != 0 then return .fail s!"the capture under load failed ({capCode}): {capErr.trim.take 300}"
        if !rel then return .fail "slot / directory not released after the capture"
        return .pass },

    { name := "capture guard: free space below copy + reserve refuses the capture BEFORE any pin or checkpoint (capture_refused no_space); the slot stays free and no serve directory is created"
      run := do
        let some pod ← masterPod | return .fail "no master"
        if !(← setReserve 1000000000000000) then return .fail "the raised reserve did not reach flared within 300 s"
        let before ← captureStat pod
        let sd ← scriptsDir
        let capArgs : Array String := #[s!"{sd}/flare_v_capture_kind.py", "--ns", cfg.«namespace», "--out", "/tmp/e2e-vcr/nospace", pod]
        let cap ← IO.Process.output { cmd := "python3", args := capArgs }
        let after ← captureStat pod
        let dirs ← serveDirs pod
        let serving ← podStat pod "rocksdb_snapshot_serving"
        IO.eprintln s!"# no-space: capture exit {cap.exitCode}: {cap.stderr.trim.take 300}; stats before [{before}] after [{after}]; serving {serving}, serve dirs {dirs}"
        let restored ← setReserve e2eRebuildReserveBytes
        if cap.exitCode == 0 then return .fail "a capture SUCCEEDED with free space below copy + reserve"
        if !containsSubstr cap.stderr "capture_refused no_space" then return .fail s!"refused for another reason: {cap.stderr.trim.take 300}"
        if (← podStat pod "rocksdb_capture_last") != some "refused:no_space" then return .fail s!"rocksdb_capture_last not refused:no_space ({after})"
        if dirs != 0 || serving != some "0" then return .fail s!"a refused capture left serving {serving} / {dirs} serve dirs"
        if !restored then return .fail "the reserve was not restored within 300 s"
        return .pass },

    { name := "capture guard: a peer that stays CONNECTED but never reads is cut by the write-progress timeout (aborted:no_progress) while it is still connected; slot released, directory removed"
      run := do
        let some pod ← masterPod | return .fail "no master"
        let some ip ← getPodIp pod cfg.«namespace» | return .fail "no master IP"
        -- ~40 MB of letters: far beyond both socket buffers, so the
        -- serve really blocks in write()
        let (stored, ms) ← bulkWriteLen ip "vcr_big" 40000 1000
        IO.eprintln s!"# big data: {stored}/40000 STORED in {ms} ms"
        if stored != 40000 then return .fail s!"big data: {stored}/40000 STORED"
        let t0 ← IO.monoMsNow
        let reader ← spawnRaw pod "repl_snapshot 0 capture 600" "sleep 120"
        let cut ← waitLast pod "aborted:no_progress" 100
        let took := ((← IO.monoMsNow) - t0) / 1000
        let stillConnected := (← reader.tryWait).isNone
        let rel ← released pod
        IO.eprintln s!"# stalled reader: cut {cut} after ~{took} s (reader still connected: {stillConnected}); {← captureStat pod}"
        reader.kill
        let _ ← reader.wait
        if !cut then return .fail s!"the stalled serve was not cut within 100 s ({← captureStat pod})"
        if !stillConnected then return .fail "the reader went away before the cut: the progress timeout was not what ended the serve"
        if !rel then return .fail "slot / directory not released after the cut"
        return .pass },

    { name := "capture guard: the TOTAL deadline ends a slow capture whose reader keeps reading (aborted:deadline); slot released, directory removed"
      run := do
        let some pod ← masterPod | return .fail "no master"
        let t0 ← IO.monoMsNow
        -- 200 KB/s over ~40 MB would take minutes; the deadline is 10 s (the
        -- check runs at the next write: up to one chunk's throttle sleep later)
        let reader ← spawnRaw pod "repl_snapshot 200 capture 10" "timeout 90 cat <&3 >/dev/null"
        let cut ← waitLast pod "aborted:deadline" 60
        let took := ((← IO.monoMsNow) - t0) / 1000
        let rel ← released pod
        IO.eprintln s!"# deadline 10 s: cut {cut} after ~{took} s; {← captureStat pod}"
        reader.kill
        let _ ← reader.wait
        if !cut then return .fail s!"the deadline did not end the capture within 60 s ({← captureStat pod})"
        if !rel then return .fail "slot / directory not released after the deadline"
        return .pass },

    { name := "capture: a reader that disconnects mid-stream ends the serve (aborted:write); slot released, directory removed"
      run := do
        let some pod ← masterPod | return .fail "no master"
        let reader ← spawnRaw pod "repl_snapshot 200 capture 600" "timeout 5 cat <&3 >/dev/null"
        let _ ← reader.wait
        let t0 ← IO.monoMsNow
        let cut ← waitLast pod "aborted:write" 60
        let rel ← released pod
        IO.eprintln s!"# disconnect: cut {cut} ~{((← IO.monoMsNow) - t0) / 1000} s after the reader left; {← captureStat pod}"
        if !cut then return .fail s!"the serve did not end after the disconnect ({← captureStat pod})"
        if !rel then return .fail "slot / directory not released after the disconnect"
        return .pass },

    { name := "capture: flared killed (-9) mid-capture leaves nothing behind after the restart (no serve directory, slot free) and the data is intact"
      run := do
        let some pod ← masterPod | return .fail "no master"
        let itemsBefore ← podStat pod "curr_items"
        let reader ← spawnRaw pod "repl_snapshot 200 capture 600" "timeout 120 cat <&3 >/dev/null"
        let serving ← waitForCondition "a capture is being served" 30 do
          return (← podStat pod "rocksdb_snapshot_serving") == some "1"
        let dirsDuring ← serveDirs pod
        let killed ← killFlared pod
        reader.kill
        let _ ← reader.wait
        let back ← waitForCondition "flared answers again after the kill" 180 do
          return (← podStat pod "rocksdb_snapshot_serving") == some "0"
        let dirsAfter ← serveDirs pod
        let itemsAfter ← podStat pod "curr_items"
        IO.eprintln s!"# crash mid-capture: serving {serving}, dirs during {dirsDuring}, {killed}; back {back}, dirs after {dirsAfter}; curr_items {itemsBefore} -> {itemsAfter}"
        if !serving then return .fail "the capture never took the slot"
        if dirsDuring != 1 then return .fail s!"{dirsDuring} serve dirs during the capture, want 1"
        if killed != "killed=1" then return .fail s!"kill from the kind node: {killed}"
        if !back then return .fail "flared did not come back within 180 s"
        if dirsAfter != 0 then return .fail s!"{dirsAfter} snapshot.serve.* directories left after the restart"
        if itemsAfter != itemsBefore then return .fail s!"curr_items changed across the crash: {itemsBefore} -> {itemsAfter}"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.VCaptureResources
