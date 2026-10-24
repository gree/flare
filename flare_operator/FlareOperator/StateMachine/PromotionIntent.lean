/-
  PromotionIntent.lean — the promotion intent's state machine and its persisted
  representation. NOT wired into the operator or flared: nothing imports this
  module except the unit checks (PromotionIntentChecks). No policy numbers live
  here; every time bound (deadline, old-authority end) is DATA in the record or
  an argument.

  One partition, one intent, one linearizable durable store (premises, not
  proved). The intent has ONE terminal decision, pending -> committed or
  pending -> cancelled, taken by a single compare-and-swap on the persisted
  record, carrying the leader fencing token and the intent id. A local timer is
  never evidence that no promotion was committed: it only licenses TRYING the
  cancel CAS (see PromotionRefusal).
-/

import FlareOperator.StateMachine.PromotionBinding

namespace FlareOperator.PromotionIntent

open FlareOperator.PromotionBinding

inductive Decision where
  | pending | committed | cancelled
  deriving Repr, DecidableEq, BEq

/-- The record member whose promise FENCES the old master when the candidate is not itself a member
    (WriteAuthority: a sole same-history lagging copy). `binding` is the incarnation the fence was
    prepared for; `promiseUntil` (its own clock) is recorded when it acknowledged the prepare, and a
    commit needs it: the store never commits a fenced intent whose fence was not seen prepared. -/
structure FenceMember where
  key : String
  binding : Binding
  promiseUntil : Option At := none
  deriving Repr, DecidableEq, BEq

/-- The persisted record. `fence` is the highest operator-leader token the store
    has adopted for this intent; a CAS must carry exactly that token.
    `oldUntil` is the upper bound of ALL old-master authority (operator lease
    included), recorded when the successor acknowledged the prepare; `none`
    means not prepared yet, so no commit is possible. `decidedBy` is the fence
    (or `none` for a successor-initiated cancel) under which the terminal
    decision was taken; it is `none` while pending too. -/
structure Intent where
  scope : Scope
  id : Nat
  successor : String
  binding : Binding
  fence : Nat
  /-- on the STORE's clock; commit and the successor's cancel read the store's clock -/
  deadline : At
  /-- the successor's own-clock bound of all old-master authority (see PromotionBinding) -/
  oldUntil : Option At := none
  decision : Decision := .pending
  decidedBy : Option Nat := none
  /-- `none`: the candidate itself is the successor whose promise fences the old master (the member
      path). `some f`: the candidate is NOT a member; `f` (a record member) fences instead. -/
  fenceMember : Option FenceMember := none
  deriving Repr, DecidableEq, BEq

def Intent.ref (i : Intent) : Ref :=
  { scope := i.scope, id := i.id, successor := i.successor, binding := i.binding }

inductive Actor where
  /-- the operator leader, with its fencing token -/
  | leader (token : Nat)
  /-- the successor itself (timer-authorised cancel; needs the store) -/
  | successor
  deriving Repr, DecidableEq, BEq

inductive Refusal where
  | mismatch (m : Mismatch)  -- scope / generation / intent id / successor / pod-boot-copy / membership
  | staleLeader        -- token is not the store's current fence
  | alreadyCommitted   -- terminal: cannot cancel
  | alreadyCancelled   -- terminal: cannot commit
  | notPrepared        -- oldUntil unknown
  | expired            -- commit at or after the deadline
  | tooEarly           -- successor cancel before the deadline
  | notLeader          -- commit by a non-leader
  | clockMismatch      -- `now` is not on the clock the deadline was stamped on
  | fenceMismatch      -- the fence member / its incarnation is not the intent's (or the intent has none)
  deriving Repr, DecidableEq, BEq

/-- Result of a store CAS. `noop` = the same decision was already taken (the
    caller learns the authoritative record; nothing changes). -/
inductive Outcome where
  | applied (i : Intent)
  | noop (i : Intent)
  | refused (r : Refusal)
  deriving Repr, DecidableEq, BEq

/-- The record after the CAS (unchanged unless applied). -/
def Outcome.next (o : Outcome) (before : Intent) : Intent :=
  match o with
  | .applied i => i
  | _ => before

