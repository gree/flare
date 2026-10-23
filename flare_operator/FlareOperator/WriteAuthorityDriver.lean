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
import FlareOperator.StateMachine.AuthoritativeHistory
import FlareOperator.K8s.Bridge

namespace FlareOperator.WriteAuthorityDriver

open FlareOperator.WriteAuthority
open FlareOperator.PromotionIntentStore
open FlareOperator.PromotionIntentKube
open FlareOperator.PromotionIntent
open FlareOperator.PromotionBinding

/-! ### Limits of the intent index

A ConfigMap holds at most 1 MiB (1048576 bytes) in total. The index value is `"intent-index-v1 "` (16
bytes) plus `t:n` entries joined by `,`; one entry takes at most `maxEntryBytes` bytes (two 20-digit
numbers, `:` and `,`). 1000000 bytes are used for the value (the rest of the 1 MiB is the object's
metadata and the other keys), so an index of at most `maxIndexEntries` entries can never exceed the
object limit. Past the bound the driver FAILS CLOSED (no new attempt); entries are never dropped or
truncated to make room. -/
def maxEntryBytes : Nat := 42
def maxIndexValueBytes : Nat := 1000000
def maxIndexEntries : Nat := (maxIndexValueBytes - 16) / maxEntryBytes
/-- Seeding a missing index reads the intents of every term 1..termNext: at least one API call per term
    (`scanFrom` stops at the first absent number, at most 17 reads per term), once per partition, and in
    the same pass. Past this bound the seeding is refused (fail closed, manual). -/
def maxSeedTerms : Nat := 2000

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
  /-- the most entries one intent index may hold (see `maxIndexEntries`) -/
  indexMaxEntries : Nat := maxIndexEntries
  /-- the most terms the one-time seeding of a missing index reads (see `maxSeedTerms`) -/
  seedMaxTerms : Nat := maxSeedTerms

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

/-- One intent of the partition: `termNext` is the term it was made for (part of its resource name and
    of its wire scope), `n` its number within that term. -/
structure Attempt where
  termNext : Nat
  n : Nat
  intent : Intent

partial def scanFrom (ctx : Ctx) (p termNext n : Nat) (acc : List Attempt) : IO (Except String (List Attempt)) := do
  if n > 16 then return .error "too many promotion attempts for one term (manual)"
  let c ← ctx.clientFor (intentName ctx.cr p termNext n)
  match ← readIntent c with
  | .settled i => scanFrom ctx p termNext (n + 1) (acc ++ [{ termNext, n, intent := i }])
  | .absent => pure (.ok acc)
  | _ => pure (.error "a promotion intent record is unreadable or broken")

def scanAttempts (ctx : Ctx) (p termNext : Nat) : IO (Except String (List Attempt)) :=
  scanFrom ctx p termNext 1 []

/-! ## The persisted intent index

One ConfigMap per partition lists the (term, number) of every intent that may still be non-terminal
(or whose terminal state is not yet confirmed on the wire). Invariants, in the order they are kept:
  * an entry is added (CAS) BEFORE its intent is created, so the index is a superset of the intents
    that exist; an entry whose intent was never created (crash in between) is harmless and is re-used
    by the next create of that number;
  * an entry is removed (CAS) only after the intent is terminal in the store AND the wire cancel was
    confirmed (the node no longer prepares that scope) — or the commit is applied to the record;
  * the index is created once, seeded from ALL terms 1..termNext (so intents of before the index
    existed are not missed). Nothing depends on how far the term has advanced or on operator restarts. -/

def indexName (cr : String) (p : Nat) : String := s!"{cr}-authority-intent-index-p{p}"

def encodeIndex (l : List (Nat × Nat)) : String :=
  "intent-index-v1 " ++ ",".intercalate (l.map fun (t, n) => s!"{t}:{n}")

def decodeIndex (s : String) : Option (List (Nat × Nat)) :=
  match (s.trim).splitOn " " with
  | ["intent-index-v1"] => some []
  | ["intent-index-v1", body] =>
    (body.splitOn ",").mapM fun e =>
      match e.splitOn ":" with
      | [t, n] => do pure (← t.toNat?, ← n.toNat?)
      | _ => none
  | _ => none

def readIndex (c : Client) : IO (Except String (Option (List (Nat × Nat) × String))) := do
  match ← c.get with
  | .error e => pure (.error e)
  | .notFound => pure (.ok none)
  | .found v rv =>
    match decodeIndex v with
    | some l => pure (.ok (some (l, rv)))
    | none => pure (.error "the intent index is malformed (never read as absent)")

