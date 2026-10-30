/-
  StateMachine/NodeMove.lean — the operator side of the cordon move
  (flare-cordon-proactive-move; design: flare-ci-inputs/decisions/
  NODE-OPS-NOSTOP-IMPLEMENTATION-PLAN-2026-10-26.md section C).

  A Node turns unschedulable (cordon). For each flared pod on it, one at a
  time, the operator

    pending ── (master) ask the ordered handover for a successor on another node
       │       (replica) demote to a proxy
       ▼
    handingOver ── the handover finished: the pod is a proxy
       ▼
    proxied ── remove the serving label (the client Service selects it)
       ▼
    unserved ── wait: the pod's address left the EndpointSlice, no new
       │        connection for a while, no open connection (bounded: then
       │        HOLD as a proxy, alert, never delete)
       ▼
    released ── written ONLY by the operator (CAS). From here no cancel.
       │        The node guard lets an eviction / delete of THIS pod through
       │        (and the operator deletes it itself after a grace)
       ▼
    deleted ── the old pod is gone
       ▼
    resyncing ── the recreated pod (other node) is seated as a replica of its
       │         partition; when Active + synced it gets the serving label back
       ▼
    done          cancelled: uncordon before `released` (generation + 1; the
                  serving label is restored only AFTER this was persisted)

  The whole record is `status.nodeMoves`, written with a compare-and-swap on
  the FlareCluster's resourceVersion, so an operator restart resumes from it
  and the node guard's `admitted` write and the operator's `released` /
  `cancelled` write exclude each other: whichever commits first wins.

  Everything here is pure; Main reads the observations and carries out the
  action a step asks for AFTER the step's new state is persisted.
-/
import Lean.Data.Json
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.NodeMove

open FlareOperator.K8s

inductive Phase where
  | pending
  | handingOver
  | proxied
  | unserved
  | released
  | deleted
  | resyncing
  | done
  | cancelled
  deriving Repr, BEq, Inhabited

def Phase.toString : Phase → String
  | .pending => "pending"
  | .handingOver => "handingOver"
  | .proxied => "proxied"
  | .unserved => "unserved"
  | .released => "released"
  | .deleted => "deleted"
  | .resyncing => "resyncing"
  | .done => "done"
  | .cancelled => "cancelled"

instance : ToString Phase := ⟨Phase.toString⟩

def Phase.fromString? : String → Option Phase
  | "pending" => some .pending
  | "handingOver" => some .handingOver
  | "proxied" => some .proxied
  | "unserved" => some .unserved
  | "released" => some .released
  | "deleted" => some .deleted
  | "resyncing" => some .resyncing
  | "done" => some .done
  | "cancelled" => some .cancelled
  | _ => none

/-- the label the client Service selects on (chart: `<name>-nodes-external`) -/
def servingLabel : String := "flare.gree.net/serving"

structure Config where
  /-- partitions need at least this many real copies, the moving one included -/
  minCopies : Nat := 3
  /-- unserved → hold after this (the pod stays a proxy, alert, never deleted) -/
  drainWaitMs : Nat := 120000
  /-- total_connections must not have increased for this long -/
  quietMs : Nat := 10000
  /-- released → the operator deletes the pod itself after this -/
  evictWaitMs : Nat := 60000
  /-- handover attempts before the move holds -/
  maxHandoverAttempts : Nat := 3
  retryDelayMs : Nat := 5000
  deriving Repr

structure Move where
  /-- request id: new for every move of a pod -/
  id : String
  /-- bumped by every cancel; `released`/`admitted` bind to (id, generation) -/
  generation : Nat := 1
  node : String
  pod : String
  podUid : String
  /-- the pod's flared node key -/
  key : String
  /-- the pod's role when the move started: "master" / "slave" / "proxy" -/
  role : String
  partition : Int := -1
  phase : Phase := .pending
  /-- master: the node key of the replica that takes over -/
  successor : String := ""
  reason : String := ""
  /-- unserved: the wait bound passed (the pod is held as a proxy; alert) -/
  held : Bool := false
  /-- handover attempts so far (master) -/
  attempts : Nat := 0
  /-- AdmissionReview uid the guard last wrote with its allow (audit) -/
  admittedUid : String := ""
  /-- cancelled: the serving label has been put back (or never left) -/
  restored : Bool := false
  startedMs : Nat := 0
  phaseMs : Nat := 0
  releasedMs : Nat := 0
  deriving Repr, BEq, Inhabited

