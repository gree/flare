/-
  E2E/Tests/FailoverOrder.lean — spec 4/12 (user decision 2026-10-27): among
  the slaves that followed the LAST master, the one with the largest applied
  position (sequence) is promoted (StateMachine/FailoverOrder.lean).

  Scenario (one partition, a master and TWO followers):
    1. both followers have applied the base keys;
    2. the master ⇄ follower A link is cut; more keys are written on the
       master, which follower B applies (B's applied position is larger than
       A's, A's copy is stale);
    3. the master's node is cordoned and its pod force-deleted: the master is
       gone and unreadable, so no head can order the followers;
    4. the promoted node must be B, and every key (base and later) must be
       on it. Before the rule the refill took the first slave in map order, so
       A was seated half of the time and the later keys were lost.
  The expectation is on the data AND on the identity (B), so a lucky map order
  cannot hide a wrong rule: the node chosen as A is the one that is FIRST in
  the operator's map, the order the old code would have used.

  Then (user decision 2026-10-31, spec 12, replacing the morning's option A):
  a flare node the OPERATOR cannot reach (TCP to its flared port) is marked
  down with flarei's retry count and wait (3 probes, 5 s apart, 1 s timeout,
  ~15 s; src/flarei/ini_option.h), proxy; a master only if a reachable slave
  can be promoted (otherwise it stays master and the reason is logged); and
  when the operator reaches NO node at all it does nothing (alert only: the
  k8s API / its own network is suspect).
    - operator ⇄ master cut only -> the master is marked down, a reachable
      slave is promoted. DATA GUARANTEE: every write acknowledged and
      replicated before the cut is on the new master (0 missing is asserted).
      A client that still reaches the OLD master (C' case) can have writes
      acknowledged there that the new master never sees: those are counted and
      reported, not asserted (rule 13 resolves duplicate masters, other issue).
    - operator ⇄ every flare pod cut -> nothing happens for 90 s.
    - operator ⇄ master and ⇄ both its slaves cut (other partitions stay
      reachable) -> the master has no reachable successor: it stays master and
      the log names the reason.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.FailoverOrder

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

private def cfg : ClusterConfig := {
  name := "fo-order"
  «namespace» := "flare-fo-order"
  -- 3 partitions (9 pods): test 4 cuts partition 0's master and both slaves;
  -- with 2 partitions that is 3 of 6 nodes and the circuit breaker (>= 50%)
  -- trips before the no-successor rule is reached (41233191422)
  partitions := 3
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-fo-order"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000"
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000"),
    -- spec 13 test: pods named in this file are not sent the node map
    ("FLARE_TEST_BROADCAST_SKIP_FILE", "/tmp/bskip"),
    -- review of ae8ac49: while this file exists the reachability step's pod
    -- listing fails
    ("FLARE_TEST_REACH_LIST_FAIL_FILE", "/tmp/reachfail"),
    -- review of fac7410: while this file exists the mid-pass lease renew is
    -- sent after the ms it holds (an API answering late)
    ("FLARE_TEST_LEASE_RENEW_DELAY_FILE", "/tmp/renewdelay")]
}

/-- every kind node: pods may be placed on any of them (the multi-node
    cluster of a mixed single-suite run, 41149278771), and a pod's traffic
    crosses the FORWARD chain of the node it runs on -/
private def kindNodes : IO (List String) := do
  match ← kubectl ["get", "nodes", "-o", "jsonpath={.items[*].metadata.name}"] with
  | .ok o => return (o.trim.splitOn " ").filter (· != "")
  | .error _ => return ["flare-e2e-control-plane"]
private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

private def statNat (ip key : String) : IO (Option Nat) := do
  match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}" with
  | .error _ => return none
  | .ok o =>
    return (o.splitOn "\n").findSome? fun line =>
      let t := line.trim.replace "\r" ""
      if t.startsWith s!"STAT {key} " then (t.drop s!"STAT {key} ".length).trim.toNat? else none

private def rule (a b : String) : List String :=
  ["FORWARD", "-s", a, "-d", b, "-p", "tcp", "--dport", toString cfg.flarePort,
   "-j", "REJECT", "--reject-with", "tcp-reset"]

private def cutLink (a b : String) : IO (Except String Unit) := do
  for node in ← kindNodes do
    for spec in [rule a b, rule b a] do
      match ← hostCmd "docker" (["exec", node, "iptables", "-I", "FORWARD", "1"] ++ spec.drop 1) with
      | .error e => return .error e
      | .ok _ => pure ()
  return .ok ()

