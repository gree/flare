/-
  EvictionGuard.lean — the IO side of the planned eviction
  (docs/design-node-operations-2026-10-19.md §2, StateMachine/Disruption).

  * `handleReview`: the admission webhook for `pods/eviction` in this
    namespace. Reads the pod (UID, its copy's identity, its role in the
    committed map) and the persisted disruption, decides with
    `Disruption.admit`, persists a new request BEFORE answering, and never
    waits for the prepare.
  * `prepareStep`: once per reconcile pass on the leader. Reads fresh
    observations, advances the prepare with `Disruption.step`, persists the
    new state BEFORE acting (fence arm/release, the planned role switch).
  * The role switch is not a direct map edit: the target is reported as
    DRAINING to the reconcile pass (`plannedRef`), with the PINNED successor
    as the only promotable copy of its partition, so the existing
    drain-with-promotion path — promotion evidence, history intent, commit
    re-reads — performs it, and only to that successor.

  Concurrency (review 2026-10-19 #3): admission requests run in parallel
  tasks and the prepare runs in the reconcile loop. Every change of the
  disruption is ONE commit (`commit`): under `lock`, the in-memory state must
  still be the one the decision was made from, this pod must hold the lease
  at the generation it started with, and the status write is a server-side
  compare-and-swap (a JSON-patch `test` of the exact value read, or the
  resourceVersion when the field does not exist yet). Any mismatch discards
  the decision (admission refuses "retry"; the prepare decides again on the
  next pass from the reloaded state). The slow reads happen outside the lock.
-/
import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Bridge
import FlareOperator.K8s.Admission
import FlareOperator.K8s.DisruptionJson
import FlareOperator.StateMachine.Disruption
import FlareOperator.StateMachine.PromotionEvidence
import FlareOperator.Kubectl
import Lean.Data.Json
import Std.Sync.Mutex

namespace FlareOperator.EvictionGuard

open FlareOperator.K8s
open FlareOperator.K8s.Bridge
open FlareOperator.Kubectl
open FlareOperator.Disruption

structure Env where
  crName : String
  ns : String
  stateRef : IO.Ref FlareClusterState
  disruptionRef : IO.Ref (Option Disruption.State)
  /-- false = status.disruption could not be read / parsed: fail closed -/
  loadOkRef : IO.Ref Bool
  /-- (target key, pinned successor key): the reconcile pass treats the
      target as draining and promotes ONLY the successor in its partition -/
  plannedRef : IO.Ref (List (String × String))
  epochRef : IO.Ref Nat
  /-- the migration phase is not None (a blocker) -/
  migrationBusy : IO Bool
  /-- this pod holds the operator lease now, at the generation `epochRef` -/
  leaderOk : IO Bool
  /-- serializes every commit of the disruption (admission tasks + prepare) -/
  lock : Std.BaseMutex

/-- Wall-clock seconds (persisted deadlines must survive a restart). -/
def wallNow : IO Nat := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%s"] }
  return out.stdout.trim.toNat?.getD 0

def statOf (out key : String) : Option String :=
  ((out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)).findSome? fun l =>
    if l.startsWith s!"STAT {key} " then some (l.drop (s!"STAT {key} ").length) else none

/-- The node's own view (its accepted map) from its stats. -/
def ownOf (out : String) : Option OwnView :=
  match statOf out "own_role", (statOf out "own_partition").bind String.toInt?, (statOf out "node_map_version").bind (·.toNat?) with
  | some r, some p, some v => if r == "unknown" then none else some { role := r, partition := p, mapVersion := v }
  | _, _, _ => none

/-- The fence from one stats / fence reply (`none` = not armed or not
    reported completely, e.g. a flared without generations). -/
def fenceOf (out : String) : Option FenceObs :=
  if statOf out "fence_active" == some "1" then
    match statOf out "fence_token", (statOf out "fence_in_flight").bind (·.toNat?), (statOf out "fence_generation").bind (·.toNat?) with
    | some t, some n, some g => some { token := t, inFlight := n, generation := g }
    | _, _, _ => none
  else none

/-- The raw field and the resourceVersion, in one read. `none` field = the
    status has no `disruption` key at all. -/
def readRaw (crName ns : String) : IO (Except String (String × Option String)) := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o", "json"] with
  | .error e => return .error e
  | .ok out =>
    match Lean.Json.parse out with
    | .error e => return .error e
    | .ok j =>
      let rv := ((j.getObjValD "metadata").getObjValAs? String "resourceVersion").toOption.getD ""
      let field := ((j.getObjValD "status").getObjValAs? String "disruption").toOption
      return .ok (rv, field)

def load (crName ns : String) : IO (Except String (Option Disruption.State)) := do
  match ← readRaw crName ns with
  | .error e => return .error e
  | .ok (_, f) => return DisruptionJson.parse (f.getD "")

/-- The compare-and-swap patch (pure, unit-tested): `test` the exact value
    read, then replace; when the key does not exist yet, a merge patch
    conditioned on the resourceVersion of the same read. -/
def casPatch (raw : Option String) (rv : String) (next : Option Disruption.State) : String × String :=
  let v := Lean.Json.str (DisruptionJson.render next)
  match raw with
  | some cur =>
    ("json", (Lean.Json.arr #[
      Lean.Json.mkObj [("op", "test"), ("path", "/status/disruption"), ("value", Lean.Json.str cur)],
      Lean.Json.mkObj [("op", "replace"), ("path", "/status/disruption"), ("value", v)]]).compress)
  | none =>
    ("merge", (Lean.Json.mkObj [("metadata", Lean.Json.mkObj [("resourceVersion", Lean.Json.str rv)]),
                                 ("status", Lean.Json.mkObj [("disruption", v)])]).compress)

