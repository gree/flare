/-
  E2E/Tests/NodeOps.lean — node operations on a multi-node kind cluster
  (docs/design-node-operations-2026-10-19.md). Each test asserts the TARGET
  guarantee of the design's acceptance table; on code without the planned
  controls it FAILS, and that failure is the recorded reproduction of the
  gap (current behaviour, measured). Precondition / unobservable outcomes
  are reported as such, never as a verdict.

  Suites (each runs alone: `flare_e2e --filter node-ops-drain`):
    node-ops-drain      A  : `kubectl drain` of the master's worker, then of
                             the replica's worker, under continuous writes
    node-ops-hold       D  : drain while the replica is cut off (behind)
    node-ops-stop       B  : the master's worker stops (PVC: returns with its
                             data; tmpfs: the copy is gone)
    node-ops-partition  C  : master <-> replica and control paths cut while
                             the client reaches both sides
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.NodeOps

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl

private def followFlags : String :=
  "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000"

/-- 1 partition x 2 replicas, rocksdb, prod-like drain window and PDB, one
    flared pod per data worker. -/
private def cfgOf (name : String) (tmpfs pvc : Bool) : ClusterConfig :=
  { name := name, «namespace» := s!"flare-{name}", partitions := 1, replicas := 2,
    debugPod := s!"debug-{name}", storageBackend := "rocksdb", useTmpfs := tmpfs, usePvc := pvc,
    drainSeconds := 60, pdbMaxUnavailable := some 1, multiNode := true, extraFlaredConf := followFlags }

abbrev Sample := Nat × Option String × List (String × String)

/-- Sample every ~2 s until `done` or `secs` elapse. -/
private partial def observe (c : Ctx) (secs : Nat) (done : IO Bool) : IO (List Sample × Bool) := do
  let deadline := (← nowSec) + secs
  let mut acc : List Sample := []
  repeat
    acc := acc ++ [← c.sample]
    if ← done then return (acc, true)
    if (← nowSec) ≥ deadline then return (acc, false)
    IO.sleep 2000
  return (acc, false)

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

/-- Seed keys through the master and wait until the replica holds them. -/
private def seed (c : Ctx) (p : Placement) (pfx : String) : IO (Except String Unit) := do
  let n ← writeKeys c.cfg.debugPod c.cfg.«namespace» p.master.ip c.cfg.flarePort pfx 50
  if n != 50 then return .error (notSetUp s!"seed: {n}/50 acknowledged")
  let ok ← waitForCondition "the replica holds the seed" 120 do
    match ← c.ownCopy p.replica.ip with
    | some d => return (List.range 50).all fun i => d.lookup s!"{pfx}_{i}" == some s!"val_{i}"
    | none => return false
  if ok then return .ok () else return .error (notSetUp "the replica did not converge on the seed")

private def svcHost (c : Ctx) : String := s!"{c.cfg.name}-0.{c.cfg.«namespace»}.svc.cluster.local"
private def podHost (c : Ctx) (pod : String) : String := s!"{pod}.{c.cfg.name}-nodes.{c.cfg.«namespace»}.svc.cluster.local"

/-- Final copies: (pod, own copy) for every pod of the cluster; a copy that
    cannot be read is `none` (UNOBSERVABLE), never empty. Recorded. -/
private def finalCopies (c : Ctx) : IO (List (String × Option (List (String × String)))) := do
  let ps := (← c.pods).getD []
  let mut out := []
  for p in ps do
    let cp ← if p.ip.isEmpty then pure none else c.ownCopy p.ip
    c.art "copies.txt" s!"{p.name}@{p.node} {match cp with | some d => s!"{d.length} keys" | none => "UNREADABLE"}"
    out := out ++ [(p.name, cp)]
  return out

/-- Acknowledged writes missing from a copy, recorded per copy and writer. -/
private def recordMissing (c : Ctx) (who : String) (ws : List WriteRec) (copy : List (String × String)) : IO Nat := do
  let miss := missingAcks ws copy
  for w in miss do c.art "missing.txt" s!"{who} {w.key}={w.value} acked t={w.t} via {w.ip} -> {(copy.lookup w.key).getD "(absent)"}"
  return miss.length