/-- Create the index when it does not exist, seeded with every intent of terms 1..`termNext` that is
    not cancelled. The seeding costs at most `seedMaxTerms` x 17 reads, once; a larger term or a seed
    that would exceed `indexMaxEntries` is refused (nothing created). `false`: not confirmed (the next
    pass again). -/
def ensureIndex (ctx : Ctx) (p termNext : Nat) : IO Bool := do
  let c ← ctx.clientFor (indexName ctx.cr p)
  match ← readIndex c with
  | .error _ => pure false
  | .ok (some _) => pure true
  | .ok none =>
    if termNext > ctx.seedMaxTerms then
      IO.eprintln s!"[flare-operator] CRITICAL: write authority P{p}: the intent index does not exist and term {termNext} is beyond the seeding bound ({ctx.seedMaxTerms} terms): no new attempt (manual)"
      return false
    let mut seed : List (Nat × Nat) := []
    for t in [1:termNext + 1] do
      match ← scanFrom ctx p t 1 [] with
      | .ok l => seed := seed ++ (l.filter (·.intent.decision != .cancelled)).map fun a => (a.termNext, a.n)
      | .error _ => return false
    if seed.length > ctx.indexMaxEntries then
      IO.eprintln s!"[flare-operator] CRITICAL: write authority P{p}: the seeded intent index would hold {seed.length} entries (limit {ctx.indexMaxEntries}): no new attempt (manual)"
      return false
    match ← c.create (encodeIndex seed) with
    | .ok _ => pure true
    | _ => pure false

/-- The entry is in the index (CAS), before the intent is created. A full index (`indexMaxEntries`)
    fails closed: `false`, nothing dropped, so no new attempt is made. -/
def addIndex (ctx : Ctx) (p termNext t n : Nat) : IO Bool := do
  if !(← ensureIndex ctx p termNext) then return false
  let c ← ctx.clientFor (indexName ctx.cr p)
  match ← readIndex c with
  | .ok (some (l, rv)) =>
    if l.contains (t, n) then pure true
    else if l.length ≥ ctx.indexMaxEntries then
      IO.eprintln s!"[flare-operator] CRITICAL: write authority P{p}: the intent index is full ({l.length} entries, limit {ctx.indexMaxEntries}): no new attempt (manual)"
      pure false
    else
      match ← c.replace rv (encodeIndex (l ++ [(t, n)])) with
      | .ok _ => pure true
      | _ => pure false
  | _ => pure false

/-- Every intent that can be non-terminal: the index entries plus the current term. Complete for any
    term distance. -/
def scanAll (ctx : Ctx) (p termNext : Nat) : IO (Except String (List Attempt)) := do
  if !(← ensureIndex ctx p termNext) then return .error "the intent index could not be read or created"
  let c ← ctx.clientFor (indexName ctx.cr p)
  match ← readIndex c with
  | .error e => pure (.error e)
  | .ok none => pure (.error "the intent index is missing")
  | .ok (some (l, _)) =>
    let mut old : List Attempt := []
    for (t, n) in l do
      if t < termNext then
        match ← readIntent (← ctx.clientFor (intentName ctx.cr p t n)) with
        | .settled i => old := old ++ [{ termNext := t, n, intent := i }]
        | .absent => pure ()
        | _ => return .error "a promotion intent record is unreadable or broken"
    match ← scanAttempts ctx p termNext with
    | .error e => pure (.error e)
    | .ok cur => pure (.ok (old ++ cur))

/-- The attempts made for the term that the record `termNext` is about to start. -/
def currentTerm (termNext : Nat) (atts : List Attempt) : List Attempt :=
  atts.filter (·.termNext == termNext)

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
def widOf (termNext n : Nat) : Nat := termNext * 100 + n
def wid (m : Members) (n : Nat) : Nat := widOf (m.term + 1) n

/-- The intent's binding is the REAL incarnation: pod UID, flared boot id, persistent copy id. -/
def refOf (ctx : Ctx) (p : Nat) (m : Members) (n : Nat) (key : String) (b : Bind) : Ref :=
  { scope := { cluster := ctx.cr, partition := p, generation := m.gen }, id := n, successor := key,
    binding := { podUid := b.uid, bootId := b.boot, copyId := b.copy } }

