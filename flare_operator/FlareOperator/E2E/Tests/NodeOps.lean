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
import Lean.Data.Json

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
    -- widen the replication window: the successor's worker answers 100 ms late
    let delayed ← if drainMaster then netemDelay other.node 100 else pure false
    if delayed then c.event s!"netem: 100 ms delay on {other.node} (successor {other.name})"
    c.art "conditions.txt" s!"netem delay on the successor's worker: {if delayed then "100 ms" else "none"}"
    let (s0, _) ← observe c 10 (pure false)
    c.event s!"drain of {target.node} ({target.name}) starts"
    let t0 ← nowSec
    let stem ← startDrain target.node 600
    let (s1, done) ← observe c 660 (return (← drainResult stem).isSome)
    let (rc, out) := (← drainResult stem).getD ("timeout", "")
    for l in out.splitOn "\n" do c.art "drain.txt" l
    c.event s!"drain finished rc={rc} (completed={done})"
    if delayed then discard <| netemDelay other.node 0
    let (s2, red) ← observe c 420 (redundant c (some target.node))
    let rec_ := (← nowSec) - t0
    c.event s!"redundancy restored={red} after {rec_} s from the drain start"
    let (s3, _) ← observe c 10 (pure false)
    let ws1? ← c.stopWriter "svc"
    let ws2? ← c.stopWriter "peer"
    uncordon target.node
    let (some ws1, some ws2) := (ws1?, ws2?)
      | return .error (unobservable "a writer's record could not be read (never counted as 'no acknowledged write')")
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

/-- EV-01 / EV-05 (dry run): a bare policy/v1 Eviction (no labels) for the
    master reaches the webhook and is refused; a dry run records nothing; an
    Eviction whose UID precondition does not match is refused. -/
