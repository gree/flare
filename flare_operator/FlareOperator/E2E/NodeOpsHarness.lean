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
import FlareOperator.K8s.Bridge
import FlareOperator.Kubectl
import Std.Data.HashMap

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

/-- The stats of the pod at `ip` with the debug pod's clock just before and
    just after (one exec): (ts, te, stats). -/
def Ctx.statsTimed (c : Ctx) (ip : String) : IO (Option (Nat × Nat × Option String)) := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"date +%s; printf 'stats\\r\\nquit\\r\\n' | nc -w 3 {ip} {c.cfg.flarePort}; date +%s" with
  | .error _ => return none
  | .ok o =>
    let ls := (o.splitOn "\n").map String.trim |>.filter (!·.isEmpty)
    match ls.head?.bind (·.toNat?), ls.getLast?.bind (·.toNat?) with
    | some a, some b => return some (a, b, if containsSubstr o "END" then some o else none)
    | _, _ => return none

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

/-- With the write authority ON: the master holds a REPLICATED grant (its
    successor's promise), not the solo grant it holds until the replica is
    Active. Solo -> replicated ends the solo grant first (write_promise.cc
    set_members), so a write started on the solo grant meets a gap of one
    promise round (39927176239 D: 49/50 seeded, the members record landed
    2 s after the replica turned Active). True when the authority is off. -/
def Ctx.authorityReady (c : Ctx) (master : String) : IO Bool := do
  if !containsSubstr c.cfg.extraFlaredConf "write-authority-enabled = true" then return true
  match ← FlareOperator.K8s.Bridge.queryPodStats master c.cfg.«namespace» "authority status 0" with
  | .ok t => return containsSubstr t "STAT grant_valid 1" && containsSubstr t "STAT members_mode replicated" && containsSubstr t "STAT grant_solo 0"
  | .error _ => return false

/-- Wait (bounded) for one master and one ACTIVE replica of partition 0, both
    Ready, on different data workers with a spare worker (and, authority ON,
    the master under its replicated grant); record it. -/
def Ctx.placement (c : Ctx) (timeoutSec : Nat := 300) : IO (Except String Placement) := do
  -- a fault injected during the operator's startup grace (dead-node
  -- detection off) measures the grace, not the product (39197119445 B:
  -- the worker stopped 57 s before "grace period over")
  let graceOver ← waitForCondition "operator past its startup grace period" 300 do
    return containsSubstr (← kubectlLogsLabel s!"app={c.cfg.operatorName}" c.cfg.«namespace» 10000000) "grace period over"
  if !graceOver then return .error (notSetUp "the operator never logged the end of its startup grace period")
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
          if (← c.authorityReady p.master.name) then
            c.art "conditions.txt" s!"placement master {p.master.name}@{p.master.node} replica {p.replica.name}@{p.replica.node} spare {p.spare}"
            return last
          last := .error (notSetUp s!"the master {p.master.name} does not hold a replicated write grant")
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

/-- The key and value prefix of one writer run: unique per suite, test and
    start (epoch), so a later writer on the same cluster never meets an
    earlier writer's identical key=value (280d928: C left wo_1..wo_29471 =
    v1..v29471 and C' reused them, so C' writes that never arrived looked
    delivered). Shell-safe: [a-z0-9-] only. -/
def writerRunId (suite test name : String) (startEpoch : Nat) : String :=
  let clean := fun (x : String) => String.map (fun ch => if ch.isAlphanum then ch.toLower else '-') x
  s!"{clean suite}-{clean test}-{clean name}-{startEpoch}"

def writerKey (pfx runId : String) (n : Nat) : String := s!"{pfx}_{runId}_{n}"
def writerValue (runId : String) (n : Nat) : String := s!"v{runId}-{n}"

/-- Start a writer that sets `<prefix>_<run>_<n>` = `v<run>-<n>` against
    `host` (a DNS name resolved on every write, or an IP) until
    /tmp/stop-<name> exists, then appends `END <n>`. Each line: n epoch
    address key value reply t0 (NORESOLVE / NORESPONSE when not observed). -/