/-- A pod that cannot be moved now (under minCopies, ...): what is shown. -/
structure Blocked where
  pod : String
  node : String
  reason : String
  deriving Repr, BEq, Inhabited

structure Ledger where
  /-- the next request id number -/
  seq : Nat := 0
  moves : List Move := []
  blocked : List Blocked := []
  deriving Repr, BEq, Inhabited

/-- Finished and nothing left to do (a cancelled move still owes the serving label). -/
def Move.finished (m : Move) : Bool :=
  m.phase == .done || (m.phase == .cancelled && m.restored)

def Ledger.active (l : Ledger) : Option Move := l.moves.find? (!·.finished)

def Ledger.forPod (l : Ledger) (pod : String) : Option Move :=
  l.moves.find? fun m => m.pod == pod && !m.finished

/-- a pod's serving label is not put back by the generic label pass while
    this holds (a move owns it) -/
def Ledger.ownsLabel (l : Ledger) (pod : String) : Bool := (l.forPod pod).isSome

def Ledger.upsert (l : Ledger) (m : Move) : Ledger :=
  { l with moves := if l.moves.any (·.id == m.id) then l.moves.map (fun x => if x.id == m.id then m else x)
                    else l.moves ++ [m] }

/-- the finished moves are kept for the audit, the last few only -/
def Ledger.trim (l : Ledger) (keep : Nat := 6) : Ledger :=
  let fin := l.moves.filter (·.finished)
  let drop := fin.length - keep
  let dropIds := (fin.take drop).map (·.id)
  { l with moves := l.moves.filter fun m => !dropIds.contains m.id }

/-- Keys held out of the map's assignment while a move runs: the pod that is
    being emptied must not be seated again as a replica by the pass that
    sees its partition short of one (it is demoted ON PURPOSE), and the
    successor waits for the handover's promotion. -/
def Ledger.heldKeys (l : Ledger) : List String :=
  l.moves.foldl (fun acc m =>
    if m.finished then acc
    else match m.phase with
      | .pending => if m.successor.isEmpty then acc else acc ++ [m.successor]
      | .handingOver => (if m.successor.isEmpty then acc else acc ++ [m.successor]) ++ [m.key]
      | .proxied | .unserved | .released => acc ++ [m.key]
      | .deleted => acc ++ [m.key]
      | .resyncing | .done | .cancelled => acc) []

-- ═══════════════════════════════════════════════════════════════════════
-- Real copies (plan C.5)
-- ═══════════════════════════════════════════════════════════════════════

/-- One copy of a partition as Main read it. -/
structure CopyFact where
  key : String
  nodeName : String
  /-- Active in the map and its pod Ready, not Terminating -/
  active : Bool
  /-- same history as the master: copy identity consistent, same lineage and
      source epoch (StatsObservation.repairSourceVerdict says none) -/
  sameHistory : Bool
  /-- a replica repair is open for it -/
  repairOpen : Bool
  /-- the master dropped / failed writes to it since the ledger started -/
  dropIncreased : Bool
  deriving Repr, BEq, Inhabited

/-- Copies that still count with `cordoned` nodes going away: on a node that
    is not cordoned, Active, same history, no open repair, no new drop. -/
def realCopies (cordoned : List String) (cs : List CopyFact) : Nat :=
  (cs.filter fun c => !c.nodeName.isEmpty && !cordoned.contains c.nodeName
    && c.active && c.sameHistory && !c.repairOpen && !c.dropIncreased).length

/-- Why a pod may NOT be moved now, or none. `movingCopy` = the pod itself
    holds a copy of the partition (master / replica); `others` are the other
    copies of the partition. The partition keeps `real` copies while this one
    is away and must still have `minCopies` counting the moving copy. -/
