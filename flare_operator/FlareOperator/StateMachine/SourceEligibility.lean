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

/-- Slaves to withhold from promotion: those whose reply says the copy is
    not eligible for its source. `none` (unreadable / pre-R3) is not listed. -/
def withheld (readings : List (String × Option Nat)) : List String :=
  readings.filterMap fun (k, e) => if e == some 0 then some k else none

/-- Slaves that reported needs_rebuild, with flared's reason. -/
def rebuildRequests (readings : List (String × Option String × Option String)) : List (String × String) :=
  readings.filterMap fun (k, st, why) =>
    if st == some "needs_rebuild" then some (k, why.getD "the copy's source changed lineage or history") else none

end FlareOperator.SourceEligibility
