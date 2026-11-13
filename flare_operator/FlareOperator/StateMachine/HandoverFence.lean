/-
  StateMachine/HandoverFence.lean — the break-glass of a halted history-
  continuation handover (docs/design-handover-history-continuation.md
  addenda 6–10), pure.

  A person who made sure the silent successor's flared stopped (or is cut
  off) says so on the FlareCluster:

    flare.gree.net/handover-fenced = <approval-id>/<hid>/<pod UID>/<boot id>/<copy id>

  The node guard's MUTATING webhook (flareclusters UPDATE) sees that value
  added or changed, asks the API server whether the requester may
  `break-glass` the subresource `flareclusters/handover-fence` of group
  `flare.gree.net` (SubjectAccessReview: a question, nothing persisted —
  sideEffects None), and only then adds in the SAME update

    flare.gree.net/handover-fenced-receipt =
      <approval-id>/<hid>/<AdmissionReview uid>/<username>/<user uid>/<HMAC>

  with the HMAC (key: a Secret only the operator reads) over the five fields
  and the whole value. A receipt the requester wrote is always replaced (or
  removed). The operator consumes a valid pair once: it checks the HMAC, the
  hid and the successor's binding, writes `fencedBy` by CAS, then removes
  both annotations. Approval ids are checked against the newest 64 kept in
  status only (audit ids; safety comes from hid + binding).
-/
import Lean.Data.Json
import FlareOperator.Crypto.Sha256

namespace FlareOperator.HandoverFence

open Lean

def valueAnnotation : String := "flare.gree.net/handover-fenced"
def receiptAnnotation : String := "flare.gree.net/handover-fenced-receipt"
/-- how many consumed approval ids status keeps (addendum 8 §2) -/
def recentApprovalsKept : Nat := 64

/-- The annotation value (addendum 7 §1). -/
structure Value where
  approvalId : String
  hid : String
  podUid : String
  bootId : String
  copyId : String
  deriving Repr, BEq

/-- Every field present and free of `/`. -/
def parseValue? (s : String) : Option Value :=
  match s.trim.splitOn "/" with
  | [a, h, u, b, c] =>
    if [a, h, u, b, c].any String.isEmpty then none else some ⟨a, h, u, b, c⟩
  | _ => none

/-- The successor binding the value names, as Handover records it (`uid|boot|copy`). -/
def Value.binding (v : Value) : String := s!"{v.podUid}|{v.bootId}|{v.copyId}"

/-- `/` and `%` escaped (a username may hold either). -/
def esc (s : String) : String := (s.replace "%" "%25").replace "/" "%2F"
def unesc (s : String) : String := (s.replace "%2F" "/").replace "%25" "%"

structure Receipt where
  approvalId : String
  hid : String
  reviewUid : String
  username : String
  userUid : String
  mac : String
  deriving Repr, BEq

/-- What the HMAC covers: the five fields and the whole annotation value. -/
def macInput (approvalId hid reviewUid username userUid value : String) : String :=
  "\n".intercalate [approvalId, hid, reviewUid, username, userUid, value]

def macOf (key : ByteArray) (approvalId hid reviewUid username userUid value : String) : String :=
  Crypto.toHex (Crypto.hmacSha256 key (macInput approvalId hid reviewUid username userUid value).toUTF8)

/-- The receipt the webhook writes for `value` (already parsed as `v`). -/
def receiptFor (key : ByteArray) (value : String) (v : Value) (reviewUid username userUid : String) : String :=
  "/".intercalate [v.approvalId, v.hid, esc reviewUid, esc username, esc userUid,
    macOf key v.approvalId v.hid reviewUid username userUid value.trim]

def parseReceipt? (s : String) : Option Receipt :=
  match s.trim.splitOn "/" with
  | [a, h, r, u, uu, m] => if a.isEmpty || h.isEmpty || m.isEmpty then none else some ⟨a, h, unesc r, unesc u, unesc uu, m⟩
  | _ => none

/-- The receipt is the webhook's for exactly this value (key, the HMAC over
    its fields and the value, the same approval id and hid). -/
def receiptValid (key : ByteArray) (value : String) (v : Value) (r : Receipt) : Bool :=
  !key.isEmpty && r.approvalId == v.approvalId && r.hid == v.hid
    && Crypto.constEq r.mac (macOf key r.approvalId r.hid r.reviewUid r.username r.userUid value.trim)