def Intent.prepare (ref : Ref) (fence : Nat) (deadline : At) (fenceMember : Option FenceMember := none) : Intent :=
  { scope := ref.scope, id := ref.id, successor := ref.successor, binding := ref.binding,
    fence, deadline, fenceMember }

/-- The node whose membership the commit needs: the fence when there is one, else the successor. -/
def Intent.promiser (i : Intent) : String :=
  match i.fenceMember with
  | some f => f.key
  | none => i.successor

/-- A fenced intent whose fence was not yet seen prepared. -/
def Intent.fenceUnprepared (i : Intent) : Bool :=
  match i.fenceMember with
  | some f => f.promiseUntil.isNone
  | none => false

/-- A new leader adopts the intent: its token must be strictly newer. The
    decision, if any, is carried over untouched. -/
def adoptLeader (i : Intent) (token : Nat) : Outcome :=
  if token > i.fence then .applied { i with fence := token } else .refused .staleLeader

/-- Record that the successor durably acknowledged the prepare. `oldUntil` is
    on the successor's own clock (PromotionBinding.fromRequest). -/
def recordPrepared (i : Intent) (ref : Ref) (token : Nat) (oldUntil : At) : Outcome :=
  match i.ref.check ref with
  | some m => .refused (.mismatch m)
  | none =>
    if i.fence ≠ token then .refused .staleLeader
    else match i.decision with
    | .committed => .refused .alreadyCommitted
    | .cancelled => .refused .alreadyCancelled
    | .pending =>
      match i.oldUntil with
      | none => .applied { i with oldUntil := some oldUntil }
      | some _ => .refused .notPrepared  -- already recorded; a second ack is not accepted

