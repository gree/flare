/-
  WriteAuthorityDriverChecks.lean — the operator's C' driver (WriteAuthorityDriver) run
  end to end against a FAKE cluster: in-memory ConfigMaps (the CAS fake of the intent
  checks) and fake flared nodes that follow the semantics of write_promise.cc / op_authority.cc
  (floor never lowers, prepare / commit / cancel, a promise end on the node's own clock,
  members / solo). One world clock, ms. Finite schedules; NOT the real API and NOT the real
  flared (the E2E suites are the real runs).
-/
import FlareOperator.WriteAuthorityDriver
import FlareOperator.StateMachine.PromotionIntentStoreChecks

namespace FlareOperator.WriteAuthorityDriverChecks

open FlareOperator.WriteAuthority
open FlareOperator.WriteAuthorityDriver
open FlareOperator.PromotionIntentStoreChecks
open FlareOperator.PromotionIntentStore
open FlareOperator.PromotionIntent
open FlareOperator.PromotionBinding

structure Node where
  reachable : Bool := true
  floorTerm : Option Nat := none
  state : String := "following"
  intent : Nat := 0
  promiseEnd : Nat := 0
  mode : String := "none"
  memTerm : Nat := 0
  memGen : Nat := 0
  grant : Bool := false
  solo : Bool := false
  /-- the node's identity (flared boot id, persistent copy id) -/
  boot : String := "b1"
  copy : String := "c1"
  /-- the scope of the intent held (next term, generation) -/
  pTerm : Nat := 0
  pGen : Nat := 0
  /-- the members delivery is dropped (a partition between the operator and the master) -/
  dropMembers : Bool := false
  /-- the identity the membership is bound to -/
  mbBoot : String := "b1"
  mbCopy : String := "c1"
  deriving Inhabited

def statusText (n : Node) (now : Nat) : String :=
  let rem := if n.promiseEnd > now then n.promiseEnd - now else 0
  let prom := (n.state == "committed" || n.state == "promoted") && rem == 0
  let b : Bool → String := fun x => if x then "1" else "0"
  s!"STAT authority_enabled 1\r\nSTAT authority_refused 0\r\nSTAT promise_state {n.state}\r\nSTAT promise_intent {n.intent}\r\nSTAT promise_have {b (n.promiseEnd > 0)}\r\nSTAT promise_remaining_ms {rem}\r\nSTAT promise_promotable {b prom}\r\nSTAT promise_term_next {n.pTerm}\r\nSTAT promise_gen {n.pGen}\r\nSTAT promise_boot {n.boot}\r\nSTAT promise_copy {n.copy}\r\nSTAT identity_boot {n.boot}\r\nSTAT identity_copy {n.copy}\r\nSTAT members_boot {if n.mode == "none" then "-" else n.mbBoot}\r\nSTAT members_copy {if n.mode == "none" then "-" else n.mbCopy}\r\nSTAT floor_term {n.floorTerm.getD 0}\r\nSTAT floor_gen 0\r\nSTAT floor_set {b n.floorTerm.isSome}\r\nSTAT members_mode {n.mode}\r\nSTAT members_term {n.memTerm}\r\nSTAT members_gen {n.memGen}\r\nSTAT members_successors -\r\nSTAT grant_valid {b n.grant}\r\nSTAT grant_term {n.memTerm}\r\nSTAT grant_gen {n.memGen}\r\nSTAT grant_solo {b n.solo}\r\nSTAT grant_remaining_ms 0\r\nEND\r\n"

def nat (s : String) : Nat := s.toNat?.getD 0

def newer (n : Node) (t g : Nat) : Bool := t > n.memTerm || (t == n.memTerm && g ≥ n.memGen)