private def healLink (a b : String) : IO Unit := do
  for node in ← kindNodes do
    for spec in [rule a b, rule b a] do
      for _ in [0:5] do
        match ← hostCmd "docker" (["exec", node, "iptables", "-D"] ++ spec) with
        | .ok _ => pure ()
        | .error _ => break

private def p0Master : IO (Option String) := do
  return (findMasterFqdn (← nodeView) 0).map podOf

private def opLogs : IO String := kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 4000

private def opIpOf : IO (Except String String) := do
  let opPod ← match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.name}"] with
    | .ok o => pure o.trim
    | .error e => return .error s!"no operator pod: {e}"
  match ← getPodIp opPod cfg.«namespace» with
  | some ip => return .ok ip
  | none => return .error s!"no IP for {opPod}"

/-- the operator logged the end of its startup grace (it is not restarted in
    this suite): once seen it stays true — the line scrolls out of the log's
    tail after the first test (41185704625: tests 2-4 failed on it) -/
initialize graceSeenRef : IO.Ref Bool ← IO.mkRef false

private def graceOver : IO Bool := do
  if ← graceSeenRef.get then return true
  let ok ← waitForCondition "operator past its startup grace period" 240 do
    return containsSubstr (← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400000) "grace period over"
  if ok then graceSeenRef.set true
  return ok

/-- partition 0 has an Active master and two Active slaves again (after a heal) -/
private def p0Stable : IO Bool := do
  let es ← nodeView
  let p0 := es.filter (·.partition == 0)
  return (p0.filter (fun e => e.role == 0 && e.state == 0)).length == 1
    && (p0.filter (fun e => e.role == 1 && e.state == 0)).length == 2

/-- every flared pod is Ready by its own probe (its own map says active):
    the operator's map alone can be ahead of a node that has not applied it
    yet (41228665463: test 3 cut the operator off before a restarted node got
    the map that made it active; it went NotReady and stayed Down ~10 min) -/
private def allPodsReady : IO Bool := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"cluster={cfg.name}", "-o",
      "jsonpath={range .items[*]}{.status.containerStatuses[0].ready}{\"\\n\"}{end}"] with
  | .ok o =>
    let rs := (o.splitOn "\n").map String.trim |>.filter (· != "")
    return !rs.isEmpty && rs.all (· == "true")
  | .error _ => return false

private def waitP0Stable : IO Bool :=
  waitForCondition "partition 0 has a master and two Active slaves, every flared pod Ready" 360 do
    return (← p0Stable) && (← allPodsReady)

private def keysMissing (ip pfx : String) (n : Nat) : IO Nat := do
  let mut missing := 0
  for i in [0:n] do
    match ← memcachedGet cfg.debugPod cfg.«namespace» ip cfg.flarePort s!"{pfx}_{i}" with
    | some _ => pure ()
    | none => missing := missing + 1
  return missing

/-- `sh -c cmd` in the operator pod. -/
private def opExec (cmd : String) : IO (Except String String) := do
  match ← kubectl ["get", "pods", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.name}"] with
  | .ok o => kubectl ["exec", "-n", cfg.«namespace», o.trim, "--", "sh", "-c", cmd]
  | .error e => return .error e

private def ownRole (ip : String) : IO (Option String) := do
  match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {cfg.flarePort}" with
  | .ok o => return (o.splitOn "\n").findSome? fun l =>
      match (l.trim.replace "\r" "").splitOn " " with
      | ["STAT", "own_role", v] => some v
      | _ => none
  | .error _ => return none

private def countLines (logs needle1 needle2 : String) : Nat :=
  ((logs.splitOn "\n").filter fun l => containsSubstr l needle1 && containsSubstr l needle2).length

