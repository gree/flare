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
    failedToSuccessor := some 0, inFlightToSuccessor := some 0, oldMapVersion := some 0,
    successorBinding := some "u1|b1|c1" }

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
  -- R3 / SAF-08 (review of the a8b9793 matrix): no demote until the
  -- successor's own reading is eligible and its binding readable; the binding
  -- read then is what the drain proves, any other one aborts
  let (e1r, a1r) := step cfg fresh { okObs 1100 with successorR3 := false }
  r := r ++ [("handover: a successor whose R3 reading is not eligible keeps it requested (no V1, the master is kept)",
              e1r.phase == .requested && a1r == .none && e1r.v1.isNone)]
  let (e1u, a1u) := step cfg fresh { okObs 1100 with successorBinding := none }
  r := r ++ [("handover: an unreadable successor binding keeps it requested", e1u.phase == .requested && a1u == .none)]
  r := r ++ [("handover: the demote records the successor's binding", e1.successorBinding == "u1|b1|c1")]
  let e1x := recordSent e1 42
  let (e1y, a1y) := step cfg e1x { okObs 1200 with oldMapVersion := some 42, successorBinding := some "u1|b2|c1" }
  r := r ++ [("handover: the successor restarted (another boot) after the demote → aborted, rollback sent",
              e1y.phase == .aborted && a1y == .send)]
  let (e1z, _) := step cfg e1x { okObs 1200 with oldMapVersion := some 42, successorBinding := none }
  r := r ++ [("handover: an unreadable successor binding is not a change", e1z.phase == .draining)]
  let ep : Entry := { e1x with phase := .promoting, drainProven := true }
  let (ep1, ap1) := step cfg ep { okObs 1300 with successorBinding := some "u1|b1|c9" }
  r := r ++ [("handover: another copy before V2 → aborted, no promote", ep1.phase == .aborted && ap1 == .send && ep1.v2.isNone)]
  let (ep2, ap2) := step cfg ep (okObs 1300)
  r := r ++ [("handover: the same binding before V2 → V2 sent", ep2.phase == .promoting && ap2 == .send)]
  r := r ++ [("handover: the successor binding survives the ledger JSON",
              (Entry.fromJson? (Entry.toJson e1)).map (·.successorBinding) == some "u1|b1|c1")]
  -- review of 92a73e6: the picker and the per-tick check share one candidate
  -- predicate — a repair-pending first slave is skipped for a healthy second
  let three : FlareClusterState :=
    { nodeMap := [("m:12121", node "m" .Master .Active 0), ("s:12121", node "s" .Slave .Active 0),
                  ("t:12121", node "t" .Slave .Active 0), ("u:12121", node "u" .Slave .Prepare 0),
                  ("x:12121", node "x" .Slave .Active 1)],
      partitionMap := [(0, { master := some "m:12121", slaves := ["s:12121", "t:12121", "u:12121"] })] }
  let all := ["s:12121", "t:12121", "u:12121", "x:12121", "m:12121"]
  r := r ++ [("handover: successor candidates skip a slave with a replica repair pending (the healthy second one remains)",
              successorCandidates three ["s:12121", "t:12121", "u:12121"] 0 "m:12121" all ["s:12121"] == ["t:12121"])]
  r := r ++ [("handover: successor candidates are Active slaves of the partition, Ready, in map order (not Prepare, not another partition, not the old master)",
              successorCandidates three ["s:12121", "t:12121", "u:12121", "x:12121", "m:12121"] 0 "m:12121" all [] == ["s:12121", "t:12121"]
                && successorCandidates three ["s:12121", "t:12121"] 0 "m:12121" ["t:12121"] [] == ["t:12121"])]
  -- CI 40846298380: a master from before the handover is recognised as such
  let modern := "STAT reconstruction_boot_id 7\r\nSTAT proxy_write_in_flight 0\r\nSTAT proxy_write_failed 0\r\nEND\r\n"
  let rc56 := "STAT curr_items 5\r\nSTAT rocksdb_master_id x\r\nEND\r\n"
  let rc65 := "STAT reconstruction_boot_id 7\r\nSTAT proxy_write_dropped 0\r\nEND\r\n"
  r := r ++ [("handover: an old master with a boot id and the forward counters can be handed over",
              oldMasterCanHandOver (some modern) && !oldMasterPredatesHandover (some modern))]
  r := r ++ [("handover: a complete reply without them (rc56, rc65-rc68 shapes) predates the handover; unreadable or incomplete is neither",
              oldMasterPredatesHandover (some rc56) && oldMasterPredatesHandover (some rc65)
                && !oldMasterPredatesHandover none && !oldMasterPredatesHandover (some "STAT curr_items 5\r\n")
                && !oldMasterCanHandOver none)]
  r := r ++ [("handover (review of 7ae666c): a modern reply missing one gauge or the boot id is neither older nor handed over (fail closed: wait)",
              !oldMasterPredatesHandover (some "STAT reconstruction_boot_id 7\r\nSTAT proxy_write_in_flight 0\r\nEND\r\n")
                && !oldMasterPredatesHandover (some "STAT reconstruction_boot_id 7\r\nSTAT proxy_write_failed 0\r\nEND\r\n")
                && !oldMasterCanHandOver (some "STAT reconstruction_boot_id 7\r\nSTAT proxy_write_in_flight 0\r\nEND\r\n")
                && !oldMasterCanHandOver (some "STAT proxy_write_in_flight 0\r\nSTAT proxy_write_failed 0\r\nEND\r\n")
                && !oldMasterPredatesHandover (some "STAT proxy_write_in_flight 0\r\nSTAT proxy_write_failed 0\r\nEND\r\n"))]
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
  r := r ++ [("handover: drained clean → promoting (send V2), the drain recorded as proven",
              e6.phase == .promoting && a6 == .send && e6.drainProven)]
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
  let (eb2, ab2) := step cfg e3 (okObs (1100 + cfg.handoverMs + 3000))
  r := r ++ [("handover: a drain first observed clean after Th still promotes (progress before the bound)",
              eb2.phase == .promoting && ab2 == .send && eb2.drainProven)]
  let (eb3, _) := step cfg e1s { okObs (1100 + cfg.handoverMs + 3000) with oldMapVersion := some 42 }
  r := r ++ [("handover: V1 first observed applied after Th still moves to draining", eb3.phase == .draining)]
  let (eb4, _) := step cfg e1s { okObs (1100 + cfg.handoverMs) with oldMapVersion := some 41 }
  r := r ++ [("handover: V1 not applied by Th aborts", eb4.phase == .aborted)]
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
                            && (b.entries.map (·.drainProven)) == [true, false]
                            && (b.entries.map (·.v2)) == [some 43, none] && (b.entries.map (·.vBack)) == [none, some 44]
              | none => false)]
  r := r ++ [("handover: a malformed entry fails the whole ledger",
              (Ledger.fromJson? (Lean.Json.mkObj [("entries", Lean.Json.arr #[Lean.Json.mkObj [("partition", Lean.Json.str "x")]])])).isNone)]
  -- the old master's pod went away mid-handover (local kind 2026-10-27: the
  -- preStop window ran out; a new pod took the name and the handover read
  -- the NEW process): promote an eligible successor, never roll back to it
  let (eg, ag) := step cfg e3 { okObs 1300 with oldSameProcess := false }
  r := r ++ [("handover: the old master pod gone mid-way + an eligible successor → promoting (send V2), NOT proven (the normal promotion rules apply)",
              eg.phase == .promoting && ag == .send && !eg.drainProven)]
  -- gone before the drain was clean (draining, forwards still in flight): no proof either
  let (eg2, _) := step cfg e3 { okObs 1300 with oldSameProcess := false, inFlightToSuccessor := some 3, droppedToSuccessor := some 9 }
  r := r ++ [("handover: the old master pod gone before a clean drain → promoting without the proof",
              eg2.phase == .promoting && !eg2.drainProven)]
  let (eg3, _) := step cfg e1s { okObs 1200 with oldSameProcess := false }
  r := r ++ [("handover: the old master pod gone while demoting → promoting without the proof",
              eg3.phase == .promoting && !eg3.drainProven)]
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
  -- the one-map drain leaves the old master of a handover in progress alone
  -- (requested … promoting, the phase saved or not), and gets it back when
  -- the handover aborted
  r := r ++ [("handover: the one-map drain is held off the old master from requested to promoting, not after an abort",
              drainHeldKeys { entries := [fresh] } == ["m:12121"] && drainHeldKeys { entries := [e1s] } == ["m:12121"]
                && drainHeldKeys { entries := [e3] } == ["m:12121"] && drainHeldKeys { entries := [e6s] } == ["m:12121"]
                && drainHeldKeys { entries := [{ e9 with phase := .done }] } == [])]
  -- L7: an abort that rolled back is retried (attempts left): the drain still
  -- leaves the master; with the attempts used up, or no rollback possible,
  -- the drain gets it back
  r := r ++ [("handover: a rolled-back abort with attempts left is retryable and held from the one-map drain",
              retryable cfg eas && drainHeldKeys { entries := [eas] } == ["m:12121"])]
  r := r ++ [("handover: the last attempt's abort is not retried; the drain gets the master back",
              !retryable cfg { eas with attempt := cfg.maxAttempts } && drainHeldKeys { entries := [{ eas with attempt := cfg.maxAttempts }] } == [])]
  r := r ++ [("handover: an abort without a rollback (old master gone) is never retried",
              !retryable cfg ehs && drainHeldKeys { entries := [ehs] } == [])]
  r := r ++ [("handover: an abort before any map was sent is retryable (nothing to roll back)",
              retryable cfg e1c)]
  r := r ++ [("handover: the attempt survives the JSON round trip",
              (Ledger.fromJson? ({ entries := [{ eas with attempt := 2 }] } : Ledger).toJson).map (·.entries.map (·.attempt)) == some [2])]
  -- the commit gate: `lagging` (re-validating while the partition has only
  -- the Master/Down placeholder, the recorded history) is enough for a
  -- handover's proven successor, and for nothing else
  r := r ++ [("handover: the commit gate accepts a lagging copy only for a proven handover, never a forbidden / unknown one",
              PromotionEvidence.handoverCommitAllows .lagging && !PromotionEvidence.commitTimeAllows .lagging
                && PromotionEvidence.handoverCommitAllows .eligible
                && !PromotionEvidence.handoverCommitAllows (.forbidden "x") && !PromotionEvidence.handoverCommitAllows (.unknown "x"))]
  return r

end FlareOperator.UnitTestsHandover
