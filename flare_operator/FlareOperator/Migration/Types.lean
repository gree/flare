/-
  Migration/Types.lean — FlareMigration CRD views and the PURE migration FSM.

  A FlareMigration shrinks/reshapes a cluster blue/green style:

    Pending → Provisioning → Duplicating → Forwarding → AwaitingCutover
            → CutOver → AwaitingRetire → Retired            (happy path)
    any pre-cutover phase --abort--> Aborting → Aborted     (rollback path)

  The DECISION function (`migStep`) is pure: given the spec (user intent),
  the current phase, and this tick's observations, it returns the next phase
  and at most ONE action for the IO layer to execute. All safety gates live
  here so they are machine-checkable:

    * `paused` freezes everything (no action, no phase change),
    * cutover fires only with `approveCutover`,
    * retire (source deletion) fires only with `approveRetire`,
    * abort is refused once cutover has happened (clients already moved).
-/

import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Migration

open FlareOperator.K8s

/-! ## Phases -/

inductive MigPhase where
  | Pending          -- CR seen, nothing done yet
  | Provisioning     -- target cluster resources created, waiting for it to be Ready
  | Duplicating      -- source duplicates into target (dump + dual-write)
  | Forwarding       -- counts converged; source switched to mode=forward
  | AwaitingCutover  -- parked on the approveCutover human gate
  | CutOver          -- external Service selector flipped to the target
  | AwaitingRetire   -- parked on the approveRetire human gate
  | Retired          -- source StatefulSet + CR deleted (terminal)
  | Aborting         -- rollback in progress (stop replication, delete target)
  | Aborted          -- rollback complete (terminal)
  deriving Repr, BEq, DecidableEq

def MigPhase.toString : MigPhase → String
  | .Pending => "Pending"
  | .Provisioning => "Provisioning"
  | .Duplicating => "Duplicating"
  | .Forwarding => "Forwarding"
  | .AwaitingCutover => "AwaitingCutover"
  | .CutOver => "CutOver"
  | .AwaitingRetire => "AwaitingRetire"
  | .Retired => "Retired"
  | .Aborting => "Aborting"
  | .Aborted => "Aborted"

def MigPhase.fromString : String → Option MigPhase
  | "Pending" => some .Pending
  | "Provisioning" => some .Provisioning
  | "Duplicating" => some .Duplicating
  | "Forwarding" => some .Forwarding
  | "AwaitingCutover" => some .AwaitingCutover
  | "CutOver" => some .CutOver
  | "AwaitingRetire" => some .AwaitingRetire
  | "Retired" => some .Retired
  | "Aborting" => some .Aborting
  | "Aborted" => some .Aborted
  | _ => none

/-- Phases at or past the point of no return: clients may already be on the
    target, so rollback (abort) must be refused. -/
def MigPhase.pastPointOfNoReturn : MigPhase → Bool
  | .CutOver | .AwaitingRetire | .Retired => true
  | _ => false

def MigPhase.terminal : MigPhase → Bool
  | .Retired | .Aborted => true
  | _ => false

/-! ## Spec / observation views -/

structure MigTargetSpec where
  name : String
  partitions : Nat := 1
  replicas : Nat := 2
  persistenceSize : String := "10Gi"
  drainSeconds : Nat := 60
  deriving Repr, BEq

structure MigSpec where
  source : String
  target : MigTargetSpec
  paused : Bool := false
  approveCutover : Bool := false
  approveRetire : Bool := false
  abort : Bool := false
  externalService : String := ""
  deriving Repr, BEq

