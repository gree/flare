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
       operator with the gate open repairs it without another drop;
    5. SAF-05 (ledger persistence): with the operator's permission to write
       flareclusters/status revoked, a new request is marked UNSAVED, retried
       every pass, lands once the permission is effective FOR THE OPERATOR
       (probed from inside its pod, as its own SA; landing judged by the
       entry being in status, whichever persist path wrote it), and survives
       a restart;
    6. SAF-05 (ledger read failure): a CORRUPT ledger in status is reported
       unavailable — the operator never replaces it with an empty one — no
       drop is accounted meanwhile, and once the ledger is repaired the drop
       seen during the outage is requested and recovered (counters were not
       re-baselined);
    7. SAF-06 (delete precondition): the operator's own delete command carries
       the observed pod UID as DeleteOptions.preconditions.uid; the apiserver
       accepts it for the matching pod and REFUSES it (409) for a same-name
       replacement with another UID, which survives;
    8. SAF-06 (delete deadline): the same command against a server that
       ACCEPTS the connection (proved server-side by the bytes it received)
       and never answers ends by curl's timeout (exit 28) within the
       deadline, so a stalled API cannot stall the reconcile; a refused
       connection does not pass this test.

  Every fault-injecting step heals in every exit path.
-/
import Lean.Data.Json
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.K8s.Bridge

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

/-- (masterPod, masterIp, replicaPod, replicaIp) for partition 0, or an error.
    The replica is THE OTHER NODE of this 1-partition, 2-node cluster, whatever
    role the map gives it right now: a repair in flight legitimately cycles it
    Slave → Proxy (held) → Slave/Prepare → Active, and a test that starts in
    the instant after a demotion must still find it (CI run 34806038692:
    tests 3-6 all failed at once with "no P0 slave" because the pass after
    test 2's request had just demoted it). Every caller uses the pod IP for
    flared stats, which does not depend on the role. Retried briefly: the map
    is read over TCP mid-reconcile and can be one pass behind. -/
private def pair : IO (Except String (String × String × String × String)) := do
  let mut lastErr := ""
  for _ in [0:6] do
    let entries ← nodeView
    match findMasterFqdn entries 0 with
    | none => lastErr := "no Active P0 master in the operator's map"
    | some mFqdn =>
      match entries.find? (fun e => e.fqdn != mFqdn) with
      | none => lastErr := "no second node (the replica under repair) in the operator's map"
      | some s =>
        match ← getPodIp (podOf mFqdn) cfg.«namespace», ← getPodIp (podOf s.fqdn) cfg.«namespace» with
        | some mIp, some sIp => return .ok (podOf mFqdn, mIp, podOf s.fqdn, sIp)
        | _, _ => lastErr := "could not resolve master/replica pod IPs"
    IO.sleep 5000
  return .error lastErr

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
  -- The path, not just the destination: demoted+held, confirmed, then done.
  -- Those two lines precede completion by a minute or more of verbose
  -- per-pass output, so they can scroll out of ANY fixed log tail before
  -- COMPLETE appears; record them as they are seen during the poll instead
  -- of looking for them in the final snapshot.
  let sawDemote ← IO.mkRef false
  let sawConfirm ← IO.mkRef false
  let done ← waitForCondition "operator records REPLICA REPAIR COMPLETE" budget do
    let l ← opLog 2000
    if containsSubstr l "REPLICA REPAIR: demoting" then sawDemote.set true
    if containsSubstr l "confirmed the demotion" then sawConfirm.set true
    return containsSubstr l "REPLICA REPAIR COMPLETE"
  if !done then
    diagnostics masterIp slaveIp
    return .fail s!"the repair did not complete within {budget}s (no REPLICA REPAIR COMPLETE in the operator log)"
  if !(← sawDemote.get) then
    return .fail "completion was logged but no demotion was observed during the wait: the repair did not go through the hold"
  if !(← sawConfirm.get) then
    return .fail "completion was logged but the node was never observed confirming the demotion: the hold was skipped"
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

-- ─── ledger faults (tests 5 and 6) ─────────────────────────────────────

/-- Rule 0 of the operator's ClusterRole grants both `flareclusters` and
    `flareclusters/status`. Dropping the status resource makes the ledger's
    status patch fail (403) while the CR stays readable: a clean persistence
    fault, nothing else in the operator needs that write outside a migration. -/
private def revokeStatusWrite : IO (Except String String) :=
  kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
    "[{\"op\":\"replace\",\"path\":\"/rules/0/resources\",\"value\":[\"flareclusters\"]}]"]