/-! ## A: planned eviction (drain) -/

structure DrainObs where
  drainRc : String
  drainOut : String
  oldMaster : String
  newMaster : Option String
  redundantAfter : Bool
  recoverySec : Nat
  writes : List WriteRec
  missingMaster : Option Nat
  missingReplica : Option Nat
  summary : String

/-- The target of A (design §1): the drain completes, every acknowledged
    write is on the final master AND on the rebuilt replica, redundancy is
    back on workers other than the drained one. -/
def drainVerdict (o : DrainObs) (expectSameMaster : Bool) : Option String :=
  if o.drainRc != "0" then some s!"the drain did not complete (rc {o.drainRc}): {o.drainOut.take 600}"
  else if !o.redundantAfter then some "redundancy (master + active replica on two other workers) was not restored within the bound"
  else match o.missingMaster, o.missingReplica with
    | none, _ => some (unobservable "the final master's copy could not be read")
    | _, none => some (unobservable "the rebuilt replica's copy could not be read")
    | some mm, some mr =>
      if mm != 0 then some s!"DATA: {mm} acknowledged write(s) missing on the final master {o.newMaster} (see missing.txt)"
      else if mr != 0 then some s!"DATA: {mr} acknowledged write(s) missing on the rebuilt replica (see missing.txt)"
      else if expectSameMaster && o.newMaster != some o.oldMaster then some s!"the master moved ({o.oldMaster} -> {o.newMaster}) on a replica drain"
      else none

/-- Drain `which` worker (the master's or the replica's) under two writers:
    through the partition Service (client path) and to the other pod (proxy
    path). -/
private def drainRun (c : Ctx) (drainMaster : Bool) : IO (Except String DrainObs) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    c.conditions [s!"scenario A drain {if drainMaster then "MASTER" else "REPLICA"} worker",
      "eviction path: kubectl drain --ignore-daemonsets --delete-emptydir-data (Eviction API, PDB honoured; no --disable-eviction, no --force)"]
    match ← seed c p s!"seed{c.test}" with
    | .error e => return .error e
    | .ok () => pure ()
    let target := if drainMaster then p.master else p.replica
    let other := if drainMaster then p.replica else p.master
    if !(← c.startWriter "svc" (svcHost c) "ws") then return .error (notSetUp "writer svc did not start")
    if !(← c.startWriter "peer" (podHost c other.name) "wp") then return .error (notSetUp "writer peer did not start")
    let (s0, _) ← observe c 10 (pure false)
    c.event s!"drain of {target.node} ({target.name}) starts"
    let t0 ← nowSec
    let stem ← startDrain target.node 600
    let (s1, done) ← observe c 660 (return (← drainResult stem).isSome)
    let (rc, out) := (← drainResult stem).getD ("timeout", "")
    for l in out.splitOn "\n" do c.art "drain.txt" l
    c.event s!"drain finished rc={rc} (completed={done})"
    let (s2, red) ← observe c 420 (redundant c (some target.node))
    let rec_ := (← nowSec) - t0
    c.event s!"redundancy restored={red} after {rec_} s from the drain start"
    let (s3, _) ← observe c 10 (pure false)
    let ws1 := (← c.stopWriter "svc").getD []
    let ws2 := (← c.stopWriter "peer").getD []
    uncordon target.node
    let samples := s0 ++ s1 ++ s2 ++ s3
    let roles ← c.roles
    let newM := roles.bind (·.1)
    let ps := (← c.pods).getD []
    let copies ← finalCopies c
    let copyOf := fun (pod : Option String) => pod.bind fun n => (copies.lookup n).join
    let replicaPod := ps.find? (fun r => some r.name != newM) |>.map (·.name)
    let ws := ws1 ++ ws2
    let mm ← match copyOf newM with | some d => pure (some (← recordMissing c "master" ws d)) | none => pure none
    let mr ← match copyOf replicaPod with | some d => pure (some (← recordMissing c "replica" ws d)) | none => pure none
    let summary := s!"{writerSummary "svc" samples ws1}; {writerSummary "peer" samples ws2}"
    c.art "report.txt" summary
    return .ok { drainRc := rc, drainOut := out, oldMaster := p.master.name, newMaster := newM, redundantAfter := red,
                 recoverySec := rec_, writes := ws, missingMaster := mm, missingReplica := mr, summary }

