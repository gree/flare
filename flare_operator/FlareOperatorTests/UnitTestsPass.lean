/-
  UnitTestsPass.lean - checks for flare-operator-slow-reconcile: the per-node
  reads of a pass (one read per pass, concurrent), the version nudge, the
  lease keeper and the Service selector patch.
-/
import FlareOperator.Operator.Parallel
import FlareOperator.Operator.LeaseKeeper
import FlareOperator.StateMachine.VersionNudge
import FlareOperator.StateMachine.ServiceSelector

namespace FlareOperator.UnitTestsPass

open FlareOperator.Parallel
open FlareOperator.LeaseKeeper

private def has (h n : String) : Bool := (h.splitOn n).length > 1

/-- One pass's gate decisions: `decisions` commits, each reading all `keys`
    through the pass cache; returns (reads made, answers equal). -/
private def gateReads (keys : List String) (decisions : Nat) : IO (Nat × Bool) := do
  let cache : PassCache String Nat ← IO.mkRef []
  let reads ← IO.mkRef (0 : Nat)
  let mut same := true
  let mut first : List (String × Nat) := []
  for i in [0:decisions] do
    let got ← readOnce cache keys fun _ => do reads.modify (· + 1); pure 7
    if i == 0 then first := got else same := same && got == first
  pure (← reads.get, same)

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

def results : IO (List (String × Bool)) := do
  let mut r : List (String × Bool) := []
  -- one observation read per pass
  let keys := ["n0", "n1", "n2", "n3", "n4", "n5"]
  let (reads5, same5) ← gateReads keys 5
  r := r ++ [("pass reads: six nodes decided five times in a pass are read once each (6 reads, not 30), the same answer every time",
              reads5 == 6 && same5)]
  let cache : PassCache String Nat ← IO.mkRef []
  let n ← IO.mkRef (0 : Nat)
  let rd := fun (_ : String) => do n.modify (· + 1); pure 1
  let _ ← readOnce cache ["a", "b"] rd
  let _ ← readOnce cache ["a", "b", "c"] rd
  let afterNew ← n.get
  PassCache.forget cache "a"
  let _ ← readOnce cache ["a", "b", "c"] rd
  let afterForget ← n.get
  PassCache.reset cache
  let _ ← readOnce cache ["a", "b", "c"] rd
  r := r ++ [("pass reads: a node new to the pass is read alone (3 reads); a forgotten one is read again (4); a new pass reads all again (7)",
              afterNew == 3 && afterForget == 4 && (← n.get) == 7)]
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
  -- service selector
  let shape4 := ServiceSelector.parseShape "flare-mon-prod-nodes-1|RequireDualStack|[\"IPv4\",\"IPv6\"]"
  r := r ++ [("service: the shape is read from one get",
              shape4 == some { selector := some "flare-mon-prod-nodes-1", ipFamilyPolicy := "RequireDualStack", ipFamilies := ["IPv4", "IPv6"] }
                && ServiceSelector.parseShape "|SingleStack|[\"IPv4\"]" == some { selector := none, ipFamilyPolicy := "SingleStack", ipFamilies := ["IPv4"] }
                && ServiceSelector.parseShape "garbage" == none)]
  r := r ++ [("service: no patch when the selector already names the master's pod; a patch otherwise or when unreadable",
              !ServiceSelector.needsPatch shape4 "flare-mon-prod-nodes-1" && ServiceSelector.needsPatch shape4 "flare-mon-prod-nodes-2"
                && ServiceSelector.needsPatch none "x")]
  let sel := ServiceSelector.selectorPatch "flare-mon-prod-nodes-1"
  r := r ++ [("service: the patch sent first carries the selector and no ip family / dual-stack field",
              has sel "statefulset.kubernetes.io/pod-name" && !has sel "ipFamil" && !has sel "DualStack" && !has sel "IPv6")]
  let err := "The Service \"flare-mon-prod-0\" is invalid: \n* spec.ipFamilyPolicy: Invalid value: \"RequireDualStack\": this cluster is not configured for dual-stack services\n* spec.ipFamilies[1]: Invalid value: \"IPv6\": not configured on this cluster"
  let fb := ServiceSelector.singleStackPatch shape4 "flare-mon-prod-nodes-1"
  r := r ++ [("service: the dual-stack refusal is recognised (and another error is not); the retry is SingleStack with the Service's own first family, no IPv6",
              ServiceSelector.dualStackUnsupported err && !ServiceSelector.dualStackUnsupported "connection refused"
                && (match fb with | some p => has p "\"ipFamilyPolicy\":\"SingleStack\"" && has p "[\"IPv4\"]" && !has p "IPv6" | none => false)
                && (ServiceSelector.singleStackPatch none "x").isNone)]
  r := r ++ [("service: a refused service is not tried again within the backoff, then is",
              ServiceSelector.inBackoff 29999 30000 && !ServiceSelector.inBackoff 30000 30000)]
  return r

end FlareOperator.UnitTestsPass