def startBlock (cfg : Config) (role : String) (cordoned : List String) (others : List CopyFact) : Option String :=
  if role == "proxy" then none
  else
    let real := realCopies cordoned others
    let need := cfg.minCopies - 1
    if real < 1 then
      some s!"no other real copy of the partition would remain (0 of {others.length} other copies are Active, on an uncordoned node, with the same history, without an open repair); not started — it starts when one is"
    else if real < need then
      some s!"only {real} real copy(ies) would remain besides this one; nodeReplacement.minCopies is {cfg.minCopies} (needs {need}); not started — add a copy or lower minCopies (an accepted risk)"
    else none

-- ═══════════════════════════════════════════════════════════════════════
-- One step
-- ═══════════════════════════════════════════════════════════════════════

/-- The pod now named like the move's pod (it may be the recreated one). -/
structure CurPod where
  uid : String
  terminating : Bool
  ready : Bool
  serving : Bool
  role : Option FlareRole
  /-- Active in the map -/
  active : Bool
  /-- the replica is synced: eligible read source (R3) -/
  synced : Bool
  deriving Repr, BEq, Inhabited

inductive HandoverView where
  /-- no handover entry for the partition -/
  | none
  | running
  | aborted (why : String)
  deriving Repr, BEq, Inhabited

structure Obs where
  nowMs : Nat
  nodeCordoned : Bool
  cur : Option CurPod := none
  handover : HandoverView := .none
  /-- the successor is the partition's master in the map -/
  successorIsMaster : Bool := false
  /-- the pod's address is in an EndpointSlice of the client Service (none = unread) -/
  inEndpoints : Option Bool := none
  /-- how long total_connections has not increased (none = unread) -/
  quietMs : Option Nat := none
  currConnections : Option Nat := none
  /-- flared's own view (stats own_role) says proxy (none = unread) -/
  ownProxy : Option Bool := none
  deriving Repr

inductive Action where
  | none
  | requestHandover
  | demote
  | removeServing
  | restoreServing
  | deletePod
  deriving Repr, BEq, Inhabited

def Action.label : Action → String
  | .none => "none"
  | .requestHandover => "requestHandover"
  | .demote => "demote"
  | .removeServing => "removeServing"
  | .restoreServing => "restoreServing"
  | .deletePod => "deletePod"

private def goto (m : Move) (p : Phase) (now : Nat) (why : String := "") : Move :=
  { m with phase := p, phaseMs := now, reason := why, held := false }

/-- uncordon: cancel (generation + 1). The serving label is put back by a
    LATER step, once this is persisted. -/
private def cancel (m : Move) (now : Nat) (why : String) : Move :=
  { goto m .cancelled now why with generation := m.generation + 1 }

def Obs.podPresent (o : Obs) (m : Move) : Bool := o.cur.any (·.uid == m.podUid)

/-- All three proofs that the client Service no longer sends to the pod. -/
def drained (cfg : Config) (o : Obs) : Bool :=
  o.ownProxy == some true && o.inEndpoints == some false && (o.quietMs.any (· >= cfg.quietMs)) && o.currConnections == some 0

/-- why the drain is not proven yet (status / alert text) -/
def drainWhy (cfg : Config) (o : Obs) : String :=
  let p := match o.ownProxy with
    | some true => "own_role proxy"
    | some false => "own_role is not proxy yet"
    | none => "own_role unreadable"
  let a := match o.inEndpoints with
    | some false => "address left the EndpointSlice"
    | some true => "address still in the EndpointSlice"
    | none => "EndpointSlice unreadable"
  let b := match o.quietMs with
    | some q => if q >= cfg.quietMs then "no new connections" else s!"new connections {q} ms ago (needs {cfg.quietMs})"
    | none => "total_connections unreadable"
  let c := match o.currConnections with
    | some 0 => "no open connections"
    | some n => s!"{n} open connection(s)"
    | none => "curr_connections unreadable"
  s!"{p}; {a}; {b}; {c}"

/-- One step of the move. Pure: Main persists the new move (CAS) and then
    carries out the action. Unreadable observations never advance a phase. -/
