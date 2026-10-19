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
    DRAINING to the reconcile pass (`plannedDrainKeys`), so the existing
    drain-with-promotion path — promotion evidence, history intent, commit
    re-reads — performs it.
-/
import FlareOperator.K8s.FlareCluster
import FlareOperator.K8s.Bridge
import FlareOperator.K8s.Admission
import FlareOperator.K8s.DisruptionJson
import FlareOperator.StateMachine.Disruption
import FlareOperator.StateMachine.PromotionEvidence
import FlareOperator.Kubectl
import Lean.Data.Json

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
  /-- node keys the reconcile pass must treat as draining (planned switch) -/
  plannedRef : IO.Ref (List String)
  epochRef : IO.Ref Nat
  /-- the migration phase is not None (a blocker) -/
  migrationBusy : IO Bool

/-- Wall-clock seconds (persisted deadlines must survive a restart). -/
def wallNow : IO Nat := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%s"] }
  return out.stdout.trim.toNat?.getD 0

def statOf (out key : String) : Option String :=
  ((out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)).findSome? fun l =>
    if l.startsWith s!"STAT {key} " then some (l.drop (s!"STAT {key} ").length) else none

def load (crName ns : String) : IO (Except String (Option Disruption.State)) := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o", "jsonpath={.status.disruption}"] with
  | .error e => return .error e
  | .ok s => return DisruptionJson.parse s

def persist (crName ns : String) (s : Option Disruption.State) : IO Bool := do
  let patch := (Lean.Json.mkObj [("status", Lean.Json.mkObj [("disruption", Lean.Json.str (DisruptionJson.render s))])]).compress
  match ← kubectl ["patch", "flarecluster", crName, "-n", ns, "--subresource=status", "--type=merge", "-p", patch] with
  | .ok _ => return true
  | .error e =>
    IO.eprintln s!"[flare-operator] CRITICAL: the planned-eviction state could not be persisted: {e}"
    return false

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

/-- The successor (master target) or the master (replica target) is a
    healthy master now. -/
def successorHealthy (env : Env) (pods : List PodInfo) (cur : Option Disruption.State) : IO Bool := do
  let st ← env.stateRef.get
  let ready := fun (key : String) => pods.any fun p => p.toNodeKey == key && p.ready && !p.terminating
  match cur with
  | none => return false
  | some s =>
    match s.target, s.successor with
    | .master, some k =>
      return (st.lookupNode k).any (fun n => n.role == FlareRole.Master && n.state == FlareState.Active) && ready k
    | .replica, _ =>
      return st.nodeMap.any fun (k, n) => n.role == FlareRole.Master && n.state == FlareState.Active
        && n.partition == Int.ofNat s.binding.partition && ready k
    | _, none => return false

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
          let cur ← env.disruptionRef.get
          let pn ← podNow env p cur
          let now ← wallNow
          let healthy ← successorHealthy env pods cur
          let req : EvictionReq := { podName := r.podName, preconditionUid := r.preconditionUid, dryRun := r.dryRun }
          let d := admit cur (some pn) req now (← env.epochRef.get) healthy s!"ev{now}-{p.name}" 600
          match d with
          | .denyRecord msg s =>
            -- persisted BEFORE answering: the prepare starts from the record
            if ← persist env.crName env.ns (some s) then
              env.disruptionRef.set (some s)
              reply false msg
            else reply false "flare: the eviction request could not be recorded; refused"
          | .allow msg => reply true msg
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
  -- target's own stats: fence, latest sequence
  let tStats ← match tp with
    | some p => do pure (match ← queryPodStats p.name env.ns "stats" with | .ok o => some o | .error _ => none)
    | none => pure none
  let fence := tStats.bind fun o =>
    if statOf o "fence_active" == some "1" then
      match statOf o "fence_token", (statOf o "fence_in_flight").bind (·.toNat?) with
      | some t, some n => some (t, n)
      | _, _ => none
    else none
  let seq := tStats.bind fun o => (statOf o "rocksdb_latest_sequence_number").bind (·.toNat?)
  -- the successor: an Active, Ready slave of the partition on ANOTHER node,
  -- R3-eligible and following, with a readable identity
  let mut succ : Option (String × Binding) := none
  let mut succApplied : Option Nat := none
  if s.target == .master then
    let cands := st.nodeMap.filter fun (_, n) => n.role == FlareRole.Slave && n.state == FlareState.Active && n.partition == part
    for (k, _) in cands do
      if succ.isNone then
        match pods.find? (fun p => p.toNodeKey == k) with
        | some sp =>
          if sp.ready && !sp.terminating && (tp.map (·.nodeName != sp.nodeName)).getD false then
            match ← bindingNow sp env.ns s.binding.partition with
            | some (b, out) =>
              if statOf out "repl_read_source_state" == some "eligible" && statOf out "repl_follow_state" == some "following" then
                succ := some (k, b)
                succApplied := (statOf out "repl_applied_lsn").bind (·.toNat?)
            | none => pure ()
        | none => pure ()
  let switched := match s.successor with
    | some k => (st.lookupNode k).any (fun n => n.role == FlareRole.Master && n.partition == part)
        && (tnode.map (·.role == FlareRole.Proxy)).getD false
    | none => false
  -- replica target: the master is healthy and holds data, the target is not
  -- the only copy with data
  let mut replicaSafe := false
  if s.target == .replica then
    match st.nodeMap.find? (fun (_, n) => n.role == FlareRole.Master && n.state == FlareState.Active && n.partition == part) with
    | some (mk, _) =>
      match pods.find? (fun p => p.toNodeKey == mk) with
      | some mp =>
        if mp.ready && !mp.terminating then
          -- the master is read and holds data, or the target holds none:
          -- either way the target is not the only copy with data
          let mItems := match ← queryPodStats mp.name env.ns "stats" with
            | .ok o => (statOf o "curr_items").bind (·.toNat?)
            | .error _ => none
          let tItems := tStats.bind fun o => (statOf o "curr_items").bind (·.toNat?)
          replicaSafe := match mItems, tItems with
            | some m, _ => m > 0 || tItems == some 0
            | none, _ => false
      | none => pure ()
    | none => pure ()
  let mut blockers : List String := []
  if ← env.migrationBusy then blockers := blockers ++ ["a cluster migration is in progress"]
  if st.nodeMap.any (fun (_, n) => n.role == FlareRole.Slave && n.state == FlareState.Prepare) then
    blockers := blockers ++ ["a copy is being rebuilt (redundancy not restored yet)"]
  return { now, leaseEpoch := ← env.epochRef.get, targetPresent := present, targetRole := role,
           successor := match s.successor, succ with
             | some k0, some (k, b) => if k == k0 then some (k, b) else some (k, b)
             | _, x => x,
           successorApplied := succApplied, fence, targetLatestSeq := seq, switched, replicaSafe, blockers }

