/-
  PromotionIntentStoreCheckMain.lean — `promotion_intent_store_check NAMESPACE PREFIX`:
  a real-API check of the CAS adapter on ONE test ConfigMap. Not run by CI, not
  part of flare_unit, not linked into the operator.

  Ownership: the name is PREFIX-<random hex> (run-unique), the object carries the
  label flare-cprime-cas-test/run=<run id>. Ownership is established by CREATE
  first (no initial delete / reset); on AlreadyExists nothing is touched and the
  run exits. The uid of every object this run created is recorded from the
  create reply; EVERY delete (also the final cleanup) is conditional on that uid:
  a GET must show it, then `kubectl delete --raw` carries a DeleteOptions
  precondition uid. There is no name-only delete anywhere.

  Scope guard: every kubectl call goes through `guarded` (get / create / replace
  of configmap NAME in NAMESPACE, and the uid-preconditioned raw delete of that
  one path), nothing cluster-scoped. Output is TAP-like; exit 0 only if every
  check passed and the cleanup succeeded.
-/
import FlareOperator.StateMachine.PromotionIntentKube
import FlareOperator.StateMachine.PromotionIntentChecks

namespace FlareOperator.PromotionIntentStoreCheckMain

open FlareOperator.PromotionIntent
open FlareOperator.PromotionIntentStore
open FlareOperator.PromotionIntentKube
open FlareOperator.PromotionIntentChecks
open Lean

def namePrefix : String := "flare-cprime-cas-test"
def labelKey : String := "flare-cprime-cas-test/run"

def validNs (s : String) : Bool :=
  !s.isEmpty && s.all fun c => c.isLower || c.isDigit || c == '-'

def hex (bs : ByteArray) : String :=
  bs.foldl (fun acc b => acc ++ (Nat.toDigits 16 (b.toNat + 256)).asString.drop 1) ""

/-- The manifest at `path` is a ConfigMap `ns/name` and nothing else. -/
def manifestIsOurs (ns name path : String) : IO Bool := do
  try
    let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
    let meta := j.getObjValD "metadata"
    return (j.getObjValD "kind").getStr?.toOption == some "ConfigMap" &&
      (meta.getObjValD "name").getStr?.toOption == some name &&
      (meta.getObjValD "namespace").getStr?.toOption == some ns
  catch _ => return false

def rawPath (ns name : String) : String := s!"/api/v1/namespaces/{ns}/configmaps/{name}"

def deleteBody (uid : String) : String :=
  (Json.mkObj [("apiVersion", Json.str "v1"), ("kind", Json.str "DeleteOptions"),
    ("preconditions", Json.mkObj [("uid", Json.str uid)])]).compress

/-- The only delete: raw DELETE of the one path whose body file holds a uid precondition. -/
def deleteIsPreconditioned (path : String) : IO Bool := do
  try
    let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
    let u := ((j.getObjValD "preconditions").getObjValD "uid").getStr?.toOption.getD ""
    return (j.getObjValD "kind").getStr?.toOption == some "DeleteOptions" && !u.isEmpty
  catch _ => return false

/-- `owned` records the uid of each object this run's create returned. -/
def guarded (ns name : String) (owned : IO.Ref (Option String)) : Runner := fun args => do
  let refuse : IO (Except String String) :=
    return .error s!"guard: refused kubectl {args.take 3} (only configmap {ns}/{name})"
  match args with
  | ["get", "configmap", n, "-n", s, "-o", "json"] =>
    if n == name && s == ns then kubectlRunner args else refuse
  | ["delete", "--raw", p, "-f", path] =>
    if p == rawPath ns name && (← deleteIsPreconditioned path) then kubectlRunner args else refuse
  | [verb, "-f", path, "-n", s, "-o", "json"] =>
    if (verb == "create" || verb == "replace") && s == ns && (← manifestIsOurs ns name path) then
      let r ← kubectlRunner args
      if verb == "create" then
        if let .ok out := r then
          if let .ok o := parseObj out then owned.set (some o.uid)
      return r
    else refuse
  | _ => refuse

structure Env where
  run : Runner
  ns : String
  name : String
  runId : String
  owned : IO.Ref (Option String)

def Env.client (e : Env) : IO Client :=
  mkClient e.run e.ns e.name [(labelKey, e.runId)]

