/-
  StateMachine/ServiceSelector.lean - repointing a client Service at a
  partition's master without touching its IP families.

  mon-prod (IPv4-only cluster): every pass logged
  `failed to patch service flare-mon-prod-N: spec.ipFamilyPolicy: Invalid value:
  "RequireDualStack": this cluster is not configured for dual-stack services`
  twice. The operator sends only `spec.selector`; the Service object itself
  carries `ipFamilyPolicy: RequireDualStack` / `ipFamilies: [IPv4, IPv6]`, and
  the API server validates the whole object on every update, so any patch of
  that Service is refused.

  Decision (pure, tested):
  * the patch is sent only when the selector is not already the master's pod
    (the steady state sends nothing);
  * the patch carries the selector alone;
  * only when the API server refuses an update because the cluster has no
    dual-stack, the retry derives the families from the Service itself:
    `SingleStack` with its first family (a cluster without dual-stack cannot
    be serving the second one). No dual-stack field is ever SENT on a cluster
    that does not support it, and a Service with a valid policy is left alone;
  * a refusal is remembered per (service, pod) for `backoffMs`, so a Service
    that cannot be patched costs no time on the following passes.
-/

namespace FlareOperator.ServiceSelector

structure Shape where
  /-- `spec.selector["statefulset.kubernetes.io/pod-name"]`, none when unset. -/
  selector : Option String
  ipFamilyPolicy : String
  ipFamilies : List String
  deriving BEq, Repr

/-- The jsonpath the shape is read with (one `kubectl get`). -/
def shapeJsonpath : String :=
  "jsonpath={.spec.selector.statefulset\\.kubernetes\\.io/pod-name}|{.spec.ipFamilyPolicy}|{.spec.ipFamilies}"

/-- Parse `<pod>|<policy>|["IPv4","IPv6"]`; none when it is not that shape. -/
def parseShape (out : String) : Option Shape :=
  match out.trim.splitOn "|" with
  | [sel, pol, fams] =>
    let fs := (fams.trim.replace "[" "" |>.replace "]" "" |>.replace "\"" "").splitOn ","
      |>.map String.trim |>.filter (· != "")
    some { selector := if sel.trim.isEmpty then none else some sel.trim,
           ipFamilyPolicy := pol.trim, ipFamilies := fs }
  | _ => none

/-- Send a patch? Not when the Service already selects this pod. An unreadable
    Service (none) is patched as before. -/
def needsPatch (shape : Option Shape) (pod : String) : Bool :=
  match shape with
  | some s => s.selector != some pod
  | none => true

/-- The selector-only merge patch. -/
def selectorPatch (pod : String) : String :=
  "{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"" ++ pod ++ "\"}}}"

private def has (h n : String) : Bool := (h.splitOn n).length > 1

/-- The API server refused the update because the cluster has no dual-stack. -/
def dualStackUnsupported (err : String) : Bool :=
  has err "not configured for dual-stack" || has err "not configured on this cluster"

/-- The retry after `dualStackUnsupported`: the selector, `SingleStack`, and
    the Service's own first family. None when the Service has no family to
    keep (nothing to derive it from: no second guess is sent). -/
def singleStackPatch (shape : Option Shape) (pod : String) : Option String :=
  match shape with
  | some { ipFamilies := f :: _, .. } =>
    some ("{\"spec\":{\"selector\":{\"statefulset.kubernetes.io/pod-name\":\"" ++ pod
      ++ "\"},\"ipFamilyPolicy\":\"SingleStack\",\"ipFamilies\":[\"" ++ f ++ "\"]}}")
  | _ => none

/-- Skip a (service, pod) whose update was refused `ageMs` ago. -/
def inBackoff (ageMs backoffMs : Nat) : Bool := ageMs < backoffMs

end FlareOperator.ServiceSelector
