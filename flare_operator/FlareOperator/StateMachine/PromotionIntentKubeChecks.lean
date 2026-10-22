/-
  PromotionIntentKubeChecks.lean — the kubectl -> Client mapping against canned
  kubectl outputs (stdout JSON / the "kubectl failed (exit 1): <stderr>" wrapper
  of Kubectl.kubectl). The texts follow kubectl's documented output formats and
  were NOT captured from a cluster by these checks; the real API run is
  `promotion_intent_store_check`.
-/
import FlareOperator.StateMachine.PromotionIntentKube
import FlareOperator.StateMachine.PromotionIntentChecks

namespace FlareOperator.PromotionIntentKubeChecks

open FlareOperator.PromotionIntent
open FlareOperator.PromotionIntentStore
open FlareOperator.PromotionIntentKube
open FlareOperator.PromotionIntentChecks
open Lean

def notFoundErr : String :=
  "kubectl failed (exit 1): Error from server (NotFound): configmaps \"cas-t\" not found\n"
def conflictErr : String :=
  "kubectl failed (exit 1): Error from server (Conflict): error when replacing \"/tmp/flare-intent-1-2.json\": Operation cannot be fulfilled on configmaps \"cas-t\": the object has been modified; please apply your changes to the latest version and try again\n"
def uidPreconditionErr : String :=
  "kubectl failed (exit 1): Error from server (Conflict): error when replacing \"/tmp/flare-intent-1-3.json\": Operation cannot be fulfilled on configmaps \"cas-t\": Precondition failed: UID in precondition: 1111, UID in object meta: 2222\n"
def existsErr : String :=
  "kubectl failed (exit 1): Error from server (AlreadyExists): error when creating \"/tmp/flare-intent-1-4.json\": configmaps \"cas-t\" already exists\n"
def refusedErr : String :=
  "kubectl failed (exit 1): The connection to the server 127.0.0.1:6443 was refused - did you specify the right host and port?\n"
def forbiddenErr : String :=
  "kubectl failed (exit 1): Error from server (Forbidden): configmaps \"cas-t\" is forbidden: User \"system:serviceaccount:flare-dev:x\" cannot get resource \"configmaps\" in API group \"\" in the namespace \"flare-dev\"\n"
def timeoutErr : String := "kubectl timed out after 30s (args: [get, configmap, cas-t, -n])"
/-- a not-found elsewhere in the text is not NotFound -/
def quotedErr : String :=
  "kubectl failed (exit 1): Unable to connect to the server: configmap \"x\" not found in cache"

def obj (uid rv record : String) : String :=
  (Json.mkObj [("apiVersion", "v1"), ("kind", "ConfigMap"),
    ("metadata", Json.mkObj [("name", "cas-t"), ("namespace", "flare-dev"),
      ("uid", uid), ("resourceVersion", rv), ("creationTimestamp", "2026-10-22T00:00:00Z")]),
    ("data", Json.mkObj [("record", record)])]).pretty

/-- A runner replaying canned replies; records each argv and the manifest file it was given. -/
def script (replies : List (Except String String)) :
    IO (Runner × IO.Ref (List (List String)) × IO.Ref (List String)) := do
  let q ← IO.mkRef replies
  let seen ← IO.mkRef ([] : List (List String))
  let files ← IO.mkRef ([] : List String)
  let run : Runner := fun args => do
    seen.modify (· ++ [args])
    if args.length > 2 && args[1]? == some "-f" then
      files.modify (· ++ [(← IO.FS.readFile (args.getD 2 ""))])
    match ← q.get with
    | [] => return .error "script exhausted"
    | r :: rest => q.set rest; return r
  return (run, seen, files)

def getOnce (r : Except String String) : IO GetResult := do
  let (run, _, _) ← script [r]
  let c ← mkClient run "flare-dev" "cas-t"
  c.get

def isErr : GetResult → Bool | .error _ => true | _ => false