/-- Delete the object this run created, only if it still has that uid.
    Nothing owned -> nothing to delete. A GET showing another uid, or any doubt, deletes nothing. -/
def Env.delete (e : Env) : IO (Except String String) := do
  let some uid ← e.owned.get | return .ok "nothing owned"
  match ← e.run ["get", "configmap", e.name, "-n", e.ns, "-o", "json"] with
  | .error m =>
    if isNotFound m then
      e.owned.set none
      return .ok "already gone"
    else return .error m
  | .ok out =>
    match parseObj out with
    | .error m => return .error s!"unreadable: {m}"
    | .ok o =>
      if o.uid != uid then
        return .error s!"uid is {o.uid}, not ours ({uid}): not deleting"
      else
        let pid ← IO.Process.getPID
        let path := s!"/tmp/flare-intent-del-{pid}-{← IO.monoNanosNow}.json"
        try IO.FS.writeFile path (deleteBody uid) catch m => return .error s!"cannot write body: {m}"
        let r ← e.run ["delete", "--raw", rawPath e.ns e.name, "-f", path]
        try IO.FS.removeFile path catch _ => pure ()
        if r.toOption.isSome then e.owned.set none
        return r

/-- Establish ownership by create. `none` = ours; `some why` = abort, nothing deleted.
    A create whose reply was lost (error): adopt the object only if the unique name
    carries this run's label, else leave it alone. -/
def claim (e : Env) (c : Client) (i : Intent) : IO (Option String) := do
  match ← c.create (encode i) with
  | .ok _ => return none
  | .alreadyExists => return some s!"configmap {e.ns}/{e.name} already exists: not touching it"
  | .error _ =>
    match ← e.run ["get", "configmap", e.name, "-n", e.ns, "-o", "json"] with
    | .ok out =>
      let lab := ((Json.parse out).toOption.getD Json.null |>.getObjValD "metadata"
        |>.getObjValD "labels" |>.getObjValD labelKey).getStr?.toOption
      match parseObj out, lab with
      | .ok o, some l =>
        if l == e.runId then
          e.owned.set (some o.uid)
          return none
        else return some s!"configmap {e.ns}/{e.name} exists with another run label: not touching it"
      | _, _ => return some s!"configmap {e.ns}/{e.name} exists, not recognised: not touching it"
    | .error m => return some s!"create outcome unknown ({m.take 200}); check configmap {e.ns}/{e.name} by hand"

/-- Delete our object (uid-conditional) and create a fresh one holding `i`
    (new uid, recorded); returns a fresh client. AlreadyExists -> none, nothing touched. -/
def Env.reset (e : Env) (i : Intent) : IO (Option Client) := do
  match ← e.delete with
  | .error _ => return none
  | .ok _ =>
    let c ← e.client
    match ← claim e c i with
    | none => return some c
    | some _ => return none

def Env.stored (e : Env) : IO (Option Intent) := do
  match ← readIntent (← e.client) with
  | .settled i => return some i
  | _ => return none

def commit1 (c : Client) : IO Result := commitIntent c ref7 (.leader 1) members0 (atS 19)
def cancel1 (c : Client) : IO Result := cancelIntent c ref7 (.leader 1) (atS 0)

/-- one race round: a commit and a cancel from two separate clients, concurrently -/
def raceOnce (e : Env) : IO Bool := do
  let some _ ← e.reset prepared | return false
  let a ← e.client
  let b ← e.client
  let ta ← IO.asTask (commit1 a) (prio := .dedicated)
  let tb ← IO.asTask (cancel1 b) (prio := .dedicated)
  let ra ← IO.ofExcept (← IO.wait ta)
  let rb ← IO.ofExcept (← IO.wait tb)
  let fin ← e.stored
  -- exactly one wins; the loser is refused; the store holds the winner's record
  let commitWon := ra == .done c7 && rb == .refused .alreadyCommitted c7 && fin == some c7
  let cancelWon := rb == .done x7 && ra == .refused .alreadyCancelled x7 && fin == some x7
  return commitWon || cancelWon

def tRace (e : Env) : IO Bool := do
  let mut ok := true
  for _ in [0:5] do
    if !(← raceOnce e) then ok := false
  return ok

