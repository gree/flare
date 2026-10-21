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

namespace FlareOperator.PromotionIntent

inductive Decision where
  | pending | committed | cancelled
  deriving Repr, DecidableEq, BEq

/-- The persisted record. `fence` is the highest operator-leader token the store
    has adopted for this intent; a CAS must carry exactly that token.
    `oldUntil` is the upper bound of ALL old-master authority (operator lease
    included), recorded when the successor acknowledged the prepare; `none`
    means not prepared yet, so no commit is possible. `decidedBy` is the fence
    (or `none` for a successor-initiated cancel) under which the terminal
    decision was taken; it is `none` while pending too. -/
structure Intent where
  id : Nat
  partition : Nat
  successor : String
  fence : Nat
  deadline : Nat
  oldUntil : Option Nat := none
  decision : Decision := .pending
  decidedBy : Option Nat := none
  deriving Repr, DecidableEq, BEq

inductive Actor where
  /-- the operator leader, with its fencing token -/
  | leader (token : Nat)
  /-- the successor itself (timer-authorised cancel; needs the store) -/
  | successor
  deriving Repr, DecidableEq, BEq

inductive Refusal where
  | staleIntent        -- another intent id
  | staleLeader        -- token is not the store's current fence
  | alreadyCommitted   -- terminal: cannot cancel
  | alreadyCancelled   -- terminal: cannot commit
  | notPrepared        -- oldUntil unknown
  | expired            -- commit at or after the deadline
  | tooEarly           -- successor cancel before the deadline
  | notLeader          -- commit by a non-leader
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

def Intent.prepare (id partition : Nat) (successor : String) (fence deadline : Nat) : Intent :=
  { id, partition, successor, fence, deadline }

/-- A new leader adopts the intent: its token must be strictly newer. The
    decision, if any, is carried over untouched. -/
def adoptLeader (i : Intent) (token : Nat) : Outcome :=
  if token > i.fence then .applied { i with fence := token } else .refused .staleLeader

/-- Record that the successor durably acknowledged the prepare. -/
def recordPrepared (i : Intent) (id token oldUntil : Nat) : Outcome :=
  if i.id ≠ id then .refused .staleIntent
  else if i.fence ≠ token then .refused .staleLeader
  else match i.decision with
    | .committed => .refused .alreadyCommitted
    | .cancelled => .refused .alreadyCancelled
    | .pending =>
      match i.oldUntil with
      | none => .applied { i with oldUntil := some oldUntil }
      | some _ => .refused .notPrepared  -- already recorded; a second ack is not accepted

/-- Promotion commit: leader only, current fence, intent id, prepared, strictly
    before the deadline on the store's clock. -/
def commit (i : Intent) (id : Nat) (actor : Actor) (now : Nat) : Outcome :=
  if i.id ≠ id then .refused .staleIntent
  else match actor with
  | .successor => .refused .notLeader
  | .leader token =>
    match i.decision with
    | .committed => if i.fence = token then .noop i else .refused .staleLeader
    | .cancelled => .refused .alreadyCancelled
    | .pending =>
      if i.fence ≠ token then .refused .staleLeader
      else if i.oldUntil.isNone then .refused .notPrepared
      else if i.deadline ≤ now then .refused .expired
      else .applied { i with decision := .committed, decidedBy := some token }

/-- Cancel: the leader (explicit unprepare, any time, current fence) or the
    successor (only from the deadline on). -/
def cancel (i : Intent) (id : Nat) (actor : Actor) (now : Nat) : Outcome :=
  if i.id ≠ id then .refused .staleIntent
  else match i.decision with
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
      if now < i.deadline then .refused .tooEarly
      else .applied { i with decision := .cancelled, decidedBy := none }

/-! Universally quantified terminal-decision lemmas (all records, tokens, times). -/

theorem committed_cannot_cancel (i : Intent) (id : Nat) (a : Actor) (t : Nat)
    (h : i.decision = .committed) : cancel i id a t = .refused .alreadyCommitted ∨
      cancel i id a t = .refused .staleIntent := by
  unfold cancel
  by_cases hi : i.id ≠ id
  · simp [hi]
  · simp [hi, h]

theorem cancelled_cannot_commit (i : Intent) (id : Nat) (a : Actor) (t : Nat)
    (h : i.decision = .cancelled) : ∀ i', commit i id a t ≠ .applied i' := by
  intro i'
  unfold commit
  by_cases hi : i.id ≠ id
  · simp [hi]
  · cases a <;> simp [hi, h]

theorem committed_never_cancel_applied (i : Intent) (id : Nat) (a : Actor) (t : Nat)
    (h : i.decision = .committed) : ∀ i', cancel i id a t ≠ .applied i' := by
  intro i'
  unfold cancel
  by_cases hi : i.id ≠ id
  · simp [hi]
  · simp [hi, h]

