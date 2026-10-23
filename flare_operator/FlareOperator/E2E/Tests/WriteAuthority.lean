/-
  E2E/Tests/WriteAuthority.lean — C' (no dual writer) end to end, with the write
  authority ON (docs/design-node-operations-2026-10-19.md §13). Every suite sets
  the explicit flag on BOTH sides (flared `write-authority-enabled` with its
  margin / max-ttl, the operator's FLARE_WRITE_AUTHORITY_*); the numbers below
  are the tests' own choices, not defaults:
      ttl 6 s, renew 2 s, flared margin 5 s, prepare window 120 s.

  Suites (each runs alone: `flare_e2e --filter <name>`):
    node-ops-drain-wa      A  : the planned drains of node-ops-drain, authority ON
    node-ops-hold-wa       D  : the held drain of node-ops-hold, authority ON
    node-ops-stop-wa       B, B' : the sudden stops of node-ops-stop, authority ON
    node-ops-partition-wa  C, C' : the cuts of node-ops-partition, authority ON;
                           C' is judged on the acknowledgements (zero interval in
                           which both the old and the new master acknowledge)
    failover-wa            : the existing failover suite (2 partitions, the P0 master
                           pod is killed) with the authority ON
    write-authority-operator-absent : the operator is scaled to 0 while writes
                           continue: every write keeps being acknowledged
    write-authority-two-failovers : the master pod is killed twice in a row (the second as soon as
                           the first new master holds its grant): zero interval in which two
                           pods acknowledge locally, and the second failover completes
    write-authority-solo   : a 1-copy partition (no successor) keeps serving, also
                           with the operator absent
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.E2E.Tests.NodeOps
import FlareOperator.E2E.Tests.Failover
import FlareOperator.K8s.Bridge
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.WriteAuthority

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl

def waFlaredConf : String :=
  FlareOperator.E2E.Tests.NodeOps.followFlags ++
    "\nwrite-authority-enabled = true\nwrite-authority-margin-ms = 5000\nwrite-authority-max-ttl-ms = 6000"

def waOperatorEnv : List (String × String) :=
  [("FLARE_WRITE_AUTHORITY_TTL_MS", "6000"), ("FLARE_WRITE_AUTHORITY_RENEW_MS", "2000"),
   ("FLARE_WRITE_AUTHORITY_MARGIN_MS", "5000"), ("FLARE_WRITE_AUTHORITY_PREPARE_TIMEOUT_MS", "120000")]

/-- The same cluster with the write authority switched on on both sides. -/
def waOf (c : ClusterConfig) : ClusterConfig :=
  { c with extraFlaredConf := waFlaredConf, operatorEnv := c.operatorEnv ++ waOperatorEnv }

def waCfg (name : String) (tmpfs pvc : Bool) : ClusterConfig :=
  waOf (FlareOperator.E2E.Tests.NodeOps.cfgOf name tmpfs pvc)

def authorityTextP (cfg : ClusterConfig) (pod : String) (p : Nat) : IO String := do
  match ← FlareOperator.K8s.Bridge.queryPodStats pod cfg.«namespace» s!"authority status {p}" with
  | .ok o => pure o
  | .error e => pure s!"ERR {e}"

def authorityText (cfg : ClusterConfig) (pod : String) : IO String := authorityTextP cfg pod 0

/-- The pod that holds the grant the cluster is meant to be under (partition 0, the master),
    if any: a replicated cluster (more than one copy) is under a grant from its successors'
    promises (NOT the solo grant the master holds before its replica is Active — a seed
    started on that one would meet the switch to the replicated grant), a single copy under
    the solo grant. -/
def grantedPodOf (cfg : ClusterConfig) (p : Nat) : IO (Option String) := do
  for pod in ← getPodNames s!"cluster={cfg.name}" cfg.«namespace» do
    let t ← authorityTextP cfg pod p
    let held := containsSubstr t "STAT grant_valid 1"
    let kind := if cfg.replicas > 1 then containsSubstr t "STAT members_mode replicated" && containsSubstr t "STAT grant_solo 0"
      else containsSubstr t "STAT grant_solo 1"
    if held && kind then return some pod
  return none

