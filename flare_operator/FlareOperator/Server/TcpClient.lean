/-
  Server/TcpClient.lean - Outbound TCP client for pushing topology to flared nodes

  Implements active connections from operator to flared nodes' port 12121.
  When topology changes (nodeMapVersion increments), the operator actively
  connects to each flared node and sends "node sync <version>" command
  with the full node list.

  This mirrors the C++ flarei behavior where the coordinator pushes topology
  updates to nodes via their listening port (src/lib/queue_node_sync.cc).
-/

import Std.Internal.UV.TCP
import Std.Net.Addr
import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol

namespace FlareOperator.Server

open FlareOperator.K8s
open FlareOperator.Flare
open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4 IPv4Addr)

-- ===========================================================================
-- Client Connection Helpers
-- ===========================================================================

/-- Parse an IPv4 address string (e.g., "10.244.0.5") into IPv4Addr.
    Returns none if the format is invalid. -/
private def parseIPv4 (s : String) : Option IPv4Addr :=
  let parts := s.split (· == '.')
  if parts.length != 4 then
    none
  else
    match parts.mapM (·.toNat?) with
    | none => none
    | some octets =>
      if octets.any (· > 255) then
        none
      else
        match octets with
        | [a, b, c, d] => some ⟨#v[a.toUInt8, b.toUInt8, c.toUInt8, d.toUInt8]⟩
        | _ => none

/-- Send a string over the socket, with a HARD deadline. An accepted-but-
    stalled peer used to park the unbounded wait forever — and because the
    topology broadcast runs synchronously in the reconcile loop, ONE such
    pod froze the whole control plane (observed live: 22 minutes with no
    reconcile ticks — no failover, no drain, no refill — while a wedged
    flared held the send). 3s dwarfs any healthy in-VPC send. -/
private def sendString (sock : Socket) (s : String) : IO Unit := do
  let promise ← sock.send s.toUTF8
  let t := promise.result!
  for _ in [0:60] do
    if (← IO.hasFinished t) then
      let _ := t.get
      return ()
    IO.sleep 50
  throw (IO.userError "send timed out after 3s (peer accepted but stalled)")

/-- Can the OPERATOR open a TCP connection to this flared? Connect-only,
    bounded by the same 3s budget as the topology push, socket closed
    immediately.

    This tests the operator→pod path specifically, which nothing else does:
    the readiness probe runs INSIDE the pod (kubelet asks flared about
    itself) and `kubectl exec` stats probes travel via the API server. A
    node can therefore be perfectly healthy for clients while the operator
    cannot push topology to it — it then runs on a stale map indefinitely.

    Deliberately NOT wired into dead detection: unreachability is a loss of
    OUR feedback, and the fault may be on our side, so acting on it (failing
    over a master we merely cannot see) is the unsafe control action. It is
    an alerting signal only. -/
def probeNodeReachable (ip : String) (port : Nat) : IO Bool := do
  let ipAddr ← match parseIPv4 ip with
    | some addr => pure addr
    | none => return false
  let sock ← Socket.new
  let addr := SocketAddress.v4 (SocketAddressV4.mk ipAddr port.toUInt16)
  try
    let connectPromise ← sock.connect addr
    let connectTask := connectPromise.result!
    let mut connected := false
    for _ in [0:60] do
      if (← IO.hasFinished connectTask) then
        connected := true
        break
      IO.sleep 50
    if !connected then
      return false
    match connectTask.get with
    | .error _ => return false
    | .ok () => return true
  catch _ =>
    return false
  finally
    try
      let shutdownPromise ← sock.shutdown
      let t := shutdownPromise.result!
      for _ in [0:20] do
        if (← IO.hasFinished t) then
          break
        IO.sleep 50
    catch _ =>
      pure ()

-- ===========================================================================
-- Topology Push (Node Sync)
-- ===========================================================================

/-- Connect to a flared node's port 12121 and send "node sync <version>" with full node list.

    Wire protocol (operator push to flared's listening port):
      <operator connects to flared:12121>
      Operator → flared: "node sync <version>\r\n"
      Operator → flared: "NODE <name> <port> <role> <state> <partition> <balance> <thread>\r\n" (repeated)
      Operator → flared: "END\r\n"
      <operator disconnects>

    Reference: C++ src/lib/queue_node_sync.cc::run_client() -/
def sendNodeSyncToNode (ip : String) (port : Nat) (version : Nat) (nodes : List FlareNode) : IO Unit := do
  -- Parse IP address
  let ipAddr ← match parseIPv4 ip with
    | some addr => pure addr
    | none =>
      IO.eprintln s!"[TcpClient] Invalid IP address: {ip}"
      return ()

  -- Create socket and connect
  let sock ← Socket.new
  let addr := SocketAddress.v4 (SocketAddressV4.mk ipAddr port.toUInt16)

  try
    -- Connect to flared node's listening port 12121 under a HARD deadline.
    -- A deleted pod's IP blackholes the SYN and the kernel connect timeout
    -- is ~2 minutes; blocking that long serialized the whole (sequential)
    -- broadcast and starved the reconcile loop for minutes per dead target
    -- (observed live: minutes of "time expired" to a recreated pod's old IP
    -- while the cluster sat masterless). Poll the connect task with a 3s
    -- budget instead — a live flared on the same VPC connects in <10ms, so
    -- 3s only ever gives up on genuinely unreachable targets.
    let connectPromise ← sock.connect addr
    let connectTask := connectPromise.result!
    let mut connected := false
    for _ in [0:60] do
      if (← IO.hasFinished connectTask) then
        connected := true
        break
      IO.sleep 50
    if !connected then
      IO.eprintln s!"[TcpClient] connect to {ip}:{port} timed out after 3s — skipping target"
      return ()
    let connectResult := connectTask.get
    match connectResult with
    | .error e =>
      IO.eprintln s!"[TcpClient] Failed to connect to {ip}:{port}: {e}"
      return ()
    | .ok () =>
      -- Send "node sync <version>" command
      sendString sock s!"node sync {version}\r\n"

      -- Send full node list
      let nodeListPayload := serializeNodeList nodes
      sendString sock nodeListPayload

      IO.eprintln s!"[TcpClient] Sent node sync v{version} ({nodes.length} nodes) to {ip}:{port}"
  catch e =>
    IO.eprintln s!"[TcpClient] Error sending to {ip}:{port}: {e}"
  finally
    -- Close connection (bounded: best-effort — never park the caller)
    try
      let shutdownPromise ← sock.shutdown
      let t := shutdownPromise.result!
      for _ in [0:20] do
        if (← IO.hasFinished t) then
          break
        IO.sleep 50
    catch _ =>
      pure ()

end FlareOperator.Server