inductive Commit where
  | ok
  /-- the decision was made from a state that is not current any more -/
  | stale (why : String)
  | failed (why : String)
  deriving Repr, BEq

/-- Is a decision made from `base` still applicable? `none` = yes (pure,
    unit-tested). -/
def commitGate (leader : Bool) (epochNow epochAtStart : Nat) (mem base : Option Disruption.State)
    (server : Except String (Option Disruption.State)) : Option Commit :=
  if !leader then some (.failed "this pod does not hold the operator lease")
  else if epochNow != epochAtStart then some (.stale "the leadership generation changed")
  else if mem != base then some (.stale "the disruption changed concurrently (in this operator)")
  else match server with
    | .error e => some (.failed s!"status.disruption cannot be read ({e})")
    | .ok cur => if cur != base then some (.stale "the disruption changed concurrently (in the cluster)") else none

/-- Commit `next` over `base` (see the header). On `.stale` the in-memory
    state is reloaded from the cluster. -/
def commit (env : Env) (epochAtStart : Nat) (base next : Option Disruption.State) : IO Commit := do
  env.lock.lock
  try
    let leader ← env.leaderOk
    let raw ← readRaw env.crName env.ns
    let server := raw.bind fun (_, f) => DisruptionJson.parse (f.getD "")
    match commitGate leader (← env.epochRef.get) epochAtStart (← env.disruptionRef.get) base server with
    | some c =>
      if let .ok cur := server then env.disruptionRef.set cur
      IO.eprintln s!"[flare-operator] EVICTION state not committed: {repr c}"
      return c
    | none =>
      match raw with
      | .error e => return .failed e
      | .ok (rv, field) =>
        let (ty, patch) := casPatch field rv next
        match ← kubectl ["patch", "flarecluster", env.crName, "-n", env.ns, "--subresource=status", s!"--type={ty}", "-p", patch] with
        | .ok _ =>
          env.disruptionRef.set next
          return .ok
        | .error e =>
          -- a failed test / resourceVersion conflict = someone else wrote
          match ← load env.crName env.ns with
          | .ok cur => env.disruptionRef.set cur
          | .error _ => pure ()
          IO.eprintln s!"[flare-operator] CRITICAL: the planned-eviction state was not written (compare-and-swap refused or failed): {e.take 200}"
          return .stale s!"the compare-and-swap was refused ({e.take 120})"
  finally
    env.lock.unlock

