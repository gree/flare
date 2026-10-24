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
    write-authority-sole-lagging : the master pod is killed twice; the copy that became Active after the
                           first failover is NOT in the membership record (operator test seam
                           FLARE_TEST_HOLD_MEMBER_ADD_FILE) and the only member is unpromotable: it is
                           promoted by FENCING the old master with a record member's expired promise
                           (logged NOT LOSS-FREE); no dual grant / acknowledgement, data check with
                           the loss window reported
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
import Std.Data.HashMap

namespace FlareOperator.E2E.Tests.WriteAuthority

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl
open FlareOperator.E2E.Tests.NodeOps (Reading maxBracketSec)

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

/-- Lines of `text` that mention one of `words` (case-insensitive), printed as comments. -/
private def printMatching (title : String) (text : String) (words : List String) (limit : Nat) : IO Unit := do
  let hit := (text.splitOn "\n").filter fun l => words.any fun w => containsSubstr l.toLower w
  IO.eprintln s!"# --- {title}: {hit.length} matching line(s), last {min limit hit.length} ---"
  for l in hit.drop (hit.length - min limit hit.length) do IO.eprintln s!"# {l}"

/-- A setup that did not reach a valid grant leaves no other trace (the framework runs no onFailure hook for
    a failed setup, and the namespace is deleted at once): print everything that tells where the chain
    stopped — every pod's `authority status` for every partition (grant / members / promise state), the
    operator's membership deliveries and promise-round lines, the flared nodes' own authority lines — and
    save the full pod logs. (39936446464: "no valid grant within 240 s" could not be diagnosed.) -/
def waSetupDiagnostics (cfg : ClusterConfig) : IO Unit := do
  let ns := cfg.«namespace»
  IO.eprintln s!"# === write authority setup diagnostics ({ns}) ==="
  try
    for pod in ← getPodNames s!"cluster={cfg.name}" ns do
      for p in List.range cfg.partitions do
        let t ← authorityTextP cfg pod p
        IO.eprintln s!"# authority status {p} on {pod}: {t.replace "\r\n" " | " |>.replace "\n" " | "}"
    saveFullLogs ns "setup-failure"
    let op ← kubectlLogsLabel s!"app={cfg.operatorName}" ns 20000
    printMatching "operator: membership deliveries / promise rounds / write authority" op
      ["write authority", "membership", "promise", "grant", "first-build", "promotion", "authoritative history", "critical", "history state", "rebuild held", "adopted", "first master"] 150
    for pod in ← getPodNames s!"cluster={cfg.name}" ns do
      match ← kubectl ["logs", "-n", ns, pod, "--tail=-1"] with
      | .ok o => printMatching s!"{pod}: authority lines" o ["authority", "membership", "promise", "grant"] 40
      | .error e => IO.eprintln s!"# {pod}: logs unavailable: {e}"
  catch e => IO.eprintln s!"# setup diagnostics failed: {e}"

def waSetup (cfg : ClusterConfig) : IO Unit := do
  deployCluster cfg
  IO.sleep 50000
  if !(← waitAuthority cfg 240) then
    waSetupDiagnostics cfg
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
  let cfg0 := waCfg "node-part-wa" true false
  -- flared logs one line per applied mutation (write-authority-trace, tests only): attributes the acks forwarded
  -- through the replica inside the cut and dates the old master's last write against its grant
  let cfg := { cfg0 with extraFlaredConf := cfg0.extraFlaredConf ++ "\nwrite-authority-trace = true" }
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

/-- The setup predicate of failover-wa, sampled continuously from the seed start: every partition has an
    ACTIVE master in the operator's map AND that master holds the replicated grant (members_mode replicated,
    grant valid, not solo) — the same pod. `none` = holds. -/
def failoverWaSeedGuard (cfg : ClusterConfig) : IO (Option String) := do
  let sync ← operatorTcpCmd cfg.debugPod cfg.«namespace» cfg.operatorName cfg.operatorPort "node sync"
  let entries := parseNodeSync sync
  for p in List.range cfg.partitions do
    match findMasterPod entries p with
    | none => return some s!"P{p} has no Active master in the map"
    | some m =>
      match ← grantedPodOf cfg p with
      | none => return some s!"P{p}: no pod holds the replicated grant (map master {m})"
      | some g => if g != m then return some s!"P{p}: the replicated grant is held by {g}, the map master is {m}"
  return none

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
    (do if !(← waitAuthority cfg 240) then
          waSetupDiagnostics cfg
          throw (IO.userError "the write authority was not established on every partition's master"))
    240 (some (failoverWaSeedGuard cfg))

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