/-- What goes on the wire for attempt `n`: id, next term, generation, the receiver's boot and copy. -/
def wireOf (m : Members) (n : Nat) (b : Bind) : WireScope :=
  { id := wid m n, termNext := m.term + 1, gen := m.gen, boot := b.boot, copy := b.copy }

/-- The ORIGINAL wire scope of an existing attempt, rebuilt from the attempt itself (its own term,
    generation and receiver binding as created): every message about that attempt (prepare, commit,
    cancel, re-cancel) uses it, never the current membership's term or generation. -/
def wireOfAttempt (a : Attempt) : WireScope :=
  { id := widOf a.termNext a.n, termNext := a.termNext, gen := a.intent.ref.scope.generation,
    boot := a.intent.binding.bootId, copy := a.intent.binding.copyId }

/-- The attempt was made for exactly the term and generation of the record in force. -/
def inScope (m : Members) (a : Attempt) : Bool :=
  a.termNext == m.term + 1 && a.intent.ref.scope.generation == m.gen

/-- A pending attempt of an older term or generation: it can never be committed (the commit needs the
    current membership), so it is to be cancelled in its original scope. -/
def stalePending (m : Members) (a : Attempt) : Bool :=
  a.intent.decision == .pending && !inScope m a

def attemptName (ctx : Ctx) (p : Nat) (a : Attempt) : String :=
  intentName ctx.cr p a.termNext a.n

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
def newestFor (m : Members) (as : List Attempt) (key : String) (b : Bind) : Option Attempt :=
  (as.filter fun a => inScope m a && a.intent.successor == key && bindingOfIntent a.intent == b).getLast?

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
  let n := ((currentTerm (m.term + 1) as).map (·.n)).foldl max 0 + 1
  let now ← nowAt ctx
  let deadline : At := { now with t := now.t + ctx.cfg.prepareTimeoutMs }
  if !(← addIndex ctx p (m.term + 1) (m.term + 1) n) then return false
  let c ← ctx.clientFor (intentName ctx.cr p (m.term + 1) n)
  match ← createIntent c (Intent.prepare (refOf ctx p m n key b) ctx.token deadline) with
  | .done _ => pure true
  | .settled _ => pure true
  | _ => pure false

def doPrepare (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) (key : String) (b : Bind) : IO Bool := do
  let sc := wireOfAttempt a
  match (← ask ctx key (cmdPrepare p sc)).bind Status.parse with
  | none => pure false
  | some s =>
    if s.state != "preparing" || !(replicaOf s sc).scopeOk then pure false
    else
      let c ← ctx.clientFor (attemptName ctx p a)
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
def doCancelAttempt (ctx : Ctx) (p : Nat) (a : Attempt) : IO Bool := do
  let c ← ctx.clientFor (attemptName ctx p a)
  let sendCancel : IO Unit := discard <| ask ctx a.intent.successor (cmdCancel p (wireOfAttempt a))
  if (← ensureFence c ctx.token a.intent) then
    match ← cancelIntent c a.intent.ref (.leader ctx.token) (← nowAt ctx) with
    | .done _ => sendCancel; pure true
    | .settled _ => sendCancel; pure true
    | _ => pure false
  else pure false

def doCancel (ctx : Ctx) (p : Nat) (a : Attempt) : IO Unit :=
  discard <| doCancelAttempt ctx p a