private def drainTest (c : Ctx) (drainMaster : Bool) : IO TestResult := do
  match ← drainRun c drainMaster with
  | .error e => return .fail e
  | .ok o =>
    IO.eprintln s!"# [{c.test}] drain rc={o.drainRc}; master {o.oldMaster} -> {o.newMaster}; redundancy={o.redundantAfter} after {o.recoverySec} s; missing on master {o.missingMaster}, on replica {o.missingReplica}; {o.summary}"
    match drainVerdict o (!drainMaster) with
    | some why => return .fail why
    | none => return .pass

def drainSuite : TestSuite :=
  let cfg := cfgOf "node-drain" true false
  { name := "node-ops-drain"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(A) standard kubectl drain of the MASTER's worker under continuous writes (service + proxy paths): the drain completes through the Eviction API with the PDB honoured; every acknowledged write is on the new master and on the replica rebuilt on another worker; redundancy is restored on workers other than the drained one (reply classes, error window and recovery time recorded)"
        run := drainTest { cfg, suite := "node-ops-drain", test := "a-master" } true },
      { name := "(A') standard kubectl drain of the REPLICA's worker under continuous writes: the master stays, every acknowledged write is on it and on the replica rebuilt on another worker"
        run := drainTest { cfg, suite := "node-ops-drain", test := "a-replica" } false }
    ] }

/-! ## D: eviction held while the replica is behind -/

def holdVerdict (drainDone : Bool) (masterDeleting : Bool) (reasonSeen : Bool) : Option String :=
  if drainDone then some "the drain COMPLETED while the only successor was cut off (behind): the eviction was not held"
  else if masterDeleting then some "the master pod was being deleted while the successor was behind"
  else if !reasonSeen then some "the eviction was held, but no reason naming the data condition was returned to the requester"
  else none

private def holdTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["scenario D: the replica is cut off from the master (behind), then the master's worker is drained (120 s)"]
    match ← seed c p "seedhold" with
    | .error e => return .fail e
    | .ok () => pure ()
    if !(← cutBetween p.master.ip p.replica.ip) then return .fail (notSetUp "could not cut master <-> replica")
    c.event s!"cut {p.master.ip} <-> {p.replica.ip}"
    let n ← writeKeys c.cfg.debugPod c.cfg.«namespace» p.master.ip c.cfg.flarePort "behind" 100
    c.event s!"{n}/100 acknowledged by the master while the replica is cut off"
    let stem ← startDrain p.master.node 120
    let (_, done) ← observe c 150 (return (← drainResult stem).isSome)
    let (rc, out) := (← drainResult stem).getD ("running", "")
    for l in out.splitOn "\n" do c.art "drain.txt" l
    let mp := ((← c.pods).getD []).find? (·.name == p.master.name)
    let deleting := (mp.map (·.deleting)).getD true
    healBetween p.master.ip p.replica.ip
    uncordon p.master.node
    let completed := done && rc == "0"
    let reason := containsSubstr out "flare" && (containsSubstr out "behind" || containsSubstr out "not eligible" || containsSubstr out "held")
    IO.eprintln s!"# [{c.test}] drain rc={rc} completed={completed}; master deleting={deleting}; reason seen={reason}"
    match holdVerdict completed deleting reason with
    | some why => return .fail why
    | none => return .pass

def holdSuite : TestSuite :=
  let cfg := cfgOf "node-hold" true false
  { name := "node-ops-hold"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(D) the replica is cut off and behind; a standard drain of the master's worker is HELD: the drain does not complete, the master is not deleted, and the requester is told why"
        run := holdTest { cfg, suite := "node-ops-hold", test := "d-behind" } }
    ] }

/-! ## B: sudden worker stop -/

structure StopObs where
  oldMaster : String
  oldReplica : String
  promoted : Option String
  promotionSec : Option Nat
  autoRedundant : Bool
  redundantAfter : Bool
  finalMaster : Option String
  missingMaster : Option Nat
  lateMissing : Nat
  summary : String

