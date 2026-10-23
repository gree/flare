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
  /-- the first-build allowance held: (boot, copy) -/
  first : Option (String × String) := none
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
  | ["authority", "first", _, b, c] =>
    if b != n.boot || c != n.copy then (n, some "the first-build proof is for another incarnation or copy of this node")
    else ({ n with first := some (b, c) }, none)
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
  let nMid ← w.node B                                      -- the pass re-sent the cancel (index: unconfirmed)
  let cl ← lastSent w B "cancel"
  let g1 ← gate (w.ctx 7) 0 B "uid" 6                      -- a fresh attempt under gen 2
  let n2 ← w.node B
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  let n3 ← w.node B
  return d1 == some .cancelled && nMid.state == "following" && isHold g1 && n2.state == "preparing" && n2.intent == 202
    && cl == some (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
    && n3.state == "preparing" && n3.intent == 202

/-- review (same-term generation change): the generation moves while the candidate stays WANTED. The
    stale pending attempt (gen 1) is cancelled on ITS OWN resource and in ITS OWN scope — by the gate and
    by the pass — then a fresh attempt for generation 2 is prepared and accepted. A stale COMMITTED
    attempt is never re-used: the gate holds and nothing new is started. -/
def tGenChangeWanted : IO Bool := do
  let w ← World.new [A, B]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B]) [B]
  w.setClock 1000
  w.round A [B]
  let _ ← gate (w.ctx 7) 0 B "uid" 6                      -- prepared: id 201, term_next 2, gen 1
  let n1 ← w.node B
  w.bumpGen
  let g1 ← gate (w.ctx 7) 0 B "uid" 6                     -- B is wanted, but the attempt is of gen 1
  let n2 ← w.node B
  let cl ← lastSent w B "cancel"
  let d1 ← w.decision (iname 0 2 1)
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B]) [B]   -- the master acknowledges generation 2
  w.round A [B]
  let g2 ← gate (w.ctx 7) 0 B "uid" 6                     -- a fresh attempt for generation 2
  let n3 ← w.node B
  let d2 ← w.decision (iname 0 2 2)
  let d1' ← w.decision (iname 0 2 1)
  -- the same through the pass alone (ensurePartition): B stays wanted
  let w2 ← World.new [A, B]
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 A [B]) [B]
  w2.setClock 1000
  w2.round A [B]
  let _ ← gate (w2.ctx 7) 0 B "uid" 6
  w2.bumpGen
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 A [B]) [B]
  let m1 ← w2.node B
  let e1 ← w2.decision (iname 0 2 1)
  -- a committed attempt of an older generation is fail-closed
  let w3 ← World.new [A, B]
  let _ ← ensurePartition (w3.ctx 7) 0 (view1 A [B]) [B]
  w3.setClock 1000
  w3.round A [B]
  let _ ← gate (w3.ctx 7) 0 B "uid" 6
  w3.setClock 12000
  let gc ← gate (w3.ctx 7) 0 B "uid" 6
  w3.bumpGen
  let _ ← ensurePartition (w3.ctx 7) 0 (view1 A [B]) [B]
  let gh ← gate (w3.ctx 7) 0 B "uid" 6
  let q ← w3.node B
  return n1.state == "preparing" && n1.pGen == 1 && isHold g1 && n2.state == "following" && d1 == some .cancelled
    && cl == some (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
    && isHold g2 && n3.state == "preparing" && n3.intent == 202 && n3.pGen == 2 && d2 == some .pending && d1' == some .cancelled
    && m1.state == "following" && e1 == some .cancelled
    && gc == .proceed && isHold gh && q.state == "committed" && (← w3.decision (iname 0 2 2)) == none

/-- review (cross-term pending): term 2 is pending on B, then C is promoted for term 3. The next pass
    reclaims B's old intent (its own resource, its own scope: term_next 2), B promises again and accepts a
    new prepare; a cancel of the old term sent later touches nothing of the new prepare. -/
def tCrossTermPending : IO Bool := do
  let w ← World.new [A, B, C]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  w.setClock 1000
  w.round A [B, C]
  let _ ← gate (w.ctx 7) 0 B "uid" 6                      -- term 2 pending on B: id 201, term_next 2
  let n1 ← w.node B
  w.setNode A fun x => { x with reachable := false }
  -- C was promoted for term 2 (another route): the record moves to term 2, master C
  let c ← recClient (w.ctx 7) 0
  match ← readRec c with
  | .ok (some (m, rv)) =>
    discard <| writeRec c (some rv) { m with term := 2, gen := 2, master := C, successors := [A, B], acked := false, ackBind := none }
  | _ => pure ()
  let r ← ensurePartition (w.ctx 7) 0 (view1 C [A, B]) []
  let n2 ← w.node B
  let cl ← lastSent w B "cancel"
  let d1 ← w.decision (iname 0 2 1)
  w.setClock 2000
  w.round C [B]                                           -- B gives promises to the new master again
  let n3 ← w.node B
  let gm ← gate (w.ctx 7) 0 B "uid" 6                     -- term 3 attempt: id 301, term_next 3
  let n4 ← w.node B
  let old ← w.ask B (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
  let n5 ← w.node B
  return n1.state == "preparing" && n1.pTerm == 2 && (match r with | some m => m.term == 2 && m.master == C | none => false)
    && n2.state == "following" && d1 == some .cancelled
    && cl == some (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
    && n3.promiseEnd > 0 && isHold gm && n4.state == "preparing" && n4.intent == 301 && n4.pTerm == 3
    && (match old with | some t => t.startsWith "SERVER_ERROR" | none => false) && n5.state == "preparing" && n5.intent == 301

/-- two failovers in a row: A is cut off and B is promoted (term 2), then B is cut off and C is promoted
    (term 3). Each commit waits for the successor's own promise end; the second failover starts from the
    record the first one left; the last master is solo. -/
def tTwoFailovers : IO Bool := do
  let w ← World.new [A, B, C]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  w.setClock 1000
  w.round A [B, C]
  w.setNode A fun x => { x with reachable := false }
  let _ ← gate (w.ctx 7) 0 B "uid" 6                      -- B prepared (promise to 12000)
  w.setClock 11999
  let g1 ← gate (w.ctx 7) 0 B "uid" 6
  w.setClock 12000
  let g2 ← gate (w.ctx 7) 0 B "uid" 6
  let r1 ← ensurePartition (w.ctx 7) 0 (view1 B [C])      -- B is the master of term 2
  let nB ← w.node B
  w.round B [C]                                           -- B's last round: its grant runs on, C promised to 23000
  w.setNode B fun x => { x with reachable := false }
  let g3 ← gate (w.ctx 7) 0 C "uid" 6                     -- C prepared for term 3
  let nC1 ← w.node C
  w.setClock 22999
  let g4 ← gate (w.ctx 7) 0 C "uid" 6
  w.setClock 23000
  let g5 ← gate (w.ctx 7) 0 C "uid" 6
  let r2 ← ensurePartition (w.ctx 7) 0 (view1 C [])       -- C is the master of term 3
  let nC2 ← w.node C
  return isHold g1 && g2 == .proceed && (match r1 with | some m => m.term == 2 && m.master == B && m.successors == [C] | none => false)
    && nB.mode == "replicated" && nB.memTerm == 2
    && isHold g3 && nC1.state == "preparing" && nC1.intent == 301 && nC1.pTerm == 3
    && isHold g4 && g5 == .proceed && (← w.decision (iname 0 3 1)) == some .committed
    && (match r2 with | some m => m.term == 3 && m.master == C && m.successors.isEmpty | none => false)
    && nC2.mode == "solo" && nC2.grant && nC2.memTerm == 3

/-- the index entries now (term, number) -/
def indexNow (w : World) : IO (List (Nat × Nat)) := do
  match ← readIndex (← w.clientFor (indexName "c" 0)) with
  | .ok (some (l, _)) => pure l
  | _ => pure [(999, 999)]

def moveRecord (w : World) (term : Nat) (master : String) (succs : List String) : IO Unit := do
  let c ← recClient (w.ctx 7) 0
  match ← readRec c with
  | .ok (some (m, rv)) =>
    discard <| writeRec c (some rv) { m with term, gen := 2, master, successors := succs, acked := false, ackBind := none }
  | _ => pure ()

/-- review #6: B's pending prepare of term 2 is reclaimed after the record advanced to term 6 (5 terms
    later, beyond any fixed window) and the operator restarted (a new leader token): its own resource is
    cancelled, its own scope (201/2/1) goes on the wire, the index entry is dropped afterwards. -/
def tFarTermReclaim : IO Bool := do
  let w ← World.new [A, B, C]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  w.setClock 1000
  w.round A [B, C]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  let i1 ← indexNow w
  let n1 ← w.node B
  w.setNode A fun x => { x with reachable := false }
  moveRecord w 6 C [A, B]
  let r ← ensurePartition (w.ctx 8) 0 (view1 C [A, B]) []   -- operator restarted: token 8
  let n2 ← w.node B
  let cl ← lastSent w B "cancel"
  let i2 ← indexNow w
  return i1 == [(2, 1)] && n1.state == "preparing" && n1.pTerm == 2 && r.isSome
    && (← w.decision (iname 0 2 1)) == some .cancelled && n2.state == "following"
    && cl == some (cmdCancel 0 { id := 201, termNext := 2, gen := 1, boot := "b1", copy := "c1" })
    && i2 == []

/-- review #6: the cancel is not confirmed (the node is unreachable) — the entry stays in the index; once
    the node answers it still prepares that scope, the cancel is sent again, and only a later pass that
    reads the node released drops the entry. -/
def tIndexKeptUntilConfirmed : IO Bool := do
  let w ← World.new [A, B, C]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  w.setClock 1000
  w.round A [B, C]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  w.setNode A fun x => { x with reachable := false }
  moveRecord w 7 C [A, B]
  w.setNode B fun x => { x with reachable := false }
  let _ ← ensurePartition (w.ctx 8) 0 (view1 C [A, B]) []
  let i1 ← indexNow w
  let d1 ← w.decision (iname 0 2 1)
  w.setNode B fun x => { x with reachable := true }
  let _ ← ensurePartition (w.ctx 9) 0 (view1 C [A, B]) []   -- another restart; the cancel goes out again
  let n2 ← w.node B
  let i2 ← indexNow w
  let _ ← ensurePartition (w.ctx 9) 0 (view1 C [A, B]) []
  let i3 ← indexNow w
  return i1 == [(2, 1)] && d1 == some .cancelled && n2.state == "following" && i2 == [(2, 1)] && i3 == []

/-- review #6: crash between the index add and the intent create — the index names an intent that does not
    exist; scanning is fine, the next create re-uses the number (no duplicate entry), and the index lists
    exactly the existing intent. An index that did not exist yet is seeded from the intents of all terms. -/
def tIndexCrashAndSeed : IO Bool := do
  let w ← World.new [A, B, C]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  w.setClock 1000
  w.round A [B, C]
  let a1 ← addIndex (w.ctx 7) 0 2 2 1                        -- crash before the intent is created
  let s ← scanAll (w.ctx 7) 0 2
  let g ← gate (w.ctx 7) 0 B "uid" 6
  let i1 ← indexNow w
  -- seed: a legacy intent of term 3 exists without any index
  let w2 ← World.new [A, B, C]
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 A [B, C]) [B]
  let cl ← w2.clientFor (intentName "c" 0 3 1)
  discard <| createIntent cl (Intent.prepare { scope := { cluster := "c", partition := 0, generation := 1 }, id := 1, successor := B, binding := { podUid := "uid", bootId := "b1", copyId := "c1" } } 7 { clock := { node := "operator", boot := "7" }, t := 5000 })
  let s2 ← scanAll (w2.ctx 7) 0 9
  return a1 && (match s with | .ok l => l.isEmpty | .error _ => false) && isHold g && i1 == [(2, 1)]
    && (← w.decision (iname 0 2 1)) == some .pending
    && (match s2 with | .ok l => l.length == 1 && (l.head?.map (·.termNext)) == some 3 | .error _ => false)

/-- pruneIndex as the pass runs it: the record in force and every attempt, read now -/
def pruneNow (_w : World) (ctx : Ctx) : IO Unit := do
  match ← readRec (← recClient ctx 0) with
  | .ok (some (m, _)) =>
    match ← scanAll ctx 0 (m.term + 1) with
    | .ok as => pruneIndex ctx 0 m as
    | .error _ => pure ()
  | _ => pure ()

/-- B's attempt (term 2, number 1) driven to COMMITTED; the record is still term 1 / master A -/
def committedB (w : World) : IO Unit := do
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  w.setClock 1000
  w.round A [B, C]
  let _ ← gate (w.ctx 7) 0 B "uid" 6
  w.setClock 12000
  let _ ← gate (w.ctx 7) 0 B "uid" 6

/-- review f6 #1: a COMMITTED attempt is dropped from the index only when it is proven applied (the
    record names its successor as master at its term, and it is the only such commit). A commit whose
    promotion never reached the record (the term advanced by another path, master C) stays; an earlier
    term's commit stays; the applied one goes. -/