def tGetMap : IO Bool := do
  let rec' := encode prepared
  let ok ← getOnce (.ok (obj "1111" "42" rec'))
  let found := match ok with | .found v rv => v == rec' && rv == "42" | _ => false
  let nf ← getOnce (.error notFoundErr)
  let notFound := match nf with | .notFound => true | _ => false
  let mut errs := true
  for e in [refusedErr, forbiddenErr, timeoutErr, quotedErr] do
    errs := errs && isErr (← getOnce (.error e))
  return found && notFound && errs

def tGetBad : IO Bool := do
  let a ← getOnce (.ok "not json")
  let b ← getOnce (.ok "{\"metadata\":{\"uid\":\"1\",\"resourceVersion\":\"2\"}}")
  let c ← getOnce (.ok "{\"metadata\":{\"uid\":\"\",\"resourceVersion\":\"2\"},\"data\":{\"record\":\"x\"}}")
  let d ← getOnce (.ok "{\"metadata\":{\"name\":\"x\"},\"data\":{\"record\":\"x\"}}")
  return isErr a && isErr b && isErr c && isErr d

def tUid : IO Bool := do
  let rec' := encode prepared
  let (run, _, _) ← script [.ok (obj "1111" "5" rec'), .ok (obj "1111" "6" rec'), .ok (obj "2222" "1" rec'),
    .ok (obj "1111" "7" rec')]
  let c ← mkClient run "flare-dev" "cas-t"
  let g1 ← c.get
  let g2 ← c.get
  let g3 ← c.get                -- recreated: another uid
  let g4 ← c.get                -- the pinned uid is never replaced by the newcomer
  let found := fun (g : GetResult) => match g with | .found _ _ => true | _ => false
  return found g1 && found g2 && isErr g3 && found g4

def tReplaceMap : IO Bool := do
  let rec' := encode prepared
  let (run, seen, files) ← script [.ok (obj "1111" "5" rec'), .ok (obj "1111" "6" (encode c7)),
    .error conflictErr, .error uidPreconditionErr, .error notFoundErr, .error timeoutErr,
    .ok (obj "2222" "9" (encode c7))]
  let c ← mkClient run "flare-dev" "cas-t"
  let _ ← c.get
  let ok ← c.replace "5" (encode c7)
  let c1 ← c.replace "6" (encode c7)
  let c2 ← c.replace "6" (encode c7)
  let nf ← c.replace "6" (encode c7)
  let to ← c.replace "6" (encode c7)
  let other ← c.replace "6" (encode c7)       -- reply from another uid
  let isOk := match ok with | .ok rv => rv == "6" | _ => false
  let isConf := fun (r : ReplaceResult) => match r with | .conflict => true | _ => false
  let isE := fun (r : ReplaceResult) => match r with | .error _ => true | _ => false
  -- the replace manifest carries namespace, resourceVersion and uid
  let some mf := (← files.get)[0]? | return false
  let j := (Json.parse mf).toOption.getD Json.null
  let meta := j.getObjValD "metadata"
  let argOk := (← seen.get)[1]?.map (·.take 2) == some ["replace", "-f"] &&
    (← seen.get)[1]?.map (·.drop 3) == some ["-n", "flare-dev", "-o", "json"]
  return isOk && isConf c1 && isConf c2 && isE nf && isE to && isE other && argOk &&
    meta.getObjValD "resourceVersion" == "5" && meta.getObjValD "uid" == "1111" &&
    meta.getObjValD "namespace" == "flare-dev" && meta.getObjValD "name" == "cas-t" &&
    (j.getObjValD "data").getObjValD "record" == Json.str (encode c7)

def tCreateMap : IO Bool := do
  let rec' := encode prepared
  let (run, _, files) ← script [.ok (obj "1111" "1" rec'), .error existsErr, .error timeoutErr]
  -- fresh (unpinned) client per call: the create is sent
  let a ← (← mkClient run "flare-dev" "cas-t").create rec'
  let b ← (← mkClient run "flare-dev" "cas-t").create rec'
  let d ← (← mkClient run "flare-dev" "cas-t").create rec'
  let aOk := match a with | .ok rv => rv == "1" | _ => false
  let bEx := match b with | .alreadyExists => true | _ => false
  let dEr := match d with | .error _ => true | _ => false
  -- a create manifest has no resourceVersion / uid
  let some mf := (← files.get)[0]? | return false
  let meta := ((Json.parse mf).toOption.getD Json.null).getObjValD "metadata"
  return aOk && bEx && dEr && meta.getObjValD "resourceVersion" == Json.null &&
    meta.getObjValD "uid" == Json.null

/-- a pinned client never sends create: the runner sees only gets, and no write
    follows a uid mismatch (the object was deleted and recreated under the name) -/
def tCreatePinned : IO Bool := do
  let rec' := encode prepared
  let (run, seen, files) ← script [.ok (obj "1111" "1" rec'),   -- pins 1111
    .ok (obj "1111" "2" rec'),                                  -- create -> alreadyExists
    .ok (obj "2222" "1" rec'),                                  -- recreated: error
    .error notFoundErr,                                         -- gone: error, not re-created
    .error timeoutErr, .ok "not json"]
  let c ← mkClient run "flare-dev" "cas-t"
  let _ ← c.get
  let r1 ← c.create rec'
  let r2 ← c.create rec'
  let r3 ← c.create rec'
  let r4 ← c.create rec'
  let r5 ← c.create rec'
  let e1 := match r1 with | .alreadyExists => true | _ => false
  let isE := fun (r : CreateResult) => match r with | .error _ => true | _ => false
  let calls ← seen.get
  return e1 && isE r2 && isE r3 && isE r4 && isE r5 && calls.length == 6 &&
    calls.all (·.head? == some "get") && (← files.get).isEmpty

/-- the record text survives the manifest (newlines, quotes, backslashes, unicode) -/
def tManifest : IO Bool := do
  let nasty := "a\nb \"q\" \\ é\t: - #|"
  let j := (Json.parse (manifest "n" "x" nasty none none)).toOption.getD Json.null
  return (j.getObjValD "data").getObjValD "record" == Json.str nasty &&
    (j.getObjValD "kind") == "ConfigMap"

/-- adapter over the kubectl client: a 409 re-reads, decides on what is there -/
def tAdapter : IO Bool := do
  let p := encode prepared
  let (run, seen, _) ← script [.ok (obj "1111" "5" p), .error conflictErr,
    .ok (obj "1111" "6" (encode x7)),
    -- second client: restart reads the terminal record
    .ok (obj "1111" "7" (encode x7))]
  let c ← mkClient run "flare-dev" "cas-t"
  let r ← commitIntent c ref7 (.leader 1) members0 (atS 19)
  let (run2, _, _) ← script [.ok (obj "1111" "7" (encode x7))]
  let c2 ← mkClient run2 "flare-dev" "cas-t"
  let r2 ← readIntent c2
  -- get, replace (409), get again: nothing else was sent
  let verbs := (← seen.get).map (·.head?)
  return r == .refused .alreadyCancelled x7 && r2 == .settled x7 &&
    verbs == [some "get", some "replace", some "get"]

def checks : IO (List (String × Bool)) := do
  return [
    ("kube: get NotFound -> notFound; refused / Forbidden / timeout / a quoted 'not found' -> error", ← tGetMap),
    ("kube: get with unparsable JSON, no data.record, empty uid, no uid -> error", ← tGetBad),
    ("kube: a different metadata.uid under the same name is refused, the pinned uid stays", ← tUid),
    ("kube: replace 409 (modified, uid precondition) -> conflict; NotFound / timeout / other uid -> error; manifest carries rv + uid + ns", ← tReplaceMap),
    ("kube: create AlreadyExists -> alreadyExists; timeout -> error; manifest has no rv / uid", ← tCreateMap),
    ("kube: pinned client never sends create (6 calls, all get, no manifest): same uid -> alreadyExists; other uid / gone / timeout / junk -> error", ← tCreatePinned),
    ("kube: the record text survives the manifest unchanged", ← tManifest),
    ("kube: adapter over the kubectl client: 409 -> re-read -> refused against the terminal record, nothing else sent", ← tAdapter)
  ]

end FlareOperator.PromotionIntentKubeChecks