/-- what flared does with one `authority ...` line (op_authority.cc + write_promise.cc) -/
def flaredApply (n : Node) (ws : List String) : Node × Option String :=
  match ws with
  | ["authority", "status", _] => (n, none)
  | ["authority", "floor", _, t, _] =>
    match n.floorTerm with
    | some f => (if nat t > f then { n with floorTerm := some (nat t) } else n, none)
    | none => ({ n with floorTerm := some (nat t) }, none)
  | "authority" :: "members" :: _ :: t :: g :: _ :: _ :: _ :: _ =>
    if n.dropMembers then (n, some "dropped")
    else if newer n (nat t) (nat g) then
      ({ n with mode := "replicated", memTerm := nat t, memGen := nat g, grant := if n.solo then false else n.grant, solo := false,
                mbBoot := n.boot, mbCopy := n.copy }, none)
    else (n, some "older term / generation than the membership held")
  | ["authority", "solo", _, t, g] =>
    if n.dropMembers then (n, some "dropped")
    else if newer n (nat t) (nat g) then
      ({ n with mode := "solo", memTerm := nat t, memGen := nat g, grant := true, solo := true, mbBoot := n.boot, mbCopy := n.copy }, none)
    else (n, some "older term / generation than the membership held")
  | ["authority", "prepare", _, id, tn, g, b, c] =>
    if b != n.boot || c != n.copy then (n, some "another incarnation or copy")
    else if n.state == "following" then ({ n with state := "preparing", intent := nat id, pTerm := nat tn, pGen := nat g }, none)
    else if n.state == "preparing" && n.intent == nat id && n.pTerm == nat tn && n.pGen == nat g then (n, none)
    else (n, some "another intent is in progress or the node is already committed / promoted")
  | ["authority", "commit", _, id, tn, g, b, c] =>
    if (n.state == "preparing" || n.state == "committed") && n.intent == nat id && n.pTerm == nat tn && n.pGen == nat g
        && b == n.boot && c == n.copy then ({ n with state := "committed" }, none)
    else (n, some "not preparing this scope")
  | ["authority", "cancel", _, id, tn, g, b, c] =>
    if n.state == "preparing" && n.intent == nat id && n.pTerm == nat tn && n.pGen == nat g && b == n.boot && c == n.copy then
      ({ n with state := "following", intent := 0, pTerm := 0, pGen := 0 }, none)
    else if n.state == "following" then (n, none)
    else (n, some "committed, promoted, or another scope: a terminal decision does not reverse")
  | _ => (n, some "bad request")

structure World where
  clock : IO.Ref Nat
  nodes : IO.Ref (List (String × Node))
  stores : IO.Ref (List (String × Fake))
  /-- (clock, node, line) of every line sent -/
  sent : IO.Ref (List (Nat × String × String))

def World.new (keys : List String) : IO World := do
  return { clock := ← IO.mkRef 1000, nodes := ← IO.mkRef (keys.map fun k => (k, ({} : Node))),
           stores := ← IO.mkRef [], sent := ← IO.mkRef [] }

def World.node (w : World) (k : String) : IO Node := do
  return ((← w.nodes.get).lookup k).getD {}

