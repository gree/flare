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
  /-- one `authority ...` line to the flared of the node key; `none` = no (complete) reply -/
  askNode : String → String → IO (Option String)
  /-- the ConfigMap `name` as a CAS client -/
  clientFor : String → IO Client
  /-- this operator's monotonic clock, ms -/
  nowMs : IO Nat
  /-- the pod UID of the node key right now (`none`: unreadable) -/
  podUid : String → IO (Option String)

def Ctx.clock (c : Ctx) : ClockId := { node := c.node, boot := toString c.token }

def podOf (key : String) : String :=
  match key.splitOn "." with
  | p :: _ => p
  | [] => key

/-- The live wiring: kubectl exec into the pod, ConfigMaps through the kubectl client. -/
def Ctx.live (cfg : Config) (cr ns : String) (token : Nat) (node : String) : Ctx :=
  { cfg, cr, ns, token, node,
    askNode := fun key cmd => do
      match ← FlareOperator.K8s.Bridge.queryPodStats (podOf key) ns cmd with
      | .ok out => pure (some out)
      | .error _ => pure none,
    clientFor := fun name => mkClient kubectlRunner ns name [("app.kubernetes.io/managed-by", "flare-operator")],
    nowMs := IO.monoMsNow,
    podUid := fun key => FlareOperator.K8s.Bridge.podUid (podOf key) ns }

def membersName (cr : String) (p : Nat) : String := s!"{cr}-authority-p{p}"
def intentName (cr : String) (p termNext attempt : Nat) : String :=
  s!"{cr}-promotion-intent-p{p}-t{termNext}-i{attempt}"

/-! ## Nodes -/

def ask (ctx : Ctx) (key cmd : String) : IO (Option String) := ctx.askNode key cmd

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
  ctx.clientFor (membersName ctx.cr p)

/-! ## The intents of one partition and term -/

structure Attempt where
  n : Nat
  intent : Intent

partial def scanFrom (ctx : Ctx) (p termNext n : Nat) (acc : List Attempt) : IO (Except String (List Attempt)) := do
  if n > 16 then return .error "too many promotion attempts for one term (manual)"
  let c ← ctx.clientFor (intentName ctx.cr p termNext n)
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

/-- The master holds exactly this membership: push, and read it back. The reading that proves it is
    returned (it names the incarnation and copy that holds the membership). -/
def pushMaster (ctx : Ctx) (p : Nat) (m : Members) : IO (Option Status) := do
  match ← statusOf ctx m.master p with
  | none => pure none
  | some s =>
    if s.holds m then pure (some s)
    else
      discard <| ask ctx m.master (cmdMembers p m ctx.cfg)
      match ← statusOf ctx m.master p with
      | some s2 => pure (if s2.holds m then some s2 else none)
      | none => pure none

/-- The incarnation of the node `key` read now: its pod UID before and after the flared reading
    (the same pod), and the boot id / copy id flared reports. `none` when any part is unreadable or
    the pod changed in between. -/
def bindingNow (ctx : Ctx) (key : String) (p : Nat) : IO (Option (Status × Bind)) := do
  match ← ctx.podUid key with
  | none => pure none
  | some u1 =>
    match ← statusOf ctx key p with
    | none => pure none
    | some s =>
      match ← ctx.podUid key with
      | some u2 => pure (if u1 == u2 then some (s, s.bind u1) else none)
      | none => pure none

/-! ## The promotion gate -/

inductive GateResult where
  | proceed
  | hold (why : String)
  deriving Repr, BEq

def nowAt (ctx : Ctx) : IO At := do
  pure { clock := ctx.clock, t := ← ctx.nowMs }

/-- The id the successor knows an attempt by: unique across terms (an intent message that was
    delayed from an older term can never match a newer one). -/
def wid (m : Members) (n : Nat) : Nat := (m.term + 1) * 100 + n

