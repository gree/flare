/-
  PromotionIntentStoreChecks.lean — deterministic checks of the CAS adapter
  against an in-memory fake K8s object client with scripted faults. Finite
  schedules, not a proof of the real API's behaviour (no real-API test).
-/
import FlareOperator.StateMachine.PromotionIntentStore
import FlareOperator.StateMachine.PromotionIntentChecks

namespace FlareOperator.PromotionIntentStoreChecks

open FlareOperator.PromotionIntent
open FlareOperator.PromotionIntentStore
open FlareOperator.PromotionIntentChecks
open FlareOperator.PromotionBinding

/-- (`writes` counts the adapter's own writes; an `interfere` write is not counted.)
    A scripted fault, consumed by the next `replace`. -/
inductive Fault where
  /-- the write is applied, the reply is an error -/
  | lostReply
  /-- the write is not applied, the reply is an error -/
  | rejectWrite
  /-- before the write, another writer replaces the record with this text -/
  | interfere (v : String)

/-- The stored object: (text, resourceVersion counter). -/
structure Fake where
  cell : IO.Ref (Option (String × Nat))
  faults : IO.Ref (List Fault)
  writes : IO.Ref Nat
  getFails : IO.Ref Bool

def Fake.new (init : Option String) (faults : List Fault := []) : IO Fake := do
  return { cell := ← IO.mkRef (init.map (·, 1)), faults := ← IO.mkRef faults,
           writes := ← IO.mkRef 0, getFails := ← IO.mkRef false }

def Fake.applyIf (f : Fake) (rv : RV) (v : String) : IO Bool := do
  match ← f.cell.get with
  | some (_, n) =>
    if rv == toString n then
      f.cell.set (some (v, n + 1))
      f.writes.modify (· + 1)
      return true
    else return false
  | none => return false

def Fake.replace (f : Fake) (rv : RV) (v : String) : IO ReplaceResult := do
  let fs ← f.faults.get
  match fs with
  | [] =>
    return if (← f.applyIf rv v) then .ok "" else .conflict
  | x :: rest =>
    f.faults.set rest
    match x with
    | .lostReply =>
      let _ ← f.applyIf rv v
      return .error "timeout"
    | .rejectWrite => return .error "refused"
    | .interfere w =>
      match ← f.cell.get with
      | some (_, n) => f.cell.set (some (w, n + 1))
      | none => pure ()
      return if (← f.applyIf rv v) then .ok "" else .conflict

def Fake.create (f : Fake) (v : String) : IO CreateResult := do
  match ← f.cell.get with
  | some _ => return .alreadyExists
  | none =>
    f.cell.set (some (v, 1))
    f.writes.modify (· + 1)
    return .ok "1"

/-- A fresh client over the same stored object: what a restarted process holds. -/
def Fake.client (f : Fake) : Client :=
  { get := do
      if ← f.getFails.get then return .error "unreachable"
      match ← f.cell.get with
      | none => return .notFound
      | some (v, n) => return .found v (toString n)
    create := f.create
    replace := f.replace }

def Fake.text (f : Fake) : IO (Option String) := do
  return (← f.cell.get).map (·.1)

def storedIs (f : Fake) (i : Intent) : IO Bool := do
  return (← f.text) == some (encode i)

def commit1 (c : Client) : IO Result := commitIntent c ref7 (.leader 1) members0 (atS 19)
def cancel1 (c : Client) : IO Result := cancelIntent c ref7 (.leader 1) (atS 0)

/-- conflict: the interfering writer cancelled; the old commit is NOT written over it -/
def tConflictCancelled : IO Bool := do
  let f ← Fake.new (some (encode prepared)) [.interfere (encode x7)]
  let r ← commit1 f.client
  return r == .refused .alreadyCancelled x7 && (← storedIs f x7) && (← f.writes.get) == 0

/-- conflict: a new leader adopted in between; the old leader is refused, nothing of its is written -/
def tConflictAdopted : IO Bool := do
  let adopted := { prepared with fence := 2 }
  let f ← Fake.new (some (encode prepared)) [.interfere (encode adopted)]
  let r ← commit1 f.client
  return r == .refused .staleLeader adopted && (← storedIs f adopted)

/-- a benign conflict (the record is rewritten unchanged): the re-read decides again and commits once -/
def tConflictThenApply : IO Bool := do
  let f ← Fake.new (some (encode prepared)) [.interfere (encode prepared)]
  let r ← commit1 f.client
  return r == .done c7 && (← storedIs f c7) && (← f.writes.get) == 1

/-- reply lost after the write took effect: the re-read shows it -/
def tLostReply : IO Bool := do
  let f ← Fake.new (some (encode prepared)) [.lostReply]
  let r ← commit1 f.client
  let again ← commit1 f.client
  return r == .done c7 && (← storedIs f c7) && again == .settled c7 && (← f.writes.get) == 1

/-- reply lost, write NOT applied: the re-read shows the old record and the decision is made again -/
def tRejectedWrite : IO Bool := do
  let f ← Fake.new (some (encode prepared)) [.rejectWrite]
  let r ← commit1 f.client
  return r == .done c7 && (← storedIs f c7)

/-- reply lost and the record unreadable afterwards: unknown, not a commit, not a cancel -/
def tLostReplyUnreadable : IO Bool := do
  let f ← Fake.new (some (encode prepared)) [.rejectWrite]
  let c := { f.client with get := do
    let n ← f.writes.get
    f.writes.modify (· + 100)
    if n = 0 then f.client.get else return .error "unreachable" }
  let r ← commit1 c
  return (match r with | .unknown _ => true | _ => false) && (← f.text) == some (encode prepared)

/-- an old leader (stale fence) is refused and writes nothing -/
def tStaleLeader : IO Bool := do
  let adopted := { prepared with fence := 2 }
  let f ← Fake.new (some (encode prepared))
  let a ← adopt f.client 2
  let old ← commit1 f.client
  let oldCancel ← cancel1 f.client
  let again ← adopt f.client 2
  return a == .done adopted && old == .refused .staleLeader adopted &&
    oldCancel == .refused .staleLeader adopted && (← storedIs f adopted) &&
    (match again with | .refused .staleLeader _ => true | _ => false) && (← f.writes.get) == 1

/-- a fresh adapter instance re-reads a terminal record: it stays terminal -/
def tRestart : IO Bool := do
  let f ← Fake.new (some (encode prepared))
  let _ ← commit1 f.client
  let before ← f.text
  let canc ← cancel1 f.client                       -- "restarted" instance
  let succCancel ← cancelIntent f.client ref7 .successor (atS 25)
  let comm ← commit1 f.client
  let rd ← readIntent f.client
  return canc == .refused .alreadyCommitted c7 && succCancel == .refused .alreadyCommitted c7 &&
    comm == .settled c7 && rd == .settled c7 && (← f.text) == before

def tRestartCancelled : IO Bool := do
  let f ← Fake.new (some (encode prepared))
  let _ ← cancel1 f.client
  let comm ← commit1 f.client
  let rd ← readIntent f.client
  return comm == .refused .alreadyCancelled x7 && rd == .settled x7 && (← storedIs f x7)

/-- malformed / unknown version / unreadable are never absent; only notFound is -/
def tBadRecords : IO Bool := do
  let g ← Fake.new (some "garbage")
  let u ← Fake.new (some ((encode prepared).replace "v=2" "v=3"))
  let n ← Fake.new none
  let e ← Fake.new (some (encode prepared))
  e.getFails.set true
  let rg ← commit1 g.client
  let ru ← commit1 u.client
  let rn ← commit1 n.client
  let re ← commit1 e.client
  let cg ← createIntent g.client prepared
  return rg == .badRecord (.malformed "field count") && ru == .badRecord (.unknownVersion 3) &&
    rn == .absent && (match re with | .unknown _ => true | _ => false) &&
    (match cg with | .badRecord _ => true | _ => false) &&
    (← g.text) == some "garbage" && (← g.writes.get) == 0 && (← u.writes.get) == 0 && (← n.writes.get) == 0

/-- commit racing cancel, each winning the CAS in turn: exactly one terminal -/
def tCommitVsCancel : IO Bool := do
  let a ← Fake.new (some (encode prepared)) [.interfere (encode x7)]
  let ra ← commit1 a.client
  let b ← Fake.new (some (encode prepared)) [.interfere (encode c7)]
  let rb ← cancel1 b.client
  let s ← Fake.new (some (encode prepared))
  let r1 ← commit1 s.client
  let r2 ← cancel1 s.client
  let r3 ← cancelIntent s.client ref7 .successor (atS 25)
  return ra == .refused .alreadyCancelled x7 && (← storedIs a x7) &&
    rb == .refused .alreadyCommitted c7 && (← storedIs b c7) &&
    r1 == .done c7 && r2 == .refused .alreadyCommitted c7 && r3 == .refused .alreadyCommitted c7 &&
    (← storedIs s c7)

/-- conflicts without end: unknown after the bounded rounds, nothing decided -/
def tExhausted : IO Bool := do
  let p := encode prepared
  let f ← Fake.new (some p) [.interfere p, .interfere p, .interfere p, .interfere p, .interfere p]
  let r ← commit1 f.client
  return (match r with | .unknown _ => true | _ => false) && (← storedIs f prepared)

/-- the adapter reads no clock: `now` on another clock is refused by the pure side, nothing written -/
def tClock : IO Bool := do
  let f ← Fake.new (some (encode prepared))
  let r ← cancelIntent f.client ref7 .successor (atR 25)
  let c ← commitIntent f.client ref7 (.leader 1) members0 (atR 5)
  return r == .refused .clockMismatch prepared && c == .refused .clockMismatch prepared &&
    (← storedIs f prepared)

/-- create-if-absent; an existing record is never replaced -/
def tCreate : IO Bool := do
  let first := Intent.prepare ref7 1 (atS 20)
  let f ← Fake.new none
  let a ← createIntent f.client first
  let b ← createIntent f.client first
  let c ← createIntent f.client { first with id := 8 }
  let t ← Fake.new (some (encode c7))
  let d ← createIntent t.client first
  let l ← Fake.new none [] 
  let lc := { l.client with create := fun v => do
    let _ ← l.client.create v
    return .error "timeout" }
  let e ← createIntent lc first
  return a == .done first && b == .settled first && (match c with | .unknown _ => true | _ => false) &&
    (match d with | .unknown _ => true | _ => false) && (← storedIs t c7) && e == .done first

/-- prepare ack recorded through the adapter, then commit; second ack refused -/
def tPrepared : IO Bool := do
  let first := Intent.prepare ref7 1 (atS 20)
  let f ← Fake.new (some (encode first))
  let a ← markPrepared f.client ref7 1 (atR 10)
  let early ← Fake.new (some (encode first))
  let r ← commit1 early.client
  let b ← markPrepared f.client ref7 1 (atR 11)
  return a == .done prepared && (match r with | .refused .notPrepared _ => true | _ => false) &&
    (match b with | .refused _ _ => true | _ => false) && (← storedIs f prepared)

def checks : IO (List (String × Bool)) := do
  return [
    ("store: conflict, the interfering writer cancelled -> re-read, refused, the commit is not written over it", ← tConflictCancelled),
    ("store: conflict, a new leader adopted -> re-read, the old leader is refused (stale fence)", ← tConflictAdopted),
    ("store: benign conflict -> re-read, decided again, committed once", ← tConflictThenApply),
    ("store: reply lost after a successful write -> the re-read shows it (done); a repeat is settled, one write", ← tLostReply),
    ("store: reply lost, write not applied -> the decision is made again on the re-read", ← tRejectedWrite),
    ("store: reply lost and the re-read fails -> unknown (neither commit nor cancel assumed)", ← tLostReplyUnreadable),
    ("store: an old leader is refused for commit and cancel, writes nothing; a second adopt of the same token is refused", ← tStaleLeader),
    ("store: restart (fresh client) re-reads a committed record: stays committed, cancel refused", ← tRestart),
    ("store: restart re-reads a cancelled record: stays cancelled, commit refused", ← tRestartCancelled),
    ("store: malformed / unknown version / unreadable are never absent and write nothing; only notFound is absent", ← tBadRecords),
    ("store: commit vs cancel, either winning the CAS -> exactly one terminal, the other refused", ← tCommitVsCancel),
    ("store: conflicts without end -> unknown after bounded rounds, nothing decided", ← tExhausted),
    ("store: a now on another clock is refused (the adapter reads no clock), nothing written", ← tClock),
    ("store: create-if-absent never replaces an existing record (even terminal); a lost create reply is confirmed by re-read", ← tCreate),
    ("store: prepare ack through the adapter, commit before the ack refused, a second ack refused", ← tPrepared)
  ]

end FlareOperator.PromotionIntentStoreChecks