/-- Idempotent; safe on every exit path and in teardown. -/
private def restoreStatusWrite : IO Unit := do
  discard <| kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
    "[{\"op\":\"replace\",\"path\":\"/rules/0/resources\",\"value\":[\"flareclusters\",\"flareclusters/status\"]}]"]

/-- status.replicaRepairs as compact JSON, to save and later restore. -/
private def ledgerRawJson : IO (Option String) := do
  match ← kubectl ["get", "flarecluster", cfg.name, "-n", cfg.«namespace», "-o", "json"] with
  | .error _ => return none
  | .ok out =>
    match Lean.Json.parse out with
    | .error _ => return none
    | .ok j =>
      match j.getObjVal? "status" >>= (·.getObjVal? "replicaRepairs") with
      | .ok r => return some r.compress
      | .error _ => return none

private def patchLedgerRaw (raw : String) : IO (Except String String) :=
  kubectl ["patch", "flarecluster", cfg.name, "-n", cfg.«namespace», "--subresource=status",
           "--type=merge", "-p", s!"\{\"status\":\{\"replicaRepairs\":{raw}}}"]

private def setGate (closed : Bool) : IO (Except String Unit) := do
  let arg := if closed then "FLARE_RESYNC_ON_DROP=0" else "FLARE_RESYNC_ON_DROP-"
  match ← kubectl ["set", "env", s!"deployment/{cfg.operatorName}", "-n", cfg.«namespace», arg] with
  | .error e => return .error e
  | .ok _ =>
    if ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 240 then return .ok ()
    else return .error "operator rollout did not complete"

private def restartOperator : IO Bool := do
  discard <| kubectl ["rollout", "restart", s!"deployment/{cfg.operatorName}", "-n", cfg.«namespace»]
  kubectlRolloutStatus s!"deployment/{cfg.operatorName}" cfg.«namespace» 240

