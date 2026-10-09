/-
  Copy retention, explicit approvals (docs/design-copy-retention.md §7):
  `FlareCopyDiscardApproval` names ONE copy on ONE pod of ONE cluster and is
  used ONCE. Pure decisions here (unit tested); the operator relays a valid
  approval to that pod's flared (`copy_discard <requestId> <operation>
  <copyId>`), which records the request id before deleting anything and
  answers a repeat from its record, and writes the result to the status.
-/

namespace FlareOperator.CopyDiscardApproval

structure Approval where
  name : String
  clusterUID : String
  podUID : String
  copyId : String
  requestId : String
  operation : String
  expiresAt : String      -- RFC 3339, UTC ("...Z")
  phase : String := ""    -- status.phase ("" = not decided yet)
  attempt : Nat := 0
  deriving Repr, BEq

def operations : List String := ["discard-retained", "discard-quarantine", "discard-before-copy"]

/-- Tokens go onto flared's text protocol: a conservative character set. -/
def validToken (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 128 && s.all (fun c => c.isAlphanum || c == ':' || c == '-' || c == '_' || c == '.')

inductive Verdict where
  | skip                    -- decided already, or another cluster's approval
  | expire
  | refuse (reason : String)
  | send (pod : String)
  deriving Repr, BEq

/-- `nowUtc` and `expiresAt` are both RFC 3339 UTC with a trailing Z, so they
    compare as strings. `podByUid` finds this cluster's flared pod by UID. -/
def decide (a : Approval) (clusterUID nowUtc : String) (podByUid : String → Option String) : Verdict :=
  if a.phase != "" && a.phase != "Pending" then .skip
  else if a.clusterUID != clusterUID then .skip
  else if !operations.contains a.operation then .refuse s!"unknown operation {a.operation}"
  else if !validToken a.requestId || !validToken a.copyId || !validToken a.podUID then .refuse "malformed requestId, copyId or podUID"
  else if a.expiresAt.isEmpty || !(a.expiresAt.endsWith "Z") then .refuse "expiresAt must be an RFC 3339 UTC time (…Z)"
  else if a.expiresAt ≤ nowUtc then .expire
  else match podByUid a.podUID with
    | none => .refuse "no flared pod of this cluster has this UID (replaced or gone)"
    | some pod => .send pod

/-- flared's answer → (phase, reason). `none` = no complete answer: the
    approval stays Pending and is sent again (flared answers a repeat from its
    record, so it never runs twice). -/
def classify (reply : Option String) : String × String :=
  match reply with
  | none => ("Pending", "no complete answer from flared; sent again (a repeat is answered from flared's record)")
  | some r =>
    if r == "applied" || r == "already:applied" then ("Applied", r)
    else if r.startsWith "refused:" || r.startsWith "already:refused:" then ("Refused", r)
    else if r == "already:started" then
      ("Unknown", "flared recorded the start but not the outcome (it stopped in between); it is not run again — inspect the pod")
    else ("Failed", r)

/-- The `copy_discard_result` value from flared's reply (STAT line, then END). -/
def parseReply (out : String) : Option String :=
  let lines := (out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)
  if !lines.contains "END" then none
  else (lines.findSome? fun l =>
    if l.startsWith "STAT copy_discard_result " then some (l.drop "STAT copy_discard_result ".length) else none)

end FlareOperator.CopyDiscardApproval