/-- Target of B: the eligible copy (the replica) is promoted; a returning or
    replaced copy does not displace it; redundancy comes back. Acknowledged
    writes missing on the final master are allowed ONLY if they were
    acknowledged within `windowSec` before the stop (asynchronous
    replication: not loss-free, measured and recorded). -/
def stopVerdict (o : StopObs) : Option String :=
  if o.promoted != some o.oldReplica then some s!"the replica {o.oldReplica} was not promoted (master now {o.promoted})"
  else if !o.redundantAfter then some "redundancy was not restored"
  else if o.finalMaster != some o.oldReplica then some s!"the promoted copy was displaced by {o.finalMaster} after the old worker came back"
  else match o.missingMaster with
    | none => some (unobservable "the final master's copy could not be read")
    | some m => if m > o.lateMissing then some s!"DATA: {m - o.lateMissing} acknowledged write(s) missing on the final master that were acknowledged MORE than the async window before the stop" else none

private def stopRun (c : Ctx) (returns : Bool) : IO (Except String StopObs) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    c.conditions [s!"scenario B: the master's worker {p.master.node} is stopped (docker stop); {if returns then "it comes back with its data (PVC)" else "its tmpfs copy is gone; the pod is replaced"}"]
    match ← seed c p s!"seed{c.test}" with
    | .error e => return .error e
    | .ok () => pure ()
    if !(← c.startWriter "svc" (svcHost c) "ws") then return .error (notSetUp "writer svc did not start")
    let (s0, _) ← observe c 10 (pure false)
    let tStop ← epochNow
    match ← stopWorker p.master.node with
    | .error e => return .error (notSetUp s!"could not stop {p.master.node}: {e}")
    | .ok _ => pure ()
    c.event s!"worker {p.master.node} stopped"
    let t0 ← nowSec
    let (s1, prom) ← observe c 300 (do return ((← c.roles).bind (·.1)) == some p.replica.name)
    let tProm ← nowSec
    let promSec := if prom then some (tProm - t0) else none
    c.event s!"promotion of {p.replica.name} seen={prom} after {promSec}"
    -- without any action: does redundancy come back by itself?
    let (s2, auto) ← observe c 180 (redundant c (some p.master.node))
    c.event s!"redundancy restored without manual action within 180 s: {auto}"
    if returns then
      discard <| startWorker p.master.node
      c.event s!"worker {p.master.node} started again"
    else if !auto then
      -- documented manual step (design §3 decision 3): the worker IS stopped,
      -- so the stuck pod may be force-deleted to let the StatefulSet replace it
      discard <| kubectl ["delete", "pod", p.master.name, "-n", c.cfg.«namespace», "--force", "--grace-period=0"]
      c.event s!"manual step: force-deleted {p.master.name} (its worker is stopped)"
    let (s3, red) ← observe c 420 (redundant c (if returns then none else some p.master.node))
    c.event s!"redundancy restored={red}"
    let ws := (← c.stopWriter "svc").getD []
    if !returns then discard <| startWorker p.master.node
    let samples := s0 ++ s1 ++ s2 ++ s3
    let finalM := (← c.roles).bind (·.1)
    let copies ← finalCopies c
    let mcopy := finalM.bind fun n => (copies.lookup n).join
    let mm ← match mcopy with | some d => pure (some (← recordMissing c "master" ws d)) | none => pure none
    let late := match mcopy with
      | some d => (missingAcks ws d).filter (fun w => w.t + 5 ≥ tStop) |>.length
      | none => 0
    let summary := writerSummary "svc" samples ws
    c.art "report.txt" summary
    let promoted := if prom then some p.replica.name else finalM
    return .ok { oldMaster := p.master.name, oldReplica := p.replica.name, promoted := promoted,
                 promotionSec := promSec, autoRedundant := auto, redundantAfter := red, finalMaster := finalM,
                 missingMaster := mm, lateMissing := late, summary }

