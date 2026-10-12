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
    * abort is refused once the forward switch was issued (from then on the
      source proxies every client read and write to the target, so the
      target holds acknowledged writes the source does not — deleting it
      would lose them),
    * the forward switch fires only with a verification APPROVAL bound to
      THIS attempt and to the live masters (`forwardApproval`, the line V
      prints for a MATCH: attempt id, verification time, and per partition
      master on both sides pod / pod UID / process start / master id / copy
      id / copy epoch / sequence number — re-read and compared at the
      switch) AND evidence for this attempt: every source master's seed
      completed after the attempt began, no loss counter moved since the
      attempt began (Unknown — a restart, a counter reset, an unreadable
      master, a baseline taken after replication was already on — holds),
      and the key counts converged. Equal counts alone never advance
      (2026-10-11: they did, and the forward switch is the first
      client-visible step); a boolean (`approveForward`) is not accepted as
      a verification,
    * Forwarding → AwaitingCutover re-checks the same approval once the
      source applied forward mode: a write (or a restart, re-seed, reap)
      between the switch-time check and the apply moves a position and
      holds the migration in Forwarding until a new V MATCH is bound.
      Writes stay stopped until AwaitingCutover — the write stop is the
      operator's premise, never observed as a fence.
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

/-- Phases in which abort is refused: from the forward switch on, the
    source proxies client reads and writes to the target (flared forward
    mode: op_set/op_delete answer from the proxy and skip local storage), so
    the target holds acknowledged writes the source does not. doAbort
    deletes the target — refused here, as after cutover. -/
def MigPhase.abortRefused : MigPhase → Bool
  | .Forwarding | .AwaitingCutover | .CutOver | .AwaitingRetire | .Retired => true
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
  /-- Obsolete boolean gate: read only to say it is NOT accepted (a manual
      bool is not a verification). -/
  approveForward : Bool := false
  /-- The approval line V printed for a MATCH (scripts/flare_verify_copy.py
      `approval`): `v=1|verdict=MATCH|verified_at=<unix>|attempt=<id>|src=..|dst=..`.
      Checked against the live masters at the switch and again after the
      source applied forward mode. -/
  forwardApproval : String := ""
  approveCutover : Bool := false
  approveRetire : Bool := false
  abort : Bool := false
  externalService : String := ""
  deriving Repr, BEq

/-- What the source's loss counters say about the attempt so far. -/
inductive LossVerdict where
  | clean
  | lost (n : Nat)
  /-- the comparison with the attempt baseline was lost or never made -/
  | unknown (why : String)
  deriving Repr, BEq, DecidableEq, Inhabited

/-- One source partition master's counters, as read for the gate. -/
structure SrcCounters where
  pod : String
  podUid : String
  /-- flared start time, `time - uptime` (seconds; ±1 from rounding) -/
  boot : Nat
  /-- `cluster_replication` on/off at the time of the read -/
  replicating : Bool
  /-- proxy_write_dropped + cluster_replication[forward_dropped_* |
      forward_failed_* | forward_missing_* | seed_failed] -/
  loss : Nat
  seedCompleted : Nat
  seedState : String
  deriving Repr, BEq, Inhabited

def SrcCounters.serialize (c : SrcCounters) : String :=
  s!"{c.pod} {c.podUid} {c.boot} {if c.replicating then 1 else 0} {c.loss} {c.seedCompleted} {c.seedState}"

def SrcCounters.parse (s : String) : Option SrcCounters :=
  match (s.splitOn " ").filter (· != "") with
  | [pod, uid, boot, rep, loss, sc, st] => do
    let b ← boot.toNat?
    let l ← loss.toNat?
    let c ← sc.toNat?
    let r ← (if rep == "1" then some true else if rep == "0" then some false else none)
    some { pod, podUid := uid, boot := b, replicating := r, loss := l, seedCompleted := c, seedState := st }
  | _ => none

/-- Attempt baseline as stored in status (`;`-separated); `none` when any
    entry is malformed (a malformed baseline is no baseline). -/
