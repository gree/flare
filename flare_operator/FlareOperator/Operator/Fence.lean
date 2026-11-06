/-
  Operator/Fence.lean — the break-glass of a halted history-continuation
  handover (docs/design-handover-history-continuation.md addenda 6–10),
  the IO side: the receipt key Secret, the SubjectAccessReview and the
  mutating webhook's answer for a FlareCluster UPDATE. The decisions are
  StateMachine/HandoverFence (pure).

  The key Secret is created once by the operator (never overwritten); its
  name comes from FLARE_RECEIPT_KEY_SECRET (the chart sets it). Without a
  key no receipt is issued and none is accepted (fail closed).
-/
import FlareOperator.Operator.Base
import FlareOperator.StateMachine.HandoverFence
import FlareOperator.K8s.Admission

namespace FlareOperator.Fence

open FlareOperator.Kubectl

initialize keyRef : IO.Ref (Option ByteArray) ← IO.mkRef none

private def keySecretName : IO (Option String) := do
  match ← IO.getEnv "FLARE_RECEIPT_KEY_SECRET" with
  | some n => return if n.isEmpty then none else some n
  | none => return none

private def readKeySecret (ns name : String) : IO (Except String (Option ByteArray)) := do
  match ← kubectl ["get", "secret", name, "-n", ns, "-o", "jsonpath={.data.key}"] with
  | .ok b64 =>
    if b64.trim.isEmpty then return .ok none
    let out ← IO.Process.output { cmd := "sh", args := #["-c", "printf %s \"$1\" | base64 -d", "_", b64.trim] }
    if out.exitCode != 0 then return .error "the key does not decode"
    return .ok ((Crypto.fromHex? out.stdout.trim))
  | .error e =>
    if (e.splitOn "NotFound").length > 1 then return .ok none else return .error e

/-- The receipt key: read once, cached. Created (32 random bytes, hex)
    when the Secret does not exist; an existing Secret is never replaced
    (a concurrent creator wins and its key is read back). -/
def ensureKey (ns : String) : IO (Option ByteArray) := do
  if let some k := (← keyRef.get) then return some k
  let some name ← keySecretName | return none
  match ← readKeySecret ns name with
  | .ok (some k) =>
    keyRef.set (some k)
    return some k
  | .error e =>
    IO.eprintln s!"[flare-operator] HANDOVER FENCE: the receipt key {name} could not be read ({e}); no receipt is issued or accepted"
    return none
  | .ok none =>
    let rnd ← IO.Process.output { cmd := "sh", args := #["-c", "head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \\n'"] }
    if rnd.exitCode != 0 || rnd.stdout.trim.length != 64 then
      IO.eprintln "[flare-operator] HANDOVER FENCE: no random bytes for the receipt key"
      return none
    match ← kubectl ["create", "secret", "generic", name, "-n", ns, s!"--from-literal=key={rnd.stdout.trim}"] with
    | .ok _ => IO.eprintln s!"[flare-operator] HANDOVER FENCE: created the receipt key Secret {name}"
    | .error e => IO.eprintln s!"[flare-operator] HANDOVER FENCE: the receipt key Secret {name} was not created ({e.take 200}); reading it back"
    match ← readKeySecret ns name with
    | .ok (some k) =>
      keyRef.set (some k)
      return some k
    | _ => return none

/-- Ask the API server whether the requester may break-glass this
    FlareCluster's handover fence. `.error` = no answer (refused). A raw
    POST: no API discovery inside the webhook's 5 s (42147157735: the
    typed `kubectl create -f` did not answer in time). -/
def sarAllowed (ns name username userUid : String) (groups : List String) : IO (Except String Bool) := do
  try
    let pid ← IO.Process.getPID
    let path : System.FilePath := s!"/tmp/flare-operator-sar-{pid}-{← IO.monoNanosNow}.json"
    IO.FS.writeFile path (HandoverFence.sarJson ns name username userUid groups).compress
    let out ← IO.Process.output { cmd := "timeout", args := #["-k", "1", "4", "kubectl", "create", "--raw",
      "/apis/authorization.k8s.io/v1/subjectaccessreviews", "-f", path.toString] }
    try IO.FS.removeFile path catch _ => pure ()
    if out.exitCode != 0 then
      return .error s!"exit {out.exitCode}: {out.stderr.trim.take 300}"
    match HandoverFence.sarAllowed? out.stdout with
    | some b => return .ok b
    | none => return .error s!"unreadable reply: {out.stdout.trim.take 200}"
  catch e => return .error s!"{e}"

/-- The mutating webhook's answer for a FlareCluster UPDATE of this cluster
    (addenda 8–9): a new or changed handover-fenced value gets a receipt
    only after the SubjectAccessReview allows the requester (otherwise the
    update is refused); a receipt touched without a new value is put back.
    Nothing is written anywhere else (sideEffects: None). -/