def tCommittedNotApplied : IO Bool := do
  -- not applied: the record is at term 2 but its master is C, not B
  let w ← World.new [A, B, C]
  committedB w
  let d ← w.decision (iname 0 2 1)
  moveRecord w 2 C [A, B]
  pruneNow w (w.ctx 7)
  let i1 ← indexNow w
  -- the record moved on to term 5 with master B: an earlier term's commit is not proven
  moveRecord w 5 B [A, C]
  pruneNow w (w.ctx 7)
  let i2 ← indexNow w
  -- applied: term 2, master B (the normal promotion)
  let w2 ← World.new [A, B, C]
  committedB w2
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 B [])      -- the record is written (term 2, master B)
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 B [])      -- the next pass proves it applied and prunes
  let i3 ← indexNow w2
  return d == some .committed && i1 == [(2, 1)] && i2 == [(2, 1)] && i3 == []

/-- review f6 #2: a concurrent writer (the current leader adds an entry between the pruner's read and its
    CAS) — the pruner's replace conflicts, it re-reads, and the new entry survives while its own removal
    still happens; a STALE leader's pass (older token than the intents' fence) touches nothing. -/
def tIndexConcurrent : IO Bool := do
  let setup : IO World := do
    let w ← World.new [A, B, C]
    let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
    w.setClock 1000
    w.round A [B, C]
    let _ ← gate (w.ctx 7) 0 B "uid" 6
    match (← scanAll (w.ctx 7) 0 2) with
    | .ok [a] => discard <| doCancelAttempt (w.ctx 7) 0 a
    | _ => pure ()
    pure w
  -- (1) the leader adds (2,2) in the middle of the pruner's read-modify-write
  let w ← setup
  let gets ← IO.mkRef 0
  let racing : Ctx := { w.ctx 7 with clientFor := fun name => do
    let c ← w.clientFor name
    if name != indexName "c" 0 then return c
    return { c with get := do
      let r ← c.get
      gets.modify (· + 1)
      -- reads 1 / 2: scanAll (ensure + read); read 3: the pruner's own read-modify-write
      if (← gets.get) == 3 then discard <| addIndex (w.ctx 7) 0 2 2 2
      pure r } }
  pruneNow w racing
  let i1 ← indexNow w
  -- (2) a stale leader (token 5 < fence 7) prunes nothing
  let w2 ← setup
  pruneNow w2 (w2.ctx 5)
  let i2 ← indexNow w2
  return i1 == [(2, 2)] && i2 == [(2, 1)]

