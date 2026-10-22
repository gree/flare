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