/-- The same view over [a, b] from the node's OWN readings (see `ownViewOver`: the strict bracket). -/
def ownViewOverR (rs : List Reading) (pod : String) (a b : Nat) : Option OwnV :=
  let rs := rs.filter (·.pod == pod)
  match (rs.filter (·.te < a)).getLast?, (rs.filter (·.ts > b)).head? with
  | some x, some y =>
    if y.ts - x.te > maxBracketSec then none else
    let between := rs.filter fun r => r.te ≥ x.ts && r.ts ≤ y.te
    match x.view with
    | some v => if between.all (·.view == some v) then some v else none
    | none => none
  | _, _ => none

/-- The node that applied an acknowledged write, from the NODES' OWN role readings (not the operator's
    map): the pod that answered (`target`, from the address) was master by its own view over the whole
    span of the write -> it applied it; it was NOT master by its own view over the whole span, and exactly
    one other pod was master by its own view over the span while every other pod's view over it is
    known and not master -> that pod applied the forwarded write. Anything else (a view that changed or
    cannot be bracketed, a second pod that may have been master) is `none`: never guessed. -/
def ownApplier (rs : List Reading) (pods : List String) (target : Option String) (w : WriteRec) : Option String :=
  match target with
  | none => none
  | some t =>
    match ownViewOverR rs t w.span.1 w.span.2 with
    | none => none
    | some v =>
      if v.role == "master" then some t
      else
        let st := (pods.filter (· != t)).map fun p => (p, (ownViewOverR rs p w.span.1 w.span.2).map (·.role))
        match st.filter (·.2 == some "master") with
        | [(u, _)] => if st.all (·.2.isSome) then some u else none
        | _ => none

/-- The applier of an ack: the map master (`ackApplier`) and the nodes' own readings (`ownApplier`, only with
    readings) — either attributes; both attributing to different nodes is no attribution (never a pick). -/
def ackApplierBoth (samples : List (Nat × Option String × List (String × String))) (rs : List Reading)
    (pods : List String) (w : WriteRec) (trace : Std.HashMap String (List String) := {}) : Option String :=
  match trace.get? w.key with
  | some [p] => some p
  | some (_ :: _ :: _) => none      -- two pods applied this key as the master: never a pick
  | _ =>
  let byMap := ackApplier samples w
  if rs.isEmpty then byMap else
  let target := ((samples.filter fun (t, _, _) => t ≤ w.span.1).getLast?).bind fun (_, _, ips) => ips.lookup w.ip
  match byMap, ownApplier rs pods target w with
  | some a, some b => if a == b then some a else none
  | some a, none => some a
  | none, some b => some b
  | none, none => none

/-- Two acknowledgements whose processing intervals overlap and whose appliers differ (`dual`, found by a
    sweep over the start times: one witness per later ack); and every acknowledged write whose applier cannot
    be attributed (`unattributed`). `own` = the nodes' own role readings (empty: the map only). -/