/-- review f6 #3: the index limit fails closed — no new attempt, nothing dropped; a seed beyond the
    entry limit or the term bound creates no index. The bound itself is computed from the entry size. -/
def tIndexLimits : IO Bool := do
  let w ← World.new [A, B, C]
  let _ ← ensurePartition (w.ctx 7) 0 (view1 A [B, C]) [B]
  let small : Ctx := { w.ctx 7 with indexMaxEntries := 2 }
  let a1 ← addIndex small 0 2 2 5
  let a2 ← addIndex small 0 2 2 6
  let a3 ← addIndex small 0 2 2 7                 -- full: refused
  let i ← indexNow w
  let a4 ← addIndex small 0 2 2 6                 -- already listed: fine
  w.setClock 1000
  w.round A [B, C]
  let g ← gate small 0 B "uid" 6                  -- no room for a new attempt: held, no intent made
  let d ← w.decision (iname 0 2 1)
  -- seeding refused: a seed of 2 legacy intents against a limit of 1; and a term beyond the bound
  let w2 ← World.new [A, B, C]
  let _ ← ensurePartition (w2.ctx 7) 0 (view1 A [B, C]) [B]
  for n in [1:3] do
    let cl ← w2.clientFor (intentName "c" 0 2 n)
    discard <| createIntent cl (Intent.prepare { scope := { cluster := "c", partition := 0, generation := 1 }, id := n, successor := B, binding := { podUid := "uid", bootId := "b1", copyId := "c1" } } 7 { clock := { node := "operator", boot := "7" }, t := 5000 })
  let e1 ← ensureIndex { w2.ctx 7 with indexMaxEntries := 1 } 0 2
  let e2 ← ensureIndex { w2.ctx 7 with seedMaxTerms := 1 } 0 2
  let none1 ← readIndex (← w2.clientFor (indexName "c" 0))
  let e3 ← ensureIndex (w2.ctx 7) 0 2
  return a1 && a2 && !a3 && i == [(2, 5), (2, 6)] && a4 && isHold g && d == none
    && !e1 && !e2 && (match none1 with | .ok none => true | _ => false) && e3
    && maxIndexEntries * maxEntryBytes + 16 ≤ maxIndexValueBytes && maxIndexValueBytes < 1048576
    && (encodeIndex ((List.range maxIndexEntries).map fun _ => (18446744073709551615, 18446744073709551615))).utf8ByteSize ≤ maxIndexValueBytes

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

