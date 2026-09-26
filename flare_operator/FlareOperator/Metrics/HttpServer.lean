/-
  HttpServer.lean - Simple HTTP server for Prometheus metrics endpoint

  Listens on port 9090 and serves /metrics endpoint
-/

import FlareOperator.Metrics.Prometheus
import Std.Internal.UV.TCP
import Std.Net.Addr

namespace FlareOperator.Metrics.HttpServer

open FlareOperator.Metrics.Prometheus
open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4 IPv4Addr)

/-! ## HTTP Request Parsing -/

/-- Simple HTTP request parser -/
structure HttpRequest where
  method : String
  path : String
  headers : List (String × String)
  deriving Repr

/-- Parse HTTP request line (GET /metrics HTTP/1.1) -/
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

  -- Parse headers (simplified, just for completeness)
  let headers := []

  return { method := method, path := path, headers := headers }

/-! ## HTTP Server -/

/-- Metrics HTTP server configuration -/
structure ServerConfig where
  port : UInt16 := 9090
  host : String := "0.0.0.0"

/-- Simple HTTP response -/
structure HttpResponse where
  statusCode : Nat
  statusText : String
  contentType : String
  body : String

/-- Create 200 OK response with metrics -/
def metricsResponse (body : String) : HttpResponse :=
  { statusCode := 200
    statusText := "OK"
    contentType := "text/plain; version=0.0.4"
    body := body }

/-- Create 404 Not Found response -/
def notFoundResponse : HttpResponse :=
  { statusCode := 404
    statusText := "Not Found"
    contentType := "text/plain"
    body := "404 Not Found\n" }

/-- Format HTTP response -/
def formatHttpResponse (resp : HttpResponse) : String :=
  "HTTP/1.1 " ++ toString resp.statusCode ++ " " ++ resp.statusText ++ "\r\n" ++
  "Content-Type: " ++ resp.contentType ++ "\r\n" ++
  "Content-Length: " ++ toString resp.body.length ++ "\r\n" ++
  "\r\n" ++
  resp.body

/-- Handle single HTTP request -/
private def handleClient (sock : Socket) (metrics : OperatorMetrics) (clusterName : String) : IO Unit := do
  try
    -- Read request (simplified - read up to 4KB)
    let promise ← sock.recv? 4096
    let result ← IO.wait promise.result!

    match result with
    | .error e =>
      IO.eprintln s!"[MetricsServer] Error reading request: {e}"
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
        | none => pure (formatHttpResponse notFoundResponse)
        | some req =>
          -- Handle /metrics endpoint
          if req.path.startsWith "/metrics" then do
            let metricsBody ← exportMetrics metrics clusterName
            pure (formatHttpResponse (metricsResponse metricsBody))
          else
            pure (formatHttpResponse notFoundResponse)

      -- Send response and close
      let sendPromise ← sock.send response.toUTF8
      let _ ← IO.wait sendPromise.result!
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
      pure ()

  catch e =>
    IO.eprintln s!"[MetricsServer] Error handling client: {e}"
    try
      let shutdownPromise ← sock.shutdown
      let _ ← IO.wait shutdownPromise.result!
      pure ()
    catch _ =>
      pure ()

/-- Start metrics HTTP server -/
def startMetricsServer (metrics : OperatorMetrics) (clusterName : String) (config : ServerConfig := {}) : IO Unit := do
  IO.eprintln s!"[MetricsServer] Starting HTTP server on {config.host}:{config.port}"

  -- Create server socket
  let serverSocket ← Socket.new

  -- Bind address
  let addr := SocketAddress.v4 (SocketAddressV4.mk ⟨#v[0, 0, 0, 0]⟩ config.port)
  serverSocket.bind addr
  serverSocket.listen 128

  IO.eprintln s!"[MetricsServer] Listening on port {config.port}"

  -- Accept connections loop
  let rec acceptLoop (fuel : Nat) : IO Unit := do
    match fuel with
    | 0 => return ()
    | fuel + 1 =>
      let promise ← serverSocket.accept
      let result ← IO.wait promise.result!

      match result with
      | .error e =>
        IO.eprintln s!"[MetricsServer] Accept error: {e}"
        acceptLoop fuel
      | .ok clientSocket =>
        -- Handle request in background task
        let _ ← IO.asTask (prio := .default) do
          try
            handleClient clientSocket metrics clusterName
          catch e =>
            IO.eprintln s!"[MetricsServer] Handler error: {e}"
        acceptLoop fuel

  acceptLoop 1000000

/-- Start metrics server in background task -/
def startMetricsServerBackground (metrics : OperatorMetrics) (clusterName : String) (config : ServerConfig := {}) : IO Unit := do
  let _ ← IO.asTask (prio := .default) do
    startMetricsServer metrics clusterName config
  pure ()

end FlareOperator.Metrics.HttpServer
