/-
  UnitTestsNodeMove.lean — checks of StateMachine/NodeMove.lean (the cordon
  move), in their own module like UnitTestsRolling. Called from UnitTests.run.
-/
import FlareOperator.StateMachine.NodeMove

namespace FlareOperator.UnitTestsNodeMove

open FlareOperator.K8s
open FlareOperator.NodeMove

private def cfg : Config := {}

private def mv (role : String) (phase : Phase) : Move :=
  { id := "mv1-u1", node := "w1", pod := "c-nodes-0", podUid := "u1", key := "k0", role, partition := 0,
    phase, successor := if role == "master" then "k1" else "", startedMs := 0, phaseMs := 0 }

private def pod (uid : String) (role : FlareRole) (serving : Bool := true) : CurPod :=
  { uid, terminating := false, ready := true, serving, role := some role, active := true, synced := true }

private def obs (now : Nat) (cur : Option CurPod) (cordoned : Bool := true) : Obs :=
  { nowMs := now, nodeCordoned := cordoned, cur }

private def drainedObs (now : Nat) (cur : Option CurPod) : Obs :=
  { obs now cur with inEndpoints := some false, quietMs := some 10000, currConnections := some 0, ownProxy := some true }

private def phaseOf (p : Move × Action) : Phase := p.1.phase
private def actOf (p : Move × Action) : Action := p.2

private def copy (key node : String) (ok : Bool := true) : CopyFact :=
  { key, nodeName := node, active := ok, sameHistory := true, repairOpen := false, dropIncreased := false }

private def cand (pod node role : String) (others : List CopyFact) (succ : Option String := none) : Cand :=
  { pod, key := s!"{pod}-key", uid := s!"uid-{pod}", node, role, partition := 0, others, successor := succ }

