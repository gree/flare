/-
  Planned eviction (docs/design-node-operations-2026-10-19.md §2,
  docs/review-safe-eviction-2026-10-14.md §4). Pure decisions only: the
  admission webhook (`admit`) and the operator's asynchronous prepare
  (`step`). The IO shell reads fresh observations, applies the actions, and
  persists `State` in the FlareCluster status (never in memory only).

  * The FIRST eviction of a flared pod is refused; refusing it records a
    request, which starts the prepare. Only a later request, once the prepare
    is GRANTED and the grant still matches the pod NOW, is allowed.
  * Nothing that needs time happens in admission: `admit` reads the state and
    the pod and decides.
  * Master target: fence (every new mutation refused) -> drain in-flight to 0
    -> fix the barrier (latest sequence) -> the successor on another node has
    applied the barrier with its identity unchanged -> switch roles (successor
    master, target proxy) -> confirm the target refuses / no longer owns
    writes -> grant (bound to the target's pod UID / boot / copy / history /
    partition / attempt, with an expiry).
  * Replica target: the master is healthy and the target is not the only copy
    with data -> grant directly (no fence).
  * Anything unproven holds (the request stays, its reason is reported to the
    requester); a broken precondition aborts (the fence is released if the
    roles have not changed yet). A lost operator lease aborts too; the fence's
    own TTL releases it if the release never lands.
-/

namespace FlareOperator.Disruption

inductive Phase where
  | requested
  | fencing
  | draining
  | applying
  | switching
  | granted
  | aborted
  deriving Repr, BEq, DecidableEq

def Phase.label : Phase → String
  | .requested => "requested"
  | .fencing => "fencing"
  | .draining => "draining"
  | .applying => "applying"
  | .switching => "switching"
  | .granted => "granted"
  | .aborted => "aborted"

inductive Target where
  | master
  | replica
  deriving Repr, BEq, DecidableEq

/-- The identity a prepare and its grant are bound to. -/
structure Binding where
  podUid : String
  bootId : String
  copyId : String
  historyEpoch : String
  partition : Nat
  deriving Repr, BEq, DecidableEq

/-- The persisted disruption (at most one per cluster). -/
structure State where
  id : String
  pod : String
  target : Target
  binding : Binding
  attempt : Nat
  phase : Phase
  requestedAt : Nat
  /-- the prepare must reach `granted` by then, else it aborts -/
  deadline : Nat
  leaseEpoch : Nat
  successor : Option String := none
  successorBinding : Option Binding := none
  fenceToken : Option String := none
  barrier : Option Nat := none
  grantExpiresAt : Option Nat := none
  /-- why it is held / why it aborted (reported to the requester) -/
  reason : String := ""
  deriving Repr, BEq

/-- A disruption that no longer blocks another one. -/
def State.finished (s : State) (now : Nat) : Bool :=
  s.phase == .aborted
    || (s.phase == .granted && (s.grantExpiresAt.map (fun e => decide (now ≥ e))).getD true)
    || (s.phase != .granted && decide (now ≥ s.deadline))

/-- What admission reads of the pod NOW. `none` fields = not readable. -/
structure PodNow where
  name : String
  uid : String
  /-- a flared pod of a managed FlareCluster (resolved from the pod, not from
      the Eviction object, which carries no labels) -/
  flared : Bool
  binding : Option Binding
  /-- holds no partition in the committed map (master target after switch) -/
  isProxy : Bool
  /-- master of its partition / a replica in the committed map -/
  target : Option Target
  deriving Repr

structure EvictionReq where
  podName : String
  preconditionUid : Option String := none
  dryRun : Bool := false
  deriving Repr

inductive Decision where
  | allow (why : String)
  | deny (why : String)
  /-- deny and persist this new request (never on dryRun) -/
  | denyRecord (why : String) (s : State)
  deriving Repr

def Decision.allowed : Decision → Bool
  | .allow _ => true
  | _ => false

def Decision.message : Decision → String
  | .allow w => w
  | .deny w => w
  | .denyRecord w _ => w

/-- Is the grant of `s` valid for `pod` now? `successorHealthy` = the
    successor (master target) or the master (replica target) is master and
    healthy now. `none` = valid, `some why` = not. -/
