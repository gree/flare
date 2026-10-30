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
  partitions := 1
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-fo-order"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000"
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
  for spec in [rule a b, rule b a] do
    match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ spec.drop 1) with
    | .error e => return .error e
    | .ok _ => pure ()
  return .ok ()

private def healLink (a b : String) : IO Unit := do
  for spec in [rule a b, rule b a] do
    for _ in [0:5] do
      match ← hostCmd "docker" (["exec", kindNode, "iptables", "-D"] ++ spec) with
      | .ok _ => pure ()
      | .error _ => break

private def p0Master : IO (Option String) := do
  return (findMasterFqdn (← nodeView) 0).map podOf

def suite : TestSuite := {
  name := "failover-order"
  setup := do
    deployCluster cfg
    IO.sleep 50000
  teardown := do
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "two followers: the master is lost while one follower is stale; the follower with the LARGER applied sequence is promoted, and every key is on it"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
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
          match ← kubectl ["cordon", kindNode] with
          | .error e => return .fail s!"could not cordon {kindNode}: {e}"
          | .ok _ => pure ()
          discard <| kubectl ["delete", "pod", mPod, "-n", cfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          let promoted ← waitForCondition s!"a new P0 master after {mPod} is lost" 240 do
            match ← p0Master with
            | some m => return m != mPod
            | none => return false
          discard <| kubectl ["uncordon", kindNode]
          if !promoted then return .fail s!"no successor was promoted after {mPod} was lost"
          let some m2 ← p0Master | return .fail "no master after the wait"
          IO.eprintln s!"# promoted {m2} (larger applied: {bPod}; stale: {aPod})"
          if m2 != bPod then
            return .fail s!"{m2} was promoted, but {bPod} (applied {bApplied}) held newer data than {aPod} (applied {aApplied})"
          let some m2Ip ← getPodIp m2 cfg.«namespace» | return .fail s!"no IP for {m2}"
          for (pfx, n) in [("ord_base", 30), ("ord_late", 30)] do
            for i in [0:n] do
              match ← memcachedGet cfg.debugPod cfg.«namespace» m2Ip cfg.flarePort s!"{pfx}_{i}" with
              | some _ => pure ()
              | none => return .fail s!"{pfx}_{i} is missing on the promoted master {m2}"
          return .pass
        finally
          healLink mIp aIp
          discard <| kubectl ["uncordon", kindNode] }
  ]
}

end FlareOperator.E2E.Tests.FailoverOrder
