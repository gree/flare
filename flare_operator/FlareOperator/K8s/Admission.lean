/-
  Admission review for `pods/eviction` (docs/design-node-operations-2026-10-19.md
  §2): parse the AdmissionReview the API server POSTs, and render the reply.

  The object of a `pods/eviction` CREATE is a policy/v1 (or v1beta1)
  Eviction: metadata.name / namespace of the POD and, optionally,
  deleteOptions.preconditions.uid. It carries NO pod labels, so the webhook
  is selected by namespace and resolves the pod itself (never objectSelector).

  A refusal carries HTTP code 429 in `status.code`: `kubectl drain` and the
  cluster autoscaler treat 429 as "retry later" (as for a PDB), which is what
  "refuse the first eviction, allow the retry once prepared" needs.
-/
import Lean.Data.Json

namespace FlareOperator.Admission

open Lean (Json)

structure EvictionReview where
  uid : String
  podName : String
  «namespace» : String
  dryRun : Bool
  preconditionUid : Option String
  deriving Repr, BEq

/-- Parse an AdmissionReview of a `pods/eviction` CREATE. -/
def parseEvictionReview (body : String) : Except String EvictionReview := do
  let j ← Json.parse body
  let req := j.getObjValD "request"
  let uid ← req.getObjValAs? String "uid"
  let sub := (req.getObjValAs? String "subResource").toOption.getD ""
  let res := (req.getObjValD "resource").getObjValD "resource" |>.getStr?.toOption |>.getD ""
  if res != "pods" || sub != "eviction" then
    throw s!"not a pods/eviction review ({res}/{sub})"
  let op := (req.getObjValAs? String "operation").toOption.getD ""
  if op != "CREATE" then throw s!"unexpected operation {op}"
  -- the pod is named by the request (and by the Eviction's metadata)
  let obj := req.getObjValD "object"
  let name := match (req.getObjValAs? String "name").toOption with
    | some n => if n.isEmpty then (obj.getObjValD "metadata" |>.getObjValAs? String "name").toOption.getD "" else n
    | none => (obj.getObjValD "metadata" |>.getObjValAs? String "name").toOption.getD ""
  let ns := match (req.getObjValAs? String "namespace").toOption with
    | some n => n
    | none => (obj.getObjValD "metadata" |>.getObjValAs? String "namespace").toOption.getD ""
  if name.isEmpty then throw "the eviction does not name a pod"
  let dry := (req.getObjValAs? Bool "dryRun").toOption.getD false
  let pre := ((obj.getObjValD "deleteOptions").getObjValD "preconditions").getObjValAs? String "uid" |>.toOption
  return { uid, podName := name, «namespace» := ns, dryRun := dry, preconditionUid := pre }

/-- The reply (admission.k8s.io/v1). A refusal carries code 429 + message. -/
def reviewResponse (uid : String) (allowed : Bool) (message : String) : String :=
  let status : Json := if allowed then Json.mkObj [] else
    Json.mkObj [("code", Json.num 429), ("reason", Json.str "TooManyRequests"), ("message", Json.str message)]
  let resp := Json.mkObj ([("uid", Json.str uid), ("allowed", Json.bool allowed)] ++ (if allowed then [] else [("status", status)]))
  (Json.mkObj [("apiVersion", Json.str "admission.k8s.io/v1"), ("kind", Json.str "AdmissionReview"), ("response", resp)]).compress

/-- A reply for a review that could not be parsed: refused (fail closed). -/
def malformedResponse (body : String) (why : String) : String :=
  let uid := match Json.parse body with
    | .ok j => ((j.getObjValD "request").getObjValAs? String "uid").toOption.getD ""
    | .error _ => ""
  reviewResponse uid false s!"flare: malformed admission review ({why})"

end FlareOperator.Admission
