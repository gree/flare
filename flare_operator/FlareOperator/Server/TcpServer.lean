/-
  Server/TcpServer.lean - Native TCP server with strict pure/IO separation

  Provides a TCP server on port 12120 for the flarei text protocol.
  Uses Lean 4 Std.Internal.UV.TCP Socket API with IO.asTask for
  concurrent client handling.

  Architecture:
  - ServerState: encapsulates shared mutable state (IO.Ref)
  - handleConnection: read loop calling pure reconcileStep (no K8s IO)
  - startServer: bind + listen + accept loop with concurrent dispatch

  Strict separation: all mutation flows through the pure reconcileStep
  function. The TCP layer only does read/write/parse — never kubectl calls.
-/

import Std.Internal.UV.TCP
import Std.Net.Addr
import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler

namespace FlareOperator.Server

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler
open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4 IPv4Addr)

-- ===========================================================================
-- Server State
-- ===========================================================================

/-- Encapsulates the shared mutable state for the TCP server.
    All fields are IO.Ref for thread-safe access from concurrent handlers.
    The CRD ref is read-only from the TCP server's perspective (updated
    by the reconcile loop in Main). -/
structure ServerState where
  /-- Mutable cluster state, updated by reconcileStep on each command -/
  clusterState : IO.Ref FlareClusterState
  /-- CRD spec, read-only from TCP handlers (updated by reconcile loop) -/
  crdSpec : IO.Ref FlareClusterView

/-- Create a new ServerState with default values. -/
def ServerState.new (crName ns : String) : IO ServerState := do
  let stateRef ← IO.mkRef FlareClusterState.default
  let crdRef ← IO.mkRef ({
    metadata := { name := some crName, «namespace» := some ns }
    spec := { partitions := 1, replicas := 1 }
  } : FlareClusterView)
  return { clusterState := stateRef, crdSpec := crdRef }

/-- Create a ServerState from existing refs (for backward compatibility with Main.lean). -/
def ServerState.fromRefs (stateRef : IO.Ref FlareClusterState) (crdRef : IO.Ref FlareClusterView)
    : ServerState :=
  { clusterState := stateRef, crdSpec := crdRef }

-- ===========================================================================
-- Socket I/O Helpers
-- ===========================================================================

/-- Read data from a socket and split into a line (up to \n, trimming \r\n).
    Uses a buffer ref to handle partial reads across recv boundaries. -/
private def readLine (sock : Socket) (bufRef : IO.Ref ByteArray) : IO (Option String) := do
  let rec loop (fuel : Nat) : IO (Option String) := do
    match fuel with
    | 0 => return none
    | fuel + 1 =>
      let buf ← bufRef.get
      let bufStr := String.fromUTF8! buf
      match bufStr.splitOn "\n" with
      | line :: rest =>
        if rest.isEmpty then
          -- No newline yet, read more data
          let promise ← sock.recv? 4096
          let result ← IO.wait promise.result!
          match result with
          | .error _ => return none
          | .ok none =>
            if buf.isEmpty then return none
            else
              bufRef.set ByteArray.empty
              return some bufStr.trim
          | .ok (some bytes) =>
            if bytes.isEmpty then
              if buf.isEmpty then return none
              else
                bufRef.set ByteArray.empty
                return some bufStr.trim
            else
              bufRef.set (buf ++ bytes)
              loop fuel
        else
          -- Found newline: first part is the line, rest is buffered
          let remainder := "\n".intercalate rest
          bufRef.set remainder.toUTF8
          return some line.trim
      | [] =>
        let promise ← sock.recv? 4096
        let result ← IO.wait promise.result!
        match result with
        | .error _ => return none
        | .ok none => return none
        | .ok (some bytes) =>
          bufRef.set (buf ++ bytes)
          loop fuel
  loop 1000

/-- Send a string response over the socket. -/
private def sendResponse (sock : Socket) (response : String) : IO Unit := do
  let promise ← sock.send response.toUTF8
  let _ ← IO.wait promise.result!

