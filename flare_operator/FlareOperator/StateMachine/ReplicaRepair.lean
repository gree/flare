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
  deriving Repr, BEq, DecidableEq

def Phase.toString : Phase → String
  | .requested => "requested"
  | .demoted v => s!"demoted@{v}"
  | .reseated => "reseated"

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
      write. -/
  mustReach : Option Nat := none
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

def counterKey (masterKey dest : String) : String := s!"{masterKey}|{dest}"

/-- Outcome of comparing one observed counter to the ledger. -/
inductive DropDelta where
  | baseline (n : Nat)           -- first sighting on an uninitialized ledger
  | unchanged
  | increased (by_ : Nat)
  | reset (now : Nat)            -- counter went down: new incarnation, `now` are new drops
  deriving Repr, BEq

def classify (prev : Option Nat) (initialized : Bool) (n : Nat) : DropDelta :=
  match prev with
  | none => if initialized then (if n > 0 then .increased n else .unchanged) else .baseline n
  | some p => if n > p then .increased (n - p) else if n < p then .reset n else .unchanged

/-- Fold one master's `proxy_write_dropped[dest]` readings into the ledger.
    Returns the ledger with counters updated and the (dest, newDrops) pairs
    that must become or extend requests. A `reset` with `now = 0` is a
    restart with no drops yet and attributes nothing. -/
def observe (l : Ledger) (masterKey : String) (observed : List (String × Nat))
    : Ledger × List (String × Nat) :=
  let step := fun (acc : Ledger × List (String × Nat)) ((dest, n) : String × Nat) =>
    let (led, drops) := acc
    let key := counterKey masterKey dest
    let delta := classify (led.counters.lookup key) l.initialized n
    let led' := { led with counters := (led.counters.filter (·.1 != key)) ++ [(key, n)] }
    match delta with
    | .increased d => (led', drops ++ [(dest, d)])
    | .reset now => if now > 0 then (led', drops ++ [(dest, now)]) else (led', drops)
    | .baseline _ | .unchanged => (led', drops)
  let (led, drops) := observed.foldl step (l, [])
  ({ led with initialized := true }, drops)

/-- Record drops for a destination: a new `requested` entry, or more drops on
    an existing one (whatever its phase — a repair in flight subsumes them,
    because reconstruction copies the whole partition). -/
def request (l : Ledger) (masterKey dest : String) (drops : Nat) : Ledger :=
  match l.entries.find? (·.dest == dest) with
  | some _ =>
    { l with entries := l.entries.map fun e =>
        if e.dest == dest then { e with drops := e.drops + drops } else e }
  | none =>
    { l with entries := l.entries ++ [{ dest := dest, masterKey := masterKey, drops := drops }] }

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

/-- Resolved requests the caller should demote now. When `allowed` is false
    they are marked with the gate reason instead and nothing is returned. -/
def plan (l : Ledger) (allowed : Bool) (gateReason : String) : Ledger × List (String × Entry) :=
  if allowed then
    let acts := l.entries.filterMap fun e =>
      match e.phase, e.nodeKey with
      | .requested, some k => if e.owned then none else some (k, e)
      | _, _ => none
    ({ l with entries := l.entries.map fun e => if e.owned then e else { e with hold := none } }, acts)
  else
    ({ l with entries := l.entries.map fun e =>
        match e.phase, e.nodeKey with
        | .requested, some _ => { e with hold := some gateReason }
        | _, _ => e }, [])

/-- What the destination's own stats say about its continuous follower. -/
structure FollowReading where
  /-- `repl_follow_enabled`: the mode is on for that node. -/
  enabled : Bool := false
  /-- `repl_follow_state`: idle / initial_sync / following / disconnected /
      needs_rebuild / error. `none` = the stats could not be read. -/
  state : Option String := none
  /-- `repl_applied_lsn`: contiguously applied position. -/
  appliedLsn : Option Nat := none
  deriving Repr, BEq

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
def holdOwned (l : Ledger) (dest : String) (masterSeq : Option Nat) : Ledger :=
  { l with entries := l.entries.map fun e =>
      if e.dest == dest then
        { e with owned := true, hold := some "owned by continuous replication",
                 mustReach := match e.mustReach, masterSeq with
                   | some a, some b => some (max a b)
                   | some a, none => some a
                   | none, b => b }
      else e }

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
  else if !(ownedByFollower r) then
    -- needs_rebuild, idle, or unreadable: ownership ends, the entry becomes
    -- an ordinary request again (drops and node key kept).
    (some { e with owned := false, hold := none }, .handedOver)
  else
    match r.state, r.appliedLsn, e.mustReach with
    | some "following", some applied, some bar =>
      if applied ≥ bar then (none, .closed) else (some e, .keep)
    | _, _, none => (some { e with owned := false, hold := none }, .handedOver)
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

inductive Step where
  | none
  | released      -- demotion confirmed; node freed for assignment
  | completed     -- Slave/Active with a reconstruction that began after the reseat and finished
  | completedRequeued -- as `completed`, but drops arrived after the reconstruction began: the increment is requeued
  | voided        -- node became a Master while under repair
  deriving Repr, BEq

/-- Advance one entry by one observation. -/
def advanceEntry (e : Entry) (o : Observation) : Option Entry × Step :=
  match e.phase with
  | .requested => (some e, .none)
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

-- ═══════════════════════════════════════════════════════════════════════
-- Persistence (FlareCluster status.replicaRepairs)
-- ═══════════════════════════════════════════════════════════════════════

open Lean in
def Phase.toJson : Phase → Json
  | .requested => Json.mkObj [("kind", Json.str "requested")]
  | .demoted v => Json.mkObj [("kind", Json.str "demoted"), ("version", Json.num v)]
  | .reseated => Json.mkObj [("kind", Json.str "reseated")]

open Lean in
def Phase.fromJson? (j : Json) : Option Phase :=
  match j.getObjValAs? String "kind" with
  | .ok "requested" => some .requested
  | .ok "reseated" => some .reseated
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
    hold := (j.getObjValAs? String "hold").toOption }

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