def grantedPod (cfg : ClusterConfig) : IO (Option String) := grantedPodOf cfg 0

/-- Every partition's master holds its grant. -/
def waitAuthority (cfg : ClusterConfig) (secs : Nat) : IO Bool :=
  waitForCondition "every partition's master holds a valid write grant (the operator established the membership)" secs do
    for p in List.range cfg.partitions do
      if (← grantedPodOf cfg p).isNone then return false
    return true

def waSetup (cfg : ClusterConfig) : IO Unit := do
  deployCluster cfg
  IO.sleep 50000
  if !(← waitAuthority cfg 240) then
    throw (IO.userError "the write authority was not established on any master within 240 s of the cluster start")

/-! ## A, D, B, B', C, C' with the authority ON -/

def drainWaSuite : TestSuite :=
  let cfg := { waCfg "node-drain-wa" true false with evictionGuard := true }
  { name := "node-ops-drain-wa"
    setup := waSetup cfg
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(A, authority ON) standard kubectl drain of the MASTER's worker under continuous writes: the promotion goes through the intent (prepare -> successor's promise over -> terminal commit); every acknowledged write is on the new master and on the replica rebuilt elsewhere"
        run := FlareOperator.E2E.Tests.NodeOps.drainTest { cfg, suite := "node-ops-drain-wa", test := "a-master" } true },
      { name := "(A', authority ON) drain of the REPLICA's worker: the master stays and keeps acknowledging (the successor set shrinks first)"
        run := FlareOperator.E2E.Tests.NodeOps.drainTest { cfg, suite := "node-ops-drain-wa", test := "a-replica" } false }
    ] }

def holdWaSuite : TestSuite :=
  let cfg := { waCfg "node-hold-wa" true false with evictionGuard := true }
  { name := "node-ops-hold-wa"
    setup := waSetup cfg
    teardown := do
      for w in ← dataWorkers do uncordon w
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(#3, authority ON) four FIRST evictions at once: all refused, exactly one request recorded"
        run := FlareOperator.E2E.Tests.NodeOps.concurrentTest { cfg, suite := "node-ops-hold-wa", test := "concurrent" } },
      { name := "(D, authority ON) the replica is cut off and behind; the drain of the master's worker is HELD (no intent is committed for a successor that is behind)"
        run := FlareOperator.E2E.Tests.NodeOps.holdTest { cfg, suite := "node-ops-hold-wa", test := "d-behind" } }
    ] }

def stopWaSuite : TestSuite :=
  let pvc := waCfg "node-stop-wa" false true
  let tmp := waCfg "node-stop-wa-t" true false
  { name := "node-ops-stop-wa"
    setup := waSetup pvc
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
      { name := "(B, authority ON) the master's worker stops (PVC) and comes back with its data: the replica is promoted through the intent after its promise to the dead master expired, the returning copy does not displace it"
        run := FlareOperator.E2E.Tests.NodeOps.stopTest { cfg := pvc, suite := "node-ops-stop-wa", test := "b-return" } true },
      { name := "(B', authority ON) the master's worker stops and its tmpfs copy is gone: the replica is promoted; the copy is rebuilt on the spare worker"
        run := do
          cleanupCluster pvc
          waSetup tmp
          FlareOperator.E2E.Tests.NodeOps.stopTest { cfg := tmp, suite := "node-ops-stop-wa", test := "b-replace" } false }
    ] }

