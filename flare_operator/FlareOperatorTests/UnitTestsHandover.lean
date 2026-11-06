/-
  UnitTestsHandover.lean — checks of StateMachine/Handover.lean, in their own
  module (its own C file: UnitTests.lean's single C file already takes most
  of the operator's build time). Called from UnitTests.run.
-/
import Lean.Data.Json
import FlareOperator.StateMachine.Handover
import FlareOperator.StateMachine.HandoverDrive
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

/-- A3b (addendum 2 §3, 4, 5): recovery from a partial commit, a stopped
    successor and an unknown outcome. -/
private def recoveryResults : List (String × Bool) := Id.run do
  let ccfg : Config := { continuation := true }
  let mut r : List (String × Bool) := []
  -- partition 0: m master, s successor, r1 / r2 prepared replicas
  let trio : FlareClusterState :=
    { nodeMap := [("m:12121", node "m" .Master .Active 0), ("s:12121", node "s" .Slave .Active 0),
                  ("r1:12121", node "r1" .Slave .Active 0), ("r2:12121", node "r2" .Slave .Active 0)],
      partitionMap := [(0, { master := some "m:12121", slaves := ["s:12121", "r1:12121", "r2:12121"] })] }
  let sent : Entry :=
    { fresh with phase := .committingReplicas, demotedMs := 1100, phaseMs := 1300, v1 := some 5, v2 := some 9,
                 successorBinding := "u1|b1|c1", drainProven := true, hid := "p0-a1-1100", contSeq := some 500,
                 toEpoch := "9:e", contMasterId := "M",
                 prepared := [("r1:12121", "u2|b2|c2"), ("r2:12121", "u3|b3|c3")], committed := ["r2:12121"] }
  let late := 1100 + 10000
  -- the successor answers: promoting
  let (a, aa) := step ccfg sent { okObs late with successorAlive := true }
  -- no answer, its stop not confirmed: halted (nothing promoted, nothing rolled back)
  let (h, ha) := step ccfg sent (okObs late)
  -- a stop recorded for ANOTHER pod UID is not this successor's
  let (hx, _) := step ccfg { sent with successorStopped := "u9" } (okObs late)
  r := r ++ [("recovery: one commit at the deadline — the successor answering with its binding is promoted; silent and its stop unconfirmed (or confirmed for another pod UID) = HALTED in committingReplicas, no map",
              a.phase == .promoting && aa == .send
                && h.phase == .committingReplicas && ha == .none && h.reason.startsWith "HALTED" && h.v2 == some 9
                && hx.phase == .committingReplicas && hx.reason.startsWith "HALTED")]
  -- the kubelet confirmed the successor's stop: the first COMMITTED replica
  -- in prepared order (r2, not r1) replaces it; the old successor is fenced
  let (rp, rpa) := step ccfg { sent with successorStopped := "u1" } (okObs late)
  let m3 := apply trio rp
  r := r ++ [("recovery: the successor's kubelet-confirmed stop -> the first committed replica replaces it (not an uncommitted one), V3 is a fresh promotion (no hid, no V2), the old successor is a proxy",
              rpa == .send && rp.phase == .promoting && rp.successor == "r2:12121" && rp.successorBinding == "u3|b3|c3"
                && rp.fencedOut == "s:12121" && rp.hid.isEmpty && rp.v2.isNone && rp.prepared.isEmpty && rp.committed.isEmpty
                && roleOf m3 "r2:12121" == some (.Master, .Active) && roleOf m3 "s:12121" == some (.Proxy, .Active)
                && roleOf m3 "m:12121" == some (.Proxy, .Active)
                && (m3.partitionMap.find? (·.1 == 0)).map (fun (_, p) => (p.master, p.slaves)) == some (some "r2:12121", ["r1:12121"]))]
  -- unknown commits at the deadline: the live successor is promoted; silent = HALTED
  let unk := { sent with committed := [] }
  r := r ++ [("recovery: commits unknown at the deadline — the successor answering is promoted; silent = HALTED (no rollback, no other promotion); proven none still rolls back",
              (step ccfg unk { okObs late with successorAlive := true }).1.phase == .promoting
                && (step ccfg unk (okObs late)).1.reason.startsWith "HALTED" && (step ccfg unk (okObs late)).1.phase == .committingReplicas
                && (step ccfg unk { okObs late with zeroCommitProven := true }).1.phase == .rollingBack
                && (step ccfg { unk with successorStopped := "u1" } (okObs late)).1.reason.startsWith "HALTED")]
  -- promoting after V2 went to the successor (addendum 4 §2)
  let prom : Entry := { sent with phase := .promoting, phaseMs := 2000, fullSent := true }
  let pl := 2000 + 10000
  let (pw, pwa) := step ccfg prom (okObs 3000)
  let (ph, pha) := step ccfg prom (okObs pl)
  let (pr, pra) := step ccfg { prom with successorStopped := "u1" } (okObs pl)
  let (pn, pna) := step ccfg { prom with successorStopped := "u1", committed := [] } (okObs pl)
  let (poff, poffa) := step {} prom (okObs pl)
  r := r ++ [("recovery: promoting after V2 — waits within Th; silent past Th = HALTED; its kubelet-confirmed stop -> a committed replica replaces it, none committed -> aborted (no rollback: the failover rules); continuation off = as before (waits)",
              pw == prom && pwa == .none
                && ph.phase == .promoting && pha == .none && ph.reason.startsWith "HALTED"
                && pr.phase == .promoting && pra == .send && pr.successor == "r2:12121" && pr.fencedOut == "s:12121"
                && pn.phase == .aborted && pna == .finish && pn.noRollback
                && poff == prom && poffa == .none)]
  -- the applied promotion still finishes, alive or not
  let doneObs : Obs := { okObs pl with entryVersions := [("s:12121", some 9), ("m:12121", some 9)], successorOwnRole := some "master" }
  r := r ++ [("recovery: a successor that applied V2 (all pods at V2, own_role master) finishes the handover even past Th",
              (step ccfg prom doneObs).1.phase == .done)]
  -- the frozen keys: every copy of the partition while committing or V2 is out
  let slavesOf := fun (p : Nat) => if p == 0 then ["s:12121", "r1:12121", "r2:12121"] else []
  r := r ++ [("recovery: while committingReplicas or promoting with V2 out, the partition's copies (and a fenced successor) are not promoted by the failover/refill; not before V2, not after",
              frozenKeys { entries := [sent] } slavesOf == ["s:12121", "r1:12121", "r2:12121"]
                && frozenKeys { entries := [rp] } slavesOf == []
                && frozenKeys { entries := [{ rp with v2 := some 11 }] } slavesOf == ["r2:12121", "s:12121", "r1:12121"]
                && frozenKeys { entries := [{ sent with phase := .done }] } slavesOf == []
                && frozenKeys { entries := [{ sent with phase := .draining }] } slavesOf == [])]
  let rt := Ledger.fromJson? ({ entries := [{ rp with successorStopped := "u1" }] } : Ledger).toJson
  r := r ++ [("recovery: successorStopped and fencedOut survive the status JSON",
              rt.map (fun l => l.entries.map fun x => (x.successorStopped, x.fencedOut, x.successor)) == some [("u1", "s:12121", "r2:12121")]
                && bindingUid "u1|b1|c1" == "u1")]
  return r

-- the checks are one long `do` (each `r := r ++ …` nests the rest): past
-- ~70 of them the default recursion depth is exceeded
set_option maxRecDepth 4096 in
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
  -- review of 67e27eb: the FSM's drain leaves a master the handover step did
  -- not see Terminating, and every Terminating master when it saw nothing
  r := r ++ [("handover: a master Terminating after the handover step saw it alive is deferred to the next pass; one it saw Terminating is not",
              drainDeferred (some ["m:12121"]) ["m:12121"] ["m:12121"] == ["m:12121"]
                && drainDeferred (some []) ["m:12121"] ["m:12121"] == [])]
  r := r ++ [("handover: with no observation by the handover step (ledger or pods unreadable), every Terminating Active master is deferred (fail closed); a Terminating slave is not",
              drainDeferred none ["m:12121", "s:12121"] ["m:12121"] == ["m:12121"])]
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
  -- 3dcfc5c S9: a retry due with no acceptable successor uses up its
  -- attempt, so the drain is not held without end
  let ns1 := noSuccessorAttempt { eas with attempt := 1 } 9000
  let ns2 := noSuccessorAttempt ns1 9500
  r := r ++ [("handover (3dcfc5c S9): a due retry without an acceptable successor is an abort without a map that uses up its attempt; after the last the drain gets the master back",
              ns1.attempt == 2 && ns1.phase == .aborted && ns1.v1.isNone && ns1.phaseMs == 9000
                && retryable cfg ns1 && drainHeldKeys { entries := [ns1] } == ["m:12121"]
                && ns2.attempt == cfg.maxAttempts && !retryable cfg ns2 && drainHeldKeys { entries := [ns2] } == [])]
  r := r ++ [("handover: the attempt survives the JSON round trip",
              (Ledger.fromJson? ({ entries := [{ eas with attempt := 2 }] } : Ledger).toJson).map (·.entries.map (·.attempt)) == some [2])]
  -- the commit gate: `lagging` (re-validating while the partition has only
  -- the Master/Down placeholder, the recorded history) is enough for a
  -- handover's proven successor, and for nothing else
  r := r ++ [("handover: the commit gate accepts a lagging copy only for a proven handover, never a forbidden / unknown one",
              PromotionEvidence.handoverCommitAllows .lagging && !PromotionEvidence.commitTimeAllows .lagging
                && PromotionEvidence.handoverCommitAllows .eligible
                && !PromotionEvidence.handoverCommitAllows (.forbidden "x") && !PromotionEvidence.handoverCommitAllows (.unknown "x"))]
  -- history continuation (design addendum 2-4): the phases, off by default
  let ccfg : Config := { continuation := true }
  let draining0 : Entry := { fresh with phase := .draining, demotedMs := 1100, phaseMs := 1100 }
  let draining : Entry := { draining0 with v1 := (some 5), oldBoot := (some 7), dropped0 := (some 3), failed0 := (some 0), successorBinding := "u1|b1|c1" }
  let (dOff, aOff) := step cfg draining (okObs 1200)
  let (dOn, aOn) := step ccfg draining (okObs 1200)
  r := r ++ [("continuation: a clean drain prepares (continuation on) and promotes as before (off, the default)",
              dOff.phase == .promoting && aOff == .send && dOn.phase == .preparing && aOn == .prepare && dOn.drainProven)]
  let prep := afterPrepare dOn 1300 "p0-a1-1100" 500 "9:e" "M" [("r1:12121", "u2|b2|c2"), ("r2:12121", "u3|b3|c3")]
  let none0 := afterPrepare dOn 1300 "p0-a1-1100" 500 "9:e" "M" []
  r := r ++ [("continuation: after the prepare, committingReplicas with the prepared list; none prepared = promote as before (no hid)",
              prep.phase == .committingReplicas && prep.prepared.length == 2 && prep.contSeq == some 500
                && none0.phase == .promoting && none0.hid.isEmpty)]
  let (c1, ca1) := step ccfg prep (okObs 1400)
  r := r ++ [("continuation: committingReplicas sends V2 to the prepared replicas only first (sendTargeted)",
              c1.phase == .committingReplicas && ca1 == .sendTargeted)]
  let sent := recordSent prep 9
  let (c2, ca2) := step ccfg sent { okObs 1500 with committedKeys := ["r1:12121"] }
  let (c3, ca3) := step ccfg c2 { okObs 1600 with committedKeys := ["r2:12121", "x:12121"] }
  r := r ++ [("continuation: commits are accumulated (only prepared keys); all committed -> promoting",
              c2.phase == .committingReplicas && c2.committed == ["r1:12121"] && ca2 == .sendTargeted
                && c3.phase == .promoting && ca3 == .send && c3.committed == ["r1:12121", "r2:12121"])]
  let (p1, pa1) := step ccfg c3 (okObs 1700)
  let p1s := recordSent p1 9
  r := r ++ [("continuation: promoting after the targeted V2 sends V2 to every pod once (fullSent), then waits as before",
              pa1 == .send && p1s.fullSent && p1s.v2 == some 9 && (step ccfg p1s (okObs 1800)).2 == .none)]
  -- the deadline in committingReplicas (handoverMs 10000 from demotedMs 1100)
  let late := 1100 + 10000
  let (x1, _) := step ccfg sent { okObs late with committedKeys := ["r1:12121"], successorAlive := true }
  let (x2, _) := step ccfg sent { okObs late with zeroCommitProven := true }
  let (x3, _) := step ccfg sent { okObs late with successorAlive := true }
  r := r ++ [("continuation: at the deadline one commit -> promoting (never back), proven none -> rollingBack, unknown -> promoting the prepared successor (no rollback) — the successor answering with its binding",
              x1.phase == .promoting && x2.phase == .rollingBack && x3.phase == .promoting)]
  let rb := recordSent x2 11
  let rbApplied : Obs := { okObs (late + 100) with entryVersions := [("m:12121", some 11), ("s:12121", some 11)] }
  r := r ++ [("continuation: rollingBack sends V1' (vBack) and ends aborted once every pod has it; its map makes the old master master again",
              (step ccfg x2 (okObs late)).2 == .send && rb.vBack == some 11
                && (step ccfg rb rbApplied).1.phase == .aborted
                && roleOf (apply pair x2) "m:12121" == some (.Master, .Active))]
  r := r ++ [("continuation: preparing past the deadline or with the successor gone rolls back (nothing active yet)",
              (step ccfg dOn (okObs late)).1.phase == .rollingBack
                && (step ccfg dOn { okObs 1300 with successorEligible := false }).1.phase == .rollingBack)]
  r := r ++ [("continuation: the old master stays master/down while preparing / committingReplicas (no refill promotes the successor)",
              roleOf (apply pair dOn) "m:12121" == some (.Master, .Down) && blockedKeys { entries := [dOn, prep] } == ["s:12121", "s:12121"])]
  let rt := Ledger.fromJson? ({ entries := [{ c2 with leaderEpoch := 4 }] } : Ledger).toJson
  r := r ++ [("continuation: the entry's continuation fields survive the status JSON",
              rt.map (fun l => l.entries.map fun x => (x.hid, x.contSeq, x.toEpoch, x.contMasterId, x.prepared, x.committed, x.leaderEpoch, x.phase))
                == some [(c2.hid, some 500, "9:e", "M", c2.prepared, ["r1:12121"], 4, Phase.committingReplicas)])]
  -- the drive's pure helpers (flare-hc-op-phases: CAS before send, bindings)
  let ent : Entry := { prep with hid := "p0-a1-1100", toEpoch := "9:e", contMasterId := "M", v2 := some 9,
                                 prepared := [("r1:12121", "u2|b2|c2"), ("r2:12121", "u3|b3|c3")] }
  let rd := fun (b : String) (pend : String) (ep : String) (v : Nat) =>
    ({ binding := some b, pending := some pend, epoch := some ep, masterId := some "M", version := some v } : HandoverDrive.Reading)
  r := r ++ [("drive: the CAS needs heldUntil − now ≥ 4 s + 1 s and is cut at min(4 s, left − 1 s)",
              HandoverDrive.casBound 4 == none && HandoverDrive.casBound 5 == some 4 && HandoverDrive.casBound 60 == some 4
                && HandoverDrive.casBound (-3) == none)]
  r := r ++ [("drive: after the answer only the same holder, epoch and time left allow the send",
              HandoverDrive.leaseKept "a" "a" false 3 3 2 && !HandoverDrive.leaseKept "a" "b" false 3 3 2
                && !HandoverDrive.leaseKept "a" "a" true 3 3 2 && !HandoverDrive.leaseKept "a" "a" false 3 4 2
                && !HandoverDrive.leaseKept "a" "a" false 3 3 0)]
  r := r ++ [("drive: nothing is guarded with the continuation off; on, the continuation phases and entries with a hid are",
              !HandoverDrive.guarded false ent && !HandoverDrive.guarded false { ent with phase := .rollingBack }
                && HandoverDrive.guarded true { ent with phase := .committingReplicas } && HandoverDrive.guarded true { fresh with phase := .rollingBack }
                && HandoverDrive.guarded true { fresh with phase := .promoting, hid := "h" }
                && !HandoverDrive.guarded true { fresh with phase := .promoting } && !HandoverDrive.guarded true { fresh with phase := .draining }
                && HandoverDrive.guarded true { fresh with phase := .promoting, contSeq := some 5 })]
  let st : Ledger := { entries := [{ ent with phase := .committingReplicas, leaderEpoch := 4 }] }
  let ok? := fun (x : Entry) (ep : Nat) => match HandoverDrive.casAllowed st x ep with | .ok _ => true | .error _ => false
  r := r ++ [("drive: an older leader's write and a phase written back are refused; the same or a newer epoch, the next phase and another attempt are allowed",
              !ok? { ent with phase := .committingReplicas } 3 && ok? { ent with phase := .committingReplicas } 4
                && ok? { ent with phase := .promoting } 5 && !ok? { ent with phase := .preparing } 5
                && !ok? { ent with phase := .rollingBack, hid := "x" } 3 && ok? { ent with phase := .rollingBack } 4
                && (match HandoverDrive.casAllowed {} ent 1 with | .ok _ => true | .error _ => false))]
  -- review of 0cf92ba (P1): a stale leader's delayed CAS of an older attempt
  -- must not overwrite a newer attempt; a new attempt starts only after the
  -- stored one is over
  let okIn := fun (l : Ledger) (x : Entry) (ep : Nat) => match HandoverDrive.casAllowed l x ep with | .ok _ => true | .error _ => false
  let newer : Ledger := { entries := [{ ent with phase := .preparing, attempt := 2, leaderEpoch := 5 }] }
  let newerJson := newer.toJson.compress
  r := r ++ [("drive: an older leader's entry of attempt 1 is refused over a stored attempt 2 of a newer leader (any phase); the stored ledger is unchanged",
              !okIn newer { ent with phase := .committingReplicas, attempt := 1 } 4
                && !okIn newer { ent with phase := .rollingBack, attempt := 1 } 4
                && !okIn newer { ent with phase := .promoting, attempt := 1, oldUid := "other" } 4
                && !okIn newer { ent with phase := .committingReplicas, attempt := 1 } 5
                && newer.toJson.compress == newerJson)]
  let running : Ledger := { entries := [{ ent with phase := .committingReplicas, attempt := 1, leaderEpoch := 4 }] }
  let abortedL : Ledger := { entries := [{ ent with phase := .aborted, attempt := 1, leaderEpoch := 4 }] }
  let doneL : Ledger := { entries := [{ ent with phase := .done, attempt := 1, leaderEpoch := 4 }] }
  r := r ++ [("drive: a new attempt starts only after the stored one is over — attempt + 1 of the same pod after an abort, or another old pod after done/aborted; never over a running one, a skipped or a lower attempt",
              okIn abortedL { ent with phase := .requested, attempt := 2 } 4
                && okIn abortedL { ent with phase := .requested, attempt := 1, oldUid := "new-pod" } 4
                && okIn doneL { ent with phase := .requested, attempt := 1, oldUid := "new-pod" } 4
                && !okIn doneL { ent with phase := .requested, attempt := 2 } 4
                && !okIn running { ent with phase := .requested, attempt := 2 } 4
                && !okIn running { ent with phase := .requested, oldUid := "new-pod" } 4
                && !okIn abortedL { ent with phase := .requested, attempt := 3 } 4
                && !okIn { entries := [{ ent with phase := .aborted, attempt := 2, leaderEpoch := 4 }] } { ent with phase := .requested, attempt := 1 } 4
                && !okIn abortedL { ent with phase := .requested, attempt := 2 } 3)]
  let good := [("r1:12121", rd "u2|b2|c2" "-" "9:e" 9), ("r2:12121", rd "u3|b3|c3" "-" "9:e" 8)]
  r := r ++ [("drive: committed needs the same binding, no pending, epoch = toEpoch, master_id and version ≥ V2",
              HandoverDrive.committedKeys ent good == ["r1:12121"]
                && HandoverDrive.committedKeys ent [("r1:12121", { rd "u2|b2|c2" "-" "9:e" 9 with binding := some "u9|b2|c2" })] == []
                && HandoverDrive.committedKeys ent [("r1:12121", { rd "u2|b2|c2" "-" "8:e" 9 with pending := some "-" })] == []
                && HandoverDrive.committedKeys ent [("r1:12121", rd "u2|b2|c2" "v1 replica h 0 s a 9:e 5 M 1 i" "9:e" 9)] == []
                && HandoverDrive.committedKeys ent [("r1:12121", { rd "u2|b2|c2" "-" "9:e" 9 with masterId := some "X" })] == []
                && HandoverDrive.committedKeys { ent with v2 := none } good == [])]
  let pend := "v1 replica p0-a1-1100 0 s:12121 8:e 9:e 500 M 99999 inc"
  let p1 := ("r1:12121", rd "u2|b2|c2" pend "8:e" 8)
  let pending := [p1, ("r2:12121", rd "u3|b3|c3" pend "8:e" 8)]
  r := r ++ [("drive: zero commit is proven only when EVERY prepared replica was read fresh, bound the same and still pending with its from epoch",
              HandoverDrive.zeroProven ent pending
                && !HandoverDrive.zeroProven ent [p1]
                && !HandoverDrive.zeroProven ent [p1, ("r2:12121", { rd "u3|b3|c3" pend "8:e" 8 with binding := none })]
                && !HandoverDrive.zeroProven ent [p1, ("r2:12121", rd "u3|b3|c3" "-" "9:e" 9)]
                && !HandoverDrive.zeroProven ent [p1, ("r2:12121", rd "u3|b3|c3" pend "9:e" 8)]
                && !HandoverDrive.zeroProven ent [p1, ("r2:12121", rd "u3|b3|c3" "v1 replica OTHER 0 s a 8:e 5 M 1 i" "8:e" 8)]
                && HandoverDrive.pendingFrom pend "p0-a1-1100" == some "8:e" && (HandoverDrive.pendingFrom "-" "p0-a1-1100").isNone)]
  let (dEnt, dropped) := HandoverDrive.dropChanged ent [("r1:12121", some "u2|b2|c2"), ("r2:12121", some "u3x|b3|c3")]
  let (dSame, droppedSame) := HandoverDrive.dropChanged ent [("r1:12121", some "u2|b2|c2"), ("r2:12121", some "u3|b3|cNEW")]
  let (dAll, _) := HandoverDrive.dropChanged ent [("r1:12121", none), ("r2:12121", some "zz")]
  let (dAllV1, _) := HandoverDrive.dropChanged { ent with v2 := none } [("r1:12121", none), ("r2:12121", none)]
  r := r ++ [("drive: a prepared replica whose pod, process or copy changed (or unreadable) is dropped; same process = discard it; none left = promote as before",
              dEnt.prepared == [("r1:12121", "u2|b2|c2")] && dropped == [("r2:12121", false)]
                && dSame.prepared.length == 1 && droppedSame == [("r2:12121", true)]
                && dAll.phase == .promoting && dAll.prepared.isEmpty && dAll.hid == "p0-a1-1100" && !dAll.fullSent
                && dAllV1.phase == .promoting && dAllV1.hid.isEmpty
                && (HandoverDrive.dropChanged ent [("r1:12121", some "u2|b2|c2"), ("r2:12121", some "u3|b3|c3")]).2.isEmpty)]
  r := r ++ [("drive: flared command lines, the promote_prepare reply, safe arguments and the pending's wall deadline",
              HandoverDrive.promotePrepareCmd "h" 0 "s:12121" 77 == "history promote_prepare h 0 s:12121 77"
                && HandoverDrive.prepareCmd "h" 0 "s:12121" "8:e" "9:e" 5 "M" 77 "inc" == "history prepare h 0 s:12121 8:e 9:e 5 M 77 inc"
                && HandoverDrive.discardCmd "h" == "history discard h" && HandoverDrive.releaseCmd "h" == "wal_pin release h"
                && HandoverDrive.parsePromote "STAT history_result prepared\r\nSTAT history_from_epoch 8:e\r\nSTAT history_to_epoch 9:e\r\nSTAT history_seq 500\r\nSTAT history_master_id M\r\nEND\r\n" == some ("9:e", 500, "M")
                && (HandoverDrive.parsePromote "STAT history_result already\r\nSTAT history_to_epoch 9:e\r\nSTAT history_seq 500\r\nSTAT history_master_id M\r\nEND").isSome
                && (HandoverDrive.parsePromote "STAT history_result refused:busy\r\nEND").isNone
                && (HandoverDrive.parsePromote "STAT history_result prepared\r\nSTAT history_to_epoch 9:e\r\nEND").isNone
                && HandoverDrive.safeArg "p0-a1-1100" && HandoverDrive.safeArg "pod-0.svc.ns:12121" && !HandoverDrive.safeArg "a b" && !HandoverDrive.safeArg "x'y" && !HandoverDrive.safeArg ""
                && HandoverDrive.wallDeadline 1000000 5000 12000 == 1007000 && HandoverDrive.wallDeadline 1000000 13000 12000 == 1000000)]
  -- addendum 11: arm before V2, and the publish gate while committingReplicas
  let held := { ent with phase := .committingReplicas }
  let prom := { ent with phase := .promoting }
  let ks := ["r1:12121", "s:12121", "other:12121"]
  let (dArm, _) := (HandoverDrive.dropPrepared held ["r2:12121"], 0)
  let dArmAll := HandoverDrive.dropPrepared { held with committed := ["r1:12121"] } ["r1:12121", "r2:12121"]
  r := r ++ [("drive: history arm command line and result; a replica whose arm failed is dropped (none left = promoting with the hid kept, fullSent false)",
              HandoverDrive.armCmd "p0-a1-1100" 9 == "history arm p0-a1-1100 9"
                && HandoverDrive.armOk (some "armed") && HandoverDrive.armOk (some "already")
                && !HandoverDrive.armOk (some "refused:armed_for_another_version") && !HandoverDrive.armOk (some "failed:write") && !HandoverDrive.armOk none
                && dArm.prepared == [("r1:12121", "u2|b2|c2")] && dArm.phase == .committingReplicas
                && dArmAll.phase == .promoting && dArmAll.prepared.isEmpty && dArmAll.committed.isEmpty
                && dArmAll.hid == "p0-a1-1100" && dArmAll.v2 == some 9 && !dArmAll.fullSent)]
  r := r ++ [("drive: publish gate — while an entry is committingReplicas a fleet-wide publish is skipped and a targeted one keeps only its prepared replicas (never the successor or other pods); an unread ledger fails closed; otherwise as before",
              HandoverDrive.publishGate true [held] none == .skip
                && HandoverDrive.publishGate true [held] (some ks) == .only ["r1:12121"]
                && HandoverDrive.publishGate true [held] (some ["s:12121"]) == .only []
                && HandoverDrive.publishGate true [prep, { held with partition := 3 }] none == .skip
                && HandoverDrive.publishGate true [prom] none == .all
                && HandoverDrive.publishGate true [] none == .all
                && HandoverDrive.publishGate true [prom] (some ks) == .only ks
                && HandoverDrive.publishGate false [] none == .skip
                && HandoverDrive.publishGate false [] (some ks) == .skip
                && HandoverDrive.holdsV2 held && !HandoverDrive.holdsV2 prom && !HandoverDrive.holdsV2 { held with phase := .done })]
  r := r ++ recoveryResults
  return r

end FlareOperator.UnitTestsHandover