def World.setNode (w : World) (k : String) (f : Node → Node) : IO Unit :=
  w.nodes.modify fun l => l.map fun (k', x) => if k' == k then (k', f x) else (k', x)

def World.ask (w : World) (key cmd : String) : IO (Option String) := do
  let now ← w.clock.get
  w.sent.modify (· ++ [(now, key, cmd)])
  let n ← w.node key
  if !n.reachable then return none
  let (n', err) := flaredApply n ((cmd.splitOn " ").filter (· != ""))
  w.setNode key fun _ => n'
  return some (match err with | some e => s!"SERVER_ERROR {e}\r\n" | none => statusText n' now)

def World.clientFor (w : World) (name : String) : IO Client := do
  match (← w.stores.get).lookup name with
  | some f => return f.client
  | none =>
    let f ← Fake.new none
    w.stores.modify (· ++ [(name, f)])
    return f.client

def World.ctx (w : World) (token : Nat) (clockOffset : Nat := 0)
    (uidOf : String → IO (Option String) := fun _ => pure (some "uid")) : Ctx :=
  { cfg := { ttlMs := 6000, renewMs := 2000, marginMs := 5000, prepareTimeoutMs := 120000 },
    cr := "c", ns := "n", token, node := "operator",
    askNode := w.ask, clientFor := w.clientFor, podUid := uidOf, nowMs := do return (← w.clock.get) + clockOffset }

def World.setClock (w : World) (t : Nat) : IO Unit := w.clock.set t

/-- One request round of the master `m` to its successors at the world's clock (ttl 6 s, margin 5 s):
    each following successor with the master's term as its floor records its promise end; the
    master gets a grant when every one promised. -/
def World.round (w : World) (m : String) (succs : List String) : IO Unit := do
  let now ← w.clock.get
  let mn ← w.node m
  let mut all := true
  for s in succs do
    let sn ← w.node s
    if sn.reachable && sn.state == "following" && sn.floorTerm == some mn.memTerm then
      w.setNode s fun x => { x with promiseEnd := max x.promiseEnd (now + 6000 + 5000) }
    else all := false
  if all && mn.mode == "replicated" then w.setNode m fun x => { x with grant := true }

def World.decision (w : World) (name : String) : IO (Option Decision) := do
  match (← w.stores.get).lookup name with
  | none => return none
  | some f =>
    match ← f.text with
    | none => return none
    | some t => match decode t with
      | .ok i => return some i.decision
      | .error _ => return none

def World.firstSent (w : World) (key : String) (verb : String) : IO (Option Nat) := do
  return ((← w.sent.get).find? fun (_, k, c) => k == key && (c.startsWith s!"authority {verb} ")).map (·.1)

def A : String := "a-0.s.n.svc:12121"
def B : String := "a-1.s.n.svc:12121"
def C : String := "a-2.s.n.svc:12121"
def view1 (m : String) (ss : List String) : View := { master := some m, successors := ss }
def iname (p t n : Nat) : String := intentName "c" p t n
def bnd : Bind := { uid := "uid", boot := "b1", copy := "c1" }
def isHold (r : GateResult) : Bool := match r with | .hold _ => true | _ => false

/-- steady state: the record, the floors, the master holds it and it is confirmed -/
def tSteady : IO Bool := do
  let w ← World.new [A, B]
  let r ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  let nA ← w.node A
  let nB ← w.node B
  return r == some { term := 1, gen := 1, master := A, successors := [B], acked := true, ackBind := some bnd }
    && nB.floorTerm == some 1 && nA.mode == "replicated" && nA.memTerm == 1 && nA.memGen == 1
    -- idempotent: a second pass changes nothing and sends nothing but reads
    && (← ensurePartition (w.ctx 7) 0 (view1 A [B])) == r

/-- C' failover with the master cut off: nothing is committed or promoted before the
    successor's promise to the master is over on ITS clock, which is after the master's
    last possible deadline; afterwards the term moves and the new master is solo -/
def tFailover : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]                                  -- the master's last round: send point 1000, grant until 7000
  w.setNode A fun x => { x with reachable := false }
  let g1 ← gate (w.ctx 7) 0 B "uid" 6        -- intent created, successor prepared (promise runs to 12000)
  let nB1 ← w.node B
  let d1 ← w.decision (iname 0 2 1)
  w.setClock 5000
  let g2 ← gate (w.ctx 7) 0 B "uid" 6
  let d2 ← w.decision (iname 0 2 1)
  w.setClock 11999
  let g3 ← gate (w.ctx 7) 0 B "uid" 6
  let d3 ← w.decision (iname 0 2 1)
  w.setClock 12000
  let g4 ← gate (w.ctx 7) 0 B "uid" 6
  let d4 ← w.decision (iname 0 2 1)
  let nB4 ← w.node B
  let firstCommit ← w.firstSent B "commit"
  -- after the map made B the master
  let r ← ensurePartition (w.ctx 7) 0 (view1 B [])
  let nB5 ← w.node B
  return isHold g1 && nB1.state == "preparing" && nB1.intent == 201 && d1 == some .pending
    && isHold g2 && d2 == some .pending && isHold g3 && d3 == some .pending
    && g4 == .proceed && d4 == some .committed && nB4.state == "committed"
    -- no commit message before the promise end (12000), which is after the old master's deadline (7000)
    && firstCommit == some 12000
    && r == some { term := 2, gen := 2, master := B, successors := [], acked := true, ackBind := some bnd }
    && nB5.mode == "solo" && nB5.grant && nB5.solo && nB5.memTerm == 2

/-- Unknown never commits and never cancels blindly (the successor's incarnation is unreadable: the
    attempt stays as it is); once it is readable again the expired attempt is cancelled (store, then the
    successor) and the next attempt goes through -/
def tUnknownAndRecancel : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6              -- prepared, promise to 12000
  w.setNode B fun x => { x with reachable := false }
  w.setClock 20000                                 -- the promise is over, but the successor cannot be read
  let g1 ← gate (w.ctx 7) 0 B "uid" 6
  let d1 ← w.decision (iname 0 2 1)
  let c1 ← w.firstSent B "commit"
  w.setClock 200000                                -- past the prepare window (1000 + 120000)
  let g2 ← gate (w.ctx 7) 0 B "uid" 6
  let d2 ← w.decision (iname 0 2 1)
  w.setNode B fun x => { x with reachable := true }
  let nB2 ← w.node B                               -- still preparing intent 1
  let g3 ← gate (w.ctx 7) 0 B "uid" 6              -- readable: the expired attempt is cancelled (store, then the successor)
  let d3 ← w.decision (iname 0 2 1)
  let nB3 ← w.node B
  let g4 ← gate (w.ctx 7) 0 B "uid" 6              -- a new attempt (2): prepared, its old promise long over, committed, promotable
  let nB4 ← w.node B
  let d4 ← w.decision (iname 0 2 2)
  return isHold g1 && d1 == some .pending && c1 == none
    && isHold g2 && d2 == some .pending && nB2.state == "preparing" && nB2.intent == 201
    && isHold g3 && d3 == some .cancelled && nB3.state == "following"
    && g4 == .proceed && nB4.state == "committed" && nB4.intent == 202 && d4 == some .committed

/-- The operator restarts (a new leader token, a new clock): the old pending intent is not
    committed on a clock it cannot compare; it is cancelled by the new leader, then re-made -/
def tOperatorRestart : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  w.setClock 12000
  let g1 ← gate (w.ctx 8 50000) 0 B "uid" 6   -- the new leader: deadlines are on the dead leader's clock
  let d1 ← w.decision (iname 0 2 1)
  let nB1 ← w.node B
  let g2 ← gate (w.ctx 8 50000) 0 B "uid" 6   -- attempt 2 under the new token (its promise is long over: committed)
  let d2 ← w.decision (iname 0 2 2)
  let oldCommit := (← w.sent.get).any fun (_, k, c) => k == B && c.startsWith "authority commit 0 201 "
  return isHold g1 && d1 == some .cancelled && nB1.state == "following"
    && g2 == .proceed && d2 == some .committed && !oldCommit

/-- the membership does not move while an intent is open, and a master change without a committed
    intent is not accepted -/
def tFrozen : IO Bool := do
  let w ← World.new [A, B]
  let rec0 ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6          -- an open (pending) intent
  let r1 ← ensurePartition (w.ctx 7) 0 (view1 A []) [B]       -- the successor vanishes from the map: NOT solo yet (the gate asked about B)
  let r2 ← ensurePartition (w.ctx 7) 0 (view1 B [A]) [B]      -- another master without a committed intent: refused
  return r1 == rec0 && r2 == rec0

/-- the gate needs the master's confirmation, a candidate in the membership, and a record -/
def tGatePreconditions : IO Bool := do
  let w ← World.new [A, B, C]
  w.setNode A fun x => { x with reachable := false }       -- the master never confirmed
  let r ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  let g1 ← gate (w.ctx 7) 0 B "uid" 6                  -- unconfirmed membership
  let sentPrepare ← w.firstSent B "prepare"
  w.setNode A fun x => { x with reachable := true }
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  let g2 ← gate (w.ctx 7) 0 C "uid" 6                  -- not a successor
  let w2 ← World.new [A, B]
  let g3 ← gate (w2.ctx 7) 0 B "uid" 6                 -- no record at all
  return (match r with | some m => !m.acked | none => false) && isHold g1 && sentPrepare == none && isHold g2 && isHold g3
    && (← w2.firstSent B "prepare") == none

/-- a committed intent is not undone: after the CAS the old leader's cancel is refused and the
    successor stays committed -/
def tTerminal : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  w.setClock 12000
  let g ← gate (w.ctx 7) 0 B "uid" 6
  let c ← w.clientFor (iname 0 2 1)
  let res ← cancelIntent c (refOf (w.ctx 7) 0 { term := 1, gen := 1, master := A, successors := [B], acked := true } 1 B bnd) (.leader 7) { clock := (w.ctx 7).clock, t := 12000 }
  let nB ← w.node B
  return g == .proceed && (match res with | .refused _ _ => true | _ => false) && nB.state == "committed"
    && (← w.decision (iname 0 2 1)) == some .committed


/-- An intent nobody asked about in this pass is abandoned: cancelled in the store, the successor
    told (its promises and the master's grant resume), the membership no longer frozen; a COMMITTED
    one is left alone (it cannot be undone) -/
def tAbandon : IO Bool := do
  let w ← World.new [A, B]
  let rec0 ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6               -- pending and prepared: B no longer promises
  let nB1 ← w.node B
  -- the next pass does not ask the gate about B (the master is healthy again): the intent is abandoned
  let r1 ← ensurePartition (w.ctx 7) 0 (view1 A [B]) []
  let nB2 ← w.node B
  let d1 ← w.decision (iname 0 2 1)
  w.round A [B]                                         -- B promises again: the master's grant is renewed
  let nA ← w.node A
  -- and the membership can move again (B leaves the map)
  let r2 ← ensurePartition (w.ctx 7) 0 { view1 A [] with pods := some [A] } []
  -- a committed intent cannot be abandoned
  let w2 ← World.new [A, B]
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 A [B])
  w2.setClock 1000
  w2.round A [B]
  let _ ← gate (w2.ctx 7) 0 B "uid" 6
  w2.setClock 12000
  let g ← gate (w2.ctx 7) 0 B "uid" 6
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 A [B]) []
  let nB3 ← w2.node B
  return rec0.isSome && nB1.state == "preparing" && r1 == rec0 && nB2.state == "following" && d1 == some .cancelled
    && nA.grant && (match r2 with | some m => m.gen == 2 && m.successors.isEmpty | none => false)
    && g == .proceed && (← w2.decision (iname 0 2 1)) == some .committed && nB3.state == "committed"

/-- review 1: the master cut off from the operator (members delivery dropped) is not confirmed, so the
    successor is NOT promotable even if it is in the record; when the delivery recovers the normal
    switch happens -/
def tMembersDropped : IO Bool := do
  let w ← World.new [A, B]
  w.setNode A fun x => { x with dropMembers := true }
  let r ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let g1 ← gate (w.ctx 7) 0 B "uid" 6
  let sent ← w.firstSent B "prepare"
  w.setNode A fun x => { x with dropMembers := false }
  let r2 ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  let g2 ← gate (w.ctx 7) 0 B "uid" 6
  let sent2 ← w.firstSent B "prepare"
  return (match r with | some m => !m.acked | none => false) && isHold g1 && sent == none
    && (match r2 with | some m => m.acked && m.ackBind == some bnd | none => false) && sent2.isSome

/-- review 1: a successor that is temporarily not eligible / unreadable is not removed (no solo from an
    observation); only an authoritative removal is -/
def tTransient : IO Bool := do
  let w ← World.new [A, B]
  let rec0 ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  let r1 ← ensurePartition (w.ctx 7) 0 (view1 A [])                                       -- not Active / not Ready now
  let r2 ← ensurePartition (w.ctx 7) 0 { view1 A [] with pods := some [A, B] }            -- the pod is still there
  let nA ← w.node A
  let r3 ← ensurePartition (w.ctx 7) 0 { view1 A [] with pods := some [A] }               -- the pod is gone
  return r1 == rec0 && r2 == rec0 && nA.mode == "replicated" && (match r3 with | some m => m.gen == 2 && m.successors.isEmpty | none => false)

/-- review 2: a delayed command of another scope (term / generation / incarnation) changes nothing;
    an old cancel does not release a new prepare -/
def tWireScope : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6                                                      -- prepared: id 201, term_next 2, gen 1
  let sc : WireScope := { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" }
  let old : WireScope := { sc with termNext := 3 }
  let oldGen : WireScope := { sc with gen := 0 }
  let other : WireScope := { sc with copy := "c0" }
  w.setClock 20000
  let r1 ← w.ask B (cmdCommit 0 old)
  let r2 ← w.ask B (cmdCommit 0 oldGen)
  let r3 ← w.ask B (cmdCommit 0 other)
  let r4 ← w.ask B (cmdCancel 0 old)
  let n1 ← w.node B
  let r5 ← w.ask B (cmdCommit 0 sc)
  let n2 ← w.node B
  let r6 ← w.ask B (cmdCancel 0 old)                                                       -- committed: an old cancel releases nothing
  let n3 ← w.node B
  let refused : Option String → Bool := fun r => match r with | some t => t.startsWith "SERVER_ERROR" | none => false
  return refused r1 && refused r2 && refused r3 && refused r4 && n1.state == "preparing"
    && (match r5 with | some t => !t.startsWith "SERVER_ERROR" | none => false) && n2.state == "committed"
    && refused r6 && n3.state == "committed"

/-- review 2: a restarted master (another boot id, membership forgotten) is not the acknowledging
    incarnation: nothing is promotable until it holds the exact record again and acknowledges anew -/
def tMasterRestart : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  w.setNode A fun x => { x with boot := "b2", mode := "none", memTerm := 0, memGen := 0, grant := false }
  let g1 ← gate (w.ctx 7) 0 B "uid" 6
  let sent ← w.firstSent B "prepare"
  let r ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  return isHold g1 && sent == none
    && (match r with | some m => m.acked && m.ackBind == some { bnd with boot := "b2" } | none => false)

/-- the record moves to a newer generation of the same term (the pending intent was made under the old one) -/
def World.bumpGen (w : World) : IO Unit := do
  let c ← recClient (w.ctx 7) 0
  match ← readRec c with
  | .ok (some (m, rv)) => discard <| writeRec c (some rv) { m with gen := m.gen + 1 }
  | _ => pure ()

def lastSent (w : World) (key verb : String) : IO (Option String) := do
  return ((← w.sent.get).filter fun (_, k, c) => k == key && c.startsWith s!"authority {verb} ").getLast?.map (·.2.2)

/-- review (cancel scope): a pending prepare cancelled after a generation change is cancelled in its
    ORIGINAL scope (id / term / generation 1 / boot / copy), so the successor is released and a new
    prepare is accepted -/
def tCancelOldScope : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6                      -- prepared: id 201, term_next 2, gen 1
  let n1 ← w.node B
  w.bumpGen
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B]) []    -- not asked: cancelled under the gen-2 record
  let n2 ← w.node B
  let cl ← lastSent w B "cancel"
  let d1 ← w.decision (iname 0 2 1)
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6                      -- a new attempt is accepted
  let n3 ← w.node B
  return n1.state == "preparing" && n1.pGen == 1 && n2.state == "following" && d1 == some .cancelled
    && cl == some (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
    && n3.state == "preparing" && n3.intent == 202 && n3.pGen == 2

/-- review (cancel scope): the cancel message is lost (store cancelled, successor unreachable), the
    generation changes, and the re-cancel of the `.cancelled` branch is sent in the ORIGINAL scope; then a
    new prepare is accepted (a prepare state never expires by itself) -/
def tRecancelOldScope : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  w.setNode B fun x => { x with reachable := false }
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B]) []    -- store: cancelled; the delayed cancel never arrives
  let d1 ← w.decision (iname 0 2 1)
  w.bumpGen
  w.setNode B fun x => { x with reachable := true }
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B]) []
  let nMid ← w.node B                                      -- still preparing under gen 1
  let g1 ← gate (w.ctx 7) 0 B "uid" 6                      -- the re-cancel (original scope)
  let n2 ← w.node B
  let cl ← lastSent w B "cancel"
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  let n3 ← w.node B
  return d1 == some .cancelled && nMid.state == "preparing" && isHold g1 && n2.state == "following"
    && cl == some (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
    && n3.state == "preparing" && n3.intent == 202

/-- review (ackedFor): the COMPLETE incarnation (pod UID, boot id, copy id) must be the one that
    acknowledged; a same-name pod recreated with only the UID changed is not; an unknown part is not;
    with the master unreadable altogether the durable ACK stands -/
def tAckedUid : IO Bool := do
  let w ← World.new [A, B]
  let r ← ensurePartition (w.ctx 7) 0 (view1 A [B])
  match r with
  | none => return false
  | some m =>
    let same ← ackedFor (w.ctx 7) 0 m
    let uid2 ← ackedFor (w.ctx 7 0 fun _ => pure (some "uid2")) 0 m
    let unk ← ackedFor (w.ctx 7 0 fun _ => pure none) 0 m
    w.setNode A fun x => { x with boot := "b2" }
    let boot2 ← ackedFor (w.ctx 7) 0 m
    w.setNode A fun x => { x with boot := "b1", reachable := false }
    let gone ← ackedFor (w.ctx 7 0 fun _ => pure none) 0 m
    return same && !uid2 && !unk && !boot2 && gone

def checks : IO (List (String × Bool)) := do
  return [
    ("driver: steady state — record, floor on the successor, membership confirmed by the master, idempotent", ← tSteady),
    ("driver: C' failover — no commit message before the successor's promise end (after the old master's last deadline); then term + 1 and the new master solo", ← tFailover),
    ("driver: an unreadable successor never commits; the cancel the successor missed is sent again before a new attempt", ← tUnknownAndRecancel),
    ("driver: operator restart — the old pending intent is cancelled by the new leader (clocks are not compared) and re-made", ← tOperatorRestart),
    ("driver: the membership is frozen while an intent is open; a master change without a committed intent is refused", ← tFrozen),
    ("driver: no promotion without the master's confirmation, a candidate in the membership, and a record", ← tGatePreconditions),
    ("driver: an intent nobody asked about in this pass is abandoned (store, successor, membership unfrozen); a committed one is left alone", ← tAbandon),
    ("driver: a master that did not confirm the exact membership (delivery dropped) leaves the successor not promotable; after the delivery recovers the switch happens", ← tMembersDropped),
    ("driver: a transient absence / ineligibility removes no member (no solo); only an authoritative removal does", ← tTransient),
    ("driver: a delayed command of another term / generation / copy changes nothing; an old cancel releases nothing", ← tWireScope),
    ("driver: a restarted master is acknowledged anew (its incarnation is bound); no promotion before", ← tMasterRestart),
    ("driver: a pending prepare cancelled after a generation change is cancelled in its original scope; a new prepare is then accepted", ← tCancelOldScope),
    ("driver: the delayed cancel is sent again in the original scope (not the current generation); a new prepare is then accepted", ← tRecancelOldScope),
    ("driver: the master's ACK needs the complete incarnation — a pod recreated with only the UID changed (or an unknown part) is not acknowledged", ← tAckedUid),
    ("driver: a committed intent is terminal — the leader's cancel is refused, the successor stays committed", ← tTerminal) ]

end FlareOperator.WriteAuthorityDriverChecks