-- ===========================================================================
-- Connection Handler
-- ===========================================================================

/-- Handle a single client connection.
    Read loop: parse command → pure reconcileStep → send response.
    No K8s I/O happens here — strict separation from kubectl bridge. -/
def handleConnection (sock : Socket) (state : ServerState) : IO Unit := do
  let bufRef ← IO.mkRef ByteArray.empty
  let mut running := true
  while running do
    match ← readLine sock bufRef with
    | none =>
      running := false
    | some line =>
      -- Parse: pure (String → FlareEvent)
      let event := parseFlareCommand line
      -- Atomic read-modify-write: modifyGet uses Ref.take (destructive read)
      -- to prevent lost updates from concurrent handlers
      let crd ← state.crdSpec.get
      let (newState, response) ← state.clusterState.modifyGet fun cs =>
        let (newState, resp) := reconcileStep cs crd event
        ((newState, resp), newState)
      -- Trace logging
      match event with
      | .NodeAdd serverName serverPort =>
        let nodeKey := FlareClusterState.toNodeKey serverName serverPort
        match newState.lookupNode nodeKey with
        | some node =>
          if node.role == FlareRole.Master then
            IO.eprintln s!"[TRACE] Event: NodeAdd {nodeKey} | Result: Master P{node.partition} | Reason: partition needed master"
          else if node.role == FlareRole.Slave then
            IO.eprintln s!"[TRACE] Event: NodeAdd {nodeKey} | Result: Slave P{node.partition} (Prepare) | Reason: partition needed slave"
          else
            IO.eprintln s!"[TRACE] Event: NodeAdd {nodeKey} | Result: Proxy | Reason: all partitions full"
        | none => pure ()
      | .NodeState serverName serverPort _ =>
        let nodeKey := FlareClusterState.toNodeKey serverName serverPort
        match response with
        | .OK => IO.eprintln s!"[TRACE] Event: NodeState {nodeKey} | Result: Prepare->Active | Reason: reconstruction complete"
        | .ServerError msg => IO.eprintln s!"[TRACE] Event: NodeState {nodeKey} | Result: rejected | Reason: {msg}"
        | _ => pure ()
      | _ => pure ()
      -- Respond
      match response with
      | .CloseConnection =>
        running := false
      | _ =>
        sendResponse sock (serializeResponse response)

-- ===========================================================================
-- Server Entry Point
-- ===========================================================================

/-- Start the TCP server listening on the given port.
    Accepts connections in a loop and dispatches each to handleConnection
    via IO.asTask for concurrency. -/
def startServer (port : UInt16) (state : ServerState) : IO Unit := do
  let serverSocket ← Socket.new
  let addr := SocketAddress.v4 (SocketAddressV4.mk ⟨#v[0, 0, 0, 0]⟩ port)
  serverSocket.bind addr
  serverSocket.listen 128
  IO.eprintln s!"[flare-operator] TCP server listening on port {port}"
  let rec acceptLoop (fuel : Nat) : IO Unit := do
    match fuel with
    | 0 => return ()
    | fuel + 1 =>
      let promise ← serverSocket.accept
      let result ← IO.wait promise.result!
      match result with
      | .error e =>
        IO.eprintln s!"[flare-operator] accept error: {e}"
        acceptLoop fuel
      | .ok clientSocket =>
        -- Spawn handler as async task
        let _ ← IO.asTask (prio := .default) do
          try
            handleConnection clientSocket state
          catch e =>
            IO.eprintln s!"[flare-operator] connection error: {e}"
          let shutdownPromise ← clientSocket.shutdown
          let _ ← IO.wait shutdownPromise.result!
        acceptLoop fuel
  acceptLoop 1000000

/-- Convenience: start server from raw IO.Ref (backward compatible with Main.lean). -/
def startServerFromRefs (port : UInt16) (stateRef : IO.Ref FlareClusterState)
    (crdRef : IO.Ref FlareClusterView) : IO Unit :=
  startServer port (ServerState.fromRefs stateRef crdRef)

end FlareOperator.Server