def results : List (String × Bool) := Id.run do
  let mut r : List (String × Bool) := []
  -- ── transitions ─────────────────────────────────────────────────────
  let m := mv "master" .pending
  let s1 := step cfg m (obs 1000 (some (pod "u1" .Master)))
  r := r ++ [("node move: pending master -> handingOver and asks the ordered handover",
              phaseOf s1 == .handingOver && actOf s1 == .requestHandover)]
  let s2 := step cfg (mv "master" .handingOver) (obs 2000 (some (pod "u1" .Master)))
  r := r ++ [("node move: handingOver with no handover entry yet asks again (restart before the request)",
              phaseOf s2 == .handingOver && actOf s2 == .requestHandover)]
  let s3 := step cfg (mv "master" .handingOver) { obs 2000 (some (pod "u1" .Master)) with handover := .running }
  r := r ++ [("node move: handingOver while the handover runs waits", phaseOf s3 == .handingOver && actOf s3 == .none)]
  let s4 := step cfg (mv "master" .handingOver)
    { obs 3000 (some (pod "u1" .Proxy)) with successorIsMaster := true }
  r := r ++ [("node move: handingOver -> proxied once the pod is a proxy and the successor is master", phaseOf s4 == .proxied)]
  let s4b := step cfg (mv "master" .handingOver) { obs 3000 (some (pod "u1" .Proxy)) with successorIsMaster := false }
  r := r ++ [("node move: a proxy whose successor is not master yet is not proxied", phaseOf s4b == .handingOver)]
  let sl := step cfg (mv "slave" .pending) (obs 1000 (some (pod "u1" .Slave)))
  r := r ++ [("node move: pending replica asks to be demoted to a proxy",
              phaseOf sl == .pending && actOf sl == .demote)]
  r := r ++ [("node move: pending replica that is a proxy -> proxied (never handingOver)",
              phaseOf (step cfg (mv "slave" .pending) (obs 1000 (some (pod "u1" .Proxy)))) == .proxied)]
  let s5 := step cfg (mv "slave" .proxied) (obs 4000 (some (pod "u1" .Proxy)))
  r := r ++ [("node move: proxied removes the serving label", phaseOf s5 == .proxied && actOf s5 == .removeServing)]
  let s6 := step cfg (mv "slave" .proxied) (obs 4000 (some (pod "u1" .Proxy false)))
  r := r ++ [("node move: proxied -> unserved once the label is gone", phaseOf s6 == .unserved)]
  let un := { mv "slave" .unserved with phaseMs := 4000 }
  r := r ++ [("node move: unserved waits while the address is still in the EndpointSlice",
              phaseOf (step cfg un { drainedObs 5000 (some (pod "u1" .Proxy false)) with inEndpoints := some true }) == .unserved)]
  r := r ++ [("node move: unserved waits while connections are still being opened (total_connections moved < 10 s ago)",
              phaseOf (step cfg un { drainedObs 5000 (some (pod "u1" .Proxy false)) with quietMs := some 3000 }) == .unserved)]
  r := r ++ [("node move: unserved waits while a connection is open",
              phaseOf (step cfg un { drainedObs 5000 (some (pod "u1" .Proxy false)) with currConnections := some 2 }) == .unserved)]
  r := r ++ [("node move: a pod whose own_role is not proxy yet is not released",
              phaseOf (step cfg un { drainedObs 5000 (some (pod "u1" .Proxy false)) with ownProxy := some false }) == .unserved)]
  r := r ++ [("node move: unreadable evidence never releases",
              phaseOf (step cfg un { obs 5000 (some (pod "u1" .Proxy false)) with inEndpoints := none }) == .unserved)]
  let rel := step cfg un (drainedObs 5000 (some (pod "u1" .Proxy false)))
  r := r ++ [("node move: unserved -> released when all three proofs hold (the operator writes it)",
              phaseOf rel == .released && rel.1.releasedMs == 5000)]
  let late := step cfg un { drainedObs 130000 (some (pod "u1" .Proxy false)) with currConnections := some 1 }
  r := r ++ [("node move: past the 120 s bound the move HOLDS as a proxy, nothing is deleted, the reason says why",
              phaseOf late == .unserved && late.1.held && actOf late == .none && late.1.reason.length > 0)]
  r := r ++ [("node move: a held move still releases if the proofs arrive later",
              phaseOf (step cfg late.1 (drainedObs 140000 (some (pod "u1" .Proxy false)))) == .released)]
  -- released: the operator deletes after the grace, not before
  let rl := { mv "slave" .released with releasedMs := 5000 }
  r := r ++ [("node move: released waits for the eviction within 60 s", actOf (step cfg rl (obs 30000 (some (pod "u1" .Proxy false)))) == .none)]
  r := r ++ [("node move: released with no eviction after 60 s -> the operator deletes (uid precondition)",
              actOf (step cfg rl (obs 70000 (some (pod "u1" .Proxy false)))) == .deletePod)]
  r := r ++ [("node move: a terminating released pod is left to finish",
              actOf (step cfg rl (obs 70000 (some { pod "u1" .Proxy false with terminating := true }))) == .none)]
  r := r ++ [("node move: released -> deleted when the old pod is gone",
              phaseOf (step cfg rl (obs 7000 none)) == .deleted)]
  r := r ++ [("node move: released -> deleted when the name holds another uid", phaseOf (step cfg rl (obs 7000 (some (pod "u2" .Proxy false)))) == .deleted)]
  let dl := mv "slave" .deleted
  r := r ++ [("node move: deleted waits while the pod is absent", phaseOf (step cfg dl (obs 8000 none)) == .deleted)]
  r := r ++ [("node move: deleted -> resyncing when a pod with a new uid exists",
              phaseOf (step cfg dl (obs 8000 (some (pod "u2" .Proxy false)))) == .resyncing)]
  let rs := mv "slave" .resyncing
  let newPod := fun (role : FlareRole) (active synced : Bool) =>
    { pod "u2" role false with active, synced }
  r := r ++ [("node move: resyncing waits while the new pod is not Active and synced",
              actOf (step cfg rs (obs 9000 (some (newPod .Slave false false)))) == .none
              && actOf (step cfg rs (obs 9000 (some (newPod .Slave true false)))) == .none)]
  r := r ++ [("node move: resyncing waits while the new pod is still a proxy (not yet seated as a replica)",
              actOf (step cfg rs (obs 9000 (some (newPod .Proxy true true)))) == .none)]
  r := r ++ [("node move: Active, synced replica -> the serving label comes back",
              actOf (step cfg rs (obs 9000 (some (newPod .Slave true true)))) == .restoreServing)]
  r := r ++ [("node move: the serving label is NEVER put back on a terminating pod",
              actOf (step cfg rs (obs 9000 (some { newPod .Slave true true with terminating := true }))) == .none)]
  r := r ++ [("node move: resyncing -> done once the new pod serves",
              phaseOf (step cfg rs (obs 9000 (some { newPod .Slave true true with serving := true }))) == .done)]
  r := r ++ [("node move: done is final", phaseOf (step cfg (mv "slave" .done) (obs 1 none)) == .done)]
  -- ── cancel (uncordon) ──────────────────────────────────────────────
  let c1 := step cfg (mv "slave" .proxied) (obs 4000 (some (pod "u1" .Proxy false)) false)
  r := r ++ [("node move: uncordon before released -> cancelled with generation + 1, and NO label action yet",
              phaseOf c1 == .cancelled && c1.1.generation == 2 && actOf c1 == .none && !c1.1.restored)]
  let c2 := step cfg c1.1 (obs 4100 (some (pod "u1" .Proxy false)) false)
  r := r ++ [("node move: the serving label is restored only AFTER the cancel is persisted (the next step)",
              actOf c2 == .restoreServing)]
  let c3 := step cfg c1.1 (obs 4200 (some (pod "u1" .Proxy true)) false)
  r := r ++ [("node move: cancelled + label present -> finished", c3.1.restored && c3.1.finished)]
  r := r ++ [("node move: a cancelled move does not restore the label of a terminating pod",
              actOf (step cfg c1.1 (obs 4300 (some { pod "u1" .Proxy false with terminating := true }) false)) == .none)]
  r := r ++ [("node move: unserved + uncordon -> cancelled",
              phaseOf (step cfg { mv "slave" .unserved with phaseMs := 1 } (obs 5000 (some (pod "u1" .Proxy false)) false)) == .cancelled)]
  r := r ++ [("node move: uncordon before the first step -> cancelled", phaseOf (step cfg (mv "master" .pending) (obs 1 (some (pod "u1" .Master)) false)) == .cancelled)]
  -- uncordon during a running handover waits for the handover's boundary
  r := r ++ [("node move: uncordon while the handover runs does not interrupt it",
              phaseOf (step cfg (mv "master" .handingOver) { obs 2000 (some (pod "u1" .Master)) false with handover := .running }) == .handingOver)]
  r := r ++ [("node move: uncordon after the handover finished -> cancelled, not proxied",
              phaseOf (step cfg (mv "master" .handingOver)
                { obs 3000 (some (pod "u1" .Proxy)) false with successorIsMaster := true }) == .cancelled)]
  -- released cannot be cancelled
  for ph in [Phase.released] do
    r := r ++ [("node move: after released an uncordon is refused — the move completes",
                phaseOf (step cfg { mv "slave" ph with releasedMs := 1 } (obs 2 (some (pod "u1" .Proxy false)) false)) == .released
                && !(mv "slave" ph).cancellable)]
  r := r ++ [("node move: cancellable only before released",
              (mv "slave" .pending).cancellable && (mv "slave" .unserved).cancellable
              && !(mv "slave" .released).cancellable && !(mv "slave" .deleted).cancellable)]
  r := r ++ [("node move: after released, an uncordoned node does not stop the delete",
              actOf (step cfg { mv "slave" .released with releasedMs := 0 } (obs 70000 (some (pod "u1" .Proxy false)) false)) == .deletePod)]
  -- handover retries
  let ab := { mv "master" .handingOver with attempts := 1, phaseMs := 1000 }
  let ab1 := step cfg ab { obs 2000 (some (pod "u1" .Master)) with handover := .aborted "gate" }
  r := r ++ [("node move: an aborted handover waits the retry delay", actOf ab1 == .none)]
  let ab2 := step cfg ab { obs 9000 (some (pod "u1" .Master)) with handover := .aborted "gate" }
  r := r ++ [("node move: ... then asks again with attempts + 1", actOf ab2 == .requestHandover && ab2.1.attempts == 2)]
  let ab3 := step cfg { ab with attempts := 3 } { obs 99000 (some (pod "u1" .Master)) with handover := .aborted "gate" }
  r := r ++ [("node move: after the attempts the move holds (the pod stays a master, nothing deleted)",
              ab3.1.held && actOf ab3 == .none && phaseOf ab3 == .handingOver)]
  -- the pod replaced / removed
  r := r ++ [("node move: a pod replaced under the same name before released -> cancelled",
              phaseOf (step cfg (mv "slave" .proxied) (obs 1 (some (pod "u9" .Proxy)))) == .cancelled)]
  -- ── minCopies ───────────────────────────────────────────────────────
  let others2 := [copy "a" "w2", copy "b" "w3"]
  r := r ++ [("node move: 3 copies (this + 2 real) start with minCopies 3", (startBlock cfg "slave" ["w1"] others2).isNone)]
  r := r ++ [("node move: 2 copies (this + 1 real) are refused with minCopies 3",
              (startBlock cfg "slave" ["w1"] [copy "a" "w2"]).isSome)]
  r := r ++ [("node move: minCopies 2 accepts them (the accepted risk)",
              (startBlock { cfg with minCopies := 2 } "slave" ["w1"] [copy "a" "w2"]).isNone)]
  r := r ++ [("node move: no other real copy is refused whatever minCopies is",
              (startBlock { cfg with minCopies := 1 } "slave" ["w1"] []).isSome)]
  r := r ++ [("node move: a copy on the cordoned node does not count",
              (startBlock cfg "slave" ["w1"] [copy "a" "w1", copy "b" "w3"]).isSome)]
  r := r ++ [("node move: a copy on ANOTHER cordoned node does not count either",
              (startBlock cfg "slave" ["w1", "w2"] [copy "a" "w2", copy "b" "w3"]).isSome)]
  r := r ++ [("node move: a copy that is not Active does not count",
              (startBlock cfg "slave" ["w1"] [copy "a" "w2" false, copy "b" "w3"]).isSome)]
  r := r ++ [("node move: a copy with another history does not count",
              (startBlock cfg "slave" ["w1"] [{ copy "a" "w2" with sameHistory := false }, copy "b" "w3"]).isSome)]
  r := r ++ [("node move: a copy with an open replica repair does not count",
              (startBlock cfg "slave" ["w1"] [{ copy "a" "w2" with repairOpen := true }, copy "b" "w3"]).isSome)]
  r := r ++ [("node move: a copy the master dropped / failed writes to does not count",
              (startBlock cfg "slave" ["w1"] [{ copy "a" "w2" with dropIncreased := true }, copy "b" "w3"]).isSome)]
  r := r ++ [("node move: a proxy holds no copy and is never blocked", (startBlock cfg "proxy" ["w1"] []).isNone)]
  r := r ++ [("node move: a refusal says why (text for status / Event / alert)",
              match startBlock cfg "slave" ["w1"] [copy "a" "w2"] with
              | some w => w.length > 20 | none => false)]
  -- ── next: one node / one pod at a time ──────────────────────────────
  -- copies on w3/w4: with w1 and w2 both cordoned, a copy on w2 would not count
  let others34 := [copy "a" "w3", copy "b" "w4"]
  let c0 := cand "c-nodes-0" "w1" "slave" others34
  let c1c := cand "c-nodes-1" "w2" "slave" others34
  let l0 : Ledger := {}
  let (st0, bl0) := next cfg l0 ["w1", "w2"] [c1c, c0] 100
  r := r ++ [("node move: two cordoned nodes -> exactly one move starts (the first by name)",
              match st0 with | .start m => m.pod == "c-nodes-0" && m.node == "w1" && m.phase == .pending | .idle => false)]
  let l1 := match st0 with | .start m => l0.upsert m | .idle => l0
  r := r ++ [("node move: while one runs, the second does not start",
              match (next cfg l1 ["w1", "w2"] [c1c, c0] 200).1 with | .idle => true | .start _ => false)]
  let done := l1.moves.map fun m => { m with phase := .done }
  let l2 : Ledger := { l1 with moves := done, seq := 1 }
  r := r ++ [("node move: after the first is done, the second starts",
              match (next cfg l2 ["w1", "w2"] [c1c, c0] 300).1 with | .start m => m.pod == "c-nodes-1" | .idle => false)]
  r := r ++ [("node move: a finished move for the pod is not started again by the same node",
              match (next cfg l2 ["w1"] [c0] 300).1 with | .idle => true | .start _ => false)]
  r := r ++ [("node move: the recreated pod (new UID) on a cordoned node starts a new move",
              match (next cfg l2 ["w1"] [{ c0 with uid := "uid-new" }] 300).1 with
              | .start m => m.podUid == "uid-new" | .idle => false)]
  r := r ++ [("node move: replicas go before masters",
              match (next cfg l0 ["w1"] [cand "c-nodes-0" "w1" "master" others2 (some "k1"), cand "c-nodes-2" "w1" "slave" others2] 1).1 with
              | .start m => m.role == "slave" | .idle => false)]
  r := r ++ [("node move: a master with no successor on an uncordoned node is blocked, not started",
              match next cfg l0 ["w1"] [cand "c-nodes-0" "w1" "master" others2 none] 1 with
              | (.idle, bl) => bl.length == 1
              | _ => false)]
  r := r ++ [("node move: below minCopies nothing starts and the pod is reported blocked",
              match next cfg l0 ["w1"] [cand "c-nodes-0" "w1" "slave" [copy "a" "w2"]] 1 with
              | (.idle, bl) => bl.length == 1 && bl.head!.node == "w1" && bl.head!.reason.length > 0
              | _ => false)]
  r := r ++ [("node move: a blocked pod does not hold up another that can move",
              match next cfg l0 ["w1", "w2"] [cand "c-nodes-0" "w1" "slave" [copy "a" "w3"], cand "c-nodes-1" "w2" "slave" others34] 1 with
              | (.start m, bl) => m.pod == "c-nodes-1" && bl.length == 1
              | _ => false)]
  r := r ++ [("node move: pods on schedulable nodes are not candidates",
              match (next cfg l0 ["w9"] [c0] 1).1 with | .idle => true | _ => false)]
  r := r ++ [("node move: bl0 reports nothing for startable pods", bl0.isEmpty)]
  -- ── the node guard ──────────────────────────────────────────────────
  let released := { mv "slave" .released with releasedMs := 5 }
  let lr : Ledger := { moves := [released] }
  let g := fun (l : Ledger) (cordoned : List String) (uid node : String) (serving : Bool) =>
    guard l cordoned "c-nodes-0" uid node serving (some FlareRole.Proxy)
  r := r ++ [("node guard: released, same uid, no serving label, node still cordoned -> permit",
              match g lr ["w1"] "u1" "w1" false with | .permit m => m.id == "mv1-u1" | _ => false)]
  r := r ++ [("node guard: another uid is refused", match g lr ["w1"] "u9" "w1" false with | .hold _ => true | _ => false)]
  r := r ++ [("node guard: a serving label on the pod refuses", match g lr ["w1"] "u1" "w1" true with | .hold _ => true | _ => false)]
  r := r ++ [("node guard: an uncordoned node refuses (the cordon was withdrawn)", match g lr [] "u1" "w1" false with | .hold _ => true | _ => false)]
  r := r ++ [("node guard: a pod on another node than the move's refuses", match g lr ["w1", "w2"] "u1" "w2" false with | .hold _ => true | _ => false)]
  for ph in [Phase.pending, .handingOver, .proxied, .unserved] do
    r := r ++ [(s!"node guard: phase {ph} is held (429), never allowed",
                match g { moves := [mv "slave" ph] } ["w1"] "u1" "w1" false with | .hold _ => true | _ => false)]
  r := r ++ [("node guard: a cancelled move does not release (even with its old released shape)",
              match g { moves := [{ released with phase := .cancelled, restored := true }] } ["w1"] "u1" "w1" false with
              | .hold _ => true | .unrelated => true | _ => false)]
  r := r ++ [("node guard: a data pod on a cordoned node with no move yet is held",
              match guard {} ["w1"] "c-nodes-0" "u1" "w1" true (some FlareRole.Slave) with | .hold _ => true | _ => false)]
  r := r ++ [("node guard: a proxy on a cordoned node with no move is left to the usual rules",
              guard {} ["w1"] "c-nodes-0" "u1" "w1" true (some FlareRole.Proxy) == .unrelated)]
  r := r ++ [("node guard: a pod on a schedulable node is unrelated",
              guard {} [] "c-nodes-0" "u1" "w1" true (some FlareRole.Slave) == .unrelated)]
  let adm := lr.admit released "review-7"
  r := r ++ [("node guard: admit writes the AdmissionReview uid and nothing else of the move",
              (adm.moves.head!.admittedUid == "review-7") && ({ adm.moves.head! with admittedUid := "" } == released))]
  -- ── cancel vs released race: whichever is persisted first wins ─────
  -- the operator's two candidate writes from the SAME read, `released` and
  -- `cancelled`: they are different values of the same record, so a CAS on
  -- the record's resourceVersion lets exactly one commit; a guard reading
  -- the committed one cannot see the other.
  let readBoth := step cfg un (drainedObs 5000 (some (pod "u1" .Proxy false)))
  let readCancel := step cfg un (obs 5000 (some (pod "u1" .Proxy false)) false)
  r := r ++ [("node move: race — from one read the operator may write released OR cancelled, never both",
              phaseOf readBoth == .released && phaseOf readCancel == .cancelled)]
  let lc : Ledger := { moves := [readCancel.1] }
  r := r ++ [("node move: race — cancel committed first: the guard refuses (no released to see)",
              match g lc ["w1"] "u1" "w1" false with | .hold _ => true | _ => false)]
  r := r ++ [("node move: race — released committed first: the next step has no cancel",
              phaseOf (step cfg readBoth.1 (obs 5100 (some (pod "u1" .Proxy false)) false)) == .released)]
  r := r ++ [("node move: a cancel bumps the generation; a later move of the pod starts with a new id",
              readCancel.1.generation == 2
              && (match (next cfg { seq := 1, moves := [{ readCancel.1 with restored := true }] } ["w1"] [c0] 9).1 with
                  | .start m => m.id != readCancel.1.id | .idle => false))]
  -- ── restart: the record is all the operator needs ───────────────────
  let full : Ledger := { seq := 2, moves := [{ mv "master" .handingOver with attempts := 2, reason := "x" }, { released with admittedUid := "r" }],
                         blocked := [{ pod := "c-nodes-3", node := "w1", reason := "min" }] }
  r := r ++ [("node move: the ledger survives a JSON round trip (operator restart)",
              match Ledger.fromJson? full.toJson with | some l => l == full | none => false)]
  r := r ++ [("node move: a malformed move fails the whole read (never forgotten silently)",
              (Ledger.fromJson? (Lean.Json.mkObj [("moves", Lean.Json.arr #[Lean.Json.mkObj [("id", Lean.Json.str "x")]])])).isNone)]
  let restored := (Ledger.fromJson? ({ moves := [mv "slave" .unserved] : Ledger }).toJson).getD {}
  r := r ++ [("node move: after a restart the move resumes where it was (unserved -> released)",
              match restored.active with
              | some m => phaseOf (step cfg { m with phaseMs := 4000 } (drainedObs 5000 (some (pod "u1" .Proxy false)))) == .released
              | none => false)]
  r := r ++ [("node move: after a restart in released the delete still follows",
              match (Ledger.fromJson? ({ moves := [{ released with releasedMs := 1 }] } : Ledger).toJson).bind (·.active) with
              | some m => actOf (step cfg m (obs 70000 (some (pod "u1" .Proxy false)))) == .deletePod
              | none => false)]
  -- held keys: the demoted pod is not re-seated by the assignment
  r := r ++ [("node move: heldKeys keeps the emptied pod and the successor out of assignment",
              ({ moves := [mv "slave" .unserved] } : Ledger).heldKeys == ["k0"]
              && ({ moves := [mv "master" .handingOver] } : Ledger).heldKeys == ["k1", "k0"]
              && ({ moves := [mv "master" .pending] } : Ledger).heldKeys == ["k1"]
              -- 41136280524 C2: the slave demoted while pending stays held
              && ({ moves := [mv "slave" .pending] } : Ledger).heldKeys.contains "k0"
              && ({ moves := [mv "slave" .resyncing] } : Ledger).heldKeys == []
              && ({ moves := [mv "slave" .done] } : Ledger).heldKeys == [])]
  r := r ++ [("node move: trim keeps the unfinished moves and the last few finished",
              let ms := (List.range 10).map fun i => { mv "slave" .done with id := s!"d{i}" }
              let l : Ledger := { moves := ms ++ [mv "slave" .proxied] }
              l.trim.moves.length == 7 && l.trim.active.isSome)]
  return r

end FlareOperator.UnitTestsNodeMove