def suite : TestSuite := {
  name := "failover-order"
  setup := do
    deployCluster cfg
    IO.sleep 50000
  teardown := do
    for node in ← kindNodes do
      discard <| kubectl ["uncordon", node]
    cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "operator ⇄ master cut only (the pod Ready, clients reaching it): the master is marked down after flarei's 3 probes and a reachable slave is promoted; every write acknowledged and replicated before the cut is on the new master (0 missing); writes only the old master acknowledged afterwards are counted"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let some mPod ← p0Master | return .fail "no Active P0 master in the operator's map"
        let some mIp ← getPodIp mPod cfg.«namespace» | return .fail s!"no IP for {mPod}"
        let opIp ← match ← opIpOf with
          | .ok ip => pure ip
          | .error e => return .fail e
        let slaves := ((← nodeView).filter fun e => e.partition == 0 && e.role == 1).map (podOf ·.fqdn)
        let pre ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "unr_pre" 20
        if pre != 20 then return .fail s!"precondition: only {pre}/20 keys stored before the cut"
        let some h0 ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "the master's head is unreadable"
        for sp in slaves do
          let some sIp ← getPodIp sp cfg.«namespace» | return .fail s!"no IP for {sp}"
          let ok ← waitForCondition s!"{sp} applied the keys (head {h0})" 120 do
            return (← statNat sIp "repl_applied_lsn").getD 0 ≥ h0
          if !ok then return .fail s!"precondition: {sp} did not apply the keys"
        let t0 ← IO.monoMsNow
        match ← cutLink opIp mIp with
        | .error e => return .fail s!"could not cut operator ⇄ {mPod}: {e}"
        | .ok _ => pure ()
        try
          let promoted ← waitForCondition s!"a new P0 master after the operator lost {mPod}" 180 do
            match ← p0Master with
            | some m => return m != mPod
            | none => return false
          let secs := ((← IO.monoMsNow) - t0) / 1000
          if !promoted then return .fail s!"{mPod} (reachable by clients, unreachable from the operator) was never failed over (180 s)"
          IO.eprintln s!"# {mPod} replaced {secs} s after the cut (flarei equivalent: 3 probes x 5 s = ~15 s, plus a tick and the map commit)"
          let some m2 ← p0Master | return .fail "no master after the wait"
          if !(slaves.contains m2) then return .fail s!"{m2} was promoted but is not one of the slaves {slaves}"
          if countLines (← opLogs) "UNREACHABLE: master" mPod == 0 then
            return .fail s!"no 'UNREACHABLE: master {mPod}' line in the operator log"
          let some m2Ip ← getPodIp m2 cfg.«namespace» | return .fail s!"no IP for {m2}"
          let applied ← waitForCondition s!"{m2} reports own_role master" 60 do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {m2Ip} {cfg.flarePort}" with
            | .ok o => return containsSubstr o "STAT own_role master"
            | .error _ => return false
          if !applied then return .fail s!"{m2} never reported itself master"
          let missingPre ← keysMissing m2Ip "unr_pre" 20
          let fresh ← writeKeys cfg.debugPod cfg.«namespace» m2Ip cfg.flarePort "unr_new" 20
          -- C' case: a client that still reaches the old master
          let oldAcked ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "unr_old" 20
          IO.eprintln s!"# new master {m2}: {20 - missingPre}/20 pre-cut keys present, {fresh}/20 new writes acknowledged; old master {mPod} still acknowledged {oldAcked}/20 writes from a client"
          if missingPre != 0 then return .fail s!"{missingPre}/20 writes acknowledged and replicated before the cut are missing on the new master {m2}"
          if fresh != 20 then return .fail s!"only {fresh}/20 writes acknowledged by the new master {m2}"
          healLink opIp mIp
          if !(← waitP0Stable) then return .fail "partition 0 did not return to a master and two Active slaves after the heal"
          let some m3 ← p0Master | return .fail "no master after the heal"
          let some m3Ip ← getPodIp m3 cfg.«namespace» | return .fail s!"no IP for {m3}"
          let lostOld := (← keysMissing m3Ip "unr_old" 20)
          IO.eprintln s!"# after the heal (master {m3}): unr_pre missing {(← keysMissing m3Ip "unr_pre" 20)}, unr_new missing {(← keysMissing m3Ip "unr_new" 20)}; of the {oldAcked} writes only the old master acknowledged, {lostOld}/20 are absent (C' case: not asserted; rule 13 handles duplicate masters)"
          return .pass
        finally
          healLink opIp mIp },
    { name := "(spec 13) a master the committed map no longer names keeps claiming it (failed over while cut from the operator, then reachable again with the map withheld from it and not restarted): detected and treated as down after 15 s; the map's master keeps serving (writes acknowledged); once it gets the map the claim ends"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let some mPod ← p0Master | return .fail "no Active P0 master in the operator's map"
        let some mIp ← getPodIp mPod cfg.«namespace» | return .fail s!"no IP for {mPod}"
        let opIp ← match ← opIpOf with
          | .ok ip => pure ip
          | .error e => return .fail e
        -- the seam withholds the map from mPod and keeps the operator from
        -- restarting it (a restart would hand it the map by re-registration)
        match ← opExec s!"echo {mPod} > /tmp/bskip" with
        | .error e => return .fail s!"could not arm the broadcast skip: {e}"
        | .ok _ => pure ()
        try
          match ← cutLink opIp mIp with
          | .error e => return .fail s!"could not cut operator ⇄ {mPod}: {e}"
          | .ok _ => pure ()
          let promoted ← waitForCondition s!"a new P0 master after the operator lost {mPod}" 180 do
            match ← p0Master with
            | some m => return m != mPod
            | none => return false
          if !promoted then return .fail s!"precondition: {mPod} was not failed over while cut (rule 12)"
          healLink opIp mIp
          let some m2 ← p0Master | return .fail "no master after the failover"
          let claims ← waitForCondition s!"{mPod} still reports own_role master" 30 do
            return (← ownRole mIp) == some "master"
          if !claims then return .fail s!"precondition: {mPod} does not claim master after the heal (it got a map anyway?)"
          let detected ← waitForCondition s!"the operator treats {mPod} as a duplicate master" 120 do
            return countLines (← opLogs) s!"DUPLICATE MASTER: {mPod}" "treated as down" > 0
          let logs ← opLogs
          for l in (logs.splitOn "\n").filter (fun l => containsSubstr l "DUPLICATE MASTER" || containsSubstr l "claims to be a MASTER") do
            IO.eprintln s!"# {l.trim.take 300}"
          -- every audit sample of mPod (41207217684: one CRITICAL and no
          -- later sample in the suite's log tail to show why it never stood)
          if !detected then
            let full ← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400000
            for l in (full.splitOn "\n").filter (fun l => containsSubstr l s!"[TopologyAudit] node={mPod}." || (containsSubstr l mPod && containsSubstr l "reach")) do
              IO.eprintln s!"# {l.trim.take 300}"
          if !detected then return .fail s!"{mPod} claimed a master the map gives to {m2}, but it was never treated as a duplicate master (120 s)"
          if (← p0Master) != some m2 then return .fail s!"the map's master changed from {m2} while the duplicate claim was handled"
          let some m2Ip ← getPodIp m2 cfg.«namespace» | return .fail s!"no IP for {m2}"
          let acked ← writeKeys cfg.debugPod cfg.«namespace» m2Ip cfg.flarePort "dup_new" 20
          if acked != 20 then return .fail s!"only {acked}/20 writes acknowledged by the map's master {m2}"
          discard <| opExec "rm -f /tmp/bskip"
          let ended ← waitForCondition s!"{mPod} no longer claims master once it gets the map" 120 do
            return (← ownRole mIp) != some "master"
          if !ended then return .fail s!"{mPod} still claims master 120 s after the map was no longer withheld"
          if !(← waitP0Stable) then return .fail "partition 0 did not return to a master and two Active slaves"
          return .pass
        finally
          discard <| opExec "rm -f /tmp/bskip"
          healLink opIp mIp },
    { name := "operator ⇄ EVERY flare pod cut (nothing reachable: the operator's own network is suspect): nothing is marked down, the master is unchanged for 90 s and the 'cannot reach ANY' alert is logged"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let some mPod ← p0Master | return .fail "no Active P0 master in the operator's map"
        let some mIp ← getPodIp mPod cfg.«namespace» | return .fail s!"no IP for {mPod}"
        let opIp ← match ← opIpOf with
          | .ok ip => pure ip
          | .error e => return .fail e
        let mut ips : List String := []
        for e in ← nodeView do
          if let some ip ← getPodIp (podOf e.fqdn) cfg.«namespace» then ips := ips ++ [ip]
        let downBefore := countLines (← opLogs) "UNREACHABLE:" ""
        let mut cut : List String := []
        try
          for ip in ips do
            match ← cutLink opIp ip with
            | .error e => return .fail s!"could not cut operator ⇄ {ip}: {e}"
            | .ok _ => cut := cut ++ [ip]
          let alerted ← waitForCondition "the operator alerts that it reaches NO node" 120 do
            return containsSubstr (← opLogs) "cannot reach ANY of the"
          if !alerted then return .fail "no 'cannot reach ANY' alert within 120 s (the cuts did not take)"
          for i in [0:9] do
            IO.sleep 10000
            match ← p0Master with
            | some m => if m != mPod then return .fail s!"{mPod} was replaced by {m} while the operator reached no node ({(i + 1) * 10} s)"
            | none => return .fail s!"partition 0 has no master {(i + 1) * 10} s after the alert"
          let downAfter := countLines (← opLogs) "UNREACHABLE:" ""
          if downAfter > downBefore then return .fail s!"the operator marked a node unreachable-down while it reached none ({downBefore} -> {downAfter} log lines)"
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "unr_all" 20
          IO.eprintln s!"# master {mPod} unchanged for 90 s with every operator link cut; alert logged; {stored}/20 writes acknowledged"
          if stored != 20 then return .fail s!"only {stored}/20 writes acknowledged by {mPod}"
          return .pass
        finally
          -- every ip, not `cut`: a `let mut` updated inside the try is not
          -- seen by its finally when the try exits through `return`
          -- (41194666000: no link was healed, every later test ran cut off)
          for ip in ips do healLink opIp ip },
    { name := "an unreachable master with NO reachable promotable slave (operator ⇄ master and ⇄ both its slaves cut, the other partition reachable) is NOT marked down: it stays the master for 90 s and the log names the reason"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let some mPod ← p0Master | return .fail "no Active P0 master in the operator's map"
        let some mIp ← getPodIp mPod cfg.«namespace» | return .fail s!"no IP for {mPod}"
        let opIp ← match ← opIpOf with
          | .ok ip => pure ip
          | .error e => return .fail e
        let slaveIps ← (((← nodeView).filter fun e => e.partition == 0 && e.role == 1).map (podOf ·.fqdn)).mapM fun sp => do
          return (← getPodIp sp cfg.«namespace»).getD ""
        if slaveIps.length != 2 || slaveIps.any (· == "") then return .fail s!"precondition: two slaves with IPs expected, got {slaveIps}"
        let before := countLines (← opLogs) "NO reachable promotable successor" mPod
        let mut cut : List String := []
        try
          for ip in mIp :: slaveIps do
            match ← cutLink opIp ip with
            | .error e => return .fail s!"could not cut operator ⇄ {ip}: {e}"
            | .ok _ => cut := cut ++ [ip]
          let logged ← waitForCondition s!"the operator logs that {mPod} has no reachable promotable successor" 180 do
            return countLines (← opLogs) "NO reachable promotable successor" mPod > before
          if !logged then return .fail s!"no 'NO reachable promotable successor' line naming {mPod} within 180 s"
          for i in [0:9] do
            IO.sleep 10000
            match ← p0Master with
            | some m => if m != mPod then return .fail s!"{mPod} was replaced by {m} although no reachable slave could be promoted ({(i + 1) * 10} s)"
            | none => return .fail s!"{mPod} is no longer the Active master of partition 0 ({(i + 1) * 10} s after the reason was logged)"
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "unr_nosucc" 20
          IO.eprintln s!"# {mPod} still the master 90 s after the reason was logged; {stored}/20 writes acknowledged"
          if stored != 20 then return .fail s!"only {stored}/20 writes acknowledged by {mPod}"
          return .pass
        finally
          -- the fixed list, not `cut` (see the test above)
          for ip in mIp :: slaveIps do healLink opIp ip
          discard <| waitP0Stable },
    { name := "two followers: the master is lost while one follower is stale; the follower with the LARGER applied sequence is promoted, and every key is on it"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable (master and two Active slaves)"
        let some mPod ← p0Master | return .fail "no Active P0 master in the operator's map"
        let some mIp ← getPodIp mPod cfg.«namespace» | return .fail s!"no IP for {mPod}"
        let entries ← nodeView
        -- A = the follower FIRST in the operator's map order (what the old
        -- refill would have taken); B = the other one
        let followers := (entries.filter fun e => e.partition == 0 && podOf e.fqdn != mPod).map (podOf ·.fqdn)
        let [aPod, bPod] := followers | return .fail s!"precondition: expected two followers, got {followers}"
        let some aIp ← getPodIp aPod cfg.«namespace» | return .fail s!"no IP for {aPod}"
        let some bIp ← getPodIp bPod cfg.«namespace» | return .fail s!"no IP for {bPod}"
        let base ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "ord_base" 30
        if base != 30 then return .fail s!"precondition: only {base}/30 base keys stored"
        let some h0 ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "the master's head is unreadable"
        let both ← waitForCondition s!"both followers applied the base keys (head {h0})" 120 do
          return ((← statNat aIp "repl_applied_lsn").getD 0 ≥ h0) && ((← statNat bIp "repl_applied_lsn").getD 0 ≥ h0)
        if !both then return .fail "precondition: the followers did not apply the base keys"
        match ← cutLink mIp aIp with
        | .error e => return .fail s!"could not cut master ⇄ {aPod}: {e}"
        | .ok _ => pure ()
        try
          IO.sleep 2000
          let later ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "ord_late" 30
          if later != 30 then return .fail s!"precondition: only {later}/30 later keys stored"
          let some h1 ← statNat mIp "rocksdb_latest_sequence_number" | return .fail "the master's head is unreadable"
          let bCaught ← waitForCondition s!"{bPod} applied the later keys (head {h1})" 120 do
            return (← statNat bIp "repl_applied_lsn").getD 0 ≥ h1
          let aApplied := (← statNat aIp "repl_applied_lsn").getD 0
          let bApplied := (← statNat bIp "repl_applied_lsn").getD 0
          IO.eprintln s!"# applied: {aPod}={aApplied} (stale), {bPod}={bApplied}, master head {h1}"
          if !bCaught then return .fail s!"precondition: {bPod} did not apply the later keys ({bApplied} < {h1})"
          if aApplied ≥ bApplied then return .fail s!"precondition: {aPod} is not behind {bPod} ({aApplied} vs {bApplied}): no order to test"
          -- the master is lost for good: its node is cordoned, its pod deleted
          let mNode ← match ← kubectl ["get", "pod", mPod, "-n", cfg.«namespace», "-o", "jsonpath={.spec.nodeName}"] with
            | .ok o => pure o.trim
            | .error e => return .fail s!"no node for {mPod}: {e}"
          match ← kubectl ["cordon", mNode] with
          | .error e => return .fail s!"could not cordon {mNode}: {e}"
          | .ok _ => pure ()
          discard <| kubectl ["delete", "pod", mPod, "-n", cfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          let promoted ← waitForCondition s!"a new P0 master after {mPod} is lost" 240 do
            match ← p0Master with
            | some m => return m != mPod
            | none => return false
          discard <| kubectl ["uncordon", mNode]
          if !promoted then return .fail s!"no successor was promoted after {mPod} was lost"
          let some m2 ← p0Master | return .fail "no master after the wait"
          IO.eprintln s!"# promoted {m2} (larger applied: {bPod}; stale: {aPod})"
          if m2 != bPod then
            return .fail s!"{m2} was promoted, but {bPod} (applied {bApplied}) held newer data than {aPod} (applied {aApplied})"
          let some m2Ip ← getPodIp m2 cfg.«namespace» | return .fail s!"no IP for {m2}"
          -- read only once the promoted node itself applied the map: before
          -- that it still forwards reads to the lost master and they come
          -- back as misses (41103383413: read 1 s after the commit)
          let applied ← waitForCondition s!"{m2} reports own_role master" 60 do
            match ← execInDebugPod cfg.debugPod cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {m2Ip} {cfg.flarePort}" with
            | .ok o => return containsSubstr o "STAT own_role master"
            | .error _ => return false
          if !applied then return .fail s!"{m2} never reported itself master (the promotion map was not applied)"
          for (pfx, n) in [("ord_base", 30), ("ord_late", 30)] do
            for i in [0:n] do
              match ← memcachedGet cfg.debugPod cfg.«namespace» m2Ip cfg.flarePort s!"{pfx}_{i}" with
              | some _ => pure ()
              | none => return .fail s!"{pfx}_{i} is missing on the promoted master {m2}"
          return .pass
        finally
          healLink mIp aIp
          for node in ← kindNodes do
            discard <| kubectl ["uncordon", node] },
    { name := "(review of ae8ac49) stale pod addresses: a slave's OLD IP is cut from the operator and its pod recreated (new IP, reachable) — the slave is never marked unreachable; with the reachability step's pod listing failing (FLARE_TEST_REACH_LIST_FAIL_FILE) while the master is cut, nothing is marked down and the master is unchanged for 60 s"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let opIp ← match ← opIpOf with
          | .ok ip => pure ip
          | .error e => return .fail e
        let some sPod := ((← nodeView).filter fun e => e.partition == 0 && e.role == 1).head?.map (podOf ·.fqdn)
          | return .fail "precondition: no slave of partition 0"
        let some sIp ← getPodIp sPod cfg.«namespace» | return .fail s!"no IP for {sPod}"
        let before := countLines (← opLogs) "UNREACHABLE" sPod
        match ← cutLink opIp sIp with
        | .error e => return .fail s!"could not cut operator ⇄ {sIp}: {e}"
        | .ok _ => pure ()
        try
          discard <| kubectl ["delete", "pod", sPod, "-n", cfg.«namespace», "--wait=false"]
          let moved ← waitForCondition s!"{sPod} is recreated on another IP and Ready" 180 do
            match ← getPodIp sPod cfg.«namespace» with
            | some ip => return ip != sIp && (← allPodsReady)
            | none => return false
          if !moved then return .fail s!"precondition: {sPod} did not come back Ready on another IP than {sIp}"
          IO.sleep 30000   -- six probe rounds against the new address
          let after := countLines (← opLogs) "UNREACHABLE" sPod
          IO.eprintln s!"# {sPod}: old IP {sIp} cut, recreated on {(← getPodIp sPod cfg.«namespace»).getD "-"}; UNREACHABLE lines {before} -> {after}"
          if after > before then return .fail s!"{sPod} was marked unreachable after it was recreated on a reachable IP (its old IP stayed cut)"
        finally
          healLink opIp sIp
        if !(← waitP0Stable) then return .fail "partition 0 did not settle after the recreation"
        -- part 2: no fresh listing, no decision
        let some mPod ← p0Master | return .fail "no Active P0 master in the operator's map"
        let some mIp ← getPodIp mPod cfg.«namespace» | return .fail s!"no IP for {mPod}"
        match ← opExec "touch /tmp/reachfail" with
        | .error e => return .fail s!"could not arm the listing-failure seam: {e}"
        | .ok _ => pure ()
        try
          match ← cutLink opIp mIp with
          | .error e => return .fail s!"could not cut operator ⇄ {mIp}: {e}"
          | .ok _ => pure ()
          for i in [0:6] do
            IO.sleep 10000
            match ← p0Master with
            | some m => if m != mPod then return .fail s!"{mPod} was replaced by {m} while the reachability listing failed ({(i + 1) * 10} s)"
            | none => return .fail s!"{mPod} is no longer the Active master while the reachability listing failed ({(i + 1) * 10} s)"
          let logs ← opLogs
          if countLines logs "reachability: pod listing failed" "no down decision" == 0 then
            return .fail "the operator never logged that the reachability step skipped its round for a failed listing"
          return .pass
        finally
          discard <| opExec "rm -f /tmp/reachfail"
          healLink opIp mIp
          discard <| waitP0Stable },
    { name := "(review of a74d3ec) a slave's failure streak does not pass to its recreated pod: its old IP is cut until it fails a probe, the pod is deleted (missing from the listing) and recreated under the same name, and the NEW pod is cut once Ready — it is marked down no sooner than three of its own failed probes (~10 s after the cut), never at its first"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let opIp ← match ← opIpOf with
          | .ok ip => pure ip
          | .error e => return .fail e
        let some sPod := ((← nodeView).filter fun e => e.partition == 0 && e.role == 1).head?.map (podOf ·.fqdn)
          | return .fail "precondition: no slave of partition 0"
        let some oldIp ← getPodIp sPod cfg.«namespace» | return .fail s!"no IP for {sPod}"
        let down0 := countLines (← opLogs) "UNREACHABLE" sPod
        match ← cutLink opIp oldIp with
        | .error e => return .fail s!"could not cut operator ⇄ {oldIp}: {e}"
        | .ok _ => pure ()
        try
          IO.sleep 7000   -- one or two failed probes of the old pod, not three
          if countLines (← opLogs) "UNREACHABLE" sPod > down0 then
            return .fail "precondition: the old pod was already marked down before its deletion (three probes in 7 s)"
          discard <| kubectl ["delete", "pod", sPod, "-n", cfg.«namespace», "--wait=false"]
          -- the new pod registers with the operator first (cut before that,
          -- it never becomes active nor Ready: 41253435088); it is cut the
          -- moment it is Ready, so its first probes fail
          let ready ← waitForCondition s!"{sPod} is recreated on another IP and Ready" 180 do
            match ← getPodIp sPod cfg.«namespace» with
            | some ip =>
              if ip == oldIp then return false
              match ← kubectl ["get", "pod", sPod, "-n", cfg.«namespace», "-o", "jsonpath={.status.containerStatuses[0].ready}"] with
              | .ok o => return o.trim == "true"
              | .error _ => return false
            | none => return false
          if !ready then return .fail s!"precondition: {sPod} did not come back Ready on another IP"
          let newIp := (← getPodIp sPod cfg.«namespace»).getD ""
          match ← cutLink opIp newIp with
          | .error e => return .fail s!"could not cut operator ⇄ {newIp}: {e}"
          | .ok _ => pure ()
          let t0 ← IO.monoMsNow
          let down1 := countLines (← opLogs) "UNREACHABLE" sPod
          let mut downAt : Option Nat := none
          for _ in [0:60] do
            if countLines (← opLogs) "UNREACHABLE" sPod > down1 then
              downAt := some ((← IO.monoMsNow) - t0)
              break
            IO.sleep 1000
          IO.eprintln s!"# {sPod}: old IP {oldIp} cut, recreated on {newIp} and cut; marked down {downAt.map (s!"{·} ms") |>.getD "not within 60 s"} after the cut of the new IP"
          match downAt with
          | some ms => if ms < 8000 then return .fail s!"the recreated {sPod} was marked down {ms} ms after its new IP was cut — fewer than its own three probes (the old pod's failures were added)"
          | none => return .fail s!"the recreated {sPod}, cut from its first probe, was never marked down within 60 s"
          return .pass
        finally
          -- the pod's address now, not `newIp`: a `let mut` set in the try is
          -- not seen here when the try returns early
          healLink opIp oldIp
          match ← getPodIp sPod cfg.«namespace» with
          | some ip => if ip != oldIp then healLink opIp ip
          | none => pure ()
          discard <| waitP0Stable },
    { name := "(review of fac7410) the mid-pass lease check affirms authority only from a renew answered with 5 s of the 15 s lease left: with every renew answered 11 s late (FLARE_TEST_LEASE_RENEW_DELAY_FILE) a slave's pod is deleted — the check refuses and no node map is broadcast for 40 s; with the delay removed the map goes out and partition 0 settles"
      run := do
        if !(← graceOver) then return .fail "the operator never logged the end of its startup grace period"
        if !(← waitP0Stable) then return .fail "precondition: partition 0 is not stable"
        let some sPod := ((← nodeView).filter fun e => e.partition == 0 && e.role == 1).head?.map (podOf ·.fqdn)
          | return .fail "precondition: no slave of partition 0"
        let refused0 := countLines (← opLogs) "LEASE CHECK: authority NOT confirmed" "the renew took"
        match ← opExec "echo 11000 > /tmp/renewdelay" with
        | .error e => return .fail s!"could not arm the renew-delay seam: {e}"
        | .ok _ => pure ()
        try
          discard <| kubectl ["delete", "pod", sPod, "-n", cfg.«namespace», "--wait=false"]
          -- the deletion moves the map; its broadcast is checked first
          let refused ← waitForCondition "the lease check refuses a renew answered 11 s late" 120 do
            return countLines (← opLogs) "LEASE CHECK: authority NOT confirmed" "the renew took" > refused0
          if !refused then return .fail "the lease check never refused a renew answered 11 s late (less than the 5 s margin of the 15 s lease left)"
          IO.sleep 40000
          -- this window's log alone (a tail of fixed length scrolls)
          let win ← match ← kubectl ["logs", "-n", cfg.«namespace», "-l", s!"app={cfg.operatorName}", "--since=39s", "--tail=-1"] with
            | .ok o => pure o
            | .error e => return .fail s!"could not read the operator log of the window: {e}"
          let sent := countLines win "[TopologyBroadcast] Broadcasting node sync" "to"
          IO.eprintln s!"# renew delayed 11 s: refusals in the window {countLines win "LEASE CHECK: authority NOT confirmed" "the renew took"}, broadcasts {sent}"
          if sent > 0 then return .fail s!"{sent} node map broadcast(s) went out in 39 s while every renew was answered with less than the margin of the lease left"
        finally
          discard <| opExec "rm -f /tmp/renewdelay"
        -- the recreated slave is Ready only once it has the map: the
        -- broadcast went out after the delay was removed
        if !(← waitP0Stable) then return .fail "partition 0 did not settle once the renew answered in time again"
        return .pass }
  ]
}

end FlareOperator.E2E.Tests.FailoverOrder