/-- Record that the FENCE member durably acknowledged the prepare (key and incarnation must be the
    intent's own; once). -/
def recordFencePrepared (i : Intent) (ref : Ref) (token : Nat) (key : String) (b : Binding) (u : At) : Outcome :=
  match i.ref.check ref with
  | some m => .refused (.mismatch m)
  | none =>
    if i.fence ≠ token then .refused .staleLeader
    else match i.decision with
    | .committed => .refused .alreadyCommitted
    | .cancelled => .refused .alreadyCancelled
    | .pending =>
      match i.fenceMember with
      | none => .refused .fenceMismatch
      | some f =>
        if f.key ≠ key || f.binding ≠ b then .refused .fenceMismatch
        else match f.promiseUntil with
        | none => .applied { i with fenceMember := some { f with promiseUntil := some u } }
        | some _ => .refused .notPrepared

/-- Promotion commit: leader only, exact ref, current fence, prepared, the
    successor still in the current membership of the same scope, strictly
    before the deadline on the store's clock (`now` must be on that clock). -/
def commit (i : Intent) (ref : Ref) (actor : Actor) (members : Membership) (now : At) : Outcome :=
  match i.ref.check ref with
  | some m => .refused (.mismatch m)
  | none =>
  match actor with
  | .successor => .refused .notLeader
  | .leader token =>
    match i.decision with
    | .committed => if i.fence = token then .noop i else .refused .staleLeader
    | .cancelled => .refused .alreadyCancelled
    | .pending =>
      if i.fence ≠ token then .refused .staleLeader
      else if i.oldUntil.isNone || i.fenceUnprepared then .refused .notPrepared
      else match members.check i.scope i.promiser with
      | some m => .refused (.mismatch m)
      | none =>
        match now.reached? i.deadline with
        | none => .refused .clockMismatch
        | some true => .refused .expired
        | some false => .applied { i with decision := .committed, decidedBy := some token }

/-- Cancel: the leader (explicit unprepare, any time, current fence) or the
    successor (only from the deadline on, `now` on the store's clock). -/
def cancel (i : Intent) (ref : Ref) (actor : Actor) (now : At) : Outcome :=
  match i.ref.check ref with
  | some m => .refused (.mismatch m)
  | none =>
  match i.decision with
  | .committed => .refused .alreadyCommitted
  | .cancelled =>
    match actor with
    | .leader token => if i.fence = token then .noop i else .refused .staleLeader
    | .successor => .noop i
  | .pending =>
    match actor with
    | .leader token =>
      if i.fence ≠ token then .refused .staleLeader
      else .applied { i with decision := .cancelled, decidedBy := some token }
    | .successor =>
      match now.reached? i.deadline with
      | none => .refused .clockMismatch
      | some false => .refused .tooEarly
      | some true => .applied { i with decision := .cancelled, decidedBy := none }

/-! Universally quantified terminal-decision lemmas (all records, refs, tokens, times). -/

set_option maxHeartbeats 400000 in
theorem committed_never_cancel_applied (i : Intent) (r : Ref) (a : Actor) (t : At)
    (h : i.decision = .committed) : ∀ i', cancel i r a t ≠ .applied i' := by
  intro i'
  unfold cancel
  cases hm : i.ref.check r
  · rw [h]; exact nofun
  · exact nofun

set_option maxHeartbeats 400000 in
theorem cancelled_never_cancel_applied (i : Intent) (r : Ref) (a : Actor) (t : At)
    (h : i.decision = .cancelled) : ∀ i', cancel i r a t ≠ .applied i' := by
  intro i'
  unfold cancel
  cases hm : i.ref.check r
  · rw [h]
    cases a with
    | leader token => dsimp only; split <;> exact nofun
    | successor => exact nofun
  · exact nofun

set_option maxHeartbeats 400000 in
theorem cancelled_cannot_commit (i : Intent) (r : Ref) (a : Actor) (m : Membership) (t : At)
    (h : i.decision = .cancelled) : ∀ i', commit i r a m t ≠ .applied i' := by
  intro i'
  unfold commit
  cases hm : i.ref.check r
  · cases a with
    | successor => exact nofun
    | leader token => dsimp only; rw [h]; exact nofun
  · exact nofun

set_option maxHeartbeats 400000 in
theorem committed_never_commit_applied (i : Intent) (r : Ref) (a : Actor) (m : Membership) (t : At)
    (h : i.decision = .committed) : ∀ i', commit i r a m t ≠ .applied i' := by
  intro i'
  unfold commit
  cases hm : i.ref.check r
  · cases a with
    | successor => exact nofun
    | leader token => dsimp only; rw [h]; dsimp only; split <;> exact nofun
  · exact nofun

set_option maxHeartbeats 400000 in
theorem stale_fence_cannot_commit (i : Intent) (r : Ref) (token : Nat) (m : Membership) (t : At)
    (h : i.fence ≠ token) : ∀ i', commit i r (.leader token) m t ≠ .applied i' := by
  intro i'
  unfold commit
  cases hm : i.ref.check r
  · dsimp only
    cases hd : i.decision
    · dsimp only; rw [if_pos h]; exact nofun
    · dsimp only; rw [if_neg (fun e => h e)] <;> exact nofun
    · dsimp only; exact nofun
  · exact nofun

set_option maxHeartbeats 400000 in
/-- A mismatching ref (other scope / generation / intent / successor / binding)
    is never applied by any of the three CASes. -/
theorem mismatching_ref_never_applied (i : Intent) (r : Ref) (x : Mismatch)
    (h : i.ref.check r = some x) (a : Actor) (m : Membership) (t : At) (tok : Nat) (o : At) :
    (∀ i', commit i r a m t ≠ .applied i') ∧ (∀ i', cancel i r a t ≠ .applied i') ∧
    (∀ i', recordPrepared i r tok o ≠ .applied i') := by
  refine ⟨?_, ?_, ?_⟩
  · intro i'; unfold commit; simp only [h]; intro e; cases e
  · intro i'; unfold cancel; simp only [h]; intro e; cases e
  · intro i'; unfold recordPrepared; simp only [h]; intro e; cases e

/-! ## Persisted representation

One line, tab separated, `key=value`, in a fixed order:
`flare-promotion-intent v=2 id cluster partition generation successor pod boot copy
 fence deadline=node:boot:t old_until=node:boot:t|- decision decided_by`, each as
 `key=value`. Strings are percent-escaped for `%`, `:`, whitespace controls, space.
 This is a CODEC only: there is no durable store, no CAS implementation and no
 read-modify-write here; the CAS semantics live in `commit` / `cancel` above on
 an in-memory record.
Decoding is strict: after parsing, the record is re-encoded and must equal the
input byte for byte (rejects leading zeros, upper-case hex, alternate
spellings), and the record's own invariants must hold. -/

def currentVersion : Nat := 2
def magic : String := "flare-promotion-intent"

inductive DecodeError where
  | malformed (why : String)
  | unknownVersion (v : Nat)
  deriving Repr, DecidableEq, BEq

private def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

private def needsEscape (c : Char) : Bool :=
  c == '%' || c == ':' || c == '\t' || c == '\n' || c == '\r' || c == ' ' || c.toNat < 32 || c.toNat == 127

def escape (s : String) : String :=
  s.foldl (fun acc c =>
    if needsEscape c ∧ c.toNat < 256 then
      acc ++ "%" ++ String.singleton (hexDigit (c.toNat / 16)) ++ String.singleton (hexDigit (c.toNat % 16))
    else acc.push c) ""

private def hexVal? (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - 48)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat - 87)
  else none

def unescape? (s : String) : Option String :=
  let rec go : List Char → String → Option String
    | [], acc => some acc
    | '%' :: a :: b :: rest, acc =>
      match hexVal? a, hexVal? b with
      | some x, some y => go rest (acc.push (Char.ofNat (x * 16 + y)))
      | _, _ => none
    | '%' :: _, _ => none
    | c :: rest, acc => if needsEscape c then none else go rest (acc.push c)
  go s.toList ""

private def decisionStr : Decision → String
  | .pending => "pending" | .committed => "committed" | .cancelled => "cancelled"

private def optStr : Option Nat → String
  | none => "-" | some n => toString n

private def atStr (a : At) : String := s!"{escape a.clock.node}:{escape a.clock.boot}:{a.t}"

private def optAtStr : Option At → String
  | none => "-" | some a => atStr a

/-- The fence member's two extra fields (none for the member path: those records are byte for byte
    what they always were, and an old record decodes unchanged). -/
