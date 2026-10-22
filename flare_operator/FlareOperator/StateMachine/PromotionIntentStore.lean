/-
  PromotionIntentStore.lean — terminal commit/cancel CAS adapter over an ABSTRACT
  K8s object client (design: docs/design-node-operations-2026-10-19.md §12.7).
  NOT wired: nothing imports this module except its checks; no kubectl client,
  no call site in Main / the reconcile loop, no flag. The adapter keeps no state
  and reads no clock: every decision is the pure PromotionIntent function applied
  to the record just read, and `now` is supplied by the caller (who names the
  clock owner; a different clock is refused by the pure side).
-/
import FlareOperator.StateMachine.PromotionIntent

namespace FlareOperator.PromotionIntentStore

open FlareOperator.PromotionIntent
open FlareOperator.PromotionBinding

/-- resourceVersion: an opaque token, compared for equality only. -/
abbrev RV := String

inductive GetResult where
  | found (value : String) (rv : RV)
  | notFound
  | error (e : String)

inductive CreateResult where
  | ok (rv : RV)
  | alreadyExists
  /-- the reply may have been lost: the write may or may not have happened -/
  | error (e : String)

inductive ReplaceResult where
  | ok (rv : RV)
  | conflict
  /-- the reply may have been lost: the write may or may not have happened -/
  | error (e : String)

/-- One K8s object (one ConfigMap's `data.record`). -/
structure Client where
  get : IO GetResult
  create : String → IO CreateResult
  replace : RV → String → IO ReplaceResult

/-- What the adapter tells its caller. Only `done` / `settled` mean the
    terminal (or requested) state is in the store. -/
inductive Result where
  /-- this call's write took effect (confirmed by the reply or by a re-read) -/
  | done (i : Intent)
  /-- the same decision was already in the store; nothing written -/
  | settled (i : Intent)
  /-- the pure decision refused it, on the record read -/
  | refused (r : Refusal) (current : Intent)
  /-- the store has no record (affirmatively) -/
  | absent
  /-- the record is unreadable / unknown version: never treated as absent -/
  | badRecord (e : DecodeError)
  /-- cannot tell (store unreadable, lost reply not resolved, conflicts exhausted):
      the caller must NOT assume commit or cancel -/
  | unknown (why : String)
  deriving Repr, DecidableEq, BEq

/-- Read and decode the record with its resourceVersion. -/
def load (c : Client) : IO (Except Result (Intent × RV)) := do
  match ← c.get with
  | .error e => return .error (.unknown s!"read failed: {e}")
  | .notFound => return .error .absent
  | .found v rv =>
    match decode v with
    | .error e => return .error (.badRecord e)
    | .ok i => return .ok (i, rv)

/-- Read-decide-write with resourceVersion. A conflict or an error re-reads and
    decides again on what is there (never overwrites blindly, never resends the
    old value); `fuel` bounds the rounds. -/
def casLoop (c : Client) (decide : Intent → Outcome) : Nat → IO Result
  | 0 => return .unknown "retries exhausted"
  | fuel + 1 => do
    match ← load c with
    | .error r => return r
    | .ok (cur, rv) =>
      match decide cur with
      | .refused r => return .refused r cur
      | .noop i => return .settled i
      | .applied next =>
        match ← c.replace rv (encode next) with
        | .ok _ => return .done next
        | .conflict => casLoop c decide fuel
        | .error _ =>
          -- the write may have happened: the re-read decides
          match ← load c with
          | .ok (now, _) =>
            if now == next then return .done next else casLoop c decide fuel
          | .error r => return r

def defaultFuel : Nat := 4

/-- Create the prepared intent if the store has none. An existing record is
    never replaced: the same intent is `settled`, anything else `refused`
    (a terminal record is not superseded by this unit). -/
def createIntent (c : Client) (i : Intent) : IO Result := do
  match ← c.create (encode i) with
  | .ok _ => return .done i
  | .alreadyExists =>
    match ← load c with
    | .ok (cur, _) => if cur == i then return .settled cur else return .unknown "another intent record exists"
    | .error r => return r
  | .error _ =>
    match ← load c with
    | .ok (cur, _) => if cur == i then return .done i else return .unknown "another intent record exists"
    | .error .absent => return .unknown "create not confirmed"
    | .error r => return r

def adopt (c : Client) (token : Nat) : IO Result :=
  casLoop c (fun i => adoptLeader i token) defaultFuel

def markPrepared (c : Client) (ref : Ref) (token : Nat) (oldUntil : At) : IO Result :=
  casLoop c (fun i => recordPrepared i ref token oldUntil) defaultFuel

def commitIntent (c : Client) (ref : Ref) (actor : Actor) (members : Membership) (now : At) :
    IO Result :=
  casLoop c (fun i => commit i ref actor members now) defaultFuel

def cancelIntent (c : Client) (ref : Ref) (actor : Actor) (now : At) : IO Result :=
  casLoop c (fun i => cancel i ref actor now) defaultFuel

/-- The current record, for a successor deciding whether it may resume / promote
    (feed `readOf`-style evidence; absent / unknown are NOT cancel). -/
def readIntent (c : Client) : IO Result := do
  match ← load c with
  | .ok (i, _) => return .settled i
  | .error r => return r

end FlareOperator.PromotionIntentStore