def Ctx.startWriter (c : Ctx) (name host pfx : String) : IO Bool := do
  -- seconds + the monotonic nanoseconds and the process id: two starts in
  -- the same second (same or another harness process) do not collide
  let ns ← IO.monoNanosNow
  let pid ← IO.Process.getPID
  let runId := s!"{writerRunId c.suite c.test name (← epochNow)}-{pid}-{ns % 1000000000000}"
  let script := s!"n=0; out=/tmp/w-{name}.log; : > $out; rm -f /tmp/stop-{name}; while [ ! -f /tmp/stop-{name} ]; do n=$((n+1)); k={pfx}_{runId}_$n; v=v{runId}-$n; case {host} in *[a-z]*) ip=$(nslookup {host} 2>/dev/null | awk '/^Address/ \{a=$NF} END \{print a}');; *) ip={host};; esac; t0=$(date +%s); r=$(printf 'set %s 0 0 %d\\r\\n%s\\r\\n' \"$k\" $\{#v} \"$v\" | nc -w 3 \"$ip\" {c.cfg.flarePort} 2>/dev/null | head -1 | tr -d '\\r' | tr ' ' '_'); echo \"$n $(date +%s) $\{ip:-NORESOLVE} $k $v $\{r:-NORESPONSE} $t0\" >> $out; done; echo \"END $n\" >> $out"
  match ← kubectl ["exec", c.cfg.debugPod, "-n", c.cfg.«namespace», "--", "sh", "-c", s!"nohup sh -c '{script.replace "'" "'\\''"}' >/dev/null 2>&1 &"] with
  | .ok _ => c.event s!"writer {name} started against {host} (keys {writerKey pfx runId 0}.., values {writerValue runId 0}..)"; return true
  | .error e => c.event s!"writer {name} could not start: {e}"; return false

