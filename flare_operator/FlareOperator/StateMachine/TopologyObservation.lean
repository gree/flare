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

/-- Diagnostic classification only. Recompare with TODAY'S desired version;
    a cached `current` verdict must not remain current after a new commit.
    Missing/expired feedback is Unknown, never evidence of node death. -/
def observedVerdict (desired now maxAgeMs : Nat) (sample : Option Sample) : Verdict :=
  match sample with
  | none => .unknown
  | some s =>
    if s.verdict == .unknown || s.observedAtMs > now || now - s.observedAtMs > maxAgeMs then .unknown
    else judge desired s.uid s.uid s.reportedVersion

structure Counts where
  behind : Nat := 0
  ahead : Nat := 0
  unknown : Nat := 0
  deriving BEq, Repr

def summarize (audit : Audit) (liveKeys : List String) (desired now maxAgeMs : Nat) : Counts :=
  liveKeys.foldl (fun counts key =>
    match observedVerdict desired now maxAgeMs (audit.samples.find? (·.nodeKey == key)) with
    | .behind => { counts with behind := counts.behind + 1 }
    | .ahead => { counts with ahead := counts.ahead + 1 }
    | .unknown => { counts with unknown := counts.unknown + 1 }
    | .current => counts) {}

end FlareOperator.TopologyObservation