def partitionWaSuite : TestSuite :=
  let cfg := waCfg "node-part-wa" true false
  { name := "node-ops-partition-wa"
    setup := waSetup cfg
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(C, authority ON) master<->replica and operator<->master cut, both pods Ready: no failover; the master's grant lapses by itself (it hears no promise), nothing acknowledged is lost after the heal"
        run := FlareOperator.E2E.Tests.NodeOps.partitionTestWa { cfg, suite := "node-ops-partition-wa", test := "c-links" } false },
      { name := "(C', authority ON) the master's worker is also cut from the control plane while the client still reaches it: ZERO interval in which both the old and the new master acknowledge (judged on the acknowledgements; unclassified acks make the check stricter); no failover / no new-master ack = NOT VERIFIED, never green"
        run := FlareOperator.E2E.Tests.NodeOps.partitionTestWa { cfg, suite := "node-ops-partition-wa", test := "c-node" } true }
    ] }

/-- The existing failover suite (2 partitions x 2 copies, the master pod of P0 is killed) with the
    write authority ON: the promotion goes through the promotion intent, within a longer bound. -/
def failoverWaSuite : TestSuite :=
  let cfg : ClusterConfig := { FlareOperator.E2E.Tests.Failover.cfg with
    name := "failover-wa", «namespace» := "flare-failover-wa", debugPod := "debug-failover-wa",
    -- the write authority needs a persistent copy id: flared refuses to start on the default tch
    -- storage (flared.cc "write-authority-enabled needs a storage with a persistent copy id"), the
    -- pod crash-loops and the StatefulSet never rolls out (39927148972: "cluster did not stabilize")
    storageBackend := "rocksdb",
    extraFlaredConf := "write-authority-enabled = true\nwrite-authority-margin-ms = 5000\nwrite-authority-max-ttl-ms = 6000",
    operatorEnv := waOperatorEnv }
  FlareOperator.E2E.Tests.Failover.mkSuite "failover-wa" cfg
    (do if !(← waitAuthority cfg 240) then throw (IO.userError "the write authority was not established on every partition's master"))
    240

/-! ## operator absent, solo -/

private def debugEpoch (c : Ctx) : IO (Option Nat) := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» "date +%s" with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

private def operatorGone (cfg : ClusterConfig) : IO Bool :=
  waitForCondition "the operator pod is gone" 120 do
    return (← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»).isEmpty

private def operatorBack (cfg : ClusterConfig) : IO Unit := do
  discard <| kubectlScale "deployment" cfg.operatorName cfg.«namespace» 1
  discard <| waitForCondition "the operator pod is back" 180 do
    return !(← getPodNames s!"app={cfg.operatorName}" cfg.«namespace»).isEmpty

/-- Writes to `ip` for `secs`; the replies whose request ended inside [from, to]. -/
private def windowReplies (ws : List WriteRec) (a b : Nat) : List WriteRec :=
  ws.filter fun w => w.span.1 ≥ a && w.span.2 ≤ b

private def replyVerdict (what : String) (ws : List WriteRec) (minAcks : Nat) : Option String :=
  let acks := ws.filter fun w => classify w.reply == .ack
  let errs := ws.filter fun w => classify w.reply == .error
  let unobs := ws.filter fun w => classify w.reply == .unobserved
  if !errs.isEmpty then
    some s!"{what}: {errs.length} write(s) were refused or failed while the authority should hold (first reply {(errs.head?.map (·.reply)).getD "?"}); acks {acks.length}"
  else if !unobs.isEmpty then
    some (unobservable s!"{what}: {unobs.length} write(s) got no reply (acks {acks.length}): not counted as a product failure")
  else if acks.length < minAcks then
    some (unobservable s!"{what}: only {acks.length} acknowledged write(s) in the window (need {minAcks}): the writer did not run long enough to show it")
  else none

