/-
  E2E/Tests/NodeOpsSwitch.lean — planned master switches under a client-like
  write load (NODE-OPS-NOSTOP-IMPLEMENTATION-PLAN-2026-10-26, stage 1.5;
  issue flare-lossless-switch-paths).

  Target of every planned switch: NO write error the client sees (server
  error, timeout, connection error) and NO acknowledged write missing on the
  final master or the replica; a delay is allowed and is measured.

  Load: 4 writers through the partition Service (the client path) and 2
  through the all-pods Service <cluster>-nodes-external (writes landing on a
  non-master pod take the proxy path), 200 requests/s each, a new connection per
  request (clients connect for each use, a connection lasts seconds at most:
  user decision 2026-10-28), closed loop (one request at a time per writer) — the rate actually achieved
  and the lowest rate in any second are reported with the result.

  Each test also records, so a failure can be attributed and not only
  observed (review of baseline 40298853632):
  - the operation's own result (kubectl exit code, rollout / drain completion)
    and that pods actually moved (UIDs replaced, no flared pod left on a
    drained worker); an operation that did not happen is a precondition
    failure, never a data verdict;
  - which backend pod each failed request was talking to (peer address ->
    pod, from the samples);
  - a timeline every ~2 s: the operator's map (master, replicas), each pod's
    own role / partition / node map version / items / reconstruction state,
    and the CR's replica-repair status;
  - acknowledged writes missing on the replica when the switch settled AND
    again 120 s later (a gap that a repair fills is delayed, not lost).

  Ported from the node-operations harness on safety/saf-10-restore-provenance
  (source f3861b0e77e343079d52b9fa026345d9d211a459, NodeOps.lean switch part).
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.E2E.LoadWriter
import FlareOperator.Kubectl
import Std.Data.HashMap

namespace FlareOperator.E2E.Tests.NodeOpsSwitch

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl

/-- 1 partition x 2 replicas, rocksdb, prod-like drain window and PDB, one
    flared pod per data worker; the product's flared defaults. -/
def cfgOf (name : String) (tmpfs pvc : Bool) : ClusterConfig :=
  { name := name, «namespace» := s!"flare-{name}", partitions := 1, replicas := 2,
    debugPod := s!"debug-{name}", storageBackend := "rocksdb", useTmpfs := tmpfs, usePvc := pvc,
    drainSeconds := 60, pdbMaxUnavailable := some 1, multiNode := true }

private def svcHost (c : Ctx) : String := s!"{c.cfg.name}-0.{c.cfg.«namespace»}.svc.cluster.local"
private def podHost (c : Ctx) (pod : String) : String := s!"{pod}.{c.cfg.name}-nodes.{c.cfg.«namespace»}.svc.cluster.local"

/-- Redundancy restored: a master and an ACTIVE replica of partition 0, both
    pods Ready and not deleting, on different workers, none on `avoid`, AND the
    replica holds the master's history and is read-eligible (its own
    `rocksdb_source_epoch` equals the master's and `repl_read_source_eligible`
    is 1): a replica left on an older history after a re-promotion under the
    same pod name is not redundancy (baseline 40341355474, S3 -> S4). -/
private def redundant (c : Ctx) (avoid : Option String) : IO Bool := do
  let some ps ← c.pods | return false
  let some (some m, rs) ← c.roles | return false
  let v ← c.nodeView
  let activeR := rs.filter fun r => v.any fun e => podOfFqdn e.fqdn == r && e.state == 0
  match ps.find? (·.name == m), activeR.head? with
  | some mp, some r =>
    match ps.find? (·.name == r) with
    | some rp =>
      if !(mp.ready && rp.ready && !mp.deleting && !rp.deleting && mp.node != rp.node
            && some mp.node != avoid && some rp.node != avoid) then return false
      match ← c.stats mp.ip, ← c.stats rp.ip with
      | some mo, some ro =>
        let sameHistory := (statOf mo "rocksdb_source_epoch").isSome && statOf mo "rocksdb_source_epoch" == statOf ro "rocksdb_source_epoch"
        -- a missing or unreadable safety stat is NOT eligible: only an explicit 1 is
        let eligible := statOf ro "repl_read_source_eligible" == some "1"
          && (statOf ro "repl_read_source_state").all (· == "eligible")   -- not revalidating / needs_rebuild
        return sameHistory && eligible
      | _, _ => return false
    | none => return false
  | _, _ => return false

/-- One timeline row: the operator's map, each pod's own view and copy, and
    the CR's replica-repair status. Returns pod ip -> name for attribution. -/
private def switchSample (c : Ctx) : IO (List (String × String)) := do
  let t ← epochNow
  let roles ← c.roles
  let pods := (← c.pods).getD []
  let mut own : List String := []
  for p in pods do
    if p.ip.isEmpty then own := own ++ [s!"{p.name}:noip"] else
    match ← c.stats p.ip with
    | none => own := own ++ [s!"{p.name}:unreadable"]
    | some o =>
      let g := fun (k : String) => (statOf o k).getD "?"
      own := own ++ [s!"{p.name}@{p.node}(uid {p.uid.take 8},ready {p.ready},deleting {p.deleting}):own_role={g "own_role"},own_partition={g "own_partition"},map={g "node_map_version"},items={g "curr_items"},recon={g "reconstruction_started"}/{g "reconstruction_completed"},inflight={g "proxy_write_in_flight"},held={g "proxy_write_held"}/{g "proxy_write_held_ms_max"}ms,dropped={g "proxy_write_dropped"},reqs={g "requests_in_progress"}"]
  let repairs ← match ← kubectl ["get", "flarecluster", c.cfg.name, "-n", c.cfg.«namespace», "-o", "jsonpath={.status.replicaRepairs}"] with
    | .ok o => pure (if o.trim.isEmpty then "none" else o.trim.take 400)
    | .error _ => pure "unreadable"
  let mapTxt := match roles with
    | none => "map=unreadable"
    | some (m, rs) => s!"master={m.getD "none"} replicas={rs}"
  c.art "timeline.txt" s!"{t} SAMPLE {mapTxt} | {String.intercalate " " own} | repairs={repairs}"
  return pods.filterMap fun p => if p.ip.isEmpty then none else some (p.ip, p.name)

/-- Sample every ~2 s until `done` or `secs` elapse; the ip -> pod table seen. -/
private partial def observe (c : Ctx) (secs : Nat) (done : IO Bool) : IO (List (String × String) × Bool) := do
  let deadline := (← nowSec) + secs
  let mut ips : List (String × String) := []
  repeat
    for (ip, n) in ← switchSample c do
      if !(ips.any (·.1 == ip)) then ips := ips ++ [(ip, n)]
    if ← done then return (ips, true)
    if (← nowSec) ≥ deadline then return (ips, false)
    IO.sleep 2000
  return (ips, false)

/-- The operator has finished its startup grace (dead detection and drain
    active): every scenario assumes a settled operator. CI 40653574118 sent
    S6's SIGTERM ~60 s before the grace ended (the setup is slower there), and
    the restarted master was handled as a grace-period rejoin. -/
private def operatorSettled (c : Ctx) : IO Bool :=
  waitForCondition "the operator's startup grace period is over" 300 do
    return containsSubstr (← kubectlLogsLabel s!"app={c.cfg.operatorName}" c.cfg.«namespace» 5000) "grace period over"

/-- Final copies: (pod, own copy); an unreadable copy is `none`, never empty. -/
private def finalCopies (c : Ctx) (tag : String) : IO (List (String × Option (List (String × String)))) := do
  let ps := (← c.pods).getD []
  let mut out := []
  for p in ps do
    let cp ← if p.ip.isEmpty then pure none else c.ownCopy p.ip
    c.art "copies.txt" s!"{tag} {p.name}@{p.node} {match cp with | some d => s!"{d.length} keys" | none => "UNREADABLE"}"
    out := out ++ [(p.name, cp)]
  return out

private def recordMissing (c : Ctx) (who : String) (ws : List WriteRec) (copy : List (String × String)) : IO Nat := do
  let miss := missingAcks ws copy
  for w in miss.take 2000 do c.art "missing.txt" s!"{who} {w.key}={w.value} acked t={w.t} via {w.ip} -> {(copy.lookup w.key).getD "(absent)"}"
  return miss.length

/-- Failed requests per backend pod (peer address -> pod name). -/
private def errorsByPod (ips : List (String × String)) (rs : List LoadRec) : List (String × Nat) := Id.run do
  let mut m : List (String × Nat) := []
  for r in rs.filter (!·.ack) do
    let who := match ips.lookup r.peer with
      | some n => n
      | none => if r.peer == "-" then "(no connection)" else s!"{r.peer}(unknown)"
    m := match m.lookup who with
      | some k => (who, k + 1) :: m.filter (·.1 != who)
      | none => (who, 1) :: m
  return m

inductive SwitchOp where
  /-- `kubectl delete pod` of the master (graceful) -/
  | deleteMaster
  /-- `kubectl rollout restart` of the StatefulSet -/
  | rollingRestart
  /-- `kubectl rollout restart` of the operator Deployment AND the StatefulSet
      at once: a helm-upgrade-like roll of both (not a helm upgrade) -/
  | rollBoth
  /-- `kubectl drain` of the master's worker (Eviction API, PDB honoured) -/
  | drainMaster
  /-- `kubectl delete pod` of the master while the operator cannot save its
      handover ledger (test seam), then a restart of the operator: no
      handover map may be committed before its phase is saved, and the new
      operator completes the switch (review of af85899) -/
  | deleteMasterSaveFail
  /-- `kubectl delete pod` of the master while it is cut from its successor:
      the first handover cannot drain and aborts (rollback), the cut is
      removed, and the retry (attempt 2, L7) completes the switch; the
      one-map drain never takes the master (review of 9c4b2e1) -/
  | deleteMasterAbortRetry
  /-- `kubectl delete pod` of the master while it is cut from its successor,
      and the operator's lease taken by another identity while the handover
      is in its fast loop: the rest of that pass is skipped (no FSM step,
      rolling or send), the process exits, and the next leader resumes the
      handover from its ledger (review of 262fde9) -/
  | deleteMasterLeaseTakeover
  /-- `kubectl delete pod` of the master while the handover step cannot read
      the pods (test seam) but the FSM can: no drain or promotion while it
      lasts, then the handover completes the switch (review of 67e27eb) -/
  | deleteMasterObserveFail
  /-- a REAL `helm upgrade` of a release installed from the chart as an older
      release shipped it (StatefulSet RollingUpdate) to this chart (OnDelete),
      with a pod template change in the same upgrade (plan A0): the
      StatefulSet controller replaces no pod; the operator replaces them one
      at a time, a master after its ordered handover -/
  | helmUpgrade
  /-- `kubectl cordon` + `kubectl drain` of the master's (or the replica's)
      worker with the node guard and the cordon move on (plan C): the move
      hands the master over (or demotes the replica), takes the pod out of the
      clients' Service and releases it; the drain's evictions are held (429)
      until then. tmpfs only: a local-path PVC cannot leave its node. -/
  | cordonMaster
  | cordonReplica
  deriving BEq, Repr

def SwitchOp.label : SwitchOp → String
  | .deleteMaster => "kubectl delete pod (master)"
  | .rollingRestart => "kubectl rollout restart statefulset"
  | .rollBoth => "operator Deployment + StatefulSet rollout restart together (helm-upgrade-like, not a helm upgrade)"
  | .drainMaster => "kubectl drain of the master's worker"
  | .deleteMasterSaveFail => "kubectl delete pod (master) while the handover ledger cannot be saved, then an operator restart"
  | .deleteMasterAbortRetry => "kubectl delete pod (master) while it is cut from its successor: the handover aborts, then retries after the cut is removed"
  | .deleteMasterLeaseTakeover => "kubectl delete pod (master) while it is cut from its successor, and the operator's lease taken by another identity mid-handover"
  | .deleteMasterObserveFail => "kubectl delete pod (master) while the handover step cannot read the pods"
  | .helmUpgrade => "helm upgrade from the RollingUpdate chart to this chart (OnDelete) with a pod template change"
  | .cordonMaster => "kubectl cordon + drain of the master's worker (node guard + cordon move)"
  | .cordonReplica => "kubectl cordon + drain of the replica's worker (node guard + cordon move)"

/-- The file the operator's FLARE_TEST_HANDOVER_PODS_FAIL_FILE names. -/
def podsFailFile : String := "/tmp/handover-pods-fail"

/-- The file the operator's FLARE_TEST_HANDOVER_SAVE_FAIL_FILE names. -/
def saveFailFile : String := "/tmp/handover-save-fail"

structure SwitchObs where
  opOk : Bool
  opDetail : String
  moved : Bool
  movedDetail : String
  svc : LoadStats
  peer : LoadStats
  svcByPod : List (String × Nat)
  peerByPod : List (String × Nat)
  missingMaster : Option Nat
  missingReplica : Option Nat
  missingReplicaLater : Option Nat
  redundant : Bool
  newMaster : Option String
  /-- a safety check of the scenario itself failed (not a precondition) -/
  checkFail : Option String := none
  /-- write errors are reported, not a failure: the operator is away longer
      than the clients' wait (approved category (a), 2026-10-26: errors
      possible, no acknowledged write lost) -/
  errorsAllowed : Bool := false

/-- The target: the operation happened, 0 errors on both loads, 0
    acknowledged writes missing on the final master and on the replica
    (after the 120 s settle), redundancy back. -/
def switchVerdict (o : SwitchObs) : Option String :=
  if !o.opOk then some (notSetUp s!"the operation did not complete: {o.opDetail}")
  else if !o.moved then some (notSetUp s!"no pod moved: {o.movedDetail}")
  else if let some why := o.checkFail then some s!"SAFETY: {why}"
  else match o.missingMaster, o.missingReplicaLater with
  | none, _ => some (unobservable "the final master's copy could not be read")
  | _, none => some (unobservable "the replica's copy could not be read")
  | some mm, some mr =>
    let errs := o.svc.errors + o.peer.errors
    if mm != 0 || mr != 0 then some s!"DATA: {mm} acknowledged write(s) missing on the final master, {mr} on the replica 120 s after the switch settled ({o.missingReplica} when it settled; see missing.txt); {errs} write error(s)"
    else if errs != 0 && !o.errorsAllowed then some s!"WRITE ERRORS: {o.svc.errors} on the client path {o.svc.errorKinds} by pod {o.svcByPod}, {o.peer.errors} on the proxy path {o.peer.errorKinds} by pod {o.peerByPod} (a planned switch must only delay)"
    else if !o.redundant then some "redundancy (master + active replica) was not restored within the bound"
    else none