def parseBaseline (s : String) : Option (List SrcCounters) :=
  if s.trim.isEmpty then some []
  else ((s.splitOn ";").filter (·.trim != "")).mapM SrcCounters.parse

def serializeBaseline (cs : List SrcCounters) : String :=
  ";".intercalate (cs.map SrcCounters.serialize)

/-- Same process as at the baseline: same pod, same pod UID, same start
    time within the 1 s rounding of `time - uptime`. -/
def sameProcess (b c : SrcCounters) : Bool :=
  b.pod == c.pod && b.podUid == c.podUid && (b.boot + 2 ≥ c.boot && c.boot + 2 ≥ b.boot)

/-- Loss over the whole attempt. Unknown whenever the comparison is not
    sound: no baseline, a baseline read while replication was already on
    (a seed or forwards may have lost writes before it), the set of masters
    changed, a master restarted (counters reset) or a counter went down. -/
def lossVerdict (baseline : List SrcCounters) (current : Option (List SrcCounters)) : LossVerdict :=
  match current with
  | none => .unknown "a source master could not be read"
  | some cur =>
    if baseline.isEmpty then .unknown "no attempt baseline recorded"
    else if baseline.any (·.replicating) then
      .unknown "the attempt baseline was read while replication was already on"
    else if cur.length != baseline.length then
      .unknown s!"source masters changed ({baseline.length} at the baseline, {cur.length} now)"
    else
      let pairs := cur.map fun c => (c, baseline.find? (·.pod == c.pod))
      match pairs.find? (fun (c, b) => match b with | none => true | some b => !sameProcess b c) with
      | some (c, _) => .unknown s!"{c.pod} is not the process of the baseline (restart or replaced pod): its counters cannot be compared"
      | none =>
        let regress := pairs.find? fun (c, b) => match b with
          | some b => c.loss < b.loss || c.seedCompleted < b.seedCompleted
          | none => true
        match regress with
        | some (c, _) => .unknown s!"{c.pod}: a counter went down since the baseline"
        | none =>
          let n := pairs.foldl (fun acc (c, b) => acc + (c.loss - (b.map (·.loss)).getD c.loss)) 0
          if n == 0 then .clean else .lost n

/-- Every source master completed a seed during this attempt (same process
    as the baseline, its seed_completed above the baseline, state completed_*). -/
def seedCompletedSince (baseline : List SrcCounters) (current : Option (List SrcCounters)) : Bool :=
  match current with
  | none => false
  | some cur =>
    !cur.isEmpty && cur.length == baseline.length && cur.all fun c =>
      match baseline.find? (·.pod == c.pod) with
      | none => false
      | some b => sameProcess b c && c.seedCompleted > b.seedCompleted && c.seedState.startsWith "completed_"

/-- Converged ticks, counted only while Duplicating (a count that matched
    during Provisioning — 0 = 0 on an empty source — never pre-loads it). -/
def nextConvergedTicks (phase : MigPhase) (prev : Nat) (src tgt : Option Nat) : Nat :=
  if phase != .Duplicating then 0
  else match src, tgt with
    | some s, some t => if t ≥ s then prev + 1 else 0
    | _, _ => 0

/-- One partition master's identity and position, as bound by a V report. -/
structure NodeIdent where
  pod : String
  podUid : String
  boot : Nat
  masterId : String
  copyId : String
  epoch : String
  seq : String
  deriving Repr, BEq, Inhabited

def NodeIdent.parse (s : String) : Option NodeIdent :=
  match s.splitOn "," with
  | [pod, uid, boot, mid, copy, ep, seq] => do
    let b ← boot.toNat?
    some { pod, podUid := uid, boot := b, masterId := mid, copyId := copy, epoch := ep, seq }
  | _ => none

/-- One source pod's APPLIED cluster-replication state, read live from its
    stats (not the rendered config). Forward mode acts on the pod a client
    connects to, whatever its role (cluster_replication.cc on_pre_proxy_*),
    so EVERY source pod counts, not only the masters. -/
