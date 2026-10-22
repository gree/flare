/-
  WriteAuthorityDriver.lean — the IO of the C' wiring (docs §13), OFF unless the
  operator has an explicit, consistent Config (WriteAuthority.Config). It
    * keeps one authoritative membership record per partition in a ConfigMap
      (resourceVersion CAS, never a blind overwrite),
    * pushes the membership / floors to the nodes (`authority ...` over the
      pod's own flared port, like `fence`),
    * drives one promotion through the intent (terminal CAS) — the gate that the
      commit point of the reconcile pass asks.
  Each call does bounded work and never blocks a pass: a step that cannot be
  completed returns `hold` and the next pass continues from the stores.
-/
import FlareOperator.StateMachine.WriteAuthority
import FlareOperator.StateMachine.PromotionIntentStore
import FlareOperator.StateMachine.PromotionIntentKube
import FlareOperator.K8s.Bridge

namespace FlareOperator.WriteAuthorityDriver

open FlareOperator.WriteAuthority
open FlareOperator.PromotionIntentStore
open FlareOperator.PromotionIntentKube
open FlareOperator.PromotionIntent
open FlareOperator.PromotionBinding

structure Ctx where
  cfg : Config
  cr : String
  ns : String
  /-- the operator leader's fencing token (the leadership generation) -/
  token : Nat
  /-- the clock owner's name for intent deadlines (operator identity) -/
  node : String

def Ctx.clock (c : Ctx) : ClockId := { node := c.node, boot := toString c.token }

def podOf (key : String) : String :=
  match key.splitOn "." with
  | p :: _ => p
  | [] => key

def membersName (cr : String) (p : Nat) : String := s!"{cr}-authority-p{p}"
def intentName (cr : String) (p termNext attempt : Nat) : String :=
  s!"{cr}-promotion-intent-p{p}-t{termNext}-i{attempt}"

/-! ## Nodes -/

def ask (ctx : Ctx) (key cmd : String) : IO (Option String) := do
  match ← FlareOperator.K8s.Bridge.queryPodStats (podOf key) ctx.ns cmd with
  | .ok out => pure (some out)
  | .error _ => pure none

def statusOf (ctx : Ctx) (key : String) (p : Nat) : IO (Option Status) := do
  pure ((← ask ctx key (cmdStatus p)).bind Status.parse)

/-! ## The membership record -/

def readRec (c : Client) : IO (Except String (Option (Members × String))) := do
  match ← c.get with
  | .error e => pure (.error e)
  | .notFound => pure (.ok none)
  | .found v rv =>
    match Members.decode v with
    | some m => pure (.ok (some (m, rv)))
    | none => pure (.error "the authority record is malformed (never read as absent)")

/-- Create (no record yet) or replace at the read resourceVersion. A conflict or an
    unconfirmed reply is `false`: the next pass reads again and decides again. -/
def writeRec (c : Client) (rv : Option String) (m : Members) : IO Bool := do
  match rv with
  | none =>
    match ← c.create m.encode with
    | .ok _ => pure true
    | _ => pure false
  | some v =>
    match ← c.replace v m.encode with
    | .ok _ => pure true
    | _ => pure false

def recClient (ctx : Ctx) (p : Nat) : IO Client :=
  mkClient kubectlRunner ctx.ns (membersName ctx.cr p) [("app.kubernetes.io/managed-by", "flare-operator")]

/-! ## The intents of one partition and term -/

structure Attempt where
  n : Nat
  intent : Intent

partial def scanFrom (ctx : Ctx) (p termNext n : Nat) (acc : List Attempt) : IO (Except String (List Attempt)) := do
  if n > 16 then return .error "too many promotion attempts for one term (manual)"
  let c ← mkClient kubectlRunner ctx.ns (intentName ctx.cr p termNext n) [("app.kubernetes.io/managed-by", "flare-operator")]
  match ← readIntent c with
  | .settled i => scanFrom ctx p termNext (n + 1) (acc ++ [{ n, intent := i }])
  | .absent => pure (.ok acc)
  | _ => pure (.error "a promotion intent record is unreadable or broken")

def scanAttempts (ctx : Ctx) (p termNext : Nat) : IO (Except String (List Attempt)) :=
  scanFrom ctx p termNext 1 []

/-- Finished or not: pending, or committed while the old master is still the map's master. -/
def frozenBy (atts : List Attempt) : Bool :=
  atts.any fun a => a.intent.decision == .pending || a.intent.decision == .committed

def committedFor (atts : List Attempt) (master : String) : Option String :=
  if atts.any fun a => a.intent.decision == .committed && a.intent.successor == master then some master else none

/-! ## Keeping the nodes at the record -/

def pushFloors (ctx : Ctx) (p : Nat) (m : Members) : IO Unit := do
  for k in m.successors do
    match ← statusOf ctx k p with
    | some s =>
      if !s.floorIs m then discard <| ask ctx k (cmdFloor p m)
    | none => pure ()

/-- The master holds exactly this membership: push, and read it back. -/
def pushMaster (ctx : Ctx) (p : Nat) (m : Members) : IO Bool := do
  match ← statusOf ctx m.master p with
  | none => pure false
  | some s =>
    if s.holds m then pure true
    else
      discard <| ask ctx m.master (cmdMembers p m ctx.cfg)
      match ← statusOf ctx m.master p with
      | some s2 => pure (s2.holds m)
      | none => pure false

/-- One pass for one partition: decide the record, persist it, push it. Returns the
    record in force (or none when the store could not be read: nothing is pushed). -/
def ensurePartition (ctx : Ctx) (p : Nat) (v : View) : IO (Option Members) := do
  let c ← recClient ctx p
  match ← readRec c with
  | .error e =>
    IO.eprintln s!"[flare-operator] write authority P{p}: {e}; nothing changed this pass"
    pure none
  | .ok cur =>
    let old := cur.map (·.1)
    let termNext := (old.map (·.term)).getD 0 + 1
    let atts ← match old with
      | some _ => scanAttempts ctx p termNext
      | none => pure (.ok [])
    match atts with
    | .error e =>
      IO.eprintln s!"[flare-operator] write authority P{p}: {e}; the record is held"
      pure old
    | .ok as =>
      let master := v.master.getD ""
      let frozen := frozenBy as && (old.map (·.master)) == v.master
      let want := Members.next old v frozen (committedFor as master)
      let m ← match want with
        | none => pure none
        | some w =>
          if some w == old then pure (some w)
          else if ← writeRec c (cur.map (·.2)) w then pure (some w)
          else pure old
      match m with
      | none => pure none
      | some rec =>
        pushFloors ctx p rec
        let okM ← pushMaster ctx p rec
        if okM && !rec.acked then
          -- confirm: the master applied exactly this record (CAS'd)
          let c2 ← recClient ctx p
          match ← readRec c2 with
          | .ok (some (r2, rv2)) =>
            if r2 == rec then
              let ok2 ← writeRec c2 (some rv2) { rec with acked := true }
              pure (some (if ok2 then { rec with acked := true } else rec))
            else pure (some r2)
          | _ => pure (some rec)
        else pure (some rec)

/-! ## The promotion gate -/

inductive GateResult where
  | proceed
  | hold (why : String)
  deriving Repr, BEq

def nowAt (ctx : Ctx) : IO At := do
  pure { clock := ctx.clock, t := ← IO.monoMsNow }

def refOf (ctx : Ctx) (p : Nat) (m : Members) (n : Nat) (key uid boot : String) : Ref :=
  { scope := { cluster := ctx.cr, partition := p, generation := m.gen }, id := n, successor := key,
    binding := { podUid := uid, bootId := boot, copyId := "c" } }

def membershipOf (ctx : Ctx) (p : Nat) (m : Members) : Membership :=
  { scope := { cluster := ctx.cr, partition := p, generation := m.gen }, members := m.successors }

def replicaOf (s : Status) : Replica :=
  { state := s.state, intent := s.intent, remainingMs := s.remainingMs, promotable := s.promotable }

/-- The newest attempt for this exact pod incarnation of the candidate. -/
def newestFor (as : List Attempt) (key uid boot : String) : Option Attempt :=
  (as.filter fun a => a.intent.successor == key && a.intent.binding.podUid == uid && a.intent.binding.bootId == boot).getLast?

def viewOf (a : Option Attempt) (now : At) : IntentView :=
  match a with
  | none => .none
  | some x =>
    match x.intent.decision with
    | .committed => .committed
    | .cancelled => .cancelled
    | .pending =>
      .pending x.intent.oldUntil.isSome (match now.reached? x.intent.deadline with | some false => false | _ => true)

/-- Make the record carry this leader's token (a stale leader holds). -/
def ensureFence (c : Client) (token : Nat) (i : Intent) : IO Bool := do
  if i.fence == token then pure true
  else if i.fence < token then
    match ← adopt c token with
    | .done _ => pure true
    | .settled _ => pure true
    | _ => pure false
  else pure false

def doCreate (ctx : Ctx) (p : Nat) (m : Members) (as : List Attempt) (key uid boot : String) : IO Bool := do
  let n := (as.map (·.n)).foldl max 0 + 1
  let now ← nowAt ctx
  let deadline : At := { now with t := now.t + ctx.cfg.prepareTimeoutMs }
  let c ← mkClient kubectlRunner ctx.ns (intentName ctx.cr p (m.term + 1) n) [("app.kubernetes.io/managed-by", "flare-operator")]
  match ← createIntent c (Intent.prepare (refOf ctx p m n key uid boot) ctx.token deadline) with
  | .done _ => pure true
  | .settled _ => pure true
  | _ => pure false

def doPrepare (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) (key uid boot : String) : IO Bool := do
  match (← ask ctx key (cmdPrepare p a.n (m.term + 1))).bind Status.parse with
  | none => pure false
  | some s =>
    if s.state != "preparing" || s.intent != a.n then pure false
    else
      let c ← mkClient kubectlRunner ctx.ns (intentName ctx.cr p (m.term + 1) a.n) []
      if !(← ensureFence c ctx.token a.intent) then pure false
      else
        let oldUntil : At := { clock := { node := key, boot }, t := s.remainingMs }
        match ← markPrepared c (refOf ctx p m a.n key uid boot) ctx.token oldUntil with
        | .done _ => pure true
        | .settled _ => pure true
        | .refused _ _ => pure true
        | _ => pure false

def doCancel (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) (key uid boot : String) : IO Unit := do
  let c ← mkClient kubectlRunner ctx.ns (intentName ctx.cr p (m.term + 1) a.n) []
  if (← ensureFence c ctx.token a.intent) then
    match ← cancelIntent c (refOf ctx p m a.n key uid boot) (.leader ctx.token) (← nowAt ctx) with
    | .done _ => discard <| ask ctx key (cmdCancel p a.n)
    | .settled _ => discard <| ask ctx key (cmdCancel p a.n)
    | _ => pure ()

def doCommit (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) (key uid boot : String) : IO Bool := do
  let c ← mkClient kubectlRunner ctx.ns (intentName ctx.cr p (m.term + 1) a.n) []
  if !(← ensureFence c ctx.token a.intent) then pure false
  else
    match ← commitIntent c (refOf ctx p m a.n key uid boot) (.leader ctx.token) (membershipOf ctx p m) (← nowAt ctx) with
    | .done _ => pure true
    | .settled _ => pure true
    | _ => pure false

/-- One promotion of `key` (a slave of partition `p`, pod `uid` / restart count `boot`):
    each call takes the next steps the stores and the successor allow (bounded). -/
partial def gate (ctx : Ctx) (p : Nat) (key uid boot : String) (fuel : Nat) : IO GateResult := do
  if fuel == 0 then return .hold "the promotion intent is still being driven (next pass)"
  let c ← recClient ctx p
  match ← readRec c with
  | .error e => return .hold s!"the membership record: {e}"
  | .ok none => return .hold "no membership record yet"
  | .ok (some (m, _)) =>
    match ← scanAttempts ctx p (m.term + 1) with
    | .error e => return .hold e
    | .ok as =>
      let now ← nowAt ctx
      let a := newestFor as key uid boot
      let rv := (← statusOf ctx key p).map replicaOf
      let id := (a.map (·.n)).getD 0
      match gateDecide (m.successors.contains key) m.acked (viewOf a now) rv id with
      | .proceed => return .proceed
      | .abort why => return .hold s!"abort: {why}"
      | .wait why => return .hold s!"wait: {why}"
      | .createIntent =>
        if ← doCreate ctx p m as key uid boot then gate ctx p key uid boot (fuel - 1)
        else return .hold "the intent could not be created"
      | .sendPrepare =>
        match a with
        | none => return .hold "no intent"
        | some x =>
          if ← doPrepare ctx p m x key uid boot then gate ctx p key uid boot (fuel - 1)
          else return .hold "the successor did not acknowledge the prepare"
      | .cancelCas why =>
        match a with
        | none => return .hold "no intent"
        | some x =>
          doCancel ctx p m x key uid boot
          return .hold s!"cancelled: {why}"
      | .commitCas =>
        match a with
        | none => return .hold "no intent"
        | some x =>
          if ← doCommit ctx p m x key uid boot then
            discard <| ask ctx key (cmdCommit p x.n)
            gate ctx p key uid boot (fuel - 1)
          else return .hold "the commit CAS did not apply"
      | .sendCommit =>
        discard <| ask ctx key (cmdCommit p id)
        gate ctx p key uid boot (fuel - 1)

end FlareOperator.WriteAuthorityDriver