def grantInvalid (s : State) (pod : PodNow) (now : Nat) (successorHealthy : Bool) : Option String :=
  if s.phase != .granted then some s!"prepare not complete ({s.phase.label}{if s.reason.isEmpty then "" else s!": {s.reason}"})"
  else if (s.grantExpiresAt.map (fun e => decide (now ≥ e))).getD true then some "the grant expired"
  else if pod.uid != s.binding.podUid then some "the pod was replaced (UID changed) since the grant"
  else match pod.binding with
    | none => some "the pod's identity cannot be read now"
    | some b =>
      if b.bootId != s.binding.bootId then some "the flared process restarted since the grant"
      else if b.copyId != s.binding.copyId then some "the copy changed since the grant"
      else if b.partition != s.binding.partition then some "the partition changed since the grant"
      else if s.target == .master && !pod.isProxy then some "the pod still owns its partition (not demoted)"
      else if !successorHealthy then some "the successor is not a healthy master now"
      else none

/-- The admission decision (`pods/eviction` CREATE). -/
def admit (cur : Option State) (pod : Option PodNow) (req : EvictionReq) (now leaseEpoch : Nat)
    (successorHealthy : Bool) (newId : String) (prepareSec : Nat) : Decision :=
  match pod with
  | none => .deny "flare: UNKNOWN — the pod cannot be read; eviction refused (fail closed)"
  | some p =>
    if (req.preconditionUid.map (· != p.uid)).getD false then
      .deny "flare: the eviction's UID precondition does not match the pod"
    else if !p.flared then .allow "not a flared pod"
    else
      let fresh := fun (attempt : Nat) =>
        match p.binding, p.target with
        | some b, some t =>
          let s : State := { id := newId, pod := p.name, target := t, binding := b, attempt,
                             phase := .requested, requestedAt := now, deadline := now + prepareSec,
                             leaseEpoch, reason := "prepare requested" }
          if req.dryRun then Decision.deny "flare: not prepared (dry run: nothing recorded)"
          else Decision.denyRecord s!"flare: eviction of {p.name} needs a prepare first (request {newId} recorded; retry later)" s
        | _, _ => Decision.deny "flare: the pod's identity or role cannot be read; eviction refused"
      match cur with
      | none => fresh 1
      | some s =>
        if s.finished now then
          fresh (if s.pod == p.name then s.attempt + 1 else 1)
        else if s.pod != p.name then
          .deny s!"flare: another disruption is in progress ({s.pod}, {s.phase.label}); evictions are taken one at a time"
        else
          match grantInvalid s p now successorHealthy with
          | none => .allow s!"flare: prepared (request {s.id}, attempt {s.attempt})"
          | some why => .deny s!"flare: eviction of {p.name} held — {why}"

/-! ## The prepare (operator pass) -/

/-- Fresh observations for one prepare step (the IO shell reads them). -/
structure Obs where
  now : Nat
  leaseEpoch : Nat
  /-- the target pod still exists with this UID and is not deleting -/
  targetPresent : Bool
  /-- target is the master (or replica) of `binding.partition` in the map -/
  targetRole : Option Target
  /-- master target: the successor chosen now — eligible (R3 / history /
      identity), on ANOTHER node, not rebuilding — and its binding -/
  successor : Option (String × Binding)
  /-- successor's applied position (read fresh), `none` = unreadable -/
  successorApplied : Option Nat
  /-- target's fence as the target reports it: (token, in-flight) -/
  fence : Option (String × Nat)
  /-- target's latest sequence number, `none` = unreadable -/
  targetLatestSeq : Option Nat
  /-- the map has the successor as master and the target as proxy, and the
      target itself reports it is not master -/
  switched : Bool
  /-- replica target: the master is healthy and holds data, and the target
      is not the only copy with data -/
  replicaSafe : Bool
  /-- blockers: migration, history hold, a rebuild in progress, another
      partition masterless... (empty = none) -/
  blockers : List String
  deriving Repr

inductive Action where
  | armFence (pod token : String) (ttlSec : Nat)
  | releaseFence (pod token : String)
  | switchRoles (target successor : String)
  | notify (msg : String)
  deriving Repr, BEq

def fenceTtlSec : Nat := 30