/-- The intent's binding is the REAL incarnation: pod UID, flared boot id, persistent copy id. -/
def refOf (ctx : Ctx) (p : Nat) (m : Members) (n : Nat) (key : String) (b : Bind) : Ref :=
  { scope := { cluster := ctx.cr, partition := p, generation := m.gen }, id := n, successor := key,
    binding := { podUid := b.uid, bootId := b.boot, copyId := b.copy } }

/-- What goes on the wire for attempt `n`: id, next term, generation, the receiver's boot and copy. -/
def wireOf (m : Members) (n : Nat) (b : Bind) : WireScope :=
  { id := wid m n, termNext := m.term + 1, gen := m.gen, boot := b.boot, copy := b.copy }

/-- The ORIGINAL wire scope of an existing attempt, rebuilt from its intent (generation and receiver
    binding as created) and the term it was scanned under: every message about that attempt (prepare,
    commit, cancel, re-cancel) uses it, never the current membership's generation. -/
def wireOfAttempt (m : Members) (a : Attempt) : WireScope :=
  { id := wid m a.n, termNext := m.term + 1, gen := a.intent.ref.scope.generation,
    boot := a.intent.binding.bootId, copy := a.intent.binding.copyId }

def membershipOf (ctx : Ctx) (p : Nat) (m : Members) : Membership :=
  { scope := { cluster := ctx.cr, partition := p, generation := m.gen }, members := m.successors }

