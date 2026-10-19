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

  Review 2026-10-19 (5 points against 6f65ab7) — what each rule below is for:
  * #1 the barrier is valid only while the fence that preceded it is still
    the SAME continuous fence: flared's `fence_generation` (and boot id) is
    recorded when the fence is first seen, and every later step requires it
    unchanged. A lapse (TTL crossed, restart, release) voids the barrier and
    goes back to fencing: re-drain, re-read the barrier, wait for the
    successor again. Once the map has switched, a lapse aborts (no grant).
  * #2 the successor is PINNED at fencing (the highest applied position,
    then the key, among the eligible candidates) and the switch is confirmed
    from the nodes' OWN accepted maps (`own_role` / `own_partition` /
    `node_map_version` in their stats): the target says it is a proxy and the
    pinned successor — the same UID / boot / copy — says it is the master of
    the partition, both at a map version ≥ the operator's committed one, with
    the fence still continuous. The operator's desired map alone is not
    proof. The fence is NOT released at the grant: the old master stays
    fenced until it is gone or the grant lapses unused.
  * #4 a replica is granted only on LINEAGE evidence (`replicaVerdict`): the
    master is healthy in its own view, and the target's copy is validated
    against that master's current history and has not applied past it (or
    the target holds no data at all). Item counts prove nothing. The master
    the grant relied on is bound in the grant and re-checked at admission and
    on every pass while granted.
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
  /-- the generation of the fence the barrier was read under (#1) -/
  fenceGen : Option Nat := none
  barrier : Option Nat := none
  /-- how many times the fence lapsed during this prepare (each voided the
      barrier) -/
  lapses : Nat := 0
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

/-- The fence as the target reports it, in ONE reading (write_fence::snapshot). -/
structure FenceObs where
  token : String
  inFlight : Nat
  /-- incremented by flared each time the fence goes from not armed to armed -/
  generation : Nat
  deriving Repr, BEq

/-- A node's OWN view: its assignment in the node map it has accepted. -/
structure OwnView where
  role : String
  partition : Int
  mapVersion : Nat
  deriving Repr, BEq

/-- A successor candidate (master target), read fresh from its own stats. -/
structure SuccObs where
  key : String
  binding : Binding
  /-- an Active, Ready slave of the partition on ANOTHER node, R3 eligible
      and following, not rebuilding (only meaningful before the switch) -/
  eligible : Bool
  ready : Bool
  applied : Option Nat
  own : Option OwnView
  deriving Repr

/-- Replica target: the facts the lineage verdict is made from. -/
structure ReplicaObs where
  /-- the master of the partition in the committed map, Ready, with its
      identity and history read from its own stats -/
  masterKey : Option String := none
  masterBinding : Option Binding := none
  masterOwn : Option OwnView := none
  /-- its history (`rocksdb_source_epoch`) and latest sequence -/
  masterSourceEpoch : Option String := none
  masterSeq : Option Nat := none
  /-- identity consistent, not quarantined / partial / restored-unverified -/
  masterSound : Bool := false
  /-- the target's R3 binding: state, the node key and history validated -/
  targetSourceState : Option String := none
  targetReadSource : Option String := none
  targetReadSourceEpoch : Option String := none
  targetApplied : Option Nat := none
  targetItems : Option Nat := none
  deriving Repr

/-- Fresh observations for one prepare step (the IO shell reads them). -/
structure Obs where
  now : Nat
  leaseEpoch : Nat
  /-- the target pod still exists with this UID and is not deleting -/
  targetPresent : Bool
  /-- the target flared's boot id now, `none` = unreadable -/
  targetBoot : Option String := none
  /-- target is the master (or replica) of `binding.partition` in the map -/
  targetRole : Option Target
  /-- the target's own view, `none` = unreadable -/
  targetOwn : Option OwnView := none
  /-- master target: before the pin, every candidate read now; after it, the
      pinned successor (if it could be read) -/
  candidates : List SuccObs := []
  /-- target's fence as the target reports it -/
  fence : Option FenceObs
  /-- target's latest sequence number, `none` = unreadable -/
  targetLatestSeq : Option Nat
  /-- the operator's committed map: the pinned successor master of the
      partition and the target a proxy; and that map's version -/
  desiredSwitched : Bool := false
  desiredVersion : Nat := 0
  /-- replica target -/
  replica : ReplicaObs := {}
  /-- blockers: migration, history hold, a rebuild in progress, another
      partition masterless... (empty = none) -/
  blockers : List String
  deriving Repr

/-- The successor to pin: eligible, the highest applied position, then the
    smallest key (deterministic for the same readings). -/
def chooseSuccessor (cs : List SuccObs) : Option SuccObs :=
  cs.foldl (fun best c =>
    if !c.eligible then best else
    match best with
    | none => some c
    | some b =>
      let ac := c.applied.getD 0
      let ab := b.applied.getD 0
      if ac > ab || (ac == ab && decide (c.key < b.key)) then some c else some b) none

/-- The copies a planned switch withholds: every key in the partition of a
    planned target (`partOf` of the target) other than its pinned successor
    (and other than the target itself). -/
def plannedExcluded (planned : List (String × String)) (partOf : String → Option Int) (keys : List String) : List String :=
  keys.filter fun k =>
    planned.any fun (tk, sk) => k != sk && k != tk && (partOf tk).isSome && partOf k == partOf tk

/-- Is the switch confirmed? `none` = yes, `some why` = not yet. -/
def switchPending (s : State) (o : Obs) (succ : Option SuccObs) : Option String :=
  let part : Int := Int.ofNat s.binding.partition
  if !o.desiredSwitched then some "the committed map has not switched yet"
  else match o.targetOwn with
  | none => some "the target's own map cannot be read"
  | some t =>
    if t.role != "proxy" then some s!"the target still acts as {t.role} in its own map (v{t.mapVersion})"
    else if t.mapVersion < o.desiredVersion then some s!"the target has not accepted map v{o.desiredVersion} (it has v{t.mapVersion})"
    else match succ, s.successorBinding with
    | some c, some b0 =>
      if c.binding.podUid != b0.podUid || c.binding.bootId != b0.bootId || c.binding.copyId != b0.copyId then
        some "the pinned successor is not the same pod / process / copy"
      else if !c.ready then some "the pinned successor is not Ready"
      else match c.own with
        | none => some "the pinned successor's own map cannot be read"
        | some v =>
          if v.role != "master" || v.partition != part then some s!"the pinned successor acts as {v.role} of {v.partition} in its own map"
          else if v.mapVersion < o.desiredVersion then some s!"the pinned successor has not accepted map v{o.desiredVersion} (it has v{v.mapVersion})"
          else none
    | _, _ => some "the pinned successor cannot be read"

/-- Replica target: may it be removed without losing data the master lacks?
    `.ok (master key, master binding)` or `.error why` (unknown = refused). -/
def replicaVerdict (r : ReplicaObs) (partition : Nat) : Except String (String × Binding) :=
  match r.masterKey, r.masterBinding, r.masterOwn with
  | some mk, some mb, some mo =>
    if mo.role != "master" || mo.partition != Int.ofNat partition then .error s!"the master acts as {mo.role} of {mo.partition} in its own map"
    else if !r.masterSound then .error "the master's copy is not sound (identity / quarantine / partial / restored)"
    else if r.targetItems == some 0 then .ok (mk, mb)
    else match r.targetSourceState, r.targetReadSource, r.targetReadSourceEpoch, r.masterSourceEpoch with
      | some st, some src, some te, some me =>
        if st != "eligible" then .error s!"the target's copy is not validated against the current master (R3 {st})"
        else if src != mk then .error s!"the target's copy was validated against {src}, not the current master {mk}"
        else if te.isEmpty || te != me then .error s!"the target's history {te} is not the master's {me}: it may hold updates the master lacks"
        else match r.targetApplied, r.masterSeq with
          | some a, some m =>
            if a > m then .error s!"the target applied {a}, beyond the master's {m}: it may hold updates the master lacks"
            else .ok (mk, mb)
          | _, _ => .error "the applied positions cannot be read (unknown)"
      | _, _, _, _ => .error "the target's lineage cannot be read (unknown)"
  | _, _, _ => .error "the master is not healthy or cannot be read (unknown)"

inductive Action where
  | armFence (pod token : String) (ttlSec : Nat)
  | releaseFence (pod token : String)
  | switchRoles (target successor : String)
  | notify (msg : String)
  deriving Repr, BEq

def fenceTtlSec : Nat := 30

/-- How long a grant stays usable. -/
def grantSec : Nat := 120

def abort (s : State) (why : String) : State × List Action :=
  let release := match s.fenceToken with
    | some t => if s.phase == .switching || s.phase == .granted then [] else [Action.releaseFence s.pod t]
    | none => []
  let keep := if s.phase == .switching || s.phase == .granted then s.fenceToken else none
  ({ s with phase := .aborted, reason := why, fenceToken := keep }, release ++ [.notify s!"disruption {s.id} of {s.pod} ABORTED: {why}"])

/-- After an abort in `switching` / `granted` the fence is not released at
    once: the target may still act as master in its own map (the new map has
    not reached it). While it does — or cannot be read — it is kept fenced;
    once it acts as a proxy the TTL is left to lapse; if the committed map
    made it the master again (the switch was not committed) the fence is
    released at once. The token is dropped when nothing is left to hold, so
    an aborted record stops being observed. -/
def abortedFence (s : State) (o : Obs) : State × List Action :=
  match s.fenceToken with
  | none => (s, [])
  | some tok =>
    let drop := { s with fenceToken := none }
    let ours := o.fence.any (·.token == tok)
    if !o.targetPresent then (drop, [])
    else if o.targetRole == some .master then (drop, if ours then [.releaseFence s.pod tok] else [])
    else if o.fence.any (·.token != tok) then (drop, [])
    else match o.targetOwn with
      | some v => if v.role == "master" then (s, [.armFence s.pod tok fenceTtlSec]) else (drop, [])
      | none => (s, [.armFence s.pod tok fenceTtlSec])

/-- One prepare step. Pure: the same observations give the same result. -/
def step (s : State) (o : Obs) : State × List Action :=
  if s.phase == .aborted then abortedFence s o
  else if o.leaseEpoch != s.leaseEpoch then abort s "the operator leadership changed during the prepare"
  else if !o.targetPresent then
    if s.phase == .granted then ({ s with reason := "the pod is gone (evicted)" }, [])
    else abort s "the pod was deleted or replaced during the prepare"
  else if s.phase == .granted then
    if (s.grantExpiresAt.map (fun e => decide (o.now ≥ e))).getD true then
      let rel := match s.fenceToken with | some t => [Action.releaseFence s.pod t] | none => []
      ({ s with phase := .aborted, reason := "the grant expired without an eviction (cancelled)" },
       rel ++ [.notify s!"disruption {s.id} of {s.pod}: grant expired unused; the pod stays (as a proxy it rejoins as a follower)"])
    else match s.target with
      | .replica =>
        -- #4: the grant holds only while its evidence does (same master)
        match replicaVerdict o.replica s.binding.partition with
        | .ok (mk, mb) =>
          if some mk == s.successor && some mb == s.successorBinding then (s, [])
          else ({ s with phase := .requested, grantExpiresAt := none, reason := "grant withdrawn: the master changed" }, [.notify s!"disruption {s.id}: grant withdrawn (the master changed)"])
        | .error why => ({ s with phase := .requested, grantExpiresAt := none, reason := s!"grant withdrawn: {why}" }, [.notify s!"disruption {s.id}: grant withdrawn ({why})"])
      | .master =>
        match o.targetOwn with
        | some v => if v.role == "master" then abort s "the target acts as master again in its own map" else (s, [])
        | none => (s, [])
  else if o.now ≥ s.deadline then abort s s!"the prepare did not complete in time (last: {s.reason})"
  else if !o.blockers.isEmpty then
    if s.phase == .requested then ({ s with reason := s!"held: {String.intercalate "; " o.blockers}" }, [])
    else abort s s!"a blocker appeared: {String.intercalate "; " o.blockers}"
  else match s.target with
  | .replica =>
    if o.targetRole != some .replica then abort s "the target is no longer a replica"
    else match replicaVerdict o.replica s.binding.partition with
      | .error why => ({ s with reason := s!"held: {why}" }, [])
      | .ok (mk, mb) =>
        ({ s with phase := .granted, successor := some mk, successorBinding := some mb, grantExpiresAt := some (o.now + grantSec), reason := "" },
         [.notify s!"disruption {s.id}: replica {s.pod} may be evicted (master {mk} holds its history)"])
  | .master =>
    let tok := s.fenceToken.getD ""
    let rearm := [Action.armFence s.pod tok fenceTtlSec]
    match s.phase with
    | .requested =>
      if o.targetRole != some .master then abort s "the target is no longer the master"
      else match chooseSuccessor o.candidates with
      | none => ({ s with reason := "held: no eligible successor on another node" }, [])
      | some c =>
        let tok := s!"{s.id}-{s.attempt}"
        ({ s with phase := .fencing, successor := some c.key, successorBinding := some c.binding, fenceToken := some tok, reason := "" },
         [.armFence s.pod tok fenceTtlSec])
    | .fencing | .draining | .applying | .switching =>
      let pinned := s.successor.bind fun k => o.candidates.find? (·.key == k)
      if o.targetBoot.isSome && o.targetBoot != some s.binding.bootId then
        abort s "the target flared restarted during the prepare (its fence is gone)"
      else if s.phase != .switching && o.targetRole != some .master then abort s "the target is no longer the master"
      else
      -- the pinned successor, unchanged (before the switch: still eligible)
      let succBad : Option String := match pinned, s.successorBinding with
        | some c, some b0 =>
          if s.phase == .switching then
            (if c.binding.podUid != b0.podUid || c.binding.bootId != b0.bootId || c.binding.copyId != b0.copyId then some "the pinned successor changed identity" else none)
          else if c.binding != b0 then some "the pinned successor changed identity (UID / boot / copy / history)"
          else if !c.eligible then some "the pinned successor lost its eligibility"
          else none
        | none, _ => if s.phase == .switching then none else some "the pinned successor cannot be read or is gone"
        | _, none => some "no successor pinned"
      match succBad with
      | some why => abort s why
      | none =>
      match o.fence with
      | none =>
        if s.phase == .fencing then ({ s with reason := "waiting for the fence to be confirmed" }, rearm)
        else lapse s o "the fence is not armed"
      | some f =>
        if f.token != tok then abort s "the target holds another fence"
        else if s.phase == .fencing then
          ({ s with phase := .draining, fenceGen := some f.generation, reason := "" }, rearm)
        else if s.fenceGen != some f.generation then
          lapse s o s!"the fence generation moved ({(s.fenceGen.map toString).getD "?"} -> {f.generation})"
        else if s.phase == .draining then
          if f.inFlight != 0 then ({ s with reason := s!"draining {f.inFlight} in-flight mutation(s)" }, rearm)
          else match o.targetLatestSeq with
            | none => ({ s with reason := "the barrier cannot be read" }, rearm)
            | some seq => ({ s with phase := .applying, barrier := some seq, reason := "" }, rearm)
        else if s.phase == .applying then
          match s.barrier, pinned.bind (·.applied) with
          | some bar, some ap =>
            if ap ≥ bar then ({ s with phase := .switching, reason := "" }, rearm ++ [.switchRoles s.pod (s.successor.getD "")])
            else ({ s with reason := s!"successor at {ap}, barrier {bar}" }, rearm)
          | _, _ => ({ s with reason := "the successor's applied position cannot be read" }, rearm)
        else -- switching
          match switchPending s o pinned with
          | none =>
            -- granted; the fence is KEPT (not released, not re-armed): the
            -- target acts as a proxy in its own map now, so when the TTL
            -- lapses its writes are forwarded to the new master (#2)
            ({ s with phase := .granted, grantExpiresAt := some (o.now + grantSec), reason := "" },
             [.notify s!"disruption {s.id}: master {s.pod} handed over to {s.successor.getD "?"} (both confirmed in their own maps); it may be evicted"])
          | some why => ({ s with reason := s!"waiting for the role switch to be confirmed: {why}" }, rearm)
    | _ => (s, [])
where
  /-- #1: the fence was not continuous, so the barrier is void. Before the
      committed map switched: re-fence (re-drain, re-read the barrier, wait
      for the successor again). After it: abort (no grant). -/
  lapse (s : State) (o : Obs) (why : String) : State × List Action :=
    let tok := s.fenceToken.getD ""
    let seqNote := match s.barrier, o.targetLatestSeq with
      | some b, some q => if q > b then s!"; the target's sequence moved {b} -> {q} (writes after the barrier)" else s!"; the target's sequence is still {q}"
      | _, _ => ""
    if s.phase == .switching && o.desiredSwitched then
      abort s s!"the fence lapsed after the switch was committed ({why}){seqNote}: not granted"
    else
      ({ s with phase := .fencing, fenceGen := none, barrier := none, lapses := s.lapses + 1,
                reason := s!"the fence lapsed ({why}): the barrier is void; re-fencing{seqNote}" },
       [.armFence s.pod tok fenceTtlSec, .notify s!"disruption {s.id}: fence lapsed on {s.pod} ({why}); barrier voided{seqNote}"])

end FlareOperator.Disruption
