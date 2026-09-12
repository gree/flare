/-
  E2E/Tests/ReplicaRepair.lean — SAF-02 / SAF-05, SC-03 / EV-03.

  "A replica with missed writes remains repair-pending until reconstruction
  completes and missing data is recovered."

  The fault is real, not simulated: the kind node's iptables rejects TCP
  from the master pod to the slave pod's flared port (FORWARD chain — with
  the ptp CNI every pod-to-pod packet is routed by the node). The master's
  proxied writes then fail after their retries and are counted in
  `proxy_write_dropped[<slave>]`; the client was told STORED, so the slave
  is quietly behind. Nothing else touches the slave: it stays Slave/Active
  in the same partition, which is exactly the case the old repair missed
  (a state-only change dispatches nothing in flared).

  What is asserted, in order, against real flared:
    1. writes replicate (control);
    2. under the partition the master records drops and the slave lacks
       the keys; after healing, the operator REQUESTS a repair (log, status
       ledger, metric);
    3. the repair runs end to end: the slave is demoted and HELD, confirms
       the map, is re-seated, flared's own reconstruction_started and
       reconstruction_completed counters move, the operator records
       completion, the ledger empties, every dropped key is readable on the
       slave, and no further drop was needed;
    4. SAF-05: with resync disabled the same drop is HELD in the ledger (no
       demotion), the ledger survives an operator restart, and the restarted
       operator with the gate open repairs it without another drop.

  Every fault-injecting step heals in every exit path.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup

namespace FlareOperator.E2E.Tests.ReplicaRepair

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl
open FlareOperator.K8s

private def cfg : ClusterConfig := {
  name := "repl-repair"
  «namespace» := "flare-repl-repair"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-repl-repair"
  -- 5 minutes in production; a repair must be watchable within a test.
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
}

/-- The kind node every pod runs on (single-node cluster, same in CI). -/
private def kindNode : String := "flare-e2e-control-plane"

private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

private def nodeView : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- (masterPod, masterIp, slavePod, slaveIp) for partition 0, or an error. -/
private def pair : IO (Except String (String × String × String × String)) := do
  let entries ← nodeView
  match findMasterFqdn entries 0 with
  | none => return .error "no Active P0 master in the operator's map"
  | some mFqdn =>
    match entries.find? (fun e => e.role == 1 && e.partition == 0) with
    | none => return .error "no P0 slave in the operator's map"
    | some s =>
      match ← getPodIp (podOf mFqdn) cfg.«namespace», ← getPodIp (podOf s.fqdn) cfg.«namespace» with
      | some mIp, some sIp => return .ok (podOf mFqdn, mIp, podOf s.fqdn, sIp)
      | _, _ => return .error "could not resolve master/slave pod IPs"

/-- One numeric `stats` value straight from a flared pod. -/
private def flaredStat (targetIp key : String) : IO (Option Nat) := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {targetIp} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return none
  | .ok output =>
    for line in output.splitOn "\n" do
      let t := (line.trim.replace "\r" "")
      if t.startsWith s!"STAT {key} " then
        return (t.drop s!"STAT {key} ".length).trim.toNat?
    return none

/-- A flared node's LOCAL item count. Reads must not be trusted here: op_get
    proxies a miss to the master (queue_proxy_read), so a `get` for a dropped
    key returns the master's copy and hides the local gap. curr_items is
    local storage and does not. -/
private def currItems (ip : String) : IO Nat :=
  return (← flaredStat ip "curr_items").getD 0

/-- Sum of the master's per-destination dropped-write counters. -/
private def droppedByMaster (masterIp : String) : IO Nat := do
  let cmd := s!"printf 'stats\\r\\n' | nc -w 3 {masterIp} {cfg.flarePort}"
  match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
  | .error _ => return 0
  | .ok output =>
    let mut total := 0
    for line in output.splitOn "\n" do
      let t := (line.trim.replace "\r" "")
      if t.startsWith "STAT proxy_write_dropped[" then
        match (t.splitOn " ").getLast? >>= (·.trim.toNat?) with
        | some n => total := total + n
        | none => pure ()
    return total

private def opLog (tail : Nat := 600) : IO String :=
  kubectlLogsLabel s!"app={cfg.operatorName}" cfg.«namespace» tail

/-- One operator metric value (counters render as integers). -/
private def operatorMetric (name : String) : IO (Option Nat) := do
  let ips ← getPodIps s!"app={cfg.operatorName}" cfg.«namespace»
  match ips.head? with
  | none => return none
  | some ip =>
    let cmd := s!"printf 'GET /metrics HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' | nc -w 3 {ip} 9090"
    match ← execInDebugPod cfg.debugPod cfg.«namespace» cmd with
    | .error _ => return none
    | .ok out =>
      for line in out.splitOn "\n" do
        let t := line.trim
        if t.startsWith name && !(t.startsWith "#") then
          match (t.splitOn " ").getLast? with
          | some v =>
            -- Prometheus renders gauges as floats ("0.000000"); take the
            -- integer part so both counters and gauges parse.
            let intPart := (v.trim.splitOn ".").headD v.trim
            return intPart.toNat?
          | none => pure ()
      return none

