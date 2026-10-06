/-
  Pure parts of the E2E read/activation evidence, unit-tested in
  UnitTests.lean before any E2E relies on them:
  * parsing the replies of one `get` connection,
  * matching flared's read traces (FLARE_TEST_READ_TRACE_PREFIX) to the GETs
    of one client connection,
  * classifying each answer,
  * judging the order of a replica's activation against its acceptance of a
    map that names a new master.
  Every ambiguous input must come out as NOT passing.
-/

namespace FlareOperator.E2E.TraceMatch

private def contains (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- Replies of one connection that sent `get k` for every key of `all`, in
    order. Per key: "=<value>", "miss" (END without a value) or
    "err:<line>" (an explicit error is never a miss). `none` when the number
    of replies does not match (truncated or unexpected output). -/
def parseGetReplies (all : List String) (out : String) : Option (List (String × String)) := Id.run do
  let mut res : Array String := #[]
  let mut pending : Option String := none
  let mut expectValue := false
  for raw in out.splitOn "\n" do
    let l := (raw.replace "\r" "").trim
    if expectValue then
      pending := some ("=" ++ l)
      expectValue := false
    else if l.startsWith "VALUE " then expectValue := true
    else if l == "END" then
      res := res.push (pending.getD "miss")
      pending := none
    else if l.startsWith "SERVER_ERROR" || l.startsWith "CLIENT_ERROR" || l.startsWith "ERROR" then
      res := res.push s!"err:{l}"
      pending := none
  if expectValue || pending.isSome || res.size != all.length then return none
  return some (all.zip res.toList)

/-- flared read-trace lines in `log`, in log order: decision lines
    ("read-trace seq=") and answer lines ("read-trace-result seq="). -/
def readTraces (log : String) : List String :=
  (log.splitOn "\n").filter fun l => contains l "read-trace seq=" || contains l "read-trace-result seq="

def isDecision (l : String) : Bool := contains l "read-trace seq="

/-- Value of `name=` in a trace line ("" when absent). -/
def traceField (line name : String) : String :=
  match (line.splitOn s!" {name}=").drop 1 |>.head? with
  | some rest => (rest.splitOn " ").head?.getD ""
  | none => ""

/-- The traces of one GET: its decision line, its answer line, and whether
    the evidence is ambiguous (a key traced twice on the connection, or the
    marker itself seen more than once). -/
structure KeyTrace where
  decision : Option String := none
  answer : Option String := none
  ambiguous : Bool := false
  deriving Repr, BEq

/-- The GETs that followed `marker` on the SAME client connection, up to the
    next marker on that connection (a reused peer port starts with its own
    marker). Reads forwarded in from a peer arrive on the peer's connection
    and are never included. Each test connection reads every key once, so a
    second decision or answer line for a key marks it ambiguous. -/
def tracesAfterMarker (traces : List String) (marker : String) : List (String × KeyTrace) := Id.run do
  let markerLines := traces.filter fun l => isDecision l && traceField l "key" == marker
  let markerDup := markerLines.length > 1
  let mut conn : Option String := none
  let mut acc : List (String × KeyTrace) := []
  for l in traces do
    let k := traceField l "key"
    let cn := traceField l "conn"
    let decision := isDecision l
    match conn with
    | none =>
      if decision && k == marker && cn != "-" && cn != "" then conn := some cn
    | some c0 =>
      if cn == c0 then
        if contains k "_mark_" then
          if decision && k != marker then
            return acc.reverse.map fun (k, t) => (k, { t with ambiguous := t.ambiguous || markerDup })
        else if k != "" then
          let cur := (acc.lookup k).getD {}
          let upd : KeyTrace :=
            if decision then
              if cur.decision.isNone then { cur with decision := some l } else { cur with ambiguous := true }
            else
              if cur.answer.isNone then { cur with answer := some l } else { cur with ambiguous := true }
          acc := (k, upd) :: acc.filter (·.1 != k)
  return acc.reverse.map fun (k, t) => (k, { t with ambiguous := t.ambiguous || markerDup })

/-- Answer classes. Only `ok` is a correct answer with complete evidence.
    * refused     an explicit error reply: availability (may be a safety
                  refusal);
    * maskedMiss  the server recorded the key as UNREADABLE (failed forward,
                  partition/storage error) yet answered END — to the client a
                  missing key. Its own finding, never cancelled by a later
                  complete read;
    * wrongLocal / wrongForwarded  a real miss or another value on a normal
                  read, from this node's copy / the node it forwarded to:
                  data integrity;
    * untraced    no answer line for this GET;
    * ambiguous   duplicated traces, or an answer line that is truncated or
                  contradicts the reply (cannot be attributed). -/
inductive Answer
  | ok | refused | maskedMiss | wrongLocal | wrongForwarded | untraced | ambiguous
  deriving Repr, BEq

def Answer.label : Answer → String
  | .ok => "ok" | .refused => "refused" | .maskedMiss => "masked-miss"
  | .wrongLocal => "wrong-local" | .wrongForwarded => "wrong-forwarded"
  | .untraced => "untraced" | .ambiguous => "ambiguous"

/-- Classify `answer` (a `parseGetReplies` item) against `expected`
    ("=<value>") with the GET's traces. -/
def classifyAnswer (expected answer : String) (t : KeyTrace) : Answer :=
  if answer.startsWith "err:" then .refused
  else if t.ambiguous then .ambiguous
  else match t.answer with
    | none => .untraced
    | some r =>
      let res := traceField r "result"
      let reason := traceField r "reason"
      if reason.isEmpty then .ambiguous      -- truncated line
      else if res == "unavailable" then (if answer == "miss" then .maskedMiss else .ambiguous)
      else if res == "refused" then .ambiguous  -- the server refused, yet the reply was not an error
      else if res == "hit" then
        if answer == "miss" then .ambiguous
        else if answer == expected then .ok
        else if reason == "local" then .wrongLocal else .wrongForwarded
      else if res == "miss" then
        if answer != "miss" then .ambiguous
        else if answer == expected then .ok
        else if reason == "local" then .wrongLocal else .wrongForwarded
      else .ambiguous

/-- Was the answer served from this node's own copy (per its answer line)? -/
def answeredLocally (t : KeyTrace) : Bool :=
  (t.answer.map (traceField · "reason")) == some "local"

-- ─── activation order ─────────────────────────────────────────────────────

/-- Verdict on a replica's activations around a master switch.
    * pass         the last activation is on the NEW master's copy and every
                   activation followed a passing check of that same copy;
    * bug          a product-level violation (see the reason);
    * undecided    the old master's completed copy was activated BEFORE the
                   replica accepted the new map: not a violation by itself,
                   needs a judgment (re-validation / read suppression);
    * undetermined the log lacks what the verdict needs. -/
inductive Activation
  | pass (why : String) | bug (why : String) | undecided (why : String) | undetermined (why : String)
  deriving Repr, BEq

def Activation.isPass : Activation → Bool
  | .pass _ => true | _ => false

def Activation.describe : Activation → String
  | .pass w => s!"PASS: {w}" | .bug w => s!"BUG: {w}"
  | .undecided w => s!"UNDECIDED: {w}" | .undetermined w => s!"UNDETERMINED: {w}"

/-- Number right after `needle` (digits only). -/
def numAfter (line needle : String) : Option Nat :=
  match (line.splitOn needle).drop 1 |>.head? with
  | some rest => (rest.takeWhile Char.isDigit).toNat?
  | none => none

/-- `line` names node `pod` as a source ("source <pod>." / "from <pod>."). -/
def namesSource (line pod : String) : Bool :=
  contains line s!"source {pod}." || contains line s!"from {pod}."

/-- Judge the order in one process's log `lines` (in log order): when it
    accepted a map naming `newPod` as master, which source each passing
    check and each activation used. -/
def judgeActivation (lines : List String) (oldPod newPod : String) : Activation := Id.run do
  let idx := lines.zip (List.range lines.length)
  let accept := idx.find? fun (l, _) => contains l "node map accepted (version" && contains l s!" 0={newPod}."
  let some (acceptLine, acceptAt) := accept
    | return .undetermined s!"no line shows the replica accepting a map that names {newPod} as master"
  let some aV := numAfter acceptLine "node map accepted (version "
    | return .undetermined "the map acceptance line carries no readable version"
  -- a check of the OLD source against a map that already names the new one
  for (l, _) in idx do
    if contains l "activation source check passed" && namesSource l oldPod then
      match numAfter l "read at version " with
      | some v => if v ≥ aV then return .bug s!"the old source {oldPod} was validated against map v{v} ≥ v{aV}, which names {newPod}: {l}"
      | none => return .undetermined s!"a passing check of {oldPod} carries no map version: {l}"
  let acts := idx.filter fun (l, _) => contains l "node activated (attempt"
  if acts.isEmpty then return .undetermined "no activation is logged in the window"
  -- every activation must follow a passing check of the SAME copy: no new
  -- dump between that check and the activation
  for (a, ai) in acts do
    let src := if namesSource a oldPod then oldPod else if namesSource a newPod then newPod else ""
    if src.isEmpty then return .undetermined s!"an activation names neither {oldPod} nor {newPod}: {a}"
    let before := idx.filter fun (_, i) => i < ai
    let lastCheck := (before.filter fun (l, _) => contains l "activation source check passed" && namesSource l src).getLast?
    let lastDump := (before.filter fun (l, _) => contains l "starting dump operation").getLast?
    match lastCheck with
    | none => return .bug s!"activated on {src}'s copy without a passing source check: {a}"
    | some (_, ci) =>
      let dumpAfterCheck : Bool := match lastDump with
        | some (_, di) => decide (di > ci)
        | none => false
      if dumpAfterCheck then
        return .bug s!"activated after a new dump started since the last passing check of {src}: {a}"
    if src == oldPod && ai > acceptAt then
      return .bug s!"activated the OLD master {oldPod}'s copy after accepting map v{aV} that names {newPod}: {a}"
  match acts.getLast? with
  | some (a, ai) =>
    if namesSource a newPod then return .pass s!"last activation on {newPod}'s copy (log line {ai}), after accepting v{aV}"
    else return .undecided s!"{oldPod}'s completed copy was activated BEFORE accepting map v{aV} (log line {ai} < {acceptAt}); re-validation and read suppression after the switch need a judgment"
  | none => return .undetermined "no activation"

end FlareOperator.E2E.TraceMatch