def tStale (e : Env) : IO Bool := do
  let some c ← e.reset prepared | return false
  let adopted := { prepared with fence := 2 }
  let a ← adopt c 2
  let old ← commit1 c
  let oldCancel ← cancel1 c
  return a == .done adopted && old == .refused .staleLeader adopted &&
    oldCancel == .refused .staleLeader adopted && (← e.stored) == some adopted

/-- the write takes effect, the reply is forgotten: the re-read decides -/
def tLostReply (e : Env) : IO Bool := do
  let some c ← e.reset prepared | return false
  let lossy := { c with replace := fun rv v => do
    let _ ← c.replace rv v
    return .error "reply forgotten" }
  let r ← commit1 lossy
  let again ← commit1 c
  return r == .done c7 && again == .settled c7 && (← e.stored) == some c7

/-- deleted + recreated under the same name: a different object, refused -/
def tRecreated (e : Env) : IO Bool := do
  let some c ← e.reset prepared | return false
  let _ ← readIntent c                          -- pins the uid
  let some _ ← e.reset prepared | return false  -- same name, new uid
  let r ← commit1 c
  let w ← c.replace "1" (encode c7)             -- a stale pinned write: never ok
  let refused := match r with | .unknown _ => true | _ => false
  let notOk := match w with | .ok _ => false | _ => true
  return refused && notOk && (← e.stored) == some prepared

def tNotFound (e : Env) : IO Bool := do
  let some _ ← e.reset prepared | return false
  let .ok _ ← e.delete | return false
  let c ← e.client
  let g ← match ← c.get with | .notFound => pure true | _ => pure false
  let r ← commit1 c
  return g && r == .absent

def say (n : Nat) (ok : Bool) (what : String) : IO Unit :=
  IO.println s!"{if ok then "ok" else "not ok"} {n} - {what}"

def runAll (e : Env) : IO Bool := do
  IO.println "1..5"
  let rs := [("two writers race commit vs cancel (5 rounds): exactly one terminal, the loser refused", tRace e),
    ("stale-fence writer refused for commit and cancel, record unchanged", tStale e),
    ("lost reply after the write: the re-read decides (done), a repeat is settled", tLostReply e),
    ("deleted + recreated (uid change) refused, new object untouched, stale pinned write not ok", tRecreated e),
    ("NotFound is absent, not an error", tNotFound e)]
  let mut all := true
  let mut n := 0
  for (what, t) in rs do
    n := n + 1
    let ok ← try t catch ex => do IO.eprintln s!"# exception: {ex}"; pure false
    say n ok what
    if !ok then all := false
  return all

def main (args : List String) : IO UInt32 := do
  let [ns, pfx] := args
    | IO.eprintln "usage: promotion_intent_store_check NAMESPACE NAME_PREFIX"; return 2
  unless validNs ns && pfx.startsWith namePrefix && validNs pfx do
    IO.eprintln s!"refused: namespace must be [a-z0-9-]+, name prefix must start with {namePrefix}"
    return 2
  let runId := hex (← IO.getRandomBytes 8)
  let name := (pfx.dropRightWhile (· == '-')) ++ "-" ++ runId
  let owned ← IO.mkRef (none : Option String)
  let e : Env := { run := guarded ns name owned, ns, name, runId, owned }
  IO.println s!"# name {ns}/{name} run {runId}"
  if let some why ← claim e (← e.client) prepared then
    IO.println s!"Bail out! {why}"
    return 2
  IO.println s!"# owned uid {(← owned.get).getD "?"}"
  let result ← try
      let ok ← runAll e
      pure (some ok)
    catch ex => do IO.eprintln s!"# aborted: {ex}"; pure none
  -- cleanup: runs on pass, fail and abort; deletes only the uid this run created
  let d ← e.delete
  match d with
  | .ok m => IO.println s!"# cleanup: {m}; configmap {ns}/{name} (uid-conditional delete)"
  | .error m => IO.println s!"# CLEANUP FAILED: configmap {ns}/{name} not deleted (it may be ours or not; check its uid/label {labelKey}={runId} before deleting by hand): {m.take 200}"
  return if result == some true && d.toOption.isSome then 0 else 1

end FlareOperator.PromotionIntentStoreCheckMain

def main := FlareOperator.PromotionIntentStoreCheckMain.main