/-- The binding of a pod read NOW from its own stats (`none` = unreadable or
    incomplete: the copy id, boot id or history is not reported). -/
def bindingNow (p : PodInfo) (ns : String) (partition : Nat) : IO (Option (Binding × String)) := do
  match ← queryPodStats p.name ns "stats" with
  | .error _ => return none
  | .ok out =>
    let s := PromotionEvidence.parseStats out
    match s.bootId, s.copyId, s.copyEpoch with
    | some b, some c, some h =>
      if !s.complete || p.uid.isEmpty then return none
      return some ({ podUid := p.uid, bootId := b, copyId := c, historyEpoch := h, partition }, out)
    | _, _, _ => return none

/-- The pod as admission sees it now. -/
def podNow (env : Env) (p : PodInfo) (cur : Option Disruption.State) : IO PodNow := do
  let st ← env.stateRef.get
  let node := st.lookupNode p.toNodeKey
  let target : Option Target := node.bind fun n =>
    if n.role == FlareRole.Master then some .master
    else if n.role == FlareRole.Slave && n.state == FlareState.Active then some .replica
    else none
  let isProxy := (node.map (·.role == FlareRole.Proxy)).getD false
  -- a demoted target owns no partition: bind it to the prepared one
  let partNat : Nat := match node with
    | some n => if n.partition ≥ 0 then n.partition.toNat else ((cur.map (·.binding.partition)).getD 0)
    | none => (cur.map (·.binding.partition)).getD 0
  let b ← bindingNow p env.ns partNat
  return { name := p.name, uid := p.uid, flared := true, binding := b.map (·.1), isProxy, target }

/-- The copy the grant relied on — the successor (master target) or the
    master (replica target) — is, NOW, the same pod / process / copy and the
    Ready master of the partition in the committed map and in its own. -/
def successorHealthy (env : Env) (pods : List PodInfo) (cur : Option Disruption.State) : IO Bool := do
  let st ← env.stateRef.get
  match cur with
  | none => return false
  | some s =>
    match s.successor, s.successorBinding with
    | some k, some b0 =>
      let inMap := (st.lookupNode k).any fun n => n.role == FlareRole.Master && n.state == FlareState.Active
        && n.partition == Int.ofNat s.binding.partition
      match pods.find? (fun p => p.toNodeKey == k && p.ready && !p.terminating) with
      | none => return false
      | some sp =>
        if !inMap || sp.uid != b0.podUid then return false
        match ← bindingNow sp env.ns s.binding.partition with
        | none => return false
        | some (b, out) =>
          return b.bootId == b0.bootId && b.copyId == b0.copyId
            && (ownOf out).any (fun v => v.role == "master" && v.partition == Int.ofNat s.binding.partition)
    | _, _ => return false

/-- The admission webhook (POST body = AdmissionReview). -/
def handleReview (env : Env) (body : String) : IO String := do
  match Admission.parseEvictionReview body with
  | .error e => return Admission.malformedResponse body e
  | .ok r =>
    let reply := fun (allowed : Bool) (msg : String) => do
      IO.eprintln s!"[flare-operator] EVICTION {if allowed then "ALLOWED" else "REFUSED"} pods/{r.podName}{if r.dryRun then " (dry run)" else ""}: {msg}"
      return Admission.reviewResponse r.uid allowed msg
    if r.«namespace» != env.ns then reply true "not managed by this operator"
    else if !(← env.loadOkRef.get) then
      reply false "flare: the planned-eviction state (status.disruption) cannot be read; every flared eviction is refused (fail closed)"
    else
      match ← listFlaredPodsE env.crName env.ns with
      | .error e => reply false s!"flare: UNKNOWN — the cluster's pods cannot be listed ({e}); eviction refused"
      | .ok pods =>
        match pods.find? (·.name == r.podName) with
        | none => reply true "not a flared pod of this cluster"
        | some p =>
          let epoch ← env.epochRef.get
          let cur ← env.disruptionRef.get
          let pn ← podNow env p cur
          let now ← wallNow
          let healthy ← successorHealthy env pods cur
          let req : EvictionReq := { podName := r.podName, preconditionUid := r.preconditionUid, dryRun := r.dryRun }
          let d := admit cur (some pn) req now epoch healthy s!"ev{now}-{p.name}" 600
          match d with
          | .denyRecord msg s =>
            -- persisted BEFORE answering: the prepare starts from the record
            match ← commit env epoch cur (some s) with
            | .ok => reply false msg
            | .stale why => reply false s!"flare: a concurrent update won ({why}); nothing recorded, retry"
            | .failed why => reply false s!"flare: the eviction request could not be recorded ({why}); refused"
          | .allow msg =>
            -- the grant must still be the state this decision read, under
            -- the same leadership
            if (← env.disruptionRef.get) != cur || (← env.epochRef.get) != epoch then
              reply false "flare: the disruption changed while deciding; retry"
            else reply true msg
          | .deny msg => reply false msg

