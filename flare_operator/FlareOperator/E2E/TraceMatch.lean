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

/-- Final copy check of a replica (review 2026-10-13 finding 3). `expect`:
    every key with "=<value>" or "miss" (absent). `replies`: one round on the
    replica (`none` = not observed). Every key must be answered as expected
    AND be attributed to the replica's OWN copy: decision and answer lines
    both `local`. A proxied answer (availability evidence only), a refusal,
    an untraced or ambiguous answer, a reply set that is not exactly the
    expected keys, or an empty `expect` all fail. Returns the problems
    (empty = the copy matched). -/
def judgeLocalCopy (expect : List (String × String)) (replies : Option (List (String × String)))
    (traces : List (String × KeyTrace)) : List String := Id.run do
  if expect.isEmpty then return ["no keys to check"]
  let some rs := replies | return ["the replica's final reads were not observed (incomplete exchange)"]
  if rs.map (·.1) != expect.map (·.1) then return [s!"replies for {rs.map (·.1)} do not match the keys checked {expect.map (·.1)}"]
  let mut bad : List String := []
  for ((k, want), (_, got)) in expect.zip rs do
    let t := (traces.lookup k).getD {}
    let cls := classifyAnswer want got t
    let decLocal := (t.decision.map (traceField · "decision")) == some "local"
    if cls != .ok then
      bad := bad ++ [s!"{k}: {got} (want {want}) {cls.label}"]
    else if !(answeredLocally t && decLocal) then
      bad := bad ++ [s!"{k}: {got} correct but NOT from the replica's own copy (decision {(t.decision.map (traceField · "decision")).getD "(none)"}, answer {(t.answer.map (traceField · "reason")).getD "(none)"})"]
  return bad

-- ─── acceptance observation (review 2026-10-13 round 11) ──────────────────

