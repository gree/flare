/-
  E2E/Tests/NodeOpsSwitch.lean — planned master switches under a client-like
  write load (NODE-OPS-NOSTOP-IMPLEMENTATION-PLAN-2026-10-26, stage 1.5;
  issue flare-lossless-switch-paths).

  Target of every planned switch: NO write error the client sees (server
  error, timeout, connection error) and NO acknowledged write missing on the
  final master or the replica; a delay is allowed and is measured.

  Load: 4 kept-open connections through the partition Service (the client
  path) and 2 to the other pod (the proxy path), 200 requests/s each, closed
  loop (one request per connection at a time) — the rate actually achieved
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
    pods Ready and not deleting, on different workers, none on `avoid`. -/
private def redundant (c : Ctx) (avoid : Option String) : IO Bool := do
  let some ps ← c.pods | return false
  let some (some m, rs) ← c.roles | return false
  let v ← c.nodeView
  let activeR := rs.filter fun r => v.any fun e => podOfFqdn e.fqdn == r && e.state == 0
  match ps.find? (·.name == m), activeR.head? with
  | some mp, some r =>
    match ps.find? (·.name == r) with
    | some rp => return mp.ready && rp.ready && !mp.deleting && !rp.deleting && mp.node != rp.node
                  && some mp.node != avoid && some rp.node != avoid
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
      own := own ++ [s!"{p.name}@{p.node}(uid {p.uid.take 8},ready {p.ready},deleting {p.deleting}):own_role={g "own_role"},own_partition={g "own_partition"},map={g "node_map_version"},items={g "curr_items"},recon={g "reconstruction_started"}/{g "reconstruction_completed"}"]
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
  deriving BEq, Repr

def SwitchOp.label : SwitchOp → String
  | .deleteMaster => "kubectl delete pod (master)"
  | .rollingRestart => "kubectl rollout restart statefulset"
  | .rollBoth => "operator Deployment + StatefulSet rollout restart together (helm-upgrade-like, not a helm upgrade)"
  | .drainMaster => "kubectl drain of the master's worker"

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

/-- The target: the operation happened, 0 errors on both loads, 0
    acknowledged writes missing on the final master and on the replica
    (after the 120 s settle), redundancy back. -/
def switchVerdict (o : SwitchObs) : Option String :=
  if !o.opOk then some (notSetUp s!"the operation did not complete: {o.opDetail}")
  else if !o.moved then some (notSetUp s!"no pod moved: {o.movedDetail}")
  else match o.missingMaster, o.missingReplicaLater with
  | none, _ => some (unobservable "the final master's copy could not be read")
  | _, none => some (unobservable "the replica's copy could not be read")
  | some mm, some mr =>
    let errs := o.svc.errors + o.peer.errors
    if mm != 0 || mr != 0 then some s!"DATA: {mm} acknowledged write(s) missing on the final master, {mr} on the replica 120 s after the switch settled ({o.missingReplica} when it settled; see missing.txt); {errs} write error(s)"
    else if errs != 0 then some s!"WRITE ERRORS: {o.svc.errors} on the client path {o.svc.errorKinds} by pod {o.svcByPod}, {o.peer.errors} on the proxy path {o.peer.errorKinds} by pod {o.peerByPod} (a planned switch must only delay)"
    else if !o.redundant then some "redundancy (master + active replica) was not restored within the bound"
    else none

private def switchRun (c : Ctx) (op : SwitchOp) : IO (Except String SwitchObs) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    c.conditions [s!"scenario: {op.label} under a client-like load (4 x 200/s via the partition Service, 2 x 200/s via the other pod; kept-open connections, closed loop)"]
    match ← c.ensureLoadWriter with
    | .error e => return .error (notSetUp e)
    | .ok () => pure ()
    if !(← c.startLoad "svc" (svcHost c) 4 200) then return .error (notSetUp "the client-path load did not start")
    if !(← c.startLoad "peer" (podHost c p.replica.name) 2 200) then return .error (notSetUp "the proxy-path load did not start")
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
    let (ips1, red) ← observe c 600 (redundant c drained)
    c.event s!"redundancy restored={red}"
    -- did pods move
    let after := (← c.pods).getD []
    let uidChanged := fun (n : String) => match before.find? (·.name == n), after.find? (·.name == n) with
      | some b, some a => b.uid != a.uid
      | some _, none => true
      | _, _ => false
    let (moved, movedDetail) := match op with
      | .deleteMaster => (uidChanged p.master.name, s!"master pod {p.master.name} replaced={uidChanged p.master.name}")
      | .rollingRestart | .rollBoth =>
        let all := before.all fun (b : PodRow) => uidChanged b.name
        (all, s!"every pod replaced={all} ({before.map fun (b : PodRow) => (b.name, uidChanged b.name)})")
      | .drainMaster =>
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
                           redundant := red, newMaster := newM }
    c.art "report.txt" (o.svc.summary "svc")
    c.art "report.txt" (o.peer.summary "peer")
    return .ok o

def switchTest (c : Ctx) (op : SwitchOp) : IO TestResult := do
  match ← switchRun c op with
  | .error e => return .fail e
  | .ok o =>
    IO.eprintln s!"# [{c.test}] {op.label}: operation ok={o.opOk} ({o.opDetail}); moved={o.moved} ({o.movedDetail}); master -> {o.newMaster}; redundancy={o.redundant}; missing on master {o.missingMaster}, on replica {o.missingReplica} when settled and {o.missingReplicaLater} 120 s later; {o.svc.summary "svc"}; errors by pod {o.svcByPod}; {o.peer.summary "peer"}; errors by pod {o.peerByPod}"
    match switchVerdict o with
    | some why => return .fail why
    | none => return .pass

private def switchTests (cfg : ClusterConfig) (suite : String) : List TestCase := [
  { name := "(S1) kubectl delete pod of the MASTER under a client-like load: the pod is replaced; 0 write errors, 0 acknowledged writes missing on the final master and replica"
    run := switchTest { cfg, suite, test := "s-delete" } .deleteMaster },
  { name := "(S2) rolling restart of the StatefulSet under a client-like load: every pod is replaced; 0 write errors, 0 missing"
    run := switchTest { cfg, suite, test := "s-rolling" } .rollingRestart },
  { name := "(S3) operator Deployment + StatefulSet rollout restart together (helm-upgrade-like, not a helm upgrade) under a client-like load: 0 write errors, 0 missing"
    run := switchTest { cfg, suite, test := "s-rollboth" } .rollBoth },
  { name := "(S4) kubectl drain of the MASTER's worker (no eviction guard) under a client-like load: the drain completes and no flared pod is left there; 0 write errors, 0 missing"
    run := switchTest { cfg, suite, test := "s-drain" } .drainMaster }
]

private def switchSuiteOf (name suite : String) (tmpfs pvc : Bool) : TestSuite :=
  let cfg := cfgOf name tmpfs pvc
  { name := suite
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := switchTests cfg suite }

def switchSuite : TestSuite := switchSuiteOf "node-sw" "node-ops-switch" false true
def switchTmpfsSuite : TestSuite := switchSuiteOf "node-swt" "node-ops-switch-tmpfs" true false

end FlareOperator.E2E.Tests.NodeOpsSwitch
