/-
  The planned-eviction state as JSON (FlareCluster `status.disruption`, a
  JSON string). Persisted before any action is taken, so an operator restart
  resumes from it (and aborts it when the leadership changed).
-/
import FlareOperator.StateMachine.Disruption
import Lean.Data.Json

namespace FlareOperator.DisruptionJson

open Lean (Json)
open FlareOperator.Disruption

def phaseOf : String → Option Phase
  | "requested" => some .requested
  | "fencing" => some .fencing
  | "draining" => some .draining
  | "applying" => some .applying
  | "switching" => some .switching
  | "granted" => some .granted
  | "aborted" => some .aborted
  | _ => none

def bindingJson (b : Binding) : Json :=
  Json.mkObj [("podUid", Json.str b.podUid), ("bootId", Json.str b.bootId), ("copyId", Json.str b.copyId),
              ("historyEpoch", Json.str b.historyEpoch), ("partition", Json.num b.partition)]

def bindingOf (j : Json) : Except String Binding := do
  return { podUid := ← j.getObjValAs? String "podUid", bootId := ← j.getObjValAs? String "bootId",
           copyId := ← j.getObjValAs? String "copyId", historyEpoch := ← j.getObjValAs? String "historyEpoch",
           partition := ← j.getObjValAs? Nat "partition" }

def optStr (o : Option String) : Json := match o with | some s => Json.str s | none => Json.null
def optNat (o : Option Nat) : Json := match o with | some n => Json.num n | none => Json.null

def toJson (s : State) : Json :=
  Json.mkObj [
    ("id", Json.str s.id), ("pod", Json.str s.pod),
    ("target", Json.str (if s.target == .master then "master" else "replica")),
    ("binding", bindingJson s.binding), ("attempt", Json.num s.attempt), ("phase", Json.str s.phase.label),
    ("requestedAt", Json.num s.requestedAt), ("deadline", Json.num s.deadline), ("leaseEpoch", Json.num s.leaseEpoch),
    ("successor", optStr s.successor),
    ("successorBinding", match s.successorBinding with | some b => bindingJson b | none => Json.null),
    ("fenceToken", optStr s.fenceToken), ("fenceGen", optNat s.fenceGen), ("barrier", optNat s.barrier),
    ("lapses", Json.num s.lapses),
    ("grantExpiresAt", optNat s.grantExpiresAt), ("reason", Json.str s.reason)]

def ofJson (j : Json) : Except String State := do
  let target ← match ← j.getObjValAs? String "target" with
    | "master" => pure Target.master
    | "replica" => pure Target.replica
    | t => throw s!"unknown target {t}"
  let phase ← match phaseOf (← j.getObjValAs? String "phase") with
    | some p => pure p
    | none => throw "unknown phase"
  let optS := fun (k : String) => (j.getObjValAs? String k).toOption
  let optN := fun (k : String) => (j.getObjValAs? Nat k).toOption
  return { id := ← j.getObjValAs? String "id", pod := ← j.getObjValAs? String "pod", target,
           binding := ← bindingOf (j.getObjValD "binding"), attempt := ← j.getObjValAs? Nat "attempt", phase,
           requestedAt := ← j.getObjValAs? Nat "requestedAt", deadline := ← j.getObjValAs? Nat "deadline",
           leaseEpoch := ← j.getObjValAs? Nat "leaseEpoch", successor := optS "successor",
           successorBinding := (bindingOf (j.getObjValD "successorBinding")).toOption,
           fenceToken := optS "fenceToken", fenceGen := optN "fenceGen", barrier := optN "barrier",
           lapses := (optN "lapses").getD 0, grantExpiresAt := optN "grantExpiresAt",
           reason := (optS "reason").getD "" }

/-- `""` / absent = no disruption; unparsable = an error (never "none"). -/
def parse (s : String) : Except String (Option State) :=
  if s.trim.isEmpty then .ok none else
  match Json.parse s with
  | .error e => .error e
  | .ok j => if j.isNull then .ok none else (ofJson j).map some

def render (s : Option State) : String :=
  match s with
  | some st => (toJson st).compress
  | none => ""

end FlareOperator.DisruptionJson