private def fenceFields (i : Intent) : List String :=
  match i.fenceMember with
  | none => []
  | some f =>
    [ s!"fence_member={escape f.key}:{escape f.binding.podUid}:{escape f.binding.bootId}:{escape f.binding.copyId}",
      s!"fence_until={optAtStr f.promiseUntil}" ]

def encode (i : Intent) : String :=
  String.intercalate "\t"
    ([ magic, s!"v={currentVersion}", s!"id={i.id}", s!"cluster={escape i.scope.cluster}",
      s!"partition={i.scope.partition}", s!"generation={i.scope.generation}",
      s!"successor={escape i.successor}", s!"pod={escape i.binding.podUid}",
      s!"boot={escape i.binding.bootId}", s!"copy={escape i.binding.copyId}",
      s!"fence={i.fence}", s!"deadline={atStr i.deadline}",
      s!"old_until={optAtStr i.oldUntil}", s!"decision={decisionStr i.decision}",
      s!"decided_by={optStr i.decidedBy}" ] ++ fenceFields i)

/-- The record's own invariants (see decode). -/
def Intent.wellFormed (i : Intent) : Bool :=
  match i.decision with
  | .pending => i.decidedBy.isNone
  | .committed => i.oldUntil.isSome && i.decidedBy.isSome && !i.fenceUnprepared
  | .cancelled => true

private def field? (key : String) (s : String) : Option String :=
  let p := key ++ "="
  if s.startsWith p then some (s.drop p.length) else none

private def nat? (s : String) : Option Nat := s.toNat?
private def optNat? (s : String) : Option (Option Nat) :=
  if s == "-" then some none else (nat? s).map some

private def at? (s : String) : Option At :=
  match s.splitOn ":" with
  | [n, b, t] => do
    let n ← unescape? n
    let b ← unescape? b
    let t ← nat? t
    some { clock := { node := n, boot := b }, t }
  | _ => none

private def optAt? (s : String) : Option (Option At) :=
  if s == "-" then some none else (at? s).map some

private def decisionOf? (s : String) : Option Decision :=
  if s == "pending" then some .pending
  else if s == "committed" then some .committed
  else if s == "cancelled" then some .cancelled
  else none

private def strField? (key s : String) : Option String := do
  unescape? (← field? key s)