/-- Destinations currently in status.replicaRepairs.entries. -/
private def ledgerDests : IO (List String) := do
  match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{.status.replicaRepairs.entries[*].dest}" with
  | .ok out => return (out.trim.splitOn " ").filter (· != "")
  | .error _ => return []

private def ledgerHolds : IO (List String) := do
  match ← kubectlGetJsonpath "flarecluster" cfg.name cfg.«namespace» "{.status.replicaRepairs.entries[*].hold}" with
  | .ok out => return (out.trim.splitOn " ").filter (· != "")
  | .error _ => return []

-- ─── the fault ─────────────────────────────────────────────────────────

private def ruleSpec (masterIp slaveIp : String) : List String :=
  ["FORWARD", "-s", masterIp, "-d", slaveIp, "-p", "tcp", "--dport", toString cfg.flarePort,
   "-j", "REJECT", "--reject-with", "tcp-reset"]

/-- Reject master→slave flared traffic on the node. Existing connections get
    RST on their next packet, new connects are refused at once, so the
    master's proxy retries fail fast and the write is DROPPED. -/
private def cutMasterToSlave (masterIp slaveIp : String) : IO (Except String Unit) := do
  match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I"] ++ ["FORWARD", "1"] ++ (ruleSpec masterIp slaveIp).drop 1) with
  | .ok _ => IO.eprintln s!"# fault: rejecting {masterIp} → {slaveIp}:{cfg.flarePort} on {kindNode}"; return .ok ()
  | .error e => return .error e

/-- Remove every copy of the rule (idempotent; safe to call on every exit). -/
private def heal (masterIp slaveIp : String) : IO Unit := do
  for _ in [0:5] do
    match ← hostCmd "docker" (["exec", kindNode, "iptables", "-D"] ++ ruleSpec masterIp slaveIp) with
    | .ok _ => pure ()
    | .error _ => break
  IO.eprintln s!"# fault cleared: {masterIp} → {slaveIp} forwards again"

/-- What one partitioned write burst produced: the keys, the master's drop
    counter afterwards, and the LOCAL item gap (master − slave) measured
    WHILE the link was still cut — before any demote could reconstruct it
    away. A positive gap is the proof that writes are locally missing on the
    slave, which a proxied `get` cannot show. -/
structure Burst where
  keys : List String
  droppedTotal : Nat
  gapWhileCut : Nat

private def writeUnderPartition (masterIp slaveIp keyPrefix : String) (count : Nat)
    : IO (Except String Burst) := do
  let d0 ← droppedByMaster masterIp
  match ← cutMasterToSlave masterIp slaveIp with
  | .error e => return .error s!"could not inject the fault: {e}"
  | .ok _ =>
    IO.sleep 2000
    let stored ← writeKeys cfg.debugPod cfg.«namespace» masterIp cfg.flarePort keyPrefix count
    let keys := (List.range count).map fun i => s!"{keyPrefix}_{i}"
    let dropped ← waitForCondition s!"master counts dropped writes to the slave (was {d0})" 120 do
      return (← droppedByMaster masterIp) > d0
    let d1 ← droppedByMaster masterIp
    if !dropped then
      heal masterIp slaveIp
      return .error s!"the master never counted a dropped write while the link was cut (stored {stored}/{count} on the master; proxy_write_dropped stayed {d1}) — the fault did not reach the proxy path"
    -- Local gap NOW, link still cut: the slave has not been demoted or
    -- reconstructed yet, so this is the honest count of writes it is missing.
    let mItems ← currItems masterIp
    let sItems ← currItems slaveIp
    let gap := if mItems > sItems then mItems - sItems else 0
    IO.eprintln s!"# stored {stored}/{count} on the master; master dropped {d1 - d0} write(s); local items master={mItems} slave={sItems} (gap {gap})"
    return .ok { keys := keys, droppedTotal := d1, gapWhileCut := gap }

private def diagnostics (masterIp slaveIp : String) : IO Unit := do
  IO.eprintln s!"# operator tail:\n{← opLog 40}"
  IO.eprintln s!"# ledger dests: {← ledgerDests}; holds: {← ledgerHolds}"
  IO.eprintln s!"# master dropped total: {← droppedByMaster masterIp}"
  IO.eprintln s!"# slave reconstruction started/completed: {← flaredStat slaveIp "reconstruction_started"}/{← flaredStat slaveIp "reconstruction_completed"}"
  IO.eprintln s!"# node view: {repr (← nodeView)}"