def doCommit (ctx : Ctx) (p : Nat) (m : Members) (a : Attempt) : IO Bool := do
  let c ← ctx.clientFor (attemptName ctx p a)
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
    match ← scanAll ctx p (m.term + 1) with
    | .error e => return .hold e
    | .ok as =>
      match ← bindingNow ctx key p with
      | none => return .hold "the candidate's pod / flared identity is unreadable"
      | some (st, b) =>
        if b.uid != uid then return .hold "the candidate's pod is not the one the commit point observed"
        -- a pending attempt of ANOTHER incarnation of this candidate (restart, replaced copy) is dead:
        -- cancel it (terminal CAS), then go on with an attempt of the incarnation read now
        -- (also dead: a pending attempt of an earlier term or generation — it can never be committed
        -- under the record in force; cancelled on its ORIGINAL resource and in its ORIGINAL scope)
        let stale := as.filter fun a => a.intent.decision == .pending
          && ((a.intent.successor == key && bindingOfIntent a.intent != b) || stalePending m a)
        if let some x := stale.head? then
          discard <| doCancelAttempt ctx p x
          return .hold "an attempt of another incarnation, term or generation was cancelled; the next pass starts a fresh one"
        -- a CANCELLED attempt out of scope whose cancel never arrived (the node still prepares exactly
        -- its scope): the cancel is sent again, in the original scope
        let lost := as.filter fun a => a.intent.decision == .cancelled && !inScope m a
          && a.intent.successor == key && (replicaOf st (wireOfAttempt a)).scopeOk && st.state == "preparing"
        if let some x := lost.head? then
          discard <| ask ctx key (cmdCancel p (wireOfAttempt x))
          return .hold "the cancel of an abandoned prepare (older term / generation) was sent again; the next pass starts a fresh one"
        -- a COMMITTED attempt of this term under another generation is never re-used or dropped
        if as.any fun a => a.termNext == m.term + 1 && a.intent.decision == .committed
            && a.intent.successor == key && !inScope m a then
          IO.eprintln s!"[flare-operator] CRITICAL: write authority P{p}: a COMMITTED promotion intent of {key} belongs to an older generation of this term (manual)"
          return .hold "a committed attempt of an older generation exists (fail-closed)"
        let now ← nowAt ctx
        let a := newestFor m as key b
        let sc := (a.map fun x => wireOfAttempt x).getD (wireOf m 0 b)
        let rv := some (replicaOf st sc)
        let id := (a.map fun x => widOf x.termNext x.n).getD 0
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
            doCancel ctx p x
            return .hold s!"cancelled: {why}"
        | .commitCas =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            if ← doCommit ctx p m x then
              discard <| ask ctx key (cmdCommit p (wireOfAttempt x))
              gate ctx p key uid (fuel - 1)
            else return .hold "the commit CAS did not apply"
        | .sendCommit =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            discard <| ask ctx key (cmdCommit p (wireOfAttempt x))
            gate ctx p key uid (fuel - 1)
        | .sendCancel =>
          match a with
          | none => return .hold "no intent"
          | some x =>
            discard <| ask ctx key (cmdCancel p (wireOfAttempt x))
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
    if a.intent.decision == .pending && (!wanted.contains a.intent.successor || stalePending m a) then
      if ← doCancelAttempt ctx p a then
        IO.eprintln s!"[flare-operator] write authority P{p}: the pending promotion intent {a.n} (term {a.termNext}, generation {a.intent.ref.scope.generation}) of {a.intent.successor} was not asked for in this pass or is of an older term / generation: cancelled (its promises resume)"
        out := out ++ [{ a with intent := { a.intent with decision := .cancelled, decidedBy := some ctx.token } }]
      else out := out ++ [a]
    else out := out ++ [a]
  pure out

/-- The committed attempt `a` was applied to the membership record `m` — the only evidence that lets its
    index entry go. Proof (Members.next): the term advances only at `o.term + 1` in a pass whose
    `committedFor` is the master the map shows, i.e. through SOME committed attempt of `termNext = new
    term` whose successor is the new master; the new record names that successor as `master`, and a
    later change of the record's master needs another term. So, for `a.termNext == m.term` and
    `m.master == a.successor`, a committed attempt of this term and successor was applied, and when `a`
    is the ONLY committed attempt of that term and successor it is exactly the applied one. Anything
    else is NOT proven and stays: a committed attempt of an earlier term (the record has moved on; which
    attempt of that term authorised the advance is not recorded), one with another successor than the
    record's master (never applied: a commit whose promotion did not reach the record), or one of
    several committed attempts of the same term and successor. Staying costs one entry (and is the
    fail-closed state, reported by the CRITICAL lines); it never frees a committed intent unproven. -/
def appliedCommit (m : Members) (as : List Attempt) (a : Attempt) : Bool :=
  a.intent.decision == .committed && a.termNext == m.term && a.intent.successor == m.master
    && (as.filter fun b => b.intent.decision == .committed && b.termNext == a.termNext
        && b.intent.successor == a.intent.successor).length == 1

