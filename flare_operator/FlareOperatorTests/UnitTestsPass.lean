/-
  UnitTestsPass.lean - checks for flare-operator-slow-reconcile: the per-node
  reads of a gate decision (fresh every decision, concurrent within one), the
  version nudge, the lease keeper and the Service selector patch.
-/
import FlareOperator.Operator.Parallel
import FlareOperator.Operator.FreshGate
import FlareOperator.Operator.LeaseKeeper
import FlareOperator.StateMachine.VersionNudge
import FlareOperator.StateMachine.ServiceSelector

namespace FlareOperator.UnitTestsPass

open FlareOperator.Parallel
open FlareOperator.LeaseKeeper
open FlareOperator.K8s
open FlareOperator.RebuildConcurrency

private def has (h n : String) : Bool := (h.splitOn n).length > 1

private def node (r : FlareRole) (st : FlareState) (p : Int) (nm : String) : FlareNode :=
  { serverName := nm, serverPort := 12121, role := r, state := st, partition := p, lastMasterOf := -1 }

private def stateOf (l : List (String × FlareNode)) : FlareClusterState :=
  ({ nodeMap := l } : FlareClusterState).rebuildPartitionMap

/-- Two gate decisions of ONE pass (the FSM commits twice), each admitting a
    new assignment. `x` is an Active member catching up at boot whose stats the
    map does not show: idle at the first read, a running reconstruction at the
    second. Returns (nodes admitted at gate 1, at gate 2, reads made). -/
private def twoGates : IO (List String × List String × Nat) := do
  let m0 := ("m0", node .Master .Active 0 "m0")
  let x := ("x", node .Slave .Active 0 "x")
  let before1 := stateOf [m0, x, ("a", node .Proxy .Active (-1) "a")]
  let after1 := stateOf [m0, x, ("a", node .Slave .Prepare 0 "a")]
  let before2 := stateOf [m0, x, ("a", node .Proxy .Active (-1) "a"), ("b", node .Proxy .Active (-1) "b")]
  let after2 := stateOf [m0, x, ("a", node .Proxy .Active (-1) "a"), ("b", node .Slave .Prepare 0 "b")]
  let started ← IO.mkRef false
  let reads ← IO.mkRef (0 : Nat)
  -- the observation function: x idle until its reconstruction starts
  let observe (st : FlareClusterState) : IO (List (String × Obs)) := do
    let obs ← Parallel.readFresh (st.nodeMap.map (·.1)) fun k => do
      reads.modify (· + 1)
      pure (if k == "x" && (← started.get) then Obs.running else Obs.idle)
    pure obs
  let admitted := fun (v : FreshGate.Verdict) (k : String) =>
    ((v.decision.state.lookupNode k).map (·.role)) == some FlareRole.Slave
  let v1 ← FreshGate.decide (observe before1) [] before1 after1 1 1
  -- flared starts x's reconstruction between the two gates of the pass
  started.set true
  let v2 ← FreshGate.decide (observe before2) [] before2 after2 1 1
  pure ((if admitted v1 "a" then ["a"] else []), (if admitted v2 "b" then ["b"] else []), ← reads.get)

/-- Read `keys` for `decisions` gate decisions, each reading them together;
    returns (reads made, longest single decision in ms). -/
private def gateReads (keys : List String) (decisions : Nat) (delayMs : UInt32) : IO (Nat × Nat) := do
  let reads ← IO.mkRef (0 : Nat)
  let mut worst := 0
  for _ in [0:decisions] do
    let t0 ← IO.monoMsNow
    let _ ← Parallel.readFresh keys fun _ => do reads.modify (· + 1); IO.sleep delayMs; pure 7
    worst := max worst ((← IO.monoMsNow) - t0)
  pure (← reads.get, worst)

/-- A keeper run on a fake clock: a pass of `passMs` with `periodMs` between
    renews, the API answering `answer t`. Returns (lost reason, the longest
    time the lease went without an accepted renew). -/
private def simulate (passMs periodMs leaseMs deadlineMs : Nat) (answer : Nat → Renewal)
    : IO (Option String × Nat) := do
  let clock ← IO.mkRef (0 : Nat)
  let lastOk ← IO.mkRef (0 : Nat)
  let maxGap ← IO.mkRef (0 : Nat)
  let lost ← IO.mkRef (none : Option String)
  let renew : IO Renewal := do
    let t ← clock.get
    let r := answer t
    if r == .renewed then
      maxGap.modify (max (t - (← lastOk.get)))
      lastOk.set t
    pure r
  let done : IO Bool := do pure ((← clock.get) ≥ passMs || (← lost.get).isSome)
  run renew clock.get (do pure (some 0)) (fun ms => clock.modify (· + ms)) done
    (fun why => lost.set (some why)) leaseMs periodMs deadlineMs 0
  maxGap.modify (max ((← clock.get) - (← lastOk.get)))
  pure (← lost.get, ← maxGap.get)

