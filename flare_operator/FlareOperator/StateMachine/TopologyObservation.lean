/- Observed topology is feedback, not authority. These samples never authorize
   failover, promotion or deletion and never suppress a fresh audit. -/
namespace FlareOperator.TopologyObservation

inductive Verdict where
  | unknown | behind | current | ahead
  deriving BEq, Repr

def Verdict.label : Verdict → String
  | .unknown => "unknown"
  | .behind => "behind"
  | .current => "current"
  | .ahead => "ahead"

structure Sample where
  nodeKey : String
  uid : Option String
  reportedVersion : Option Nat
  observedAtMs : Nat
  verdict : Verdict
  deriving Repr

structure Audit where
  next : Nat := 0
  samples : List Sample := []
  deriving Repr

def reportedVersion (reply : String) : Option Nat := do
  let lines := reply.splitOn "\n" |>.map (·.trim) |>.filter (· != "")
  if lines.getLast? != some "END" then none else do
    let values := lines.filterMap fun line =>
      match line.splitOn " " with
      | ["STAT", "node_map_version", value] => some value
      | _ => none
    match values with
    | [value] => value.toNat?
    | _ => none

def judge (desired : Nat) (before after : Option String) (version : Option Nat) : Verdict :=
  if before.isNone || before == some "" || before != after then .unknown
  else match version with
    | none => .unknown
    | some n => if n < desired then .behind else if n == desired then .current else .ahead

def record (audit : Audit) (liveKeys : List String) (sample : Sample) : Audit :=
  { next := audit.next + 1
    samples := sample :: audit.samples.filter (fun s => liveKeys.contains s.nodeKey && s.nodeKey != sample.nodeKey) }

end FlareOperator.TopologyObservation