structure PodRepl where
  pod : String
  replicating : Bool
  /-- `cluster_replication_mode` ("duplicate" / "forward"; "" if absent) -/
  mode : String
  /-- every asynchronous (duplicate-mode) forward this process enqueued has
      a terminal outcome: forward_enqueued ≤ applied + noop + missing +
      failed + dropped (abandoned / down / unknown op) -/
  settled : Bool
  deriving Repr, BEq

/-- The pure part of `sourcePodsRepl`: one pod's stats reply → its applied
    replication state. `none` when the reply is incomplete (no END). -/
def podReplOf (pod : String) (out : String) : Option PodRepl :=
  let lines := (out.splitOn "\n").map (fun l => l.trim.replace "\r" "")
  if !lines.contains "END" then none
  else
    let stat := fun (name : String) => lines.findSome? fun t =>
      if t.startsWith s!"STAT {name} " then some (t.drop s!"STAT {name} ".length).trim else none
    let counter := fun (pred : String → Bool) => lines.foldl (fun acc t =>
      if t.startsWith "STAT cluster_replication[" then
        let inner := ((t.drop "STAT cluster_replication[".length).splitOn "]").headD ""
        let v := ((t.splitOn " ").getLast?.bind (·.toNat?)).getD 0
        if pred inner then acc + v else acc
      else acc) 0
    let enqueued := counter (· == "forward_enqueued")
    let settled := counter fun i =>
      i == "forward_applied" || i.startsWith "forward_noop_" || i.startsWith "forward_missing_"
        || i.startsWith "forward_failed_" || i == "forward_dropped_abandoned"
        || i == "forward_dropped_down" || i == "forward_dropped_unknown_op"
    some { pod, replicating := stat "cluster_replication" == some "on"
           mode := (stat "cluster_replication_mode").getD "", settled := enqueued ≤ settled }

/-- Why the source pods do not all apply `want` with nothing in flight
    (`none` = they do). Unreadable or empty = held (fail closed). -/
def podsHold (want : String) : Option (List PodRepl) → Option String
  | none => some "a source pod's live replication state is unreadable (fail closed)"
  | some [] => some "no source pod listed"
  | some ps =>
    match ps.find? (fun p => !p.replicating || p.mode != want) with
    | some p => some s!"source pod {p.pod} applies {if p.replicating then (if p.mode.isEmpty then "an unreported mode" else p.mode) else "no replication"}; every source pod must apply {want}"
    | none =>
      match ps.find? (fun p => !p.settled) with
      | some p => some s!"source pod {p.pod} still has asynchronous forwards in flight (forward_enqueued above its settled outcomes)"
      | none => none

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
  /-- Every source partition master completed a seed during this attempt
      (`cluster_replication_seed` completed_* AND its seed_completed counter
      above the attempt baseline, same process). -/
  seedCompleted : Bool := false
  /-- Loss counters since the attempt began, over the whole attempt. -/
  loss : LossVerdict := .unknown "not observed"
  /-- status.attemptId: minted when duplication is enabled (CR uid + the
      attempt baseline); empty before. -/
  attemptId : String := ""
  /-- Live identity/position of every source / target partition master,
      read this tick (`none` = some master unreadable or none). -/
  srcIdent : Option (List NodeIdent) := none
  dstIdent : Option (List NodeIdent) := none
  /-- The source masters' own clock this tick (largest `time` stat). -/
  now : Option Nat := none
  /-- status.forwardApprovalConsumed: the approval line a forward switch was
      already issued with (recorded in the same status patch as the
      switch). Empty = none used. -/
  consumedApproval : String := ""
  /-- Every source pod's APPLIED replication state, read live this tick
      (`none` = a pod unreadable or the list failed). -/
  sourcePods : Option (List PodRepl) := none
  deriving Repr, BEq

/-- Convergence dwell: how many consecutive converged ticks are required
    before Duplicating advances. At the 5s reconcile interval this is ~30s
    of stable convergence. -/
def convergenceDwellTicks : Nat := 6

