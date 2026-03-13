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

/-- Send a string over the socket. -/
private def sendString (sock : Socket) (s : String) : IO Unit := do
  let promise ← sock.send s.toUTF8
  let _ ← IO.wait promise.result!

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
    -- Connect to flared node's listening port 12121
    let connectPromise ← sock.connect addr
    let connectResult ← IO.wait connectPromise.result!
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
    -- Close connection
    try
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
    catch _ =>
      pure ()

end FlareOperator.Server
