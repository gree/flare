/-
  PromotionIntentStoreCheckMain.lean — `promotion_intent_store_check NAMESPACE NAME`:
  a real-API check of the CAS adapter on ONE test ConfigMap. Not run by CI, not
  part of flare_unit, not linked into the operator.

  Scope guard: every kubectl call goes through `guarded`, which allows only
  get / create / replace / delete of configmap NAME in namespace NAMESPACE (the
  manifest file is parsed and must be that ConfigMap), nothing cluster-scoped.
  An existing ConfigMap of that name is never touched (the run aborts, nothing
  deleted). The ConfigMap is deleted at the end, also on failure.
  Output is TAP-like; exit 0 only if every check passed.
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

def validNs (s : String) : Bool :=
  !s.isEmpty && s.all fun c => c.isLower || c.isDigit || c == '-'

/-- The manifest at `path` is a ConfigMap `ns/name` and nothing else. -/
def manifestIsOurs (ns name path : String) : IO Bool := do
  try
    let j ← IO.ofExcept (Json.parse (← IO.FS.readFile path))
    let meta := j.getObjValD "metadata"
    return (j.getObjValD "kind").getStr?.toOption == some "ConfigMap" &&
      (meta.getObjValD "name").getStr?.toOption == some name &&
      (meta.getObjValD "namespace").getStr?.toOption == some ns
  catch _ => return false

def guarded (ns name : String) : Runner := fun args => do
  let refuse : IO (Except String String) :=
    return .error s!"guard: refused kubectl {args.take 3} (only configmap {ns}/{name})"
  match args with
  | ["get", "configmap", n, "-n", s, "-o", "json"] =>
    if n == name && s == ns then kubectlRunner args else refuse
  | ["delete", "configmap", n, "-n", s, "--ignore-not-found"] =>
    if n == name && s == ns then kubectlRunner args else refuse
  | [verb, "-f", path, "-n", s, "-o", "json"] =>
    if (verb == "create" || verb == "replace") && s == ns && (← manifestIsOurs ns name path)
    then kubectlRunner args else refuse
  | _ => refuse

structure Env where
  run : Runner
  ns : String
  name : String

def Env.client (e : Env) : IO Client := mkClient e.run e.ns e.name

def Env.delete (e : Env) : IO (Except String String) :=
  e.run ["delete", "configmap", e.name, "-n", e.ns, "--ignore-not-found"]

/-- Delete and recreate the ConfigMap holding `i`; returns a fresh client. -/
def Env.reset (e : Env) (i : Intent) : IO (Option Client) := do
  match ← e.delete with
  | .error _ => return none
  | .ok _ =>
    let c ← e.client
    match ← createIntent c i with
    | .done _ => return some c
    | _ => return none

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
  let _ ← e.delete
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

/-- Create the ConfigMap only if absent; `none` = abort without touching anything. -/
def preflight (e : Env) : IO (Option String) := do
  match ← (← e.client).get with
  | .notFound => return none
  | .found _ _ => return some s!"configmap {e.ns}/{e.name} already exists: not touching it"
  | .error m => return some s!"cannot read configmap {e.ns}/{e.name}: {m.take 200}"

def main (args : List String) : IO UInt32 := do
  let [ns, name] := args
    | IO.eprintln "usage: promotion_intent_store_check NAMESPACE NAME"; return 2
  unless validNs ns && name.startsWith namePrefix && validNs name do
    IO.eprintln s!"refused: namespace must be [a-z0-9-]+, name must start with {namePrefix}"
    return 2
  let e : Env := { run := guarded ns name, ns, name }
  if let some why ← preflight e then
    IO.println s!"Bail out! {why}"
    return 2
  let result ← try
      let ok ← runAll e
      pure (some ok)
    catch ex => do IO.eprintln s!"# aborted: {ex}"; pure none
  -- cleanup: runs on pass, fail and abort; only the ConfigMap this run created
  let d ← e.delete
  match d with
  | .ok _ => IO.println s!"# deleted configmap {ns}/{name}"
  | .error m => IO.println s!"# CLEANUP FAILED, delete configmap {ns}/{name} by hand: {m.take 200}"
  return if result == some true && d.toOption.isSome then 0 else 1

end FlareOperator.PromotionIntentStoreCheckMain

def main := FlareOperator.PromotionIntentStoreCheckMain.main