private def switchRun (c : Ctx) (op : SwitchOp) : IO (Except String SwitchObs) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    -- each test starts from a healthy pair (the previous test may have left a
    -- replica on an older history): wait for it, else it is a precondition failure
    if !(← operatorSettled c) then
      return .error (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .error (notSetUp "the cluster did not start this test with a master and a replica on its history (left by the previous test?)")
    c.conditions [s!"scenario: {op.label} under a client-like load (4 x 200/s via the partition Service, 2 x 200/s via the all-pods Service; a new connection per request, closed loop)"]
    match ← c.ensureLoadWriter with
    | .error e => return .error (notSetUp e)
    | .ok () => pure ()
    -- the clients' Service selects the serving label the operator puts on
    if c.cfg.nodeReplacement then
      let labelled ← waitForCondition "every flared pod carries the serving label" 120 do
        match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app=flare,cluster={c.cfg.name},flare.gree.net/serving=true", "-o", "jsonpath={.items[*].metadata.name}"] with
        | .ok o => return ((o.trim.splitOn " ").filter (!·.isEmpty)).length == c.cfg.replicas * c.cfg.partitions
        | .error _ => return false
      if !labelled then return .error (notSetUp "the operator did not label every pod serving")
    if !(← c.startLoad "svc" (svcHost c) 4 200) then return .error (notSetUp "the client-path load did not start")
    -- the clients' all-pods Service (the chart's <cluster>-nodes-external):
    -- the writes that land on a non-master pod take the proxy path. A pod's
    -- own DNS name would keep sending to a pod the switch replaces.
    -- (S8 cuts the master from the replica on purpose: a write landing on the
    -- replica could not reach the master for that reason alone, so both loads
    -- go through the partition Service there)
    let peerHost := if op == .deleteMasterAbortRetry || op == .deleteMasterLeaseTakeover then svcHost c
      else s!"{c.cfg.name}-nodes-external.{c.cfg.«namespace»}.svc.cluster.local"
    if !(← c.startLoad "peer" peerHost 2 200) then return .error (notSetUp "the proxy-path load did not start")
    let before := (← c.pods).getD []
    let opUids := fun (_ : Unit) => do
      match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].metadata.uid}"] with
      | .ok o => pure (some ((o.trim.splitOn " ").filter (!·.isEmpty)))
      | .error _ => pure none
    let opBefore ← opUids ()
    let (ips0, _) ← observe c 10 (pure false)
    let ns := c.cfg.«namespace»
    c.event s!"{op.label} starts (master {p.master.name} on {p.master.node})"
    let mut opOk := true
    let mut opDetail := ""
    let mut drained : Option String := none
    let mut checkFail : Option String := none
    match op with
    | .deleteMaster =>
      match ← kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
      | .ok _ => opDetail := "delete accepted"
      | .error e => opOk := false; opDetail := s!"delete failed: {e.take 200}"
    | .rollingRestart =>
      match ← kubectl ["rollout", "restart", s!"statefulset/{c.cfg.name}-nodes", "-n", ns] with
      | .ok _ => opDetail := "rollout restart accepted"
      | .error e => opOk := false; opDetail := s!"rollout restart failed: {e.take 200}"
    | .rollBoth =>
      let a ← kubectl ["rollout", "restart", s!"deployment/{c.cfg.operatorName}", "-n", ns]
      let b ← kubectl ["rollout", "restart", s!"statefulset/{c.cfg.name}-nodes", "-n", ns]
      match a, b with
      | .ok _, .ok _ => opDetail := "both rollout restarts accepted"
      | _, _ => opOk := false; opDetail := "a rollout restart failed"
    | .drainMaster =>
      let stem ← startDrain p.master.node 600
      let (_, _) ← observe c 660 (return (← drainResult stem).isSome)
      match ← drainResult stem with
      | some (rc, out) =>
        for l in out.splitOn "\n" do c.art "drain.txt" l
        opDetail := s!"drain rc={rc}"
        if rc != "0" then opOk := false
      | none => opOk := false; opDetail := "drain did not finish within 660 s"
      drained := some p.master.node
    | .helmUpgrade =>
      let stsField := fun (path : String) => do
        match ← kubectl ["get", "statefulset", s!"{c.cfg.name}-nodes", "-n", ns, "-o", s!"jsonpath=\{{path}}"] with
        | .ok o => pure o.trim
        | .error _ => pure ""
      let podRevs := fun (_ : Unit) => do
        match ← kubectl ["get", "pods", "-n", ns, "-l", s!"cluster={c.cfg.name}", "-o",
            "jsonpath={range .items[*]}{.metadata.name}|{.metadata.labels.controller-revision-hash}{\"\\n\"}{end}"] with
        | .ok o => pure ((o.splitOn "\n").filterMap fun l => match l.trim.splitOn "|" with
            | [n, r] => if n.isEmpty then none else some (n, r)
            | _ => none)
        | .error _ => pure []
      let s0 ← stsField ".spec.updateStrategy.type"
      let rev0 ← stsField ".status.updateRevision"
      c.event s!"before the upgrade: updateStrategy {s0}, update revision {rev0}, pods {← podRevs ()}"
      if s0 != "RollingUpdate" then
        checkFail := some s!"the release was not installed from the RollingUpdate chart (updateStrategy {s0})"
      let chart ← helmChartDir
      let t0 ← nowSec
      match ← helmCmd ["upgrade", helmRelease c.cfg, chart, "--namespace", ns, "--reuse-values",
          "--set", "cluster.podLabels.flare-e2e-upgrade=v2"] 300 with
      | .error e => opOk := false; opDetail := s!"helm upgrade failed: {e.take 300}"
      | .ok _ =>
        let _ ← waitForCondition "the StatefulSet has a new update revision" 60 do
          return (← stsField ".status.updateRevision") != rev0
        let s1 ← stsField ".spec.updateStrategy.type"
        let rev1 ← stsField ".status.updateRevision"
        c.event s!"helm upgrade done in {(← nowSec) - t0} s: updateStrategy {s0} -> {s1}, update revision {rev0} -> {rev1}"
        if s1 != "OnDelete" then
          checkFail := some s!"after the upgrade the StatefulSet's updateStrategy is {s1}, not OnDelete"
        if rev1 == rev0 || rev1.isEmpty then
          opOk := false; opDetail := s!"the upgrade made no new pod template revision ({rev0} -> {rev1})"
        else
          -- every pod on the new revision, Ready (the operator's rolling)
          let (_, all) ← observe c 900 (do
            let rs ← podRevs ()
            let ps := (← c.pods).getD []
            return rs.length == c.cfg.partitions * c.cfg.replicas && rs.all (·.2 == rev1)
              && ps.all (fun (r : PodRow) => r.ready && !r.deleting))
          c.event s!"every pod on {rev1} and Ready={all}: {← podRevs ()}"
          if !all then opOk := false; opDetail := s!"the pods did not all reach {rev1} within 900 s"
          else opDetail := s!"helm upgrade: {s0} -> {s1}; every pod replaced onto {rev1}"
          -- the switch order: who deleted each pod, and the master's handover first
          let lines := (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000).splitOn "\n"
          let order := lines.filter fun l => containsSubstr l "ROLLING: deleted" || containsSubstr l "HANDOVER p0 "
          for x in order do c.art "upgrade-order.txt" x
          c.event s!"switch order (operator): {(order.filter (containsSubstr · "ROLLING: deleted")).map fun l => ((l.splitOn "ROLLING: deleted ").getD 1 "").take 60}"
          let mut fails : List String := []
          for b in before do
            let delIdx := lines.findIdx? fun l => containsSubstr l s!"ROLLING: deleted {b.name} (uid {b.uid}"
            if delIdx.isNone then
              fails := fails ++ [s!"{b.name} (uid {b.uid}) was replaced without the operator's rolling delete (by the StatefulSet controller?)"]
            if b.name == p.master.name then
              let hIdx := lines.findIdx? fun l => containsSubstr l "HANDOVER p0 " && containsSubstr l p.master.name
              match hIdx, delIdx with
              | some h, some d => if h > d then fails := fails ++ [s!"the master {b.name} was deleted before its handover"]
              | none, _ => fails := fails ++ [s!"the master {b.name} was replaced without an ordered handover"]
              | _, none => pure ()
          if !fails.isEmpty then
            checkFail := some ((checkFail.map (· ++ "; ")).getD "" ++ String.intercalate "; " fails ++ " (see upgrade-order.txt)")
    | .cordonMaster | .cordonReplica =>
      let target := if op == SwitchOp.cordonMaster then p.master else p.replica
      match ← kubectl ["cordon", target.node] with
      | .error e => opOk := false; opDetail := s!"cordon failed: {e.take 200}"
      | .ok _ =>
        c.event s!"cordoned {target.node} ({target.name}); kubectl drain starts at once"
        let stem ← startDrain target.node 600
        let (_, _) ← observe c 660 (return (← drainResult stem).isSome)
        match ← drainResult stem with
        | some (rc, out) =>
          for l in out.splitOn "\n" do c.art "drain.txt" l
          opDetail := s!"drain rc={rc}"
          if rc != "0" then opOk := false
        | none => opOk := false; opDetail := "drain did not finish within 660 s"
        drained := some target.node
        -- the move released the pod, and every eviction before that was held
        let lines := (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000).splitOn "\n"
        for x in lines.filter (fun x => containsSubstr x "NODE MOVE" || containsSubstr x "NODE GUARD") do c.art "cordon-move.txt" x
        let rel := lines.findIdx? fun l => containsSubstr l s!"NODE MOVE {target.name}@" && containsSubstr l "-> released"
        let heldIdx := lines.findIdx? fun l =>
          (containsSubstr l "NODE GUARD: HELD" || containsSubstr l "NODE GUARD: REFUSED") && containsSubstr l s!" {target.name}"
        c.event s!"move released at operator log line {rel}; first held/refused eviction at {heldIdx}"
        match rel, heldIdx with
        | none, _ => checkFail := some s!"no release of {target.name} by the cordon move was logged (see cordon-move.txt)"
        | some _, none => checkFail := some s!"no eviction of {target.name} was held before its release: the drain was not gated (see cordon-move.txt)"
        | some r, some h => if h > r then checkFail := some s!"the first held eviction of {target.name} came after its release (see cordon-move.txt)"
    | .deleteMasterSaveFail =>
      let opNames ← match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].metadata.name}"] with
        | .ok o => pure (some ((o.trim.splitOn " ").filter (!·.isEmpty)))
        | .error _ => pure none
      match opNames with
      | some [opPod] =>
        match ← kubectl ["exec", opPod, "-n", ns, "--", "touch", saveFailFile] with
        | .error e => opOk := false; opDetail := s!"could not arm the save failure in {opPod}: {e.take 200}"
        | .ok _ =>
          c.event s!"handover ledger saves fail in {opPod} ({saveFailFile})"
          match ← kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
          | .error e => opOk := false; opDetail := s!"delete failed: {e.take 200}"
          | .ok _ =>
            -- the operator asks for the demote map and cannot save its phase
            let refused ← waitForCondition "the operator refused a handover map it could not save" 90 do
              return containsSubstr (← kubectlLogs opPod ns 2000) "is NOT committed this tick"
            let logs ← kubectlLogs opPod ns 5000
            for l in (logs.splitOn "\n").filter (fun l => containsSubstr l "HANDOVER") do c.art "operator-before-restart.txt" l
            if !refused then
              opOk := false; opDetail := "delete accepted, but the operator never asked for a handover map (no save was refused within 90 s)"
            else
              if containsSubstr logs "map committed as" then
                checkFail := some s!"the operator {opPod} committed a handover map although its phase could not be saved (see operator-before-restart.txt)"
              c.event s!"save refused, no map committed={!containsSubstr logs "map committed as"}; restarting the operator"
              match ← kubectl ["delete", "pod", opPod, "-n", ns, "--wait=false"] with
              | .ok _ => opDetail := "delete accepted; the save was refused; operator pod deleted"
              | .error e => opOk := false; opDetail := s!"the operator pod could not be deleted: {e.take 200}"
      | other => opOk := false; opDetail := s!"expected exactly one operator pod, saw {other}"
    | .deleteMasterObserveFail =>
      let opNames ← match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].metadata.name}"] with
        | .ok o => pure (some ((o.trim.splitOn " ").filter (!·.isEmpty)))
        | .error _ => pure none
      match opNames with
      | some [opPod] =>
        match ← kubectl ["exec", opPod, "-n", ns, "--", "touch", podsFailFile] with
        | .error e => opOk := false; opDetail := s!"could not arm the pods-read failure in {opPod}: {e.take 200}"
        | .ok _ =>
          c.event s!"the handover step's pod reads fail in {opPod} ({podsFailFile})"
          match ← kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
          | .error e =>
            discard <| kubectl ["exec", opPod, "-n", ns, "--", "rm", "-f", podsFailFile]
            opOk := false; opDetail := s!"delete failed: {e.take 200}"
          | .ok _ =>
            -- held while the handover cannot observe: the FSM sees the
            -- Terminating master and must leave it
            let deferred ← waitForCondition "the drain leaves the Terminating master the handover step did not observe" 60 do
              return containsSubstr (← kubectlLogs opPod ns 3000) "were not observed by this pass's handover step"
            IO.sleep 20000
            let held ← kubectlLogs opPod ns 5000
            for l in (held.splitOn "\n").filter (fun l => containsSubstr l "HANDOVER" || containsSubstr l "graceful drain" || containsSubstr l "PROMOTION committed") do
              c.art "operator-while-unobserved.txt" l
            let oneMapDrain := containsSubstr held "graceful drain: demoting Terminating"
            let promoted := containsSubstr held "PROMOTION committed"
            c.event s!"while unobserved: deferral logged={deferred}, one-map drain={oneMapDrain}, promotion committed={promoted}; reads restored"
            discard <| kubectl ["exec", opPod, "-n", ns, "--", "rm", "-f", podsFailFile]
            if !deferred then
              opOk := false; opDetail := "the operator never logged deferring the unobserved Terminating master (the seam may not have engaged)"
            else
              if oneMapDrain || promoted then
                checkFail := some s!"while the handover step could not observe, the one-map drain={oneMapDrain} / a promotion={promoted} took the master (see operator-while-unobserved.txt)"
              let done ← waitForCondition "the ordered handover completes once the pods are readable" 180 do
                return containsSubstr (← kubectlLogs opPod ns 20000) "HANDOVER p0 done"
              opDetail := s!"delete accepted; held while unobserved; handover done after reads restored={done}"
              if !done then
                checkFail := some ((checkFail.map (· ++ "; ")).getD "" ++ "no handover completed after the pods became readable")
      | other => opOk := false; opDetail := s!"expected exactly one operator pod, saw {other}"
    | .deleteMasterAbortRetry =>
      let opLogs := fun (_ : Unit) => kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 20000
      let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
      match ← installCuts rules with
      | .error (why, part) => removeCuts part; opOk := false; opDetail := s!"could not cut master <-> replica: {why}"
      | .ok installed =>
        c.event s!"cut {p.master.ip} <-> {p.replica.ip}; deleting the master {p.master.name}"
        match ← kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
        | .error e => removeCuts installed; opOk := false; opDetail := s!"delete failed: {e.take 200}"
        | .ok _ =>
          -- the abort must be the one under test: V1 sent, the drain to the
          -- cut successor not clean within Th, then the rollback map V1′
          -- committed — and applied by BOTH pods before the cut is healed
          -- (review of 4bdc83b: any "-> aborted" could be a pre-V1 abort, and
          -- the phase line comes before V1′ is even committed)
          let rollbackVersion := fun (l : String) =>
            ((l.splitOn "aborted map committed as v").drop 1).head?.bind fun rest =>
              (rest.takeWhile Char.isDigit).toNat?
          let aborted ← waitForCondition "the first handover aborted from draining on Th, and its rollback map was committed" 90 do
            let l ← opLogs ()
            return containsSubstr l "demoting map committed as v" && containsSubstr l "draining -> aborted"
              && containsSubstr l "not drained within" && (rollbackVersion l).isSome
          let vBack := rollbackVersion (← opLogs ())
          let applied ← match vBack with
            | none => pure false
            | some v => waitForCondition s!"the rollback map v{v} is applied by the old master and the successor" 60 do
                let ver := fun (ip : String) => do
                  return ((← c.stats ip).bind (statOf · "node_map_version")).bind (·.toNat?)
                let a ← ver p.master.ip
                let b ← ver p.replica.ip
                return a.any (· >= v) && b.any (· >= v)
          removeCuts installed
          c.event s!"first handover aborted on Th={aborted}; rollback map {vBack} applied by both={applied}; cut removed"
          if !aborted || !applied then
            opOk := false; opDetail := s!"the forced abort was not produced as intended (aborted from draining on Th={aborted}, rollback v{vBack} applied by both={applied})"
          else
            let retried ← waitForCondition "the handover is retried (attempt 2) and completes" 120 do
              let l ← opLogs ()
              return containsSubstr l "(attempt 2 of" && containsSubstr l "HANDOVER p0 done"
            let l ← opLogs ()
            for x in (l.splitOn "\n").filter (fun x => containsSubstr x "HANDOVER" || containsSubstr x "graceful drain") do c.art "operator-handover.txt" x
            if containsSubstr l s!"graceful drain: demoting Terminating node(s) to live proxy + promoting replacement(s): [{p.master.name}" then
              checkFail := some "the one-map drain took the master while its handover could still be retried (see operator-handover.txt)"
            if !retried then
              checkFail := some ((checkFail.map (· ++ "; ")).getD "" ++ "no retry (attempt 2) completed the handover within 120 s after the abort (see operator-handover.txt)")
            opDetail := s!"delete accepted; first handover aborted; retry completed={retried}"
    | .deleteMasterLeaseTakeover =>
      let opPodOf := fun (_ : Unit) => do
        match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].metadata.name}"] with
        | .ok o => pure ((o.trim.splitOn " ").filter (!·.isEmpty))
        | .error _ => pure []
      let restartsOf := fun (pod : String) => do
        match ← kubectl ["get", "pod", pod, "-n", ns, "-o", "jsonpath={.status.containerStatuses[?(@.name==\"flare-operator\")].restartCount}"] with
        | .ok o => pure o.trim.toNat?
        | .error _ => pure none
      let leaseName := s!"{c.cfg.name}-operator-lease"
      match ← opPodOf () with
      | [opPod] =>
        let r0 := (← restartsOf opPod).getD 0
        let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
        match ← installCuts rules with
        | .error (why, part) => removeCuts part; opOk := false; opDetail := s!"could not cut master <-> replica: {why}"
        | .ok installed =>
          c.event s!"cut {p.master.ip} <-> {p.replica.ip}; deleting the master {p.master.name}"
          match ← kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
          | .error e => removeCuts installed; opOk := false; opDetail := s!"delete failed: {e.take 200}"
          | .ok _ =>
            -- the handover is in its fast loop once V1 is committed (the cut
            -- keeps it draining until Th)
            let demoted ← waitForCondition "the demoting map is committed (the fast loop runs)" 60 do
              return containsSubstr (← kubectlLogs opPod ns 5000) "demoting map committed as v"
            let patch := "{\"spec\":{\"holderIdentity\":\"e2e-foreign-holder\",\"leaseDurationSeconds\":600,\"renewTime\":\"2999-01-01T00:00:00.000000Z\"}}"
            let took ← if demoted then pure ((← kubectlPatch "lease" leaseName ns patch) matches .ok _) else pure false
            c.event s!"handover demoted={demoted}; lease taken by another identity={took}"
            -- the process must notice and exit (the kubelet restarts it)
            let exited ← if took then waitForCondition "the operator exits on the lost lease" 90 do
                return ((← restartsOf opPod).getD 0) > r0
              else pure false
            let prev ← match ← kubectl ["logs", opPod, "-n", ns, "-c", "flare-operator", "--previous", "--tail=20000"] with
              | .ok o => pure o
              | .error _ => pure ""
            for x in (prev.splitOn "\n").filter (fun x => containsSubstr x "HANDOVER" || containsSubstr x "PASS STOPPED" || containsSubstr x "LEASE" || containsSubstr x "ROLLING" || containsSubstr x "committed as" || containsSubstr x "graceful drain") do
              c.art "operator-before-takeover.txt" x
            -- authority back (this harness runs one operator replica): the
            -- restarted process waits on the foreign holder until it is gone
            discard <| kubectl ["delete", "lease", leaseName, "-n", ns]
            removeCuts installed
            c.event s!"operator exited={exited}; lease deleted; cut removed"
            if !demoted || !took || !exited then
              opOk := false; opDetail := s!"the takeover was not produced as intended (demoted={demoted}, lease taken={took}, operator exited={exited})"
            else
              -- in the process that lost the lease: after the failed renewal,
              -- nothing more is decided or sent before it exits
              let tail := match (prev.splitOn "HANDOVER: the lease could not be renewed").drop 1 with
                | [] => none
                | rest => some (String.intercalate "" rest)
              match tail with
              | none => checkFail := some "the handover's fast loop never reported the failed lease renewal (see operator-before-takeover.txt)"
              | some t =>
                let after := (t.splitOn "LOST LEASE").head!
                let acted := ["map committed as", "ROLLING: deleted", "graceful drain:", "), broadcasting"].filter (containsSubstr after ·)
                if !containsSubstr after "PASS STOPPED" then
                  checkFail := some "after the failed renewal the pass did not report that it stopped (see operator-before-takeover.txt)"
                else if !acted.isEmpty then
                  checkFail := some s!"after the failed renewal the old leader still acted: {acted} (see operator-before-takeover.txt)"
              let done ← waitForCondition "the next leader finishes the handover from its ledger" 240 do
                return containsSubstr (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 20000) "HANDOVER p0 done"
              let l ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 20000
              for x in (l.splitOn "\n").filter (fun x => containsSubstr x "HANDOVER" || containsSubstr x "graceful drain" || containsSubstr x "ledger restored") do c.art "operator-handover.txt" x
              if !done then
                checkFail := some ((checkFail.map (· ++ "; ")).getD "" ++ "the next leader did not finish the handover within 240 s (see operator-handover.txt)")
              opDetail := s!"delete accepted; lease taken mid-handover; old leader stopped and exited; handover finished by the next leader={done}"
      | other => opOk := false; opDetail := s!"expected exactly one operator pod, saw {other}"
    c.event s!"operation: ok={opOk} {opDetail}"
    if opOk && (op == .rollingRestart || op == .rollBoth) then
      let ok ← kubectlRolloutStatus s!"statefulset/{c.cfg.name}-nodes" ns 900
      if !ok then opOk := false; opDetail := opDetail ++ "; statefulset rollout did not complete within 900 s"
      c.event s!"statefulset rollout complete={ok}"
    if opOk && op == .rollBoth then
      let ok ← kubectlRolloutStatus s!"deployment/{c.cfg.operatorName}" ns 600
      let opAfter ← opUids ()
      let replaced := match opBefore, opAfter with
        | some b, some a => !b.isEmpty && !a.isEmpty && b.all (fun u => !a.contains u)
        | _, _ => false
      c.event s!"operator rollout complete={ok}, operator pods replaced={replaced} ({opBefore} -> {opAfter})"
      if !ok then opOk := false; opDetail := opDetail ++ "; operator rollout did not complete within 600 s"
      if !replaced then opOk := false; opDetail := opDetail ++ s!"; operator pods not replaced ({opBefore} -> {opAfter})"
    -- PVC on local-path storage: the volume is pinned to the drained node, so
    -- its pod can only come back there. Check that the drain emptied the node
    -- now, then uncordon so the replacement can schedule and resync (CI
    -- 40811206461: the pod sat Pending 10 min and the check could never pass)
    let mut offAtDrain : Option Bool := none
    if op == .drainMaster && c.cfg.usePvc && c.cfg.storageClass.isNone then
      let now := (← c.pods).getD []
      let off := !(now.any fun (a : PodRow) => some a.node == drained && !a.deleting)
      offAtDrain := some off
      c.event s!"pvc: no flared pod running on {drained} after the drain={off}; uncordoning so the pinned volume's pod can return"
      if let some n := drained then uncordon n
    let (ips1, red) ← observe c 600 (redundant c (if offAtDrain.isSome then none else drained))
    c.event s!"redundancy restored={red}"
    -- did pods move
    let after := (← c.pods).getD []
    -- replaced = a new incarnation (another UID) that is Ready; a Pending or
    -- missing replacement has not moved
    let uidChanged := fun (n : String) => match before.find? (·.name == n), after.find? (·.name == n) with
      | some b, some a => b.uid != a.uid && a.ready && !a.deleting
      | _, _ => false
    let (moved, movedDetail) := match op with
      | .deleteMaster | .deleteMasterSaveFail | .deleteMasterAbortRetry | .deleteMasterLeaseTakeover | .deleteMasterObserveFail => (uidChanged p.master.name, s!"master pod {p.master.name} replaced={uidChanged p.master.name}")
      | .rollingRestart | .rollBoth | .helmUpgrade =>
        let all := before.all fun (b : PodRow) => uidChanged b.name
        (all, s!"every pod replaced={all} ({before.map fun (b : PodRow) => (b.name, uidChanged b.name)})")
      | .cordonMaster | .cordonReplica =>
        let target := if op == SwitchOp.cordonMaster then p.master else p.replica
        let off := !(after.any fun (a : PodRow) => some a.node == drained)
        (off && uidChanged target.name, s!"no flared pod left on {drained}={off}, {target.name} recreated elsewhere={uidChanged target.name}")
      | .drainMaster =>
        match offAtDrain with
        | some off =>
          (off && uidChanged p.master.name, s!"pvc: no flared pod left on {drained} after the drain={off}, master pod RECREATED on its pinned node after uncordon={uidChanged p.master.name} (local-path: a recreation, NOT a relocation to another node; cordon-move acceptance needs migratable storage)")
        | none =>
          let off := !(after.any fun (a : PodRow) => some a.node == drained)
          (off && uidChanged p.master.name, s!"no flared pod left on {drained}={off}, master pod replaced={uidChanged p.master.name}")
    c.event s!"moved={moved}: {movedDetail}"
    let (ips2, _) ← observe c 10 (pure false)
    if let some n := drained then uncordon n
    let svc? ← c.stopLoad "svc" 4
    let peer? ← c.stopLoad "peer" 2
    let (some svcRes, some peerRes) := (svc?, peer?)
      | return .error (unobservable "a load log could not be read or failed its integrity check (never counted as 'no error')")
    let ips := ips0 ++ ips1 ++ ips2
    let newM := (← c.roles).bind (·.1)
    let ps := (← c.pods).getD []
    let svcRs := svcRes.recs
    let peerRs := peerRes.recs
    let acks : List WriteRec := ((svcRs ++ peerRs).filter (fun (r : LoadRec) => r.ack)).map (fun (r : LoadRec) => r.toWrite)
    let copies ← finalCopies c "settled"
    let copyOf := fun (cs : List (String × Option (List (String × String)))) (pod : Option String) => pod.bind fun n => (cs.lookup n).join
    let replicaPod : Option String := (ps.find? (fun (r : PodRow) => some r.name != newM)).map (fun (r : PodRow) => r.name)
    let mm ← match copyOf copies newM with | some d => pure (some (← recordMissing c "master" acks d)) | none => pure none
    let mr ← match copyOf copies replicaPod with | some d => pure (some (← recordMissing c "replica-settled" acks d)) | none => pure none
    -- a gap that a repair fills is delayed, not lost: read the replica again after 120 s
    let mrLater ← if mr == some 0 then pure mr else do
      let (_, _) ← observe c 120 (pure false)
      let copies2 ← finalCopies c "later"
      match copyOf copies2 replicaPod with
      | some d => pure (some (← recordMissing c "replica-later" acks d))
      | none => pure none
    let o : SwitchObs := { opOk, opDetail, moved, movedDetail, svc := loadStats svcRes, peer := loadStats peerRes,
                           svcByPod := errorsByPod ips svcRs, peerByPod := errorsByPod ips peerRs,
                           missingMaster := mm, missingReplica := mr, missingReplicaLater := mrLater,
                           redundant := red, newMaster := newM, checkFail,
                           errorsAllowed := op == SwitchOp.deleteMasterLeaseTakeover }
    c.art "report.txt" (o.svc.summary "svc")
    c.art "report.txt" (o.peer.summary "peer")
    return .ok o

