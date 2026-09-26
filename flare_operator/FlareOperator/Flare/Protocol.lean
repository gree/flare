/-
  FlareOperator - Flare Protocol Parser & Serializer
  Based on C++ src/flarei/op_parser_text_index.cc and src/lib/cluster.cc
-/

import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Flare

open FlareOperator.K8s

/-! ## FlareEvent -/

inductive FlareEvent where
  | Ping
  | Meta
  | Stats
  /-- flarei-compatible `stats nodes` — what flare-tools' flare-admin uses
      to list the cluster's nodes. -/
  | StatsNodes
  | Version
  | Quit
  | NodeAdd (serverName : String) (serverPort : Nat)
  | NodeSync (nodeMapVersion : Option Nat)
  | NodeRemove (serverName : String) (serverPort : Nat)
  | NodeState (serverName : String) (serverPort : Nat) (newState : FlareState)
  | MutationAttempt (raw : String)
  | ParseError (raw : String)
  deriving Repr

/-! ## FlareResponse -/

inductive FlareResponse where
  | OK
  | End (lines : List String)
  /-- Bare line(s) with NO trailing END terminator. flarei's `version` reply
      is exactly one line; appending END desyncs clients that read one line
      per response (flare-tools read the leftover END as the NEXT command's
      reply — every subsequent response was off by one, observed live). -/
  | Raw (lines : List String)
  | ServerError (msg : String)
  | Error
  | CloseConnection
  deriving Repr

/-! ## Parser -/

/-- Parse a natural number from a string. Returns 0 on failure. -/
private def parseNat (s : String) : Option Nat :=
  s.toNat?

/-- Parse state from string (e.g., "active", "prepare", "ready", "down") or number.
    Matches C++ cluster::state_cast() behavior. -/
private def parseStateString (s : String) : Option FlareState :=
  match s.trim.toLower with
  | "active" => some .Active
  | "prepare" => some .Prepare
  | "down" => some .Down
  | "ready" => some .Ready
  | _ => s.toNat? >>= FlareState.fromNat

/-- Parse a flare protocol command line (total, pure). -/
def parseFlareCommand (line : String) : FlareEvent :=
  let trimmed := line.trim
  let words := trimmed.splitOn " " |>.filter (· != "")
  match words with
  | [] => FlareEvent.ParseError trimmed
  | ["ping"] => FlareEvent.Ping
  | ["meta"] => FlareEvent.Meta
  | ["stats"] => FlareEvent.Stats
  | ["stats", "nodes"] => FlareEvent.StatsNodes
  | ["version"] => FlareEvent.Version
  | ["quit"] => FlareEvent.Quit
  | "node" :: "add" :: name :: portStr :: _ =>
    match parseNat portStr with
    | some port => FlareEvent.NodeAdd name port
    | none => FlareEvent.ParseError trimmed
  | "node" :: "sync" :: rest =>
    match rest with
    | [] => FlareEvent.NodeSync none
    | vStr :: _ =>
      match parseNat vStr with
      | some v => FlareEvent.NodeSync (some v)
      | none => FlareEvent.NodeSync none
  | "node" :: "remove" :: name :: portStr :: _ =>
    match parseNat portStr with
    | some port => FlareEvent.NodeRemove name port
    | none => FlareEvent.ParseError trimmed
  | "node" :: "role" :: _ => FlareEvent.MutationAttempt trimmed
  | "node" :: "state" :: name :: portStr :: stateStr :: _ =>
    match parseNat portStr, parseStateString stateStr with
    | some port, some st => FlareEvent.NodeState name port st
    | _, _ => FlareEvent.ParseError trimmed
  | "node" :: "state" :: _ => FlareEvent.ParseError trimmed
  | _ => FlareEvent.ParseError trimmed

/-! ## Serializer -/

def serializeRole (r : FlareRole) : String := toString r.toNat
def serializeState (s : FlareState) : String := toString s.toNat

/-- Serialize a node in wire format: NODE <name> <port> <role> <state> <partition> <balance> <thread_type> -/
def serializeNode (n : FlareNode) : String :=
  s!"NODE {n.serverName} {n.serverPort} {serializeRole n.role} {serializeState n.state} {n.partition} {n.balance} {n.threadType}\r\n"

/-- Serialize a list of nodes followed by END. -/
def serializeNodeList (nodes : List FlareNode) : String :=
  let lines := nodes.map serializeNode
  String.join lines ++ "END\r\n"

/-- Serialize META response with cluster state. -/
def serializeMeta (cs : FlareClusterState) : String :=
  let metaLines :=
    s!"META partition-size {cs.partitionSize}\r\n" ++
    s!"META key-hash-algorithm {cs.keyHashAlgorithm}\r\n" ++
    s!"META partition-type modular\r\n" ++
    s!"META partition-modular-hint 1\r\n" ++
    s!"META partition-modular-virtual 4096\r\n" ++
    s!"META node_map_version {cs.nodeMapVersion}\r\n"
  metaLines ++ "END\r\n"

def serializeOK : String := "OK\r\n"
def serializeServerError (msg : String) : String := s!"SERVER_ERROR {msg}\r\n"
def serializeError : String := "ERROR\r\n"

/-- Serialize a FlareResponse to wire format. -/
def serializeResponse (resp : FlareResponse) : String :=
  match resp with
  | .OK => serializeOK
  | .End lines => String.join (lines.map (· ++ "\r\n")) ++ "END\r\n"
  | .Raw lines => String.join (lines.map (· ++ "\r\n"))
  | .ServerError msg => serializeServerError msg
  | .Error => serializeError
  | .CloseConnection => ""

/-! ## #eval tests -/

#eval parseFlareCommand "ping"           -- Ping
#eval parseFlareCommand "meta"           -- Meta
#eval parseFlareCommand "quit"           -- Quit
#eval parseFlareCommand "node add host1 1234"  -- NodeAdd
#eval parseFlareCommand "node sync"      -- NodeSync none
#eval parseFlareCommand "node sync 5"    -- NodeSync (some 5)
#eval parseFlareCommand "node remove host1 1234"  -- NodeRemove
#eval parseFlareCommand "node role host1 1234 master 100 0"  -- MutationAttempt
#eval parseFlareCommand "node state host1 1234 0"       -- NodeState Active
#eval parseFlareCommand ""               -- ParseError

end FlareOperator.Flare
