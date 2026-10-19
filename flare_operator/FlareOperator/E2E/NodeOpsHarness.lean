/-
  E2E/NodeOpsHarness.lean — harness for the node-operations suites
  (docs/design-node-operations-2026-10-19.md §4.1).

  Runs on the multi-node kind cluster (.github/kind/multinode.yaml): the
  operator and the debug pod on the control-plane, flared one pod per data
  worker. What it guarantees about its own observations:

  * a placement that is not "master and replica on different data workers,
    with a spare data worker" is PRECONDITION NOT MET, never a verdict;
  * every client write is recorded with its target address and its reply;
    no reply / no address is UNOBSERVED — never counted as a success or as
    a failure of the product;
  * a write is classified LOCAL (its target was the partition master in the
    nearest earlier map sample) or PROXY (any other node), or UNKNOWN (no
    sample yet);
  * a copy that cannot be read is UNOBSERVABLE, never "empty";
  * the conditions, the SHA under test, a timeline (map roles, pods, nodes,
    per-copy positions every ~2 s), every acknowledged key and value, and
    each copy's final own content are written under
    $FLARE_E2E_LOG_DIR/node-ops/<suite>/<test>/.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.Kubectl

namespace FlareOperator.E2E.NodeOps

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

/-- Precondition failure: not a verdict on the product. -/
def notSetUp (what : String) : String := s!"PRECONDITION NOT MET (not a data verdict): {what}"
/-- A required observation failed: neither a pass nor data loss. -/
def unobservable (what : String) : String := s!"UNOBSERVABLE (not a data verdict): {what}"

def nowSec : IO Nat := return (← IO.monoMsNow) / 1000

def utcNow : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }
  return out.stdout.trim

def epochNow : IO Nat := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%s"] }
  return out.stdout.trim.toNat?.getD 0

def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

structure Ctx where
  cfg : ClusterConfig
  suite : String
  test : String