private def absentRun (c : Ctx) (what : String) : IO TestResult := do
  if !(← waitAuthority c.cfg 240) then return .fail (notSetUp "no master holds a write grant")
  let some masterPod ← grantedPod c.cfg | return .fail (notSetUp "the granted pod vanished")
  let some ip ← getPodIp masterPod c.cfg.«namespace» | return .fail (notSetUp "the master's address cannot be read")
  c.conditions [s!"{what}: the master {masterPod} ({ip}) holds a grant; the operator is scaled to 0 while a writer keeps writing to the master"]
  if !(← c.startWriter "w" ip "wa") then return .fail (notSetUp "the writer did not start")
  IO.sleep 20000
  match ← kubectlScale "deployment" c.cfg.operatorName c.cfg.«namespace» 0 with
  | .error e => do
    discard <| c.stopWriter "w"
    return .fail (notSetUp s!"the operator could not be scaled to 0: {e}")
  | .ok _ =>
    if !(← operatorGone c.cfg) then
      discard <| c.stopWriter "w"
      operatorBack c.cfg
      return .fail (notSetUp "the operator pod did not go away")
    let some tGone ← debugEpoch c | do discard <| c.stopWriter "w"; operatorBack c.cfg; return .fail (notSetUp "the debug pod's clock cannot be read")
    -- 10 x the ttl with no operator: every renewal comes from the master <-> replica promise
    IO.sleep 60000
    let some tEnd ← debugEpoch c | do discard <| c.stopWriter "w"; operatorBack c.cfg; return .fail (notSetUp "the debug pod's clock cannot be read")
    let after ← authorityText c.cfg masterPod
    let wl? ← c.stopWriter "w"
    operatorBack c.cfg
    let some wl := wl? | return .fail (unobservable "the writer's record could not be read or failed its integrity check")
    c.art "report.txt" s!"{what}: writes {wl.ws.length}, window {tGone}..{tEnd}, authority after: {after.replace "\r\n" " "}"
    let win := windowReplies wl.ws tGone tEnd
    match replyVerdict what win 20 with
    | some why => return .fail why
    | none =>
      if !containsSubstr after "STAT grant_valid 1" then
        return .fail s!"{what}: the grant was not valid at the end of the operator-less window ({after.replace "\r\n" " "})"
      else return .pass

def operatorAbsentSuite : TestSuite :=
  let cfg := { waCfg "wa-absent" true false with multiNode := false }
  { name := "write-authority-operator-absent"
    setup := waSetup cfg
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(R4) the operator is scaled to 0 while writes continue: for 60 s (10 x the grant ttl) every write to the master is acknowledged, and the grant is still valid at the end — the master's authority comes from its successor's promise, not from the operator"
        run := absentRun { cfg, suite := "write-authority-operator-absent", test := "operator-absent" } "operator absent" }
    ] }

/-! ## two failovers in a row -/

/-- Seconds before / after an ack's span in which the map master must not have changed for the ack to be
    attributed (the observer samples every second). -/
def attributionGuard : Nat := 2

/-- The node that APPLIED an acknowledged write: the map master of the observer's samples, when it is
    the same pod in the nearest sample before the write's span and in every sample from
    `span.1 - guard` to `span.2 + guard`. A local ack of the target and an ack forwarded by it are
    both applied by that master. While the master changes, is unknown, or no sample precedes the
    write (a failover window), the applier cannot be told: `none`. (The operator's map is the only
    reading of "who is master" the observer has; a node that wrongly thinks it is master is not seen.) -/
def ackApplier (samples : List (Nat × Option String × List (String × String))) (w : WriteRec) :
    Option String :=
  match (samples.filter fun (t, _, _) => t ≤ w.span.1).getLast? with
  | none => none
  | some (_, none, _) => none
  | some (_, some m, _) =>
    let near := samples.filter fun (t, _, _) => t + attributionGuard ≥ w.span.1 && t ≤ w.span.2 + attributionGuard
    if near.all fun (_, mm, _) => mm == some m then some m else none

/-- Two acknowledgements whose processing intervals overlap and whose appliers differ (`dual`); and
    every acknowledged write whose applier cannot be attributed (`unattributed`). -/