structure WriteRec where
  n : Nat
  t : Nat
  ip : String
  key : String
  value : String
  reply : String
  /-- when the request was sent (same clock as `t`, the debug pod's); the
      write was processed somewhere in [t0, t]. 0 = not recorded (older
      writer line format) -/
  t0 : Nat := 0
  deriving Repr

/-- The interval the write was processed in (`t0` unknown -> the writer's
    3 s nc timeout before `t`, conservative). -/
def WriteRec.span (w : WriteRec) : Nat × Nat := (if w.t0 == 0 then w.t - 4 else w.t0, w.t)

def parseWrites (out : String) : List WriteRec :=
  (out.splitOn "\n").filterMap fun l =>
    match (l.trim.splitOn " ").filter (!·.isEmpty) with
    | [n, t, ip, k, v, r] => (n.toNat?).bind fun n => (t.toNat?).map fun t => { n, t, ip, key := k, value := v, reply := r }
    | [n, t, ip, k, v, r, t0] => (n.toNat?).bind fun n => (t.toNat?).bind fun t => (t0.toNat?).map fun t0 => { n, t, ip, key := k, value := v, reply := r, t0 }
    | _ => none

/-- A writer's log after the stop. `complete` = it ends with the writer's own
    `END <n>` marker, written AFTER its last record, with `n` = the number of
    records: the writer stopped and nothing after record 1 was lost (a log
    that lost its tail cannot pass on the 1..N sequence alone — the marker
    carries N). -/
structure WriterLog where
  ws : List WriteRec
  complete : Bool
  note : Option String := none
  deriving Repr

/-- Check a writer log (review 2026-10-19/20): every complete line parses,
    the sequence is 1..N with no gap or repeat, at least one write was
    acknowledged. Only the LAST line may be cut short (the writer was stopped
    mid-append): it is dropped and the log is then NOT complete (an ack may
    have been in it). No end marker = not complete. An empty, corrupt or
    gapped log is an error — never "no write". -/
def parseWriterLog (out : String) : Except String WriterLog := do
  let endsNl := out.endsWith "\n"
  let ls := (out.splitOn "\n").filter (!·.isEmpty)
  if ls.isEmpty then throw "the writer log is empty"
  let (body, marker) := match ls.getLast? with
    | some l => if l.startsWith "END " then (ls.dropLast, (l.drop 4).trim.toNat?) else (ls, none)
    | none => (ls, none)
  let mut ws : List WriteRec := []
  let mut note : Option String := none
  let mut i := 0
  for l in body do
    i := i + 1
    match parseWrites l with
    | [w] => ws := ws ++ [w]
    | _ =>
      if i == body.length && marker.isNone && !endsNl then note := some s!"the last line was cut short and is not used: {l.take 80}"
      else throw s!"line {i} of the writer log does not parse: {l.take 80}"
  let ns := ws.map (·.n)
  if ns != (List.range ws.length).map (· + 1) then
    throw s!"the writer log's sequence is not 1..{ws.length} (a gap, repeat or reorder: starts {ns.take 5})"
  if !ws.any (fun w => w.reply == "STORED") then throw "the writer log has no acknowledged write"
  match marker with
  | some n =>
    if n != ws.length then throw s!"the writer's end marker says {n} records, the log has {ws.length} (records lost)"
    return { ws, complete := true }
  | none => return { ws, complete := false, note := some ((note.getD "") ++ " no end marker: the writer was not confirmed stopped") }

def Ctx.stopWriter (c : Ctx) (name : String) : IO (Option WriterLog) := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"touch /tmp/stop-{name}" with
  | .error e => c.event s!"writer {name}: the stop request failed ({e.take 120})"; return none
  | .ok _ => pure ()
  -- wait (bounded) for the writer's own end marker
  let mut ended := false
  for _ in [0:20] do
    if !ended then
      match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"tail -n 1 /tmp/w-{name}.log" with
      | .ok o => if o.trim.startsWith "END " then ended := true else IO.sleep 1000
      | .error _ => IO.sleep 1000
  if !ended then c.event s!"writer {name}: no end marker within 20 s of the stop request"
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"cat /tmp/w-{name}.log" with
  | .error e => c.event s!"writer {name}: the log cannot be read ({e.take 120})"; return none
  | .ok out =>
    match parseWriterLog out with
    | .error why => c.event s!"writer {name}: log REJECTED as unobserved — {why}"; return none
    | .ok wl =>
    if let some n := wl.note then c.event s!"writer {name}: {n}"
    for w in wl.ws do c.art s!"writes-{name}.txt" s!"{w.n} {w.t} {w.ip} {w.key} {w.value} {w.reply} {w.t0}"
    return some wl

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
  -- a hash index: a list lookup per write is quadratic (a long cut writes 10^5 keys)
  let idx : Std.HashMap String String := copy.foldl (fun m (k, v) => if m.contains k then m else m.insert k v) {}
  ws.filter fun w => classify w.reply == .ack && idx.get? w.key != some w.value

/-- Run `act` for at most `ms` milliseconds: `none` = the deadline passed first (the action is abandoned,
    not cancelled). Lets a test print its verdict before the leg's own timeout can kill the process. -/
def withDeadline {α : Type} (ms : UInt32) (act : IO α) : IO (Option α) := do
  let t ← IO.asTask act Task.Priority.dedicated
  let s ← IO.asTask (IO.sleep ms) Task.Priority.dedicated
  match ← IO.waitAny [t.map fun e => some e, s.map fun _ => none] with
  | some (.ok a) => pure (some a)
  | some (.error e) => throw e
  | none => pure none

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

/-- The kind node containers (empty = cannot be listed). -/
def kindNodes : IO (List String) := do
  match ← hostCmd "kind" ["get", "nodes", "--name", "flare-e2e"] with
  | .ok o => return (o.splitOn "\n").map String.trim |>.filter (!·.isEmpty)
  | .error _ => return []

/-! ## Fault injection: network cuts (review 2026-10-19 C')

    WHERE a packet meets netfilter decides which chain must drop it:
    * pod <-> pod / pod <-> operator: the packets are ROUTED by the kind node
      container that hosts the pod (veth -> eth0), so they cross that
      container's FORWARD chain — a FORWARD rule on every node container;
    * node <-> node (the kubelet -> API server, both kind containers on the
      docker bridge): the packets are LOCALLY generated / delivered in each
      container's own namespace — OUTPUT on the sender, INPUT on the
      receiver, never FORWARD. A FORWARD-only rule leaves this path open
      (acfa862 C': the master pod stayed Ready for the whole 330 s cut).
    Every rule must install, every rule's packet counter is recorded before
    the heal, and the cut is proven by real connections (see the probes);
    nothing here is taken as done because a command was issued. -/

structure CutRule where
  node : String
  chain : String
  src : String
  dst : String
  deriving Repr, BEq

/-- An IPv6 address goes to ip6tables (the kind docker network is dual-stack:
    e51ad45 C' dropped the kubelet's IPv4 packets yet its Lease kept
    renewing — hypothesis: the API server stayed reachable over IPv6). -/
def CutRule.v6 (r : CutRule) : Bool := r.src.contains ':'
def CutRule.tool (r : CutRule) : String := if r.v6 then "ip6tables" else "iptables"
def CutRule.args (r : CutRule) : List String := ["-s", r.src, "-d", r.dst, "-j", "DROP"]
def CutRule.label (r : CutRule) : String := s!"{r.node}:{r.tool}:{r.chain} {r.src}->{r.dst}"

/-- Pod-address pair: FORWARD, both directions, on every node container. -/
def podCutRules (nodes : List String) (a b : String) : List CutRule :=
  nodes.flatMap fun n => [{ node := n, chain := "FORWARD", src := a, dst := b }, { node := n, chain := "FORWARD", src := b, dst := a }]

/-- Node-address pair (containers `na` at `ia`, `nb` at `ib`): OUTPUT on the
    sender and INPUT on the receiver, both directions. -/
def nodeCutRules (na ia nb ib : String) : List CutRule :=
  [{ node := na, chain := "OUTPUT", src := ia, dst := ib }, { node := na, chain := "INPUT", src := ib, dst := ia },
   { node := nb, chain := "OUTPUT", src := ib, dst := ia }, { node := nb, chain := "INPUT", src := ia, dst := ib }]

/-- Every address family both containers have: IPv4 with IPv4, IPv6 with
    IPv6 (`as` / `bs` = the containers' addresses). -/
def nodeCutRulesAll (na : String) (as : List String) (nb : String) (bs : List String) : List CutRule :=
  as.flatMap fun ia => (bs.filter fun ib => ib.contains ':' == ia.contains ':').flatMap fun ib => nodeCutRules na ia nb ib

/-- Install every rule. `.ok installed` only when ALL installed; on a
    failure `.error (why, installed so far)` so the caller still removes
    what it put in place. -/
def installCuts (rules : List CutRule) : IO (Except (String × List CutRule) (List CutRule)) := do
  if rules.isEmpty then return .error ("no rule to install (no kind node / address resolved)", [])
  let mut done : List CutRule := []
  for r in rules do
    match ← hostCmd "docker" (["exec", r.node, r.tool, "-I", r.chain, "1"] ++ r.args) with
    | .ok _ => done := done ++ [r]
    | .error e => return .error (s!"{r.label}: {e}", done)
  return .ok done

/-- Remove the rules (every copy; idempotent). -/
def removeCuts (rules : List CutRule) : IO Unit := do
  for r in rules do
    for _ in [0:3] do
      discard <| hostCmd "docker" (["exec", r.node, r.tool, "-D", r.chain] ++ r.args)

/-- Packets dropped by the rule so far (`none` = the rule is not there or
    the counter cannot be read). -/
def cutCounter (r : CutRule) : IO (Option Nat) := do
  match ← hostCmd "docker" ["exec", r.node, r.tool, "-nvxL", r.chain] with
  | .error _ => return none
  | .ok out =>
    return (out.splitOn "\n").findSome? fun l =>
      let ws := (l.splitOn " ").filter (!·.isEmpty)
      -- pkts bytes target prot opt in out source destination
      match ws with
      -- ip6tables prints no `opt` column
      | pk :: _ :: "DROP" :: _ :: _ :: _ :: _ :: src :: dst :: _ =>
        if src == r.src && dst == r.dst then pk.toNat? else
        if !r.v6 then none else match ws with
          | pk :: _ :: "DROP" :: _ :: _ :: _ :: src :: dst :: _ => if (src == r.src || src == r.src ++ "/128") && (dst == r.dst || dst == r.dst ++ "/128") then pk.toNat? else none
          | _ => none
      | pk :: _ :: "DROP" :: _ :: _ :: _ :: src :: dst :: _ =>
        if r.v6 && (src == r.src || src == r.src ++ "/128") && (dst == r.dst || dst == r.dst ++ "/128") then pk.toNat? else none
      | _ => none

/-- What one HTTPS probe of an API server address found. -/
inductive ApiProbe where
  /-- an HTTP answer -/
  | open_
  /-- the connection timed out (what a DROP rule produces) -/
  | timedOut
  /-- refused / unreachable at once: nothing listens there (not a cut) -/
  | refused
  /-- the probe itself could not run or ended otherwise -/
  | cannotRun (why : String)
  deriving Repr, BEq

def ApiProbe.label : ApiProbe → String
  | .open_ => "open" | .timedOut => "timed-out" | .refused => "refused" | .cannotRun w => s!"cannot-run({w})"

def apiProbe (node addr : String) (port : Nat) : IO ApiProbe := do
  let host := if addr.contains ':' then s!"[{addr}]" else addr
  let out ← IO.Process.output { cmd := "docker", args := #["exec", node, "curl", "-gsk", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", s!"https://{host}:{port}/healthz"] }
  let code := out.stdout.trim
  if out.exitCode == 0 && !code.isEmpty && code != "000" then return .open_
  else if out.exitCode == 28 then return .timedOut
  else if out.exitCode == 7 then return .refused
  else return .cannotRun s!"exit {out.exitCode}"

/-- The API server the node's kubelet is configured for: (host, port) from
    the `server:` line of /etc/kubernetes/kubelet.conf (only that line is
    read; no credential leaves the container). -/
def kubeletServer (node : String) : IO (Option (String × Nat)) := do
  match ← hostCmd "docker" ["exec", node, "sh", "-c", "grep -m1 -E '^[[:space:]]*server:' /etc/kubernetes/kubelet.conf"] with
  | .error _ => return none
  | .ok o =>
    let url := ((o.trim.drop "server:".length).trim.replace "https://" "")
    let (host, port) := match url.splitOn "]:" with
      | [h, p] => (h.drop 1, p)
      | _ => match url.splitOn ":" with
        | [h, p] => (h, p)
        | _ => (url, "443")
    return (port.trim.toNat?).map fun n => (host, n)

/-- How the node resolves `host` (every address, both families). An IP
    literal resolves to itself. -/
def resolveOn (node host : String) : IO (List String) := do
  if host.all (fun ch => ch.isDigit || ch == '.') || host.contains ':' then return [host]
  match ← hostCmd "docker" ["exec", node, "getent", "ahosts", host] with
  | .error _ => return []
  | .ok o => return ((o.splitOn "\n").filterMap fun l => (l.trim.splitOn " ").head?.filter (!·.isEmpty)).eraseDups

/-- Peer addresses from `ss -Htn state established` lines (Recv-Q Send-Q
    Local Peer); IPv6 in brackets, IPv4-mapped IPv6 as IPv4. -/
def parseSsPeers (o : String) : List String :=
  ((o.splitOn "\n").filterMap fun l =>
    match (l.trim.splitOn " ").filter (!·.isEmpty) with
    | [_, _, _, peer] | [_, _, _, peer, _] =>
      let a := if peer.startsWith "[" then (peer.drop 1).takeWhile (· != ']') else (peer.dropRightWhile (· != ':')).dropRight 1
      if a.isEmpty then none else some (a.replace "::ffff:" "")
    | _ => none).eraseDups

/-- The peers of the node's ESTABLISHED TCP connections to `port` (the
    kubelet's live API connections, among any others to that port). -/
def establishedPeers (node : String) (port : Nat) : IO (Option (List String)) := do
  match ← hostCmd "docker" ["exec", node, "ss", "-Htn", "state", "established", s!"( dport = :{port} )"] with
  | .error _ => return none
  | .ok o => return some (parseSsPeers o)

/-- Can a TCP connection to `ip:port` be opened from inside `pod`
    (`container`)? `some true` = OPEN, `some false` = the connect TIMED OUT
    (timeout 124: a DROP), `none` = the probe could not tell (exec failed,
    no `timeout`, refused, any other exit) — never taken as a cut. -/
def tcpFromPod (ns pod container ip : String) (port : Nat) : IO (Option Bool) := do
  match ← kubectl ["exec", pod, "-n", ns, "-c", container, "--", "bash", "-c",
      s!"command -v timeout >/dev/null 2>&1 || \{ echo PROBE=none; exit 0; }; timeout 3 bash -c 'exec 3<>/dev/tcp/{ip}/{port}' 2>/dev/null; echo PROBE=$?"] with
  | .ok o =>
    if containsSubstr o "PROBE=0" then return some true
    else if containsSubstr o "PROBE=124" then return some false
    else return none
  | .error _ => return none

/-- A background observer: runs `once` in its own task, then waits
    `periodMs`, until `stop` is set; every result is appended in order. It
    is independent of whatever the caller does meanwhile (rule installation,
    probes with their timeouts, counter collection), so their duration never
    opens a gap in the observations. -/
structure Observer (α : Type) where
  stop : IO.Ref Bool
  acc : IO.Ref (Array α)
  task : Task (Except IO.Error Unit)

partial def observerLoop {α : Type} (once : IO α) (periodMs : Nat) (stop : IO.Ref Bool) (acc : IO.Ref (Array α)) : IO Unit := do
  if ← stop.get then return
  let x ← once
  acc.modify (·.push x)
  if ← stop.get then return
  IO.sleep periodMs.toUInt32
  observerLoop once periodMs stop acc

def startObserver {α : Type} (once : IO α) (periodMs : Nat) : IO (Observer α) := do
  let stop ← IO.mkRef false
  let acc ← IO.mkRef #[]
  let task ← IO.asTask (prio := .dedicated) (observerLoop once periodMs stop acc)
  return { stop, acc, task }

/-- Stop and collect (waits for the iteration in progress). An observer that
    ended with an exception is an ERROR (with how many readings it had), never
    a silently shorter list. -/
def Observer.finish {α : Type} (o : Observer α) : IO (Except String (List α)) := do
  o.stop.set true
  match ← IO.wait o.task with
  | .ok () => return .ok (← o.acc.get).toList
  | .error e => return .error s!"the observer failed after {(← o.acc.get).size} reading(s): {e}"

/-- What has been observed so far (the observer keeps running). -/
def Observer.sofar {α : Type} (o : Observer α) : IO (List α) := return (← o.acc.get).toList

/-- The node's Ready condition (`True` / `False` / `Unknown`). -/
def nodeReady (node : String) : IO (Option String) := do
  match ← kubectl ["get", "node", node, "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}"] with
  | .ok o => return if o.trim.isEmpty then none else some o.trim
  | .error _ => return none

/-- The node Lease's last heartbeat (kube-node-lease renewTime). -/
def nodeLeaseRenew (node : String) : IO (Option String) := do
  match ← kubectl ["get", "lease", node, "-n", "kube-node-lease", "-o", "jsonpath={.spec.renewTime}"] with
  | .ok o => return if o.trim.isEmpty then none else some o.trim
  | .error _ => return none

/-- A flared node's OWN view, read by the client (debug pod) from its stats:
    role in the map it accepted, that map's version, its boot id. -/
structure OwnV where
  role : String
  version : Nat
  boot : String
  deriving Repr, BEq

def ownVOf (out : String) : Option OwnV :=
  match statOf out "own_role", (statOf out "node_map_version").bind (·.toNat?), statOf out "reconstruction_boot_id" with
  | some r, some v, some b => if r == "unknown" then none else some { role := r, version := v, boot := b }
  | _, _, _ => none

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
