/-
  TcpServer.lean - Native Socket TCP server on :12120
  Uses Lean 4 Std.Internal.UV.TCP for the flarei text protocol
-/

import Std.Internal.UV.TCP
import Std.Net.Addr
import FlareOperator.K8s.FlareCluster
import FlareOperator.Flare.Protocol
import FlareOperator.StateMachine.Reconciler

namespace FlareOperator.TcpServer

open FlareOperator.K8s
open FlareOperator.Flare
open FlareOperator.Reconciler
open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4 IPv4Addr)

/-- Read data from a socket and split into a line (up to \n, trimming \r\n). -/
private def readLine (sock : Socket) (bufRef : IO.Ref ByteArray) : IO (Option String) := do
  let rec loop (fuel : Nat) : IO (Option String) := do
    match fuel with
    | 0 => return none
    | fuel + 1 =>
      -- Check if buffer already contains a newline
      let buf ← bufRef.get
      let bufStr := String.fromUTF8! buf
      match bufStr.splitOn "\n" with
      | line :: rest =>
        if rest.isEmpty then
          -- No newline found yet, read more data
          let promise ← sock.recv? 4096
          let result ← IO.wait promise.result!
          match result with
          | .error _ => return none
          | .ok none => -- Connection closed
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
          -- Found a newline: line is the first part, rest is remainder
          let remainder := "\n".intercalate rest
          bufRef.set remainder.toUTF8
          return some line.trim
      | [] =>
        -- Empty split result, read more
        let promise ← sock.recv? 4096
        let result ← IO.wait promise.result!
        match result with
        | .error _ => return none
        | .ok none => return none
        | .ok (some bytes) =>
          bufRef.set (buf ++ bytes)
          loop fuel
  loop 1000  -- fuel limit to ensure termination

/-- Send a string response over the socket. -/
private def sendResponse (sock : Socket) (response : String) : IO Unit := do
  let promise ← sock.send response.toUTF8
  let _ ← IO.wait promise.result!
  return ()

/-- Handle a single client connection. -/
def handleConnection (sock : Socket) (stateRef : IO.Ref FlareClusterState)
    (crdRef : IO.Ref FlareClusterView) : IO Unit := do
  let bufRef ← IO.mkRef ByteArray.empty
  let mut running := true
  while running do
    match ← readLine sock bufRef with
    | none =>
      running := false
    | some line =>
      let event := parseFlareCommand line
      let crd ← crdRef.get
      let state ← stateRef.get
      let (newState, response) := reconcileStep state crd event
      stateRef.set newState
      match response with
      | .CloseConnection =>
        running := false
      | _ =>
        sendResponse sock (serializeResponse response)

/-- Start the TCP server listening on the given port. -/
def startServer (port : UInt16) (stateRef : IO.Ref FlareClusterState)
    (crdRef : IO.Ref FlareClusterView) : IO Unit := do
  let serverSocket ← Socket.new
  let addr := SocketAddress.v4 (SocketAddressV4.mk ⟨#v[0, 0, 0, 0]⟩ port)
  serverSocket.bind addr
  serverSocket.listen 128
  IO.eprintln s!"[flare-operator] TCP server listening on port {port}"
  -- Accept loop
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
            handleConnection clientSocket stateRef crdRef
          catch e =>
            IO.eprintln s!"[flare-operator] connection error: {e}"
          let shutdownPromise ← clientSocket.shutdown
          let _ ← IO.wait shutdownPromise.result!
          return ()
        acceptLoop fuel
  acceptLoop 1000000  -- large fuel for long-running server

end FlareOperator.TcpServer