def ackOverlaps (samples : List (Nat × Option String × List (String × String))) (ws : List WriteRec) :
    List (WriteRec × WriteRec) × List WriteRec :=
  let acks := ws.filter fun w => classify w.reply == .ack
  let att := acks.filterMap fun w => (ackApplier samples w).map (w, ·)
  let unatt := acks.filter fun w => (ackApplier samples w).isNone
  let pairs := att.flatMap fun (a, pa) => att.filterMap fun (b, pb) =>
    if pa != pb && a.span.2 ≥ b.span.1 && b.span.2 ≥ a.span.1 && a.t ≤ b.t then some (a, b) else none
  (pairs, unatt)

/-- The verdict on the acknowledgements of the two-failovers run: an overlap of different appliers is a
    PRODUCT GAP; any ack that cannot be attributed to the node that applied it makes the run NOT
    VERIFIED (never green). `none`: every ack attributed and no overlap. -/
def ackVerdict (samples : List (Nat × Option String × List (String × String))) (ws : List WriteRec) :
    Option String :=
  let (dual, unatt) := ackOverlaps samples ws
  match dual.head? with
  | some (a, b) =>
    some s!"PRODUCT GAP (dual acknowledgement over two failovers, authority ON): acks of two nodes overlap ({a.ip} {a.span} / {b.ip} {b.span}); {dual.length} overlapping pair(s)"
  | none =>
    match unatt.head? with
    | some w => some s!"NOT VERIFIED: {unatt.length} acknowledgement(s) cannot be attributed to the node that applied them (the map master changed or was unknown around them, e.g. {w.ip} {w.span}): an overlap cannot be ruled out"
    | none => none

private def killPod (c : Ctx) (pod : String) : IO Unit := do
  c.event s!"killing {pod} (force)"
  discard <| kubectl ["delete", "pod", pod, "-n", c.cfg.«namespace», "--force", "--grace-period=0"]

/-- A writer on every pod that has an address now. -/
private def writersOnPods (c : Ctx) (phase : String) : IO (List String) := do
  let mut names : List String := []
  for p in (← c.pods).getD [] do
    if !p.ip.isEmpty then
      let n := s!"{phase}-{p.name}"
      if ← c.startWriter n p.ip "tf" then names := names ++ [n]
  return names

