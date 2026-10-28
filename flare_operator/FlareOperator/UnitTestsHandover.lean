/-
  UnitTestsHandover.lean — checks of StateMachine/Handover.lean, in their own
  module (its own C file: UnitTests.lean's single C file already takes most
  of the operator's build time). Called from UnitTests.run.
-/
import Lean.Data.Json
import FlareOperator.StateMachine.Handover
import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.PromotionEvidence

namespace FlareOperator.UnitTestsHandover

open FlareOperator.K8s
open FlareOperator.Handover

private def node (name : String) (role : FlareRole) (st : FlareState) (part : Int) : FlareNode :=
  { serverName := name, serverPort := 12121, role := role, state := st, partition := part }

/-- 1 partition: m (master), s (slave), p (proxy). -/
private def pair : FlareClusterState :=
  { nodeMap := [("m:12121", node "m" .Master .Active 0), ("s:12121", node "s" .Slave .Active 0),
                ("p:12121", node "p" .Proxy .Active (-1))],
    partitionMap := [(0, { master := some "m:12121", slaves := ["s:12121"] })] }

private def fresh : Entry :=
  { partition := 0, oldMaster := "m:12121", successor := "s:12121", startedMs := 1000, phaseMs := 1000 }

private def okObs (now : Nat) : Obs :=
  { nowMs := now, successorEligible := true, oldBoot := some 7, droppedToSuccessor := some 3,
    failedToSuccessor := some 0, inFlightToSuccessor := some 0, oldMapVersion := some 0 }

private def roleOf (s : FlareClusterState) (k : String) : Option (FlareRole × FlareState) :=
  (s.lookupNode k).map fun n => (n.role, n.state)

/-- Every check: (name, ok). -/
def results : List (String × Bool) := Id.run do
  let cfg : Config := {}
  let mut r : List (String × Bool) := []
  -- requested → demoting once the successor is eligible and the counters read
  let (e1, a1) := step cfg fresh (okObs 1100)
  r := r ++ [("handover: requested → demoting (send V1) with an eligible successor and readable counters",
              e1.phase == .demoting && a1 == .send && e1.dropped0 == some 3 && e1.oldBoot == some 7 && e1.demotedMs == 1100)]
  -- unreadable counters keep it requested; after startMs it gives up (no map was sent)
  let (e1b, a1b) := step cfg fresh { okObs 1100 with droppedToSuccessor := none }
  r := r ++ [("handover: unreadable counters keep it requested", e1b.phase == .requested && a1b == .none)]
  let (e1c, a1c) := step cfg fresh { okObs 40000 with successorEligible := false }
  r := r ++ [("handover: a successor that never becomes eligible ends it unsent (aborted, finish)",
              e1c.phase == .aborted && a1c == .finish && e1c.v1.isNone)]
  -- V1: old master master/down, successor still slave; blocked from refill
  let e1s := recordSent e1 42
  let s1 := apply pair e1s
  r := r ++ [("handover: V1 = old master Master/Down, successor still Slave/Active",
              roleOf s1 "m:12121" == some (.Master, .Down) && roleOf s1 "s:12121" == some (.Slave, .Active) && e1s.v1 == some 42)]
  r := r ++ [("handover: the successor is blocked from promotion while demoting",
              blockedKeys { entries := [e1s] } == ["s:12121"] && ownedMasters { entries := [e1s] } == ["m:12121"])]
  -- demoting → draining when the old master reports ≥ V1
  let (e2, _) := step cfg e1s { okObs 1200 with oldMapVersion := some 41 }
  r := r ++ [("handover: the old master below V1 keeps it demoting", e2.phase == .demoting)]
  let (e3, a3) := step cfg e1s { okObs 1200 with oldMapVersion := some 42 }
  r := r ++ [("handover: the old master at V1 → draining", e3.phase == .draining && a3 == .none)]
  -- draining → promoting only with nothing in flight AND no new drop / failure
  let (e4, a4) := step cfg e3 { okObs 1300 with inFlightToSuccessor := some 2 }
  r := r ++ [("handover: forwards in flight keep it draining", e4.phase == .draining && a4 == .none)]
  let (e5, _) := step cfg e3 { okObs 1300 with droppedToSuccessor := some 4 }
  r := r ++ [("handover: a drop to the successor since the start never promotes (in flight 0 is not delivery)", e5.phase == .draining)]
  let (e6, a6) := step cfg e3 (okObs 1300)
  r := r ++ [("handover: drained clean → promoting (send V2)", e6.phase == .promoting && a6 == .send)]
  -- V2: successor master, old master proxy, partition master = successor
  let e6s := recordSent e6 43
  let s2 := apply pair e6s
  r := r ++ [("handover: V2 = successor Master/Active, old master Proxy, partition master = successor",
              roleOf s2 "s:12121" == some (.Master, .Active) && roleOf s2 "m:12121" == some (.Proxy, .Active)
                && (s2.partitionMap.find? (·.1 == 0)).map (·.2.master) == some (some "s:12121")
                && blockedKeys { entries := [e6s] } == [])]
  -- promoting → done only when every entry pod has V2 and the successor says master
  let (e7, a7) := step cfg e6s { okObs 1400 with entryVersions := [("m:12121", some 43), ("s:12121", some 42)], successorOwnRole := some "master" }
  r := r ++ [("handover: a pod still below V2 keeps it promoting", e7.phase == .promoting && a7 == .none)]
  let (e8, a8) := step cfg e6s { okObs 1400 with entryVersions := [("m:12121", some 43), ("s:12121", some 43), ("p:12121", none)], successorOwnRole := some "master" }
  r := r ++ [("handover: an unreadable pod version keeps it promoting", e8.phase == .promoting && a8 == .none)]
  let (e9, a9) := step cfg e6s { okObs 1400 with entryVersions := [("m:12121", some 43), ("s:12121", some 44)], successorOwnRole := some "master" }
  r := r ++ [("handover: every pod at V2 and the successor master → done", e9.phase == .done && a9 == .finish)]
  -- aborts before promoting, with a rollback map
  let (ea, aa) := step cfg e3 { okObs 1300 with successorEligible := false }
  r := r ++ [("handover: an ineligible successor while draining aborts with a rollback map",
              ea.phase == .aborted && aa == .send)]
  let (eb, _) := step cfg e3 { okObs (1100 + cfg.handoverMs) with inFlightToSuccessor := some 1 }
  r := r ++ [("handover: not drained within Th aborts", eb.phase == .aborted)]
  let (ec, _) := step cfg e3 { okObs 1300 with oldBoot := some 8 }
  r := r ++ [("handover: the old master restarted aborts", ec.phase == .aborted)]
  let eas := recordSent ea 44
  let s3 := apply pair eas
  r := r ++ [("handover: the rollback map puts the old master back Master/Active",
              roleOf s3 "m:12121" == some (.Master, .Active) && roleOf s3 "s:12121" == some (.Slave, .Active) && eas.vBack == some 44)]
  let (ed, ad) := step cfg eas { okObs 1400 with entryVersions := [("m:12121", some 44), ("s:12121", some 44)] }
  r := r ++ [("handover: the rollback ends when every pod has it", ed.phase == .aborted && ad == .finish)]
  -- promoting never aborts
  let (ee, _) := step cfg e6s { okObs 99999 with successorEligible := false }
  r := r ++ [("handover: promoting is never aborted", ee.phase == .promoting)]
  -- persistence round trip
  let l : Ledger := { entries := [e6s, eas] }
  let back := Ledger.fromJson? l.toJson
  r := r ++ [("handover: the ledger survives a JSON round trip",
              match back with
              | some b => b.entries.length == 2 && (b.entries.map (·.phase)) == [.promoting, .aborted]
                            && (b.entries.map (·.v2)) == [some 43, none] && (b.entries.map (·.vBack)) == [none, some 44]
              | none => false)]
  r := r ++ [("handover: a malformed entry fails the whole ledger",
              (Ledger.fromJson? (Lean.Json.mkObj [("entries", Lean.Json.arr #[Lean.Json.mkObj [("partition", Lean.Json.str "x")]])])).isNone)]
  -- the old master's pod went away mid-handover (local kind 2026-10-27: the
  -- preStop window ran out; a new pod took the name and the handover read
  -- the NEW process): promote an eligible successor, never roll back to it
  let (eg, ag) := step cfg e3 { okObs 1300 with oldSameProcess := false }
  r := r ++ [("handover: the old master pod gone mid-way + an eligible successor → promoting (send V2)",
              eg.phase == .promoting && ag == .send)]
  let (eh, ah) := step cfg e3 { okObs 1300 with oldSameProcess := false, successorEligible := false }
  let ehs := recordSent eh 50
  r := r ++ [("handover: the old master pod gone mid-way, no eligible successor → aborted WITHOUT a rollback map",
              eh.phase == .aborted && ah == .finish && eh.noRollback && ehs.vBack.isNone
                && roleOf (apply pair ehs) "m:12121" == some (.Master, .Active))]
  let (ei, ai) := step cfg fresh { okObs 1100 with oldSameProcess := false }
  r := r ++ [("handover: the old master pod gone before it started → aborted unsent", ei.phase == .aborted && ai == .finish && ei.v1.isNone)]
  -- the breaker does not count a handover's placeholder (Master/Down, pod
  -- alive and Terminating), but still counts any other Down node
  let s4 := s1.addNode "x:12121" (node "x" .Proxy .Down (-1))
  let live := ["m:12121", "s:12121", "x:12121", "p:12121"]
  r := r ++ [("handover: the breaker skips the old master's placeholder, still counts another Down node",
              K8sReconciler.breakerCountedKeys s4 [] live ["m:12121"] == ["x:12121"]
                && (let all := K8sReconciler.breakerCountedKeys s4 [] live []
                    all.length == 2 && all.contains "m:12121" && all.contains "x:12121"))]
  -- the commit gate: `lagging` (re-validating while the partition has only
  -- the Master/Down placeholder, the recorded history) is enough for a
  -- handover's proven successor, and for nothing else
  r := r ++ [("handover: the commit gate accepts a lagging copy only for a proven handover, never a forbidden / unknown one",
              PromotionEvidence.handoverCommitAllows .lagging && !PromotionEvidence.commitTimeAllows .lagging
                && PromotionEvidence.handoverCommitAllows .eligible
                && !PromotionEvidence.handoverCommitAllows (.forbidden "x") && !PromotionEvidence.handoverCommitAllows (.unknown "x"))]
  return r

end FlareOperator.UnitTestsHandover
