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
def broadcastTopologyToAllPods (crName ns : String) (version : Nat) (nodes : List FlareNode) : IO Unit := do
  -- Get current pod list with IP addresses from K8s
  let pods ← listFlaredPods crName ns

  if pods.isEmpty then
    IO.eprintln "[TopologyBroadcast] No pods found to broadcast to"
    return ()

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
  for t in tasks do
    match ← IO.wait t with
    | .ok _ => pure ()
    | .error e => IO.eprintln s!"[TopologyBroadcast] send task failed: {e}"

  IO.eprintln s!"[TopologyBroadcast] Broadcast complete (v{version})"

end FlareOperator.Server
