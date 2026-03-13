/-
  HealthCheck.lean - Kubernetes health check endpoints

  Provides HTTP endpoints for K8s liveness and readiness probes:
  - /healthz: Liveness probe (operator is running)
  - /readyz: Readiness probe (leader elected, TCP server listening)
-/

import Std.Internal.UV.TCP
import Std.Net.Addr

namespace FlareOperator.Health.HealthCheck

open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4 IPv4Addr)

/-! ## Health Status Tracking -/

/-- Operator health status -/
structure HealthStatus where
  /-- Whether the operator is the current leader -/
  isLeader : IO.Ref Bool
  /-- Whether the TCP server (port 12120) is listening -/
  tcpServerReady : IO.Ref Bool
  deriving Nonempty

/-- Create new health status tracker -/
def HealthStatus.new : IO HealthStatus := do
  let isLeader ← IO.mkRef false
  let tcpServerReady ← IO.mkRef false
  return { isLeader := isLeader, tcpServerReady := tcpServerReady }

/-- Update leader status -/
def HealthStatus.setLeader (status : HealthStatus) (leader : Bool) : IO Unit := do
  status.isLeader.set leader

/-- Update TCP server status -/
def HealthStatus.setTcpServerReady (status : HealthStatus) (ready : Bool) : IO Unit := do
  status.tcpServerReady.set ready

/-- Check if operator is ready (for /readyz endpoint) -/
def HealthStatus.isReady (status : HealthStatus) : IO Bool := do
  let leader ← status.isLeader.get
  let tcpReady ← status.tcpServerReady.get
  return leader && tcpReady

/-! ## HTTP Request Parsing -/

/-- Simple HTTP request parser -/
structure HttpRequest where
  method : String
  path : String
  deriving Repr

/-- Parse HTTP request line (GET /healthz HTTP/1.1) -/
private def parseRequestLine (line : String) : Option (String × String) := do
  let parts := line.split (· == ' ')
  match parts with
  | [method, path, _version] => some (method, path)
  | _ => none

/-- Parse HTTP request from string -/
def parseHttpRequest (data : String) : Option HttpRequest := do
  let lines := data.split (· == '\n')
  guard (!lines.isEmpty)

  let (method, path) ← parseRequestLine lines.head!

  return { method := method, path := path }

/-! ## HTTP Responses -/

/-- Simple HTTP response -/
structure HttpResponse where
  statusCode : Nat
  statusText : String
  contentType : String
  body : String

/-- Create 200 OK response -/
def okResponse (body : String) : HttpResponse :=
  { statusCode := 200
    statusText := "OK"
    contentType := "text/plain; charset=utf-8"
    body := body }

/-- Create 503 Service Unavailable response -/
def serviceUnavailableResponse (body : String) : HttpResponse :=
  { statusCode := 503
    statusText := "Service Unavailable"
    contentType := "text/plain; charset=utf-8"
    body := body }

/-- Create 404 Not Found response -/
def notFoundResponse : HttpResponse :=
  { statusCode := 404
    statusText := "Not Found"
    contentType := "text/plain; charset=utf-8"
    body := "404 Not Found\n" }

/-- Format HTTP response -/
def formatHttpResponse (resp : HttpResponse) : String :=
  "HTTP/1.1 " ++ toString resp.statusCode ++ " " ++ resp.statusText ++ "\r\n" ++
  "Content-Type: " ++ resp.contentType ++ "\r\n" ++
  "Content-Length: " ++ toString resp.body.length ++ "\r\n" ++
  "\r\n" ++
  resp.body

/-! ## Health Check Handlers -/

/-- Handle /healthz endpoint (liveness probe) -/
def handleHealthz : IO HttpResponse := do
  -- If we can respond, we're alive
  return okResponse "OK\n"

/-- Handle /readyz endpoint (readiness probe) -/
def handleReadyz (status : HealthStatus) : IO HttpResponse := do
  let ready ← status.isReady
  if ready then
    return okResponse "Ready\n"
  else
    let leader ← status.isLeader.get
    let tcpReady ← status.tcpServerReady.get
    let reason :=
      if !leader then "not leader"
      else if !tcpReady then "TCP server not ready"
      else "unknown"
    return serviceUnavailableResponse s!"Not ready: {reason}\n"

/-- Handle single HTTP request -/
private def handleClient (sock : Socket) (status : HealthStatus) : IO Unit := do
  try
    -- Read request (simplified - read up to 4KB)
    let promise ← sock.recv? 4096
    let result ← IO.wait promise.result!

    match result with
    | .error e =>
      IO.eprintln s!"[HealthCheck] Error reading request: {e}"
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
      pure ()
    | .ok none =>
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
      pure ()
    | .ok (some received) =>
      let requestData := String.fromUTF8! received

      -- Parse HTTP request and generate response
      let response ← match parseHttpRequest requestData with
        | none =>
          pure (formatHttpResponse notFoundResponse)
        | some req =>
          -- Handle health endpoints
          if req.path.startsWith "/healthz" then do
            let resp ← handleHealthz
            pure (formatHttpResponse resp)
          else if req.path.startsWith "/readyz" then do
            let resp ← handleReadyz status
            pure (formatHttpResponse resp)
          else
            pure (formatHttpResponse notFoundResponse)

      -- Send response and close
      let sendPromise ← sock.send response.toUTF8
      let _ ← IO.wait sendPromise.result!
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
      pure ()

  catch e =>
    IO.eprintln s!"[HealthCheck] Error handling client: {e}"
    try
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
      pure ()
    catch _ =>
      pure ()

/-! ## Health Check HTTP Server -/

/-- Health server configuration -/
structure ServerConfig where
  port : UInt16 := 8080
  host : String := "0.0.0.0"

/-- Start health check HTTP server -/
def startHealthServer (status : HealthStatus) (config : ServerConfig := {}) : IO Unit := do
  IO.eprintln s!"[HealthCheck] Starting health check server on {config.host}:{config.port}"

  -- Create server socket
  let serverSocket ← Socket.new

  -- Bind address
  let addr := SocketAddress.v4 (SocketAddressV4.mk ⟨#v[0, 0, 0, 0]⟩ config.port)
  serverSocket.bind addr
  serverSocket.listen 128

  IO.eprintln s!"[HealthCheck] Listening on port {config.port}"
  IO.eprintln s!"[HealthCheck] Endpoints: /healthz (liveness), /readyz (readiness)"

  -- Accept connections loop
  let rec acceptLoop (fuel : Nat) : IO Unit := do
    match fuel with
    | 0 => return ()
    | fuel + 1 =>
      let promise ← serverSocket.accept
      let result ← IO.wait promise.result!

      match result with
      | .error e =>
        IO.eprintln s!"[HealthCheck] Accept error: {e}"
        acceptLoop fuel
      | .ok clientSocket =>
        -- Handle request in background task
        let _ ← IO.asTask (prio := .default) do
          try
            handleClient clientSocket status
          catch e =>
            IO.eprintln s!"[HealthCheck] Handler error: {e}"
        acceptLoop fuel

  acceptLoop 1000000

/-- Start health server in background task -/
def startHealthServerBackground (status : HealthStatus) (config : ServerConfig := {}) : IO Unit := do
  let _ ← IO.asTask (prio := .default) do
    startHealthServer status config
  pure ()

end FlareOperator.Health.HealthCheck
