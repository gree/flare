/-
  WriteAuthority.lean — the pure part of the C' wiring (docs/design-node-operations-
  2026-10-19.md §13): the operator-side flag/config, the authoritative membership
  record, the parse of flared's `authority status`, and the gate's decision for
  one promotion. Everything here is a pure function over data; the IO that reads
  and writes the stores and talks to the nodes is WriteAuthorityDriver. No policy
  numbers live here: ttl / renew / margin / prepare timeout are the operator's
  explicit configuration (env), and a missing one keeps the whole feature OFF.
-/

namespace FlareOperator.WriteAuthority

/-! ## Flag and numbers -/

structure Config where
  ttlMs : Nat
  renewMs : Nat
  marginMs : Nat
  prepareTimeoutMs : Nat
  deriving Repr, BEq

/-- Every number explicit and consistent: renew < ttl, and the prepare window
    must outlast the wait the successor imposes (ttl + margin). -/
def Config.valid (c : Config) : Bool :=
  0 < c.renewMs && c.renewMs < c.ttlMs && 0 < c.marginMs && c.ttlMs + c.marginMs < c.prepareTimeoutMs

/-- `none` = the feature is OFF: any of the four missing, or inconsistent
    (the caller reports an inconsistent set loudly; it never guesses a value). -/
def Config.ofValues (ttl renew margin timeout : Option Nat) : Option Config :=
  match ttl, renew, margin, timeout with
  | some t, some r, some m, some p =>
    let c : Config := { ttlMs := t, renewMs := r, marginMs := m, prepareTimeoutMs := p }
    if c.valid then some c else none
  | _, _, _, _ => none

/-! ## The authoritative membership record (one per partition) -/

/-- The incarnation of a node an acknowledgement / an intent is bound to: the pod UID (kubernetes),
    the flared process boot id and the storage's persistent copy id (both as flared reports them in
    `authority status`: identity_boot / identity_copy). A restart, a replaced pod or a replaced copy
    is another binding. -/
structure Bind where
  uid : String
  boot : String
  copy : String
  deriving Repr, BEq, DecidableEq