/-- Wait for the whole repair to land: completion logged, ledger empty,
    the slave's reconstruction counters moved past `started0/completed0`, the
    slave's LOCAL item count caught up to the master's, and NO new drop since
    `droppedAfterHeal`. -/
private def awaitRepair (masterIp slaveIp : String)
    (started0 completed0 droppedAfterHeal : Nat) (budget : Nat) : IO TestResult := do
  let done ← waitForCondition "operator records REPLICA REPAIR COMPLETE" budget do
    return containsSubstr (← opLog) "REPLICA REPAIR COMPLETE"
  if !done then
    diagnostics masterIp slaveIp
    return .fail s!"the repair did not complete within {budget}s (no REPLICA REPAIR COMPLETE in the operator log)"
  let log ← opLog
  -- The path, not just the destination: demoted+held, confirmed, then done.
  if !containsSubstr log "REPLICA REPAIR: demoting" then
    return .fail "completion was logged but no demotion was: the repair did not go through the hold"
  if !containsSubstr log "confirmed the demotion" then
    return .fail "completion was logged but the node never confirmed the demotion: the hold was skipped"
  let s1 := (← flaredStat slaveIp "reconstruction_started").getD 0
  let c1 := (← flaredStat slaveIp "reconstruction_completed").getD 0
  if !(s1 > started0 && c1 > completed0) then
    diagnostics masterIp slaveIp
    return .fail s!"flared did not report a reconstruction for the repair: started {started0}→{s1}, completed {completed0}→{c1}"
  let emptied ← waitForCondition "ledger persisted as empty" 60 do
    return (← ledgerDests).isEmpty
  if !emptied then
    return .fail s!"the ledger still lists {← ledgerDests} after completion"
  -- Recovery, proven from LOCAL storage: the slave's item count reaches the
  -- master's. A proxied get would pass even with an empty slave.
  let recovered ← waitForCondition "slave's local items catch up to the master's" 120 do
    let m ← currItems masterIp
    let sv ← currItems slaveIp
    return sv ≥ m && m > 0
  if !recovered then
    diagnostics masterIp slaveIp
    return .fail s!"the repair completed but the slave's local curr_items ({← currItems slaveIp}) did not reach the master's ({← currItems masterIp})"
  let dNow ← droppedByMaster masterIp
  if dNow != droppedAfterHeal then
    return .fail s!"the repair itself cost drops: proxy_write_dropped moved {droppedAfterHeal} → {dNow} after the link was healed"
  return .pass