/-- Fresh observations for one prepare step. -/
def observe (env : Env) (s : Disruption.State) (pods : List PodInfo) : IO Obs := do
  let st ← env.stateRef.get
  let now ← wallNow
  let tp := pods.find? (·.name == s.pod)
  let present := (tp.map fun p => p.uid == s.binding.podUid && !p.terminating).getD false
  let tnode := tp.bind fun p => st.lookupNode p.toNodeKey
  let role : Option Target := tnode.bind fun n =>
    if n.role == FlareRole.Master then some .master
    else if n.role == FlareRole.Slave && n.state == FlareState.Active then some .replica else none
  let part := Int.ofNat s.binding.partition
  -- target's own stats: fence (one reading), latest sequence, boot, own map
  let tStats ← match tp with
    | some p => do pure (match ← queryPodStats p.name env.ns "stats" with | .ok o => some o | .error _ => none)
    | none => pure none
  let fence := tStats.bind fenceOf
  let seq := tStats.bind fun o => (statOf o "rocksdb_latest_sequence_number").bind (·.toNat?)
  let targetOwn := tStats.bind ownOf
  let targetBoot := tStats.bind fun o => (PromotionEvidence.parseStats o).bootId
  let active := s.phase != .aborted
  -- successor candidates (before the pin) or the pinned successor only
  let mut cands : List SuccObs := []
  if active && s.target == .master then
    let keys : List String := match s.successor with
      | some k => [k]
      | none => (st.nodeMap.filter fun (_, n) => n.role == FlareRole.Slave && n.state == FlareState.Active && n.partition == part).map (·.1)
    for k in keys do
      match pods.find? (fun p => p.toNodeKey == k) with
      | some sp =>
        if !sp.terminating then
          match ← bindingNow sp env.ns s.binding.partition with
          | some (b, out) =>
            let inMap := (st.lookupNode k).any fun n => n.role == FlareRole.Slave && n.state == FlareState.Active && n.partition == part
            let eligible := inMap && sp.ready && (tp.map (·.nodeName != sp.nodeName)).getD false
              && statOf out "repl_read_source_state" == some "eligible" && statOf out "repl_follow_state" == some "following"
            cands := cands ++ [{ key := k, binding := b, eligible, ready := sp.ready,
                                 applied := (statOf out "repl_applied_lsn").bind (·.toNat?), own := ownOf out }]
          | none => pure ()
      | none => pure ()
  let desiredSwitched := match s.successor with
    | some k => (st.lookupNode k).any (fun n => n.role == FlareRole.Master && n.partition == part)
        && (tnode.map (·.role == FlareRole.Proxy)).getD false
    | none => false
  -- replica target: the lineage facts (review #4; item counts are not evidence)
  let mut rep : ReplicaObs := {}
  if active && s.target == .replica then
    rep := { rep with
      targetSourceState := tStats.bind (statOf · "repl_read_source_state"),
      targetReadSource := tStats.bind (statOf · "repl_read_source"),
      targetReadSourceEpoch := tStats.bind (statOf · "repl_read_source_epoch"),
      targetApplied := tStats.bind fun o => (statOf o "repl_applied_lsn").bind (·.toNat?),
      targetItems := tStats.bind fun o => (statOf o "curr_items").bind (·.toNat?) }
    match st.nodeMap.find? (fun (_, n) => n.role == FlareRole.Master && n.state == FlareState.Active && n.partition == part) with
    | some (mk, _) =>
      match pods.find? (fun p => p.toNodeKey == mk) with
      | some mp =>
        if mp.ready && !mp.terminating then
          match ← bindingNow mp env.ns s.binding.partition with
          | some (mb, out) =>
            let ms := PromotionEvidence.parseStats out
            rep := { rep with
              masterKey := some mk, masterBinding := some mb, masterOwn := ownOf out,
              masterSourceEpoch := ms.sourceEpoch,
              masterSeq := (statOf out "rocksdb_latest_sequence_number").bind (·.toNat?),
              masterSound := ms.identityConsistent == some 1 && ms.quarantined == some 0
                && ms.copyPartial != some 1 && ms.restoredUnverified != some 1 }
          | none => pure ()
      | none => pure ()
    | none => pure ()
  let mut blockers : List String := []
  if ← env.migrationBusy then blockers := blockers ++ ["a cluster migration is in progress"]
  if st.nodeMap.any (fun (_, n) => n.role == FlareRole.Slave && n.state == FlareState.Prepare) then
    blockers := blockers ++ ["a copy is being rebuilt (redundancy not restored yet)"]
  return { now, leaseEpoch := ← env.epochRef.get, targetPresent := present, targetBoot, targetRole := role, targetOwn,
           candidates := cands, fence, targetLatestSeq := seq, desiredSwitched, desiredVersion := st.nodeMapVersion,
           replica := rep, blockers }

/-- One prepare step on the leader (each reconcile pass). -/
def prepareStep (env : Env) : IO Unit := do
  let epoch ← env.epochRef.get
  let some s ← env.disruptionRef.get | env.plannedRef.set []; return
  -- an aborted disruption only holds the old master's fence (if any)
  if s.phase == .aborted then
    env.plannedRef.set []
    if s.fenceToken.isNone then return
  let pods ← match ← listFlaredPodsE env.crName env.ns with
    | .ok ps => pure ps
    | .error _ => return
  let o ← observe env s pods
  let (s', acts) := step s o
  -- the target is gone after its grant: the disruption is complete
  if s'.phase == .granted && !o.targetPresent then
    if (← commit env epoch (some s) none) == .ok then
      IO.eprintln s!"[flare-operator] EVICTION complete: {s.pod} was evicted after its grant ({s.id})"
      env.plannedRef.set []
    return
  if s' != s then
    -- persisted BEFORE acting; a stale decision is dropped (decided again
    -- on the next pass from the reloaded state)
    if (← commit env epoch (some s) (some s')) != .ok then return
    IO.eprintln s!"[flare-operator] EVICTION {s'.id} {s'.pod}: {s.phase.label} -> {s'.phase.label}{if s'.reason.isEmpty then "" else s!" ({s'.reason})"}"
  for a in acts do
    match a with
    | .armFence pod tok ttl =>
      match ← queryPodStats pod env.ns s!"fence arm {tok} {ttl}" with
      | .ok out => if (fenceOf out).isNone then IO.eprintln s!"[flare-operator] EVICTION {s'.id}: fence arm on {pod} not confirmed: {out.trim.take 200}"
      | .error e => IO.eprintln s!"[flare-operator] EVICTION {s'.id}: fence arm on {pod} failed: {e}"
    | .releaseFence pod tok =>
      discard <| queryPodStats pod env.ns s!"fence release {tok}"
    | .switchRoles target succ =>
      -- the target drains, and ONLY the pinned successor may take over
      match pods.find? (·.name == target) with
      | some p => env.plannedRef.set [(p.toNodeKey, succ)]
      | none => pure ()
    | .notify msg => IO.eprintln s!"[flare-operator] EVICTION {msg}"
  if s'.phase == .aborted then env.plannedRef.set []

end FlareOperator.EvictionGuard
