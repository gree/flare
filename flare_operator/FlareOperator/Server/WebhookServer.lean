/-
  WebhookServer.lean — plain-HTTP endpoint for the node-guard admission
  webhook (A0 stage 6b; taken from the SAF-10 branch unchanged in behaviour,
  flare-ci-inputs/decisions/A0-DESIGN-rc68.md). It listens on 127.0.0.1
  only: the API server reaches it through a TLS-terminating sidecar in the
  operator pod (the Lean runtime has no TLS). One POST per connection; the
  body is read up to its Content-Length (bounded).
-/
import Std.Internal.UV.TCP
import Std.Net.Addr

namespace FlareOperator.Server.WebhookServer

open Std.Internal.UV.TCP (Socket)
open Std.Net (SocketAddress SocketAddressV4)

/-- (header block, body so far) once the blank line has been seen. -/
def splitHead (s : String) : Option (String × String) :=
  match s.splitOn "\r\n\r\n" with
  | h :: rest => if rest.isEmpty then none else some (h, String.intercalate "\r\n\r\n" rest)
  | [] => none

def contentLength (head : String) : Option Nat :=
  (head.splitOn "\r\n").findSome? fun l =>
    let lower := l.toLower
    if lower.startsWith "content-length:" then (l.drop "content-length:".length).trim.toNat? else none

def respond (status : String) (body : String) : String :=
  s!"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {body.utf8ByteSize}\r\nConnection: close\r\n\r\n{body}"

private def closeQuietly (sock : Socket) : IO Unit := do
  try
    let p ← sock.shutdown
    let _ ← IO.wait p.result!
  catch _ => pure ()

/-- Read one request: head + body up to Content-Length (max 1 MiB). -/
private partial def readRequest (sock : Socket) (acc : ByteArray) : IO (Option (String × String)) := do
  let s := String.fromUTF8! acc
  match splitHead s with
  | some (head, body) =>
    let want := (contentLength head).getD 0
    if want > 1048576 then return none
    if body.utf8ByteSize ≥ want then return some (head, body)
    let p ← sock.recv? 65536
    match ← IO.wait p.result! with
    | .ok (some more) => readRequest sock (acc ++ more)
    | _ => return some (head, body)
  | none =>
    if acc.size > 65536 then return none
    let p ← sock.recv? 65536
    match ← IO.wait p.result! with
    | .ok (some more) => readRequest sock (acc ++ more)
    | _ => return none

/-- Serve POSTs on 127.0.0.1:`port` with `handler path body → reply body`. -/
def serve (port : UInt16) (handler : String → String → IO String) : IO Unit := do
  let server ← Socket.new
  server.bind (SocketAddress.v4 (SocketAddressV4.mk ⟨#v[127, 0, 0, 1]⟩ port))
  server.listen 64
  IO.eprintln s!"[WebhookServer] listening on 127.0.0.1:{port} (TLS terminated by the sidecar)"
  let rec loop (fuel : Nat) : IO Unit := do
    match fuel with
    | 0 => return ()
    | fuel + 1 =>
      let p ← server.accept
      match ← IO.wait p.result! with
      | .error e =>
        IO.eprintln s!"[WebhookServer] accept error: {e}"
        loop fuel
      | .ok client =>
        let _ ← IO.asTask (prio := .dedicated) do
          try
            match ← readRequest client ByteArray.empty with
            | none =>
              let r := respond "400 Bad Request" "{}"
              let sp ← client.send r.toUTF8
              let _ ← IO.wait sp.result!
            | some (head, body) =>
              let path := ((head.splitOn "\r\n").head?.map fun l => ((l.splitOn " ").drop 1).headD "/").getD "/"
              let out ← handler path body
              let sp ← client.send (respond "200 OK" out).toUTF8
              let _ ← IO.wait sp.result!
          catch e =>
            IO.eprintln s!"[WebhookServer] handler error: {e}"
          closeQuietly client
        loop fuel
  loop 100000000

def serveBackground (port : UInt16) (handler : String → String → IO String) : IO Unit := do
  let _ ← IO.asTask (prio := .dedicated) do
    try serve port handler
    catch e => IO.eprintln s!"[WebhookServer] stopped: {e}"
  pure ()

end FlareOperator.Server.WebhookServer