def suite : TestSuite := {
  name := "replica-repair"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      IO.eprintln "# WARNING: cluster did not stabilize during setup"
  teardown := do
    -- Belt and braces: whatever happened, no rule survives the suite.
    match ← pair with
    | .ok (_, mIp, _, sIp) => heal mIp sIp
    | .error _ => pure ()
    cleanupCluster cfg
  onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
  tests := [
    { name := "control: writes to the master replicate to the slave"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let stored ← writeKeys cfg.debugPod cfg.«namespace» mIp cfg.flarePort "base" 40
          if stored < 40 then return .fail s!"only {stored}/40 stored on the master"
          -- LOCAL item counts must converge: a proxied get would pass even
          -- if nothing replicated, so it proves nothing here.
          let replicated ← waitForCondition "slave's local items reach the master's" 60 do
            let m ← currItems mIp
            let sv ← currItems sIp
            return m > 0 && sv ≥ m
          if !replicated then
            return .fail s!"slave local items {← currItems sIp} never reached master {← currItems mIp} — live replication is broken, the repair tests would be meaningless"
          return .pass },

    { name := "cut link: the master drops replica writes and the operator requests a repair"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let requested0 := (← operatorMetric "flare_operator_replica_repair_requested_total").getD 0
          match ← writeUnderPartition mIp sIp "dropped" 30 with
          | .error e => return .fail e
          | .ok burst =>
            heal mIp sIp
            if burst.gapWhileCut == 0 then
              return .fail "the master counted a drop but the slave's local item count did not fall behind: nothing was actually lost locally, so there is nothing to repair"
            IO.eprintln s!"# slave was missing {burst.gapWhileCut} item(s) locally while cut off"
            let requested ← waitForCondition "operator requests a replica repair (probe interval 15s)" 150 do
              return containsSubstr (← opLog) "REPLICA REPAIR requested"
            if !requested then
              diagnostics mIp sIp
              return .fail "the master's drop counter rose but the operator never requested a repair"
            let inLedger ← waitForCondition "ledger in status names the slave" 60 do
              return !(← ledgerDests).isEmpty
            if !inLedger then
              return .fail "a repair was requested but status.replicaRepairs has no entry: the ledger is not persisted"
            let requested1 := (← operatorMetric "flare_operator_replica_repair_requested_total").getD 0
            if !(requested1 > requested0) then
              return .fail s!"flare_operator_replica_repair_requested_total did not move ({requested0} → {requested1})"
            return .pass },

    { name := "the repair runs: held as proxy, confirmed, re-seated, reconstructed; keys recovered without another drop"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          -- Boot gave the slave one reconstruction (Slave/Prepare → Active);
          -- the repair must add another. Read the counters NOW: the request
          -- from the previous test is at most one probe old, and the
          -- demotion happens on the operator's next pass.
          let s0 := (← flaredStat sIp "reconstruction_started").getD 0
          let c0 := (← flaredStat sIp "reconstruction_completed").getD 0
          let dAfterHeal ← droppedByMaster mIp
          match ← awaitRepair mIp sIp (started0 := s0) (completed0 := c0)
              (droppedAfterHeal := dAfterHeal) (budget := 300) with
          | .pass =>
            let completed := (← operatorMetric "flare_operator_replica_repair_completed_total").getD 0
            let pending := (← operatorMetric "flare_operator_replica_repairs_pending").getD 99
            if completed < 1 then return .fail "flare_operator_replica_repair_completed_total is 0 after a logged completion"
            if pending != 0 then return .fail s!"flare_operator_replica_repairs_pending is {pending} after completion"
            return .pass
          | r => return r },

    { name := "SAF-05: a drop seen while resync is disabled is held, survives an operator restart, and is repaired once the gate opens"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          -- Close the gate by restarting the operator with resync disabled.
          match ← kubectl ["set", "env", s!"deployment/{cfg.operatorName}", "-n", cfg.«namespace», "FLARE_RESYNC_ON_DROP=0"] with
          | .error e => return .fail s!"could not set the gate: {e}"
          | .ok _ => pure ()
          if !(← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 240) then
            return .fail "operator rollout with FLARE_RESYNC_ON_DROP=0 did not complete"
          let restored ← waitForCondition "restarted operator restores the ledger from status" 120 do
            return containsSubstr (← opLog) "replica repair ledger restored from status"
          if !restored then
            return .fail "the restarted operator did not restore a ledger from status (counters would be re-baselined, drops lost)"
          -- The gated drop.
          match ← writeUnderPartition mIp sIp "gated" 20 with
          | .error e => return .fail e
          | .ok burst =>
            heal mIp sIp
            if burst.gapWhileCut == 0 then
              return .fail "the gated burst left no local gap on the slave: nothing to hold"
            let dAfterHeal ← droppedByMaster mIp
            let held ← waitForCondition "operator HOLDS the repair (gate closed)" 150 do
              return containsSubstr (← opLog) "replica repair HELD"
            if !held then
              diagnostics mIp sIp
              return .fail "with resync disabled the drop was neither held nor logged: it was consumed"
            let holds ← ledgerHolds
            if holds.isEmpty then
              return .fail "the HELD entry is not persisted with its gate reason"
            -- Nothing may act while the gate is closed.
            IO.sleep 20000
            let logGated ← opLog
            if containsSubstr logGated "REPLICA REPAIR: demoting" then
              return .fail "the operator demoted the replica although resync was disabled"
            match (← nodeView).find? (fun e => e.role == 1 && e.partition == 0) with
            | none => return .fail "the slave left the map while the repair was held"
            | some e => if e.state != 0 then return .fail "the slave is not Slave/Active while held: something acted"
            -- Open the gate: a NEW operator process must pick the request up
            -- from status and finish it without any further drop.
            let s0 := (← flaredStat sIp "reconstruction_started").getD 0
            let c0 := (← flaredStat sIp "reconstruction_completed").getD 0
            match ← kubectl ["set", "env", s!"deployment/{cfg.operatorName}", "-n", cfg.«namespace», "FLARE_RESYNC_ON_DROP-"] with
            | .error e => return .fail s!"could not open the gate: {e}"
            | .ok _ => pure ()
            if !(← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 240) then
              return .fail "operator rollout with the gate open did not complete"
            let restored2 ← waitForCondition "restarted operator restores the HELD request" 120 do
              let l ← opLog
              return containsSubstr l "replica repair ledger restored from status" && containsSubstr l "requested"
            if !restored2 then
              diagnostics mIp sIp
              return .fail "the operator that should repair did not restore the pending request from status"
            awaitRepair mIp sIp (started0 := s0) (completed0 := c0)
              (droppedAfterHeal := dAfterHeal) (budget := 360) }
  ]
}

end FlareOperator.E2E.Tests.ReplicaRepair
