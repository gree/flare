/-
  PromotionIntentKube.lean — the concrete `PromotionIntentStore.Client` on the
  operator's existing kubectl bridge (`Kubectl.kubectl`: argv-direct, 30 s wall),
  one ConfigMap, the same get / create / replace-with-resourceVersion the
  history ConfigMap uses. NOT wired: nothing in Main or the reconcile loop calls
  it; only the checks and the `promotion_intent_store_check` executable.

  Mapping (kubectl wraps stderr as "kubectl failed (exit N): <stderr>"):
    get      NotFound            -> notFound   (any other failure -> error)
    create   AlreadyExists       -> alreadyExists
    replace  Conflict (409)      -> conflict   (NotFound / anything else -> error)
  Every reply that names an object is checked against the metadata.uid pinned by
  the first read or create of this client: a different uid under the same name
  (deleted + recreated) is an `error` forever after, never found / ok. The uid is
  also sent in the replace manifest, so the API server itself refuses (409) a
  write meant for another incarnation.
-/
import FlareOperator.StateMachine.PromotionIntentStore
import FlareOperator.Kubectl
import Lean.Data.Json

namespace FlareOperator.PromotionIntentKube

open FlareOperator.PromotionIntentStore
open Lean

/-- Runs kubectl with argv and returns stdout, or the wrapped error text. -/
abbrev Runner := List String → IO (Except String String)

def contains (h n : String) : Bool := (h.splitOn n).length > 1

/-- `kubectl get` failure that affirmatively says the object does not exist.
    Only the API's own `(NotFound)` status counts; a connection failure or a
    quoted "not found" elsewhere does not. -/
def isNotFound (e : String) : Bool := contains e "(NotFound)"
def isConflict (e : String) : Bool := contains e "(Conflict)"
def isAlreadyExists (e : String) : Bool := contains e "(AlreadyExists)"

/-- (uid, resourceVersion, data.record) of a ConfigMap printed with `-o json`. -/
structure Obj where
  uid : String
  rv : String
  record : Option String
  deriving Repr, DecidableEq, BEq

def parseObj (out : String) : Except String Obj := do
  let j ← Json.parse out
  let meta ← j.getObjVal? "metadata"
  let uid ← meta.getObjValAs? String "uid"
  let rv ← meta.getObjValAs? String "resourceVersion"
  if uid.isEmpty || rv.isEmpty then throw "empty uid or resourceVersion"
  let record := (j.getObjValD "data").getObjValD "record" |>.getStr?.toOption
  return { uid, rv, record }

/-- The ConfigMap manifest (JSON is YAML). `rv` / `uid` pin the write. -/
def manifest (ns name record : String) (rv uid : Option String) : String :=
  let meta : List (String × Json) :=
    [("name", Json.str name), ("namespace", Json.str ns)] ++
    (rv.map fun r => [("resourceVersion", Json.str r)]).getD [] ++
    (uid.map fun u => [("uid", Json.str u)]).getD []
  (Json.mkObj [("apiVersion", Json.str "v1"), ("kind", Json.str "ConfigMap"),
    ("metadata", Json.mkObj meta),
    ("data", Json.mkObj [("record", Json.str record)])]).compress

/-- uid check: the first uid seen is pinned; another one is refused. -/
def checkUid (pin : IO.Ref (Option String)) (uid : String) : IO (Except String Unit) := do
  match ← pin.get with
  | none => pin.set (some uid); return .ok ()
  | some u =>
    if u == uid then return .ok ()
    else return .error s!"object uid changed ({u} -> {uid}): deleted and recreated, not the same object"

def mapGet (pin : IO.Ref (Option String)) (r : Except String String) : IO GetResult := do
  match r with
  | .error e => return if isNotFound e then .notFound else .error e
  | .ok out =>
    match parseObj out with
    | .error e => return .error s!"unreadable object: {e}"
    | .ok o =>
      match ← checkUid pin o.uid with
      | .error e => return .error e
      | .ok () =>
        match o.record with
        | some v => return .found v o.rv
        | none => return .error "object has no data.record"

def mapCreate (pin : IO.Ref (Option String)) (r : Except String String) : IO CreateResult := do
  match r with
  | .error e => return if isAlreadyExists e then .alreadyExists else .error e
  | .ok out =>
    match parseObj out with
    | .error e => return .error s!"create reply unreadable: {e}"
    | .ok o =>
      match ← checkUid pin o.uid with
      | .error e => return .error e
      | .ok () => return .ok o.rv

def mapReplace (pin : IO.Ref (Option String)) (r : Except String String) : IO ReplaceResult := do
  match r with
  | .error e => return if isConflict e then .conflict else .error e
  | .ok out =>
    match parseObj out with
    | .error e => return .error s!"replace reply unreadable: {e}"
    | .ok o =>
      match ← checkUid pin o.uid with
      | .error e => return .error e
      | .ok () => return .ok o.rv

/-- Run kubectl on a manifest in a unique temp file (no stdin, no shell). -/
def withManifest (run : Runner) (verb : String) (ns text : String) :
    IO (Except String String) := do
  let pid ← IO.Process.getPID
  let path := s!"/tmp/flare-intent-{pid}-{← IO.monoNanosNow}.json"
  try IO.FS.writeFile path text catch e => return .error s!"cannot write manifest: {e}"
  let r ← run [verb, "-f", path, "-n", ns, "-o", "json"]
  try IO.FS.removeFile path catch _ => pure ()
  return r

/-- A client for ConfigMap `ns/name` only: every call names that object and
    that namespace. A fresh client has no pinned uid (a restarted process pins
    on its first read). -/
def mkClient (run : Runner) (ns name : String) : IO Client := do
  let pin ← IO.mkRef (none : Option String)
  return {
    get := do mapGet pin (← run ["get", "configmap", name, "-n", ns, "-o", "json"])
    create := fun v => do mapCreate pin (← withManifest run "create" ns (manifest ns name v none none))
    replace := fun rv v => do
      let uid ← pin.get
      -- without a pinned uid (no read yet) the write is still resourceVersion-guarded
      mapReplace pin (← withManifest run "replace" ns (manifest ns name v (some rv) uid)) }

def kubectlRunner : Runner := FlareOperator.Kubectl.kubectl

end FlareOperator.PromotionIntentKube