private def stopTest (c : Ctx) (returns : Bool) : IO TestResult := do
  match ← stopRun c returns with
  | .error e => return .fail e
  | .ok o =>
    IO.eprintln s!"# [{c.test}] promoted {o.promoted} after {o.promotionSec} s; redundancy without action={o.autoRedundant}, finally={o.redundantAfter}; final master {o.finalMaster}; missing acks on it {o.missingMaster} ({o.lateMissing} within 5 s before the stop: async, not loss-free); {o.summary}"
    match stopVerdict o with
    | some why => return .fail why
    | none => return .pass

def stopSuite : TestSuite :=
  let pvc := cfgOf "node-stop" false true
  let tmp := cfgOf "node-stop-t" true false
  { name := "node-ops-stop"
    setup := do deployCluster pvc; IO.sleep 50000
    teardown := do
      for n in ← kindNodes do discard <| startWorker n
      cleanupCluster pvc
      cleanupCluster tmp
    onFailure := do
      dumpClusterDiagnostics pvc.«namespace» s!"app={pvc.operatorName}"
      dumpClusterDiagnostics tmp.«namespace» s!"app={tmp.operatorName}"
    afterEach := fun i => do
      saveFullLogs pvc.«namespace» s!"after-test-{i}"
      saveFullLogs tmp.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(B) the master's worker stops (PVC) and comes back with its data: the replica is promoted, the returning copy does not displace it, redundancy is restored; acknowledged writes missing on the final master only within the async window before the stop (measured, not loss-free)"
        run := stopTest { cfg := pvc, suite := "node-ops-stop", test := "b-return" } true },
      { name := "(B') the master's worker stops and its tmpfs copy is gone: the replica is promoted; whether redundancy returns WITHOUT manual action is recorded, then the stuck pod is force-deleted (the worker is known stopped) and the copy is rebuilt on the spare worker"
        run := do
          cleanupCluster pvc
          deployCluster tmp
          IO.sleep 50000
          stopTest { cfg := tmp, suite := "node-ops-stop", test := "b-replace" } false }
    ] }

/-! ## C: partition with clients on both sides -/

structure PartObs where
  masters : List String
  dualSec : Nat
  dualAcks : Nat
  lostAcks : Option Nat
  summary : String

/-- C is a MEASUREMENT (design §1): the product does not yet claim to prevent
    two masters accepting writes. The test fails when it happened (the gap,
    for the design review) or when an acknowledged write was lost. -/
def partVerdict (o : PartObs) : Option String :=
  if o.dualAcks > 0 then some s!"PRODUCT GAP: two masters accepted writes at the same time ({o.dualAcks} acknowledged writes on the old master while another master existed, over ~{o.dualSec} s; masters seen {o.masters})"
  else match o.lostAcks with
    | none => some (unobservable "the final master's copy could not be read")
    | some n => if n > 0 then some s!"DATA: {n} acknowledged write(s) missing on the final master after the heal" else none

/-- The C measurement from the samples and the writers' records (pure). -/
def partAnalyze (oldMaster : String) (s0 s1 s2 : List Sample) (wsOld wsPeer : List WriteRec) (lost : Option Nat) : PartObs :=
  let samples := s0 ++ s1 ++ s2
  let tCut := (s1.head?.map (·.1)).getD 0
  let tHeal := (s2.head?.map (·.1)).getD 0
  let otherMasterTimes := (s1.filter fun (smp : Sample) => smp.2.1.isSome && smp.2.1 != some oldMaster).map (·.1)
  let dual := wsOld.filter fun w => classify w.reply == .ack && w.t ≥ tCut && w.t ≤ tHeal
    && otherMasterTimes.any (fun t => t ≤ w.t)
  let masters := (samples.filterMap (·.2.1)).eraseDups
  let dualSec := match otherMasterTimes.head?, otherMasterTimes.getLast? with
    | some a, some b => b - a + 2
    | _, _ => 0
  { masters, dualSec, dualAcks := dual.length, lostAcks := lost,
    summary := s!"{writerSummary "old" samples wsOld}; {writerSummary "peer" samples wsPeer}" }

/-- `nodeLevel` = also cut the master's worker from the control-plane node
    (kubelet -> apiserver) and the operator, so the node goes NotReady and
    the operator may fail over while clients still reach the old master. -/
