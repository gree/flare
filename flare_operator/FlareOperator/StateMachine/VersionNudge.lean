/-
  StateMachine/VersionNudge.lean - when a commit advances the node map version
  without the map having changed (flare-operator-slow-reconcile).

  A node that is not Active (Prepare/Ready/Down) needs a fresh broadcast to be
  re-evaluated (flared only processes a strictly newer version), so while the
  cluster is converging the version is advanced as a nudge. The nudge was
  taken at EVERY commit, and a pass commits 7 times (mon-prod: v...703 → ...710
  on every pass, with a rebuilding node and one held): 7 versions for one
  broadcast. A pass needs ONE nudge: the first commit that finds the map
  unchanged and the cluster not at rest. A real change always advances.
-/

namespace FlareOperator.VersionNudge

/-- Does this commit advance the version? `nudgedThisPass`: an earlier commit
    of this pass has already advanced it. -/
def advance (changed allActive nudgedThisPass : Bool) : Bool :=
  changed || (!allActive && !nudgedThisPass)

end FlareOperator.VersionNudge