private def twoFailoversRun (c : Ctx) : IO TestResult := do
  if !(← waitAuthority c.cfg 240) then return .fail (notSetUp "no master holds a write grant")
  let some m1 ← grantedPod c.cfg | return .fail (notSetUp "the granted pod vanished")
  let obs ← startObserver c.sample 1000
  let mut names ← writersOnPods c "p1"
  IO.sleep 15000
  -- first failover
  killPod c m1
  let ok1 ← waitForCondition "a pod other than the killed master holds the grant (failover 1)" 300 do
    return (← grantedPod c.cfg).any (· != m1)
  let some m2 ← grantedPod c.cfg | return .fail (notSetUp "failover 1: no grant holder")
  c.event s!"failover 1 done: {m1} -> {m2} (completed {ok1})"
  if !ok1 || m2 == m1 then
    discard <| obs.finish
    for n in names do discard <| c.stopWriter n
    return .fail "failover 1 did not complete (no other pod holds a grant within 300 s)"
  names := names ++ (← writersOnPods c "p2")
  IO.sleep 8000
  -- The second kill must not hit the window between the promotion commit and the operator's adoption
  -- of the new master's history: a master lost with its intent unresolved holds the partition
  -- (AuthoritativeHistory.resolveIntent, "is not the master in the map that carries the intent": the
  -- acknowledged writes of that master are unknown, nothing is promoted automatically; RUNBOOK
  -- #history-held-masterless). That hold is the product's safety stop, not the property under test
  -- (39927148972: commit 09:37:47, the operator lease lapsed during a 20 s reconcile, the kill came
  -- at ~09:38:05, HELD for good). Wait for the adoption; if it does not come the run has no
  -- precondition, not a verdict.
  let adopted ← waitForCondition "the operator adopted the new master's history (the promotion intent is resolved)" 180 do
    return containsSubstr (← kubectlLogsLabel s!"app={c.cfg.operatorName}" c.cfg.«namespace» 10000000) s!"adopted as generation"
  if !adopted then
    discard <| obs.finish
    for n in names do discard <| c.stopWriter n
    return .fail (notSetUp s!"the operator did not adopt {m2}'s history within 180 s of its promotion (the second failover would meet an unresolved promotion intent)")
  -- second failover, in a row (the previous master's copy is still being rebuilt)
  killPod c m2
  let ok2 ← waitForCondition "a pod other than the second killed master holds the grant (failover 2)" 300 do
    return (← grantedPod c.cfg).any (· != m2)
  let m3 := (← grantedPod c.cfg).getD "none"
  c.event s!"failover 2: {m2} -> {m3} (completed {ok2})"
  names := names ++ (← writersOnPods c "p3")
  IO.sleep 20000
  let samples ← match ← obs.finish with
    | .ok l => pure l
    | .error e => do
      for n in names do discard <| c.stopWriter n
      return .fail (unobservable e)
  let mut ws : List WriteRec := []
  let mut complete := true
  for n in names do
    match ← c.stopWriter n with
    | some wl => ws := ws ++ wl.ws; complete := complete && wl.complete
    | none => complete := false
  c.art "report.txt" s!"masters {m1} -> {m2} -> {m3}; writes {ws.length}; acks {(ws.filter fun w => classify w.reply == .ack).length}"
  -- a failover that did not complete is the finding, whatever the writer logs of the dead window say
  -- (a writer that never got an ack is rejected as unobserved and would mask it as UNOBSERVABLE)
  if !ok2 then return .fail s!"the second failover did not complete: no pod other than {m2} holds a grant within 300 s (a prepare is stuck, or the partition is held: see the operator log); writer logs complete: {complete} ({names.length} writers)"
  if !complete then return .fail (unobservable "a writer log was not confirmed complete")
  let verdict := ackVerdict samples ws
  if let some v := verdict then
    if v.startsWith "PRODUCT GAP" then return .fail v
  let after := (ws.filter fun w => classify w.reply == .ack && pathOf samples w == "local" && w.ip != "").filter fun w =>
    ((samples.filter fun (t, _, _) => t ≤ w.t).getLast?.bind fun (_, _, ips) => ips.lookup w.ip) == some m3
  if after.isEmpty then
    return .fail (unobservable s!"the third master {m3} never acknowledged a local write in the observed window")
  if let some v := verdict then return .fail v
  return .pass

def twoFailoversSuite : TestSuite :=
  let cfg := { waCfg "wa-two" true false with multiNode := false, partitions := 1, replicas := 3 }
  { name := "write-authority-two-failovers"
    setup := waSetup cfg
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(two failovers in a row, authority ON) the master pod is killed, and the new master is killed as soon as it holds its grant: no interval in which two pods acknowledge locally, and the second failover completes (a pod other than the killed one holds a valid grant; the new master acknowledges)"
        run := twoFailoversRun { cfg, suite := "write-authority-two-failovers", test := "two-failovers" } }
    ] }

def soloSuite : TestSuite :=
  let cfg := { waCfg "wa-solo" true false with multiNode := false, replicas := 1 }
  { name := "write-authority-solo"
    setup := waSetup cfg
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(R1) a partition whose authoritative membership has no successor keeps serving: the master reports a solo grant and every write is acknowledged, also with the operator scaled to 0"
        run := do
          let c : Ctx := { cfg, suite := "write-authority-solo", test := "solo" }
          let some masterPod ← grantedPod cfg | return .fail (notSetUp "no master holds a write grant")
          let st ← authorityText cfg masterPod
          if !(containsSubstr st "STAT members_mode solo" && containsSubstr st "STAT grant_solo 1") then
            return .fail s!"the single copy is not under a solo grant: {st.replace "\r\n" " "}"
          absentRun c "solo, operator absent" }
    ] }

end FlareOperator.E2E.Tests.WriteAuthority