/-- A pass of a STALE leader (an intent already carries a newer fence than this operator's token) changes
    nothing in the index: the current leader owns it. -/
def staleLeader (ctx : Ctx) (as : List Attempt) : Bool :=
  as.any fun a => a.intent.fence > ctx.token

/-- Remove `gone` from the index: read, filter the FRESH list, replace at that resourceVersion. A conflict
    (another writer added an entry in between) re-reads and filters again (bounded), so a concurrent
    add is never overwritten and the removal still happens. -/
def removeIndex (ctx : Ctx) (p : Nat) (gone : List (Nat × Nat)) (tries : Nat) : IO Unit := do
  let c ← ctx.clientFor (indexName ctx.cr p)
  let mut left := tries
  while left > 0 do
    left := left - 1
    match ← readIndex c with
    | .ok (some (l, rv)) =>
      match ← c.replace rv (encodeIndex (l.filter fun e => !gone.contains e)) with
      | .ok _ => left := 0
      | _ => pure ()
    | _ => left := 0

/-- Drop from the index (CAS) the intents that need no more watching: cancelled in the store AND the
    node no longer prepares that scope (read now), or committed and PROVEN applied to the record
    (`appliedCommit`). A cancelled intent whose node still prepares its scope gets the cancel again
    (original scope) and stays. A stale leader's pass leaves the index alone. -/
def pruneIndex (ctx : Ctx) (p : Nat) (m : Members) (as : List Attempt) : IO Unit := do
  if staleLeader ctx as then return
  let mut gone : List (Nat × Nat) := []
  for a in as do
    match a.intent.decision with
    | .committed => if appliedCommit m as a then gone := gone ++ [(a.termNext, a.n)]
    | .cancelled =>
      match ← statusOf ctx a.intent.successor p with
      | none => pure ()
      | some s =>
        if s.state == "preparing" && (replicaOf s (wireOfAttempt a)).scopeOk then
          discard <| ask ctx a.intent.successor (cmdCancel p (wireOfAttempt a))
        else gone := gone ++ [(a.termNext, a.n)]
    | .pending => pure ()
  if !gone.isEmpty then removeIndex ctx p gone 3

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
      | some _ => scanAll ctx p termNext
      | none => pure (.ok [])
    match atts with
    | .error e =>
      IO.eprintln s!"[flare-operator] write authority P{p}: {e}; the record is held"
      pure old
    | .ok as0 =>
      let as ← match old with
        | some o => abandonUnwanted ctx p o as0 wanted
        | none => pure as0
      if let some o := old then pruneIndex ctx p o as
      let master := v.master.getD ""
      if (old.map (·.master)) == v.master then
        for a in currentTerm termNext as do
          if a.intent.decision == .committed && !wanted.contains a.intent.successor then
            IO.eprintln s!"[flare-operator] CRITICAL: write authority P{p}: the promotion intent {a.n} of {a.intent.successor} is COMMITTED but the master did not change: that successor no longer promises, so the master cannot write until it is promoted (manual)"
      let frozen := frozenBy (currentTerm termNext as) && (old.map (·.master)) == v.master
      let want := Members.next old v frozen (committedFor (currentTerm termNext as) master)
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

/-- A master the REGISTRATION reply already made master (the P0 fast path: no pass promotes it, so the
    promotion commit point never sees it) starts as a non-serving candidate: flared's gate refuses a
    Proxy -> master shift without a promotion intent. A proven FRESH FIRST BUILD (authoritative
    history, see `AuthoritativeHistory.firstBuildProven`, and NO membership record of the partition:
    the record is created by this very pass, so the proof is taken BEFORE it) is allowed once, for the
    node's REAL boot / copy identity (`authority first`); flared re-runs its pending shift under the
    same checks (the gate is never bypassed). Everything else is left to the gate (an existing copy
    needs the committed intent). `false` = this partition's record must not be created this pass: a
    proof that could not be sent now would be lost with the record. -/
def registeredFirstBuild (ctx : Ctx) (p : Nat) (mk : String) (store : Option AuthoritativeHistory.Store) (othersHold : Bool) : IO Bool := do
  let rc ← recClient ctx p
  match ← readRec rc with
  | .ok none =>
    match store with
    | none => pure true      -- no history store (the history is off): nothing proves a first build; the gate decides
    | some store =>
      match ← bindingNow ctx mk p with
      | none =>
        IO.eprintln s!"[flare-operator] write authority P{p}: the identity of the registered master {mk} is unreadable: its record is not created this pass"
        pure false
      | some (_, b) =>
        if AuthoritativeHistory.firstBuildProven store p mk b.copy true othersHold then
          match (← ask ctx mk (cmdFirst p b.boot b.copy)).bind Status.parse with
          | some _ =>
            IO.eprintln s!"[flare-operator] write authority: {mk} is the first master of P{p} (fresh first build proven by the history; registered as master); allowed once for boot {b.boot}"
            pure true
          | none =>
            IO.eprintln s!"[flare-operator] write authority P{p}: {mk} did not accept the first-build proof: its record is not created this pass"
            pure false
        else pure true
  | _ => pure true

end FlareOperator.WriteAuthorityDriver