private def rawEvictionTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["EV-01/EV-05: bare Eviction bodies posted to pods/eviction (kubectl create --raw)"]
    let ns := c.cfg.«namespace»
    let post := fun (dry : Bool) (uid : Option String) => do
      let pre := match uid with | some u => s!",\"deleteOptions\":\{\"preconditions\":\{\"uid\":\"{u}\"}}" | none => ""
      let body := s!"\{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":\{\"name\":\"{p.master.name}\",\"namespace\":\"{ns}\"}{pre}}"
      let path := s!"/api/v1/namespaces/{ns}/pods/{p.master.name}/eviction{if dry then "?dryRun=All" else ""}"
      let out ← IO.Process.output { cmd := "sh", args := #["-c", s!"printf '%s' '{body}' | kubectl create --raw '{path}' -f - 2>&1"] }
      c.art "raw-eviction.txt" s!"dry={dry} uid={uid} rc={out.exitCode}: {out.stdout.trim}"
      return (out.exitCode, out.stdout ++ out.stderr)
    let (rc1, o1) ← post true none
    let (rc2, o2) ← post false (some "00000000-0000-0000-0000-000000000000")
    let st ← kubectl ["get", "flarecluster", c.cfg.name, "-n", ns, "-o", "jsonpath={.status.disruption}"]
    let recorded := match st with | .ok t => !t.trim.isEmpty | .error _ => true
    let pods := (← c.pods).getD []
    let stillThere := pods.any fun q => q.name == p.master.name && q.uid == p.master.uid && !q.deleting
    IO.eprintln s!"# [{c.test}] dry run rc={rc1}: {o1.trim.take 200}; bad UID rc={rc2}: {o2.trim.take 200}; recorded={recorded}; master intact={stillThere}"
    if rc1 == 0 then return .fail "the dry-run eviction of the master was ALLOWED"
    if !containsSubstr o1 "flare" then return .fail s!"the dry-run refusal did not come from the flare webhook: {o1.trim.take 300}"
    if rc2 == 0 then return .fail "an eviction with a mismatched UID precondition was ALLOWED"
    if recorded then return .fail "a dry run / refused precondition recorded a disruption"
    if !stillThere then return .fail "the master pod was deleted or replaced"
    return .pass

def drainSuite : TestSuite :=
  let cfg := { cfgOf "node-drain" true false with evictionGuard := true }
  { name := "node-ops-drain"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(EV-01/05) a bare Eviction for the master (no labels) reaches the flare webhook and is refused; a dry run and a mismatched UID precondition record nothing and leave the pod"
        run := rawEvictionTest { cfg, suite := "node-ops-drain", test := "ev-raw" } },
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
    let rules := podCutRules (← kindNodes) p.master.ip p.replica.ip
    let installed ← match ← installCuts rules with
      | .ok r => pure r
      | .error (why, part) => removeCuts part; return .fail (notSetUp s!"could not cut master <-> replica: {why}")
    try
      c.event s!"cut {p.master.ip} <-> {p.replica.ip} ({installed.length} rules)"
      if (← tcpFromPod c.cfg.«namespace» p.replica.name "flared" p.master.ip c.cfg.flarePort) != some false then
        return .fail (notSetUp "the replica can still open a connection to the master after the cut (or the probe could not run)")
      let n ← writeKeys c.cfg.debugPod c.cfg.«namespace» p.master.ip c.cfg.flarePort "behind" 100
      c.event s!"{n}/100 acknowledged by the master while the replica is cut off"
      let stem ← startDrain p.master.node 120
      let (_, done) ← observe c 150 (return (← drainResult stem).isSome)
      let (rc, out) := (← drainResult stem).getD ("running", "")
      for l in out.splitOn "\n" do c.art "drain.txt" l
      let mp := ((← c.pods).getD []).find? (·.name == p.master.name)
      let deleting := (mp.map (·.deleting)).getD true
      for r in installed do c.art "cuts.txt" s!"{r.label} dropped {(← cutCounter r).map toString |>.getD "?"} packets"
      removeCuts installed
      uncordon p.master.node
      let completed := done && rc == "0"
      let reason := containsSubstr out "flare" && (containsSubstr out "behind" || containsSubstr out "not eligible" || containsSubstr out "held")
      IO.eprintln s!"# [{c.test}] drain rc={rc} completed={completed}; master deleting={deleting}; reason seen={reason}"
      match holdVerdict completed deleting reason with
      | some why => return .fail why
      | none => return .pass
    finally
      removeCuts installed

/-! ## #3: concurrent eviction requests (review 2026-10-19) -/

/-- Exactly one request may be recorded out of simultaneous first evictions
    of two pods; all are refused; neither pod is touched. -/
def concurrentVerdict (allowed : Nat) (recordedNow : Nat) (statePod : Option String) (pods : List String) (intact : Bool) : Option String :=
  if allowed > 0 then some s!"{allowed} of the simultaneous FIRST evictions were ALLOWED"
  else if recordedNow != 1 then some s!"{recordedNow} requests were recorded out of the simultaneous evictions (exactly 1 expected: the others must lose the compare-and-swap or see the disruption in progress)"
  else if !(statePod.any pods.contains) then some s!"status.disruption names {statePod}, not one of the requested pods {pods}"
  else if !intact then some "a requested pod was deleted or replaced"
  else none

private def countRecorded (c : Ctx) : IO Nat := do
  let log ← kubectlLogsLabel s!"app={c.cfg.operatorName}" c.cfg.«namespace» 10000000
  return ((log.splitOn "\n").filter fun l => containsSubstr l "EVICTION REFUSED" && containsSubstr l "recorded; retry later").length

private def disruptionPhase (c : Ctx) : IO (Option String × Option String) := do
  match ← kubectl ["get", "flarecluster", c.cfg.name, "-n", c.cfg.«namespace», "-o", "jsonpath={.status.disruption}"] with
  | .ok t =>
    match Lean.Json.parse t.trim with
    | .ok j => return ((j.getObjValAs? String "pod").toOption, (j.getObjValAs? String "phase").toOption)
    | .error _ => return (none, none)
  | .error _ => return (none, none)

private def concurrentTest (c : Ctx) : IO TestResult := do
  match ← c.placement with
  | .error e => return .fail e
  | .ok p =>
    c.conditions ["#3: four FIRST evictions at once (master x2, replica x2), bare Eviction bodies (kubectl create --raw, background)"]
    let ns := c.cfg.«namespace»
    let before ← countRecorded c
    let one := fun (pod : String) (i : Nat) =>
      s!"(printf '%s' '\{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":\{\"name\":\"{pod}\",\"namespace\":\"{ns}\"}}' | kubectl create --raw '/api/v1/namespaces/{ns}/pods/{pod}/eviction' -f - > /tmp/ev-conc-{i}.out 2>&1; echo $? > /tmp/ev-conc-{i}.rc) &"
    let script := String.intercalate " " [one p.master.name 1, one p.master.name 2, one p.replica.name 3, one p.replica.name 4, "wait"]
    discard <| IO.Process.output { cmd := "sh", args := #["-c", script] }
    let mut allowed := 0
    for i in [1, 2, 3, 4] do
      let rc := (← IO.Process.output { cmd := "cat", args := #[s!"/tmp/ev-conc-{i}.rc"] }).stdout.trim
      let out := (← IO.Process.output { cmd := "cat", args := #[s!"/tmp/ev-conc-{i}.out"] }).stdout.trim
      c.art "concurrent.txt" s!"request {i} rc={rc}: {out}"
      if rc == "0" then allowed := allowed + 1
    IO.sleep 3000
    let recorded := (← countRecorded c) - before
    let (pod, phase) ← disruptionPhase c
    let pods := (← c.pods).getD []
    let intact := [p.master, p.replica].all fun x => pods.any fun q => q.name == x.name && q.uid == x.uid && !q.deleting
    IO.eprintln s!"# [{c.test}] allowed={allowed}; recorded={recorded}; status.disruption={pod}/{phase}; pods intact={intact}"
    let verdict := concurrentVerdict allowed recorded pod [p.master.name, p.replica.name] intact
    -- let the recorded request run out (a grant nobody uses expires, an
    -- unproven prepare aborts) before the next test
    let (_, _) ← observe c 420 (do
      let (_, ph) ← disruptionPhase c
      return ph == some "aborted" || ph.isNone)
    let (_, phEnd) ← disruptionPhase c
    c.event s!"the recorded request ended as {phEnd}"
    match verdict with
    | some why => return .fail why
    | none => return .pass

def holdSuite : TestSuite :=
  let cfg := { cfgOf "node-hold" true false with evictionGuard := true }
  { name := "node-ops-hold"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(#3) four FIRST evictions at once for the master and the replica: all refused, exactly ONE request recorded (the others lose the compare-and-swap or see it in progress), neither pod touched"
        run := concurrentTest { cfg, suite := "node-ops-hold", test := "concurrent" } },
      { name := "(D) the replica is cut off and behind; a standard drain of the master's worker is HELD: the drain does not complete, the master is not deleted, and the requester is told why"
        run := holdTest { cfg, suite := "node-ops-hold", test := "d-behind" } }
    ] }

/-- CONTROLS (design §4.5: compare old and new on the same SHA): the same A
    and D scenarios with the eviction guard OFF — the behaviour without the
    planned-eviction controls. Expected: A may lose acknowledged writes under
    the 100 ms successor delay; D completes the drain (not held). -/
def drainControlSuite : TestSuite :=
  let cfg := cfgOf "node-drain-c" true false
  { name := "node-ops-drain-control"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(A, CONTROL: no eviction guard) standard kubectl drain of the MASTER's worker under continuous writes with the successor delayed 100 ms: every acknowledged write on the new master and the rebuilt replica (expected to FAIL without the guard)"
        run := drainTest { cfg, suite := "node-ops-drain-control", test := "a-master-control" } true }
    ] }

def holdControlSuite : TestSuite :=
  let cfg := cfgOf "node-hold-c" true false
  { name := "node-ops-hold-control"
    setup := do deployCluster cfg; IO.sleep 50000
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(D, CONTROL: no eviction guard) the replica is cut off and behind; a standard drain of the master's worker: held? (expected to FAIL without the guard)"
        run := holdTest { cfg, suite := "node-ops-hold-control", test := "d-behind-control" } }
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
  /-- acknowledged writes after the promotion was seen (writes resumed) -/
  acksAfterPromotion : Nat := 0
  summary : String

/-- Target of B: the eligible copy (the replica) is promoted; a returning or
    replaced copy does not displace it; redundancy comes back. Acknowledged
    writes missing on the final master are allowed ONLY if they were
    acknowledged within `windowSec` before the stop (asynchronous
    replication: not loss-free, measured and recorded). -/
def stopVerdict (o : StopObs) : Option String :=
  if o.promoted != some o.oldReplica then some s!"the replica {o.oldReplica} was not promoted (master now {o.promoted})"
  else if o.promotionSec.isNone then some "the eligible replica was not promoted within the 300 s observation bound (harness bound, not an SLO)"
  else if o.acksAfterPromotion == 0 then some "writes did not resume after the promotion (no acknowledged write after it was seen)"
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
    let ws? ← c.stopWriter "svc"
    if !returns then discard <| startWorker p.master.node
    let some ws := ws?
      | return .error (unobservable "the writer's record could not be read (never counted as 'no acknowledged write')")
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
    let tPromEpoch := tStop + (promSec.getD 0)
    let resumed := if prom then (ws.filter fun w => classify w.reply == .ack && w.t > tPromEpoch).length else 0
    return .ok { oldMaster := p.master.name, oldReplica := p.replica.name, promoted := promoted,
                 promotionSec := promSec, autoRedundant := auto, redundantAfter := red, finalMaster := finalM,
                 missingMaster := mm, lateMissing := late, acksAfterPromotion := resumed, summary }

private def stopTest (c : Ctx) (returns : Bool) : IO TestResult := do
  match ← stopRun c returns with
  | .error e => return .fail e
  | .ok o =>
    IO.eprintln s!"# [{c.test}] promoted {o.promoted} after {o.promotionSec} s; {o.acksAfterPromotion} acks after it; redundancy without action={o.autoRedundant}, finally={o.redundantAfter}; final master {o.finalMaster}; missing acks on it {o.missingMaster} ({o.lateMissing} within 5 s before the stop: async, not loss-free); {o.summary}"
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

/-! ## C: partition with clients on both sides

    Review 2026-10-19 (C'): the scenario holds only when the injection is
    PROVEN (every rule installed and counted, the cut paths really closed,
    the client path really open; C': the node goes NotReady/Unknown and its
    Lease heartbeat stops). Dual writes are judged from the nodes' OWN views
    (role / map version / boot, sampled by the client on both sides) and the
    acknowledgements in the same time window — not from the operator's map.
    "No failover" is never a pass for C': it is reported as NOT VERIFIED
    (availability after the partition, and safety after a switch, were not
    exercised). A failover is never forced. -/

/-- One reading of a pod's OWN view by the client: the read started at
    `ts` and ended at `te` (epoch seconds, the debug pod's clock = the
    writers' clock); the view held at some moment in [ts, te]. -/
structure Reading where
  pod : String
  ts : Nat
  te : Nat
  view : Option OwnV
  deriving Repr

/-- One sample of the partition run. -/
structure PartSample where
  t : Nat
  reads : List Reading
  masterPodReady : Option Bool
  nodeReady : Option String
  lease : Option String
  deriving Repr

/-- The widest gap between the two readings that bracket an interval. -/
def maxBracketSec : Nat := 12

/-- The view `pod` itself held over the WHOLE interval [a, b] — or `none`.
    Strict bracket: the last reading that ENDED before `a` and the first that
    STARTED after `b` (never the same reading, never one overlapping the
    interval's own seconds), at most `maxBracketSec` apart, and every reading
    of the pod overlapping [before.ts, after.te] (both included) read the
    SAME view (role, map version, boot). An inference from role readings,
    not a per-request trace. -/
def ownViewOver (ss : List PartSample) (pod : String) (a b : Nat) : Option OwnV :=
  let rs := (ss.flatMap (·.reads)).filter (·.pod == pod)
  match (rs.filter (·.te < a)).getLast?, (rs.filter (·.ts > b)).head? with
  | some x, some y =>
    if y.ts - x.te > maxBracketSec then none else
    let between := rs.filter fun r => r.te ≥ x.ts && r.ts ≤ y.te
    match x.view with
    | some v => if between.all (·.view == some v) then some v else none
    | none => none
  | _, _ => none

def ownRoleOver (ss : List PartSample) (pod : String) (a b : Nat) : Option String :=
  (ownViewOver ss pod a b).map (·.role)

/-- How a write was processed, inferred from the target's OWN view over the
    write's whole [sent, replied] span: "local" (it was master), "forwarded"
    (it was not), "unknown" (not strictly bracketed). -/
def ownPathOf (ss : List PartSample) (ipToPod : List (String × String)) (w : WriteRec) : String :=
  match ipToPod.lookup w.ip with
  | none => "unknown"
  | some pod => match ownRoleOver ss pod w.span.1 w.span.2 with
    | some "master" => "local"
    | some _ => "forwarded"
    | none => "unknown"

structure Injection where
  rulesInstalled : Bool
  rulesWhy : String := ""
  counters : List (String × Option Nat) := []
  /-- probes before / after the cut: each cut path OPEN before and timed
      out after; the client path still acks -/
  replicaToMasterBefore : Option Bool := none
  operatorToMasterBefore : Option Bool := none
  replicaToMaster : Option Bool := none
  operatorToMaster : Option Bool := none
  /-- C' only: the worker reaches the API server before / after the cut,
      over EVERY address family (all must be open before, timed out after) -/
  apiBefore : Option Bool := none
  apiAfter : Option Bool := none
  apiProbes : List (String × Option Bool × Option Bool) := []
  clientAcksAfterCut : Nat := 0
  deriving Repr

structure PartObs where
  nodeLevel : Bool
  oldMaster : String
  replica : String
  inj : Injection
  tCut : Nat
  tHeal : Nat
  samples : List PartSample
  oldAcks : List (WriteRec × String)
  peerAcks : List (WriteRec × String)
  lostAcks : Option Nat
  summary : String

/-- Was the injection established? `none` = yes. -/
def injectionProblem (o : PartObs) : Option String :=
  let i := o.inj
  let inCut := o.samples.filter fun s => s.t ≥ o.tCut && s.t ≤ o.tHeal
  if !i.rulesInstalled then some s!"the cut rules were not all installed ({i.rulesWhy})"
  else if i.counters.any (·.2.isNone) then some s!"a cut rule's counter could not be read: {i.counters}"
  else if i.replicaToMasterBefore != some true then some s!"replica -> master was not proven open before the cut (probe {i.replicaToMasterBefore})"
  else if i.operatorToMasterBefore != some true then some s!"operator -> master was not proven open before the cut (probe {i.operatorToMasterBefore})"
  else if i.replicaToMaster != some false then some s!"replica -> master is not proven cut (probe {i.replicaToMaster})"
  else if i.operatorToMaster != some false then some s!"operator -> master is not proven cut (probe {i.operatorToMaster})"
  else if i.clientAcksAfterCut == 0 then some "the client did not reach the old master during the cut (no acknowledged write): not the scenario"
  else if o.nodeLevel then
    if i.apiBefore != some true then some s!"the worker's API path was not proven open before the cut (probe {i.apiBefore})"
    else if i.apiAfter != some false then some s!"the worker -> API server path is not proven cut (probe {i.apiAfter})"
    else if !inCut.any (fun s => s.nodeReady == some "Unknown" || s.nodeReady == some "False") then
      some s!"the master's node never went NotReady/Unknown during the cut (Ready seen: {(inCut.filterMap (·.nodeReady)).eraseDups})"
    else
      let leases := inCut.filterMap (·.lease)
      let late := inCut.filter (fun s => s.t ≥ o.tCut + 60) |>.filterMap (·.lease)
      if leases.isEmpty || late.isEmpty then some "the node Lease heartbeat could not be read during the cut"
      else if late.eraseDups.length > 1 then some s!"the node Lease kept renewing during the cut ({late.eraseDups})"
      else none
  else none

/-- The pure verdict. `none` = pass — a MEASUREMENT pass: local / forwarded
    are inferred from the nodes' own-role readings, not traced per request,
    so it is never an acceptance of failover safety. -/
def partVerdict (o : PartObs) : Option String :=
  match injectionProblem o with
  | some why => some (notSetUp s!"injection not established: {why}")
  | none =>
  let inCut := fun (w : WriteRec) => w.span.1 ≥ o.tCut && w.span.2 ≤ o.tHeal
  let unknown := (o.oldAcks ++ o.peerAcks).filter fun (w, p) => inCut w && p == "unknown"
  -- a promotion counts only when the replica's own view said master DURING
  -- the cut (a promotion first seen after the heal is not a failover)
  let reads := (o.samples.flatMap (·.reads)).filter fun r => r.pod == o.replica && r.ts ≥ o.tCut && r.te ≤ o.tHeal
  let failedOver := reads.any fun r => (r.view.map (·.role)) == some "master"
  let oldLocal := o.oldAcks.filter fun (w, p) => inCut w && p == "local"
  let newLocal := o.peerAcks.filter fun (w, p) => inCut w && p == "local"
  -- dual write, on ONE time base (the debug pod's clock): an old-master
  -- local ack over whose whole span the new master was master by its own
  -- view, and a new-master local ack over whose whole span the old master
  -- was master by its own view
  let oldDual := oldLocal.filter fun (w, _) => ownRoleOver o.samples o.replica w.span.1 w.span.2 == some "master"
  let newDual := newLocal.filter fun (w, _) => ownRoleOver o.samples o.oldMaster w.span.1 w.span.2 == some "master"
  if !unknown.isEmpty then some (unobservable s!"{unknown.length} acknowledged write(s) in the cut window whose processing cannot be told from strictly bracketed own-view readings")
  else match o.lostAcks with
  | none => some (unobservable "the final master's copy could not be read")
  | some n =>
    if !oldDual.isEmpty && !newDual.isEmpty then
      some s!"PRODUCT GAP (dual write, inferred from own-role readings): the old master acknowledged {oldDual.length} write(s) locally while the new master was master by its own view, and the new master {newDual.length} while the old one still was (cut {o.tCut}..{o.tHeal}); no fencing stops the old master (design decision point 2)"
    else if n > 0 then some s!"DATA: {n} acknowledged write(s) missing on the final master after the heal"
    else if o.nodeLevel then
      if !failedOver then
        some "NOT VERIFIED: the replica was not master by its own view at any time DURING the cut (no failover, or only after the heal) — availability after the partition and safety after a switch were not exercised"
      else if newLocal.isEmpty then
        some "NOT VERIFIED: after the failover the new master acknowledged no write locally during the cut (write availability on the new master not shown)"
      else match (oldLocal.map (·.1.span.2)).max?, (newLocal.map (·.1.span.1)).min? with
        | some lo, some fn => if lo ≥ fn then some s!"the old master still acknowledged locally until {lo}, not before the new master's first local ack at {fn}" else none
        | _, _ => none
    else if failedOver then
      some "the replica became master while both pods stayed Ready (unexpected for C: no failover is expected while the operator only lost its connection)"
    else if oldLocal.isEmpty then
      some "NOT VERIFIED: the old master acknowledged no write locally during the cut (the single-master observation has no writes behind it)"
    else none

/-- The debug pod's clock (the writers' time base). -/
private def debugEpoch (c : Ctx) : IO (Option Nat) := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» "date +%s" with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- Sample every ~2 s for `secs`: map roles (timeline), both pods' OWN
    views (client side), the master pod's Ready, its node's Ready and Lease. -/
private partial def partObserve (c : Ctx) (secs : Nat) (pods : List PodRow) (node : String) (master : String) : IO (List PartSample) := do
  let deadline := (← nowSec) + secs
  let mut acc : List PartSample := []
  repeat
    discard <| c.sample
    let t ← epochNow
    let mut reads : List Reading := []
    for p in pods do
      let ts ← debugEpoch c
      let v := (← c.stats p.ip).bind ownVOf
      let te ← debugEpoch c
      match ts, te with
      | some a, some b => reads := reads ++ [{ pod := p.name, ts := a, te := b, view := v }]
      | _, _ => pure ()   -- no time base: the reading is not used
    let mp := ((← c.pods).getD []).find? (·.name == master)
    let nr ← nodeReady node
    let ls ← nodeLeaseRenew node
    let ownTxt := String.intercalate " " (reads.map fun r => s!"{r.pod}[{r.ts}..{r.te}]=" ++ ((r.view.map fun (x : OwnV) => x.role ++ "/v" ++ toString x.version ++ "/" ++ x.boot.take 8).getD "?"))
    c.art "own.txt" s!"{t} {ownTxt} node={nr} lease={ls} masterReady={mp.map (·.ready)}"
    acc := acc ++ [{ t, reads, masterPodReady := mp.map (·.ready), nodeReady := nr, lease := ls }]
    if (← nowSec) ≥ deadline then return acc
    IO.sleep 2000
  return acc

/-- Every address of a kind node container (IPv4 and, on the dual-stack
    kind network, IPv6). -/
private def dockerIps (node : String) : IO (List String) := do
  match ← hostCmd "docker" ["inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{.GlobalIPv6Address}} {{end}}", node] with
  | .ok o => return (o.splitOn " ").map String.trim |>.filter (!·.isEmpty)
  | .error _ => return []

private def operatorPod (c : Ctx) : IO (Option String) := do
  match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[0].metadata.name}"] with
  | .ok o => return if o.trim.isEmpty then none else some o.trim
  | .error _ => return none

/-- `nodeLevel` = also cut the master's worker from the control-plane node
    (kubelet -> API server, OUTPUT/INPUT) so the node goes NotReady. -/
private def partitionRun (c : Ctx) (nodeLevel : Bool) : IO (Except String PartObs) := do
  match ← c.placement with
  | .error e => return .error e
  | .ok p =>
    c.conditions [s!"scenario C: cut master<->replica and operator<->master (pod addresses, FORWARD on every kind node){if nodeLevel then " and the master's worker <-> control-plane (node addresses, OUTPUT/INPUT in both containers)" else ""}; the client (debug pod) reaches both. kind single-host cut: not proof of a real AZ failure"]
    match ← seed c p s!"seed{c.test}" with
    | .error e => return .error e
    | .ok () =>
    let opIp := ((← getPodIps s!"app={c.cfg.operatorName}" c.cfg.«namespace»).head?).getD ""
    let some opPod ← operatorPod c | return .error (notSetUp "the operator pod cannot be found")
    let cp := "flare-e2e-control-plane"
    let cpIps ← dockerIps cp
    let wIps ← dockerIps p.master.node
    let nodes ← kindNodes
    if opIp.isEmpty || !nodes.contains cp || !nodes.contains p.master.node || (nodeLevel && (cpIps.isEmpty || wIps.isEmpty)) then
      return .error (notSetUp s!"addresses / kind nodes for the cut not resolved (operator {opIp}, nodes {nodes}, cp {cpIps}, worker {wIps})")
    -- the API probes go to every control-plane address the worker has a
    -- family for
    let apiTargets := cpIps.filter fun a => wIps.any fun b => b.contains ':' == a.contains ':'
    let probeApi := fun (_ : Unit) => do
      let mut r : List (String × Option Bool) := []
      for a in apiTargets do r := r ++ [(a, ← apiReachableFrom p.master.node a)]
      return r
    let allIs := fun (v : Bool) (xs : List (String × Option Bool)) => !xs.isEmpty && xs.all (·.2 == some v)
    let pods := (← c.pods).getD []
    if !(← c.startWriter "old" p.master.ip "wo") || !(← c.startWriter "peer" p.replica.ip "wr") then
      return .error (notSetUp "a writer did not start")
    let apiB ← if nodeLevel then probeApi () else pure []
    let apiBefore := if !nodeLevel then none else if allIs true apiB then some true else none
    let rules := podCutRules nodes p.master.ip p.replica.ip ++ podCutRules nodes p.master.ip opIp
      ++ (if nodeLevel then nodeCutRulesAll p.master.node wIps cp cpIps else [])
    let s0 ← partObserve c 10 pods p.master.node p.master.name
    let rBefore ← tcpFromPod c.cfg.«namespace» p.replica.name "flared" p.master.ip c.cfg.flarePort
    let oBefore ← tcpFromPod c.cfg.«namespace» opPod "flare-operator" p.master.ip c.cfg.flarePort
    let some tCut ← debugEpoch c | return .error (notSetUp "the debug pod's clock cannot be read")
    let (installed, rulesOk, rulesWhy) ← match ← installCuts rules with
      | .ok r => pure (r, true, "")
      | .error (why, part) => pure (part, false, why)
    c.event s!"cut: {installed.length}/{rules.length} rules installed{if rulesOk then "" else s!" — FAILED: {rulesWhy}"}"
    let mut inj : Injection := { rulesInstalled := rulesOk, rulesWhy, replicaToMasterBefore := rBefore, operatorToMasterBefore := oBefore }
    let mut s1 : List PartSample := []
    let mut tHeal := tCut
    try
      -- keep reading the own views across the probe step (no gap)
      let sA ← partObserve c 0 pods p.master.node p.master.name
      s1 := sA
      IO.sleep 5000
      let apiA ← if nodeLevel then probeApi () else pure []
      inj := { inj with apiProbes := apiTargets.map fun a => (a, apiB.lookup a |>.join, apiA.lookup a |>.join) }
      inj := { inj with
        replicaToMaster := ← tcpFromPod c.cfg.«namespace» p.replica.name "flared" p.master.ip c.cfg.flarePort,
        operatorToMaster := ← tcpFromPod c.cfg.«namespace» opPod "flare-operator" p.master.ip c.cfg.flarePort,
        -- some false = EVERY family timed out; some true = one is open;
        -- none = a probe could not tell
        apiAfter := if !nodeLevel then none else if allIs false apiA then some false
          else if apiA.any (·.2 == some true) then some true else none,
        apiBefore }
      c.event s!"probes after the cut: replica->master open={inj.replicaToMaster} operator->master open={inj.operatorToMaster} worker->API before={inj.apiBefore} after={inj.apiAfter}"
      s1 := s1 ++ (← partObserve c 0 pods p.master.node p.master.name)
      if rulesOk then
        s1 := s1 ++ (← partObserve c (if nodeLevel then 330 else 90) pods p.master.node p.master.name)
      let mut cs : List (String × Option Nat) := []
      for r in installed do
        let n ← cutCounter r
        cs := cs ++ [(r.label, n)]
        c.art "cuts.txt" s!"{r.label} dropped {(n.map toString).getD "?"} packets"
      inj := { inj with counters := cs }
      tHeal := (← debugEpoch c).getD 0
    finally
      removeCuts installed
    c.event "healed"
    -- readings right after the heal bracket the last writes of the cut
    let sH ← partObserve c 6 pods p.master.node p.master.name
    let (s2, _) ← observe c 180 (redundant c none)
    let s3 ← partObserve c 6 pods p.master.node p.master.name
    let wsOld? ← c.stopWriter "old"
    let wsPeer? ← c.stopWriter "peer"
    let (some wsOld, some wsPeer) := (wsOld?, wsPeer?)
      | return .error (unobservable "a writer's record could not be read (never counted as 'no acknowledged write')")
    let finalM := (← c.roles).bind (·.1)
    let copies ← finalCopies c
    let mcopy := finalM.bind fun n => (copies.lookup n).join
    let lost ← match mcopy with
      | some d => pure (some (← recordMissing c "master" (wsOld ++ wsPeer) d))
      | none => pure none
    let ss := s0 ++ s1 ++ sH ++ s3
    let ipToPod := pods.map fun r => (r.ip, r.name)
    let acks := fun (ws : List WriteRec) => (ws.filter fun w => classify w.reply == .ack).map fun w => (w, ownPathOf ss ipToPod w)
    inj := { inj with clientAcksAfterCut := (wsOld.filter fun w => classify w.reply == .ack && w.t ≥ tCut + 5 && w.t ≤ tHeal).length }
    let summary := s!"{writerSummary "old" [] wsOld}; {writerSummary "peer" [] wsPeer}; samples during the cut {s1.length}; samples after the heal {s2.length}"
    c.art "report.txt" summary
    return .ok { nodeLevel, oldMaster := p.master.name, replica := p.replica.name, inj, tCut, tHeal, samples := ss,
                 oldAcks := acks wsOld, peerAcks := acks wsPeer, lostAcks := lost, summary }

private def partitionTest (c : Ctx) (nodeLevel : Bool) : IO TestResult := do
  match ← partitionRun c nodeLevel with
  | .error e => return .fail e
  | .ok o =>
    let inCut := o.samples.filter fun s => s.t ≥ o.tCut && s.t ≤ o.tHeal
    let firstNotReady := (inCut.find? fun s => s.nodeReady == some "Unknown" || s.nodeReady == some "False").map (·.t - o.tCut)
    let firstPodNotReady := (inCut.find? fun s => s.masterPodReady == some false).map (·.t - o.tCut)
    let firstNewMaster := ((inCut.flatMap (·.reads)).find? fun r => r.pod == o.replica && (r.view.map (·.role)) == some "master").map (·.ts - o.tCut)
    let paths := fun (xs : List (WriteRec × String)) (k : String) => (xs.filter (·.2 == k)).length
    IO.eprintln s!"# [{c.test}] injection {repr o.inj}; node NotReady +{firstNotReady} s, pod NotReady +{firstPodNotReady} s, replica master (own view) +{firstNewMaster} s; old acks local/forwarded/unknown {paths o.oldAcks "local"}/{paths o.oldAcks "forwarded"}/{paths o.oldAcks "unknown"}, peer {paths o.peerAcks "local"}/{paths o.peerAcks "forwarded"}/{paths o.peerAcks "unknown"}; lost {o.lostAcks}; {o.summary}"
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
      { name := "(C) master<->replica and operator<->master cut (proven: rules counted, both paths closed, client open), both pods still Ready: NO failover expected (operator lost only its connection) — observed single master by the nodes' own views, no acknowledged write lost; not a failover acceptance"
        run := partitionTest { cfg, suite := "node-ops-partition", test := "c-links" } false },
      { name := "(C') the master's worker is also cut from the control-plane (proven: kubelet->API closed, node NotReady/Unknown, Lease stopped) while the client still reaches it: detection -> promotion decision -> old/new master write authority, judged from the nodes' own views; dual write = PRODUCT GAP, no failover = NOT VERIFIED (never green)"
        run := partitionTest { cfg, suite := "node-ops-partition", test := "c-node" } true }
    ] }

end FlareOperator.E2E.Tests.NodeOps