/-- The SubjectAccessReview the webhook asks (addenda 9 §2 / 10). -/
def sarJson (ns name username userUid : String) (groups : List String) : Json :=
  Json.mkObj [
    ("apiVersion", "authorization.k8s.io/v1"), ("kind", "SubjectAccessReview"),
    ("spec", Json.mkObj [
      ("user", Json.str username), ("uid", Json.str userUid),
      ("groups", Json.arr (groups.map Json.str).toArray),
      ("resourceAttributes", Json.mkObj [
        ("group", "flare.gree.net"), ("verb", "break-glass"), ("resource", "flareclusters"),
        ("subresource", "handover-fence"), ("namespace", Json.str ns), ("name", Json.str name)])])]

/-- `status.allowed` of a SubjectAccessReview reply; `none` = unreadable
    (refused: fail closed). -/
def sarAllowed? (reply : String) : Option Bool :=
  match Json.parse reply with
  | .ok j => (j.getObjVal? "status" >>= (·.getObjValAs? Bool "allowed")).toOption
  | .error _ => none

/-- What the mutating webhook does with one FlareCluster UPDATE, given the
    old and new values of the two annotations. -/
inductive Mutation where
  /-- nothing to do (the value did not change, the receipt neither) -/
  | none
  /-- the value was added or changed: ask the SAR, then add a receipt
      (`some v`) or refuse the update (a value that does not parse is
      refused at once: `invalid`) -/
  | authorize (v : Value)
  | invalid (why : String)
  /-- the requester touched the receipt without a new value: put the old
      one back (`some r`) or remove it (`none`) -/
  | restoreReceipt (old : Option String)
  deriving Repr, BEq

def mutation (oldValue newValue oldReceipt newReceipt : Option String) : Mutation :=
  match newValue with
  | some nv =>
    if oldValue == some nv then
      if newReceipt != oldReceipt then .restoreReceipt oldReceipt else .none
    else match parseValue? nv with
      | some v => .authorize v
      | none => .invalid s!"{valueAnnotation} must be <approval-id>/<hid>/<pod UID>/<boot id>/<copy id>"
  | none =>
    -- the value removed: a receipt may go with it (or stays as it was)
    if newReceipt != oldReceipt && newReceipt.isSome then .restoreReceipt oldReceipt else .none

/-- The JSON patch of the webhook's answer for one annotation (`~1` = `/`). -/
def annotationPatch (anno : String) (value : Option String) (present : Bool) : Json :=
  let path := s!"/metadata/annotations/{(anno.replace "~" "~0").replace "/" "~1"}"
  match value with
  | some v => Json.mkObj [("op", if present then "replace" else "add"), ("path", Json.str path), ("value", Json.str v)]
  | none => Json.mkObj [("op", "remove"), ("path", Json.str path)]

/-- Who fenced, for status (`fencedBy`) and the log. -/
structure FencedBy where
  value : String
  username : String
  userUid : String
  reviewUid : String
  at_ : String
  deriving Repr, BEq

def FencedBy.toJson (f : FencedBy) : Json :=
  Json.mkObj [("value", Json.str f.value), ("username", Json.str f.username), ("userUid", Json.str f.userUid),
              ("reviewUid", Json.str f.reviewUid), ("at", Json.str f.at_)]

def FencedBy.fromJson? (j : Json) : Option FencedBy := do
  let s := fun (k : String) => (j.getObjValAs? String k).toOption
  pure ⟨← s "value", (s "username").getD "", (s "userUid").getD "", (s "reviewUid").getD "", (s "at").getD ""⟩

/-- May the operator consume this value + receipt for a handover with this
    hid and successor binding? (addenda 6–9). `fenced` = the handover
    already holds a `fencedBy` (used once; a second value is ignored);
    `recent` = the approval ids status keeps. -/
def consume (key : ByteArray) (hid successorBinding : String) (fenced : Bool) (recent : List String)
    (value : String) (receipt : Option String) (at_ : String) : Except String FencedBy := do
  let some v := parseValue? value | throw "the value does not parse"
  if fenced then throw "this handover was already fenced (used once)"
  if hid.isEmpty || v.hid != hid then throw s!"the value names handover {v.hid}, not {hid}"
  if successorBinding.isEmpty || v.binding != successorBinding then
    throw s!"the value names the successor {v.binding}, not the one recorded ({successorBinding})"
  if recent.contains v.approvalId then throw s!"approval id {v.approvalId} was already used"
  let some rs := receipt | throw "no receipt: the annotation did not pass the webhook (CRITICAL)"
  let some r := parseReceipt? rs | throw "the receipt does not parse"
  if key.isEmpty then throw "the receipt key is not available"
  if !receiptValid key value v r then throw "the receipt is not the webhook's for this value (HMAC, approval id or hid)"
  pure ⟨value.trim, r.username, r.userUid, r.reviewUid, at_⟩

end FlareOperator.HandoverFence