private def natField? (key s : String) : Option Nat := do
  nat? (← field? key s)

private def scopeOf? (cl part gen : String) : Option Scope := do
  let c ← strField? "cluster" cl
  let p ← natField? "partition" part
  let g ← natField? "generation" gen
  some { cluster := c, partition := p, generation := g }

private def bindingOf? (pod boot copy : String) : Option Binding := do
  let p ← strField? "pod" pod
  let b ← strField? "boot" boot
  let c ← strField? "copy" copy
  some { podUid := p, bootId := b, copyId := c }

private def stateOf? (fence dl ou dec db : String) :
    Option (Nat × At × Option At × Decision × Option Nat) := do
  let f ← natField? "fence" fence
  let d ← at? (← field? "deadline" dl)
  let o ← optAt? (← field? "old_until" ou)
  let x ← decisionOf? (← field? "decision" dec)
  let y ← optNat? (← field? "decided_by" db)
  some (f, d, o, x, y)

private def parseBody (id cl part gen succ pod boot copy fence dl ou dec db : String) :
    Option Intent := do
  let i ← natField? "id" id
  let sc ← scopeOf? cl part gen
  let su ← strField? "successor" succ
  let bd ← bindingOf? pod boot copy
  let st ← stateOf? fence dl ou dec db
  some { scope := sc, id := i, successor := su, binding := bd,
         fence := st.1, deadline := st.2.1, oldUntil := st.2.2.1,
         decision := st.2.2.2.1, decidedBy := st.2.2.2.2 }

/-- The fence member's two fields (`fence_member=key:pod:boot:copy`, `fence_until=at|-`). -/
private def fenceMemberOf? (fm fu : String) : Option FenceMember := do
  let body ← field? "fence_member" fm
  match body.splitOn ":" with
  | [k, p, b, c] =>
    let k' ← unescape? k
    let p' ← unescape? p
    let b' ← unescape? b
    let c' ← unescape? c
    let u ← optAt? (← field? "fence_until" fu)
    some { key := k', binding := { podUid := p', bootId := b', copyId := c' }, promiseUntil := u }
  | _ => none

private def finish (s : String) (i : Intent) : Except DecodeError Intent :=
  if !i.wellFormed then .error (.malformed "invariant")
  else if encode i ≠ s then .error (.malformed "non-canonical")
  else .ok i

/-- Strict decoder: anything that is not exactly an `encode` image of a
    well-formed record is an error (never "absent"). A record with no fence member has the 15
    fields it always had; one with a fence member has two more. -/
def decode (s : String) : Except DecodeError Intent :=
  let withHead (m v : String) (k : Nat → Except DecodeError Intent) : Except DecodeError Intent :=
    if m ≠ magic then .error (.malformed "magic")
    else match natField? "v" v with
    | none => .error (.malformed "version field")
    | some vn => if vn ≠ currentVersion then .error (.unknownVersion vn) else k vn
  match s.splitOn "\t" with
  | [m, v, id, cl, part, gen, succ, pod, boot, copy, fence, dl, ou, dec, db] =>
    withHead m v fun _ =>
      match parseBody id cl part gen succ pod boot copy fence dl ou dec db with
      | none => .error (.malformed "field")
      | some i => finish s i
  | [m, v, id, cl, part, gen, succ, pod, boot, copy, fence, dl, ou, dec, db, fm, fu] =>
    withHead m v fun _ =>
      match parseBody id cl part gen succ pod boot copy fence dl ou dec db, fenceMemberOf? fm fu with
      | some i, some f => finish s { i with fenceMember := some f }
      | _, _ => .error (.malformed "field")
  | _ => .error (.malformed "field count")

/-- What a read of the store yielded. `unreachable` and `malformed` are NOT
    `absent`: only an affirmative "no record" is absent. -/
inductive ReadResult where
  | unreachable
  | malformed (e : DecodeError)
  | absent
  | present (i : Intent)
  deriving Repr, DecidableEq, BEq

def readOf (raw : Option (Option String)) : ReadResult :=
  match raw with
  | none => .unreachable
  | some none => .absent
  | some (some s) =>
    match decode s with
    | .ok i => .present i
    | .error e => .malformed e

end FlareOperator.PromotionIntent