/-- Every flared pod of the cluster: name, UID, restart count, container ID
    and its last termination (reason / exitCode / signal / finishedAt). -/
private def podIncarnations (c : Ctx) : IO (List (String × String × String × String × String)) := do
  match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"cluster={c.cfg.name}", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.metadata.uid}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].containerID}|{.status.containerStatuses[0].lastState.terminated.reason}/{.status.containerStatuses[0].lastState.terminated.exitCode}/{.status.containerStatuses[0].lastState.terminated.signal}/{.status.containerStatuses[0].lastState.terminated.finishedAt}{\"\\n\"}{end}"] with
  | .ok o => return (o.splitOn "\n").filterMap fun l =>
      match l.trim.splitOn "|" with
      | [n, u, r, cid, last] => some (n, u, r, cid, last)
      | _ => none
  | .error _ => return []

def switchTest (c : Ctx) (op : SwitchOp) : IO TestResult := do
  -- a flared that restarts INSIDE its pod (same UID) during an operation
  -- that only replaces or keeps pods is no part of the operation
  -- (41278035134: a master's flared died with no log line): recorded before
  -- and after with its last termination, and a broken precondition — told
  -- apart from the data verdict
  let inc0 ← podIncarnations c
  for (n, u, r, cid, last) in inc0 do
    IO.eprintln s!"# [{c.test}] before: {n} uid {u} restarts {r} container {cid} lastState.terminated {last}"
  let run ← switchRun c op
  let inc1 ← podIncarnations c
  let mut unexpected : List String := []
  for (n, u, r, cid, last) in inc1 do
    IO.eprintln s!"# [{c.test}] after: {n} uid {u} restarts {r} container {cid} lastState.terminated {last}"
    match inc0.find? (fun (n0, u0, _, _, _) => n0 == n && u0 == u) with
    | some (_, _, r0, cid0, _) =>
      if r0 != r || cid0 != cid then
        unexpected := unexpected ++ [s!"{n} (restarts {r0} -> {r}, container {cid0} -> {cid}, lastState.terminated {last})"]
    | none => pure ()
  if !unexpected.isEmpty then
    return .fail s!"PRECONDITION NOT MET: flared restarted inside its pod during {op.label} (no part of the operation): {unexpected} — not a verdict on the switch"
  match run with
  | .error e => return .fail e
  | .ok o =>
    IO.eprintln s!"# [{c.test}] {op.label}: operation ok={o.opOk} ({o.opDetail}); moved={o.moved} ({o.movedDetail}); master -> {o.newMaster}; redundancy={o.redundant}; missing on master {o.missingMaster}, on replica {o.missingReplica} when settled and {o.missingReplicaLater} 120 s later; {o.svc.summary "svc"}; errors by pod {o.svcByPod}; {o.peer.summary "peer"}; errors by pod {o.peerByPod}"
    match switchVerdict o with
    | some why => return .fail why
    | none => return .pass

/-- S5 (review of 8d64aaf): the drain gate must not call a drain lossless when
    the old master's forwards to the replica fail. The master is cut from the
    replica (both directions, iptables on the kind nodes) and deleted under a
    write load; its own log (followed while it runs) must carry a NOT LOSSLESS
    / NOT CONFIRMED report from preStop or flared and no lossless claim. This
    is a gate test, not a data verdict (the cut makes the old master's late
    writes undeliverable on purpose). -/
def gateTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .fail (notSetUp "the cluster did not start this test with a healthy pair")
    c.conditions ["S5: the master is cut from the replica, then deleted under a write load; its log must report the drain as NOT lossless"]
    match ← c.ensureLoadWriter with
    | .error e => return .fail (notSetUp e)
    | .ok () => pure ()
    let ns := c.cfg.«namespace»
    let logFile := s!"/tmp/s5-{ns}-{p.master.name}-{← epochNow}.log"
    discard <| IO.Process.output { cmd := "sh", args := #["-c", s!"(kubectl logs -f {p.master.name} -n {ns} -c flared > {logFile} 2>&1 &) >/dev/null 2>&1"] }
    -- and a snapshot every second while the pod exists: a follow can end
    -- early (40729612644: the runner ran out of inotify instances)
    let snapFile := logFile ++ ".snap"
    discard <| IO.Process.output { cmd := "sh", args := #["-c", s!"(while kubectl get pod {p.master.name} -n {ns} -o jsonpath='\{.metadata.uid}' 2>/dev/null | grep -qx {p.master.uid}; do kubectl logs {p.master.name} -n {ns} -c flared > {snapFile}.tmp 2>/dev/null && mv {snapFile}.tmp {snapFile}; sleep 1; done &) >/dev/null 2>&1"] }
    if !(← c.startLoad "svc" (svcHost c) 4 200) then return .fail (notSetUp "the load did not start")
    let (_, _) ← observe c 10 (pure false)
    let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
    let installed ← match ← installCuts rules with
      | .ok r => pure r
      | .error (why, part) => removeCuts part; return .fail (notSetUp s!"could not cut master <-> replica: {why}")
    c.event s!"cut {p.master.ip} <-> {p.replica.ip} ({installed.length} rules); deleting the master {p.master.name}"
    discard <| kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"]
    let gone ← waitForCondition s!"the old master pod {p.master.uid} is gone" (c.cfg.drainSeconds + 90) do
      let ps := (← c.pods).getD []
      return !(ps.any fun q => q.uid == p.master.uid)
    removeCuts installed
    c.event s!"old master gone={gone}; cut removed"
    discard <| c.stopLoad "svc" 4
    let followed ← (try IO.FS.readFile logFile catch _ => pure "")
    let snap ← (try IO.FS.readFile (logFile ++ ".snap") catch _ => pure "")
    -- the longer of the two (both are the same log from its start)
    let log := if snap.length > followed.length then snap else followed
    -- the whole followed log is kept: PVC 40449082661 had a log without any
    -- verdict line, and the file under /tmp was not uploaded to tell why
    c.art "old-master.log" log
    for l in (log.splitOn "\n").filter (fun l => containsSubstr l "preStop" || containsSubstr l "forward drain") do
      c.art "gate.txt" l
    let claimedLossless := containsSubstr log "every forward delivered" || containsSubstr log "shutdown forward drain lossless"
    let reportedNot := containsSubstr log "NOT LOSSLESS" || containsSubstr log "NOT CONFIRMED"
    IO.eprintln s!"# [{c.test}] old master gone={gone}; gate lines {(log.splitOn "\n").filter (fun l => containsSubstr l "preStop" || containsSubstr l "forward drain")}"
    let (_, _) ← observe c 300 (redundant c none)
    if !gone then return .fail (notSetUp "the old master pod did not go away")
    if log.isEmpty then return .fail (unobservable "the old master's log could not be followed")
    if claimedLossless then return .fail "GATE: the drain was reported lossless although the old master's forwards to the replica were cut"
    if !reportedNot then return .fail (unobservable "the old master's log carries no drain verdict at all (NOT LOSSLESS / NOT CONFIRMED)")
    return .pass

/-- A one-shot memcached client in the load-writer pod: sends `req` to
    host:12121 and prints `REPLY <repr> <seconds>` once a reply line (or the
    `END` of a get) arrived, or the connection ended. -/
private def oneShotScript : String := "import socket, sys, time
t = time.time()
host, req, until_end = sys.argv[1], sys.argv[2].encode().decode('unicode_escape').encode(), sys.argv[3] == '1'
b = b''
try:
    s = socket.create_connection((host, 12121), timeout=150)
    s.settimeout(150)
    s.sendall(req)
    while True:
        d = s.recv(4096)
        if not d:
            break
        b += d
        if (until_end and b.endswith(b'END\\r\\n')) or (not until_end and b.endswith(b'\\r\\n')):
            break
except Exception as e:
    b += ('EXC ' + type(e).__name__).encode()
print('REPLY', repr(b), round(time.time() - t, 1))
"

private def oneShotArgs (c : Ctx) (host req : String) (untilEnd : Bool) : Array String :=
  #["exec", loadWriterPod c, "-n", c.cfg.«namespace», "--", "python3", "-c", oneShotScript, host, req, if untilEnd then "1" else "0"]

/-- S6 (review of 09624ee): a sync client write waits on a forward held for up
    to the hold window (60 s); a SIGTERM must not cut it off. The master is cut
    from the replica, a client sends one `set ... sync` to the master, flared
    is sent SIGTERM 5 s later, and the cut is removed 40 s after the SIGTERM —
    past the old 30 s stop budget, inside the hold. The client must get its
    terminal answer (STORED: the replica has the write) and the replica must
    hold the value. -/
def sigtermHoldTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    if !(← operatorSettled c) then
      return .fail (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .fail (notSetUp "the cluster did not start this test with a healthy pair")
    c.conditions ["S6: one sync client write waits on a forward held by a master/replica cut; the master gets SIGTERM 5 s later; the cut is removed 40 s after the SIGTERM; the client must get STORED and the replica must hold the value"]
    match ← c.ensureLoadWriter with
    | .error e => return .fail (notSetUp e)
    | .ok () => pure ()
    let ns := c.cfg.«namespace»
    let key := s!"s6key{← epochNow}"
    let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
    let installed ← match ← installCuts rules with
      | .ok r => pure r
      | .error (why, part) => removeCuts part; return .fail (notSetUp s!"could not cut master <-> replica: {why}")
    c.event s!"cut {p.master.ip} <-> {p.replica.ip}; sending one sync set of {key} to the master {p.master.name}"
    let client ← IO.Process.spawn { cmd := "kubectl", args := oneShotArgs c p.master.ip s!"set {key} 0 0 5 sync\\r\\nvalue\\r\\n" false,
                                    stdout := .piped, stderr := .piped }
    IO.sleep 5000
    let term ← kubectlLong 30 ["exec", p.master.name, "-n", ns, "-c", "flared", "--", "sh", "-c", "kill -TERM 1"]
    c.event s!"SIGTERM to flared on {p.master.name}: {match term with | .ok _ => "sent" | .error e => s!"failed: {e}"}"
    IO.sleep 40000
    removeCuts installed
    c.event "cut removed (40 s after the SIGTERM)"
    let out ← client.stdout.readToEnd
    let _ ← client.wait
    let reply := ((out.splitOn "\n").find? (fun l => l.startsWith "REPLY")).getD s!"(no reply line: {out.take 200})"
    c.event s!"client: {reply}"
    let (_, _) ← observe c 300 (redundant c none)
    -- the replica's OWN copy (a get through it can be proxied: a replica that
    -- re-validates forwards reads, and a restarted master without a
    -- partition answers a miss — CI 40653574118 read END that way)
    let copy ← c.ownCopy p.replica.ip
    let onReplica := (copy.getD []).any (·.1 == key)
    IO.eprintln s!"# [{c.test}] SIGTERM {match term with | .ok _ => "sent" | .error e => s!"failed ({e})"}; client {reply}; replica's own copy holds the value={onReplica} ({match copy with | some d => s!"{d.length} keys" | none => "UNREADABLE"})"
    if copy.isNone then return .fail (unobservable "the replica's own copy could not be read")
    if term matches .error _ then return .fail (notSetUp "the SIGTERM could not be sent")
    if !containsSubstr reply "STORED" then
      return .fail s!"the sync client write did not get its terminal answer STORED across the SIGTERM: {reply}"
    if !onReplica then return .fail s!"the client was told STORED but the replica does not hold {key}"
    -- masterless -> the same key re-seated (review of 5c904b2): the restarted
    -- master is re-registered as a slave, the partition has no master for a
    -- few passes, and the same key is promoted again with a new epoch and UID.
    -- The probe must still see that as a master change (forced follow reads of
    -- the surviving replica); before the fix the masterless pass erased the
    -- last identity and nothing was logged (41074726518).
    let lines := (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000).splitOn "\n"
    -- the LAST promotion of that key is the re-seat (an earlier one may be its first seat)
    let reseat := lines.reverse.findIdx? fun l => containsSubstr l "PROMOTION committed" && containsSubstr l p.master.name
    match reseat with
    | some j =>
      let after := lines.drop (lines.length - j)
      if !(after.any (containsSubstr · "master changed on partition(s) [0]")) then
        return .fail s!"{p.master.name} was re-seated after a masterless pass, but the operator did not see a master change on partition 0 (no forced follow probe of the surviving replica)"
    | none =>
      -- the case this checks did not happen: never counted as a pass (review of 7feb0e8)
      return .fail (notSetUp s!"no re-seat of {p.master.name} after the SIGTERM: the masterless pass -> same key back case was not exercised")
    return .pass

/-- S9 (review of 4bdc83b): attempt exhaustion through the real
    orchestration. The master stays cut from its successor, so every handover
    aborts on Th; attempts 2 and 3 must start, and only after the third
    abort may the one-map drain take the master. An orchestration test, not
    a data verdict: the cut makes the old master's forwards undeliverable on
    purpose. -/
def abortExhaustTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    if !(← operatorSettled c) then
      return .fail (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .fail (notSetUp "the cluster did not start this test with a healthy pair")
    c.conditions ["S9: the master is cut from its successor and deleted under a write load; the cut stays: three handover attempts abort, then the one-map drain may take the master"]
    let ns := c.cfg.«namespace»
    -- writes keep forwards to the cut successor in flight: without them the
    -- drain is trivially clean and nothing aborts (first local run)
    match ← c.ensureLoadWriter with
    | .error e => return .fail (notSetUp e)
    | .ok () => pure ()
    if !(← c.startLoad "svc" (svcHost c) 4 200) then return .fail (notSetUp "the write load did not start")
    let opLogs := fun (_ : Unit) => kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000
    let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
    let installed ← match ← installCuts rules with
      | .ok r => pure r
      | .error (why, part) => removeCuts part; return .fail (notSetUp s!"could not cut master <-> replica: {why}")
    c.event s!"cut {p.master.ip} <-> {p.replica.ip}; deleting the master {p.master.name}"
    match ← kubectlLong 180 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
    | .error e => removeCuts installed; return .fail (notSetUp s!"delete failed: {e.take 200}")
    | .ok _ => pure ()
    let drainLine := s!"graceful drain: demoting Terminating node(s) to live proxy + promoting replacement(s): [{p.master.name}"
    let count := fun (l n : String) => (l.splitOn n).length - 1
    -- an attempt ends in an abort from any phase: attempt 1 from draining,
    -- 2 and 3 from requested (the R3 precheck never demotes towards a copy
    -- that cannot re-validate while it is cut; 998dc30 S9), or, when no
    -- replica is acceptable as the retry falls due, as an abort without a
    -- map (3dcfc5c S9: attempt 3 was never opened and the drain was held)
    let abortMark := "-> aborted after"
    let done ← waitForCondition "three handover attempts aborted, then the one-map drain took the master" 170 do
      let l ← opLogs ()
      return count l abortMark >= 3 && containsSubstr l drainLine
    removeCuts installed
    discard <| c.stopLoad "svc" 4
    let l ← opLogs ()
    for x in (l.splitOn "\n").filter (fun x => containsSubstr x "HANDOVER" || containsSubstr x "graceful drain") do c.art "operator-handover.txt" x
    -- order: the drain line comes after the third abort
    let afterThird := match (l.splitOn abortMark).drop 3 with
      | rest :: _ => containsSubstr rest drainLine
      | [] => false
    let beforeThird := match (l.splitOn abortMark).take 3 with
      | parts => parts.any (containsSubstr · drainLine)
    IO.eprintln s!"# [{c.test}] aborts={count l abortMark}, attempt 2 started={containsSubstr l "(attempt 2 of"}, attempt 3 started={containsSubstr l "(attempt 3 of"}, drain after the third abort={afterThird}, drain before it={beforeThird}"
    if !done then return .fail "three aborts followed by the one-map drain were not seen within 170 s (see operator-handover.txt)"
    if !(containsSubstr l "(attempt 2 of" && containsSubstr l "(attempt 3 of") then
      return .fail "attempt 2 or 3 never started (see operator-handover.txt)"
    if beforeThird then return .fail "the one-map drain took the master before the attempts were used up"
    if !afterThird then return .fail "the one-map drain did not follow the third abort"
    return .pass

/-- G1 (A0 stage 6b): the node-guard webhook. With the guard on:
    a force delete (grace 0) of the master is refused and the pod stays;
    a StatefulSet scale-down over an ordinal that holds data is refused;
    the delete-override annotation (the pod's UID) lets a force delete of
    the replica through; a graceful delete of the master is refused until
    the ordered handover has moved its partition, then allowed. -/
def nodeGuardTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    if !(← operatorSettled c) then
      return .fail (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .fail (notSetUp "the cluster did not start this test with a healthy pair")
    c.conditions ["G1: node guard on; force delete / scale-down refused, override and graceful delete allowed"]
    let ns := c.cfg.«namespace»
    let uidOf := fun (pod : String) => do
      match ← kubectl ["get", "pod", pod, "-n", ns, "-o", "jsonpath={.metadata.uid}"] with
      | .ok o => pure o.trim
      | .error _ => pure ""
    let mut fails : List String := []
    -- 1. force delete of the master: refused, the pod stays
    let mUid ← uidOf p.master.name
    let r1 ← kubectlLong 60 ["delete", "pod", p.master.name, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
    let mUidAfter ← uidOf p.master.name
    c.event s!"force delete of the master: {match r1 with | .ok o => s!"ACCEPTED {o.take 120}" | .error e => s!"refused: {e.take 300}"}"
    match r1 with
    | .ok _ => fails := fails ++ ["the force delete of the master was accepted"]
    | .error e =>
      if !containsSubstr e "flare: a force delete" then fails := fails ++ [s!"the force delete was refused, but not by the node guard: {e.take 200}"]
    if mUidAfter != mUid then fails := fails ++ ["the master pod was replaced after a refused force delete"]
    -- 2. scale-down over the replica's ordinal: refused
    let r2 ← kubectl ["scale", s!"statefulset/{c.cfg.name}-nodes", "-n", ns, "--replicas=1"]
    c.event s!"scale 2 -> 1: {match r2 with | .ok o => s!"ACCEPTED {o.take 120}" | .error e => s!"refused: {e.take 300}"}"
    match r2 with
    | .ok _ =>
      fails := fails ++ ["the scale-down over a data-holding ordinal was accepted"]
      discard <| kubectl ["scale", s!"statefulset/{c.cfg.name}-nodes", "-n", ns, "--replicas=2"]
    | .error e =>
      if !containsSubstr e "flare: scaling" then fails := fails ++ [s!"the scale-down was refused, but not by the node guard: {e.take 200}"]
    -- 2b. (review of 62dddf9) a label removed from the master does not hide
    -- its delete from the guard (no label selector; judged by subdomain)
    let r2b ← match ← kubectl ["label", "pod", p.master.name, "-n", ns, "app-"] with
      | .error e => pure (Except.error s!"(label removal failed: {e.take 200})")
      | .ok _ => kubectlLong 60 ["delete", "pod", p.master.name, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
    discard <| kubectl ["label", "pod", p.master.name, "-n", ns, "--overwrite", "app=flare"]
    let mUid2b ← uidOf p.master.name
    c.event s!"force delete of the master with its app label removed: {match r2b with | .ok o => s!"ACCEPTED {o.take 120}" | .error e => s!"refused: {e.take 300}"}"
    match r2b with
    | .ok _ => fails := fails ++ ["the force delete of the master was accepted once its app label was removed"]
    | .error e =>
      if !containsSubstr e "flare: a force delete" then fails := fails ++ [s!"the force delete of the unlabelled master was refused, but not by the node guard: {e.take 200}"]
    if mUid2b != mUid then fails := fails ++ ["the master pod was replaced after the refused delete of the unlabelled master"]
    -- 2c. (review of 62dddf9) a cascading delete of the StatefulSet is
    -- refused: its garbage collection would delete every pod, the master too
    let stsUid := fun (_ : Unit) => do
      match ← kubectl ["get", "statefulset", s!"{c.cfg.name}-nodes", "-n", ns, "-o", "jsonpath={.metadata.uid}"] with
      | .ok o => pure o.trim
      | .error _ => pure ""
    let sUid ← stsUid ()
    let r2c ← kubectlLong 60 ["delete", "statefulset", s!"{c.cfg.name}-nodes", "-n", ns, "--wait=false"]
    let sUidAfter ← stsUid ()
    c.event s!"cascading delete of the StatefulSet: {match r2c with | .ok o => s!"ACCEPTED {o.take 120}" | .error e => s!"refused: {e.take 300}"}; uid {sUid} -> {sUidAfter}"
    match r2c with
    | .ok _ => fails := fails ++ ["the cascading delete of the StatefulSet was accepted"]
    | .error e =>
      if !containsSubstr e "flare: deleting the flared StatefulSet" then fails := fails ++ [s!"the StatefulSet delete was refused, but not by the node guard: {e.take 200}"]
    if sUidAfter != sUid || (← uidOf p.master.name) != mUid then
      fails := fails ++ ["the StatefulSet or the master pod is gone after the refused cascading delete"]
    if !fails.isEmpty then
      if !(← waitForCondition "the pair is redundant again" 600 (redundant c none)) then
        fails := fails ++ ["the pair did not become redundant again"]
    -- 3. the override lets a force delete of the replica through
    let rUid ← uidOf p.replica.name
    discard <| kubectl ["annotate", "pod", p.replica.name, "-n", ns, "--overwrite", s!"flare.gree.net/delete-override={rUid}"]
    let r3 ← kubectlLong 60 ["delete", "pod", p.replica.name, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
    -- judged by the outcome, not kubectl's exit: the API server may run the
    -- delete's admission again on the pod the StatefulSet already recreated
    -- under the same name (a new UID, no override), which is refused as it
    -- should be — the pod the override named is gone either way
    let rUidAfter ← uidOf p.replica.name
    c.event s!"force delete of the replica with the override: {match r3 with | .ok _ => "accepted" | .error e => s!"kubectl error (tail) {e.takeRight 400}"}; uid {rUid} -> {rUidAfter}"
    if rUidAfter == rUid then fails := fails ++ ["the override did not let the force delete of the replica through (the pod is still there)"]
    else if !containsSubstr (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 20000) s!"allowed DELETE pods {p.replica.name} (uid {rUid}" then
      fails := fails ++ ["the replica was replaced, but the node guard did not log the override allowing it"]
    if !(← waitForCondition "the replica is back and the pair redundant" 600 (redundant c none)) then
      fails := fails ++ ["the pair did not become redundant again after the replica's force delete"]
    -- 4. a graceful delete of the master (review of 9756855): refused first,
    -- the operator hands the partition over, and the retried delete passes
    -- only once the old master is no longer the master — the delete never
    -- precedes the switch
    let r4 ← kubectlLong 60 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"]
    c.event s!"graceful delete of the master (first): {match r4 with | .ok _ => "ACCEPTED" | .error e => s!"refused {e.take 300}"}"
    match r4 with
    | .ok _ => fails := fails ++ ["the first graceful delete of the master was accepted (it must be handed over first)"]
    | .error e =>
      if !containsSubstr e "handing the partition over" then
        fails := fails ++ [s!"the first graceful delete of the master was refused, but not as a handover request: {e.take 200}"]
      else
        let mut accepted := false
        let mut tries := 0
        let mUid4 ← uidOf p.master.name
        while !accepted && tries < 60 do
          IO.sleep 3000
          tries := tries + 1
          match ← kubectlLong 60 ["delete", "pod", p.master.name, "-n", ns, "--wait=false"] with
          | .ok _ => accepted := true
          | .error _ => pure ()
        let opLog ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 20000
        let lines := opLog.splitOn "\n"
        let doneIdx := lines.findIdx? (containsSubstr · "HANDOVER p0 done")
        let allowIdx := lines.findIdx? fun l => containsSubstr l s!"allowed DELETE pods {p.master.name} (uid {mUid4}"
        c.event s!"graceful delete of the master: accepted after {tries} retries={accepted}; handover done at log line {doneIdx}, delete allowed at line {allowIdx}"
        if !accepted then fails := fails ++ ["the retried graceful delete of the master was never accepted (no handover completed?)"]
        else match doneIdx, allowIdx with
          | some d, some a => if a < d then fails := fails ++ ["the master's delete was allowed before its handover completed"]
          | none, _ => fails := fails ++ ["no handover completed before the master's delete was allowed"]
          | _, none => fails := fails ++ ["the node guard did not log allowing the handed-over master's delete"]
    let logs ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 20000
    for x in (logs.splitOn "\n").filter (fun x => containsSubstr x "NODE GUARD") do c.art "node-guard.txt" x
    IO.eprintln s!"# [{c.test}] node guard: {if fails.isEmpty then "every check held" else String.intercalate "; " fails}"
    if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

/-- the pod's UID and whether it carries the serving label ("" = unreadable) -/
private def podUidServing (c : Ctx) (pod : String) : IO (String × Bool) := do
  match ← kubectl ["get", "pod", pod, "-n", c.cfg.«namespace», "-o",
      "jsonpath={.metadata.uid} {.metadata.labels.flare\\.gree\\.net/serving}"] with
  | .ok o =>
    let ws := (o.trim.splitOn " ").filter (· != "")
    return (ws.head?.getD "", ws.length ≥ 2)
  | .error _ => return ("", false)

/-- C3: the partition has fewer real copies than minCopies (2 vs 3): cordon +
    drain of the replica's worker never starts a move; the drain's evictions
    are held (it times out), the replica keeps its pod, its role and the
    serving label, and the move is reported blocked. Uncordon ends it. -/
def cordonBlockedTest (c : Ctx) (cond : String := "C3: minCopies 3 on a 2-copy pair; cordon + drain (90 s) of the replica's worker")
    (reason : Option String := none) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    if !(← operatorSettled c) then
      return .fail (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .fail (notSetUp "the cluster did not start this test with a healthy pair")
    c.conditions [cond]
    let ns := c.cfg.«namespace»
    let (uid0, _) ← podUidServing c p.replica.name
    if uid0.isEmpty then return .fail (notSetUp s!"the uid of {p.replica.name} is unreadable")
    let mut fails : List String := []
    match ← kubectl ["cordon", p.replica.node] with
    | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
    | .ok _ => pure ()
    let stem ← startDrain p.replica.node 90
    discard <| waitForCondition "the drain ended" 150 (return (← drainResult stem).isSome)
    let drain ← drainResult stem
    match drain with
    | some (rc, out) =>
      for l in out.splitOn "\n" do c.art "drain.txt" l
      c.event s!"drain rc={rc}"
      if rc == "0" then fails := fails ++ ["the drain completed: the eviction of a pod whose move cannot start was allowed"]
    | none => fails := fails ++ ["the drain did not end within 150 s"]
    let (uid1, serving1) ← podUidServing c p.replica.name
    if uid1 != uid0 then fails := fails ++ [s!"{p.replica.name} was replaced ({uid0} -> {uid1})"]
    if !serving1 then fails := fails ++ [s!"{p.replica.name} lost the serving label"]
    let logs ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000
    for x in (logs.splitOn "\n").filter (fun x => containsSubstr x "NODE MOVE" || containsSubstr x "NODE GUARD") do c.art "cordon-move.txt" x
    if containsSubstr logs s!"NODE MOVE started: {p.replica.name}" then
      fails := fails ++ [s!"a move of {p.replica.name} started with fewer copies than minCopies"]
    let ev ← match ← kubectl ["get", "events", "-n", ns, "--field-selector", "reason=FlareCordonMoveBlocked", "-o", "jsonpath={.items[*].message}"] with
      | .ok o => pure o
      | .error _ => pure ""
    c.event s!"blocked events: {ev.take 300}"
    if !containsSubstr ev p.replica.name then fails := fails ++ ["no FlareCordonMoveBlocked event names the replica"]
    if let some r := reason then
      if !containsSubstr ev r then fails := fails ++ [s!"the FlareCordonMoveBlocked event does not give the reason \"{r}\""]
    uncordon p.replica.node
    if !(← waitForCondition "the pair is still redundant after the uncordon" 120 (redundant c none)) then
      fails := fails ++ ["the pair is not redundant after the uncordon"]
    return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- C4: uncordon BEFORE the move is released cancels it: the replica, already a
    proxy out of the clients' Service, gets the serving label back, keeps its
    pod (same UID) and is a synced replica again. No drain runs. -/
def cordonCancelTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    if !(← operatorSettled c) then
      return .fail (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .fail (notSetUp "the cluster did not start this test with a healthy pair")
    c.conditions ["C4: minCopies 2; cordon of the replica's worker, uncordon once the move is proxied (no drain)"]
    let ns := c.cfg.«namespace»
    let (uid0, _) ← podUidServing c p.replica.name
    if uid0.isEmpty then return .fail (notSetUp s!"the uid of {p.replica.name} is unreadable")
    let opLogs := do return (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000)
    match ← kubectl ["cordon", p.replica.node] with
    | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
    | .ok _ => pure ()
    let proxied ← waitForCondition s!"the move of {p.replica.name} is proxied" 180 do
      return containsSubstr (← opLogs) s!"NODE MOVE {p.replica.name}@{p.replica.node}: pending -> proxied"
    uncordon p.replica.node
    c.event s!"uncordoned {p.replica.node} (move proxied={proxied})"
    if !proxied then return .fail (notSetUp s!"the move of {p.replica.name} never reached proxied within 180 s")
    let logs0 ← opLogs
    if containsSubstr logs0 s!"NODE MOVE {p.replica.name}@{p.replica.node}: unserved -> released" then
      return .fail (notSetUp "the move was released before the uncordon: the cancel case was not exercised")
    let mut fails : List String := []
    let cancelled ← waitForCondition s!"the move of {p.replica.name} is cancelled" 120 do
      return ((← opLogs).splitOn "\n").any fun l =>
        containsSubstr l s!"NODE MOVE {p.replica.name}@{p.replica.node}:" && containsSubstr l "-> cancelled"
    if !cancelled then fails := fails ++ ["no cancel of the move was logged after the uncordon"]
    let back ← waitForCondition s!"{p.replica.name} serves again" 120 do
      return (← podUidServing c p.replica.name).2
    if !back then fails := fails ++ [s!"{p.replica.name} did not get the serving label back"]
    let (uid1, _) ← podUidServing c p.replica.name
    if uid1 != uid0 then fails := fails ++ [s!"{p.replica.name} was replaced ({uid0} -> {uid1}) although the move was cancelled"]
    if !(← waitForCondition "the pair is redundant again" 300 (redundant c none)) then
      fails := fails ++ ["the replica did not become a synced replica again"]
    for x in ((← opLogs).splitOn "\n").filter (fun x => containsSubstr x "NODE MOVE" || containsSubstr x "serving label") do c.art "cordon-move.txt" x
    if (← opLogs).splitOn "\n" |>.any (fun l => containsSubstr l s!"NODE MOVE {p.replica.name}@" && containsSubstr l "-> released") then
      fails := fails ++ ["the move was released after the uncordon"]
    return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- Common start of C5-C8: the operator settled and a healthy pair. -/
private def cordonPrecond (c : Ctx) : IO (Except String Placement) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    if !(← operatorSettled c) then
      return .error (notSetUp "the operator did not finish its startup grace period")
    if !(← waitForCondition "the pair is redundant with the replica on the master's history" 300 (redundant c none)) then
      return .error (notSetUp "the cluster did not start this test with a healthy pair")
    return .ok p

/-- C5: the successor cannot catch up (master <-> replica cut): cordon + drain
    of the master's worker. The handover aborts and is never completed, the
    master stays the master on the same pod, the drain's evictions stay held
    (it times out). After the cut is removed and the node uncordoned the pair
    is redundant again. -/
def cordonNoSuccessorTest (c : Ctx) : IO TestResult := do
  match ← cordonPrecond c with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["C5: minCopies 2; master <-> replica cut, then cordon + drain (120 s) of the master's worker"]
    let ns := c.cfg.«namespace»
    let (uid0, _) ← podUidServing c p.master.name
    let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
    match ← installCuts rules with
    | .error (why, part) => removeCuts part; return .fail (notSetUp s!"could not cut master <-> replica: {why}")
    | .ok installed =>
      let mut fails : List String := []
      try
        -- writes the replica cannot receive: without them the cut leaves it
        -- current and the handover is safe (41211321783: no write was made,
        -- the handover proved the drain and completed)
        let acked ← writeKeys c.cfg.debugPod ns p.master.ip c.cfg.flarePort "c5_cut" 20
        c.event s!"{acked}/20 writes acknowledged by the master during the cut"
        if acked == 0 then return .fail (notSetUp "the master acknowledged no write during the cut")
        match ← kubectl ["cordon", p.master.node] with
        | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
        | .ok _ => pure ()
        let stem ← startDrain p.master.node 120
        discard <| waitForCondition "the drain ended" 180 (return (← drainResult stem).isSome)
        match ← drainResult stem with
        | some (rc, out) =>
          for l in out.splitOn "\n" do c.art "drain.txt" l
          c.event s!"drain rc={rc}"
          if rc == "0" then fails := fails ++ ["the drain completed: the master's eviction was allowed although its successor could not catch up"]
        | none => fails := fails ++ ["the drain did not end within 180 s"]
        let logs ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000
        for x in (logs.splitOn "\n").filter (fun x => containsSubstr x "NODE MOVE" || containsSubstr x "HANDOVER" || containsSubstr x "NODE GUARD") do c.art "cordon-move.txt" x
        -- held before it starts (forwards dropped to the successor) or
        -- aborted: either way never done
        if (logs.splitOn "\n").any fun l => containsSubstr l "HANDOVER" && containsSubstr l " done in " then
          fails := fails ++ ["a handover completed although its successor could not catch up"]
        let (uid1, _) ← podUidServing c p.master.name
        if uid1 != uid0 then fails := fails ++ [s!"{p.master.name} was replaced ({uid0} -> {uid1})"]
        match (← c.roles).bind (·.1) with
        | some m => if m != p.master.name then fails := fails ++ [s!"the master moved to {m} although its successor could not catch up"]
        | none => fails := fails ++ ["partition 0 has no master"]
      finally
        removeCuts installed
        uncordon p.master.node
      if !(← waitForCondition "the pair is redundant after the cut and the cordon end" 300 (redundant c none)) then
        fails := fails ++ ["the pair is not redundant after the cut and the cordon were removed"]
      return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- C6: the operator restarts in the middle of a move (replica's worker
    cordoned, move proxied). The new operator resumes the SAME move from
    status.nodeMoves (no second move of the pod), and a drain then completes
    with the pod recreated elsewhere. -/
def cordonOperatorRestartTest (c : Ctx) : IO TestResult := do
  match ← cordonPrecond c with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["C6: minCopies 2; cordon of the replica's worker, the operator pod deleted once the move is proxied, then a drain"]
    let ns := c.cfg.«namespace»
    let (uid0, _) ← podUidServing c p.replica.name
    let opLogs := do return (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000)
    match ← kubectl ["cordon", p.replica.node] with
    | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
    | .ok _ => pure ()
    let mut fails : List String := []
    try
      let proxied ← waitForCondition s!"the move of {p.replica.name} is proxied" 180 do
        return containsSubstr (← opLogs) s!"NODE MOVE {p.replica.name}@{p.replica.node}: pending -> proxied"
      if !proxied then return .fail (notSetUp s!"the move of {p.replica.name} never reached proxied")
      let before ← opLogs
      for x in (before.splitOn "\n").filter (containsSubstr · "NODE MOVE") do c.art "operator-before.txt" x
      let ids := (before.splitOn "\n").filterMap fun l =>
        if containsSubstr l s!"NODE MOVE started: {p.replica.name}" then (l.splitOn "request ").getLast? else none
      let opPods ← getPodNames s!"app={c.cfg.operatorName}" ns
      for op in opPods do discard <| kubectl ["delete", "pod", op, "-n", ns, "--wait=false"]
      c.event s!"operator pod(s) {opPods} deleted mid-move (request {ids})"
      let back ← waitForCondition "a new operator pod runs" 240 do
        let now ← getPodNames s!"app={c.cfg.operatorName}" ns
        return !now.isEmpty && now.all (!opPods.contains ·) && (← kubectlRolloutStatus s!"deployment/{c.cfg.operatorName}" ns 5)
      if !back then return .fail "no new operator pod came up within 240 s"
      let released ← waitForCondition s!"the new operator releases the move of {p.replica.name}" 300 do
        return containsSubstr (← opLogs) s!"NODE MOVE {p.replica.name}@{p.replica.node}:" && containsSubstr (← opLogs) "-> released"
      let after ← opLogs
      for x in (after.splitOn "\n").filter (containsSubstr · "NODE MOVE") do c.art "operator-after.txt" x
      if !released then fails := fails ++ ["the new operator did not carry the move to released within 300 s"]
      if (after.splitOn "\n").any (containsSubstr · s!"NODE MOVE started: {p.replica.name}") then
        fails := fails ++ ["the new operator started a second move of the pod instead of resuming the recorded one"]
      let stem ← startDrain p.replica.node 300
      discard <| waitForCondition "the drain ended" 360 (return (← drainResult stem).isSome)
      match ← drainResult stem with
      | some (rc, out) =>
        for l in out.splitOn "\n" do c.art "drain.txt" l
        if rc != "0" then fails := fails ++ [s!"the drain did not complete after the release (rc {rc})"]
      | none => fails := fails ++ ["the drain did not end within 360 s"]
      let moved ← waitForCondition s!"{p.replica.name} recreated off {p.replica.node}" 300 do
        let ps := (← c.pods).getD []
        return ps.any fun (r : PodRow) => r.name == p.replica.name && r.uid != uid0 && r.node != p.replica.node && r.ready
      if !moved then fails := fails ++ [s!"{p.replica.name} was not recreated on another worker"]
    finally
      uncordon p.replica.node
    if !(← waitForCondition "the pair is redundant again" 300 (redundant c none)) then
      fails := fails ++ ["the pair is not redundant after the move"]
    return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- C7 (option B, user decision 2026-11-01): both workers that hold a flared
    pod are cordoned at once (no drain), two copies, minCopies 2. A copy on
    ANOTHER cordoned node counts, so the replica's move starts — with the
    warning FlareCordonMoveOnCordonedCopy (its only other copy, the master, is
    on a cordoned node) — and it is recreated on the free third worker. The
    master's move then hands over to it: the replica's pod becomes the
    master. The old master's pod cannot be placed (required anti-affinity,
    the free worker is taken) until the uncordons; then the pair is
    redundant again. -/
def cordonTwoNodesTest (c : Ctx) : IO TestResult := do
  match ← cordonPrecond c with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["C7: minCopies 2; the master's and the replica's workers cordoned together (no drain)"]
    let ns := c.cfg.«namespace»
    let opLogs := do return (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000)
    let (uidR, _) ← podUidServing c p.replica.name
    for n in [p.master.node, p.replica.node] do discard <| kubectl ["cordon", n]
    let mut fails : List String := []
    try
      let events := fun (reason : String) => do
        match ← kubectl ["get", "events", "-n", ns, "--field-selector", s!"reason={reason}", "-o", "jsonpath={.items[*].message}"] with
        | .ok o => pure o
        | .error _ => pure ""
      let warned ← waitForCondition s!"the move of {p.replica.name} starts with the warning" 180 do
        return containsSubstr (← events "FlareCordonMoveOnCordonedCopy") p.replica.name
      c.event s!"warning events: {(← events "FlareCordonMoveOnCordonedCopy").take 400}"
      if !warned then fails := fails ++ [s!"no FlareCordonMoveOnCordonedCopy warning for {p.replica.name} within 180 s (the replica's move did not start, or started without the warning)"]
      let moved ← waitForCondition s!"{p.replica.name} recreated off the cordoned workers" 420 do
        let ps := (← c.pods).getD []
        return ps.any fun (r : PodRow) => r.name == p.replica.name && r.uid != uidR
          && r.node != p.replica.node && r.node != p.master.node && r.ready
      if !moved then fails := fails ++ [s!"{p.replica.name} was not recreated on the free worker within 420 s"]
      let handed ← waitForCondition s!"the master's move hands over to {p.replica.name}" 420 do
        return (← c.roles).bind (·.1) == some p.replica.name
      if !handed then fails := fails ++ [s!"the master did not move to {p.replica.name} (on the uncordoned worker) within 420 s"]
      for x in ((← opLogs).splitOn "\n").filter (fun x => containsSubstr x "NODE MOVE" || containsSubstr x "HANDOVER") do c.art "cordon-move.txt" x
    finally
      for n in [p.master.node, p.replica.node] do uncordon n
    if !(← waitForCondition "the pair is redundant again" 420 (redundant c none)) then
      fails := fails ++ ["the pair is not redundant after the cordons were removed"]
    return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- the restart count of the pod's flared container -/
private def podRestartCount (c : Ctx) (pod : String) : IO (Option Nat) := do
  match ← kubectl ["get", "pod", pod, "-n", c.cfg.«namespace», "-o", "jsonpath={.status.containerStatuses[0].restartCount}"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- the pod's flared container is ready -/
private def podContainerReady (c : Ctx) (pod : String) : IO Bool := do
  match ← kubectl ["get", "pod", pod, "-n", c.cfg.«namespace», "-o", "jsonpath={.status.containerStatuses[0].ready}"] with
  | .ok o => return o.trim == "true"
  | .error _ => return false

/-- C9 (review of 09ce11a): the quiet check survives a flared restart. The
    replica's worker is cordoned while a client holds a connection to the
    replica (so the move cannot be released); once its serving label is
    removed, flared is restarted in the pod (its request counter starts at 0)
    and one request is sent to the new process. The move must not be released
    until a full quiet interval (10 s) after that request: the restarted
    process's counter, below the old one, starts the window again. -/
def cordonRestartQuietTest (c : Ctx) : IO TestResult := do
  match ← cordonPrecond c with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["C9: minCopies 2; cordon of the replica's worker with a client connection held, flared restarted after the serving label is removed, one request to the new process (no drain)"]
    let ns := c.cfg.«namespace»
    let opLogs := do return (← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000)
    let released := do
      return ((← opLogs).splitOn "\n").any fun l => containsSubstr l s!"NODE MOVE {p.replica.name}@" && containsSubstr l "-> released"
    -- a held client connection keeps curr_connections > 0: never released
    match ← execInDebugPod c.cfg.debugPod ns s!"setsid sh -c 'sleep 900 | nc {p.replica.ip} {c.cfg.flarePort}' >/dev/null 2>&1 < /dev/null &" with
    | .error e => return .fail (notSetUp s!"could not hold a client connection: {e.take 200}")
    | .ok _ => pure ()
    let mut fails : List String := []
    try
      match ← kubectl ["cordon", p.replica.node] with
      | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
      | .ok _ => pure ()
      let unlabeled ← waitForCondition s!"the serving label of {p.replica.name} is removed" 180 do
        return containsSubstr (← opLogs) s!"NODE MOVE {p.replica.name}: serving label removed"
      if !unlabeled then return .fail (notSetUp "the serving label was never removed")
      if ← released then return .fail (notSetUp "the move was released while a client connection was held: the restart case was not exercised")
      let restarts0 := (← podRestartCount c p.replica.name).getD 0
      match ← kubectl ["exec", "-n", ns, p.replica.name, "--", "sh", "-c", "kill -TERM 1"] with
      | .error e => return .fail (notSetUp s!"could not restart flared in {p.replica.name}: {e.take 200}")
      | .ok _ => pure ()
      let back ← waitForCondition s!"flared in {p.replica.name} restarted and answers" 120 do
        let r := (← podRestartCount c p.replica.name).getD 0
        return r > restarts0 && (← podContainerReady c p.replica.name)
      if !back then return .fail (notSetUp "flared did not restart")
      if ← released then
        c.event "released before the request to the new process"
      -- one request to the NEW process, then watch the move every second
      let ok ← memcachedSet c.cfg.debugPod ns p.replica.ip c.cfg.flarePort "c9_after_restart" "v"
      let t0 ← IO.monoMsNow
      c.event s!"request to the restarted flared: stored={ok}"
      let mut releasedAt : Option Nat := none
      for _ in [0:60] do
        if ← released then
          releasedAt := some ((← IO.monoMsNow) - t0)
          break
        IO.sleep 1000
      c.event s!"released {releasedAt.map (s!"{·} ms") |>.getD "not within 60 s"} after the request"
      match releasedAt with
      | some ms => if ms < 8000 then fails := fails ++ [s!"the move was released {ms} ms after a request to the restarted flared (quiet interval 10 s): the old counter baseline hid it"]
      | none => pure ()
      for x in ((← opLogs).splitOn "\n").filter (fun x => containsSubstr x "NODE MOVE") do c.art "cordon-move.txt" x
    finally
      discard <| execInDebugPod c.cfg.debugPod ns "pkill -f 'sleep 900' || true"
      uncordon p.replica.node
    if !(← waitForCondition "the pair is redundant again" 600 (redundant c none)) then
      fails := fails ++ ["the pair is not redundant after the uncordon"]
    return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- C8: the operator is away (scaled to 0): the node guard webhook fails
    closed, so cordon + drain of the replica's worker cannot evict it; the
    replica keeps its pod. The operator comes back and the pair is redundant. -/
def cordonNoOperatorTest (c : Ctx) : IO TestResult := do
  match ← cordonPrecond c with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["C8: the operator scaled to 0, then cordon + drain (90 s) of the replica's worker"]
    let ns := c.cfg.«namespace»
    let (uid0, _) ← podUidServing c p.replica.name
    match ← kubectl ["scale", "deployment", c.cfg.operatorName, "-n", ns, "--replicas=0"] with
    | .error e => return .fail (notSetUp s!"could not scale the operator to 0: {e.take 200}")
    | .ok _ => pure ()
    let mut fails : List String := []
    try
      let gone ← waitForCondition "the operator pods are gone" 120 do
        return (← getPodNames s!"app={c.cfg.operatorName}" ns).isEmpty
      if !gone then return .fail (notSetUp "the operator pods did not go away")
      match ← kubectl ["cordon", p.replica.node] with
      | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
      | .ok _ => pure ()
      let stem ← startDrain p.replica.node 90
      discard <| waitForCondition "the drain ended" 150 (return (← drainResult stem).isSome)
      match ← drainResult stem with
      | some (rc, out) =>
        for l in out.splitOn "\n" do c.art "drain.txt" l
        c.event s!"drain rc={rc}"
        if rc == "0" then fails := fails ++ ["the drain completed with no operator: the eviction was not refused"]
      | none => fails := fails ++ ["the drain did not end within 150 s"]
      let (uid1, _) ← podUidServing c p.replica.name
      if uid1 != uid0 then fails := fails ++ [s!"{p.replica.name} was evicted with no operator ({uid0} -> {uid1})"]
    finally
      discard <| kubectl ["scale", "deployment", c.cfg.operatorName, "-n", ns, "--replicas=1"]
      uncordon p.replica.node
    discard <| kubectlRolloutStatus s!"deployment/{c.cfg.operatorName}" ns 300
    if !(← waitForCondition "the pair is redundant again" 300 (redundant c none)) then
      fails := fails ++ ["the pair is not redundant after the operator came back"]
    return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-! ## C10: a cordon move that goes stuck (risk B13, flare-risk-cordon-stuck) -/

/-- One move of the FlareCluster's `status.nodeMoves` as the harness reads it. -/
private structure MoveRow where
  id : String
  pod : String
  uid : String
  phase : String
  stuck : Bool
  held : Bool
  reason : String
  deriving Repr

private def MoveRow.label (m : MoveRow) : String :=
  s!"{m.id} {m.pod} (uid {m.uid.take 8}) phase {m.phase} stuck {m.stuck} held {m.held}{if m.reason.isEmpty then "" else s!" ({m.reason.take 300})"}"

/-- `status.nodeMoves.moves` of the cluster's CR (`none` = unreadable). -/
private def nodeMoveRows (c : Ctx) : IO (Option (List MoveRow)) := do
  match ← kubectl ["get", "flarecluster", c.cfg.name, "-n", c.cfg.«namespace», "-o",
      "jsonpath={range .status.nodeMoves.moves[*]}{.id}|{.pod}|{.podUid}|{.phase}|{.stuck}|{.held}|{.reason}{\"\\n\"}{end}"] with
  | .error _ => return none
  | .ok out =>
    return some ((out.splitOn "\n").filterMap fun l =>
      match l.splitOn "|" with
      | i :: p :: u :: ph :: s :: h :: rest =>
        if i.trim.isEmpty then none
        else some ({ id := i.trim, pod := p, uid := u, phase := ph, stuck := s == "true", held := h == "true",
                     reason := String.intercalate "|" rest } : MoveRow)
      | _ => none)

/-- The move of `pod` recorded for the incarnation `uid` (the latest one). -/
private def moveOf (rows : List MoveRow) (pod uid : String) : Option MoveRow :=
  (rows.filter fun r => r.pod == pod && r.uid == uid).getLast?

/-- Log `status.nodeMoves` with a timestamp; the rows read (`[]` = unreadable). -/
private def logMoves (c : Ctx) (tag : String) : IO (List MoveRow) := do
  match ← nodeMoveRows c with
  | none => c.event s!"{tag}: status.nodeMoves unreadable"; return []
  | some rs =>
    c.event s!"{tag}: status.nodeMoves = {if rs.isEmpty then "(none)" else String.intercalate " ; " (rs.map MoveRow.label)}"
    return rs

/-- One operator metric (integer part; gauges render as floats), scraped from
    the operator's /metrics through the debug pod; `none` = unreadable. -/
private def operatorMetric (c : Ctx) (name : String) : IO (Option Nat) := do
  let some ip := ((← getPodIps s!"app={c.cfg.operatorName}" c.cfg.«namespace»).filter (!·.trim.isEmpty)).head? | return none
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf 'GET /metrics HTTP/1.0\\r\\nHost: x\\r\\n\\r\\n' | nc -w 3 {ip.trim} 9090" with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun line =>
      let t := line.trim
      if t.startsWith (name ++ "{") || t.startsWith (name ++ " ") then
        ((t.splitOn " ").getLast?.map fun v => ((v.trim.splitOn ".").headD v.trim)).bind String.toNat?
      else none

/-- (type, message) of the namespace's Events with `reason`. -/
private def eventsOf (c : Ctx) (reason : String) : IO (List (String × String)) := do
  match ← kubectl ["get", "events", "-n", c.cfg.«namespace», "--field-selector", s!"reason={reason}", "-o",
      "jsonpath={range .items[*]}{.type}|{.message}{\"\\n\"}{end}"] with
  | .error _ => return []
  | .ok o =>
    return (o.splitOn "\n").filterMap fun l =>
      match l.splitOn "|" with
      | t :: rest => if t.trim.isEmpty then none else some (t.trim, String.intercalate "|" rest)
      | [] => none

/-- A master and TWO active replicas of partition 0, all Ready and not
    deleting, on three different workers, each replica on the master's
    history and read-eligible (as `redundant`): (master, replica A, replica
    B), the replicas by name. -/
private def trio (c : Ctx) : IO (Option (PodRow × PodRow × PodRow)) := do
  let some ps ← c.pods | return none
  let some (some m, rs) ← c.roles | return none
  let v ← c.nodeView
  let activeR := rs.filter fun r => v.any fun e => podOfFqdn e.fqdn == r && e.state == 0
  let some mp := ps.find? (·.name == m) | return none
  let rps := (activeR.filterMap fun r => ps.find? (·.name == r)).toArray.qsort (fun a b => a.name < b.name) |>.toList
  match rps with
  | [a, b] =>
    let all := [mp, a, b]
    if !(all.all fun p => p.ready && !p.deleting && !p.ip.isEmpty) then return none
    if (all.map (·.node)).eraseDups.length != 3 then return none
    let some mo ← c.stats mp.ip | return none
    for r in [a, b] do
      let some ro ← c.stats r.ip | return none
      let sameHistory := (statOf mo "rocksdb_source_epoch").isSome && statOf mo "rocksdb_source_epoch" == statOf ro "rocksdb_source_epoch"
      let eligible := statOf ro "repl_read_source_eligible" == some "1"
        && (statOf ro "repl_read_source_state").all (· == "eligible")
      if !(sameHistory && eligible) then return none
    return some (mp, a, b)
  | _ => return none

/-- C10 (risk B13, flare-risk-cordon-stuck; review): a cordon move goes STUCK
    on the real path and does not stop the next move. Three copies (a master
    and two replicas, one per worker), minCopies 2, the unserved deadline
    shortened to 60 s for this scenario. A client keeps a TCP connection open
    to replica A, and A's worker is cordoned: the move goes proxied ->
    unserved and cannot be released (curr_connections never drops to 0);
    past 60 s it is marked stuck (phase kept, held), with a Warning
    FlareCordonMoveStuck and flare_operator_cordon_moves_stuck >= 1. A drain
    of that worker is refused (429, it retries and times out) and the pod
    keeps its UID; the move is never released. Replica B's worker is then
    cordoned: a NEW move of B starts and completes (B released, recreated on
    its uncordoned worker and served again) while A's stays stuck. Even with
    the connection closed the stuck move is not released; the uncordon
    cancels it, A gets the serving label back on the same pod, and the
    partition has three synced copies again. A write load runs throughout:
    0 errors, 0 acknowledged writes missing. -/
def cordonStuckTest (c : Ctx) : IO TestResult := do
  if !(← operatorSettled c) then
    return .fail (notSetUp "the operator did not finish its startup grace period")
  let found ← IO.mkRef (none : Option (PodRow × PodRow × PodRow))
  discard <| waitForCondition "a master and two synced replicas on three workers" 300 do
    let t ← trio c
    found.set t
    return t.isSome
  let some (m, ra, rb) ← found.get
    | return .fail (notSetUp "the cluster did not start this test with a master and two synced replicas on three workers")
  let ns := c.cfg.«namespace»
  c.conditions ["C10: 1 partition x 3 copies (master + 2 replicas, one per worker), minCopies 2, FLARE_NODE_REPLACEMENT_UNSERVED_TIMEOUT_SECONDS=60 (nodeReplacement.unservedTimeoutSeconds); a client connection held to replica A, A's worker cordoned (move -> unserved -> stuck), drain (90 s) of A's worker, then replica B's worker cordoned (the next move); the connection closed, the uncordons; write load 2 x 50/s via the partition Service + 1 x 50/s via the all-pods Service",
    s!"master {m.name}@{m.node}; replica A (stuck) {ra.name}@{ra.node} uid {ra.uid}; replica B (next move) {rb.name}@{rb.node} uid {rb.uid}"]
  let opLogs : IO String := kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 30000
  let logHas := fun (needles : List String) => do
    return ((← opLogs).splitOn "\n").any fun l => needles.all (containsSubstr l ·)
  match ← c.ensureLoadWriter with
  | .error e => return .fail (notSetUp e)
  | .ok () => pure ()
  let labelled ← waitForCondition "every flared pod carries the serving label" 120 do
    match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={c.cfg.name},flare.gree.net/serving=true", "-o", "jsonpath={.items[*].metadata.name}"] with
    | .ok o => return ((o.trim.splitOn " ").filter (!·.isEmpty)).length == c.cfg.replicas * c.cfg.partitions
    | .error _ => return false
  if !labelled then return .fail (notSetUp "the operator did not label every pod serving")
  if !(← c.startLoad "svc" (svcHost c) 2 50) then return .fail (notSetUp "the client-path load did not start")
  if !(← c.startLoad "peer" s!"{c.cfg.name}-nodes-external.{ns}.svc.cluster.local" 1 50) then
    return .fail (notSetUp "the proxy-path load did not start")
  -- the held client connection: curr_connections of A never drops to 0. It
  -- sends `version` every 5 s: flared closes a client connection idle for
  -- its read timeout (30 s in the k8s build), and an idle one was closed
  -- before the 60 s deadline, so the move was released (41352662024)
  let holdTag := "flare-e2e-hold-3607"
  let closeHold : IO Unit := do
    discard <| execInDebugPod c.cfg.debugPod ns s!"pkill -f '{holdTag}' ; pkill -f 'nc {ra.ip} {c.cfg.flarePort}' ; true"
  match ← execInDebugPod c.cfg.debugPod ns s!"setsid sh -c ': {holdTag}; while :; do printf \"version\\r\\n\"; sleep 5; done | nc {ra.ip} {c.cfg.flarePort}' >/dev/null 2>&1 < /dev/null &" with
  | .error e => return .fail (notSetUp s!"could not hold a client connection: {e.take 200}")
  | .ok _ => pure ()
  IO.sleep 2000
  let conns := fun (ip : String) => do
    return ((← c.stats ip).bind (statOf · "curr_connections")).getD "unreadable"
  c.event s!"client connection held to {ra.name} ({ra.ip}:{c.cfg.flarePort}); its curr_connections = {← conns ra.ip} (this stats read included)"
  let mut fails : List String := []
  try
    -- 1-3. A's move: unserved, then stuck past the 60 s deadline
    match ← kubectl ["cordon", ra.node] with
    | .error e => return .fail (notSetUp s!"cordon failed: {e.take 200}")
    | .ok _ => pure ()
    c.event s!"cordoned {ra.node} ({ra.name}) with the client connection held"
    let unserved ← waitForCondition s!"the move of {ra.name} reaches unserved" 240 do
      return (← nodeMoveRows c).any fun rs => (moveOf rs ra.name ra.uid).any (·.phase == "unserved")
    let tUnserved ← IO.monoMsNow
    discard <| logMoves c "unserved"
    if !unserved then return .fail (notSetUp s!"the move of {ra.name} never reached unserved within 240 s")
    let stuck ← waitForCondition s!"the move of {ra.name} is marked stuck" 240 do
      return (← nodeMoveRows c).any fun rs => (moveOf rs ra.name ra.uid).any (·.stuck)
    let tStuck ← IO.monoMsNow
    let rows ← logMoves c "stuck"
    c.event s!"stuck observed {(tStuck - tUnserved) / 1000} s after unserved was observed (deadline 60 s); {ra.name} curr_connections = {← conns ra.ip}"
    if !stuck then
      for x in ((← opLogs).splitOn "\n").filter (containsSubstr · "NODE MOVE") do c.art "cordon-move.txt" x
      return .fail s!"the move of {ra.name} was not marked stuck within 240 s of reaching unserved (unservedTimeoutSeconds 60)"
    if tStuck - tUnserved < 45000 then
      fails := fails ++ [s!"the move was marked stuck {(tStuck - tUnserved) / 1000} s after unserved: before its 60 s deadline"]
    match moveOf rows ra.name ra.uid with
    | none => fails := fails ++ ["the stuck move is not in status.nodeMoves"]
    | some mv =>
      if mv.phase != "unserved" then fails := fails ++ [s!"the stuck move left unserved (phase {mv.phase})"]
      if !mv.held then fails := fails ++ ["the stuck move is not held"]
      if !containsSubstr mv.reason "STUCK in unserved" then fails := fails ++ [s!"the stuck move's reason is not a STUCK in unserved: {mv.reason.take 200}"]
      if !containsSubstr mv.reason "open connection" then fails := fails ++ [s!"the stuck move's reason does not name the open client connection: {mv.reason.take 200}"]
    if !(← logHas [s!"NODE MOVE {ra.name}@{ra.node}: STUCK in unserved"]) then
      fails := fails ++ ["no STUCK line for the move was logged by the operator"]
    let evOk ← waitForCondition s!"a Warning FlareCordonMoveStuck names {ra.name}" 60 do
      return (← eventsOf c "FlareCordonMoveStuck").any fun (t, msg) => t == "Warning" && containsSubstr msg ra.name
    c.event s!"FlareCordonMoveStuck events: {(← eventsOf c "FlareCordonMoveStuck").map (fun (t, msg) => s!"{t}: {msg.take 300}")}"
    if !evOk then fails := fails ++ [s!"no Warning event FlareCordonMoveStuck names {ra.name}"]
    let gaugeOk ← waitForCondition "flare_operator_cordon_moves_stuck >= 1" 60 do
      return (← operatorMetric c "flare_operator_cordon_moves_stuck").any (· ≥ 1)
    c.event s!"flare_operator_cordon_moves_stuck = {← operatorMetric c "flare_operator_cordon_moves_stuck"}"
    if !gaugeOk then fails := fails ++ ["flare_operator_cordon_moves_stuck did not read >= 1"]
    -- 4. the held pod is never released: a drain of its worker is refused
    -- (429: kubectl retries) and times out; the pod keeps its UID
    let stem ← startDrain ra.node 90
    c.event s!"drain of {ra.node} started (timeout 90 s)"
    discard <| waitForCondition "the drain ended" 150 (return (← drainResult stem).isSome)
    match ← drainResult stem with
    | some (rc, out) =>
      for l in out.splitOn "\n" do c.art "drain.txt" l
      let retries := (out.splitOn "\n").filter fun l => containsSubstr l "will retry" && containsSubstr l ra.name
      c.event s!"drain rc={rc}; {retries.length} eviction(s) of {ra.name} refused for a retry; last: {(retries.getLast?.getD "-").take 300}"
      if rc == "0" then fails := fails ++ ["the drain completed: the stuck move's pod was evicted"]
      if retries.length < 2 then fails := fails ++ [s!"only {retries.length} refused-and-retried eviction(s) of {ra.name} in the drain output (429 expected for its whole length)"]
      if !(retries.any (containsSubstr · "phase unserved")) then fails := fails ++ ["the drain's refusals do not name the move's unserved phase"]
    | none => fails := fails ++ ["the drain did not end within 150 s"]
    let (uidA1, servingA1) ← podUidServing c ra.name
    c.event s!"after the drain: {ra.name} uid {uidA1} serving {servingA1}"
    if uidA1 != ra.uid then fails := fails ++ [s!"{ra.name} was replaced or deleted while its move was stuck ({ra.uid} -> {uidA1})"]
    if servingA1 then fails := fails ++ [s!"{ra.name} carries the serving label while its move is stuck"]
    match moveOf ((← logMoves c "after the drain")) ra.name ra.uid with
    | some mv => if mv.phase != "unserved" || !mv.stuck then fails := fails ++ [s!"after the drain the move is {mv.label}, not stuck in unserved"]
    | none => fails := fails ++ ["the stuck move is gone from status.nodeMoves after the drain"]
    -- 5. the next move starts and completes while A's stays stuck
    match ← kubectl ["cordon", rb.node] with
    | .error e => return .fail (notSetUp s!"cordon of the second worker failed: {e.take 200}")
    | .ok _ => pure ()
    c.event s!"cordoned {rb.node} ({rb.name}) while the move of {ra.name} is stuck"
    let started ← waitForCondition s!"a move of {rb.name} starts" 180 do
      return (← nodeMoveRows c).any fun rs => (moveOf rs rb.name rb.uid).isSome
    discard <| logMoves c "next move"
    if !started then
      fails := fails ++ [s!"no move of {rb.name} started within 180 s while the move of {ra.name} was stuck (the stuck move blocked the next one)"]
    else
      let released ← waitForCondition s!"the move of {rb.name} is released" 300 do
        return (← nodeMoveRows c).any fun rs => (moveOf rs rb.name rb.uid).any fun r => ["released", "deleted", "resyncing", "done"].contains r.phase
      discard <| logMoves c "next move released"
      if !released then fails := fails ++ [s!"the move of {rb.name} did not reach released within 300 s"]
      else
        -- the operator deletes the released pod itself (evictWait 60 s); its
        -- replacement cannot be placed while every other worker holds a
        -- flared pod (required anti-affinity) and its own is cordoned
        let gone ← waitForCondition s!"the old pod of {rb.name} is gone" 300 do
          return (← nodeMoveRows c).any fun rs => (moveOf rs rb.name rb.uid).any fun r => ["deleted", "resyncing", "done"].contains r.phase
        discard <| logMoves c "next move deleted"
        if !gone then fails := fails ++ [s!"the released pod {rb.name} was not deleted within 300 s"]
        uncordon rb.node
        c.event s!"uncordoned {rb.node} so the replacement of {rb.name} can be placed"
        let done ← waitForCondition s!"the move of {rb.name} is done" 600 do
          if ← logHas [s!"NODE MOVE {rb.name}@{rb.node}:", "-> done"] then return true
          return (← nodeMoveRows c).any fun rs => (moveOf rs rb.name rb.uid).any (·.phase == "done")
        discard <| logMoves c "next move done"
        if !done then fails := fails ++ [s!"the move of {rb.name} was not done within 600 s"]
    -- A's move is still stuck, its pod still held
    let (uidA2, servingA2) ← podUidServing c ra.name
    match moveOf ((← logMoves c "stuck move after the next move")) ra.name ra.uid with
    | some mv => if mv.phase != "unserved" || !mv.stuck || !mv.held then fails := fails ++ [s!"after the next move the move of {ra.name} is {mv.label}, not stuck and held in unserved"]
    | none => fails := fails ++ ["the stuck move is gone from status.nodeMoves after the next move"]
    if uidA2 != ra.uid || servingA2 then fails := fails ++ [s!"{ra.name} changed while its move was stuck (uid {uidA2}, serving {servingA2})"]
    let g2 ← operatorMetric c "flare_operator_cordon_moves_stuck"
    c.event s!"flare_operator_cordon_moves_stuck = {g2} after the next move"
    if !(g2.any (· ≥ 1)) then fails := fails ++ [s!"flare_operator_cordon_moves_stuck reads {g2} while the move of {ra.name} is stuck"]
    -- 6. the connection closed: a stuck move is still never released
    closeHold
    c.event s!"client connection to {ra.name} closed; curr_connections = {← conns ra.ip} (this stats read included)"
    IO.sleep 30000
    match moveOf ((← logMoves c "30 s after the connection closed")) ra.name ra.uid with
    | some mv => if mv.phase != "unserved" || !mv.stuck then fails := fails ++ [s!"after the connection closed the stuck move became {mv.label}: a stuck move must never be released"]
    | none => fails := fails ++ ["the stuck move is gone from status.nodeMoves after the connection closed"]
    if ← logHas [s!"NODE MOVE {ra.name}@{ra.node}:", "-> released"] then
      fails := fails ++ [s!"the stuck move of {ra.name} was released"]
    -- the uncordon cancels the stuck unserved move; A serves again, same pod
    uncordon ra.node
    c.event s!"uncordoned {ra.node}"
    let cancelled ← waitForCondition s!"the stuck move of {ra.name} is cancelled" 180 do
      return (← nodeMoveRows c).any fun rs => (moveOf rs ra.name ra.uid).any (·.phase == "cancelled")
    discard <| logMoves c "after the uncordon"
    if !cancelled then fails := fails ++ ["the uncordon did not cancel the stuck move"]
    let back ← waitForCondition s!"{ra.name} serves again" 180 do
      return (← podUidServing c ra.name).2
    let (uidA3, _) ← podUidServing c ra.name
    c.event s!"{ra.name} serving label back={back}, uid {uidA3}"
    if !back then fails := fails ++ [s!"{ra.name} did not get the serving label back after the cancel"]
    if uidA3 != ra.uid then fails := fails ++ [s!"{ra.name} was replaced ({ra.uid} -> {uidA3}) although its move was cancelled"]
    let g0 ← waitForCondition "flare_operator_cordon_moves_stuck is 0" 120 do
      return (← operatorMetric c "flare_operator_cordon_moves_stuck") == some 0
    if !g0 then fails := fails ++ [s!"flare_operator_cordon_moves_stuck reads {← operatorMetric c "flare_operator_cordon_moves_stuck"} after the stuck move was cancelled"]
  finally
    closeHold
    uncordon ra.node
    uncordon rb.node
  for x in ((← opLogs).splitOn "\n").filter (fun x => containsSubstr x "NODE MOVE" || containsSubstr x "NODE GUARD" || containsSubstr x "serving label") do c.art "cordon-move.txt" x
  if !(← waitForCondition "a master and two synced replicas again" 600 (return (← trio c).isSome)) then
    fails := fails ++ ["the partition does not have a master and two synced replicas again"]
  -- the write load: 0 errors, no acknowledged write missing
  let svc? ← c.stopLoad "svc" 2
  let peer? ← c.stopLoad "peer" 1
  match svc?, peer? with
  | some svcRes, some peerRes =>
    let ss := loadStats svcRes
    let ps := loadStats peerRes
    c.art "report.txt" (ss.summary "svc")
    c.art "report.txt" (ps.summary "peer")
    c.event (ss.summary "svc")
    c.event (ps.summary "peer")
    if ss.errors + ps.errors > 0 then fails := fails ++ [s!"{ss.errors} + {ps.errors} write errors (svc + peer)"]
    let acks : List WriteRec := ((svcRes.recs ++ peerRes.recs).filter (fun (r : LoadRec) => r.ack)).map (fun (r : LoadRec) => r.toWrite)
    let master := (← c.roles).bind (·.1)
    let copies ← finalCopies c "settled"
    let mut late : List String := []
    for (pod, cp) in copies do
      match cp with
      | none => fails := fails ++ [unobservable s!"the copy of {pod} could not be read"]
      | some d =>
        let n ← recordMissing c pod acks d
        c.event s!"{pod}{if master == some pod then " (master)" else ""}: {n} of {acks.length} acknowledged writes missing"
        if n > 0 then
          if master == some pod then fails := fails ++ [s!"{n} acknowledged writes missing on the master {pod}"]
          else late := late ++ [pod]
    -- a replica gap that a repair fills is delayed, not lost: read it again after 120 s
    if !late.isEmpty then
      IO.sleep 120000
      let copies2 ← finalCopies c "later"
      for pod in late do
        match (copies2.lookup pod).join with
        | none => fails := fails ++ [unobservable s!"the copy of {pod} could not be read 120 s later"]
        | some d =>
          let n ← recordMissing c s!"{pod}-later" acks d
          c.event s!"{pod} 120 s later: {n} acknowledged writes missing"
          if n > 0 then fails := fails ++ [s!"{n} acknowledged writes missing on the replica {pod} 120 s after it settled"]
  | _, _ => fails := fails ++ [unobservable "a load log could not be read or failed its integrity check (never counted as 'no error')"]
  IO.eprintln s!"# [{c.test}] cordon stuck: {if fails.isEmpty then "every check held" else String.intercalate "; " fails}"
  return if fails.isEmpty then .pass else .fail (String.intercalate "; " fails)

/-- One scenario per suite, each on a FRESH cluster: a scenario that leaves the
    pair broken (e.g. a replica on an older history after S3) no longer makes
    the next one fail on its precondition, and each leg stays well inside the
    job's time limit (runs 40363315500 / 40422801175 were cancelled at 120 min
    with all scenarios in one leg). -/
inductive Scenario where
  | op (o : SwitchOp)
  | gate
  | sigtermHold
  | abortExhaust
  | nodeGuard
  | cordonBlocked
  | cordonCancel
  | cordonNoSuccessor
  | cordonOperatorRestart
  | cordonTwoNodes
  | cordonNoOperator
  | cordonRestartQuiet
  | cordonStuck
  /-- the replica's data is on a node-local PV (kind's local-path) -/
  | cordonPinned
  deriving BEq

def Scenario.slug : Scenario → String
  | .op .deleteMaster => "delete"
  | .op .rollingRestart => "rolling"
  | .op .rollBoth => "rollboth"
  | .op .drainMaster => "drain"
  | .op .deleteMasterSaveFail => "savefail"
  | .op .deleteMasterAbortRetry => "abortretry"
  | .op .deleteMasterLeaseTakeover => "leasetakeover"
  | .op .deleteMasterObserveFail => "observefail"
  | .op .helmUpgrade => "helm-upgrade"
  | .op .cordonMaster => "cordon-master"
  | .op .cordonReplica => "cordon-replica"
  | .gate => "gate"
  | .sigtermHold => "sigterm-hold"
  | .abortExhaust => "abortexhaust"
  | .nodeGuard => "node-guard"
  | .cordonBlocked => "cordon-blocked"
  | .cordonCancel => "cordon-cancel"
  | .cordonNoSuccessor => "cordon-no-successor"
  | .cordonOperatorRestart => "cordon-operator-restart"
  | .cordonTwoNodes => "cordon-two-nodes"
  | .cordonNoOperator => "cordon-no-operator"
  | .cordonRestartQuiet => "cordon-restart-quiet"
  | .cordonStuck => "cordon-stuck"
  | .cordonPinned => "cordon-pinned"

def Scenario.title : Scenario → String
  | .op .deleteMaster => "(S1) kubectl delete pod of the MASTER under a client-like load: the pod is replaced; 0 write errors, 0 acknowledged writes missing on the final master and replica"
  | .op .rollingRestart => "(S2) rolling restart of the StatefulSet under a client-like load: every pod is replaced; 0 write errors, 0 missing"
  | .op .rollBoth => "(S3) operator Deployment + StatefulSet rollout restart together (helm-upgrade-like, not a helm upgrade) under a client-like load: 0 write errors, 0 missing"
  | .op .drainMaster => "(S4) kubectl drain of the MASTER's worker (no eviction guard) under a client-like load: the drain completes and no flared pod is left there; 0 write errors, 0 missing"
  | .op .deleteMasterAbortRetry => "(S8) kubectl delete pod of the MASTER while it is cut from its successor, under a client-like load: the first handover aborts and rolls back, the cut is removed, the retry (attempt 2) completes; the one-map drain never takes the master; 0 write errors, 0 missing"
  | .op .deleteMasterSaveFail => "(S7) kubectl delete pod of the MASTER while the operator cannot save its handover ledger, then an operator restart, under a client-like load: no handover map before its phase is saved; the new operator completes the switch; 0 write errors, 0 missing"
  | .op .deleteMasterObserveFail => "(S11) kubectl delete pod of the MASTER while the operator's handover step cannot read the pods (the FSM can), under a client-like load: the one-map drain does not take the master and nothing is promoted while it lasts; once readable, the ordered handover completes the switch; 0 write errors, 0 missing"
  | .op .helmUpgrade => "(H1) REAL helm upgrade of a release installed from the chart with the StatefulSet's RollingUpdate (an older release) to this chart (OnDelete) with a pod template change, under a client-like load: the StatefulSet controller replaces no pod; the operator replaces every pod one at a time, the master after its ordered handover; 0 write errors, 0 missing"
  | .op .deleteMasterLeaseTakeover => "(S10) kubectl delete pod of the MASTER while it is cut from its successor, and the operator's lease taken by another identity mid-handover, under a client-like load: the old leader stops the pass (no FSM step, rolling or send) and exits; the next leader finishes the handover from its ledger; 0 acknowledged writes missing (write errors reported: the operator is away longer than the clients' wait, approved category (a))"
  | .op .cordonMaster => "(C1) kubectl cordon + drain of the MASTER's worker with the node guard and the cordon move under a client-like load: the master is handed over, the pod leaves the clients' Service, the drain's evictions are held until the move releases it, the pod is recreated on another worker; 0 write errors, 0 missing"
  | .op .cordonReplica => "(C2) kubectl cordon + drain of the REPLICA's worker with the node guard and the cordon move under a client-like load: the replica is demoted to a proxy, leaves the clients' Service, its eviction is held until released, and is recreated and resynced on another worker; 0 write errors, 0 missing"
  | .gate => "(S5) the old master is cut from the replica and deleted under a write load: preStop / flared report the drain as NOT lossless, never as lossless (gate test)"
  | .nodeGuard => "(G1) node guard webhook: a force delete of the master and a scale-down over a data-holding ordinal are refused; the delete-override annotation is allowed; a graceful delete of the master is refused until the ordered handover has moved it, then allowed"
  | .abortExhaust => "(S9) the master stays cut from its successor and is deleted: attempts 2 and 3 start, and only after the third abort does the one-map drain take the master (orchestration test, not a data verdict)"
  | .cordonBlocked => "(C3) cordon + drain of the replica's worker with fewer copies than minCopies (2 vs 3): no move starts, the evictions are held (the drain times out), the replica keeps its pod, role and serving label, a FlareCordonMoveBlocked event names it; the pair is redundant after the uncordon"
  | .cordonNoSuccessor => "(C5) cordon + drain of the master's worker while its successor cannot catch up (master <-> replica cut): the handover aborts and never completes, the master stays on the same pod, the evictions are held (the drain times out); redundant again after the cut and the cordon are removed"
  | .cordonOperatorRestart => "(C6) the operator restarts in the middle of a move (replica's worker cordoned, move proxied): the new operator resumes the recorded move (no second move of the pod), a drain then completes and the pod is recreated on another worker; redundant again"
  | .cordonTwoNodes => "(C7) the master's and the replica's workers cordoned together (two copies, minCopies 2): a copy on the other cordoned node counts, so the replica moves first (warning FlareCordonMoveOnCordonedCopy) onto the free worker, then the master hands over to it; redundant again after the cordons are removed"
  | .cordonRestartQuiet => "(C9) flared restarts after the serving label is removed (a client connection held, so not yet released) and gets one request: the move is not released until a full quiet interval after it"
  | .cordonNoOperator => "(C8) the operator is away (scaled to 0): the node guard fails closed, cordon + drain of the replica's worker evicts nothing (the drain fails), the replica keeps its pod; redundant after the operator returns"
  | .cordonStuck => "(C10) a cordon move goes STUCK: a client keeps a connection to replica A, A's worker is cordoned, the move stays unserved and past the 60 s unserved deadline is marked stuck (held, Warning FlareCordonMoveStuck, flare_operator_cordon_moves_stuck >= 1); a drain of A's worker is refused (429) and A keeps its pod; a NEW move of replica B (its worker cordoned next) runs to done meanwhile; the closed connection does not release the stuck move, the uncordon cancels it and A serves again on the same pod; 0 write errors, 0 missing"
  | .cordonPinned => "(C11) PVC on a node-local volume (local-path): cordon + drain (90 s) of the replica's worker never starts a move — the recreated pod could not leave the node; the drain's evictions are held, the replica keeps its pod and serving label, FlareCordonMoveBlocked says its data cannot leave the node; uncordon ends it"
  | .cordonCancel => "(C4) cordon of the replica's worker, uncordon once its move is proxied: the move is cancelled, the replica gets the serving label back on the same pod and is a synced replica again"
  | .sigtermHold => "(S6) a sync client write held on a cut replica across a SIGTERM (cut removed 40 s after it): the client gets STORED and the replica holds the value"

/-- Where a scenario's flared data lives. -/
inductive SwitchStorage where
  /-- memory-backed emptyDir: gone with the pod -/
  | tmpfs
  /-- a PVC on kind's default class (local-path: node-local, pinned) -/
  | pvcLocal
  /-- a PVC on network storage (the `flare-nfs` class the node-ops-cordon-pvc
      leg installs): the volume follows the pod to another node -/
  | pvcNfs
  deriving BEq

/-- The network StorageClass the node-ops-cordon-pvc leg installs. -/
def nfsStorageClass : String := "flare-nfs"

private def pinnedCond : String :=
  "C11: a PVC on a node-local volume (local-path), minCopies 2 on a 2-copy pair; cordon + drain (90 s) of the replica's worker"

private def scenarioSuite (sc : Scenario) (st : SwitchStorage) : TestSuite :=
  let tmpfs := st == .tmpfs
  let (short, suite) := match st with
    | .tmpfs => (s!"swt-{sc.slug}", s!"node-ops-switch-tmpfs-{sc.slug}")
    | .pvcLocal => (s!"sw-{sc.slug}", s!"node-ops-switch-{sc.slug}")
    | .pvcNfs => (s!"swn-{sc.slug}", s!"node-ops-switch-nfs-{sc.slug}")
  let cfgS := cfgOf s!"node-{short}" tmpfs (!tmpfs)
  let cfg0 := if st == .pvcNfs then { cfgS with storageClass := some nfsStorageClass } else cfgS
  -- S7: the save-failure seam, and a preStop window that outlasts the
  -- operator's restart (its startup is not what S7 measures)
  let cfg := if sc == .op .deleteMasterObserveFail then
      { cfg0 with operatorEnv := [("FLARE_TEST_HANDOVER_PODS_FAIL_FILE", podsFailFile)], drainSeconds := 120 }
    else if sc == .op .deleteMasterSaveFail then
      { cfg0 with operatorEnv := [("FLARE_TEST_HANDOVER_SAVE_FAIL_FILE", saveFailFile)], drainSeconds := 180 }
    -- S9: three attempts (Th + rollback + retry delay each) outlast 60 s
    else if sc == .abortExhaust || sc == .op .deleteMasterLeaseTakeover then { cfg0 with drainSeconds := 180 }
    else if sc == .nodeGuard then { cfg0 with nodeGuard := true }
    -- H1: the chart's own release (unique operator name: the chart names
    -- its ClusterRole and binding after it), node guard on as in production
    else if sc == .op .helmUpgrade then
      { cfg0 with operatorName := s!"flare-operator-{short}", nodeGuard := true }
    -- C1/C2: two copies, so minCopies 2 (the accepted risk of a 2-copy pair)
    else if sc == .op .cordonMaster || sc == .op .cordonReplica then
      { cfg0 with nodeGuard := true, nodeReplacement := true, nodeReplacementMinCopies := 2 }
    else if sc == .cordonNoSuccessor || sc == .cordonOperatorRestart || sc == .cordonTwoNodes || sc == .cordonNoOperator || sc == .cordonRestartQuiet then
      { cfg0 with nodeGuard := true, nodeReplacement := true, nodeReplacementMinCopies := 2 }
    else if sc == .cordonCancel then
      { cfg0 with nodeGuard := true, nodeReplacement := true, nodeReplacementMinCopies := 2 }
    -- C10: three copies, so a second move is legal (minCopies 2) while the
    -- first is stuck; the unserved deadline shortened from 1800 s to 60 s
    else if sc == .cordonStuck then
      { cfg0 with replicas := 3, nodeGuard := true, nodeReplacement := true, nodeReplacementMinCopies := 2,
                  operatorEnv := [("FLARE_NODE_REPLACEMENT_UNSERVED_TIMEOUT_SECONDS", "60")] }
    else if sc == .cordonBlocked then
      { cfg0 with nodeGuard := true, nodeReplacement := true, nodeReplacementMinCopies := 3 }
    -- C11: minCopies 2 met, so only the pinned volume blocks the move
    else if sc == .cordonPinned then
      { cfg0 with nodeGuard := true, nodeReplacement := true, nodeReplacementMinCopies := 2 }
    else cfg0
  let c : Ctx := { cfg, suite, test := s!"s-{sc.slug}" }
  { name := suite
    setup := do
      if sc == .op .helmUpgrade then deployHelmCluster cfg (← helmChartRollingUpdate cfg)
      else deployCluster cfg
      IO.sleep 50000
    teardown := do
      if sc == .op .helmUpgrade then cleanupHelmCluster cfg
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [{ name := sc.title, run := match sc with | .op o => switchTest c o | .gate => gateTest c | .sigtermHold => sigtermHoldTest c | .abortExhaust => abortExhaustTest c | .nodeGuard => nodeGuardTest c | .cordonBlocked => cordonBlockedTest c | .cordonCancel => cordonCancelTest c | .cordonNoSuccessor => cordonNoSuccessorTest c | .cordonOperatorRestart => cordonOperatorRestartTest c | .cordonTwoNodes => cordonTwoNodesTest c | .cordonNoOperator => cordonNoOperatorTest c | .cordonRestartQuiet => cordonRestartQuietTest c | .cordonStuck => cordonStuckTest c | .cordonPinned => cordonBlockedTest c pinnedCond (some "cannot leave the node") }] }

def scenarios : List Scenario := [.op .deleteMaster, .op .rollingRestart, .op .rollBoth, .op .drainMaster, .gate, .sigtermHold, .op .deleteMasterSaveFail, .op .deleteMasterAbortRetry, .abortExhaust, .nodeGuard, .op .deleteMasterLeaseTakeover, .op .deleteMasterObserveFail, .op .helmUpgrade]

/-- node-ops-switch-<scenario> (PVC on local-path), node-ops-switch-tmpfs-<scenario>,
    and the cordon move on network storage, node-ops-switch-nfs-<scenario>. -/
def switchSuites : List TestSuite :=
  scenarios.map (fun sc => scenarioSuite sc .pvcLocal) ++ scenarios.map (fun sc => scenarioSuite sc .tmpfs)
    -- the cordon move needs storage that can leave its node: tmpfs, or a PVC
    -- on network storage; on a node-local PV it is not started (C11)
    ++ [Scenario.op .cordonMaster, .op .cordonReplica, .cordonBlocked, .cordonCancel, .cordonNoSuccessor, .cordonOperatorRestart, .cordonTwoNodes, .cordonNoOperator, .cordonRestartQuiet, .cordonStuck].map (fun sc => scenarioSuite sc .tmpfs)
    ++ [Scenario.op .cordonMaster, .op .cordonReplica].map (fun sc => scenarioSuite sc .pvcNfs)
    ++ [scenarioSuite .cordonPinned .pvcLocal]

end FlareOperator.E2E.Tests.NodeOpsSwitch