def step (cfg : Config) (m : Move) (o : Obs) : Move × Action :=
  let now := o.nowMs
  match m.phase with
  | .pending =>
    if !o.nodeCordoned then (cancel m now "the node was uncordoned before the move started", .none)
    else if o.cur.isNone || !o.podPresent m then
      (cancel m now "the pod was replaced or removed before the move started", .none)
    else if m.role == "master" then
      ({ goto m .handingOver now with attempts := 1 }, .requestHandover)
    else if m.role == "slave" then
      if o.cur.any (·.role == some FlareRole.Proxy) then (goto m .proxied now, .none)
      else (m, .demote)
    else (goto m .proxied now, .none)
  | .handingOver =>
    let proxy := o.cur.any (·.role == some FlareRole.Proxy)
    if !o.podPresent m then
      (cancel m now "the pod went away during the handover", .none)
    else if proxy && o.successorIsMaster then
      -- finished: continue the move, or (uncordoned meanwhile) end it
      if o.nodeCordoned then (goto m .proxied now, .none)
      else (cancel m now "the node was uncordoned while the handover ran", .none)
    else match o.handover with
      | .running => (m, .none)
      | .aborted why =>
        if m.attempts >= cfg.maxHandoverAttempts then
          ({ m with held := true, reason := s!"the handover aborted {m.attempts} time(s) (last: {why}); held — the pod stays a master" }, .none)
        else if now >= m.phaseMs + cfg.retryDelayMs then
          ({ m with attempts := m.attempts + 1, phaseMs := now, reason := s!"retrying after: {why}" }, .requestHandover)
        else (m, .none)
      | .none =>
        if !o.nodeCordoned then (cancel m now "the node was uncordoned before the handover started", .none)
        else if o.cur.any (·.role == some FlareRole.Master) then (m, .requestHandover)
        else (m, .none)
  | .proxied =>
    if !o.nodeCordoned then (cancel m now "the node was uncordoned", .none)
    else if !o.podPresent m then (cancel m now "the pod went away", .none)
    else if o.cur.any (·.serving) then (m, .removeServing)
    else (goto m .unserved now, .none)
  | .unserved =>
    if !o.nodeCordoned then (cancel m now "the node was uncordoned", .none)
    else if !o.podPresent m then (cancel m now "the pod went away", .none)
    else if o.cur.any (·.serving) then (m, .removeServing)
    else if drained cfg o then ({ goto m .released now with releasedMs := now }, .none)
    else if now >= m.phaseMs + cfg.drainWaitMs then
      ({ m with held := true,
                reason := s!"the client Service still reaches the pod after {cfg.drainWaitMs / 1000} s ({drainWhy cfg o}); held as a proxy, nothing is deleted" }, .none)
    else ({ m with reason := drainWhy cfg o }, .none)
  | .released =>
    -- no cancel from here: the move completes
    if !o.podPresent m then (goto m .deleted now, .none)
    else if o.cur.any (·.terminating) then (m, .none)
    else if now >= m.releasedMs + cfg.evictWaitMs then (m, .deletePod)
    else (m, .none)
  | .deleted =>
    match o.cur with
    | some c => if c.uid != m.podUid then (goto m .resyncing now, .none) else (m, .none)
    | none => (m, .none)
  | .resyncing =>
    match o.cur with
    | none => (m, .none)
    | some c =>
      if c.uid == m.podUid then (goto m .deleted now, .none)  -- the old pod again (it was still going)
      else if c.terminating then (m, .none)                 -- never label a terminating pod
      else if c.serving then (goto m .done now, .none)
      else if c.ready && c.active && c.synced && c.role == some FlareRole.Slave then (m, .restoreServing)
      else (m, .none)
  | .cancelled =>
    if m.restored then (m, .none)
    else match o.cur with
      | none => ({ m with restored := true }, .none)
      | some c =>
        if c.serving || c.terminating then ({ m with restored := !c.terminating || c.serving }, .none)
        else if c.ready then (m, .restoreServing)
        else (m, .none)
  | .done => (m, .none)

-- ═══════════════════════════════════════════════════════════════════════
-- Starting a move
-- ═══════════════════════════════════════════════════════════════════════