/-- One tick's worth of world state, gathered by the IO layer. -/
structure MigObs where
  /-- Target FlareCluster exists AND its node map shows every partition with
      an Active master and all replicas Active. -/
  targetReady : Bool := false
  /-- Total curr_items summed over the SOURCE cluster's partition masters. -/
  sourceKeys : Nat := 0
  /-- Total curr_items summed over the TARGET cluster's partition masters. -/
  targetKeys : Nat := 0
  /-- Consecutive ticks the counts have been converged (targetKeys ≥
      sourceKeys with both readable). Maintained by the controller in
      status; convergence must hold for several ticks so a dump that has
      not yet STARTED (both counts equal by accident, e.g. 0=0) or a
      mid-dump plateau does not advance the phase prematurely. -/
  convergedTicks : Nat := 0
  /-- The source cluster's extra.conf carries `cluster-replication-mode =
      forward` (the forward switch has been rendered + applied). -/
  sourceForwardApplied : Bool := false
  deriving Repr, BEq

/-- Convergence dwell: how many consecutive converged ticks are required
    before Duplicating advances. At the 5s reconcile interval this is ~30s
    of stable convergence. -/
def convergenceDwellTicks : Nat := 6

/-! ## Actions -/

inductive MigAction where
  | none
  | provisionTarget      -- create target CR/CMs/Services/StatefulSet/operator
  | startDuplicate       -- patch source CR: clusterReplication duplicate → target
  | switchForward        -- patch source CR: mode = forward
  | doCutover            -- flip the external Service selector to the target
  | doRetire             -- delete source StatefulSet + FlareCluster CR (PVCs kept)
  | doAbort              -- stop replication on source, delete target resources
  deriving Repr, BEq, DecidableEq

/-! ## The pure step function -/

/-- One migration FSM step. Total and effect-free; the IO layer executes the
    returned action and persists the returned phase. -/
def migStep (spec : MigSpec) (phase : MigPhase) (obs : MigObs) : MigPhase × MigAction :=
  -- pause freezes everything, including aborts: the operator takes NO action
  -- of any kind while the user holds the migration still.
  if spec.paused then
    (phase, .none)
  -- abort: honored from any phase before the point of no return; refused
  -- after (clients may already be on the target). Terminal phases stay put.
  else if spec.abort && !phase.pastPointOfNoReturn && !phase.terminal then
    -- keep issuing the (idempotent) rollback; land on Aborted the tick after
    ((if phase == .Aborting then .Aborted else .Aborting), .doAbort)
  else
    match phase with
    | .Pending => (.Provisioning, .provisionTarget)
    | .Provisioning =>
      if obs.targetReady then (.Duplicating, .startDuplicate)
      else (.Provisioning, .none)
    | .Duplicating =>
      if obs.convergedTicks ≥ convergenceDwellTicks then (.Forwarding, .switchForward)
      else (.Duplicating, .none)
    | .Forwarding =>
      if obs.sourceForwardApplied then (.AwaitingCutover, .none)
      else (.Forwarding, .none)
    | .AwaitingCutover =>
      if spec.approveCutover then (.CutOver, .doCutover)
      else (.AwaitingCutover, .none)
    | .CutOver =>
      (.AwaitingRetire, .none)
    | .AwaitingRetire =>
      if spec.approveRetire then (.Retired, .doRetire)
      else (.AwaitingRetire, .none)
    | .Retired => (.Retired, .none)
    | .Aborting => (.Aborted, .doAbort)
    | .Aborted => (.Aborted, .none)

/-! ## Safety theorems

    These are the gates the design promises; they hold for EVERY spec, phase
    and observation, by case analysis on the (finite) step function. -/

/-- `paused` freezes the migration completely: no phase change, no action. -/
theorem migStep_paused_frozen (spec : MigSpec) (phase : MigPhase) (obs : MigObs)
    (h : spec.paused = true) :
    migStep spec phase obs = (phase, .none) := by
  simp [migStep, h]

/-- Cutover happens only with the user's explicit approval. -/
theorem migStep_cutover_requires_approval (spec : MigSpec) (phase : MigPhase) (obs : MigObs)
    (h : (migStep spec phase obs).2 = .doCutover) :
    spec.approveCutover = true := by
  by_cases hp : spec.paused
  · simp [migStep, hp] at h
  · by_cases ha : spec.abort && !phase.pastPointOfNoReturn && !phase.terminal
    · cases phase <;> simp_all [migStep]
    · cases phase <;> by_cases hc : spec.approveCutover <;>
        simp_all [migStep, convergenceDwellTicks] <;> split at h <;> simp_all

/-- Retiring (deleting the source cluster) happens only with the user's
    explicit approval. -/
theorem migStep_retire_requires_approval (spec : MigSpec) (phase : MigPhase) (obs : MigObs)
    (h : (migStep spec phase obs).2 = .doRetire) :
    spec.approveRetire = true := by
  by_cases hp : spec.paused
  · simp [migStep, hp] at h
  · by_cases ha : spec.abort && !phase.pastPointOfNoReturn && !phase.terminal
    · cases phase <;> simp_all [migStep]
    · cases phase <;> by_cases hr : spec.approveRetire <;>
        simp_all [migStep, convergenceDwellTicks] <;> split at h <;> simp_all

/-- Abort is never acted on once the migration is past the point of no
    return: after cutover the external Service already points at the target,
    so rollback would strand clients. -/
theorem migStep_no_abort_past_cutover (spec : MigSpec) (phase : MigPhase) (obs : MigObs)
    (h : phase.pastPointOfNoReturn = true) :
    (migStep spec phase obs).2 ≠ .doAbort := by
  by_cases hp : spec.paused
  · simp [migStep, hp]
  · cases phase <;> simp_all [migStep, MigPhase.pastPointOfNoReturn] <;>
      split <;> simp_all

end FlareOperator.Migration