def ackOverlaps (samples : List (Nat × Option String × List (String × String))) (ws : List WriteRec)
    (own : List Reading := []) (trace : Std.HashMap String (List String) := {}) :
    List (WriteRec × WriteRec) × List WriteRec :=
  let pods := (own.map (·.pod)).eraseDups
  let acks := ws.filter fun w => classify w.reply == .ack
  let ap := acks.map fun w => (w, ackApplierBoth samples own pods w trace)
  let att := ap.filterMap fun (w, a) => a.map (w, ·)
  let unatt := ap.filterMap fun (w, a) => if a.isNone then some w else none
  -- per applier, the attributed ack that ends last so far; an ack that starts no later than it ends
  -- overlaps it (every earlier ack started no later)
  let sorted := att.toArray.qsort fun (a, _) (b, _) => a.span.1 < b.span.1
  let (pairs, _) := sorted.foldl (init := (([] : List (WriteRec × WriteRec)), ([] : List (String × WriteRec))))
    fun (acc, ends) (b, pb) =>
      let hits := ends.filterMap fun (p, a) => if p != pb && a.span.2 ≥ b.span.1 then some (a, b) else none
      let ends' := match ends.lookup pb with
        | some a => if a.span.2 ≥ b.span.2 then ends else (pb, b) :: ends.filter (·.1 != pb)
        | none => (pb, b) :: ends
      (hits ++ acc, ends')
  (pairs, unatt)

/-- The verdict on the acknowledgements of the two-failovers run: an overlap of different appliers is a
    PRODUCT GAP; any ack that cannot be attributed to the node that applied it makes the run NOT
    VERIFIED (never green). `none`: every ack attributed and no overlap. -/
def ackVerdict (samples : List (Nat × Option String × List (String × String))) (ws : List WriteRec)
    (own : List Reading := []) (trace : Std.HashMap String (List String) := {}) : Option String :=
  let (dual, unatt) := ackOverlaps samples ws own trace
  match dual.head? with
  | some (a, b) =>
    some s!"PRODUCT GAP (dual acknowledgement over two failovers, authority ON): acks of two nodes overlap ({a.ip} {a.span} / {b.ip} {b.span}); {dual.length} overlapping ack(s)"
  | none =>
    match unatt.head? with
    | some w => some s!"NOT VERIFIED: {unatt.length} acknowledgement(s) cannot be attributed to the node that applied them (neither the write trace of any flared, the map master, nor the nodes' own role readings over the write name one applier, e.g. {w.ip} {w.span} key {w.key}; trace lines for it: {((trace.get? w.key).getD []).length}): an overlap cannot be ruled out"
    | none => none

/-- One reading round of every pod's own view (the debug pod's clock), for the attribution. -/
private def tfOwn (c : Ctx) : IO (List Reading) := do
  let mut out : List Reading := []
  for p in (← c.pods).getD [] do
    if !p.ip.isEmpty then
      match ← c.statsTimed p.ip with
      | some (a, b, o) => out := out ++ [{ pod := p.name, ts := a, te := b, view := o.bind ownVOf }]
      | none => pure ()
  return out

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
  -- the nodes' own role readings (every pod's own view, timed on the writers' clock): the second source of
  -- who applied an ack, where the operator's map does not say (its master changed / unknown around it)
  let ownObs ← startObserver (tfOwn c) 1000
  -- the write trace of every flared (direct per-request evidence of the applier), streamed while it runs
  let traceFollow ← startTraceFollow c ((← c.pods).getD [] |>.map (·.name))
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
    discard <| ownObs.finish
    discard <| stopTraceFollow traceFollow
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
    discard <| ownObs.finish
    discard <| stopTraceFollow traceFollow
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
      discard <| ownObs.finish
      discard <| stopTraceFollow traceFollow
      for n in names do discard <| c.stopWriter n
      return .fail (unobservable e)
  let own ← match ← ownObs.finish with
    | .ok l => pure (l.flatMap id)
    | .error e => do
      discard <| stopTraceFollow traceFollow
      for n in names do discard <| c.stopWriter n
      return .fail (unobservable s!"own-view observer: {e}")
  let mut ws : List WriteRec := []
  let mut complete := true
  for n in names do
    match ← c.stopWriter n with
    | some wl => ws := ws ++ wl.ws; complete := complete && wl.complete
    | none => complete := false
  IO.sleep 1500
  let traceLines ← stopTraceFollow traceFollow
  let trace := traceIndex traceLines
  let acks := ws.filter fun w => classify w.reply == .ack
  let byTrace := acks.filter fun w => (traceApplier trace w).isSome
  let twoAppliers := acks.filter fun w => ((trace.get? w.key).getD []).length > 1
  let (_, unattributed) := ackOverlaps samples ws own trace
  let (_, unattNoTrace) := ackOverlaps samples ws own
  let (_, unattByMap) := ackOverlaps samples ws
  c.art "report.txt" s!"masters {m1} -> {m2} -> {m3}; writes {ws.length}; acks {acks.length}; write-trace lines {traceLines.length} (keys {trace.size}); acks attributed by the write trace {byTrace.length}, applied as master by two pods {twoAppliers.length}; unattributed: by the map alone {unattByMap.length}, with the own role readings {unattNoTrace.length} ({own.length} readings), with the trace as well {unattributed.length}"
  c.event s!"attribution: {acks.length} acks, {byTrace.length} by the write trace ({traceLines.length} trace lines), {unattributed.length} unattributed (map+own alone: {unattNoTrace.length})"
  -- a failover that did not complete is the finding, whatever the writer logs of the dead window say
  -- (a writer that never got an ack is rejected as unobserved and would mask it as UNOBSERVABLE)
  if !ok2 then return .fail s!"the second failover did not complete: no pod other than {m2} holds a grant within 300 s (a prepare is stuck, or the partition is held: see the operator log); writer logs complete: {complete} ({names.length} writers)"
  if !complete then return .fail (unobservable "a writer log was not confirmed complete")
  let verdict := ackVerdict samples ws own trace
  if let some v := verdict then
    if v.startsWith "PRODUCT GAP" then return .fail v
  let after := (ws.filter fun w => classify w.reply == .ack && pathOf samples w == "local" && w.ip != "").filter fun w =>
    ((samples.filter fun (t, _, _) => t ≤ w.t).getLast?.bind fun (_, _, ips) => ips.lookup w.ip) == some m3
  if after.isEmpty then
    return .fail (unobservable s!"the third master {m3} never acknowledged a local write in the observed window")
  if let some v := verdict then return .fail v
  return .pass