structure Members where
  term : Nat
  gen : Nat
  master : String
  successors : List String
  /-- the master confirmed it applied exactly this membership (CAS'd) -/
  acked : Bool
  /-- who confirmed it: the master incarnation read at the time (`none` while not acked) -/
  ackBind : Option Bind := none
  deriving Repr, BEq, DecidableEq

def Bind.encode (b : Bind) : String := s!"{b.uid},{b.boot},{b.copy}"

def Members.encode (m : Members) : String :=
  s!"v=2 term={m.term} gen={m.gen} acked={if m.acked then 1 else 0} master={m.master} succ={String.intercalate "," m.successors} ack={match m.ackBind with | some b => b.encode | none => "-"}"

private def fieldOf (k : String) (w : String) : Option String :=
  if w.startsWith (k ++ "=") then some (w.drop (k.length + 1)) else none

private def okKey (s : String) : Bool :=
  !s.isEmpty && s.all fun c => c.isAlphanum || c == '.' || c == '-' || c == ':' || c == '_'

private def natStrict (s : String) : Option Nat :=
  if !s.isEmpty && s.all Char.isDigit then s.toNat? else none

private def succOf (s : String) : Option (List String) :=
  if s.isEmpty then some [] else
    let xs := s.splitOn ","
    if xs.all okKey then some xs else none

private def ackedOf (s : String) : Option Bool :=
  if s == "1" then some true else if s == "0" then some false else none

private def bindOf (s : String) : Option (Option Bind) :=
  if s == "-" then some none else
    match s.splitOn "," with
    | [u, b, c] => if okKey u && okKey b && okKey c then some (some { uid := u, boot := b, copy := c }) else none
    | _ => none

/-- acked <-> bound: an acknowledgement always names the incarnation that gave it -/
private def build (t g a ma su ak : String) : Option Members := do
  let t' ← natStrict t
  let g' ← natStrict g
  let a' ← ackedOf a
  let su' ← succOf su
  let ak' ← bindOf ak
  if okKey ma && a' == ak'.isSome then
    some { term := t', gen := g', master := ma, successors := su', acked := a', ackBind := ak' }
  else none

private def decodeFields (v t g a ma su ak : String) : Option Members := do
  let v' ← fieldOf "v" v
  if v' != "2" then none else
    let t' ← fieldOf "term" t
    let g' ← fieldOf "gen" g
    let a' ← fieldOf "acked" a
    let ma' ← fieldOf "master" ma
    let su' ← fieldOf "succ" su
    let ak' ← fieldOf "ack" ak
    build t' g' a' ma' su' ak'

/-- Strict, canonical form only (anything else is a broken record, never absent). -/
def Members.decode (s : String) : Option Members :=
  match s.trim.splitOn " " with
  | [v, t, g, a, ma, su, ak] =>
    match decodeFields v t g a ma su ak with
    | some m => if m.encode == s.trim then some m else none
    | none => none
  | _ => none

/-- What the node map says about one partition, as the operator reads it. -/
structure View where
  master : Option String
  /-- Active slaves whose pod is Ready and not terminating: the nodes ELIGIBLE to be added. Their
      absence from a later pass is only an observation and removes nobody. -/
  successors : List String
  /-- the keys of every pod that exists (the pod list was read in full), or `none` when it could not
      be read: nobody is removed on an unreadable pod list -/
  pods : Option (List String) := none
  deriving Repr, BEq

/-- The members of the record that are AUTHORITATIVELY gone: their pod no longer exists (read in
    full). A pod that is rebuilding, not Ready, not Active, a Proxy, down or unreachable is NOT gone
    (design §12.5: unreachable / temporarily ineligible is not "no successor"). -/
def View.gone (v : View) (members : List String) : List String :=
  match v.pods with
  | none => []
  | some ps => members.filter fun k => !ps.contains k

def sortedKeys (xs : List String) : List String :=
  (xs.toArray.qsort (· < ·)).toList

/-- The next membership record. `frozen`: an intent for the partition is not
    finished (pending, or committed and not yet promoted), so the set of
    successors is not changed (leaving it must not give the old master its
    authority back). `committedFor`: the candidate whose intent was COMMITTED in
    the terminal CAS for term old.term + 1. A master change without a committed
    intent keeps the old record (the new master gets no grant: fail closed). -/
def Members.next (old : Option Members) (v : View) (frozen : Bool) (committedFor : Option String) :
    Option Members :=
  match v.master with
  | none => old
  | some m =>
    let eligible := v.successors.filter (· != m)
    match old with
    | none => some { term := 1, gen := 1, master := m, successors := sortedKeys eligible.eraseDups, acked := false }
    | some o =>
      -- the successors are the record's members that are not authoritatively gone, plus the newly
      -- eligible: a member that is merely not Active / not Ready / unreachable stays (and the set
      -- is solo only when every member was authoritatively removed)
      let kept := o.successors.filter fun k => k != m && !(v.gone o.successors).contains k
      let succ := sortedKeys (kept ++ eligible).eraseDups
      if o.master == m then
        if o.successors == succ || frozen then some o
        else some { o with gen := o.gen + 1, successors := succ, acked := false, ackBind := none }
      else if committedFor == some m then
        some { term := o.term + 1, gen := o.gen + 1, master := m, successors := succ, acked := false }
      else some o

/-! ## flared's `authority status` -/

structure Status where
  enabled : Bool
  state : String
  intent : Nat
  remainingMs : Nat
  promotable : Bool
  floorSet : Bool
  floorTerm : Nat
  floorGen : Nat
  mode : String
  memTerm : Nat
  memGen : Nat
  grantValid : Bool
  grantSolo : Bool
  grantTerm : Nat
  grantGen : Nat
  /-- the scope of the intent the node holds (term_next, generation, boot, copy) -/
  promiseTermNext : Nat
  promiseGen : Nat
  promiseBoot : String
  promiseCopy : String
  /-- the node's own identity now, and the one its membership is bound to -/
  idBoot : String
  idCopy : String
  memBoot : String
  memCopy : String
  deriving Repr, BEq

private def statLine (out k : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    match (line.trim.replace "\r" "").splitOn " " |>.filter (· != "") with
    | ["STAT", k', v] => if k' == k then some v else none
    | _ => none

private def statNatOf (out k : String) : Option Nat := (statLine out k).bind natStrict

private def statFlag (out k : String) : Option Bool :=
  match statLine out k with
  | some "1" => some true
  | some "0" => some false
  | _ => none

private def completeReply (out : String) : Bool :=
  (out.splitOn "\n").any fun l => (l.trim.replace "\r" "") == "END"

/-- The status is read in three small parts (one big do-block of 24 fields made the elaborator
    run out of memory). -/
private structure StA where
  enabled : Bool
  state : String
  intent : Nat
  remainingMs : Nat
  promotable : Bool
  floorSet : Bool
  floorTerm : Nat
  floorGen : Nat

private structure StB where
  mode : String
  memTerm : Nat
  memGen : Nat
  grantValid : Bool
  grantSolo : Bool
  grantTerm : Nat
  grantGen : Nat

private structure StC where
  promiseTermNext : Nat
  promiseGen : Nat
  promiseBoot : String
  promiseCopy : String
  idBoot : String
  idCopy : String
  memBoot : String
  memCopy : String

private def readA (out : String) : Option StA := do
  let enabled ← statFlag out "authority_enabled"
  let state ← statLine out "promise_state"
  let intent ← statNatOf out "promise_intent"
  let remainingMs ← statNatOf out "promise_remaining_ms"
  let promotable ← statFlag out "promise_promotable"
  let floorSet ← statFlag out "floor_set"
  let floorTerm ← statNatOf out "floor_term"
  let floorGen ← statNatOf out "floor_gen"
  some { enabled, state, intent, remainingMs, promotable, floorSet, floorTerm, floorGen }

private def readB (out : String) : Option StB := do
  let mode ← statLine out "members_mode"
  let memTerm ← statNatOf out "members_term"
  let memGen ← statNatOf out "members_gen"
  let grantValid ← statFlag out "grant_valid"
  let grantSolo ← statFlag out "grant_solo"
  let grantTerm ← statNatOf out "grant_term"
  let grantGen ← statNatOf out "grant_gen"
  some { mode, memTerm, memGen, grantValid, grantSolo, grantTerm, grantGen }

private def knownWord (w : String) : Bool := okKey w && w != "-"

private def readC (out : String) : Option StC := do
  let promiseTermNext ← statNatOf out "promise_term_next"
  let promiseGen ← statNatOf out "promise_gen"
  let promiseBoot ← (statLine out "promise_boot").filter okKey
  let promiseCopy ← (statLine out "promise_copy").filter okKey
  -- an undetermined identity is printed as "-": the whole reply is Unknown (fail closed), never a binding
  let idBoot ← (statLine out "identity_boot").filter knownWord
  let idCopy ← (statLine out "identity_copy").filter knownWord
  let memBoot ← (statLine out "members_boot").filter okKey
  let memCopy ← (statLine out "members_copy").filter okKey
  some { promiseTermNext, promiseGen, promiseBoot, promiseCopy, idBoot, idCopy, memBoot, memCopy }

private def statusOfFields (out : String) : Option Status :=
  match readA out, readB out, readC out with
  | some a, some b, some c =>
    some { enabled := a.enabled, state := a.state, intent := a.intent, remainingMs := a.remainingMs,
           promotable := a.promotable, floorSet := a.floorSet, floorTerm := a.floorTerm, floorGen := a.floorGen,
           mode := b.mode, memTerm := b.memTerm, memGen := b.memGen, grantValid := b.grantValid,
           grantSolo := b.grantSolo, grantTerm := b.grantTerm, grantGen := b.grantGen,
           promiseTermNext := c.promiseTermNext, promiseGen := c.promiseGen, promiseBoot := c.promiseBoot,
           promiseCopy := c.promiseCopy, idBoot := c.idBoot, idCopy := c.idCopy, memBoot := c.memBoot,
           memCopy := c.memCopy }
  | _, _, _ => none

/-- A reply is read only when complete (END) and every field is present: a
    truncated or error reply is `none` (Unknown), never a default. -/
def Status.parse (out : String) : Option Status :=
  if completeReply out then statusOfFields out else none

/-- The identity the node reports for itself now. -/
def Status.bind (s : Status) (uid : String) : Bind := { uid, boot := s.idBoot, copy := s.idCopy }

/-- The master holds exactly this membership (term AND generation), bound to its CURRENT incarnation
    and copy, and no grant of any other (term, generation) is valid: a replicated master need not hold
    a grant yet, but a grant it does hold must be of exactly this record (an older generation's
    grant, which the newcomer never promised behind, is not the one in use). Solo: the unlimited grant
    of exactly this record. -/
def Status.holds (s : Status) (m : Members) : Bool :=
  s.enabled && s.memTerm == m.term && s.memGen == m.gen && s.memBoot == s.idBoot && s.memCopy == s.idCopy &&
    (if m.successors.isEmpty then s.mode == "solo" && s.grantValid && s.grantSolo && s.grantTerm == m.term && s.grantGen == m.gen
     else s.mode == "replicated" && !s.grantSolo && (!s.grantValid || (s.grantTerm == m.term && s.grantGen == m.gen)))

/-- The floor fences by TERM; its generation stays 0 (docs §13: a generation change must not
    refuse the master's forwards or renewals in between). -/
def Status.floorIs (s : Status) (m : Members) : Bool :=
  s.floorSet && s.floorTerm == m.term

/-! ## Commands -/

def cmdMembers (p : Nat) (m : Members) (c : Config) : String :=
  if m.successors.isEmpty then s!"authority solo {p} {m.term} {m.gen}"
  else s!"authority members {p} {m.term} {m.gen} {c.ttlMs} {c.renewMs} {String.intercalate " " m.successors}"

def cmdFloor (p : Nat) (m : Members) : String := s!"authority floor {p} {m.term} 0"
/-- The complete scope of an intent on the wire: the id (unique across terms), the next term, the
    membership generation and the receiver's flared boot id / copy id. flared matches ALL of it. -/
structure WireScope where
  id : Nat
  termNext : Nat
  gen : Nat
  boot : String
  copy : String
  deriving Repr, BEq

def WireScope.line (s : WireScope) : String := s!"{s.id} {s.termNext} {s.gen} {s.boot} {s.copy}"

def cmdPrepare (p : Nat) (s : WireScope) : String := s!"authority prepare {p} {s.line}"
def cmdCommit (p : Nat) (s : WireScope) : String := s!"authority commit {p} {s.line}"
def cmdCancel (p : Nat) (s : WireScope) : String := s!"authority cancel {p} {s.line}"
/-- a proven fresh first build of the partition, for this incarnation of the node (once) -/
def cmdFirst (p : Nat) (boot copy : String) : String := s!"authority first {p} {boot} {copy}"
def cmdStatus (p : Nat) : String := s!"authority status {p}"

/-! ## The promotion gate (one candidate, one pass) -/

inductive IntentView where
  | none
  | pending (prepared : Bool) (deadlineReached : Bool)
  | committed
  | cancelled
  deriving Repr, BEq

structure Replica where
  state : String
  intent : Nat
  /-- the whole scope the node reports (id, next term, generation, boot, copy) is the attempt's -/
  scopeOk : Bool
  remainingMs : Nat
  promotable : Bool
  deriving Repr, BEq

inductive Action where
  | wait (why : String)
  | abort (why : String)
  | createIntent
  | sendPrepare
  | cancelCas (why : String)
  /-- the intent is cancelled in the store but the successor still holds that prepare
      (the cancel message did not reach it): say it again before anything new -/
  | sendCancel
  | commitCas
  | sendCommit
  | proceed
  deriving Repr, BEq

/-- One decision. Unknown (the replica unreadable) never cancels and never
    commits. A committed intent is not undone. -/
def gateDecide (isSuccessor acked : Bool) (iv : IntentView) (rv : Option Replica) (id : Nat) : Action :=
  if !isSuccessor then .abort "the candidate is not in the membership"
  else if !acked then .wait "the master has not confirmed this membership"
  else match iv with
  | .none => .createIntent
  | .cancelled =>
    match rv with
    | some r => if r.state == "preparing" && r.intent == id && r.scopeOk then .sendCancel else .createIntent
    | none => .createIntent
  | .pending false _ => .sendPrepare
  | .pending true reached =>
    if reached then .cancelCas "the prepare window passed without a commit"
    else match rv with
    | none => .wait "the successor is unreadable"
    | some r =>
      if r.state != "preparing" || r.intent != id || !r.scopeOk then .cancelCas "the successor does not hold this prepare (id, term, generation and incarnation)"
      else if r.remainingMs > 0 then .wait s!"its promise to the old master runs {r.remainingMs} ms more"
      else .commitCas
  | .committed =>
    match rv with
    | none => .wait "the successor is unreadable"
    | some r =>
      if r.intent != id || !r.scopeOk then .abort "a committed intent the successor does not know (manual)"
      else if r.promotable then .proceed
      else if r.state == "preparing" then .sendCommit
      else .wait s!"waiting for {r.remainingMs} ms"

end FlareOperator.WriteAuthority