/-- `attempt=<id>|src=<node>;..|dst=<node>;..` (scripts/flare_verify_copy.py
    binding_line). `none` when malformed. -/
def parseBinding (s : String) : Option (String × List NodeIdent × List NodeIdent) :=
  match s.splitOn "|" with
  | [a, sr, ds] =>
    if !(a.startsWith "attempt=" && sr.startsWith "src=" && ds.startsWith "dst=") then none
    else do
      let nodes := fun (x : String) => ((x.drop 4).splitOn ";").filter (· != "") |>.mapM NodeIdent.parse
      some ((a.drop 8), ← nodes sr, ← nodes ds)
  | _ => none

private def identHold (side : String) (bound now : List NodeIdent) : Option String :=
  let pods := bound.map (·.pod)
  if bound.isEmpty then some s!"{side}: the verification binds no node"
  else if pods.eraseDups.length != pods.length then
    some s!"{side}: the verification names a master twice"
  else if bound.length != now.length then
    some s!"{side}: {bound.length} masters verified, {now.length} now"
  else bound.findSome? fun b =>
    match now.find? (·.pod == b.pod) with
    | none => some s!"{side} {b.pod}: not a master now"
    | some n =>
      if n.podUid != b.podUid || !(b.boot + 2 ≥ n.boot && n.boot + 2 ≥ b.boot) then
        some s!"{side} {b.pod}: restarted or replaced since the verification"
      else if n.masterId != b.masterId || n.epoch != b.epoch then
        some s!"{side} {b.pod}: history changed since the verification"
      else if n.copyId != b.copyId then
        some s!"{side} {b.pod}: copy changed since the verification"
      else if n.seq != b.seq then
        some s!"{side} {b.pod}: position moved since the verification (a write, a reap, a re-seed)"
      else none

/-- The binding alone: the live masters must be exactly what V verified, in
    this attempt. -/
def forwardBindingHold (binding attemptNow : String) (srcNow dstNow : List NodeIdent) : Option String :=
  match parseBinding binding with
  | none => some "verification binding unreadable"
  | some (att, src, dst) =>
    if attemptNow.isEmpty then some "this attempt has no id yet (duplication not enabled by this migration)"
    else if att != attemptNow then some "the verification belongs to another attempt (stale or reused)"
    else (identHold "source" src srcNow).orElse fun _ => identHold "target" dst dstNow

/-- How long a MATCH may be used, on the source masters' clock. Every
    position must ALSO be unchanged; the age bounds what no position shows
    (an unobserved counter, a client that kept a connection open). -/
def approvalMaxAgeSeconds : Nat := 3600

/-- `v=1|verdict=MATCH|verified_at=<unix>|<binding>` → (verified_at, binding).
    Only a MATCH line parses; DIFFERENT / UNKNOWN never print one. -/
def parseApproval (s : String) : Option (Nat × String) :=
  match s.trim.splitOn "|" with
  | v :: verdict :: at_ :: rest =>
    if v != "v=1" || verdict != "verdict=MATCH" || !at_.startsWith "verified_at=" then none
    else ((at_.drop "verified_at=".length).toNat?).map fun t => (t, "|".intercalate rest)
  | _ => none

/-- Why a V approval cannot be used against this tick's live masters, or
    `none`. Fail-closed: unreadable masters or clock = held. -/
def approvalHold (approval : String) (obs : MigObs) : Option String :=
  match parseApproval approval with
  | none => some "forwardApproval is not a V MATCH approval line (v=1|verdict=MATCH|verified_at=..|attempt=..|src=..|dst=..)"
  | some (at_, binding) =>
    match obs.srcIdent, obs.dstIdent, obs.now with
    | some src, some dst, some now =>
      if now + 5 < at_ then some s!"verified_at {at_} is in the future of the source clock ({now})"
      else if at_ + approvalMaxAgeSeconds < now then
        some s!"the verification is older than {approvalMaxAgeSeconds} s (verified_at {at_}, now {now}): re-run V"
      else forwardBindingHold binding obs.attemptId src dst
    | _, _, _ => some "live master identities or clock unreadable this tick: the approval cannot be checked (held)"