/-- A flared pod on a cordoned node, with what the start decision needs. -/
structure Cand where
  pod : String
  key : String
  uid : String
  node : String
  role : String
  partition : Int
  /-- the other copies of its partition -/
  others : List CopyFact
  /-- master: the replica that takes over (an uncordoned, caught-up Active Slave) -/
  successor : Option String
  /-- Terminating / not Ready pods are not moved -/
  movable : Bool := true
  deriving Repr

inductive Start where
  | idle
  | start (m : Move)
  deriving Repr

/-- Start the next move if none is active: slaves before masters (a master's
    handover is the more disruptive step, so the replicas of its partition
    are settled first), ties by pod name. Candidates that cannot start are
    reported (blocked) and skipped; they stay held by the node guard. -/
def next (cfg : Config) (l : Ledger) (cordoned : List String) (cs : List Cand) (nowMs : Nat)
    : Start × List Blocked :=
  -- a done move for the same UID means the observation is stale (a moved pod
  -- comes back with a new UID); a cancelled one may start again (new request)
  let cands := cs.filter fun c => cordoned.contains c.node
    && !(l.moves.any fun m => m.pod == c.pod && (!m.finished || (m.phase == .done && m.podUid == c.uid)))
  let sorted := (cands.toArray.qsort fun a b =>
    let ra := if a.role == "master" then 1 else 0
    let rb := if b.role == "master" then 1 else 0
    if ra != rb then ra < rb else a.pod < b.pod).toList
  let why : Cand → Option String := fun c =>
    if !c.movable then some "the pod is not Ready or is terminating"
    else if c.role == "master" && c.successor.isNone then
      some "no caught-up replica on an uncordoned node to take the master over"
    else startBlock cfg c.role cordoned c.others
  let blocked := sorted.filterMap fun c => (why c).map fun w => ({ pod := c.pod, node := c.node, reason := w } : Blocked)
  if (l.active).isSome then (.idle, blocked)
  else match sorted.find? (fun c => (why c).isNone) with
    | none => (.idle, blocked)
    | some c =>
      (.start { id := s!"mv{l.seq + 1}-{c.uid.take 8}", node := c.node, pod := c.pod, podUid := c.uid,
                key := c.key, role := c.role, partition := c.partition, phase := .pending,
                successor := c.successor.getD "", startedMs := nowMs, phaseMs := nowMs,
                reason := "started" },
       blocked.filter fun b => b.pod != c.pod)

-- ═══════════════════════════════════════════════════════════════════════
-- The node guard (plan C.6)
-- ═══════════════════════════════════════════════════════════════════════

inductive Guard where
  /-- the pod has no move and is not on a cordoned node: the usual rules -/
  | unrelated
  /-- refuse, retry later (429) -/
  | hold (why : String)
  /-- allow, after writing `admitted` for this move (CAS) -/
  | permit (m : Move)
  deriving Repr, BEq, Inhabited

/-- What the guard does with the eviction / delete of a pod. `podUid`, its
    serving label and node come from the review; `cordoned` from the Nodes. -/
def guard (l : Ledger) (cordoned : List String) (podName podUid podNode : String) (podServing : Bool)
    (podRole : Option FlareRole) : Guard :=
  match l.forPod podName with
  | some m =>
    if m.phase != .released then
      .hold s!"flare: pod {podName} is being moved off node {m.node} (phase {m.phase}{if m.reason.isEmpty then "" else s!": {m.reason}"}); eviction is held until it is released"
    else if m.podUid != podUid then
      .hold s!"flare: the move {m.id} is for another incarnation of {podName} (uid {m.podUid}, this one {podUid})"
    else if podServing then
      .hold s!"flare: pod {podName} carries the serving label again; the move {m.id} does not release it"
    else if !(cordoned.contains m.node && podNode == m.node) then
      .hold s!"flare: node {m.node} is no longer cordoned (or the pod is elsewhere); the move {m.id} does not release the pod"
    else .permit m
  | none =>
    if cordoned.contains podNode && podRole != some FlareRole.Proxy then
      .hold s!"flare: node {podNode} is cordoned and the cordon move of {podName} has not been released (not started: waiting for its turn or for enough real copies, see status.nodeMoves)"
    else .unrelated

