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
  /-- The replica's `reconstruction_completed` when it was released to
      assignment. Completion means the counter differs from this. -/
  completedBaseline : Option Nat := none
  /-- Why a resolved request is not being acted on this pass (gate reason). -/
  hold : Option String := none
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
      | .requested, some k => some (k, e)
      | _, _ => none
    ({ l with entries := l.entries.map fun e => { e with hold := none } }, acts)
  else
    ({ l with entries := l.entries.map fun e =>
        match e.phase, e.nodeKey with
        | .requested, some _ => { e with hold := some gateReason }
        | _, _ => e }, [])

/-- The caller committed `dest`'s node as Proxy at `version`. -/
def markDemoted (l : Ledger) (dest : String) (version : Nat) : Ledger :=
  { l with entries := l.entries.map fun e =>
      if e.dest == dest then { e with phase := .demoted version, hold := none } else e }

/-- What one pass observed about a replica under repair. -/
structure Observation where
  /-- The node's own `node_map_version`, if its stats could be read. -/
  reportedVersion : Option Nat := none
  /-- The node's own `reconstruction_completed`, if readable. -/
  reconstructionCompleted : Option Nat := none
  /-- Role/state of the node in the committed map, if present. -/
  mapped : Option (FlareRole × FlareState) := none

inductive Step where
  | none
  | released      -- demotion confirmed; node freed for assignment
  | completed     -- Slave/Active with a moved reconstruction counter
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
          (some { e with phase := .reseated, completedBaseline := o.reconstructionCompleted }, .released)
        else (some e, .none)
      | Option.none => (some e, .none)
  | .reseated =>
    match o.mapped with
    | some (FlareRole.Master, _) => (Option.none, .voided)
    | some (FlareRole.Slave, FlareState.Active) =>
      match o.reconstructionCompleted, e.completedBaseline with
      | some now, some base => if now != base then (Option.none, .completed) else (some e, .none)
      -- No baseline was readable at release time: a moved counter cannot be
      -- shown, so the first readable value becomes the baseline and the
      -- entry waits for it to move. Better a repair that lingers than one
      -- declared done on the strength of a re-announced Active.
      | some now, Option.none => (some { e with completedBaseline := some now }, .none)
      | Option.none, _ => (some e, .none)
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
    ++ (match e.completedBaseline with | some b => [("completedBaseline", Json.num b)] | none => [])
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
    completedBaseline := (j.getObjValAs? Nat "completedBaseline").toOption,
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
  let counters ← match j.getObjVal? "counters" with
    | .ok (Json.arr a) => some <| a.toList.filterMap fun c =>
        match c.getObjValAs? String "key", c.getObjValAs? Nat "count" with
        | .ok k, .ok n => some (k, n)
        | _, _ => none
    | .ok _ => none
    | .error _ => some []
  let entries ← match j.getObjVal? "entries" with
    | .ok (Json.arr a) => some (a.toList.filterMap Entry.fromJson?)
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