def abort (s : State) (why : String) : State × List Action :=
  let release := match s.fenceToken with
    | some t => if s.phase == .switching || s.phase == .granted then [] else [Action.releaseFence s.pod t]
    | none => []
  ({ s with phase := .aborted, reason := why }, release ++ [.notify s!"disruption {s.id} of {s.pod} ABORTED: {why}"])

/-- One prepare step. Pure: the same observations give the same result. -/
def step (s : State) (o : Obs) : State × List Action :=
  if s.phase == .aborted then (s, [])
  else if o.leaseEpoch != s.leaseEpoch then abort s "the operator leadership changed during the prepare"
  else if !o.targetPresent then
    if s.phase == .granted then ({ s with reason := "the pod is gone (evicted)" }, [])
    else abort s "the pod was deleted or replaced during the prepare"
  else if s.phase == .granted then
    if (s.grantExpiresAt.map (fun e => decide (o.now ≥ e))).getD true then
      ({ s with phase := .aborted, reason := "the grant expired without an eviction (cancelled)" },
       [.notify s!"disruption {s.id} of {s.pod}: grant expired unused; the pod stays (as a proxy it rejoins as a follower)"])
    else (s, [])
  else if o.now ≥ s.deadline then abort s s!"the prepare did not complete in time (last: {s.reason})"
  else if !o.blockers.isEmpty then
    if s.phase == .requested then ({ s with reason := s!"held: {String.intercalate "; " o.blockers}" }, [])
    else abort s s!"a blocker appeared: {String.intercalate "; " o.blockers}"
  else match s.target with
  | .replica =>
    if o.targetRole != some .replica then abort s "the target is no longer a replica"
    else if !o.replicaSafe then ({ s with reason := "held: the master is not healthy, or the target is the only copy with data" }, [])
    else ({ s with phase := .granted, grantExpiresAt := some (o.now + 120), reason := "" },
          [.notify s!"disruption {s.id}: replica {s.pod} may be evicted"])
  | .master =>
    match s.phase with
    | .requested =>
      if o.targetRole != some .master then abort s "the target is no longer the master"
      else match o.successor with
      | none => ({ s with reason := "held: no eligible successor on another node" }, [])
      | some (k, b) =>
        let tok := s!"{s.id}-{s.attempt}"
        ({ s with phase := .fencing, successor := some k, successorBinding := some b, fenceToken := some tok, reason := "" },
         [.armFence s.pod tok fenceTtlSec])
    | .fencing | .draining | .applying =>
      let tok := s.fenceToken.getD ""
      let rearm := [Action.armFence s.pod tok fenceTtlSec]
      if o.targetRole != some .master then abort s "the target is no longer the master"
      else match o.successor, s.successor, s.successorBinding with
      | some (k, b), some k0, some b0 =>
        if k != k0 || b != b0 then abort s "the successor changed or lost its eligibility / identity"
        else match o.fence with
        | none => (s, rearm)
        | some (t, inflight) =>
          if t != tok then abort s "the target holds another fence"
          else if s.phase == .fencing then ({ s with phase := .draining }, rearm)
          else if s.phase == .draining then
            if inflight != 0 then ({ s with reason := s!"draining {inflight} in-flight mutation(s)" }, rearm)
            else match o.targetLatestSeq with
              | none => ({ s with reason := "the barrier cannot be read" }, rearm)
              | some seq => ({ s with phase := .applying, barrier := some seq, reason := "" }, rearm)
          else -- applying
            match s.barrier, o.successorApplied with
            | some bar, some ap =>
              if ap ≥ bar then ({ s with phase := .switching, reason := "" }, rearm ++ [.switchRoles s.pod k0])
              else ({ s with reason := s!"successor at {ap}, barrier {bar}" }, rearm)
            | _, _ => ({ s with reason := "the successor's applied position cannot be read" }, rearm)
      | _, _, _ => abort s "no eligible successor any more"
    | .switching =>
      let tok := s.fenceToken.getD ""
      if o.switched then
        ({ s with phase := .granted, grantExpiresAt := some (o.now + 120), reason := "" },
         [.releaseFence s.pod tok, .notify s!"disruption {s.id}: master {s.pod} handed over to {s.successor.getD "?"}; it may be evicted"])
      else ({ s with reason := "waiting for the role switch to be confirmed" }, [.armFence s.pod tok fenceTtlSec])
    | _ => (s, [])

end FlareOperator.Disruption