def answer (crName ns : String) (r : Admission.Review) : IO String := do
  if r.«namespace» != ns || r.name != crName || r.operation != "UPDATE" then
    return Admission.patchResponse r.uid []
  let oldA := fun (k : String) => (((r.oldObject.getObjValD "metadata").getObjValD "annotations").getObjValAs? String k).toOption
  let oldV := oldA HandoverFence.valueAnnotation
  let oldR := oldA HandoverFence.receiptAnnotation
  let newV := r.newAnnotation HandoverFence.valueAnnotation
  let newR := r.newAnnotation HandoverFence.receiptAnnotation
  match HandoverFence.mutation oldV newV oldR newR with
  | .none => return Admission.patchResponse r.uid []
  | .invalid why =>
    IO.eprintln s!"[flare-operator] NODE GUARD: handover-fenced REFUSED for {r.username}: {why}"
    return Admission.reviewResponse r.uid false s!"flare: {why}"
  | .restoreReceipt old =>
    IO.eprintln s!"[flare-operator] NODE GUARD: handover-fenced: a receipt written by {r.username} was replaced with the stored one"
    return Admission.patchResponse r.uid [HandoverFence.annotationPatch HandoverFence.receiptAnnotation old newR.isSome]
  | .authorize v =>
    match ← sarAllowed ns crName r.username r.userUid r.groups with
    | .ok true =>
      let some key ← ensureKey ns
        | IO.eprintln s!"[flare-operator] NODE GUARD: handover-fenced REFUSED for {r.username}: no receipt key"
          return Admission.reviewResponse r.uid false "flare: the handover fence cannot be receipted now (no key); retry"
      let value := newV.getD ""
      let rc := HandoverFence.receiptFor key value v r.uid r.username r.userUid
      IO.eprintln s!"[flare-operator] NODE GUARD: handover-fenced {value} by {r.username} (uid {r.userUid}, review {r.uid}): receipted"
      return Admission.patchResponse r.uid [HandoverFence.annotationPatch HandoverFence.receiptAnnotation (some rc) newR.isSome]
    | .ok false =>
      IO.eprintln s!"[flare-operator] NODE GUARD: handover-fenced REFUSED for {r.username}: no break-glass permission on flareclusters/handover-fence"
      return Admission.reviewResponse r.uid false s!"flare: {r.username} may not break-glass the handover fence (verb break-glass on flareclusters/handover-fence, group flare.gree.net)"
    | .error why =>
      IO.eprintln s!"[flare-operator] NODE GUARD: handover-fenced REFUSED for {r.username}: the SubjectAccessReview did not answer ({why})"
      return Admission.reviewResponse r.uid false "flare: the permission could not be checked (SubjectAccessReview); retry"

/-- The fence annotations of the FlareCluster and the approval ids status
    keeps (`status.handoverApprovals`, the newest 64). -/
def readInputs (crName ns : String) : IO (Except String (Option String × Option String × List String)) := do
  match ← kubectl ["get", "flarecluster", crName, "-n", ns, "-o", "json"] with
  | .error e => return .error e
  | .ok out =>
    match Lean.Json.parse out with
    | .error e => return .error s!"the FlareCluster did not parse: {e}"
    | .ok j =>
      let ann := fun (k : String) => (((j.getObjValD "metadata").getObjValD "annotations").getObjValAs? String k).toOption
      let approvals := match (j.getObjValD "status").getObjVal? "handoverApprovals" with
        | .ok (Lean.Json.arr a) => a.toList.filterMap fun x => x.getStr?.toOption
        | _ => []
      return .ok (ann HandoverFence.valueAnnotation, ann HandoverFence.receiptAnnotation, approvals)

/-- After the ledger holds `fencedBy`: the approval id joins
    `status.handoverApprovals` (the newest 64) and both annotations are
    removed. Either may fail: `fencedBy` already makes the value used. -/
def finish (crName ns approvalId : String) : IO Unit := do
  match ← readInputs crName ns with
  | .ok (_, _, ids) =>
    if !ids.contains approvalId then
      let keep := (ids ++ [approvalId]).drop ((ids.length + 1) - HandoverFence.recentApprovalsKept)
      let patch := (Lean.Json.mkObj [("status", Lean.Json.mkObj [("handoverApprovals", Lean.Json.arr (keep.map Lean.Json.str).toArray)])]).compress
      match ← kubectl ["patch", "flarecluster", crName, "-n", ns, "--subresource=status", "--type=merge", "-p", patch] with
      | .ok _ => pure ()
      | .error e => IO.eprintln s!"[flare-operator] HANDOVER FENCE: approval id {approvalId} not recorded in status ({e.take 200})"
  | .error e => IO.eprintln s!"[flare-operator] HANDOVER FENCE: status unreadable ({e.take 200}); approval id {approvalId} not recorded"
  match ← kubectl ["annotate", "flarecluster", crName, "-n", ns, s!"{HandoverFence.valueAnnotation}-", s!"{HandoverFence.receiptAnnotation}-"] with
  | .ok _ => IO.eprintln s!"[flare-operator] HANDOVER FENCE: the consumed annotations were removed"
  | .error e => IO.eprintln s!"[flare-operator] HANDOVER FENCE: the consumed annotations were not removed ({e.take 200}); fencedBy keeps them used"

end FlareOperator.Fence
