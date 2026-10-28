/-
  K8s/Admission.lean — the AdmissionReview the API server POSTs to the
  node-guard webhook (A0 stage 6b, flare-ci-inputs/decisions/A0-DESIGN-rc68.md),
  and the reply. The reply format is the SAF-10 branch's; the request side is
  general (DELETE of a pod, UPDATE of a StatefulSet or its scale subresource).
-/
import Lean.Data.Json

namespace FlareOperator.Admission

open Lean (Json)

/-- The fields of a review the node guard decides on. -/
structure Review where
  uid : String
  operation : String
  /-- resource.resource, e.g. "pods", "statefulsets" -/
  resource : String
  subResource : String := ""
  name : String
  «namespace» : String
  /-- userInfo.username of the requester -/
  username : String := ""
  dryRun : Bool := false
  object : Json := Json.null
  oldObject : Json := Json.null
  /-- the DeleteOptions of a DELETE -/
  options : Json := Json.null
  deriving Inhabited

/-- Parse an AdmissionReview (admission.k8s.io/v1). -/
def parseReview (body : String) : Except String Review := do
  let j ← Json.parse body
  let req := j.getObjValD "request"
  let uid ← req.getObjValAs? String "uid"
  let str := fun (v : Json) (k : String) => (v.getObjValAs? String k).toOption.getD ""
  let res := str (req.getObjValD "resource") "resource"
  let obj := req.getObjValD "object"
  let old := req.getObjValD "oldObject"
  let meta := fun (v : Json) (k : String) => str (v.getObjValD "metadata") k
  let name := match str req "name" with
    | "" => match meta old "name" with | "" => meta obj "name" | n => n
    | n => n
  let ns := match str req "namespace" with
    | "" => match meta old "namespace" with | "" => meta obj "namespace" | n => n
    | n => n
  return { uid, operation := str req "operation", resource := res, subResource := str req "subResource",
           name, «namespace» := ns, username := str (req.getObjValD "userInfo") "username",
           dryRun := (req.getObjValAs? Bool "dryRun").toOption.getD false,
           object := obj, oldObject := old, options := req.getObjValD "options" }

/-- `gracePeriodSeconds` of a DELETE's options (none = the pod's own). -/
def Review.gracePeriodSeconds (r : Review) : Option Nat :=
  (r.options.getObjValAs? Nat "gracePeriodSeconds").toOption

/-- The pod's UID, hostname and subdomain (the deleted pod is `oldObject`). -/
def Review.podUid (r : Review) : String :=
  ((r.oldObject.getObjValD "metadata").getObjValAs? String "uid").toOption.getD ""

def Review.podHostname (r : Review) : String :=
  ((r.oldObject.getObjValD "spec").getObjValAs? String "hostname").toOption.getD ""

def Review.podSubdomain (r : Review) : String :=
  ((r.oldObject.getObjValD "spec").getObjValAs? String "subdomain").toOption.getD ""

/-- spec.nodeName of the deleted pod. -/
def Review.podNodeName (r : Review) : String :=
  ((r.oldObject.getObjValD "spec").getObjValAs? String "nodeName").toOption.getD ""

/-- The deleted pod already has a deletionTimestamp (it is terminating). -/
def Review.podTerminating (r : Review) : Bool :=
  match (r.oldObject.getObjValD "metadata").getObjVal? "deletionTimestamp" with
  | .ok Lean.Json.null => false
  | .ok _ => true
  | .error _ => false

/-- An annotation of the deleted pod. -/
def Review.podAnnotation (r : Review) (key : String) : Option String :=
  (((r.oldObject.getObjValD "metadata").getObjValD "annotations").getObjValAs? String key).toOption

/-- spec.replicas of the new and the old object (a StatefulSet, or an
    autoscaling/v1 Scale for the scale subresource). -/
def Review.replicas (r : Review) : Option Nat × Option Nat :=
  let rep := fun (v : Json) => ((v.getObjValD "spec").getObjValAs? Nat "replicas").toOption
  (rep r.object, rep r.oldObject)

/-- The reply. A refusal carries `code` (403 Forbidden by default; 429 makes
    `kubectl drain` retry) and the message the requester sees. -/
def reviewResponse (uid : String) (allowed : Bool) (message : String)
    (code : Nat := 403) (reason : String := "Forbidden") : String :=
  let status : Json := if allowed then Json.mkObj [] else
    Json.mkObj [("code", Json.num code), ("reason", Json.str reason), ("message", Json.str message)]
  let resp := Json.mkObj ([("uid", Json.str uid), ("allowed", Json.bool allowed)] ++ (if allowed then [] else [("status", status)]))
  (Json.mkObj [("apiVersion", Json.str "admission.k8s.io/v1"), ("kind", Json.str "AdmissionReview"), ("response", resp)]).compress

/-- A reply for a review that could not be parsed: refused (fail closed). -/
def malformedResponse (body : String) (why : String) : String :=
  let uid := match Json.parse body with
    | .ok j => ((j.getObjValD "request").getObjValAs? String "uid").toOption.getD ""
    | .error _ => ""
  reviewResponse uid false s!"flare: malformed admission review ({why})"

end FlareOperator.Admission