def twoFailoversSuite : TestSuite :=
  let cfg0 := { waCfg "wa-two" true false with multiNode := false, partitions := 1, replicas := 3 }
  -- flared logs one line per applied mutation (write-authority-trace, tests only): the direct evidence of the applier
  let cfg := { cfg0 with extraFlaredConf := cfg0.extraFlaredConf ++ "\nwrite-authority-trace = true" }
  { name := "write-authority-two-failovers"
    setup := waSetup cfg
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(two failovers in a row, authority ON) the master pod is killed, and the new master is killed as soon as it holds its grant: no interval in which two pods acknowledge locally, and the second failover completes (a pod other than the killed one holds a valid grant; the new master acknowledges)"
        run := twoFailoversRun { cfg, suite := "write-authority-two-failovers", test := "two-failovers" } }
    ] }


/-! ## the sole lagging copy that is not yet a member of the record -/

/-- A shell line in the operator's pod (the test seam files live there). -/
private def opShell (c : Ctx) (cmd : String) : IO (Except String String) := do
  match (← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»).head? with
  | none => return .error "no operator pod"
  | some pod => kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", cmd]

/-- The authoritative membership record of partition 0 (the ConfigMap's `data.record`). -/
private def membersRecord (c : Ctx) : IO (Option String) := do
  match ← kubectl ["get", "configmap", s!"{c.cfg.name}-authority-p0", "-n", c.cfg.«namespace», "-o", "jsonpath={.data.record}"] with
  | .ok o => return some o.trim
  | .error _ => return none

/-- `pod` is a SUCCESSOR of the record (`succ=k1,k2` names node keys `pod.service...:port`). -/
private def recordHasSuccessor (record pod : String) : Bool :=
  (record.splitOn " ").any fun w => w.startsWith "succ=" && ((w.drop 5).splitOn ",").any (·.startsWith s!"{pod}.")

private def recordMasterIs (record pod : String) : Bool :=
  (record.splitOn " ").any fun w => w.startsWith "master=" && (w.drop 7).startsWith s!"{pod}."

/-- seconds an acknowledgement before the second kill may still be missing: the grant ttl + the margin -/
def soleWindowSec : Nat := 11

def soleLaggingRun (c : Ctx) : IO TestResult := do
  let ns := c.cfg.«namespace»
  if !(← waitAuthority c.cfg 240) then return .fail (notSetUp "no master holds a write grant")
  let some m1 ← grantedPod c.cfg | return .fail (notSetUp "the granted pod vanished")
  let obs ← startObserver c.sample 1000
  let ownObs ← startObserver (tfOwn c) 1000
  let traceFollow ← startTraceFollow c ((← c.pods).getD [] |>.map (·.name))
  let mut names ← writersOnPods c "p1"
  let stopAll := fun (ns' : List String) => do
    discard <| obs.finish
    discard <| ownObs.finish
    discard <| stopTraceFollow traceFollow
    for n in ns' do discard <| c.stopWriter n
  IO.sleep 15000
  -- from here newly eligible successors are not added to the record (the operator's test seam): a copy
  -- that becomes Active after failover 1 stays a non-member
  if let .error e ← opShell c "touch /tmp/holdadd" then
    stopAll names
    return .fail (notSetUp s!"could not arm the member-add hold in the operator pod: {e}")
  let adoptedBefore := ((← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 10000000).splitOn "adopted as generation").length
  let k1 ← epochNow
  killPod c m1
  let ok1 ← waitForCondition "a pod other than the killed master holds the grant (failover 1)" 300 do
    return (← grantedPod c.cfg).any (· != m1)
  let some m2 ← grantedPod c.cfg | do stopAll names; return .fail (notSetUp "failover 1: no grant holder")
  c.event s!"failover 1 done: {m1} -> {m2} (completed {ok1})"
  if !ok1 || m2 == m1 then
    stopAll names
    return .fail "failover 1 did not complete (no other pod holds a grant within 300 s)"
  names := names ++ (← writersOnPods c "p2")
  let r := ((← c.pods).getD [] |>.map (·.name)).find? fun p => p != m1 && p != m2
  let some r := r | do stopAll names; return .fail (notSetUp "the third pod is not known")
  -- The second kill must not hit the window between the promotion commit and the operator's adoption of
  -- the new master's history (an unresolved promotion intent holds the partition: the product's safety
  -- stop, not the property under test; same wait as two-failovers). The hold file keeps m1 out of the
  -- record meanwhile. Count the adoption AFTER the first kill: the start-up adoption is in the log already.
  let adopted ← waitForCondition "the operator adopted the new master's history (the promotion intent is resolved)" 180 do
    return ((← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 10000000).splitOn "adopted as generation").length > adoptedBefore
  if !adopted then
    stopAll names
    return .fail (notSetUp s!"the operator did not adopt {m2}'s history within 180 s of its promotion (the second failover would meet an unresolved promotion intent)")
  -- the window of the gap: the old master's copy m1 is Active (a data copy, same history) but NOT a member of the
  -- record; the only member r is a live proxy held by replica repair (unpromotable). Then the new master dies.
  let mut ready := false
  let mut lastState := ""
  for _ in [0:300] do
    let view ← c.nodeView
    let m1Active := view.any fun e => podOfFqdn e.fqdn == m1 && e.role == 1 && e.state == 0
    let rProxy := view.any fun e => podOfFqdn e.fqdn == r && e.role == 2
    let record := (← membersRecord c).getD ""
    let m1Out := !recordHasSuccessor record m1 && recordMasterIs record m2
    lastState := s!"{m1} active slave {m1Active}, {r} proxy {rProxy}, {m1} outside the record {m1Out}, record [{record}]"
    if m1Active && rProxy && m1Out then ready := true; break
    IO.sleep 1000
  if !ready then
    stopAll names
    return .fail (notSetUp s!"the gap was not reached within 300 s of failover 1: {lastState}")
  c.event s!"the gap: {lastState}"
  let k2 ← epochNow
  killPod c m2
  let ok2 ← waitForCondition "a pod other than the second killed master holds the grant (failover 2: the sole lagging copy, fenced)" 300 do
    return (← grantedPod c.cfg).any (· != m2)
  let m3 := (← grantedPod c.cfg).getD "none"
  c.event s!"failover 2: {m2} -> {m3} (completed {ok2})"
  names := names ++ (← writersOnPods c "p3")
  IO.sleep 20000
  let opLog ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 10000000
  let fenced := containsSubstr opLog s!"PROMOTION NOT LOSS-FREE (write authority): {m1}."
  let rec2 ← membersRecord c
  c.art "report.txt" s!"masters {m1} -> {m2} -> {m3}; member {r}; kills at {k1} and {k2}; fence path logged: {fenced}; record at the end [{rec2.getD "?"}]"
  let samples ← match ← obs.finish with
    | .ok l => pure l
    | .error e => do
      discard <| ownObs.finish
      discard <| stopTraceFollow traceFollow
      for n in names do discard <| c.stopWriter n
      return .fail (unobservable e)
  let own ← match ← ownObs.finish with
    | .ok l => pure (l.flatMap id)
    | .error e => do
      discard <| stopTraceFollow traceFollow
      for n in names do discard <| c.stopWriter n
      return .fail (unobservable s!"own-view observer: {e}")
  let mut ws : List WriteRec := []
  let mut complete := true
  for n in names do
    match ← c.stopWriter n with
    | some wl => ws := ws ++ wl.ws; complete := complete && wl.complete
    | none => complete := false
  IO.sleep 1500
  let traceLines ← stopTraceFollow traceFollow
  let trace := traceIndex traceLines
  let acks := ws.filter fun w => classify w.reply == .ack
  let (_, unattributed) := ackOverlaps samples ws own trace
  c.event s!"{acks.length} acks, {(acks.filter fun w => (traceApplier trace w).isSome).length} attributed by the write trace ({traceLines.length} trace lines), {unattributed.length} unattributed"
  if !ok2 then return .fail s!"the second failover did not complete: no pod other than {m2} holds a grant within 300 s — the sole lagging copy {m1} outside the record was not promoted (see the operator log: fence path / gate); fence path logged: {fenced}"
  if !fenced || m3 != m1 then
    return .fail (notSetUp s!"the second failover went another way (the promoted/granted pod is {m3}, the fence path was logged: {fenced}): the sole-lagging path was not exercised")
  if !complete then return .fail (unobservable "a writer log was not confirmed complete")
  -- (i) no dual grant / dual acknowledgement: attributed by the write trace, none unattributed, no overlap of the
  -- old and the new master's acknowledgements
  if let some v := ackVerdict samples ws own trace then return .fail v
  let after := acks.filter fun w => pathOf samples w == "local" && w.ip != "" &&
    ((samples.filter fun (t, _, _) => t ≤ w.t).getLast?.bind fun (_, _, ips) => ips.lookup w.ip) == some m3
  if after.isEmpty then
    return .fail (unobservable s!"the new master {m3} never acknowledged a local write in the observed window")
  -- (ii) data: every write acknowledged before (kill - ttl - margin) of either kill is on the final master;
  -- an acknowledgement inside such a window that is missing is REPORTED (the loss tolerance is an open decision)
  let some ip := ((← c.pods).getD [] |>.find? (·.name == m3)).map (·.ip) | return .fail (unobservable s!"no address of {m3}")
  let some copy ← c.ownCopy ip | return .fail (unobservable s!"the copy of {m3} could not be read")
  let required := fun (w : WriteRec) => w.t + soleWindowSec < k1 || (k1 ≤ w.t && w.t + soleWindowSec < k2)
  let lostRequired := missingAcks (ws.filter required) copy
  let lostWindow := missingAcks (ws.filter (!required ·)) copy
  for w in lostWindow do
    c.event s!"acknowledged write missing on {m3} inside a loss window (kill 1 at {k1}, kill 2 at {k2}): {w.key} acked at {w.t} (sent {w.t0}) by {w.ip}"
  c.art "report.txt" s!"acks {acks.length}; missing outside the windows {lostRequired.length}; missing inside the windows {lostWindow.length} (reported, not a failure: open decision #13)"
  if let some w := lostRequired.head? then
    return .fail s!"DATA LOSS: {lostRequired.length} acknowledged write(s) are missing on the final master {m3} although acknowledged more than {soleWindowSec} s before a kill (e.g. {w.key} acked at {w.t}; kills at {k1} and {k2}); {lostWindow.length} more inside the loss windows"
  return .pass

def soleLaggingSuite : TestSuite :=
  let cfg0 := { waCfg "wa-sole" true false with multiNode := false, partitions := 1, replicas := 3 }
  let cfg := { cfg0 with extraFlaredConf := cfg0.extraFlaredConf ++ "\nwrite-authority-trace = true",
                         operatorEnv := cfg0.operatorEnv ++ [("FLARE_TEST_HOLD_MEMBER_ADD_FILE", "/tmp/holdadd")] }
  { name := "write-authority-sole-lagging"
    setup := waSetup cfg
    teardown := cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(sole lagging copy, authority ON) the master pod is killed; a copy that becomes Active afterwards is held out of the membership record (test seam) while the only member is unpromotable; the new master is killed: that copy is promoted by FENCING the old master with the member's expired promise (logged NOT LOSS-FREE), a pod other than the killed one holds a grant, and there is no dual grant / dual acknowledgement; every write acknowledged before a kill's loss window is on the final master (acknowledgements inside it that are missing are reported)"
        run := soleLaggingRun { cfg, suite := "write-authority-sole-lagging", test := "sole-lagging" } }
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