/-- Why the forward switch is held, or `none` when every condition holds. -/
def forwardHold (spec : MigSpec) (obs : MigObs) : Option String :=
  if obs.convergedTicks < convergenceDwellTicks then
    some s!"key counts not converged ({obs.targetKeys}/{obs.sourceKeys}, {obs.convergedTicks}/{convergenceDwellTicks} ticks)"
  else if !obs.seedCompleted then
    some "seed not completed on every source master during this attempt"
  else match obs.loss with
    | .lost n => some s!"{n} writes lost since the attempt began (counted on the source): verification V must list them; cutover path refused"
    | .unknown why => some s!"loss since the attempt began is UNKNOWN ({why}): held"
    | .clean =>
      if spec.forwardApproval.isEmpty then
        some ((if spec.approveForward then "approveForward is a boolean and is NOT accepted as a verification; " else "")
          ++ s!"counts, seed and loss counters satisfied — NOT a verification: stop writes, run V for attempt {obs.attemptId} and set spec.forwardApproval to the approval line it prints for a MATCH")
      else if !obs.consumedApproval.isEmpty && spec.forwardApproval.trim == obs.consumedApproval.trim then
        some "forwardApproval refused: this approval was already used for a forward switch (one use)"
      else match approvalHold spec.forwardApproval obs with
        | some w => some ("forwardApproval refused: " ++ w)
        | none => (podsHold "duplicate" obs.sourcePods).map
            ("switch precondition (every source pod in duplicate mode, nothing in flight): " ++ ·)

/-- Why Forwarding may not advance to AwaitingCutover: forward mode not yet
    applied, or the approval no longer matches the live masters after the
    apply (a write in the switch window). -/
def forwardAppliedHold (spec : MigSpec) (obs : MigObs) : Option String :=
  if !obs.sourceForwardApplied then some "the source has not applied forward mode yet"
  else match podsHold "forward" obs.sourcePods with
    | some w => some ("forward mode is rendered but not yet applied by every source pod (mixed modes: keep writes stopped): " ++ w)
    | none => (approvalHold spec.forwardApproval obs).map
        ("after the forward apply the approval no longer matches (keep writes stopped; re-run V and set a new forwardApproval): " ++ ·)

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
  else if spec.abort && !phase.abortRefused && !phase.terminal then
    -- keep issuing the (idempotent) rollback; land on Aborted the tick after
    ((if phase == .Aborting then .Aborted else .Aborting), .doAbort)
  else
    match phase with
    | .Pending => (.Provisioning, .provisionTarget)
    | .Provisioning =>
      if obs.targetReady then (.Duplicating, .startDuplicate)
      else (.Provisioning, .none)
    | .Duplicating =>
      if (forwardHold spec obs).isNone then (.Forwarding, .switchForward)
      else (.Duplicating, .none)
    | .Forwarding =>
      if (forwardAppliedHold spec obs).isNone then (.AwaitingCutover, .none)
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
  · by_cases ha : spec.abort && !phase.abortRefused && !phase.terminal
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
  · by_cases ha : spec.abort && !phase.abortRefused && !phase.terminal
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
  · cases phase <;> simp_all [migStep, MigPhase.pastPointOfNoReturn, MigPhase.abortRefused] <;>
      split <;> simp_all

/-- Abort is never acted on once the forward switch was issued. -/
theorem migStep_no_abort_after_forward (spec : MigSpec) (phase : MigPhase) (obs : MigObs)
    (h : phase.abortRefused = true) :
    (migStep spec phase obs).2 ≠ .doAbort := by
  by_cases hp : spec.paused
  · simp [migStep, hp]
  · cases phase <;> simp_all [migStep, MigPhase.abortRefused] <;>
      split <;> simp_all