/-- The artifact directory of this test (created), `none` outside CI. -/
def Ctx.dir (c : Ctx) : IO (Option String) := do
  let some root ← IO.getEnv "FLARE_E2E_LOG_DIR" | return none
  let d := s!"{root}/node-ops/{c.suite}/{c.test}"
  discard <| IO.Process.output { cmd := "mkdir", args := #["-p", d] }
  return some d

/-- Append a line to an artifact file of this test (and nothing outside CI). -/
def Ctx.art (c : Ctx) (file line : String) : IO Unit := do
  let some d ← c.dir | return
  let h ← IO.FS.Handle.mk s!"{d}/{file}" .append
  h.putStrLn line
  h.flush

def Ctx.event (c : Ctx) (what : String) : IO Unit := do
  let t ← utcNow
  IO.eprintln s!"# [{c.test}] {t} {what}"
  c.art "timeline.txt" s!"{t} EVENT {what}"

/-- The test conditions and the SHA under test (first artifact). -/
def Ctx.conditions (c : Ctx) (lines : List String) : IO Unit := do
  let sha := ((← IO.getEnv "GITHUB_SHA").getD "local")
  for l in [s!"sha {sha}", s!"suite {c.suite}", s!"test {c.test}", s!"namespace {c.cfg.«namespace»}",
            s!"partitions {c.cfg.partitions} replicas {c.cfg.replicas} backend {c.cfg.storageBackend} tmpfs {c.cfg.useTmpfs} pvc {c.cfg.usePvc}",
            s!"drainSeconds {c.cfg.drainSeconds} pdbMaxUnavailable {c.cfg.pdbMaxUnavailable}"] ++ lines do
    c.art "conditions.txt" l

/-! ## Cluster observation -/

structure PodRow where
  name : String
  node : String
  uid : String
  ip : String
  ready : Bool
  deleting : Bool
  deriving Repr, BEq

/-- The cluster's flared pods (by the `cluster=` label). -/
def Ctx.pods (c : Ctx) : IO (Option (List PodRow)) := do
  match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"cluster={c.cfg.name}", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.spec.nodeName}|{.metadata.uid}|{.status.podIP}|{.status.conditions[?(@.type==\"Ready\")].status}|{.metadata.deletionTimestamp}{\"\\n\"}{end}"] with
  | .error _ => return none
  | .ok out =>
    return some ((out.splitOn "\n").filterMap fun l =>
      match (l.trim.splitOn "|") with
      | [n, nd, u, ip, r, del] => if n.isEmpty then none else some { name := n, node := nd, uid := u, ip := ip, ready := r == "True", deleting := !del.isEmpty }
      | _ => none)

/-- Data workers (label flare-e2e/data=true) that are schedulable. -/
def dataWorkers : IO (List String) := do
  match ← kubectl ["get", "nodes", "-l", "flare-e2e/data=true", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.spec.unschedulable}{\"\\n\"}{end}"] with
  | .error _ => return []
  | .ok out => return (out.splitOn "\n").filterMap fun l =>
      match l.trim.splitOn "|" with
      | [n, u] => if n.isEmpty || u == "true" then none else some n
      | _ => none

def Ctx.nodeView (c : Ctx) : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd c.cfg.debugPod c.cfg.«namespace» c.cfg.operatorName c.cfg.operatorPort "node sync"
  return parseNodeSync sync

def podOfFqdn (fqdn : String) : String := (fqdn.splitOn ".").headD fqdn

/-- (master pod, replica pods) of partition 0 in the operator's map; `none`
    when the map cannot be read. -/
def Ctx.roles (c : Ctx) : IO (Option (Option String × List String)) := do
  let v ← c.nodeView
  if v.isEmpty then return none
  let m := (findMasterFqdn v 0).map podOfFqdn
  let s := (v.filter fun e => e.role == 1 && e.partition == 0).map (podOfFqdn ·.fqdn)
  return some (m, s)

/-- One flared stat of the pod at `ip` (from the debug pod). -/
def Ctx.stats (c : Ctx) (ip : String) : IO (Option String) := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf 'stats\\r\\nquit\\r\\n' | nc -w 3 {ip} {c.cfg.flarePort}" with
  | .error _ => return none
  | .ok o => return if containsSubstr o "END" then some o else none

def statOf (out key : String) : Option String :=
  ((out.splitOn "\n").map (fun l => (l.replace "\r" "").trim)).findSome? fun l =>
    if l.startsWith s!"STAT {key} " then some (l.drop (s!"STAT {key} ").length) else none

/-- Every key and value in the copy at `ip` (`dump`); `none` = unreadable. -/
def Ctx.ownCopy (c : Ctx) (ip : String) : IO (Option (List (String × String))) := do
  match ← hostCmd "timeout" ["-k", "5", "120", "kubectl", "exec", c.cfg.debugPod, "-n", c.cfg.«namespace», "--", "sh", "-c",
      s!"printf 'dump 0 -1 0 0\\r\\nquit\\r\\n' | nc -w 90 {ip} {c.cfg.flarePort}"] with
  | .error _ => return none
  | .ok out =>
    let mut acc : List (String × String) := []
    let mut pending : Option String := none
    let mut ended := false
    for raw in out.splitOn "\n" do
      let l := (raw.replace "\r" "").trim
      match pending with
      | some k =>
        acc := (k, l) :: acc
        pending := none
      | none =>
        if l.startsWith "VALUE " then pending := ((l.splitOn " ").drop 1).head?
        else if l == "END" then ended := true
    return if ended then some acc.reverse else none

/-! ## Placement -/

structure Placement where
  master : PodRow
  replica : PodRow
  spare : List String
  deriving Repr

def placementVerdict (masterPod : Option String) (replicas : List String) (pods : List PodRow) (workers : List String) :
    Except String Placement :=
  match masterPod with
  | none => .error (notSetUp "no master of partition 0 in the operator's map")
  | some mp =>
    match pods.find? (·.name == mp), replicas.head? with
    | none, _ => .error (notSetUp s!"the master {mp} is not among the cluster's pods")
    | _, none => .error (notSetUp "no replica of partition 0 in the operator's map")
    | some m, some rp =>
      match pods.find? (·.name == rp) with
      | none => .error (notSetUp s!"the replica {rp} is not among the cluster's pods")
      | some r =>
        if m.node.isEmpty || r.node.isEmpty then .error (notSetUp "a pod is not scheduled")
        else if m.node == r.node then .error (notSetUp s!"master {m.name} and replica {r.name} are on the SAME worker {m.node}")
        else if !workers.contains m.node || !workers.contains r.node then .error (notSetUp s!"a copy is not on a data worker ({m.node}, {r.node})")
        else
          let spare := workers.filter fun w => w != m.node && w != r.node
          if spare.isEmpty then .error (notSetUp "no spare data worker to relocate to")
          else .ok { master := m, replica := r, spare }

/-- Wait (bounded) for one master and one ACTIVE replica of partition 0, both
    Ready, on different data workers with a spare worker; record it. -/
def Ctx.placement (c : Ctx) (timeoutSec : Nat := 300) : IO (Except String Placement) := do
  let mut last : Except String Placement := .error (notSetUp "not observed")
  let deadline := (← nowSec) + timeoutSec
  repeat
    let pods ← c.pods
    let roles ← c.roles
    let ws ← dataWorkers
    let v ← c.nodeView
    match pods, roles with
    | some ps, some (m, rs) =>
      let activeRs := rs.filter fun r => v.any fun e => podOfFqdn e.fqdn == r && e.state == 0
      last := placementVerdict m activeRs ps ws
      match last with
      | .ok p =>
        if p.master.ready && p.replica.ready then
          c.art "conditions.txt" s!"placement master {p.master.name}@{p.master.node} replica {p.replica.name}@{p.replica.node} spare {p.spare}"
          return last
      | .error _ => pure ()
    | _, _ => last := .error (unobservable "the pods or the operator's map could not be read")
    if (← nowSec) ≥ deadline then break
    IO.sleep 3000
  return last

/-! ## Timeline -/

/-- One timeline sample: map roles, pods (node, ready, deleting, ip) and each
    copy's positions. Returns the parsed (epoch, master pod, pod ips). -/
def Ctx.sample (c : Ctx) : IO (Nat × Option String × List (String × String)) := do
  let t ← epochNow
  let roles ← c.roles
  let pods := (← c.pods).getD []
  let mut copies : List String := []
  for p in pods do
    if p.ip.isEmpty then copies := copies ++ [s!"{p.name}:noip"] else
    match ← c.stats p.ip with
    | none => copies := copies ++ [s!"{p.name}:unreadable"]
    | some o =>
      copies := copies ++ [s!"{p.name}:items={(statOf o "curr_items").getD "?"},seq={(statOf o "rocksdb_latest_sequence_number").getD "?"},applied={(statOf o "repl_applied_lsn").getD "?"},follow={(statOf o "repl_follow_state").getD "?"}"]
  let rolesTxt := match roles with
    | none => "map=unreadable"
    | some (m, rs) => s!"master={m.getD "none"} replicas={rs}"
  let podsTxt := String.intercalate " " (pods.map fun p => s!"{p.name}@{p.node}/{p.ip}/ready={p.ready}/deleting={p.deleting}")
  -- the partition Service (ClusterIP) and the pod its selector names: a
  -- write through it is attributed to that pod
  let svc ← match ← kubectl ["get", "svc", s!"{c.cfg.name}-0", "-n", c.cfg.«namespace», "-o",
      "jsonpath={.spec.clusterIP}|{.spec.selector.statefulset\\.kubernetes\\.io/pod-name}"] with
    | .ok o => match o.trim.splitOn "|" with
      | [ip, pod] => if ip.isEmpty || pod.isEmpty then pure none else pure (some (ip, pod))
      | _ => pure none
    | .error _ => pure none
  let svcTxt := match svc with | some (ip, pod) => s!"svc {ip}->{pod}" | none => "svc unreadable"
  c.art "timeline.txt" s!"{t} SAMPLE {rolesTxt} | {svcTxt} | {podsTxt} | {String.intercalate " " copies}"
  return (t, (roles.bind (·.1)), pods.map (fun p => (p.ip, p.name)) ++ svc.toList)

/-! ## Client writers (in the debug pod) -/

/-- Start a writer that sets `<prefix>_<n>` = `v<n>` against `host` (a DNS
    name resolved on every write, or an IP) until /tmp/stop-<name> exists.
    Each line: n epoch address key value reply (NORESOLVE / NORESPONSE when
    not observed). -/
def Ctx.startWriter (c : Ctx) (name host pfx : String) : IO Bool := do
  let script := s!"n=0; out=/tmp/w-{name}.log; : > $out; rm -f /tmp/stop-{name}; while [ ! -f /tmp/stop-{name} ]; do n=$((n+1)); k={pfx}_$n; v=v$n; case {host} in *[a-z]*) ip=$(nslookup {host} 2>/dev/null | awk '/^Address/ \{a=$NF} END \{print a}');; *) ip={host};; esac; r=$(printf 'set %s 0 0 %d\\r\\n%s\\r\\n' \"$k\" $\{#v} \"$v\" | nc -w 3 \"$ip\" {c.cfg.flarePort} 2>/dev/null | head -1 | tr -d '\\r' | tr ' ' '_'); echo \"$n $(date +%s) $\{ip:-NORESOLVE} $k $v $\{r:-NORESPONSE}\" >> $out; done"
  match ← kubectl ["exec", c.cfg.debugPod, "-n", c.cfg.«namespace», "--", "sh", "-c", s!"nohup sh -c '{script.replace "'" "'\\''"}' >/dev/null 2>&1 &"] with
  | .ok _ => c.event s!"writer {name} started against {host} (keys {pfx}_N)"; return true
  | .error e => c.event s!"writer {name} could not start: {e}"; return false

structure WriteRec where
  n : Nat
  t : Nat
  ip : String
  key : String
  value : String
  reply : String
  deriving Repr

def parseWrites (out : String) : List WriteRec :=
  (out.splitOn "\n").filterMap fun l =>
    match (l.trim.splitOn " ").filter (!·.isEmpty) with
    | [n, t, ip, k, v, r] => (n.toNat?).bind fun n => (t.toNat?).map fun t => { n, t, ip, key := k, value := v, reply := r }
    | _ => none

def Ctx.stopWriter (c : Ctx) (name : String) : IO (Option (List WriteRec)) := do
  discard <| execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"touch /tmp/stop-{name}"
  IO.sleep 4000
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"cat /tmp/w-{name}.log" with
  | .error _ => return none
  | .ok out =>
    let ws := parseWrites out
    for w in ws do c.art s!"writes-{name}.txt" s!"{w.n} {w.t} {w.ip} {w.key} {w.value} {w.reply}"
    return some ws

/-- Reply classes: an acknowledgement, an explicit error, or unobserved. -/
inductive Reply where
  | ack
  | error
  | unobserved
  deriving BEq, Repr

def classify (r : String) : Reply :=
  if r == "STORED" then .ack
  else if r == "NORESPONSE" || r == "NORESOLVE" then .unobserved
  else .error

/-- LOCAL (the target was the master in the nearest earlier sample), PROXY,
    or UNKNOWN (no earlier sample). `samples` = (epoch, master pod, ip→pod). -/
def pathOf (samples : List (Nat × Option String × List (String × String))) (w : WriteRec) : String :=
  match (samples.filter fun (t, _, _) => t ≤ w.t).getLast? with
  | none => "unknown"
  | some (_, m, ips) =>
    match ips.lookup w.ip with
    | none => "unknown"
    | some pod => if m == some pod then "local" else "proxy"

/-- Acknowledged writes absent (or with another value) in `copy`. -/
def missingAcks (ws : List WriteRec) (copy : List (String × String)) : List WriteRec :=
  ws.filter fun w => classify w.reply == .ack && copy.lookup w.key != some w.value

/-- Summary line of one writer's records (for the report). -/
def writerSummary (name : String) (samples : List (Nat × Option String × List (String × String))) (ws : List WriteRec) : String :=
  let acks := ws.filter (classify ·.reply == .ack)
  let errs := ws.filter (classify ·.reply == .error)
  let unobs := ws.filter (classify ·.reply == .unobserved)
  let nLocal := (acks.filter fun w => pathOf samples w == "local").length
  let proxy := (acks.filter fun w => pathOf samples w == "proxy").length
  let span := fun (l : List WriteRec) => match l.head?, l.getLast? with
    | some a, some b => s!"{a.t}..{b.t}"
    | _, _ => "-"
  s!"writer {name}: {ws.length} writes, {acks.length} acknowledged ({nLocal} local, {proxy} proxy, {acks.length - nLocal - proxy} unknown path), {errs.length} errors ({span errs}), {unobs.length} unobserved ({span unobs})"

/-! ## Faults -/

/-- Run `kubectl drain` (Eviction API, PDB honoured; no --disable-eviction, no
    --force) in the background; its output and exit code land in the debug
    host's /tmp. Returns the file stem. -/
def startDrain (node : String) (timeoutSec : Nat) : IO String := do
  let stem := s!"/tmp/drain-{node}-{← epochNow}"
  discard <| IO.Process.output { cmd := "sh", args := #["-c",
    s!"(kubectl drain {node} --ignore-daemonsets --delete-emptydir-data --timeout={timeoutSec}s > {stem}.out 2>&1; echo $? > {stem}.rc) >/dev/null 2>&1 &"] }
  return stem

/-- `some (exit code, output)` once the drain finished. -/
def drainResult (stem : String) : IO (Option (String × String)) := do
  try
    let rc ← IO.FS.readFile s!"{stem}.rc"
    let out ← (try IO.FS.readFile s!"{stem}.out" catch _ => pure "")
    return some (rc.trim, out)
  catch _ => return none

def uncordon (node : String) : IO Unit := discard <| kubectl ["uncordon", node]

/-- Stop / start a kind node container (the whole worker becomes unreachable). -/
def stopWorker (node : String) : IO (Except String String) := hostCmd "docker" ["stop", "-t", "0", node]
def startWorker (node : String) : IO (Except String String) := hostCmd "docker" ["start", node]

/-- Drop traffic between two addresses (both directions) on every kind node,
    so pod-to-pod traffic across workers is cut wherever it is forwarded. -/
def kindNodes : IO (List String) := do
  match ← hostCmd "kind" ["get", "nodes", "--name", "flare-e2e"] with
  | .ok o => return (o.splitOn "\n").map String.trim |>.filter (!·.isEmpty)
  | .error _ => return []

def cutRule (a b : String) : List String := ["-s", a, "-d", b, "-j", "DROP"]

def cutBetween (a b : String) : IO Bool := do
  let mut ok := true
  for n in ← kindNodes do
    for (x, y) in [(a, b), (b, a)] do
      match ← hostCmd "docker" (["exec", n, "iptables", "-I", "FORWARD", "1"] ++ cutRule x y) with
      | .ok _ => pure ()
      | .error _ => ok := false
  return ok

def healBetween (a b : String) : IO Unit := do
  for n in ← kindNodes do
    for (x, y) in [(a, b), (b, a)] do
      for _ in [0:3] do
        discard <| hostCmd "docker" (["exec", n, "iptables", "-D", "FORWARD"] ++ cutRule x y)

/-- Delay every packet leaving a kind node by `ms` (tc netem on eth0), or
    remove the delay (`ms = 0`). Used to widen the window in which an
    acknowledged write has not reached the replica yet, so a drain that does
    not wait for it can be caught losing it (deterministic enough to compare
    old and new code; the delay is recorded in the conditions). -/
def netemDelay (node : String) (ms : Nat) : IO Bool := do
  discard <| hostCmd "docker" ["exec", node, "tc", "qdisc", "del", "dev", "eth0", "root"]
  if ms == 0 then return true
  match ← hostCmd "docker" ["exec", node, "tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", s!"{ms}ms"] with
  | .ok _ => return true
  | .error e => IO.eprintln s!"# netem on {node} failed: {e}"; return false

end FlareOperator.E2E.NodeOps