/-- a master the registration made master (no pass promoted it): the first-build proof is sent BEFORE its
    record exists, with the node's REAL boot / copy; never for an existing copy, another node holding the
    partition, a record that exists, or a store that was not a first build -/
def tRegisteredFirstBuild : IO Bool := do
  let bC : AuthoritativeHistory.Binding := ⟨"uid", "b1", "c1"⟩
  let h : AuthoritativeHistory.Hist := ⟨"M", "1:e"⟩
  let fresh : AuthoritativeHistory.Store := { clusterUid := "cu", origin := "first-build" }
  let recorded : AuthoritativeHistory.Store :=
    { fresh with parts := [(0, .known { gen := 1, hist := h, holder := A, binding := bC, since := "t", reason := "first-build" } none)] }
  -- proven (nothing recorded yet): the node holds the allowance for its real incarnation; the record may be made
  let w1 ← World.new [A]
  let r1 ← registeredFirstBuild (w1.ctx 7) 0 A (some fresh) false
  let n1 ← w1.node A
  -- proven (recorded as this node's first build, the copy it reports now)
  let w2 ← World.new [A]
  let r2 ← registeredFirstBuild (w2.ctx 7) 0 A (some recorded) false
  let n2 ← w2.node A
  -- not proven: another node holds the partition / not a first-build store / another copy / no pod identity
  let w3 ← World.new [A]
  let r3 ← registeredFirstBuild (w3.ctx 7) 0 A (some fresh) true
  let r3b ← registeredFirstBuild (w3.ctx 7) 0 A (some { fresh with origin := "" }) false
  w3.setNode A fun x => { x with copy := "c-other" }
  let r3c ← registeredFirstBuild (w3.ctx 7) 0 A (some recorded) false
  let n3 ← w3.node A
  let r3d ← registeredFirstBuild (w3.ctx 7 0 fun _ => pure none) 0 A (some fresh) false
  -- the record exists (the master was acknowledged before): an existing copy, never a first build
  let w4 ← World.new [A]
  let _ ← ensurePartition (w4.ctx 7) 0 (view1 A [])
  let r4 ← registeredFirstBuild (w4.ctx 7) 0 A (some fresh) false
  let n4 ← w4.node A
  -- the node does not accept it (unreachable): the record must not be made this pass
  let w5 ← World.new [A]
  w5.setNode A fun x => { x with reachable := false }
  let r5 ← registeredFirstBuild (w5.ctx 7) 0 A (some fresh) false
  -- 2 partitions, a fresh cluster (failover-wa, f11): P0's master A was recorded as its first build while the map
  -- still had one partition, then P0's slave B and P1's master C registered; the first pass with both partitions
  -- must prove EVERY partition's first build (P0 with its slave present, P1 not yet recorded)
  let h2 : AuthoritativeHistory.Hist := ⟨"M", "1:e"⟩
  let bumpP0 : AuthoritativeHistory.Store :=
    { fresh with parts := [(0, .known { gen := 1, hist := h2, holder := A, binding := bC, since := "t", reason := "first-build" } none)] }
  let w6 ← World.new [A, B, C]
  let q0 ← registeredFirstBuild (w6.ctx 7) 0 A (some bumpP0) false true
  let q1 ← registeredFirstBuild (w6.ctx 7) 1 C (some bumpP0) false false
  let n6a ← w6.node A
  let n6c ← w6.node C
  -- a slave beside an UNRECORDED partition is an existing copy: no proof
  let w7 ← World.new [A, B]
  let q2 ← registeredFirstBuild (w7.ctx 7) 0 A (some fresh) false true
  let n7 ← w7.node A
  return r1 && n1.first == some ("b1", "c1") && r2 && n2.first == some ("b1", "c1")
    && r3 && r3b && r3c && n3.first == none && !r3d
    && r4 && n4.first == none && !r5
    && q0 && q1 && n6a.first == some ("b1", "c1") && n6c.first.isSome && q2 && n7.first == none

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
    ("driver: a generation change with the candidate still wanted — the stale pending attempt is cancelled on its own resource / scope, a fresh one is prepared; a stale committed one is fail-closed", ← tGenChangeWanted),
    ("driver: a previous term's pending prepare is reclaimed in its own scope after another node is promoted; the node promises and accepts a new prepare", ← tCrossTermPending),
    ("driver: two failovers in a row — each waits for the successor's promise end; the last master is solo", ← tTwoFailovers),
    ("driver: a pending intent is reclaimed 5 terms later after an operator restart (original resource and scope); the index entry is dropped", ← tFarTermReclaim),
    ("driver: the index entry stays until the cancel is confirmed on the node; the cancel is sent again", ← tIndexKeptUntilConfirmed),
    ("driver: index consistent after a crash between add and create; seeded from all terms when absent", ← tIndexCrashAndSeed),
    ("driver: a committed attempt leaves the index only when proven applied to the record (not applied / earlier term: kept)", ← tCommittedNotApplied),
    ("driver: a concurrent index writer is never overwritten (CAS conflict re-reads); a stale leader's pass prunes nothing", ← tIndexConcurrent),
    ("driver: the index limit and the seeding bound fail closed (no new attempt, nothing dropped)", ← tIndexLimits),
    ("driver: the master's ACK needs the complete incarnation — a pod recreated with only the UID changed (or an unknown part) is not acknowledged", ← tAckedUid),
    ("driver: a master registered as master gets the first-build proof (real boot / copy) BEFORE its record exists, only with the history's proof; an existing copy / record / another holder / unreadable identity / unreachable node gets none (the record is held when the proof cannot be sent)", ← tRegisteredFirstBuild),
    ("driver: a committed intent is terminal — the leader's cancel is refused, the successor stays committed", ← tTerminal) ]

end FlareOperator.WriteAuthorityDriverChecks