private def dockerIp (node : String) : IO String := do
  match ← hostCmd "docker" ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", node] with
  | .ok o => return o.trim
  | .error _ => return ""

/-- Placement, seed, addresses and writers for C; every precondition here. -/
private def partitionPrepare (c : Ctx) (nodeLevel : Bool) : IO (Except String (Placement × List (String × String))) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    c.conditions [s!"scenario C: cut master<->replica and operator<->master{if nodeLevel then " and the master's worker <-> control-plane" else ""}; the client (debug pod, control-plane) reaches both. kind single-host cut: not proof of a real AZ failure"]
    match ← seed c p s!"seed{c.test}" with
    | .error e => return .error e
    | .ok () =>
      let opIp := ((← getPodIps s!"app={c.cfg.operatorName}" c.cfg.«namespace»).head?).getD ""
      let cpIp ← dockerIp "flare-e2e-control-plane"
      let wIp ← dockerIp p.master.node
      if opIp.isEmpty || (nodeLevel && (cpIp.isEmpty || wIp.isEmpty)) then
        return .error (notSetUp "addresses for the cut not resolved")
      let w1 ← c.startWriter "old" p.master.ip "wo"
      let w2 ← c.startWriter "peer" p.replica.ip "wr"
      if !w1 || !w2 then return .error (notSetUp "a writer did not start")
      let pairs := [(p.master.ip, p.replica.ip), (p.master.ip, opIp)] ++ (if nodeLevel then [(wIp, cpIp)] else [])
      return .ok (p, pairs)

/-- Cut, observe, heal, collect (no early exit). -/
private def partitionExecute (c : Ctx) (nodeLevel : Bool) (p : Placement) (pairs : List (String × String)) : IO PartObs := do
  let (s0, _) ← observe c 10 (pure false)
  for (a, b) in pairs do discard <| cutBetween a b
  c.event s!"cut {pairs}"
  let (s1, _) ← observe c (if nodeLevel then 150 else 90) (pure false)
  for (a, b) in pairs do healBetween a b
  c.event "healed"
  let (s2, _) ← observe c 180 (redundant c none)
  let wsOld := (← c.stopWriter "old").getD []
  let wsPeer := (← c.stopWriter "peer").getD []
  let finalM := (← c.roles).bind (·.1)
  let copies ← finalCopies c
  let mcopy := finalM.bind fun n => (copies.lookup n).join
  let lost ← match mcopy with
    | some d => pure (some (← recordMissing c "master" (wsOld ++ wsPeer) d))
    | none => pure none
  let o := partAnalyze p.master.name s0 s1 s2 wsOld wsPeer lost
  c.art "report.txt" o.summary
  return o

private def partitionRun (c : Ctx) (nodeLevel : Bool) : IO (Except String PartObs) := do
  match ← partitionPrepare c nodeLevel with
  | .error e => return .error e
  | .ok (p, pairs) => return .ok (← partitionExecute c nodeLevel p pairs)

private def partitionTest (c : Ctx) (nodeLevel : Bool) : IO TestResult := do
  match ← partitionRun c nodeLevel with
  | .error e => return .fail e
  | .ok o =>
    IO.eprintln s!"# [{c.test}] masters seen {o.masters}; dual-master acks {o.dualAcks} over ~{o.dualSec} s; lost acks {o.lostAcks}; {o.summary}"
    match partVerdict o with
    | some why => return .fail why
    | none => return .pass

def partitionSuite : TestSuite :=
  let cfg := cfgOf "node-part" true false
  { name := "node-ops-partition"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(C) master<->replica and operator<->master cut, both pods still Ready, the client reaches both: measured — at most one master accepts writes; no acknowledged write is lost after the heal"
        run := partitionTest { cfg, suite := "node-ops-partition", test := "c-links" } false },
      { name := "(C') the master's worker is also cut from the control-plane (node NotReady) while the client still reaches it: measured — whether old and new master accept writes at the same time (dual write = product gap for review) and what survives the heal"
        run := partitionTest { cfg, suite := "node-ops-partition", test := "c-node" } true }
    ] }

end FlareOperator.E2E.Tests.NodeOps
