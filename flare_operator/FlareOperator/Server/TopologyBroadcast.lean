/-
  Server/TopologyBroadcast.lean - Orchestrate topology updates to all flared pods

  When nodeMapVersion changes, the operator must actively push the updated
  topology to ALL flared nodes by connecting to their listening port 12121.

  This module:
  1. Queries K8s for current pod list with IPs
  2. Spawns concurrent tasks to each pod's port 12121
  3. Sends "node sync <version>" with full node list
  4. Continues even if some pods fail (logs errors)

  Reference: C++ src/lib/cluster.cc::_broadcast() → queue_node_sync
-/

import FlareOperator.K8s.Bridge
import FlareOperator.Server.TcpClient
import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Server

open FlareOperator.K8s
open FlareOperator.K8s.Bridge

-- ===========================================================================
-- Broadcast Orchestration
-- ===========================================================================

/-- Broadcast topology update to all flared pods in parallel.

    This function:
    1. Gets current pod list from K8s (with live IP addresses)
    2. Spawns concurrent tasks to each pod's port 12121
    3. Sends "node sync <version>" with complete node list to each pod
    4. Logs success/failure per pod

    The port is hardcoded to 12121 (flared's protocol listening port).
    This matches C++ flarei's behavior where the coordinator actively
    pushes topology changes to all nodes via queue_node_sync. -/
def pendingTopologyAfterAttempt (previous : Option Nat) (version : Nat)
    (confirmed : Bool) : Option Nat :=
  if confirmed then none else some (previous.getD version)

/-- Why a reconcile pass pushes the committed map. The pass sends exactly
    when `any` holds; the record is logged with every send so a test (and an
    incident reader) can tell WHICH reason carried a given push instead of
    inferring it from the absence of other lines. In a fresh process
    `pending` is seeded with the committed version (startup republish); the
    topology audit can also set it when a recipient reports an older map. -/
structure BroadcastTriggers where
  versionMoved : Bool
  pending : Option Nat
  repairHeld : Nat
  activeNotReady : Nat
  deriving Repr, BEq

def BroadcastTriggers.any (t : BroadcastTriggers) : Bool :=
  t.versionMoved || t.pending.isSome || t.repairHeld > 0 || t.activeNotReady > 0

/-- Only the pending flag, nothing else, asks for this send. -/
def BroadcastTriggers.pendingOnly (t : BroadcastTriggers) : Bool :=
  t.pending.isSome && !t.versionMoved && t.repairHeld == 0 && t.activeNotReady == 0

def BroadcastTriggers.label (t : BroadcastTriggers) : String :=
  let p := match t.pending with | some v => s!"v{v}" | none => "none"
  s!"versionMoved={t.versionMoved} pending={p} repairHeld={t.repairHeld} activeNotReady={t.activeNotReady}"

def broadcastTopologyToAllPods (crName ns : String) (version : Nat) (nodes : List FlareNode) : IO Bool := do
  -- Get current pod list with IP addresses from K8s
  let pods ← match ← listFlaredPodsE crName ns with
    | .ok ps => pure ps
    | .error e =>
      IO.eprintln s!"[TopologyBroadcast] Pod list unavailable; delivery unconfirmed: {e}"
      return false

  if pods.isEmpty then
    IO.eprintln "[TopologyBroadcast] No pods found to broadcast to"
    return nodes.isEmpty

  IO.eprintln s!"[TopologyBroadcast] Broadcasting node sync v{version} ({nodes.length} nodes) to {pods.length} pods"

  -- Fan out per pod: one unreachable target (e.g. a just-recreated pod's
  -- old IP still in the list) must not delay the others or the caller —
  -- combined with the TcpClient 3s connect deadline this bounds the whole
  -- broadcast to ~3s instead of minutes of serialized kernel timeouts.
  -- Note: Terminating pods are INTENTIONALLY included (graceful drain sends
  -- the demotion map to the still-alive leaving pod); the deadline is what
  -- distinguishes "Terminating but reachable" from "gone".
  let tasks ← pods.mapM fun pod =>
    IO.asTask (sendNodeSyncToNode pod.ip 12121 version nodes)
  let deadline := (← IO.monoMsNow) + 15000
  let mut confirmed := true
  -- Belt over TcpClient's own deadlines: the broadcast runs synchronously
  -- in the reconcile loop, so NOTHING here may wait unboundedly (one stuck
  -- pod froze the loop for 22 min live). 15s >> connect(3s)+sends(3s each).
  for t in tasks do
    let mut finished := false
    for _ in [0:300] do
      if (← IO.hasFinished t) then
        finished := true
        break
      if (← IO.monoMsNow) >= deadline then break
      IO.sleep 50
    if finished then
      match t.get with
      | .ok ok => confirmed := confirmed && ok
      | .error e =>
        confirmed := false
        IO.eprintln s!"[TopologyBroadcast] send task failed: {e}"
    else
      confirmed := false
      IO.eprintln "[TopologyBroadcast] WARNING: send task exceeded 15s — abandoning it (bounded broadcast)"

  IO.eprintln s!"[TopologyBroadcast] Broadcast attempt complete (v{version}); all targets reply-confirmed={confirmed}"
  return confirmed

end FlareOperator.Server
