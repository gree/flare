import FlareOperator.StateMachine.K8sReconciler
import FlareOperator.StateMachine.PromotionEvidence
import FlareOperator.StateMachine.Reconciler

/-!
  history-tracking 10 (rc67 matrix 38545812141 attempt 1) — deterministic
  replay of the operator's promotion decision with the inputs the failing
  and the passing order produced. No timing: each case fixes what the
  replica's R3 validator had (or had not yet) reported when the operator's
  first pass read it.

  Run (any tree): `lake env lean --run FlareOperator/Repro/HistoryTracking10.lean`
  It PRINTS what the pure decision does; it asserts nothing (it is evidence,
  not a gate).
-/

open FlareOperator
open FlareOperator.K8s
open FlareOperator.K8sReconciler

namespace FlareOperator.Repro.HT10

def nd (r : FlareRole) (st : FlareState) (p : Int) (nm : String) (lmo : Int := -1) : FlareNode :=
  { serverName := nm, serverPort := 12121, role := r, state := st, partition := p, lastMasterOf := lmo }

def crd : FlareClusterView :=
  { metadata := { name := some "ht10", «namespace» := some "default" }
    spec := { partitions := 1, replicas := 2 } }

def masterOf (s : FlareClusterState) : Option String :=
  (s.nodeMap.find? (fun kv => kv.2.role == FlareRole.Master)).map (·.1)

def logs (effs : List FlareEffect) : List String :=
  effs.filterMap fun | .Log m => some m | _ => none

/-- The R3 stats a WAL follower reports. `state` = repl_read_source_state. -/
def stats (eligible : Nat) (state : String) (reason : String) (follow : String) : String :=
  String.intercalate "\r\n"
    [ s!"STAT repl_read_source_eligible {eligible}", s!"STAT repl_read_source_state {state}",
      s!"STAT repl_read_source_reason {reason}", s!"STAT repl_follow_last_reason {follow}",
      "STAT rocksdb_copy_identity_consistent 1", "STAT rocksdb_quarantined 0",
      "STAT rocksdb_copy_partial 0", "STAT rebuild_in_flight 0", "STAT rebuild_parked 0",
      "STAT rocksdb_switch_unresolved 0", "STAT rocksdb_corrupted 0",
      "STAT reconstruction_current_state none", "STAT curr_items 40",
      "STAT rocksdb_master_id M1", "STAT rocksdb_source_epoch E1",
      "STAT rocksdb_copy_id C1", "STAT reconstruction_boot_id B1",
      "STAT rocksdb_partition_binding -", "STAT rocksdb_restored_unverified 0", "END"]

/-- Attempt 1: R3 still BOUND from before the cut (validator not yet re-run). -/
def staleBound : String := stats 1 "eligible" "bound" "peer_unreachable"
/-- Attempt 2: the validator re-ran against the empty returning ex-master. -/
def rebuiltVsEmpty : String :=
  stats 0 "needs_rebuild" "lineage differs: copy M1, master m M2" "peer_unreachable"

def obsNoMaster : PromotionEvidence.Observed :=
  { mapPrepare := false, mapActive := true, podReady := true, partitionHasMaster := false,
    lastMasterHistory := some ("M1", "E1") }

/-- Main's followUnfitKeys = FollowEvidence.unfit ++ notReadyActive ++
    sourceIneligible (classes other than eligible/legacy/empty). The follower
    here is FollowEvidence-UNPROVEN (disconnected, its own backlog 0), never
    unfit; only the R3 class can put it into the excluded list. -/
def excludedFor (cls : PromotionEvidence.Class) : List String :=
  match cls with
  | .eligible | .legacy | .empty => []
  | _ => ["f"]

def run (title : String) (st : FlareClusterState) (live dataBearing knownEmpty : List String)
    (reply : String) : IO Unit := do
  let cls := PromotionEvidence.classify (some reply) obsNoMaster
  let excl := excludedFor cls
  let after := promoteMasterlessPartitions st crd live [] dataBearing excl true [] knownEmpty []
  let s : FlareReconcileState :=
    { followUnfitKeys := excl, followUnprovenKeys := ["f"], followHoldEnabled := true,
      livePodKeys := live, dataBearingKeys := dataBearing, knownEmptyKeys := knownEmpty }
  let effs := logs (refillHoldEffects st after crd s)
  let commit := PromotionEvidence.commitAllows (some cls) ⟨some "u", some "B1", some "C1"⟩ ⟨some "u", some "B1", some "C1"⟩
  IO.println s!"{title}\n  class(f)={cls.label} excluded={excl} -> crowned={masterOf after} commitAllows={commit.1}\n  logs={effs.map (·.take 90)}"

def main : IO Unit := do
  -- (A) the CI case: ex-master m came back EMPTY (read empty, live), f is
  --     the only data holder, missing 20 acknowledged writes
  let backEmpty : FlareClusterState :=
    ({ nodeMap := [("m", nd .Slave .Prepare 0 "m" 0), ("f", nd .Slave .Active 0 "f")], nodeMapVersion := 9 }
      : FlareClusterState).rebuildPartitionMap
  run "(A1) ex-master back EMPTY, R3 stale BOUND (attempt-1 order)" backEmpty ["m", "f"] ["f"] ["m"] staleBound
  run "(A2) ex-master back EMPTY, R3 needs_rebuild (attempt-2 order)" backEmpty ["m", "f"] ["f"] ["m"] rebuiltVsEmpty
  -- (B) ex-master AWAY (its pod not live; PVC/emptyDir may still hold the 20 writes)
  let away : FlareClusterState :=
    ({ nodeMap := [("m", nd .Proxy .Down (-1) "m" 0), ("f", nd .Slave .Active 0 "f")], nodeMapVersion := 9 }
      : FlareClusterState).rebuildPartitionMap
  run "(B1) ex-master AWAY, R3 stale BOUND" away ["f"] ["f"] [] staleBound
  run "(B2) ex-master AWAY, R3 needs_rebuild/lagging" away ["f"] ["f"] [] rebuiltVsEmpty
  -- (C) ex-master BACK WITH its data (same history, the 20 writes on it)
  let backData : FlareClusterState :=
    ({ nodeMap := [("m", nd .Slave .Prepare 0 "m" 0), ("f", nd .Slave .Active 0 "f")], nodeMapVersion := 9 }
      : FlareClusterState).rebuildPartitionMap
  run "(C1) ex-master BACK WITH DATA, R3 stale BOUND" backData ["m", "f"] ["m", "f"] [] staleBound
  run "(C2) ex-master BACK WITH DATA, R3 lagging" backData ["m", "f"] ["m", "f"] [] rebuiltVsEmpty

end FlareOperator.Repro.HT10

def main : IO Unit := FlareOperator.Repro.HT10.main