/-- The node holds exactly the scope of attempt `sc`: id, next term, generation, and the incarnation /
    copy it was prepared for (which is also the node's identity now). -/
def replicaOf (s : Status) (sc : WireScope) : Replica :=
  { state := s.state, intent := s.intent, remainingMs := s.remainingMs, promotable := s.promotable,
    scopeOk := s.intent == sc.id && s.promiseTermNext == sc.termNext && s.promiseGen == sc.gen
      && s.promiseBoot == sc.boot && s.promiseCopy == sc.copy && s.idBoot == sc.boot && s.idCopy == sc.copy }

def bindingOfIntent (i : Intent) : Bind :=
  { uid := i.binding.podUid, boot := i.binding.bootId, copy := i.binding.copyId }

/-- The newest attempt for this exact incarnation of the candidate (pod UID, flared boot id, copy id). -/
def newestFor (as : List Attempt) (key : String) (b : Bind) : Option Attempt :=
  (as.filter fun a => a.intent.successor == key && bindingOfIntent a.intent == b).getLast?

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

def doCreate (ctx : Ctx) (p : Nat) (m : Members) (as : List Attempt) (key : String) (b : Bind) : IO Bool := do
  let n := (as.map (·.n)).foldl max 0 + 1
  let now ← nowAt ctx
  let deadline : At := { now with t := now.t + ctx.cfg.prepareTimeoutMs }
  let c ← ctx.clientFor (intentName ctx.cr p (m.term + 1) n)
  match ← createIntent c (Intent.prepare (refOf ctx p m n key b) ctx.token deadline) with
  | .done _ => pure true
  | .settled _ => pure true
  | _ => pure false

def doPrepare (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) (key : String) (b : Bind) : IO Bool := do
  let sc := wireOfAttempt m a
  match (← ask ctx key (cmdPrepare p sc)).bind Status.parse with
  | none => pure false
  | some s =>
    if s.state != "preparing" || !(replicaOf s sc).scopeOk then pure false
    else
      let c ← ctx.clientFor (intentName ctx.cr p (m.term + 1) a.n)
      if !(← ensureFence c ctx.token a.intent) then pure false
      else
        let oldUntil : At := { clock := { node := key, boot := b.boot }, t := s.remainingMs }
        match ← markPrepared c a.intent.ref ctx.token oldUntil with
        | .done _ => pure true
        | .settled _ => pure true
        | .refused _ _ => pure true
        | _ => pure false

/-- Cancel one attempt (the terminal CAS first, then the successor with the attempt's own scope).
    `true` when the store says cancelled. -/
def doCancelAttempt (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) : IO Bool := do
  let c ← ctx.clientFor (intentName ctx.cr p (m.term + 1) a.n)
  let sendCancel : IO Unit := discard <| ask ctx a.intent.successor (cmdCancel p (wireOfAttempt m a))
  if (← ensureFence c ctx.token a.intent) then
    match ← cancelIntent c a.intent.ref (.leader ctx.token) (← nowAt ctx) with
    | .done _ => sendCancel; pure true
    | .settled _ => sendCancel; pure true
    | _ => pure false
  else pure false

def doCancel (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) : IO Unit :=
  discard <| doCancelAttempt ctx p m a

def doCommit (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) : IO Bool := do
  let c ← ctx.clientFor (intentName ctx.cr p (m.term + 1) a.n)
  if !(← ensureFence c ctx.token a.intent) then pure false
  else
    match ← commitIntent c a.intent.ref (.leader ctx.token) (membershipOf ctx p m) (← nowAt ctx) with
    | .done _ => pure true
    | .settled _ => pure true
    | _ => pure false

/-- The membership record is acknowledged by its master, for the exact generation: the record says
    acked and names the incarnation that did. When the master can be read now, it must still be that
    incarnation (and copy) holding exactly this record; when it cannot be read (the failover case: the
    master is gone) the durable acknowledgement stands — a master that lost its state holds no grant. -/
def ackedFor (ctx : Ctx) (p : Nat) (m : Members) : IO Bool := do
  if !m.acked then return false
  match m.ackBind with
  | none => return false
  | some ab =>
    match ← bindingNow ctx m.master p with
    | none =>
      -- unreadable (or the pod changed during the reading): the durable ACK stands only when the
      -- flared itself cannot be read; a readable flared with an unreadable pod UID is Unknown
      match ← statusOf ctx m.master p with
      | none => return true
      | some _ => return false
    | some (s, bnd) => pure (s.holds m && bnd == ab)

/-- One promotion of `key` (a slave of partition `p`, pod `uid`): each call takes the next steps the
    stores and the successor allow (bounded). The attempt is bound to the incarnation read now (pod
    UID, flared boot id, persistent copy id) and every message carries that scope. -/
partial def gate (ctx : Ctx) (p : Nat) (key uid : String) (fuel : Nat) : IO GateResult := do
  if fuel == 0 then return .hold "the promotion intent is still being driven (next pass)"
  let c ← recClient ctx p
  match ← readRec c with
  | .error e => return .hold s!"the membership record: {e}"
  | .ok none => return .hold "no membership record yet"
  | .ok (some (m, _)) =>
    match ← scanAttempts ctx p (m.term + 1) with
    | .error e => return .hold e
    | .ok as =>
      match ← bindingNow ctx key p with
      | none => return .hold "the candidate's pod / flared identity is unreadable"
      | some (st, b) =>
        if b.uid != uid then return .hold "the candidate's pod is not the one the commit point observed"
        -- a pending attempt of ANOTHER incarnation of this candidate (restart, replaced copy) is dead:
        -- cancel it (terminal CAS), then go on with an attempt of the incarnation read now
        let stale := as.filter fun a => a.intent.successor == key && bindingOfIntent a.intent != b && a.intent.decision == .pending
        if let some x := stale.head? then
          discard <| doCancelAttempt ctx p m x
          return .hold "an attempt of another incarnation of the candidate was cancelled; the next pass starts one for this incarnation"
        let now ← nowAt ctx
        let a := newestFor as key b
        let sc := (a.map fun x => wireOfAttempt m x).getD (wireOf m 0 b)
        let rv := some (replicaOf st sc)
        let id := (a.map fun x => wid m x.n).getD 0
        let acked ← ackedFor ctx p m
        match gateDecide (m.successors.contains key) acked (viewOf a now) rv id with
        | .proceed => return .proceed
        | .abort why => return .hold s!"abort: {why}"
        | .wait why => return .hold s!"wait: {why}"
        | .createIntent =>
          if ← doCreate ctx p m as key b then gate ctx p key uid (fuel - 1)
          else return .hold "the intent could not be created"
        | .sendPrepare =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            if ← doPrepare ctx p m x key b then gate ctx p key uid (fuel - 1)
            else return .hold "the successor did not acknowledge the prepare"
        | .cancelCas why =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            doCancel ctx p m x
            return .hold s!"cancelled: {why}"
        | .commitCas =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            if ← doCommit ctx p m x then
              discard <| ask ctx key (cmdCommit p (wireOfAttempt m x))
              gate ctx p key uid (fuel - 1)
            else return .hold "the commit CAS did not apply"
        | .sendCommit =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            discard <| ask ctx key (cmdCommit p (wireOfAttempt m x))
            gate ctx p key uid (fuel - 1)
        | .sendCancel =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            discard <| ask ctx key (cmdCancel p (wireOfAttempt m x))
            return .hold "the cancel of the abandoned prepare was sent again; the next pass starts a new attempt"

/-- One pass for one partition: decide the record, persist it, push it. `wanted` = the node keys the
    promotion commit point asked the gate about in this pass: a PENDING intent of any other
    successor is abandoned (the promotion is no longer wanted, or another check held it) and
    cancelled — the terminal CAS first, then the successor, so its promises and the master's grant
    resume. A COMMITTED intent cannot be undone: it is reported (the master cannot write until that
    successor is promoted). Returns the record in force (none when the store could not be read:
    nothing is pushed). -/
def abandonUnwanted (ctx : Ctx) (p : Nat) (m : Members) (as : List Attempt) (wanted : List String) :
    IO (List Attempt) := do
  let mut out : List Attempt := []
  for a in as do
    if a.intent.decision == .pending && !wanted.contains a.intent.successor then
      if ← doCancelAttempt ctx p m a then
        IO.eprintln s!"[flare-operator] write authority P{p}: the pending promotion intent {a.n} of {a.intent.successor} was not asked for in this pass: cancelled (its promises resume)"
        out := out ++ [{ a with intent := { a.intent with decision := .cancelled, decidedBy := some ctx.token } }]
      else out := out ++ [a]
    else out := out ++ [a]
  pure out

def ensurePartition (ctx : Ctx) (p : Nat) (v : View) (wanted : List String := []) : IO (Option Members) := do
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
    | .ok as0 =>
      let as ← match old with
        | some o => abandonUnwanted ctx p o as0 wanted
        | none => pure as0
      let master := v.master.getD ""
      if (old.map (·.master)) == v.master then
        for a in as do
          if a.intent.decision == .committed && !wanted.contains a.intent.successor then
            IO.eprintln s!"[flare-operator] CRITICAL: write authority P{p}: the promotion intent {a.n} of {a.intent.successor} is COMMITTED but the master did not change: that successor no longer promises, so the master cannot write until it is promoted (manual)"
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
        match ← pushMaster ctx p rec with
        | none => pure (some rec)
        | some held =>
          -- the master holds exactly this record. Record WHO says so: the incarnation read (pod UID
          -- before and after the flared reading, boot id, copy id). A different incarnation than the
          -- one recorded (a restarted master that was given the record again) is acknowledged anew.
          match ← bindingNow ctx rec.master p with
          | none => pure (some rec)
          | some (s, bnd) =>
            if !(s.holds rec) || held.idBoot != s.idBoot then pure (some rec)
            else if rec.acked && rec.ackBind == some bnd then pure (some rec)
            else
              -- confirm: the master applied exactly this record (CAS'd on the record we read)
              let c2 ← recClient ctx p
              match ← readRec c2 with
              | .ok (some (r2, rv2)) =>
                if r2 == rec then
                  let acked := { rec with acked := true, ackBind := some bnd }
                  let ok2 ← writeRec c2 (some rv2) acked
                  pure (some (if ok2 then acked else rec))
                else pure (some r2)
              | _ => pure (some rec)

end FlareOperator.WriteAuthorityDriver
