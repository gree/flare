/-
  StateMachine/UnreachableNode.lean — when the operator's own failure to reach
  a node makes that node DOWN (spec 12, user decision 2026-10-31).

  A Ready node whose flared port the operator cannot connect to is treated like
  any other unhealthy node: after the same retry count and wait as the EC2
  index server it joins the unhealthy list that dead detection already uses
  (K8sReconciler: unhealthy keys -> dead node keys -> circuit breaker ->
  failover / masterless refill). Nothing here acts on the cluster; it only
  names the keys.

  flarei defaults used (src/flarei/ini_option.h):
    monitor_threshold     3        consecutive failed probes
    monitor_interval      5 s      between probes (= one reconcile tick)
    monitor_read_timeout  1000 ms  per probe
  so a node is down after ~15 s of failed probes, as on EC2.

  Master: `K8sReconciler.unhealthyMastersKept` keeps an unhealthy master that
  has no Active slave of its partition which is live and not itself unhealthy
  (the same rule as for a NotReady master), so a master is marked down only
  when a reachable, promotable successor exists; the FailoverOrder /
  promotion-evidence rules then choose it. Slave: down / proxy, the existing
  rebuild path builds another copy.

  GUARD: when every probed node is unreachable the fault is taken to be the
  operator's own (k8s API / network): nothing is flagged and the streaks
  restart, so a partial recovery cannot make a stale streak fire at once.
-/
import FlareOperator.StateMachine.K8sReconciler

namespace FlareOperator.UnreachableNode

open FlareOperator.K8s

/-- flarei `monitor_threshold` -/
def monitorThreshold : Nat := 3
/-- flarei `monitor_interval`, seconds (one operator tick) -/
def monitorIntervalSec : Nat := 5
/-- flarei `monitor_read_timeout`, milliseconds (the probe's connect timeout) -/
def monitorReadTimeoutMs : Nat := 1000

structure Verdict where
  /-- consecutive failed probes per Active master / slave (the next pass's `prev`) -/
  streaks : List (String × Nat) := []
  /-- unreachable for `threshold` probes in a row: treated as unhealthy -/
  down : List String := []
  /-- every probed node was unreachable: the operator's side is suspect -/
  guardTripped : Bool := false
  deriving BEq, Repr

/-- `probed`: (node key, reachable) for every Ready, non-Terminating pod
    probed this pass. -/
def step (prev : List (String × Nat)) (probed : List (String × Bool))
    (state : FlareClusterState) (threshold : Nat := monitorThreshold) : Verdict :=
  let unreachable := (probed.filter (fun p => !p.2)).map (·.1)
  let guardTripped := !probed.isEmpty && unreachable.length == probed.length
  if guardTripped then { guardTripped := true }
  else
    let streaks := K8sReconciler.unreadyStreaks prev unreachable state
    { streaks := streaks
      down := (streaks.filter (fun kv => kv.2 ≥ threshold)).map (·.1) }

end FlareOperator.UnreachableNode
