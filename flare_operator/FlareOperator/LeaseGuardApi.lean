/-
  LeaseGuardApi.lean — the lease guard's REAL api (bounded kubectl calls, the
  monotonic clock, a microsecond renewTime per attempt, a log line per renewer
  outcome). Shared by the operator (Main) and the host probe lease_guard_probe.
-/
import FlareOperator.StateMachine.LeaseGuard
import FlareOperator.K8s.Bridge

namespace FlareOperator.LeaseGuard

open FlareOperator.K8s.Bridge

/-- Stderr line, prefixed like the operator's own. -/
def logLine (msg : String) : IO Unit :=
  IO.eprintln s!"[flare-operator] lease guard: {msg}"

def realLeaseApi (leaseName ns identity : String) : Api where
  now := IO.monoMsNow
  stamp := leaseStamp
  renew := fun stamp bound => do
    let r ← try renewLeaseStamped (some bound) leaseName ns identity stamp
      catch e => pure (.error s!"{e}")
    match r with
    | .ok () => pure .applied
    | .error e => pure (.failed e)
  read := fun bound => do
    let r ← try getLeaseWith (some bound) leaseName ns
      catch e => pure (.error s!"{e}")
    match r with
    | .ok l => pure (.lease l.holderIdentity l.renewTime)
    | .error e =>
      logLine s!"renewer: read-back error: {e.take 300}"
      pure .unreadable
  sleep := fun ms => IO.sleep ms.toUInt32
  log := logLine

/-- Start the watchdog and the renewer as dedicated tasks. -/
def startTasks (api : Api) (g : Guard) : IO Unit := do
  let _ ← IO.asTask (prio := .dedicated) (watchdogTask api g)
  let _ ← IO.asTask (prio := .dedicated) (renewerTask api g)

end FlareOperator.LeaseGuard