theorem cancelled_never_cancel_applied (i : Intent) (id : Nat) (a : Actor) (t : Nat)
    (h : i.decision = .cancelled) : ∀ i', cancel i id a t ≠ .applied i' := by
  intro i'
  unfold cancel
  by_cases hi : i.id ≠ id
  · simp [hi]
  · cases a <;> simp [hi, h] <;> split <;> simp

theorem committed_never_commit_applied (i : Intent) (id : Nat) (a : Actor) (t : Nat)
    (h : i.decision = .committed) : ∀ i', commit i id a t ≠ .applied i' := by
  intro i'
  unfold commit
  by_cases hi : i.id ≠ id
  · simp [hi]
  · cases a <;> simp [hi, h] <;> split <;> simp

theorem stale_fence_cannot_commit (i : Intent) (id token t : Nat)
    (h : i.fence ≠ token) : ∀ i', commit i id (.leader token) t ≠ .applied i' := by
  intro i'
  unfold commit
  by_cases hi : i.id ≠ id
  · simp [hi]
  · cases hd : i.decision <;> simp [hi, h]

/-! ## Persisted representation

One line, tab separated, `key=value`, in a fixed order:
`flare-promotion-intent  v=1  id=..  partition=..  successor=..  fence=..
 deadline=..  old_until=..|-  decision=..  decided_by=..|-`.
The successor identity is percent-escaped for `%`, whitespace controls, space.
Decoding is strict: after parsing, the record is re-encoded and must equal the
input byte for byte (rejects leading zeros, upper-case hex, alternate
spellings), and the record's own invariants must hold. -/

def currentVersion : Nat := 1
def magic : String := "flare-promotion-intent"

inductive DecodeError where
  | malformed (why : String)
  | unknownVersion (v : Nat)
  deriving Repr, DecidableEq, BEq

private def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

private def needsEscape (c : Char) : Bool :=
  c == '%' || c == '\t' || c == '\n' || c == '\r' || c == ' ' || c.toNat < 32 || c.toNat == 127

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

def encode (i : Intent) : String :=
  String.intercalate "\t"
    [ magic, s!"v={currentVersion}", s!"id={i.id}", s!"partition={i.partition}",
      s!"successor={escape i.successor}", s!"fence={i.fence}", s!"deadline={i.deadline}",
      s!"old_until={optStr i.oldUntil}", s!"decision={decisionStr i.decision}",
      s!"decided_by={optStr i.decidedBy}" ]

/-- The record's own invariants (see decode). -/
def Intent.wellFormed (i : Intent) : Bool :=
  match i.decision with
  | .pending => i.decidedBy.isNone
  | .committed => i.oldUntil.isSome && i.decidedBy.isSome
  | .cancelled => true

private def field? (key : String) (s : String) : Option String :=
  let p := key ++ "="
  if s.startsWith p then some (s.drop p.length) else none

private def nat? (s : String) : Option Nat := s.toNat?
private def optNat? (s : String) : Option (Option Nat) :=
  if s == "-" then some none else (nat? s).map some

/-- Strict decoder: anything that is not exactly an `encode` image of a
    well-formed record is an error (never "absent"). -/
def decode (s : String) : Except DecodeError Intent :=
  match s.splitOn "\t" with
  | [m, v, id, part, succ, fence, dl, ou, dec, db] =>
    if m ≠ magic then .error (.malformed "magic")
    else match field? "v" v with
    | none => .error (.malformed "version field")
    | some vs =>
      match nat? vs with
      | none => .error (.malformed "version number")
      | some vn =>
        if vn ≠ currentVersion then .error (.unknownVersion vn)
        else
          let r : Option Intent := do
            let id ← nat? (← field? "id" id)
            let part ← nat? (← field? "partition" part)
            let succ ← unescape? (← field? "successor" succ)
            let fence ← nat? (← field? "fence" fence)
            let dl ← nat? (← field? "deadline" dl)
            let ou ← optNat? (← field? "old_until" ou)
            let d ← (match ← field? "decision" dec with
              | "pending" => some Decision.pending
              | "committed" => some Decision.committed
              | "cancelled" => some Decision.cancelled
              | _ => none)
            let db ← optNat? (← field? "decided_by" db)
            some { id, partition := part, successor := succ, fence, deadline := dl,
                   oldUntil := ou, decision := d, decidedBy := db }
          match r with
          | none => .error (.malformed "field")
          | some i =>
            if !i.wellFormed then .error (.malformed "invariant")
            else if encode i ≠ s then .error (.malformed "non-canonical")
            else .ok i
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