/-- One prepare step on the leader (each reconcile pass). -/
def prepareStep (env : Env) : IO Unit := do
  let some s ← env.disruptionRef.get | env.plannedRef.set []; return
  if s.phase == .aborted then env.plannedRef.set []; return
  let pods ← match ← listFlaredPodsE env.crName env.ns with
    | .ok ps => pure ps
    | .error _ => return
  let o ← observe env s pods
  let (s', acts) := step s o
  -- the target is gone after its grant: the disruption is complete
  if s'.phase == .granted && !o.targetPresent then
    if ← persist env.crName env.ns none then
      IO.eprintln s!"[flare-operator] EVICTION complete: {s.pod} was evicted after its grant ({s.id})"
      env.disruptionRef.set none
      env.plannedRef.set []
    return
  if s' != s then
    if !(← persist env.crName env.ns (some s')) then return
    env.disruptionRef.set (some s')
    IO.eprintln s!"[flare-operator] EVICTION {s'.id} {s'.pod}: {s.phase.label} -> {s'.phase.label}{if s'.reason.isEmpty then "" else s!" ({s'.reason})"}"
  for a in acts do
    match a with
    | .armFence pod tok ttl =>
      match ← queryPodStats pod env.ns s!"fence arm {tok} {ttl}" with
      | .ok out => if !(containsStat out "fence_active 1") then IO.eprintln s!"[flare-operator] EVICTION {s'.id}: fence arm on {pod} not confirmed: {out.trim.take 200}"
      | .error e => IO.eprintln s!"[flare-operator] EVICTION {s'.id}: fence arm on {pod} failed: {e}"
    | .releaseFence pod tok =>
      discard <| queryPodStats pod env.ns s!"fence release {tok}"
    | .switchRoles target _ =>
      match pods.find? (·.name == target) with
      | some p => env.plannedRef.set [p.toNodeKey]
      | none => pure ()
    | .notify msg => IO.eprintln s!"[flare-operator] EVICTION {msg}"
  if s'.phase == .aborted then env.plannedRef.set []
where
  containsStat (out needle : String) : Bool := (out.splitOn needle).length > 1

end FlareOperator.EvictionGuard