/-- Record the AdmissionReview uid the guard is about to allow with. -/
def Ledger.admit (l : Ledger) (m : Move) (reviewUid : String) : Ledger :=
  l.upsert { m with admittedUid := reviewUid }

/-- uncordon: may this move still be cancelled? (After `released` it may not.) -/
def Move.cancellable (m : Move) : Bool :=
  match m.phase with
  | .pending | .handingOver | .proxied | .unserved => true
  | _ => false

-- ═══════════════════════════════════════════════════════════════════════
-- Persistence (FlareCluster status.nodeMoves)
-- ═══════════════════════════════════════════════════════════════════════

open Lean in
def Move.toJson (m : Move) : Json :=
  Json.mkObj [("id", Json.str m.id), ("generation", Json.num m.generation), ("node", Json.str m.node),
    ("pod", Json.str m.pod), ("podUid", Json.str m.podUid), ("key", Json.str m.key), ("role", Json.str m.role),
    ("partition", Json.num m.partition), ("phase", Json.str m.phase.toString),
    ("successor", Json.str m.successor), ("reason", Json.str m.reason), ("held", Json.bool m.held),
    ("attempts", Json.num m.attempts), ("admittedUid", Json.str m.admittedUid),
    ("restored", Json.bool m.restored), ("startedMs", Json.num m.startedMs),
    ("phaseMs", Json.num m.phaseMs), ("releasedMs", Json.num m.releasedMs)]

open Lean in
def Move.fromJson? (j : Json) : Option Move := do
  let s := fun (k : String) => (j.getObjValAs? String k).toOption
  let n := fun (k : String) => (j.getObjValAs? Nat k).toOption
  let id ← s "id"
  let node ← s "node"
  let pod ← s "pod"
  let phase ← (s "phase") >>= Phase.fromString?
  pure { id, node, pod, phase,
         generation := (n "generation").getD 1, podUid := (s "podUid").getD "", key := (s "key").getD "",
         role := (s "role").getD "", partition := (j.getObjValAs? Int "partition").toOption.getD (-1),
         successor := (s "successor").getD "", reason := (s "reason").getD "",
         held := (j.getObjValAs? Bool "held").toOption.getD false, attempts := (n "attempts").getD 0,
         admittedUid := (s "admittedUid").getD "", restored := (j.getObjValAs? Bool "restored").toOption.getD false,
         startedMs := (n "startedMs").getD 0, phaseMs := (n "phaseMs").getD 0, releasedMs := (n "releasedMs").getD 0 }

open Lean in
def Ledger.toJson (l : Ledger) : Json :=
  Json.mkObj [("seq", Json.num l.seq), ("moves", Json.arr (l.moves.map Move.toJson).toArray),
    ("blocked", Json.arr (l.blocked.map fun b =>
      Json.mkObj [("pod", Json.str b.pod), ("node", Json.str b.node), ("reason", Json.str b.reason)]).toArray)]

open Lean in
/-- Strict, like the other ledgers: one malformed move fails the whole read. -/
def Ledger.fromJson? (j : Json) : Option Ledger := do
  let moves ← match j.getObjVal? "moves" with
    | .ok (Json.arr a) => a.toList.mapM Move.fromJson?
    | .ok _ => none
    | .error _ => some []
  let blocked := match j.getObjVal? "blocked" with
    | .ok (Json.arr a) => a.toList.filterMap fun b =>
        match (b.getObjValAs? String "pod").toOption, (b.getObjValAs? String "node").toOption with
        | some pod, some node => some ({ pod, node, reason := (b.getObjValAs? String "reason").toOption.getD "" } : Blocked)
        | _, _ => none
    | _ => []
  pure { seq := (j.getObjValAs? Nat "seq").toOption.getD 0, moves, blocked }

def Ledger.summary (l : Ledger) : String :=
  match l.moves.filter (!·.finished) with
  | [] => if l.blocked.isEmpty then "no node moves" else s!"no node move running; {l.blocked.length} blocked"
  | ms => String.intercalate "; " <| ms.map fun m =>
      s!"{m.pod}@{m.node} {m.phase} g{m.generation}{if m.reason.isEmpty then "" else s!" ({m.reason})"}"

end FlareOperator.NodeMove
