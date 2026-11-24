/-
  E2E/Tests/SlowReconcileLease.lean — slow reconcile passes (flare-operator-slow-reconcile).

  Under a bulk write load (mon-prod) a reconcile pass took 18-31 s, longer
  than the 15 s leader lease. The loop renewed the lease once per pass, so the
  standby took it and the leader logged `LOST LEASE -- exiting` every 10-15
  min. A pass also read every node one after the other (the sum of the node
  latencies) and advanced the topology version at every commit (+7 a pass).

  The rebuild gate reads the nodes FRESH at every decision that may admit a
  new assignment (a reconstruction can start between two gates of a pass, so
  nothing is reused across decisions; review of PR #188). A pass therefore
  takes about N x one delay for its N gate decisions (not the sum of the
  nodes), and the lease keeper keeps the lease whatever the pass length.

  Two operator replicas (a standby is what takes a lapsed lease), 2 partitions
  x 2 replicas. A held rebuild (flared's activation held on both replicas, both
  masters rewritten: one rebuild stays in Prepare, the other is HELD as a
  Proxy) makes the rebuild gate read every node at every pass, and the seam
  FLARE_TEST_NODE_READ_DELAY_FILE delays each of those reads by 20 s (never
  armed in production). Then, for 360 s:
    1. passes are slow (`reconcile slow`, longer than the 15 s lease) but the
       leader keeps the lease: no LOST LEASE in either operator, the holder and
       leaseTransitions are unchanged at every 10 s sample, no operator
       container restarts;
    2. the 4 reads of ONE gate decision run together: each decision takes about
       one delay (20 s), not their sum (80 s); a pass of N decisions takes about
       N x 20 s, inside the 180 s pass deadline;
    3. while a node is not Active the topology version advances at most once
       per pass.
  Then the lease is really taken (another holder): the old leader still stops —
  it exits within 40 s, in the middle of a slow pass, and broadcasts nothing
  after the lease is gone.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.SlowReconcileLease

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

/-- the delay of each per-node read of the gate while the seam file exists -/
private def readDelayMs : Nat := 20000

private def cfg : ClusterConfig := {
  name := "slow-lease"
  «namespace» := "flare-slow-lease"
  partitions := 2
  replicas := 2
  operatorReplicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-slow-lease"
  storageBackend := "rocksdb"
  usePvc := true
  flaredEnv := [("FLARE_TEST_ACTIVATION_HOLD_FILE", "/tmp/act-hold")]
  operatorEnv := [("FLARE_FOLLOW_PROBE_INTERVAL", "1"),
    ("FLARE_TEST_NODE_READ_DELAY_FILE", "/tmp/nodereaddelay")]
}

private def ns : String := cfg.«namespace»
private def leaseName : String := s!"{cfg.name}-operator-lease"

private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def kget (args : List String) : IO String := do
  match ← kubectl args with
  | .ok o => return o.trim
  | .error _ => return ""

/-- (holder, leaseTransitions) of the leader lease -/
private def leaseNow : IO (String × String) := do
  let h ← kget ["get", "lease", leaseName, "-n", ns, "-o", "jsonpath={.spec.holderIdentity}"]
  let t ← kget ["get", "lease", leaseName, "-n", ns, "-o", "jsonpath={.spec.leaseTransitions}"]
  return (h, t)

private def operatorPods : IO (List String) := do
  let o ← kget ["get", "pods", "-n", ns, "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[*].metadata.name}"]
  return (o.splitOn " ").filter (· != "")

private def restartsOf (pod : String) : IO Nat := do
  let o ← kget ["get", "pod", pod, "-n", ns, "-o",
    "jsonpath={.status.containerStatuses[?(@.name==\"flare-operator\")].restartCount}"]
  return o.toNat?.getD 0

private def restartsOfAll (pods : List String) : IO (List (String × Nat)) := do
  let mut out := []
  for p in pods do out := out ++ [(p, ← restartsOf p)]
  return out

private def utcStamp : IO String := do
  let o ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%S.%NZ"] }
  return o.stdout.trim

/-- one operator pod's log since `since` (RFC 3339), each line with its time;
    `previous` = the container before its last restart -/
private def podLogSince (pod since : String) (previous : Bool := false) : IO String := do
  match ← kubectl (["logs", "-n", ns, pod, "-c", "flare-operator", "--timestamps", "--since-time", since, "--tail=-1"]
      ++ (if previous then ["--previous"] else [])) with
  | .ok o => return o
  | .error _ => return ""

/-- seconds of the day of a `--timestamps` line (HH:MM:SS after the `T`) -/
private def secOf (l : String) : Option Nat :=
  match l.splitOn "T" with
  | _ :: t :: _ =>
    match (t.take 8).splitOn ":" with
    | [h, m, sec] => do pure ((← h.toNat?) * 3600 + (← m.toNat?) * 60 + (← sec.toNat?))
    | _ => none
  | _ => none

/-- Group the delayed-read lines into gate decisions: the reads of one decision
    start together (they run in parallel), the next decision starts only after
    the previous one's reads have finished (>= delay later). Returns, per
    decision, the spread (s) between its first and last read start and its
    number of reads. -/
private def decisions (reads : List String) (delayS : Nat) : List (Nat × Nat) := Id.run do
  let secs := reads.filterMap secOf
  let mut out : List (Nat × Nat) := []
  let mut cur : List Nat := []
  for t in secs do
    match cur.getLast? with
    | some last =>
      if (t + 86400 - last) % 86400 < delayS / 2 then cur := cur ++ [t]
      else
        out := out ++ [((cur.foldl max 0) - (cur.foldl min (cur.headD 0)), cur.length)]
        cur := [t]
    | none => cur := [t]
  if !cur.isEmpty then out := out ++ [((cur.foldl max 0) - (cur.foldl min (cur.headD 0)), cur.length)]
  return out

private def lines (s : String) (needle : String) : List String :=
  (s.splitOn "\n").filter (containsSubstr · needle)

/-- the number right after `marker` in a line -/
private def natAfter (l marker : String) : Option Nat :=
  match l.splitOn marker with
  | _ :: rest :: _ => (String.mk (rest.toList.takeWhile Char.isDigit)).toNat?
  | _ => none

private def nodeViewOn (leaderPod : String) : IO (List NodeSyncEntry) := do
  match ← getPodIp leaderPod ns with
  | none => return []
  | some ip =>
    match ← execInDebugPod cfg.debugPod ns s!"printf 'node sync\\r\\n' | nc -w 3 {ip} {cfg.operatorPort}" with
    | .ok o => return parseNodeSync o
    | .error _ => return []

/-- `sh -c cmd` in every operator pod (the standby may be the next leader) -/
private def opExecAll (cmd : String) : IO Unit := do
  for p in ← operatorPods do
    discard <| kubectl ["exec", "-n", ns, p, "-c", "flare-operator", "--", "sh", "-c", cmd]

private def flaredExec (pod : String) (cmd : List String) : IO Unit :=
  discard <| kubectl (["exec", "-n", ns, pod, "-c", "flared", "--"] ++ cmd)

/-- (master ip, a Slave pod) of partition `p` -/
private def pairOf (leaderPod : String) (p : Nat) : IO (Option (String × String)) := do
  let es ← nodeViewOn leaderPod
  match findMasterFqdn es p with
  | none => return none
  | some m =>
    match es.find? (fun e => e.partition == Int.ofNat p && e.fqdn != m) with
    | none => return none
    | some s =>
      match ← getPodIp (podOf m) ns with
      | some mIp => return some (mIp, podOf s.fqdn)
      | none => return none

def suite : TestSuite := {
  name := "slow-reconcile-lease"
  setup := do
    deployCluster cfg
    IO.sleep 30000
  teardown := cleanupCluster cfg
  onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
  tests := [
    { name := "slow passes (held rebuild gate, every per-node read delayed 20 s) for 360 s: passes outlast the 15 s lease (reconcile slow) but the leader keeps it (no LOST LEASE, holder and leaseTransitions unchanged, no restart), the node reads of each gate decision run together (a decision ≈ one delay, not the sum of the nodes; a pass ≈ N decisions × one delay), and the topology version advances at most once per pass while a node is not Active"
      run := do
        let grace ← waitForCondition "an operator past its startup grace period" 300 do
          return containsSubstr (← kubectlLogsLabel s!"app={cfg.operatorName}" ns 400000) "grace period over"
        if !grace then return .fail "no operator logged the end of its startup grace period"
        let pods ← operatorPods
        if pods.length != 2 then return .fail s!"precondition: {pods.length} operator pod(s), not 2 (a standby is what takes a lapsed lease)"
        let (leader, trans0) ← leaseNow
        if leader.isEmpty || !pods.contains leader then
          return .fail s!"precondition: lease holder '{leader}' is not one of the operator pods {pods}"
        let some (m0Ip, s0) ← pairOf leader 0 | return .fail "precondition: no master and slave in partition 0"
        let some (m1Ip, s1) ← pairOf leader 1 | return .fail "precondition: no master and slave in partition 1"
        -- a held rebuild: both replicas' activation held, both masters rewritten
        -- (a new history, then keys): one replica stays in Prepare, the other
        -- assignment is HELD as a Proxy, so the gate reads every node every pass
        flaredExec s0 ["touch", "/tmp/act-hold"]
        flaredExec s1 ["touch", "/tmp/act-hold"]
        for mIp in [m0Ip, m1Ip] do
          discard <| execInDebugPod cfg.debugPod ns s!"printf 'flush_all\\r\\n' | nc -w 5 {mIp} {cfg.flarePort}"
        IO.sleep 2000
        for mIp in [m0Ip, m1Ip] do
          discard <| writeKeys cfg.debugPod ns mIp cfg.flarePort "slowlease" 20
        let held ← waitForCondition "a rebuild is in Prepare and a second assignment is held" 600 do
          let log ← podLogSince leader "1970-01-01T00:00:00Z"
          let es ← nodeViewOn leader
          return !(lines log "REBUILD HELD").isEmpty && (es.filter (fun e => e.role == 1 && e.state == 1)).length == 1
        if !held then return .fail "precondition: no held rebuild (a Prepare slave and a HELD assignment) was reached"
        -- the window: the lease and the containers are sampled every 10 s
        let (leaderBefore, transBefore) ← leaseNow
        if leaderBefore != leader || transBefore != trans0 then
          return .fail s!"the lease changed before the window: {leader}/{trans0} -> {leaderBefore}/{transBefore}"
        let restarts0 ← restartsOfAll pods
        opExecAll s!"echo {readDelayMs} > /tmp/nodereaddelay"
        let t0 ← utcStamp
        IO.eprintln s!"# window start {t0}: leader {leader}, leaseTransitions {transBefore}, restarts {restarts0}"
        let mut drift : Option String := none
        for i in [0:36] do
          IO.sleep 10000
          let (h, t) ← leaseNow
          let rs ← restartsOfAll pods
          if drift.isNone && (h != leader || t != transBefore) then
            drift := some s!"lease {leader}/{transBefore} -> {h}/{t} at {(i + 1) * 10} s"
          if drift.isNone && rs != restarts0 then
            drift := some s!"operator restarts {restarts0} -> {rs} at {(i + 1) * 10} s"
        let t1 ← utcStamp
        let esEnd ← nodeViewOn leader
        let notActive := (esEnd.filter (·.state != 0)).length
        -- the evidence of this window only
        let mut lost := 0
        for p in pods do lost := lost + (lines (← podLogSince p t0) "LOST LEASE").length
        let leaderLog ← podLogSince leader t0
        let slow := (lines leaderLog "reconcile slow: ").filterMap (natAfter · "reconcile slow: ")
        let delayedLines := lines leaderLog "TEST SEAM: read of "
        let delayed := delayedLines.length
        let gateDecisions := decisions delayedLines (readDelayMs / 1000)
        let versions := (lines leaderLog "Broadcasting node sync v").filterMap (natAfter · "Broadcasting node sync v")
        let vDelta := (versions.foldl max 0) - (versions.foldl min (versions.headD 0))
        let longest := slow.foldl max 0
        -- the first pass logged in the window may have started before it (and
        -- before the delayed reads applied): only the passes after it must be slow
        let gated := slow.drop 1
        let shortest := gated.foldl min (gated.headD 0)
        IO.eprintln s!"# window {t0} .. {t1}: reconcile slow {slow} ms; delayed reads {delayed}; LOST LEASE {lost}; versions {versions.length} broadcasts, v{versions.foldl min (versions.headD 0)}..v{versions.foldl max 0} (+{vDelta}); nodes not Active at the end {notActive}; gate decisions (spread s, reads) {gateDecisions}; drift {drift}"
        if let some d := drift then return .fail s!"the leader did not keep the lease for the whole window: {d}"
        if lost != 0 then return .fail s!"{lost} LOST LEASE line(s) in an operator log during the window"
        if slow.length < 2 then return .fail s!"only {slow.length} slow pass(es) logged in 360 s (a delayed gate makes every pass slow): the seam did not take effect"
        if longest < 15000 then return .fail s!"the longest pass took {longest} ms, not longer than the 15 s lease: the window did not outlast the lease"
        -- every gate decision reads the nodes fresh (N decisions a pass, one delay
        -- each, so a pass is about N x 20 s: at most 8 decisions, inside the
        -- 180 s pass deadline); the 4 reads of ONE decision run together: their
        -- starts are within a few seconds, not 20 s apart (the sequential sum is 80 s)
        if longest > 8 * readDelayMs then
          return .fail s!"a pass took {longest} ms; with N <= 8 gate decisions of one delay ({readDelayMs} ms) each it is at most {8 * readDelayMs} ms"
        if shortest + 5000 < readDelayMs then
          return .fail s!"a pass took only {shortest} ms although every read waits {readDelayMs} ms: the gate did not read the nodes in that pass"
        if gateDecisions.length < 2 then return .fail s!"only {gateDecisions.length} gate decision(s) read the nodes in the window"
        match gateDecisions.find? (fun (spread, _) => spread > 5) with
        | some (spread, n) => return .fail s!"a gate decision's {n} reads started {spread} s apart: the nodes of one decision were not read together (sequential reads would be {readDelayMs / 1000} s apart)"
        | none => pure ()
        if delayed < 4 then return .fail s!"only {delayed} delayed node read(s) in the window"
        -- the version: at most once per pass (a pass before the window edge may
        -- still be counted: one extra), and it does move while a node is not Active
        if notActive == 0 then return .fail "precondition: every node is Active at the end of the window (no rebuild in progress)"
        if versions.isEmpty || vDelta == 0 then
          return .fail s!"the topology version never advanced although a node is not Active ({versions.length} broadcast(s))"
        if vDelta > slow.length + 1 then
          return .fail s!"the topology version advanced {vDelta} times in {slow.length} passes (at most once per pass expected)"
        return .pass },
    { name := "the lease is really taken (another holder) in the middle of a slow pass: the old leader stops and exits within 40 s, broadcasts nothing after it, and the cluster recovers when the lease is free again"
      run := do
        let pods ← operatorPods
        let (leader, trans0) ← leaseNow
        if !pods.contains leader then return .fail s!"precondition: lease holder '{leader}' is not an operator pod"
        -- still slow: the seam file of the leader's container is there
        match ← kubectl ["exec", "-n", ns, leader, "-c", "flare-operator", "--", "sh", "-c", "test -f /tmp/nodereaddelay"] with
        | .error e => return .fail s!"precondition: the delayed reads are not armed on {leader} ({e}); the first test did not leave them"
        | .ok _ => pure ()
        let r0 ← restartsOf leader
        let others := pods.filter (· != leader)
        let tTake ← utcStamp
        let patch := "{\"spec\":{\"holderIdentity\":\"e2e-foreign-holder\",\"leaseDurationSeconds\":600,\"renewTime\":\"2999-01-01T00:00:00.000000Z\"}}"
        match ← kubectlPatch "lease" leaseName ns patch with
        | .error e => return .fail s!"could not take the lease: {e}"
        | .ok _ => pure ()
        let t0 ← IO.monoMsNow
        let exited ← waitForCondition "the old leader exits on the lost lease" 40 do
          return (← restartsOf leader) > r0
        let took := (← IO.monoMsNow) - t0
        let prev ← podLogSince leader "1970-01-01T00:00:00Z" (previous := true)
        let after := (prev.splitOn "\n").filter fun l => (l.take 30) > tTake && !l.isEmpty
        let sent := lines (String.intercalate "\n" after) "Broadcasting node sync"
        let lostLines := lines (String.intercalate "\n" after) "LOST LEASE"
        IO.eprintln s!"# lease taken at {tTake} (was {leader}, transitions {trans0}); old leader exited={exited} after ~{took} ms; LOST LEASE lines {lostLines.length}; broadcasts after the take {sent.length}; standbys {others}"
        for l in (after.take 6) do IO.eprintln s!"#   {l.take 220}"
        -- authority back: the foreign holder is gone, the cluster recovers
        discard <| kubectl ["delete", "lease", leaseName, "-n", ns]
        opExecAll "rm -f /tmp/nodereaddelay"
        let back ← waitForCondition "an operator holds the lease again" 180 do
          let (h, _) ← leaseNow
          return !h.isEmpty && h != "e2e-foreign-holder"
        -- let the held rebuild go and the cluster converge
        for pod in ← (do
            let o ← kget ["get", "pods", "-n", ns, "-l", s!"cluster={cfg.name}", "-o", "jsonpath={.items[*].metadata.name}"]
            pure ((o.splitOn " ").filter (· != ""))) do
          discard <| kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
        if !exited then return .fail s!"the old leader {leader} did not exit within 40 s of the lease being taken (restartCount stayed {r0}): a process that neither leads nor exits leaves the cluster unowned"
        if lostLines.isEmpty then return .fail "the old leader exited without logging LOST LEASE"
        if !sent.isEmpty then return .fail s!"the old leader broadcast {sent.length} node map(s) after the lease was taken"
        if !back then return .fail "no operator took the lease again within 180 s of its release"
        let converged ← waitForCondition "both partitions' replicas are Active slaves again" 600 do
          let (h, _) ← leaseNow
          let es ← nodeViewOn h
          return (es.filter (fun e => e.role == 1 && e.state == 0)).length == 2
        if !converged then return .fail "the cluster did not converge after the lease was released"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.SlowReconcileLease