def suite : TestSuite := {
  name := "replica-repair"
  setup := do
    cleanupCluster cfg
    deployCluster cfg
    let stable ← waitForStable cfg 50
    if !stable then
      IO.eprintln "# WARNING: cluster did not stabilize during setup"
  teardown := do
    -- Belt and braces: whatever happened, no rule and no RBAC hole survives.
    restoreStatusWrite
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
            -- The HELD line is logged in the pass that decides it; the persist
            -- (and its dirty retry) lands within a pass or two. Wait for it
            -- rather than reading status once, immediately after the log line.
            let persisted ← waitForCondition "HELD entry persisted to status with its gate reason" 90 do
              return !(← ledgerHolds).isEmpty
            if !persisted then
              return .fail "the HELD entry was not persisted with its gate reason within 90s"
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
              (droppedAfterHeal := dAfterHeal) (budget := 360) },

    { name := "SAF-05: a ledger save that fails is marked unsaved, retried every pass, lands when allowed, and survives a restart"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          if !(← ledgerDests).isEmpty then
            return .fail s!"precondition: the ledger is not empty ({← ledgerDests})"
          -- Close the gate so the request stays PENDING (held) rather than
          -- being repaired in memory before the save can be observed.
          match ← setGate true with
          | .error e => return .fail s!"could not close the gate: {e}"
          | .ok _ => pure ()
          match ← revokeStatusWrite with
          | .error e => return .fail s!"could not revoke the status write: {e}"
          | .ok _ => IO.eprintln "# fault: the operator may no longer patch flareclusters/status"
          match ← writeUnderPartition mIp sIp "unsaved" 20 with
          | .error e => restoreStatusWrite; return .fail e
          | .ok burst =>
            heal mIp sIp
            if burst.gapWhileCut == 0 then restoreStatusWrite; return .fail "the burst left no local gap"
            let unsaved ← waitForCondition "operator marks the ledger UNSAVED after the failed persist" 150 do
              return containsSubstr (← opLog) "marked unsaved and will retry"
            if !unsaved then
              restoreStatusWrite; diagnostics mIp sIp
              return .fail "a failed save was not marked unsaved (a restart now would silently lose the request)"
            if !(← ledgerDests).isEmpty then
              restoreStatusWrite
              return .fail s!"status shows an entry although the write was forbidden: {← ledgerDests}"
            let retried ← waitForCondition "operator retries the unsaved ledger on a later pass" 90 do
              return containsSubstr (← opLog) "still unsaved"
            if !retried then restoreStatusWrite; return .fail "no retry of the unsaved ledger was logged on a later pass"
            restoreStatusWrite
            IO.eprintln "# fault cleared: status write allowed again"
            -- Restoring the grant takes effect for the OPERATOR only after a
            -- delay of about two minutes (observed ~131s locally; >124s in CI
            -- run 34818137311). A runner-side `kubectl auth can-i --as=<SA>`
            -- is NOT a proxy for that: in that CI run it said "yes" at once
            -- while the operator's own patch stayed Forbidden for the whole
            -- 120s window, so the previous version of this step timed the
            -- environment's latency and blamed the operator. Probe the
            -- permission the way the operator exercises it — from inside its
            -- pod, as its own service account, over its own token and CA —
            -- and only then time the retry. The operator keeps the ledger
            -- dirty and retries every pass meanwhile (asserted above).
            let ops ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
            let opPod := ops.head?.getD ""
            let tRestore ← IO.monoMsNow
            -- Where does the time go? Three clocks from the restore: (1) the
            -- permission as the operator sees it (in-pod can-i, its own SA and
            -- token), (2) the OUTCOME — the unsaved entry lands in status —
            -- and (3) the deadline. CI runs 35561126678/35565289216/
            -- 35570216917 spent the whole 300 s with the probe answering
            -- "no" while locally it says "yes" at once; the probe alone
            -- cannot tell an authorization delay from a probe fault. So the
            -- deadline is on the outcome, both clocks are recorded, and a
            -- probe that never says yes while the ledger landed is reported
            -- as a probe/harness discrepancy with its raw output.
            let probeYesAt ← IO.mkRef (none : Option Nat)
            let probeRaw ← IO.mkRef ""
            let landed ← waitForCondition "the unsaved ledger lands once the write is allowed (entry present in status; in-pod can-i sampled alongside)" 300 do
              if (← probeYesAt.get).isNone then
                match ← Bridge.execInPod opPod cfg.«namespace» ["sh", "-c", s!"kubectl auth can-i patch flareclusters/status -n {cfg.«namespace»} 2>&1; echo rc=$?"] with
                | .ok o =>
                  probeRaw.set o.trim
                  if (o.splitOn "\n").any (fun l => l.trim == "yes") then probeYesAt.set (some ((← IO.monoMsNow) - tRestore))
                | .error e => probeRaw.set s!"exec failed: {e}"
              return !(← ledgerDests).isEmpty
            let landMs := (← IO.monoMsNow) - tRestore
            let authMs := (← probeYesAt.get)
            let raw := (← probeRaw.get).take 200
            let authText := match authMs with
              | some ms => s!"{ms / 1000}s"
              | none => s!"NEVER (raw: {raw})"
            let viaRetry := containsSubstr (← opLog 2000) "ledger persisted on retry"
            IO.eprintln s!"# timeline from the restore: in-pod can-i said yes after {authText}; unsaved ledger landed after {landMs / 1000}s (via {if viaRetry then "the top-of-pass retry" else "the silent per-pass persist"}); landed={landed}"
            if landed && authMs.isNone then
              -- Runner-side view for the discrepancy report only.
              let asSa := (← kubectl ["auth", "can-i", "patch", "flareclusters/status", "-n", cfg.«namespace», s!"--as=system:serviceaccount:{cfg.«namespace»}:flare-operator"]).toOption.getD "?"
              let rule0 := (← kubectl ["get", "clusterrole", "flare-operator", "-o", "jsonpath={.rules[0]}"]).toOption.getD "?"
              IO.eprintln s!"# PROBE DISCREPANCY: the operator's own write landed but the in-pod can-i never said yes; runner-side can-i --as=SA: {asSa.trim}; rule[0]: {rule0.trim}"
            if !landed then
              diagnostics mIp sIp
              return .fail s!"the unsaved ledger never landed within 300s of the restore (in-pod can-i: {authText})"
            -- And the operator must have stopped calling it unsaved: a landed
            -- ledger that keeps being retried would mean the dirty flag was
            -- not cleared. One probe interval later, no NEW "still unsaved".
            let stillUnsaved (log : String) : Nat := ((log.splitOn "still unsaved").length) - 1
            let n0 := stillUnsaved (← opLog 2000)
            IO.sleep 25000
            let n1 := stillUnsaved (← opLog 2000)
            if n1 > n0 then
              return .fail s!"the ledger landed in status but the operator kept reporting it unsaved ({n0} → {n1} lines): the dirty flag was not cleared by the write that landed it"
            -- Survives a restart: the entry must come back from status.
            if !(← restartOperator) then return .fail "operator restart did not complete"
            let restored ← waitForCondition "restarted operator restores the HELD request from status" 120 do
              let l ← opLog
              return containsSubstr l "restored from status" && containsSubstr l "requested"
            if !restored then diagnostics mIp sIp; return .fail "the request that was saved on retry did not come back after a restart"
            -- Open the gate; the restored request is repaired without another drop.
            let s0 := (← flaredStat sIp "reconstruction_started").getD 0
            let c0 := (← flaredStat sIp "reconstruction_completed").getD 0
            let dAfterHeal ← droppedByMaster mIp
            match ← setGate false with
            | .error e => return .fail s!"could not open the gate: {e}"
            | .ok _ => pure ()
            awaitRepair mIp sIp (started0 := s0) (completed0 := c0)
              (droppedAfterHeal := dAfterHeal) (budget := 360) },

    { name := "SAF-05: a corrupt ledger is held as unavailable, never replaced by an empty one; the drop seen meanwhile is recovered once it is readable"
      run := do
        match ← pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          if !(← ledgerDests).isEmpty then
            return .fail s!"precondition: the ledger is not empty ({← ledgerDests})"
          match ← ledgerRawJson with
          | none => return .fail "could not read the persisted ledger to save it"
          | some raw =>
            match ← patchLedgerRaw "{\"entries\":\"corrupt\"}" with
            | .error e => return .fail s!"could not corrupt the ledger: {e}"
            | .ok _ => IO.eprintln "# fault: status.replicaRepairs.entries is now a string (unparseable)"
            if !(← restartOperator) then discard <| patchLedgerRaw raw; return .fail "operator restart did not complete"
            let held ← waitForCondition "restarted operator reports the ledger UNAVAILABLE (not absent)" 180 do
              return containsSubstr (← opLog) "ledger UNAVAILABLE at start"
            if !held then
              discard <| patchLedgerRaw raw; diagnostics mIp sIp
              return .fail "the operator did not report the corrupt ledger as unavailable"
            if containsSubstr (← opLog) "starting fresh" then
              discard <| patchLedgerRaw raw
              return .fail "the operator started from an EMPTY ledger over a corrupt one (pending requests and counters would be lost)"
            -- While unavailable: a drop must NOT be accounted, and the hold is logged.
            match ← writeUnderPartition mIp sIp "outage" 20 with
            | .error e => discard <| patchLedgerRaw raw; return .fail e
            | .ok burst =>
              heal mIp sIp
              if burst.gapWhileCut == 0 then discard <| patchLedgerRaw raw; return .fail "the burst left no local gap"
              IO.sleep 45000
              let during ← opLog
              if containsSubstr during "REPLICA REPAIR requested" then
                discard <| patchLedgerRaw raw
                return .fail "a drop was accounted while the ledger was unavailable (it would have been baselined against nothing)"
              if !containsSubstr during "holding all repair actions" then
                discard <| patchLedgerRaw raw
                return .fail "no hold was logged while the ledger was unavailable"
              -- Repair the ledger. The counters it carries predate the outage
              -- drop, so recovery must REQUEST it — nothing was re-baselined.
              match ← patchLedgerRaw raw with
              | .error e => return .fail s!"could not restore the ledger: {e}"
              | .ok _ => IO.eprintln "# fault cleared: ledger restored to its pre-corruption content"
              let recovered ← waitForCondition "ledger RECOVERED from status" 120 do
                return containsSubstr (← opLog) "ledger RECOVERED from status"
              if !recovered then diagnostics mIp sIp; return .fail "the operator did not recover the repaired ledger"
              let requested ← waitForCondition "the drop seen during the outage is requested after recovery" 150 do
                return containsSubstr (← opLog) "REPLICA REPAIR requested"
              if !requested then
                diagnostics mIp sIp
                return .fail "the drop observed during the outage was lost: recovery re-baselined the counters"
              let s0 := (← flaredStat sIp "reconstruction_started").getD 0
              let c0 := (← flaredStat sIp "reconstruction_completed").getD 0
              let dAfterHeal ← droppedByMaster mIp
              awaitRepair mIp sIp (started0 := s0) (completed0 := c0)
                (droppedAfterHeal := dAfterHeal) (budget := 360) },

    { name := "SAF-06: the delete carries the observed pod UID as an API precondition; a same-name pod with another UID is refused by the apiserver"
      run := do
        -- Run the operator's EXACT delete command (Bridge.uidPreconditionDeleteCommand)
        -- inside the operator pod, so the token, CA and RBAC are the real ones.
        let ops ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
        match ops.head? with
        | none => return .fail "no operator pod"
        | some opPod =>
          let victim := "uid-victim"
          let mk : IO (Except String String) := kubectl ["run", victim, "-n", cfg.«namespace», "--image=busybox:1.36", "--restart=Never", "--command", "--", "sleep", "3600"]
          let uidOf : IO (Option String) := do
            match ← kubectlGetJsonpath "pod" victim cfg.«namespace» "{.metadata.uid}" with
            | .ok u => return (if u.trim.isEmpty then none else some u.trim)
            | .error _ => return none
          -- The command prints the HTTP status, then "curl_exit=N".
          let runDelete := fun (uid : String) => do
            let out ← Bridge.execInPod opPod cfg.«namespace» ["sh", "-c", Bridge.uidPreconditionDeleteCommand victim cfg.«namespace» uid]
            match out with
            | .ok o =>
              let ls := o.splitOn "\n" |>.filter (· != "") |>.filter (fun l => !l.startsWith "curl_exit=")
              return (ls.getLast?.getD "").trim
            | .error e => return s!"exec-error:{e}"
          match ← mk with
          | .error e => return .fail s!"could not create the victim pod: {e}"
          | .ok _ => pure ()
          let _ ← waitForCondition "victim pod has a UID" 60 do return (← uidOf).isSome
          match ← uidOf with
          | none => return .fail "victim pod never got a UID"
          | some uid1 =>
            -- Delete it with ITS uid: allowed.
            let code1 ← runDelete uid1
            if code1 != "200" && code1 != "202" then
              discard <| kubectl ["delete", "pod", victim, "-n", cfg.«namespace», "--wait=false"]
              return .fail s!"delete with the matching UID was not accepted (http {code1})"
            let gone ← waitForCondition "victim pod gone" 90 do return (← uidOf).isNone
            if !gone then return .fail "victim pod did not go away after the accepted delete"
            -- Recreate under the SAME name: a different UID.
            match ← mk with
            | .error e => return .fail s!"could not recreate the victim pod: {e}"
            | .ok _ => pure ()
            let _ ← waitForCondition "replacement pod has a UID" 60 do return (← uidOf).isSome
            match ← uidOf with
            | none => return .fail "replacement pod never got a UID"
            | some uid2 =>
              if uid2 == uid1 then return .fail "replacement pod reused the UID (cannot test)"
              -- Delete with the STALE uid: the apiserver must refuse and the pod must survive.
              let code2 ← runDelete uid1
              let still ← uidOf
              discard <| kubectl ["delete", "pod", victim, "-n", cfg.«namespace», "--wait=false"]
              if code2 != "409" then
                return .fail s!"a delete carrying a stale UID was not refused with 409 (got http {code2}); a same-name replacement could be deleted"
              if still != some uid2 then
                return .fail s!"the replacement pod did not survive the stale-UID delete (uid now {still})"
              IO.eprintln s!"# apiserver refused the stale-UID delete (409); replacement {uid2} untouched"
              return .pass },

    { name := "SAF-06: the UID-precondition delete has a deadline — a server that accepts and never answers returns within it"
      run := do
        -- A TCP black hole: accepts the connection and never speaks, so the
        -- TLS handshake hangs. Without --connect-timeout/--max-time this
        -- would block the reconcile (and the lease renewal) indefinitely.
        let ops ← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»
        match ops.head? with
        | none => return .fail "no operator pod"
        | some opPod =>
          let hole := "blackhole"
          -- Accept, then say nothing: nc's stdin is a pipe held open for an
          -- hour, so the connection stays up and silent; whatever the client
          -- sends (the TLS ClientHello) is appended to /tmp/accepted, which
          -- is the SERVER-SIDE proof that the connection was accepted — a
          -- refused connection would leave it empty and is not this scenario.
          discard <| kubectl ["run", hole, "-n", cfg.«namespace», "--image=busybox:1.36", "--restart=Never", "--command", "--", "sh", "-c", "while true; do sleep 3600 | nc -l -p 6443 >> /tmp/accepted; done"]
          let ready ← waitForCondition "blackhole pod has an IP" 60 do return (← getPodIp hole cfg.«namespace»).isSome
          match ready, ← getPodIp hole cfg.«namespace» with
          | true, some ip =>
            IO.sleep 3000
            let cmd := Bridge.uidPreconditionDeleteCommand "nobody" cfg.«namespace» "00000000-0000-0000-0000-000000000000" (apiBase := s!"https://{ip}:6443")
            let t0 ← IO.monoMsNow
            let out ← Bridge.execInPod opPod cfg.«namespace» ["sh", "-c", cmd]
            let elapsed := (← IO.monoMsNow) - t0
            let text := match out with | .ok o => o | .error e => e
            -- Server-side acceptance: bytes arrived on the black hole. Read it
            -- BEFORE deleting the pod — an exec into a terminating pod can fail
            -- and would read as "0 bytes accepted", i.e. a false verdict.
            let accepted ← do
              match ← Bridge.execInPod hole cfg.«namespace» ["sh", "-c", "wc -c < /tmp/accepted 2>/dev/null || echo 0"] with
              | .ok o => pure ((o.trim.toNat?).getD 0)
              | .error _ => pure 0
            discard <| kubectl ["delete", "pod", hole, "-n", cfg.«namespace», "--wait=false"]
            IO.eprintln s!"# black-hole delete returned in {elapsed}ms; server accepted {accepted} byte(s): {text.replace "\n" " | " |>.take 200}"
            if accepted == 0 then
              return .fail s!"the black hole never accepted the connection (0 bytes received): this was a refused connection, not a silent one — the scenario was not staged ({text.take 160})"
            if elapsed > 20000 then
              return .fail s!"the delete against a silent server took {elapsed}ms: no effective deadline"
            if !containsSubstr text "curl_exit=28" then
              return .fail s!"the accepted-but-silent connection did not end by TIMEOUT (curl exit 28); got: {text.take 200}"
            return .pass
          | _, _ =>
            discard <| kubectl ["delete", "pod", hole, "-n", cfg.«namespace», "--wait=false"]
            return .fail "could not start the black-hole pod" }
  ]
}

end FlareOperator.E2E.Tests.ReplicaRepair
