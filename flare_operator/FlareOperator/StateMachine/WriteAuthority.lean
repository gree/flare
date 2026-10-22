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

structure Members where
  term : Nat
  gen : Nat
  master : String
  successors : List String
  /-- the master confirmed it applied exactly this membership (CAS'd) -/
  acked : Bool
  deriving Repr, BEq, DecidableEq

def Members.encode (m : Members) : String :=
  s!"v=1 term={m.term} gen={m.gen} acked={if m.acked then 1 else 0} master={m.master} succ={String.intercalate "," m.successors}"

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

private def build (t g a ma su : String) : Option Members :=
  match natStrict t, natStrict g, ackedOf a, succOf su with
  | some t', some g', some a', some su' =>
    if okKey ma then some { term := t', gen := g', master := ma, successors := su', acked := a' } else none
  | _, _, _, _ => none

/-- Strict, canonical form only (anything else is a broken record, never absent). -/
def Members.decode (s : String) : Option Members :=
  match s.trim.splitOn " " with
  | [v, t, g, a, ma, su] =>
    match fieldOf "v" v, fieldOf "term" t, fieldOf "gen" g, fieldOf "acked" a, fieldOf "master" ma, fieldOf "succ" su with
    | some "1", some t', some g', some a', some ma', some su' =>
      match build t' g' a' ma' su' with
      | some m => if m.encode == s.trim then some m else none
      | none => none
    | _, _, _, _, _, _ => none
  | _ => none

/-- What the node map says about one partition, as the operator reads it. -/
structure View where
  master : Option String
  /-- Active slaves whose pod is Ready and not terminating, in a fixed order -/
  successors : List String
  deriving Repr, BEq

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
    let succ := sortedKeys (v.successors.filter (· != m))
    match old with
    | none => some { term := 1, gen := 1, master := m, successors := succ, acked := false }
    | some o =>
      if o.master == m then
        if o.successors == succ || frozen then some o
        else some { o with gen := o.gen + 1, successors := succ, acked := false }
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

private def statusOfFields (out : String) : Option Status := do
  let enabled ← statFlag out "authority_enabled"
  let state ← statLine out "promise_state"
  let intent ← statNatOf out "promise_intent"
  let remainingMs ← statNatOf out "promise_remaining_ms"
  let promotable ← statFlag out "promise_promotable"
  let floorSet ← statFlag out "floor_set"
  let floorTerm ← statNatOf out "floor_term"
  let floorGen ← statNatOf out "floor_gen"
  let mode ← statLine out "members_mode"
  let memTerm ← statNatOf out "members_term"
  let memGen ← statNatOf out "members_gen"
  let grantValid ← statFlag out "grant_valid"
  let grantSolo ← statFlag out "grant_solo"
  pure { enabled, state, intent, remainingMs, promotable, floorSet, floorTerm, floorGen, mode, memTerm, memGen, grantValid, grantSolo }

/-- A reply is read only when complete (END) and every field is present: a
    truncated or error reply is `none` (Unknown), never a default. -/
def Status.parse (out : String) : Option Status :=
  if completeReply out then statusOfFields out else none

/-- The master holds exactly this membership (and, replicated, a grant is not required: it
    only proves the older unlimited grant cannot be the one in use). -/
def Status.holds (s : Status) (m : Members) : Bool :=
  s.enabled && s.memTerm == m.term && s.memGen == m.gen &&
    (if m.successors.isEmpty then s.mode == "solo" && s.grantValid && s.grantSolo else s.mode == "replicated")

/-- The floor fences by TERM; its generation stays 0 (docs §13: a generation change must not
    refuse the master's forwards or renewals in between). -/
def Status.floorIs (s : Status) (m : Members) : Bool :=
  s.floorSet && s.floorTerm == m.term

/-! ## Commands -/

def cmdMembers (p : Nat) (m : Members) (c : Config) : String :=
  if m.successors.isEmpty then s!"authority solo {p} {m.term} {m.gen}"
  else s!"authority members {p} {m.term} {m.gen} {c.ttlMs} {c.renewMs} {String.intercalate " " m.successors}"

def cmdFloor (p : Nat) (m : Members) : String := s!"authority floor {p} {m.term} 0"
def cmdPrepare (p id termNext : Nat) : String := s!"authority prepare {p} {id} {termNext}"
def cmdCommit (p id : Nat) : String := s!"authority commit {p} {id}"
def cmdCancel (p id : Nat) : String := s!"authority cancel {p} {id}"
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
  remainingMs : Nat
  promotable : Bool
  deriving Repr, BEq

inductive Action where
  | wait (why : String)
  | abort (why : String)
  | createIntent
  | sendPrepare
  | cancelCas (why : String)
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
  | .cancelled => .createIntent
  | .pending false _ => .sendPrepare
  | .pending true reached =>
    if reached then .cancelCas "the prepare window passed without a commit"
    else match rv with
    | none => .wait "the successor is unreadable"
    | some r =>
      if r.state != "preparing" || r.intent != id then .cancelCas "the successor does not hold this prepare"
      else if r.remainingMs > 0 then .wait s!"its promise to the old master runs {r.remainingMs} ms more"
      else .commitCas
  | .committed =>
    match rv with
    | none => .wait "the successor is unreadable"
    | some r =>
      if r.intent != id then .abort "a committed intent the successor does not know (manual)"
      else if r.promotable then .proceed
      else if r.state == "preparing" then .sendCommit
      else .wait s!"waiting for {r.remainingMs} ms"

end FlareOperator.WriteAuthority
