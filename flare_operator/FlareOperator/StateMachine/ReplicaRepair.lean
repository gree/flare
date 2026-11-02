/-
  StateMachine/ReplicaRepair.lean — SAF-02 / SAF-05, SC-03 / EV-03.

  "A replica with missed writes remains repair-pending until reconstruction
  completes and missing data is recovered."

  The master counts the replica writes it gave up forwarding, per
  destination (`proxy_write_dropped[host:port]` in `stats`). Live
  replication has no per-write acknowledgement, so this counter is the ONLY
  signal that a replica is quietly behind, and the operator is the only
  thing that can act on it. What acting means: put the replica through
  reconstruction — demote it to an unassigned Proxy, let the assignment
  pass seat it again as Slave/Prepare, and let flared's role diff
  (proxy → slave) start a reconstruction it reports back as Prepare → Active.

  Why this is a ledger and not a counter check:

  * A demotion that flared never sees does nothing. The old code demoted
    AFTER the commit and re-seated the node in the NEXT pass before any
    send, so the Proxy map never went on the wire; flared saw Slave/Active
    → Slave/Prepare, same role, same partition — a STATE-only change,
    which dispatches nothing (cluster::_shift_node_state is a stub) and,
    worse, matches the "map says prepare but I am active" guard that
    re-announces Active. The repair was silently skipped and the counter
    consumed. Here the node stays HELD as Proxy, out of assignment, until
    its own `node_map_version` shows it applied the demotion.
  * A drop seen while repair is not allowed (breaker held, a partition
    masterless, resync disabled) used to be consumed unrepaired. Here it
    stays `requested` and is acted on when the gate opens.
  * A destination that matches no Slave right now (mid-drain, mid-rejoin)
    stays `requested` and is resolved again every pass.
  * Operator restart, master restart and counter reset are handled by
    persisting the ledger — entries AND last-seen counters — in the
    FlareCluster status, and by treating a counter that went DOWN as a
    new incarnation whose count is entirely new drops.
  * Completion is not "the node is Active again": the re-announce path can
    make it Active without reconstructing. Completion requires the node's
    own `reconstruction_completed` counter to have moved since the reseat.
  * A reconstruction the operator did not start can BE the repair
    (ADOPTION, see `reconstructingKeys`): one that began after the drops
    were counted copies every write they stand for, so a request whose
    destination starts reconstructing after it was recorded is closed by
    that reconstruction's success, with no demotion and no extra rebuild
    (a recreated pod's boot reconstruction, CI 41278035134).

  Everything that decides is pure and in this file; Main.lean feeds it
  observations and applies its actions. The unit checks in
  FlareOperator/UnitTests.lean exercise the decisions, the replica-repair
  E2E suite exercises the whole path against real flared.
-/
import Lean.Data.Json
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.ReplicaRepair

open FlareOperator.K8s

/-- Where a repair stands. -/
inductive Phase where
  /-- Drops attributed; nothing committed yet (unresolved, gated, or simply new). -/
  | requested
  /-- The node was committed as Proxy at this node-map version; it is held out
      of assignment until its own reported version reaches it. -/
  | demoted (version : Nat)
  /-- The node applied the demotion and was released to assignment; waiting
      for Slave/Active with a moved reconstruction counter. -/
  | reseated
  /-- ADOPTED: the node began reconstructing (Slave/Prepare) after the
      request was recorded, without a demotion; that reconstruction is the
      repair. Waiting, like `reseated`, for Slave/Active with a success newer
      than the baseline in `bootIdAtReseat`/`currentIdAtReseat`; never
      demoted while in this phase (see `reconstructingKeys`). -/
  | adopted
  deriving Repr, BEq, DecidableEq

def Phase.toString : Phase → String
  | .requested => "requested"
  | .demoted v => s!"demoted@{v}"
  | .reseated => "reseated"
  | .adopted => "adopted"

instance : ToString Phase := ⟨Phase.toString⟩

structure Entry where
  /-- Destination exactly as the master reported it (host:port). -/
  dest : String
  /-- The master whose counter attributed the drops. -/
  masterKey : String
  /-- Resolved node key of the replica, once a Slave matched `dest`. -/
  nodeKey : Option String := none
  phase : Phase := .requested
  /-- Drops attributed so far (informational; the repair is the same). -/
  drops : Nat := 0
  /-- flared's process boot id and latest reconstruction id when the node
      was released to assignment. Completion is a reconstruction that
      SUCCEEDED from the current master and is either NEWER than
      `currentIdAtReseat` in the SAME process, or any success in a DIFFERENT
      process (boot id changed: a restarted node reconstructs from boot, and
      its counters may equal the old ones by coincidence — review item 4). -/
  bootIdAtReseat : Option Nat := none
  currentIdAtReseat : Option Nat := none
  /-- Drops attributed when the node was released. Drops that arrive AFTER
      the reconstruction began may not be in the copy (item 3): on
      completion the increment is requeued as a fresh request. -/
  dropsAtReseat : Nat := 0
  /-- Why a resolved request is not being acted on this pass (gate reason). -/
  hold : Option String := none
  /-- SAF-10c: the destination runs a continuous WAL follower, which OWNS the
      repair of this drop (design §5.4). The ledger records the request and
      HOLDS it — no demotion, no reconstruction — and closes it once the
      follower's applied position has reached `mustReach`. Ownership is the
      MODE, not the connection state: a follower that is momentarily
      `disconnected` still owns it. Only the follower's own `needs_rebuild`
      hands the entry back to the demote → hold → reseat path. -/
  owned : Bool := false
  /-- The master's latest sequence when the drop was observed: the dropped
      write is at or below it, so a follower that has applied past it has the
      write. Only comparable within `barEpoch`: a position from another
      history says nothing about this bar. -/
  mustReach : Option Nat := none
  /-- The master's source epoch when the bar was taken. -/
  barEpoch : Option String := none
  /-- ADOPTION (see `reconstructingKeys`): the LATEST drop increment was
      recorded while the destination was NOT Slave/Prepare in the operator's
      map (read after the master's counter). False = recorded while it was
      reconstructing, or unknown: no adoption, the 7be3ca6 path (deferred
      while Prepare, demoted once Active). Absent in an older status = false. -/
  adoptable : Bool := false
  /-- The destination's flared boot id and latest reconstruction id, read
      AFTER the latest drop increment was counted (none = unreadable). A
      reconstruction with a larger id in that boot, or any in a later boot,
      began after the read and so after every drop of this entry. -/
  bootAtRequest : Option Nat := none
  currentIdAtRequest : Option Nat := none
  /-- The destination pod's UID read after the latest drop increment: `some
      ""` = no such pod existed, `none` = could not be read. Used only when
      the flared reading above is missing (the pod was gone or not yet
      serving): a pod with ANOTHER UID was created after that read, so its
      flared process — and every reconstruction it runs — is newer than the
      drops. -/
  podAtRequest : Option String := none
  deriving Repr, BEq

structure Ledger where
  /-- False until the first observation. On that first pass every counter is
      recorded as a baseline and no drop is attributed: drops that predate
      the ledger cannot be told from history, and repairing every replica
      with a historical drop on every fresh cluster would be churn. -/
  initialized : Bool := false
  /-- Last-seen `proxy_write_dropped[dest]` per (master, dest). -/
  counters : List (String × Nat) := []
  entries : List Entry := []
  deriving Repr, BEq

def counterKey (masterKey dest : String) (boot : Option Nat := none) : String :=
  match boot with
  | some b => s!"{masterKey}|{dest}|{b}"
  | none => s!"{masterKey}|{dest}"

/-- Outcome of comparing one observed counter to the ledger. -/
inductive DropDelta where
  | firstSighting (n : Nat)      -- first sighting on an uninitialized ledger: n > 0 = possibly unrepaired
  | unchanged
  | increased (by_ : Nat)
  | reset (now : Nat)            -- counter went down: new incarnation, `now` are new drops
  deriving Repr, BEq

def classify (prev : Option Nat) (initialized : Bool) (n : Nat) : DropDelta :=
  match prev with
  | none => if initialized then (if n > 0 then .increased n else .unchanged) else .firstSighting n
  | some p => if n > p then .increased (n - p) else if n < p then .reset n else .unchanged

/-- Fold one master's `proxy_write_dropped[dest]` readings into the ledger.
    Returns the ledger with counters updated, the (dest, newDrops) pairs that
    must become or extend requests, and which of those dests came from a
    FIRST SIGHTING. A `reset` with `now = 0` is a restart with no drops yet
    and attributes nothing.

    FIRST SIGHTING (CI 37376724850): the first observation of a fresh ledger
    used to be a pure baseline, so drops before it were never repaired. A
    non-zero count seen first is now a request — POSSIBLY unrepaired: the
    drops happened at an unknown time, perhaps already repaired by other
    means. It is not a demotion; it goes through the same ownership and gate
    path as any request. The cost is a possibly unnecessary rebuild after an
    operator upgrade or a lost status; the alternative is silent divergence.

    PROCESS IDENTITY: counters are keyed by the master's flared boot id when
    it is known (`boot`). A restarted master starts a new key, so its count is
    never compared with the old process's (a restart whose count climbed back
    above the old value was attributed only the difference). Keys of the same
    master under another boot are dropped; the same cumulative value is never
    requested twice. -/
def observe (l : Ledger) (masterKey : String) (observed : List (String × Nat))
    (boot : Option Nat := none) : Ledger × List (String × Nat) × List String :=
  -- Forget this master's counters from OTHER processes (another boot id,
  -- or the boot-less form written before boot ids were recorded). Only when
  -- the boot is known: without it the old keys are the only reference.
  let otherProcess := fun (k : String) =>
    match boot with
    | some b =>
      let parts := k.splitOn "|"
      parts.head? == some masterKey && (parts.length != 3 || parts.getLast? != some (toString b))
    | none => false
  let l0 := { l with counters := l.counters.filter (fun (k, _) => !otherProcess k) }
  let step := fun (acc : Ledger × List (String × Nat) × List String) ((dest, n) : String × Nat) =>
    let (led, drops, first) := acc
    let key := counterKey masterKey dest boot
    let delta := classify (led.counters.lookup key) l.initialized n
    let led' := { led with counters := (led.counters.filter (·.1 != key)) ++ [(key, n)] }
    match delta with
    | .increased d => (led', drops ++ [(dest, d)], first)
    | .reset now => if now > 0 then (led', drops ++ [(dest, now)], first) else (led', drops, first)
    | .firstSighting n => if n > 0 then (led', drops ++ [(dest, n)], first ++ [dest]) else (led', drops, first)
    | .unchanged => (led', drops, first)
  let (led, drops, first) := observed.foldl step (l0, [], [])
  ({ led with initialized := true }, drops, first)

/-- What the caller saw of a drop's destination right AFTER reading the
    master's counter: the ADOPTION evidence (see `reconstructingKeys`). The
    default (nothing seen) is never adoptable — the 7be3ca6 behaviour. -/
structure RequestSight where
  /-- The destination was not Slave/Prepare in the operator's map. -/
  outsidePrepare : Bool := false
  /-- Its flared `reconstruction_boot_id` / `reconstruction_current_id`. -/
  bootId : Option Nat := none
  currentId : Option Nat := none
  /-- Its pod UID (`some ""` = no pod), `none` = unreadable. -/
  podUid : Option String := none
  deriving Repr, BEq

/-- Record drops for a destination: a new `requested` entry, or more drops on
    an existing one (whatever its phase — a repair in flight subsumes them,
    because reconstruction copies the whole partition).

    ADOPTION evidence is that of the LATEST increment (`sight`): every
    earlier drop of the entry was counted before it too, so a reconstruction
    that began after this increment covers them all; one counted while the
    destination is reconstructing makes the entry not adoptable (rule 2: it
    may postdate that reconstruction's final catch-up). An ADOPTED entry that
    gains drops goes back to `requested` for the same reason: the adopted
    reconstruction may not hold them. `demoted`/`reseated` keep the existing
    late-drop handling (`dropsAtReseat`, `completedRequeued`). -/
def request (l : Ledger) (masterKey dest : String) (drops : Nat) (sight : RequestSight := {}) : Ledger :=
  let withSight := fun (e : Entry) =>
    { e with adoptable := sight.outsidePrepare, bootAtRequest := sight.bootId,
             currentIdAtRequest := sight.currentId, podAtRequest := sight.podUid }
  match l.entries.find? (·.dest == dest) with
  | some _ =>
    { l with entries := l.entries.map fun e =>
        if e.dest != dest then e
        else match e.phase with
          | .requested => withSight { e with drops := e.drops + drops }
          | .adopted =>
            withSight { e with phase := .requested, drops := e.drops + drops,
                               bootIdAtReseat := none, currentIdAtReseat := none, dropsAtReseat := 0 }
          | _ => { e with drops := e.drops + drops } }
  | none =>
    { l with entries := l.entries ++ [withSight { dest := dest, masterKey := masterKey, drops := drops }] }

/-- SAF-10c: the follower ITSELF declared `needs_rebuild` — history purged
    past its position, the source epoch changed, an integrity failure, an
    incomplete restore. No drop counter is involved and none may ever be:
    the node must still take the rebuild path (demote → hold → reseat →
    reconstruction), so it gets an ordinary, un-owned request keyed by its
    own node key (which `resolveKey` accepts as a destination). Idempotent:
    a node that already has an entry, owned or not, gets nothing new — an
    owned entry is handed over by `advanceOwned` on the same reading.
    Returns whether a request was added. -/
def requestRebuild (l : Ledger) (masterKey nodeKey : String) : Ledger × Bool :=
  if l.entries.any (fun e => e.nodeKey == some nodeKey || e.dest == nodeKey) then (l, false)
  else ({ l with entries := l.entries ++ [{ dest := nodeKey, masterKey := masterKey, nodeKey := some nodeKey }] }, true)

/-- Find the node a destination refers to. The master reports the address it
    connected to, which is the node's server name (and port); accept the
    full key or the host alone. -/
def resolveKey (state : FlareClusterState) (dest : String) : Option (String × FlareNode) :=
  let host := (dest.splitOn ":").head?.getD dest
  state.nodeMap.find? fun (k, n) => k == dest || n.serverName == host

/-- Resolve unresolved requests against the committed map. A destination
    that is now a MASTER cannot be repaired by demotion and its missed
    writes are on a primary: the entry is VOIDED and returned so the caller
    can shout. Anything that is not a Slave stays unresolved. -/
def resolve (l : Ledger) (state : FlareClusterState) : Ledger × List Entry :=
  let step := fun (acc : List Entry × List Entry) (e : Entry) =>
    let (kept, voided) := acc
    match e.nodeKey with
    | some _ => (kept ++ [e], voided)
    | none =>
      match resolveKey state e.dest with
      | some (k, n) =>
        if n.role == FlareRole.Master then (kept, voided ++ [e])
        else if n.role == FlareRole.Slave then (kept ++ [{ e with nodeKey := some k }], voided)
        else (kept ++ [e], voided)
      | none => (kept ++ [e], voided)
  let (kept, voided) := l.entries.foldl step ([], [])
  ({ l with entries := kept }, voided)

/-- Node keys that must stay out of role assignment this pass: demoted, not
    yet confirmed by the node itself. -/
def heldKeys (l : Ledger) : List String :=
  l.entries.filterMap fun e =>
    match e.phase, e.nodeKey with
    | .demoted _, some k => some k
    | _, _ => none

/-- Why a request against a reconstructing destination is not acted on. -/
def reconstructingHold : String :=
  "the destination is reconstructing from its master (Slave/Prepare): no demotion while it does; the request is kept — closed by this reconstruction if it began after the drops (adopted), otherwise it takes the ordinary repair path once Active"

/-- Node keys of the committed map that are reconstructing right now: a
    Slave in Prepare (a reconstruction from the master in progress — the
    boot reconstruction of a recreated pod, or a re-seated repair). A request
    against such a node is never demoted: the demotion is what breaks the
    rebuilding node (CI 41278035134: drops counted against a replica's OLD
    pod, whose forwards failed while it was cut and deleted, became a request
    that demoted the RECREATED pod ~1 s into its boot reconstruction; flared
    kept retrying that reconstruction as a proxy and the cluster wedged for
    24 min).

    ADOPTION — a reconstruction that STARTED AFTER the drops were counted is
    the repair. flared's reconstruction (src/lib/handler_reconstruction.cc)
    first waits until the master's map forwards to it (:282-298), then takes
    L0, copies (snapshot/dump) and catches up through the WAL to L1 and again
    to now_lsn (:1410-1506): every write the master applied before the
    reconstruction began is in the copy, and a counted drop stands for such
    a write. Order is established from flared's own record, not from timing
    guesses: one handler = one `reconstruction_current_id`, assigned when it
    begins (stats::reconstruction_begin), so a success with an id LARGER than
    the one read after the drops were counted — or any success of a later
    process (another boot id, or a pod with another UID than the one that
    existed then) — began after those drops. So a request whose latest drops
    were recorded while the destination was NOT reconstructing
    (`Entry.adoptable`) and which then sees it Slave/Prepare is ADOPTED
    (`advanceEntry`): no demotion, and that reconstruction's success closes
    it. Not adopted (the 7be3ca6 behaviour: held while Prepare, then the
    ordinary demote → reseat path once Active, one extra rebuild):
    * drops counted while it was ALREADY reconstructing — they may postdate
      the copy's final catch-up (a write forwarded to a Prepare slave and
      dropped is not in its copy), and the order cannot be told; this
      includes drops that grow during an adopted reconstruction (`request`
      returns the entry to `requested`);
    * no baseline: neither flared's reading nor a newer pod proves the
      reconstruction began after the drops;
    * the node turns Active without a qualifying success (`adoptionLapsed`).
    A reconstruction whose Prepare was shorter than one operator pass (the
    map was never observed in Prepare) is covered too: an adoptable request
    whose node is already Slave/Active with a success newer than the
    baseline is closed directly (`advanceEntry`, step `adoptedCompleted`). -/
def reconstructingKeys (state : FlareClusterState) : List String :=
  state.nodeMap.filterMap fun (k, n) =>
    if n.role == FlareRole.Slave && n.state == FlareState.Prepare then some k else none

/-- Is `dest` (as the master reports it) a Slave in Prepare in `state`? A
    destination that is not in the map, or not a Slave, is not
    reconstructing by the map (see `reconstructingKeys` for why the
    adoption does not rest on the map alone). -/
def destReconstructing (state : FlareClusterState) (dest : String) : Bool :=
  match resolveKey state dest with
  | some (_, n) => n.role == FlareRole.Slave && n.state == FlareState.Prepare
  | none => false

/-- Resolved requests the caller should demote now. When `allowed` is false
    they are marked with the gate reason instead and nothing is returned.
    A request whose node is in `reconstructing` (see `reconstructingKeys`)
    is never returned: it is held with `reconstructingHold` and kept. -/
def plan (l : Ledger) (allowed : Bool) (gateReason : String)
    (reconstructing : List String := []) : Ledger × List (String × Entry) :=
  if allowed then
    let deferred := fun (e : Entry) =>
      match e.phase, e.nodeKey with
      | .requested, some k => !e.owned && reconstructing.contains k
      | _, _ => false
    let acts := l.entries.filterMap fun e =>
      match e.phase, e.nodeKey with
      | .requested, some k => if e.owned || deferred e then none else some (k, e)
      | _, _ => none
    ({ l with entries := l.entries.map fun e =>
        if e.owned then e
        else if deferred e then { e with hold := some reconstructingHold }
        else { e with hold := none } }, acts)
  else
    ({ l with entries := l.entries.map fun e =>
        match e.phase, e.nodeKey with
        | .requested, some _ => { e with hold := some gateReason }
        | _, _ => e }, [])

/-- What the destination's own stats say about its continuous follower. -/
structure FollowReading where
  /-- The stats reply was read to its END. A COMPLETE reply without the
      follower keys is a flared without a follower (tch/tcb, or an older
      build): that is "not in the mode", not "unreadable". Only a failed or
      truncated read is Unknown. (Regression found by the replica-repair
      suite on tch: with `unreadable := state.isNone` every drop on a
      non-RocksDB replica was held as "follower state unknown" forever.) -/
  complete : Bool := false
  /-- `repl_follow_enabled`: the mode is on for that node. -/
  enabled : Bool := false
  /-- `repl_follow_state`: idle / initial_sync / following / disconnected /
      needs_rebuild / error. `none` = the stats could not be read. -/
  state : Option String := none
  /-- `repl_applied_lsn`: contiguously applied position. -/
  appliedLsn : Option Nat := none
  /-- `repl_follow_source_epoch`: the history that position belongs to. -/
  sourceEpoch : Option String := none
  deriving Repr, BEq

/-- Nothing could be read. Unknown is Unknown: it neither claims nor ends
    ownership, and it never drives a demotion (SAF-04 typing, applied here). -/
def FollowReading.unreadable (r : FollowReading) : Bool := !r.complete

/-- Does the follower own this destination's repair? The mode must be on and
    the follower must not have given up: `needs_rebuild` is the one state in
    which it hands over. `disconnected` and `error` still own — resuming from
    the position is the follower's job, and starting a reconstruction there
    would be exactly the blip-costs-a-rebuild failure this exists to remove.
    Unreadable stats (`state = none`) do NOT claim ownership: fail closed to
    the path that does not depend on the reading. -/
def ownedByFollower (r : FollowReading) : Bool :=
  r.enabled && (match r.state with
    | some "following" | some "initial_sync" | some "disconnected" | some "error" => true
    | _ => false)

/-- Hold `dest`'s request under the follower's ownership, recording the
    position the follower must reach. A later drop raises the bar, never
    lowers it. -/
def holdOwned (l : Ledger) (dest : String) (masterSeq : Option Nat) (masterEpoch : Option String)
    (reason : String := "owned by continuous replication") : Ledger :=
  { l with entries := l.entries.map fun e =>
      if e.dest == dest then
        -- A bar from a DIFFERENT epoch than the one recorded is not
        -- comparable: the newer epoch replaces it rather than being max'd.
        let sameEpoch := e.barEpoch == masterEpoch || e.barEpoch.isNone
        { e with owned := true, hold := some reason,
                 mustReach := (if sameEpoch then
                     (match e.mustReach, masterSeq with
                       | some a, some b => some (max a b)
                       | some a, none => some a
                       | none, b => b)
                   else masterSeq),
                 barEpoch := (if masterEpoch.isSome then masterEpoch else e.barEpoch) }
      else e }

/-- At request time: does the reading let the follower own this drop, and
    what should the ledger do? `none` = the stats could not be read — then the
    request is HELD as "follower state unknown", still owned in the sense
    that nothing destructive happens to it, until a readable pass decides. -/
def ownershipAtRequest (r : FollowReading) : Option Bool :=
  if r.unreadable then none else some (ownedByFollower r)

/-- Outcome of checking an owned entry against the follower's reading. -/
inductive OwnedStep where
  | keep            -- still owned, not yet reached
  | closed          -- the follower applied past the drop: repaired without a rebuild
  | handedOver      -- the follower declared needs_rebuild (or the mode went off): the normal path takes it
  deriving Repr, BEq

/-- Advance one OWNED entry by the follower's reading. Closing requires the
    follower to be `following` (connected and applying — a disconnected
    follower's position is stale by definition) AND a recorded bar AND the
    applied position at or past it. An entry with no bar cannot be closed by
    position and is handed over rather than trusted. -/
def advanceOwned (e : Entry) (r : FollowReading) : Option Entry × OwnedStep :=
  if !e.owned then (some e, .keep)
  else if r.unreadable then
    -- A transient stats failure decides NOTHING: keep the hold, say why, and
    -- try again next pass. Handing over here would turn a probe hiccup into
    -- a demotion and a reconstruction.
    (some { e with hold := some "follower state unknown (stats unreadable)" }, .keep)
  else if !(ownedByFollower r) then
    -- An EXPLICIT reading that the follower does not own it (needs_rebuild,
    -- idle, mode off): ownership ends, the entry becomes an ordinary request
    -- again (drops and node key kept).
    (some { e with owned := false, hold := none }, .handedOver)
  else
    -- Readable and owning. Closing requires: following (a disconnected
    -- follower's position is stale), a recorded bar, the SAME history as
    -- the bar — a position from another epoch is a different number line —
    -- and the position at or past the bar.
    let e := { e with hold := some "owned by continuous replication" }
    match r.state, r.appliedLsn, e.mustReach with
    | some "following", some applied, some bar =>
      if r.sourceEpoch.isSome && r.sourceEpoch == e.barEpoch && applied ≥ bar then (none, .closed)
      else (some e, .keep)
    | _, _, none =>
      -- No bar was ever recorded (the master's sequence was unreadable at
      -- every observation): it cannot be closed by position. Keep it owned
      -- rather than trust it; the next observed drop supplies a bar.
      (some e, .keep)
    | _, _, _ => (some e, .keep)

def advanceOwnedAll (l : Ledger) (readings : List (String × FollowReading)) : Ledger × List (Entry × OwnedStep) :=
  let step := fun (acc : List Entry × List (Entry × OwnedStep)) (e : Entry) =>
    let (kept, out) := acc
    match readings.lookup e.dest with
    | none => (kept ++ [e], out)
    | some r =>
      match advanceOwned e r with
      | (some e', st) => (kept ++ [e'], if st == .keep then out else out ++ [(e', st)])
      | (none, st) => (kept, out ++ [(e, st)])
  let (kept, out) := l.entries.foldl step ([], [])
  ({ l with entries := kept }, out)

/-- The caller committed `dest`'s node as Proxy at `version`. -/
def markDemoted (l : Ledger) (dest : String) (version : Nat) : Ledger :=
  { l with entries := l.entries.map fun e =>
      if e.dest == dest then { e with phase := .demoted version, hold := none } else e }

/-- What one pass observed about a replica under repair. -/
structure Observation where
  /-- The node's own `node_map_version`, if its stats could be read. -/
  reportedVersion : Option Nat := none
  /-- flared's completion record (see stats.h): boot id, latest handler id
      and state, last successful id and its source. -/
  bootId : Option Nat := none
  currentId : Option Nat := none
  currentState : Option String := none
  lastSuccessId : Option Nat := none
  lastSuccessSource : Option String := none
  /-- The current Active master key of the node's partition (what a success
      must have copied from). -/
  currentMaster : Option String := none
  /-- Role/state of the node in the committed map, if present. -/
  mapped : Option (FlareRole × FlareState) := none
  /-- The node's pod UID, read before AND after the stats with the same
      answer (`some ""` = no pod); `none` = not read or changed in between.
      Read only for an adoption without a flared baseline. -/
  podUid : Option String := none

inductive Step where
  | none
  | released      -- demotion confirmed; node freed for assignment
  | completed     -- Slave/Active with a reconstruction that began after the reseat and finished
  | completedRequeued -- as `completed`, but drops arrived after the reconstruction began: the increment is requeued
  | voided        -- node became a Master while under repair
  | adopted       -- a reconstruction that began after the drops is in progress: it is the repair (no demotion)
  | adoptedCompleted -- the adopted reconstruction succeeded from the current master (or, for a Prepare shorter than a pass, one seen only once Active): closed
  | adoptionLapsed   -- Active without a qualifying success: back to the ordinary path
  | adoptionUnproven -- reconstructing, but nothing proves it began after the drops: the 7be3ca6 path
  deriving Repr, BEq

/-- The adoption baseline (boot id, reconstruction id) for an adoptable
    request whose node `o` shows reconstructing: flared's reading taken after
    the latest drops, or — when that was unreadable — `(boot, 0)` of a
    process in a pod with ANOTHER UID than the one that existed then (or none
    existed): every reconstruction of that process began after the drops.
    `none` = no proof. -/
def adoptionBaseline (e : Entry) (o : Observation) : Option (Nat × Nat) :=
  match e.bootAtRequest, e.currentIdAtRequest with
  | some b0, some c0 => some (b0, c0)
  | _, _ =>
    match e.podAtRequest, o.podUid, o.bootId with
    | some p0, some p, some b => if !p.isEmpty && p != p0 then some (b, 0) else none
    | _, _, _ => none

/-- A reconstruction that SUCCEEDED (the latest handler), from the CURRENT
    master, and began after the baseline: newer in the same process, or of a
    different process (boot id changed). -/
def successAfter (boot0 cid0 : Nat) (o : Observation) : Bool :=
  match o.bootId, o.currentId, o.currentState, o.lastSuccessId, o.lastSuccessSource, o.currentMaster with
  | some boot, some cid, some st, some lsid, some src, some master =>
    st == "succeeded" && lsid == cid && cid ≥ 1 && src == master && ((boot != boot0) || (cid > cid0))
  | _, _, _, _, _, _ => false

/-- Advance one entry by one observation. -/
def advanceEntry (e : Entry) (o : Observation) : Option Entry × Step :=
  match e.phase with
  | .requested =>
    -- ADOPTION (see `reconstructingKeys`): the node began reconstructing
    -- after the latest drops were recorded outside Prepare
    if !e.owned && e.adoptable && o.mapped == some (FlareRole.Slave, FlareState.Prepare) then
      match adoptionBaseline e o with
      | some (b0, c0) =>
        (some { e with phase := .adopted, bootIdAtReseat := some b0, currentIdAtReseat := some c0,
                       dropsAtReseat := e.drops, hold := Option.none }, .adopted)
      | Option.none =>
        -- an unreadable node decides nothing yet; a readable one without a
        -- baseline cannot be ordered after the drops
        if o.bootId.isNone then (some e, .none)
        else (some { e with adoptable := false }, .adoptionUnproven)
    -- A Prepare shorter than one pass is never observed: the node is
    -- already Active. Its success closes the request directly when it is
    -- newer than the baseline read after the latest drops (same proof: that
    -- reconstruction began after them).
    else if !e.owned && e.adoptable && o.mapped == some (FlareRole.Slave, FlareState.Active) then
      match adoptionBaseline e o with
      | some (b0, c0) => if successAfter b0 c0 o then (Option.none, .adoptedCompleted) else (some e, .none)
      | Option.none => (some e, .none)
    else (some e, .none)
  | .adopted =>
    match o.mapped with
    | some (FlareRole.Master, _) => (Option.none, .voided)
    | some (FlareRole.Slave, FlareState.Active) =>
      match e.bootIdAtReseat, e.currentIdAtReseat, o.bootId, o.currentId, o.currentState with
      | some b0, some c0, some boot, some cid, some st =>
        if successAfter b0 c0 o then (Option.none, .adoptedCompleted)
        -- the adopted handler is still finishing (Active is reported from
        -- inside it, just before its success is recorded)
        else if st == "running" && ((boot != b0) || (cid > c0)) then (some e, .none)
        else
          (some { e with phase := .requested, adoptable := false, bootIdAtReseat := Option.none,
                         currentIdAtReseat := Option.none, dropsAtReseat := 0 }, .adoptionLapsed)
      | _, _, _, _, _ => (some e, .none)
    | _ => (some e, .none)
  | .demoted v =>
    match o.mapped with
    | some (FlareRole.Master, _) => (Option.none, .voided)
    | _ =>
      match o.reportedVersion with
      | some rv =>
        if rv ≥ v then
          (some { e with phase := .reseated, bootIdAtReseat := o.bootId,
                         currentIdAtReseat := o.currentId, dropsAtReseat := e.drops }, .released)
        else (some e, .none)
      | Option.none => (some e, .none)
  | .reseated =>
    match o.mapped with
    | some (FlareRole.Master, _) => (Option.none, .voided)
    | some (FlareRole.Slave, FlareState.Active) =>
      match o.bootId, o.currentId, o.currentState, o.lastSuccessId, o.lastSuccessSource, o.currentMaster with
      | some boot, some cid, some st, some lsid, some src, some master =>
        match e.bootIdAtReseat, e.currentIdAtReseat with
        | some boot0, some cid0 =>
          -- The copy that recovers the drops is a reconstruction that
          -- SUCCEEDED (the latest handler, not an earlier one before a
          -- failure), from the CURRENT master, and is either newer than the
          -- one current at reseat in the same process, or belongs to a new
          -- process (boot id changed) — which covers a restart whose
          -- counters happen to equal the old ones (item 4), and a failure
          -- followed by a success (item 3 of the second review).
          let newEnough := (boot != boot0) || (cid > cid0)
          if st == "succeeded" && lsid == cid && cid ≥ 1 && src == master && newEnough then
            if e.drops > e.dropsAtReseat then
              (some { e with phase := .requested, drops := e.drops - e.dropsAtReseat,
                             bootIdAtReseat := Option.none, currentIdAtReseat := Option.none,
                             dropsAtReseat := 0, hold := Option.none },
               .completedRequeued)
            else (Option.none, .completed)
          else (some e, .none)
        -- No baseline readable at release: record the first readable one
        -- and wait for a later success.
        | _, _ => (some { e with bootIdAtReseat := some boot, currentIdAtReseat := some cid }, .none)
      | _, _, _, _, _, _ => (some e, .none)
    | _ => (some e, .none)

/-- Advance every entry the caller could observe. Entries without an
    observation are untouched. -/
def advance (l : Ledger) (obs : List (String × Observation)) : Ledger × List (Entry × Step) :=
  let step := fun (acc : List Entry × List (Entry × Step)) (e : Entry) =>
    let (kept, steps) := acc
    match obs.lookup e.dest with
    | Option.none => (kept ++ [e], steps)
    | some o =>
      let (e', st) := advanceEntry e o
      let steps' := if st == .none then steps else steps ++ [(e, st)]
      match e' with
      | some e'' => (kept ++ [e''], steps')
      | Option.none => (kept, steps')
  let (kept, steps) := l.entries.foldl step ([], [])
  ({ l with entries := kept }, steps)

/-- An adoptable request whose node is Slave/Active while a reconstruction
    that began after the baseline is still finishing (Active is reported from
    inside the handler, just before its success is recorded). -/
def adoptionFinishing (e : Entry) (o : Observation) : Bool :=
  e.phase == .requested && !e.owned && e.adoptable
    && o.mapped == some (FlareRole.Slave, FlareState.Active)
    && match adoptionBaseline e o, o.bootId, o.currentId, o.currentState with
      | some (b0, c0), some boot, some cid, some st => st == "running" && ((boot != b0) || (cid > c0))
      | _, _, _, _ => false

/-- The adoption close, applied BEFORE the demotion plan (review of a549080,
    P1): with the gate open, `plan` returns every requested Slave/Active
    node, so a Prepare that ended between two passes was demoted before part
    2 could close its request. This closes each adoptable request whose node
    `obs` shows Slave/Active with a success newer than the baseline (the
    `adoptedCompleted` of `advanceEntry`), and returns the node keys whose
    qualifying reconstruction is still finishing: the caller holds those out
    of the plan like a node in Prepare. Every other entry is untouched (the
    ordinary path decides it). -/
def adoptBeforePlan (l : Ledger) (obs : List (String × Observation)) :
    Ledger × List Entry × List String :=
  let step := fun (acc : List Entry × List Entry × List String) (e : Entry) =>
    let (kept, closed, finishing) := acc
    let candidate := e.phase == .requested && !e.owned && e.adoptable
    match candidate, obs.lookup e.dest with
    | true, some o =>
      if o.mapped != some (FlareRole.Slave, FlareState.Active) then (kept ++ [e], closed, finishing)
      else match advanceEntry e o with
        | (Option.none, .adoptedCompleted) => (kept, closed ++ [e], finishing)
        | _ =>
          let fin := if adoptionFinishing e o then e.nodeKey.toList else []
          (kept ++ [e], closed, finishing ++ fin)
    | _, _ => (kept ++ [e], closed, finishing)
  let (kept, closed, finishing) := l.entries.foldl step ([], [], [])
  ({ l with entries := kept }, closed, finishing)

-- ═══════════════════════════════════════════════════════════════════════
-- Persistence (FlareCluster status.replicaRepairs)
-- ═══════════════════════════════════════════════════════════════════════

open Lean in
def Phase.toJson : Phase → Json
  | .requested => Json.mkObj [("kind", Json.str "requested")]
  | .demoted v => Json.mkObj [("kind", Json.str "demoted"), ("version", Json.num v)]
  | .reseated => Json.mkObj [("kind", Json.str "reseated")]
  | .adopted => Json.mkObj [("kind", Json.str "adopted")]

open Lean in
def Phase.fromJson? (j : Json) : Option Phase :=
  match j.getObjValAs? String "kind" with
  | .ok "requested" => some .requested
  | .ok "reseated" => some .reseated
  | .ok "adopted" => some .adopted
  | .ok "demoted" =>
    match j.getObjValAs? Nat "version" with
    | .ok v => some (.demoted v)
    | .error _ => none
  | _ => none

open Lean in
def Entry.toJson (e : Entry) : Json :=
  Json.mkObj <|
    ([("dest", Json.str e.dest), ("masterKey", Json.str e.masterKey),
      ("phase", e.phase.toJson), ("drops", Json.num e.drops)] : List (String × Json))
    ++ (match e.nodeKey with | some k => [("nodeKey", Json.str k)] | none => [])
    ++ (match e.bootIdAtReseat with | some b => [("bootIdAtReseat", Json.num b)] | none => [])
    ++ (match e.currentIdAtReseat with | some b => [("currentIdAtReseat", Json.num b)] | none => [])
    ++ [("dropsAtReseat", Json.num e.dropsAtReseat)]
    ++ (match e.hold with | some h => [("hold", Json.str h)] | none => [])
    -- SAF-10c ownership must survive an operator restart: an owned entry that
    -- came back as an ordinary request would be demoted on the next pass.
    ++ (if e.owned then [("owned", Json.bool true)] else [])
    ++ (match e.mustReach with | some b => [("mustReach", Json.num b)] | none => [])
    ++ (match e.barEpoch with | some ep => [("barEpoch", Json.str ep)] | none => [])
    -- ADOPTION evidence: absent (an older status) reads back as not
    -- adoptable, i.e. the 7be3ca6 behaviour
    ++ (if e.adoptable then [("adoptable", Json.bool true)] else [])
    ++ (match e.bootAtRequest with | some b => [("bootAtRequest", Json.num b)] | none => [])
    ++ (match e.currentIdAtRequest with | some b => [("currentIdAtRequest", Json.num b)] | none => [])
    ++ (match e.podAtRequest with | some p => [("podAtRequest", Json.str p)] | none => [])

open Lean in
def Entry.fromJson? (j : Json) : Option Entry := do
  let dest ← (j.getObjValAs? String "dest").toOption
  let masterKey ← (j.getObjValAs? String "masterKey").toOption
  let phase ← (j.getObjVal? "phase").toOption >>= Phase.fromJson?
  pure {
    dest := dest, masterKey := masterKey, phase := phase,
    drops := (j.getObjValAs? Nat "drops").toOption.getD 0,
    nodeKey := (j.getObjValAs? String "nodeKey").toOption,
    bootIdAtReseat := (j.getObjValAs? Nat "bootIdAtReseat").toOption,
    currentIdAtReseat := (j.getObjValAs? Nat "currentIdAtReseat").toOption,
    dropsAtReseat := (j.getObjValAs? Nat "dropsAtReseat").toOption.getD 0,
    hold := (j.getObjValAs? String "hold").toOption,
    owned := (j.getObjValAs? Bool "owned").toOption.getD false,
    mustReach := (j.getObjValAs? Nat "mustReach").toOption,
    barEpoch := (j.getObjValAs? String "barEpoch").toOption,
    adoptable := (j.getObjValAs? Bool "adoptable").toOption.getD false,
    bootAtRequest := (j.getObjValAs? Nat "bootAtRequest").toOption,
    currentIdAtRequest := (j.getObjValAs? Nat "currentIdAtRequest").toOption,
    podAtRequest := (j.getObjValAs? String "podAtRequest").toOption }

open Lean in
def Ledger.toJson (l : Ledger) : Json :=
  Json.mkObj [
    ("initialized", Json.bool l.initialized),
    ("counters", Json.arr (l.counters.map fun (k, n) =>
        Json.mkObj [("key", Json.str k), ("count", Json.num n)]).toArray),
    ("entries", Json.arr (l.entries.map Entry.toJson).toArray) ]

open Lean in
def Ledger.fromJson? (j : Json) : Option Ledger := do
  let initialized := (j.getObjValAs? Bool "initialized").toOption.getD false
  -- STRICT (review item 2): one malformed counter or entry fails the WHOLE
  -- ledger, so the caller holds it unavailable rather than silently dropping
  -- the bad element and proceeding on a ledger that lost a request.
  let counters ← match j.getObjVal? "counters" with
    | .ok (Json.arr a) => a.toList.mapM fun c =>
        match c.getObjValAs? String "key", c.getObjValAs? Nat "count" with
        | .ok k, .ok n => some (k, n)
        | _, _ => none
    | .ok _ => none
    | .error _ => some []
  let entries ← match j.getObjVal? "entries" with
    | .ok (Json.arr a) => a.toList.mapM Entry.fromJson?
    | .ok _ => none
    | .error _ => some []
  pure { initialized := initialized, counters := counters, entries := entries }

/-- One line per entry, for logs and the status summary. -/
def Ledger.summary (l : Ledger) : String :=
  if l.entries.isEmpty then "no replica repairs pending"
  else String.intercalate "; " <| l.entries.map fun e =>
    let who := e.nodeKey.getD s!"unresolved:{e.dest}"
    let hold := match e.hold with | some h => s!" (held: {h})" | none => ""
    s!"{who} {e.phase} drops={e.drops}{hold}"

end FlareOperator.ReplicaRepair