/-- The first-build wait's keeper handing over to the normal loop. The wait
    ends at t = 0; initialisation (server start, ledger load, ...) takes
    `initMs`; then the normal loop renews once (`loopAnswer`). With
    `handoff` the wait keeper runs until that renew was accepted
    (`handsOver`); without it (the old behaviour) it stopped at t = 0.
    Returns (lost reason, longest time without an accepted renew). -/
private def simulateHandoff (initMs periodMs leaseMs : Nat) (handoff : Bool) (loopAnswer : Nat → Renewal)
    : IO (Option String × Nat) := do
  let clock ← IO.mkRef (0 : Nat)
  let lastOk ← IO.mkRef (0 : Nat)
  let maxGap ← IO.mkRef (0 : Nat)
  let lost ← IO.mkRef (none : Option String)
  let handed ← IO.mkRef (!handoff)
  let accepted : Nat → IO Unit := fun t => do
    maxGap.modify (max (t - (← lastOk.get)))
    lastOk.set t
  let renew : IO Renewal := do
    let t ← clock.get
    accepted t
    pure .renewed
  -- the normal loop's first renew happens once initialisation is over
  let done : IO Bool := do
    if (← handed.get) then return true
    let t ← clock.get
    if t ≥ initMs then
      let r := loopAnswer t
      if r == .renewed then accepted t
      if handsOver r then handed.set true
    pure ((← handed.get) || (← lost.get).isSome)
  run renew clock.get (pure none) (fun ms => clock.modify (· + ms)) done
    (fun why => lost.set (some why)) leaseMs periodMs 0 0
  -- after the handoff the normal loop's keeper takes over; the old behaviour
  -- left the interval from the last renew to the loop's first one open
  accepted (max (← clock.get) initMs)
  pure (← lost.get, ← maxGap.get)