/-- One `STAT <key> <value>` of a stats reply; `none` when absent. -/
def statField (out : String) (key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    let t := (line.replace "\r" "").trim
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

/-- What ACCEPTANCE requires of one node at one instant. Every field is
    required: `none` = not obtained (read failed, absent, or not parseable)
    and FAILS; an empty identity is stored as `none`; a number 0 is a value.
    One stats reply per node (one instant) plus one pod read per node. -/
structure NodeObs where
  ip : String              -- the address the stats were read from
  podIp : Option String    -- the pod's address: binds the stats to the pod
  uid : Option String      -- pod UID (recreation)
  container : Option String -- flared containerID (container restart)
  restarts : Option Nat
  boot : Option Nat        -- reconstruction_boot_id (this flared process)
  copyId : Option String   -- rocksdb_copy_id (this node's copy)
  epoch : Option String    -- rocksdb_source_epoch (the history)
  masterId : Option String -- rocksdb_master_id
  recon : Option Nat       -- reconstruction_started
  dump : Option Nat        -- rocksdb_wal_fallback_to_dump
  applied : Option Nat     -- repl_applied_lsn
  head : Option Nat        -- rocksdb_latest_sequence_number
  items : Option Nat       -- curr_items
  followEpoch : Option String -- repl_follow_source_epoch (required of the replica only)
  deriving Repr, BEq

private def nonEmpty (s : Option String) : Option String :=
  s.bind fun v => let t := v.trim; if t.isEmpty then none else some t

/-- Strict number: anything but plain digits is `none` (never 0). -/
private def strictNat (s : Option String) : Option Nat :=
  (nonEmpty s).bind fun v => if v.all Char.isDigit then v.toNat? else none

/-- `stats`: the node's ONE stats reply (`none` = not read). `pod`: the
    output of the jsonpath `{uid}|{podIP}|{containerID}|{restartCount}` of
    the flared container (`none` = not read); anything but exactly four
    fields leaves every pod field `none`. -/
def NodeObs.parse (ip : String) (stats pod : Option String) : NodeObs :=
  let st := fun k => stats.bind (statField · k)
  let parts := (pod.map fun p => (p.trim.splitOn "|")).getD []
  let pf := fun (i : Nat) => if parts.length == 4 then nonEmpty (parts[i]?) else none
  { ip, podIp := pf 1, uid := pf 0, container := pf 2,
    restarts := strictNat (pf 3),
    boot := strictNat (st "reconstruction_boot_id"),
    copyId := nonEmpty (st "rocksdb_copy_id"),
    epoch := nonEmpty (st "rocksdb_source_epoch"),
    masterId := nonEmpty (st "rocksdb_master_id"),
    recon := strictNat (st "reconstruction_started"),
    dump := strictNat (st "rocksdb_wal_fallback_to_dump"),
    applied := strictNat (st "repl_applied_lsn"),
    head := strictNat (st "rocksdb_latest_sequence_number"),
    items := strictNat (st "curr_items"),
    followEpoch := nonEmpty (st "repl_follow_source_epoch") }

/-- The fields of one node that were not obtained, plus a pod/stats binding
    failure (the stats came from another address than the pod's). -/
def NodeObs.missing (o : NodeObs) : List String :=
  let f := fun (n : String) (present : Bool) => if present then [] else [n]
  f "podIP" o.podIp.isSome ++ f "uid" o.uid.isSome ++ f "containerID" o.container.isSome ++
  f "restartCount" o.restarts.isSome ++ f "reconstruction_boot_id" o.boot.isSome ++
  f "rocksdb_copy_id" o.copyId.isSome ++ f "rocksdb_source_epoch" o.epoch.isSome ++
  f "rocksdb_master_id" o.masterId.isSome ++ f "reconstruction_started" o.recon.isSome ++
  f "rocksdb_wal_fallback_to_dump" o.dump.isSome ++ f "repl_applied_lsn" o.applied.isSome ++
  f "rocksdb_latest_sequence_number" o.head.isSome ++ f "curr_items" o.items.isSome ++
  (match o.podIp with
   | some p => if p != o.ip then [s!"stats read from {o.ip} but the pod is at {p}"] else []
   | none => [])

/-- One observation of the pair: replica and master at (about) one instant. -/
structure AccObs where
  replica : NodeObs
  master : NodeObs
  deriving Repr, BEq

/-- Everything missing in `o`, labelled (`tag` names the instant). -/
def AccObs.missing (tag : String) (o : AccObs) : List String :=
  (o.replica.missing.map (s!"{tag}: replica " ++ ·)) ++
  (if o.replica.followEpoch.isSome then [] else [s!"{tag}: replica repl_follow_source_epoch"]) ++
  (o.master.missing.map (s!"{tag}: master " ++ ·))

/-- "No rebuild, no restart, no recreation, same history" between two
    observations, judged only on COMPLETE observations (a missing field on
    either side is a failure, never "unchanged"). Same process (boot id,
    containerID, restartCount, pod UID) and same copy (copy id) for both
    nodes; same history (master's epoch and master id unchanged; the replica
    follows the master's epoch at both instants and its own epoch is
    unchanged); no reconstruction and no dump fallback on the replica;
    the replica's cursor never goes back. Returns the problems. -/
def judgeNoRebuild (tag0 tag1 : String) (a b : AccObs) : List String := Id.run do
  let miss := a.missing tag0 ++ b.missing tag1
  if !miss.isEmpty then return miss
  let mut bad : List String := []
  for (who, x, y) in [("replica", a.replica, b.replica), ("master", a.master, b.master)] do
    if x.uid != y.uid then bad := bad ++ [s!"{who}: pod recreated ({x.uid} -> {y.uid})"]
    if x.container != y.container || x.restarts != y.restarts then
      bad := bad ++ [s!"{who}: container restarted ({x.container}/{x.restarts} -> {y.container}/{y.restarts})"]
    if x.boot != y.boot then bad := bad ++ [s!"{who}: another flared process (boot id {x.boot} -> {y.boot})"]
    if x.copyId != y.copyId then bad := bad ++ [s!"{who}: another copy (copy id {x.copyId} -> {y.copyId})"]
  if a.master.epoch != b.master.epoch || a.master.masterId != b.master.masterId then
    bad := bad ++ [s!"the master's history changed (epoch {a.master.epoch} -> {b.master.epoch}, master_id {a.master.masterId} -> {b.master.masterId})"]
  if a.replica.followEpoch != a.master.epoch || b.replica.followEpoch != b.master.epoch then
    bad := bad ++ [s!"the replica does not follow the master's history ({tag0}: {a.replica.followEpoch} vs {a.master.epoch}; {tag1}: {b.replica.followEpoch} vs {b.master.epoch})"]
  if a.replica.epoch != b.replica.epoch then
    bad := bad ++ [s!"the replica's own source epoch changed ({a.replica.epoch} -> {b.replica.epoch})"]
  if a.replica.recon != b.replica.recon then bad := bad ++ [s!"a RECONSTRUCTION ran ({a.replica.recon} -> {b.replica.recon})"]
  if a.replica.dump != b.replica.dump then bad := bad ++ [s!"the WAL path fell back to a DUMP ({a.replica.dump} -> {b.replica.dump})"]
  if (b.replica.applied.getD 0) < (a.replica.applied.getD 0) then
    bad := bad ++ [s!"the applied cursor went BACKWARDS ({a.replica.applied} -> {b.replica.applied})"]
  return bad

/-- Caught up at one observation: complete, applied ≥ the master's head and
    the item counts equal (both obtained; never none == none). -/
def caughtUp (o : AccObs) : Bool :=
  (o.missing "x").isEmpty &&
  (match o.replica.applied, o.master.head, o.replica.items, o.master.items with
   | some ap, some hd, some si, some mi => ap ≥ hd && si == mi
   | _, _, _, _ => false)

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

/-- The PRECONDITION of the master-change activation test (review round 3,
    CI 37731207056 empty-source 6), judged on the replica's log read
    IMMEDIATELY BEFORE the hold is released (and again on the whole window):
    the replica accepted the map naming `newPod`; its activation was held
    before that (a held attempt precedes the acceptance); and no activation
    precedes the acceptance. A held attempt is not required AFTER the
    acceptance: the next attempt's source check sees the new master and is
    STOPPED instead of held. `none` = the precondition holds; `some why` =
    it does not (the run then says nothing about the behaviour after the new
    map). -/
def heldAcrossNewMap (lines : List String) (newPod : String) : Option String := Id.run do
  let idx := lines.zip (List.range lines.length)
  let some (_, acceptAt) := idx.find? fun (l, _) => contains l "node map accepted (version" && contains l s!" 0={newPod}."
    | return some s!"the replica never logged accepting a map that names {newPod}"
  if !(idx.any fun (l, i) => contains l "held by FLARE_TEST_ACTIVATION_HOLD_FILE" && i < acceptAt) then
    return some s!"no held activation attempt precedes the acceptance of the map naming {newPod} (line {acceptAt})"
  match idx.find? fun (l, i) => contains l "node activated (attempt" && i < acceptAt with
  | some (l, i) => return some s!"an activation (line {i}) precedes the acceptance of the map naming {newPod}: {l}"
  | none => return none

/-- R4 (continuous-replication 9) receiver-side evidence: the replica's
    own lines about the maps it applied and its role / balance / read source.
    Includes flared's versioned `node map accepted (version …); own …;
    masters: …` line (cluster.cc), which an earlier filter dropped. -/
def receiverMapLine (l : String) : Bool :=
  contains l "node map accepted (version" || contains l "node_balance" || contains l "reconstructing node map"
    || contains l "node map version" || contains l "topology" || contains l "node sync"
    || contains l "shifting node_role" || contains l "shifting node_state" || contains l "read source"

end FlareOperator.E2E.TraceMatch
