/-
  R3 (SAF-10 release checklist): a slave's copy is eligible to answer reads
  and to be PROMOTED only for the source it was validated against. flared
  withdraws the eligibility when it accepts a map that names another master
  (atomically with that map), or when the master's history changes under the
  same name, and reports it in `stats`:
    repl_read_source_eligible  1 / 0
    repl_read_source_state     none / eligible / revalidating / needs_rebuild
  The operator's part, pure here:
  * withhold a slave that reports eligible = 0 from every promotion path
    (failover, drain, refill) — read directly on the passes where a
    promotion can be decided, not from the periodic follow probe;
  * a slave that reports needs_rebuild (confirmed different lineage or
    history) takes the ordinary rebuild path, like a follower's declaration.
  An unreadable reply is NOT read as ineligible: it falls to the existing
  readiness / Unknown handling (a pre-R3 flared reports neither key).
-/

namespace FlareOperator.SourceEligibility

/-- A promotion can be decided on this pass: a partition without a master,
    a mapped node whose pod is gone, a node about to be failed over, or a
    master whose pod is terminating (graceful drain). -/
def promotionRisk (masterless deadCandidate : Bool) (unhealthy terminating masters : List String) : Bool :=
  masterless || deadCandidate || !unhealthy.isEmpty || masters.any (terminating.contains ·)

/-- One candidate's R3 reading on this pass (decision 2026-10-07):
    * `eligible v` — a complete reply carrying repl_read_source_eligible;
    * `legacy`     — a complete reply from a flared that EXPLICITLY predates R3
                     (none of the R3 or copy-identity keys): the existing
                     compatibility rule applies;
    * `unknown`    — the read failed, the reply was incomplete (no END), or a
                     build that has R3 did not report it. Withheld this pass. -/
inductive Reading where
  | eligible (v : Nat)
  | legacy
  | unknown
  deriving Repr, BEq

/-- Classify a `stats` reply (`none` = the read failed). Each pass reads
    afresh: nothing from an earlier pass stands in for this one. -/
def classifyReply (reply : Option String) : Reading :=
  match reply with
  | none => .unknown
  | some out =>
    let lines := (out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)
    if !lines.contains "END" then .unknown
    else
      let value := fun (k : String) => lines.findSome? fun l =>
        if l.startsWith s!"STAT {k} " then some (l.drop (s!"STAT {k} ").length) else none
      match (value "repl_read_source_eligible").bind String.toNat? with
      | some v => .eligible v
      | none =>
        let newerKeys := ["repl_read_source_eligible", "repl_read_source_state", "rocksdb_copy_id",
          "rocksdb_copy_identity_consistent"]
        if newerKeys.any (fun k => (value k).isSome) then .unknown else .legacy

/-- Slaves to withhold from promotion on this pass: not eligible, or
    unreadable / incomplete. A `legacy` reply is not withheld here. -/
def withheld (readings : List (String × Reading)) : List String :=
  readings.filterMap fun (k, r) => match r with
    | .eligible 0 => some k
    | .unknown => some k
    | _ => none

def readingLabel : Reading → String
  | .eligible v => toString v
  | .legacy => "legacy"
  | .unknown => "unreadable"

/-- Slaves that reported needs_rebuild, with flared's reason. -/
def rebuildRequests (readings : List (String × Option String × Option String)) : List (String × String) :=
  readings.filterMap fun (k, st, why) =>
    if st == some "needs_rebuild" then some (k, why.getD "the copy's source changed lineage or history") else none

end FlareOperator.SourceEligibility