def results : IO (List (String × Bool)) := do
  let mut r : List (String × Bool) := []
  -- every gate decision reads the nodes fresh, each node once, together
  let keys := ["n0", "n1", "n2", "n3", "n4", "n5"]
  let (reads5, worst5) ← gateReads keys 5 200
  r := r ++ [(s!"fresh gate reads: six nodes decided five times are read once per decision (30 reads), each decision about one delay (worst {worst5} ms of 200 ms reads, not 1200)",
              reads5 == 30 && worst5 < 600)]
  let (g1, g2, nreads) ← twoGates
  r := r ++ [("fresh gate: a reconstruction that starts between two assignment gates of one pass HOLDS the second assignment (gate 1 admitted a, gate 2 held b)",
              g1 == ["a"] && g2 == [] && nreads == 7)]
  let m0 := ("m0", node .Master .Active 0 "m0")
  let calm := stateOf [m0, ("a", node .Proxy .Active (-1) "a")]
  let noNew ← FreshGate.decide (do throw (IO.userError "must not read")) [] calm calm 1 1
  r := r ++ [("fresh gate: a decision with no new assignment reads no node", !noNew.read && noNew.running.isEmpty)]
  -- concurrent: 6 reads of 200 ms take about 200 ms, not 1200 ms; order kept
  let t0 ← IO.monoMsNow
  let out ← parMapIO [0, 1, 2, 3, 4, 5] fun i => do IO.sleep 200; pure (i * 10)
  let dt := (← IO.monoMsNow) - t0
  r := r ++ [(s!"parallel reads: six 200 ms reads finish in under 600 ms (took {dt} ms) and keep their order",
              out == [0, 10, 20, 30, 40, 50] && dt < 600)]
  let t1 ← IO.monoMsNow
  let outC ← parMapIO (chunk := 2) [0, 1, 2, 3] fun i => do IO.sleep 200; pure i
  let dtC := (← IO.monoMsNow) - t1
  r := r ++ [(s!"parallel reads: a chunk of 2 runs four 200 ms reads in two rounds (took {dtC} ms)",
              outC == [0, 1, 2, 3] && dtC ≥ 380 && dtC < 700)]
  let failed ← (do
      let _ ← parMapIO [1, 2, 3] fun (i : Nat) => do
        if i == 2 then throw (IO.userError "boom") else pure i
      pure false) <|> pure true
  r := r ++ [("parallel reads: a failing read raises its error after the others finished", failed)]
  -- version nudge: 7 commits of one pass
  let commits := fun (changed allActive : Bool) => Id.run do
    let mut nudged := false
    let mut adv := 0
    for _ in [0:7] do
      if VersionNudge.advance changed allActive nudged then
        adv := adv + 1
        nudged := true
    return adv
  r := r ++ [("version: nothing changed and a node rebuilding — 7 commits advance the version once (was 7 a pass)", commits false false == 1)]
  r := r ++ [("version: nothing changed and every node Active — the version stays", commits false true == 0)]
  r := r ++ [("version: a real change advances at its commit",
              VersionNudge.advance true true true && VersionNudge.advance true false true)]
  r := r ++ [("version: the pass after a nudge nudges again while a node is not Active",
              VersionNudge.advance false false false)]
  -- lease keeper
  let lease := 15000
  let (lost1, gap1) ← simulate 31000 5000 lease 180000 fun _ => .renewed
  r := r ++ [(s!"lease: a 31 s pass with the keeper renewing every 5 s never goes {lease} ms without a renewal (longest gap {gap1} ms), not lost",
              lost1 == none && gap1 ≤ 5000)]
  let (lost2, _) ← simulate 31000 5000 lease 180000 fun t => if t < 10000 || t > 15000 then .renewed else .failed
  r := r ++ [("lease: a 10 s API outage inside the lease is not a loss", lost2 == none)]
  let (lost3, _) ← simulate 60000 5000 lease 180000 fun t => if t < 10000 then .renewed else .failed
  r := r ++ [("lease: no accepted renew for the whole lease is lost (fail closed)",
              match lost3 with | some w => has w "no renew was accepted" | none => false)]
  let (lost4, _) ← simulate 60000 5000 lease 180000 fun t => if t < 20000 then .renewed else .otherHolder
  r := r ++ [("lease: another holder is lost at once (split-brain: the process exits)",
              match lost4 with | some w => has w "another holder" | none => false)]
  let (lost5, _) ← simulate 400000 5000 lease 60000 fun _ => .renewed
  r := r ++ [("lease: a pass past its deadline stops renewing and is lost (a stuck pass does not keep leadership)",
              match lost5 with | some w => has w "deadline" | none => false)]
  r := r ++ [("lease: decide — renewed keeps; failed keeps until the lease age; other holder loses",
              decide .renewed 0 lease 0 0 == .keep && decide .failed 14999 lease 0 0 == .keep
                && decide .failed 15000 lease 0 0 != .keep && decide .otherHolder 0 lease 0 0 != .keep)]
  -- first-build wait: handoff of the Lease to the normal loop
  let (hl1, hg1) ← simulateHandoff 40000 5000 lease true fun _ => .renewed
  r := r ++ [(s!"lease handoff: a 40 s initialisation after the wait is covered by the wait keeper until the loop's first accepted renew (longest gap {hg1} ms of {lease} ms)",
              hl1 == none && hg1 ≤ 5000)]
  let (_, hg0) ← simulateHandoff 40000 5000 lease false fun _ => .renewed
  r := r ++ [(s!"lease handoff: stopping the wait keeper when the wait ends (the old behaviour) leaves a gap past the lease ({hg0} ms), the case this prevents",
              hg0 > lease)]
  let (hl2, hg2) ← simulateHandoff 40000 5000 lease true fun t => if t < 50000 then .failed else .renewed
  r := r ++ [(s!"lease handoff: a loop renew that fails does not end the wait keeper (still renewing, longest gap {hg2} ms)",
              hl2 == none && hg2 ≤ 5000)]
  r := r ++ [("lease handoff: only an accepted renew hands over; another holder or a failed renew does not",
              handsOver .renewed && !handsOver .failed && !handsOver .otherHolder)]
  -- service selector
  let shape4 := ServiceSelector.parseShape "flare-prod-nodes-1|RequireDualStack|[\"IPv4\",\"IPv6\"]"
  r := r ++ [("service: the shape is read from one get",
              shape4 == some { selector := some "flare-prod-nodes-1", ipFamilyPolicy := "RequireDualStack", ipFamilies := ["IPv4", "IPv6"] }
                && ServiceSelector.parseShape "|SingleStack|[\"IPv4\"]" == some { selector := none, ipFamilyPolicy := "SingleStack", ipFamilies := ["IPv4"] }
                && ServiceSelector.parseShape "garbage" == none)]
  r := r ++ [("service: no patch when the selector already names the master's pod; a patch otherwise or when unreadable",
              !ServiceSelector.needsPatch shape4 "flare-prod-nodes-1" && ServiceSelector.needsPatch shape4 "flare-prod-nodes-2"
                && ServiceSelector.needsPatch none "x")]
  let sel := ServiceSelector.selectorPatch "flare-prod-nodes-1"
  r := r ++ [("service: the patch sent first carries the selector and no ip family / dual-stack field",
              has sel "statefulset.kubernetes.io/pod-name" && !has sel "ipFamil" && !has sel "DualStack" && !has sel "IPv6")]
  let err := "The Service \"flare-prod-0\" is invalid: \n* spec.ipFamilyPolicy: Invalid value: \"RequireDualStack\": this cluster is not configured for dual-stack services\n* spec.ipFamilies[1]: Invalid value: \"IPv6\": not configured on this cluster"
  let fb := ServiceSelector.singleStackPatch shape4 "flare-prod-nodes-1"
  r := r ++ [("service: the dual-stack refusal is recognised (and another error is not); the retry is SingleStack with the Service's own first family, no IPv6",
              ServiceSelector.dualStackUnsupported err && !ServiceSelector.dualStackUnsupported "connection refused"
                && (match fb with | some p => has p "\"ipFamilyPolicy\":\"SingleStack\"" && has p "[\"IPv4\"]" && !has p "IPv6" | none => false)
                && (ServiceSelector.singleStackPatch none "x").isNone)]
  r := r ++ [("service: a refused service is not tried again within the backoff, then is",
              ServiceSelector.inBackoff 29999 30000 && !ServiceSelector.inBackoff 30000 30000)]
  return r

end FlareOperator.UnitTestsPass
