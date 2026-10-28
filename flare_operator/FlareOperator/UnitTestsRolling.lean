/-
  UnitTestsRolling.lean — checks of StateMachine/Rolling.lean (A0), in their
  own module like UnitTestsHandover. Called from UnitTests.run.
-/
import FlareOperator.StateMachine.Rolling

namespace FlareOperator.UnitTestsRolling

open FlareOperator.K8s
open FlareOperator.Rolling

private def node (name : String) (role : FlareRole) (st : FlareState) (part : Int) : FlareNode :=
  { serverName := name, serverPort := 12121, role := role, state := st, partition := part }

private def pair : FlareClusterState :=
  { nodeMap := [("m:12121", node "m" .Master .Active 0), ("s:12121", node "s" .Slave .Active 0)],
    partitionMap := [(0, { master := some "m:12121", slaves := ["s:12121"] })] }

private def pod (name key rev : String) (term : Bool := false) : Candidate :=
  { name, nodeKey := key, uid := s!"uid-{name}", revision := rev, ready := true, terminating := term }

def results : List (String × Bool) := Id.run do
  let mut r : List (String × Bool) := []
  let m0 := pod "nodes-0" "m:12121" "old"
  let s1 := pod "nodes-1" "s:12121" "old"
  let masters := ["m:12121"]
  r := r ++ [("rolling: every pod on the update revision → idle",
              match decide "old" [m0, s1] masters 5 2 with | .idle _ => true | _ => false)]
  r := r ++ [("rolling: an unlabelled pod is never replaced",
              outdated "new" [pod "x" "x:1" ""] == [])]
  r := r ++ [("rolling: not stable for long enough → wait",
              match decide "new" [m0, s1] masters 1 2 with | .wait _ => true | _ => false)]
  r := r ++ [("rolling: a terminating pod → wait (one at a time)",
              match decide "new" [m0, pod "nodes-1" "s:12121" "old" true] masters 5 2 with | .wait _ => true | _ => false)]
  r := r ++ [("rolling: the replica is replaced before the master",
              match decide "new" [m0, s1] masters 5 2 with | .delete c _ => c.name == "nodes-1" | _ => false)]
  r := r ++ [("rolling: with only the master left, the master is deleted (the handover moves it)",
              match decide "new" [m0, pod "nodes-1" "s:12121" "new"] masters 5 2 with | .delete c _ => c.name == "nodes-0" | _ => false)]
  r := r ++ [("rolling: no update revision → idle", match decide "" [m0, s1] masters 5 2 with | .idle _ => true | _ => false)]
  -- ordinal order is numeric (review of 97c487f)
  let many := (List.range 12).map fun i => pod s!"node-sw-nodes-{i}" s!"n{i}:12121" "old"
  r := r ++ [("rolling: the highest StatefulSet ordinal goes first, numerically (nodes-11 before nodes-9)",
              match decide "new" many ["n0:12121"] 5 2 with | .delete c _ => c.name == "node-sw-nodes-11" | _ => false)]
  let tenNine := [pod "x-nodes-9" "a:1" "old", pod "x-nodes-10" "b:1" "old"]
  r := r ++ [("rolling: nodes-10 is replaced before nodes-9",
              match decide "new" tenNine [] 5 2 with | .delete c _ => c.name == "x-nodes-10" | _ => false)]
  r := r ++ [("rolling: ordinal parses the trailing number", ordinal "a-b-nodes-12" == some 12 && ordinal "nope" == none)]
  -- a pod whose revision is unknown blocks the rollout explicitly (review of 97c487f)
  let unk := pod "nodes-1" "s:12121" ""
  r := r ++ [("rolling: current + unknown revision → wait (never idle, never deleted)",
              match decide "new" [pod "nodes-0" "m:12121" "new", unk] masters 5 2 with
              | .wait why => why.startsWith "the revision of" | _ => false)]
  r := r ++ [("rolling: outdated + unknown revision → wait, the unknown pod is not deleted",
              match decide "new" [m0, unk] masters 5 2 with | .wait _ => true | _ => false)]
  -- stability
  let ready := ["m:12121", "s:12121"]
  r := r ++ [("rolling: stable = Active master + Active, Ready, eligible slave, nothing busy",
              stable pair 1 ready ["s:12121"] false)]
  r := r ++ [("rolling: a slave that is not eligible (R3 / rebuilding) is not stable",
              !stable pair 1 ready [] false)]
  r := r ++ [("rolling: a pod not Ready is not stable", !stable pair 1 ["m:12121"] ["s:12121"] false)]
  r := r ++ [("rolling: a running handover / repair is not stable", !stable pair 1 ready ["s:12121"] true)]
  let down := pair.addNode "m:12121" (node "m" .Master .Down 0)
  r := r ++ [("rolling: a master that is not Active is not stable", !stable down 1 ready ["s:12121"] false)]
  return r

end FlareOperator.UnitTestsRolling