theorem forwardHold_none (spec : MigSpec) (obs : MigObs) (h : forwardHold spec obs = none) :
    approvalHold spec.forwardApproval obs = none ∧ obs.seedCompleted = true ∧ obs.loss = .clean ∧
      convergenceDwellTicks ≤ obs.convergedTicks ∧
      ¬ (obs.consumedApproval.isEmpty = false ∧ spec.forwardApproval.trim = obs.consumedApproval.trim) ∧
      podsHold "duplicate" obs.sourcePods = none := by
  unfold forwardHold at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i hc hs
      split at h
      · simp at h
      · simp at h
      · rename_i hl
        split at h
        · simp at h
        · split at h
          · simp at h
          · rename_i hcons
            split at h
            · simp at h
            · rename_i ha
              refine ⟨ha, by simpa using hs, hl, by omega, by simpa using hcons, ?_⟩
              cases hp : podsHold "duplicate" obs.sourcePods <;> simp_all

/-- The approval check passes only for a parsed MATCH line whose binding
    names this tick's attempt and equals the live masters. -/
theorem approvalHold_none (approval : String) (obs : MigObs)
    (h : approvalHold approval obs = none) :
    ∃ at_ binding src dst now, parseApproval approval = some (at_, binding) ∧
      obs.srcIdent = some src ∧ obs.dstIdent = some dst ∧ obs.now = some now ∧
      at_ ≤ now + 5 ∧ now ≤ at_ + approvalMaxAgeSeconds ∧
      forwardBindingHold binding obs.attemptId src dst = none := by
  unfold approvalHold at h
  split at h
  · simp at h
  · rename_i at_ binding hp
    split at h
    · rename_i src dst now hs hd hn
      split at h
      · simp at h
      · split at h
        · simp at h
        · exact ⟨at_, binding, src, dst, now, hp, hs, hd, hn, by omega, by omega, h⟩
    · simp at h

/-- The forward switch — the first client-visible step — is issued only with
    a V approval that holds against this tick's live masters in this attempt
    AND this attempt's evidence: seed completed, loss counters clean over the
    whole attempt, counts converged. Equal counts alone, or a boolean, never
    issue it. -/
theorem migStep_forward_requires_approval_and_evidence (spec : MigSpec) (phase : MigPhase)
    (obs : MigObs) (h : (migStep spec phase obs).2 = .switchForward) :
    approvalHold spec.forwardApproval obs = none ∧ obs.seedCompleted = true ∧ obs.loss = .clean ∧
      convergenceDwellTicks ≤ obs.convergedTicks ∧
      ¬ (obs.consumedApproval.isEmpty = false ∧ spec.forwardApproval.trim = obs.consumedApproval.trim) ∧
      podsHold "duplicate" obs.sourcePods = none := by
  apply forwardHold_none
  by_cases hp : spec.paused
  · simp [migStep, hp] at h
  · by_cases ha : spec.abort && !phase.abortRefused && !phase.terminal
    · cases phase <;> simp_all [migStep]
    · cases phase <;> simp_all [migStep] <;> split at h <;> simp_all

/-- Forwarding reaches AwaitingCutover only when the source applied forward
    mode AND the same approval still holds against the live masters (no
    write, restart or re-seed in the switch window). -/
theorem migStep_awaitingCutover_rechecks_approval (spec : MigSpec) (obs : MigObs)
    (h : (migStep spec .Forwarding obs).1 = .AwaitingCutover) :
    spec.paused = false ∧ obs.sourceForwardApplied = true ∧ podsHold "forward" obs.sourcePods = none ∧
      approvalHold spec.forwardApproval obs = none := by
  by_cases hp : spec.paused
  · simp [migStep, hp] at h
  · simp [migStep, hp, MigPhase.abortRefused] at h
    split at h
    · rename_i hf
      unfold forwardAppliedHold at hf
      split at hf
      · simp at hf
      · rename_i hs
        split at hf
        · simp at hf
        · rename_i hpods
          refine ⟨by simpa using hp, by simpa using hs, hpods, ?_⟩
          cases hh : approvalHold spec.forwardApproval obs <;> simp_all
    · simp at h

end FlareOperator.Migration
