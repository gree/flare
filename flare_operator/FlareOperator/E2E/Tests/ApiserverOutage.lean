/-
  E2E/Tests/ApiserverOutage.lean — what flare does while the kube-apiserver is
  down (issue flare-e2e-apiserver-outage). No product change: this suite
  characterises, and asserts only what the data path must keep.

  The kube-apiserver of a kind cluster is a static pod on the control-plane
  node container; it is stopped by moving its manifest out of
  /etc/kubernetes/manifests and started by moving it back. While it is down
  `kubectl` cannot be used, so everything during the outage is measured by the
  in-cluster load writer (LoadWriter.lean, as NodeOpsSwitch does: 4 writers via
  the partition Service, 2 via the all-pods Service, replies required) and read
  back after the API returns, or by `docker exec` on the node containers.

  T1  long outage (~120 s): 0 write errors, 0 acknowledged writes missing; the
      operator leader exits on the lost lease, a leader resumes after the API
      returns and the cluster settles (one master, map version not lower).
  T2  short blip (10 s, the API port dropped with iptables on the control-plane
      node so the window is exact; restoring the static pod took 25 s in
      43692989177; the 10 s run from the iptables insert to its removal, with
      1 s resolution, and SUMMARY prints the measured value): 0 errors, 0
      missing, and NOTHING happens: the operator
      container does not restart, logs no LOST LEASE, the operator pod is the
      same, the master and the node map version are unchanged. With the port
      dropped the renewal's kubectl call waits (30 s wall, Kubectl.lean) and
      succeeds when the port opens. An API that REFUSES connections (T1, the
      static pod stopped) fails the renewal at once and the operator exits on
      that first failure (Main.lean; flare-operator-lease-renew-tolerance).
  T3  API down + the master's flared killed (-9, from the node; the kubelet
      restarts the container, the emptyDir is kept): errors are CHARACTERISED
      (per type, window, whether the restarted flared serves before the API
      returns), and after the API returns every acknowledged write is on the
      master and the replica, with one master and a settled cluster.
  T4  the order T3 reaches only by chance: with the API port dropped, the
      master's flared restarts and registers with the still-running operator,
      which then exits on the failed renewal; the next leader resumes from the
      persisted map that still names that node master. The new master tenure
      is recorded in the authoritative history, no replica rebuild is held on
      it, and 0 acknowledged writes are missing.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.E2E.LoadWriter
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.ApiserverOutage

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl

/-- 1 partition x 2 replicas, rocksdb on tmpfs (an emptyDir survives a
    container restart), one flared pod per data worker. -/
def cfg : ClusterConfig :=
  { name := "node-apiout", «namespace» := "flare-node-apiout", partitions := 1, replicas := 2,
    debugPod := "debug-node-apiout", storageBackend := "rocksdb", useTmpfs := true, usePvc := false,
    drainSeconds := 60, pdbMaxUnavailable := some 1, multiNode := true }

private def ctx : Ctx := { cfg := cfg, suite := "apiserver-outage", test := "apiserver-outage" }

private def manifest : String := "/etc/kubernetes/manifests/kube-apiserver.yaml"
private def parked : String := "/etc/kubernetes/kube-apiserver.yaml"

private def cpNode : IO (Option String) := return (← kindNodes).find? (containsSubstr · "control-plane")

private def apiReady : IO Bool := do
  match ← hostCmd "kubectl" ["get", "--raw", "/readyz", "--request-timeout=4s"] with
  | .ok o => return o.trim == "ok"
  | .error _ => return false

/-- Poll `check` every 2 s for up to `secs`; the seconds it took, or `none`. -/
private def pollFor (secs : Nat) (check : IO Bool) : IO (Option Nat) := do
  let t0 ← nowSec
  repeat
    if ← check then return some ((← nowSec) - t0)
    if (← nowSec) - t0 ≥ secs then return none
    IO.sleep 2000
  return none

/-- Idempotent: a no-op when the manifest is already in place. -/
private def apiStart (cp : String) : IO Unit :=
  discard <| hostCmd "docker" ["exec", cp, "sh", "-c", s!"if [ -f {parked} ]; then mv {parked} {manifest}; fi"]

private def apiStop (cp : String) : IO (Except String String) :=
  hostCmd "docker" ["exec", cp, "sh", "-c", s!"mv {manifest} {parked}"]

/-- The API port dropped on the control-plane node: every client (pods via the
    Service DNAT, the kubelets, the runner's port mapping) reaches it through
    INPUT. Exact on and off, unlike restarting the static pod. -/
private def dropRule : List String := ["INPUT", "-p", "tcp", "--dport", "6443", "-j", "DROP"]

private def apiDrop (cp : String) : IO (Except String String) :=
  hostCmd "docker" (["exec", cp, "iptables", "-I"] ++ dropRule)

/-- Idempotent: removes every copy of the rule. -/
private def apiUndrop (cp : String) : IO Unit :=
  discard <| hostCmd "docker" ["exec", cp, "sh", "-c",
    s!"while iptables -C {" ".intercalate dropRule} 2>/dev/null; do iptables -D {" ".intercalate dropRule}; done"]

private def operatorPod (c : Ctx) : IO (Option (String × String)) := do
  match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app={c.cfg.operatorName}", "-o",
      "jsonpath={range .items[*]}{.metadata.name}|{.spec.nodeName}{\"\\n\"}{end}"] with
  | .ok o =>
    match (o.splitOn "\n").filter (!·.trim.isEmpty) with
    | [l] => match l.trim.splitOn "|" with
      | [n, nd] => return some (n, nd)
      | _ => return none
    | _ => return none
  | .error _ => return none

private def operatorRestarts (c : Ctx) (pod : String) : IO (Option Nat) := do
  match ← kubectl ["get", "pod", pod, "-n", c.cfg.«namespace», "-o",
      "jsonpath={.status.containerStatuses[?(@.name==\"flare-operator\")].restartCount}"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- Operator log lines on its node (works with the API down): every container
    incarnation's file under /var/log/pods, lines mentioning the lease and
    stamped at or after `sinceSec` (epoch seconds) — the earlier tests' lines
    are in the same files. -/
private def operatorLeaseLines (c : Ctx) (node pod : String) (sinceSec : Nat) : IO (List String) := do
  match ← hostCmd "docker" ["exec", node, "sh", "-c",
      s!"s=$(date -u -d @{sinceSec} +%Y-%m-%dT%H:%M:%S); cat /var/log/pods/{c.cfg.«namespace»}_{pod}_*/flare-operator/*.log 2>/dev/null | sort | awk -v s=\"$s\" 'substr($1,1,19) >= s' | grep -i 'lease' | tail -n 60"] with
  | .ok o => return (o.splitOn "\n").filter (!·.trim.isEmpty)
  | .error _ => return []

private def lostLease (ls : List String) : Bool := ls.any (containsSubstr · "LOST LEASE")

private def operatorSettled (c : Ctx) : IO Bool :=
  waitForCondition "the operator's startup grace period is over" 300 do
    return containsSubstr (← kubectlLogsLabel s!"app={c.cfg.operatorName}" c.cfg.«namespace» 5000) "grace period over"

/-- Settled: the operator answers, exactly one master and an ACTIVE replica of
    partition 0 in its map, every flared pod Ready and not deleting, and
    exactly one pod that says it is the master. -/
private def settled (c : Ctx) : IO Bool := do
  let some ps ← c.pods | return false
  let v ← c.nodeView
  let masters := v.filter fun e => e.role == 0 && e.state == 0 && e.partition == 0
  let some (some _, rs) ← c.roles | return false
  let activeR := rs.filter fun r => v.any fun e => podOfFqdn e.fqdn == r && e.state == 0
  if masters.length != 1 || activeR.isEmpty || ps.length != c.cfg.replicas
      || !ps.all (fun (r : PodRow) => r.ready && !r.deleting) then return false
  let mut own := 0
  for p in ps do
    match ← c.stats p.ip with
    | some o => if statOf o "own_role" == some "master" then own := own + 1
    | none => return false
  return own == 1

private def masterMapVersion (c : Ctx) : IO (Option Nat) := do
  let some (some m, _) ← c.roles | return none
  let some ps ← c.pods | return none
  let some p := ps.find? (·.name == m) | return none
  return (← c.stats p.ip).bind (statOf · "node_map_version") |>.bind (·.toNat?)

private def killFlared (node uid : String) : IO (Except String String) := do
  let u := uid.replace "-" "_"
  hostCmd "docker" ["exec", node, "sh", "-c",
    s!"n=0; for p in $(pgrep -x flared); do if grep -q -e '{uid}' -e '{u}' /proc/$p/cgroup 2>/dev/null; then kill -9 $p && n=$((n+1)); fi; done; echo killed=$n"]

inductive Kind where
  | long
  | blip
  | killMaster
  deriving BEq

private def Kind.label : Kind → String
  | .long => "long outage (~120 s)"
  | .blip => "short blip (10 s, API port dropped)"
  | .killMaster => "outage (~90 s) with the master's flared killed"

private def Kind.outageSecs : Kind → Nat
  | .long => 120
  | .blip => 10
  | .killMaster => 90

private def nowUs : IO Nat := return (← epochNow) * 1000000

private def outageTest (c : Ctx) (k : Kind) : IO TestResult := do
  let some cp ← cpNode | return .fail (notSetUp "no control-plane container among the kind nodes")
  try
    match ← c.placement with
    | .error e => return .fail e
    | .ok p =>
      if !(← operatorSettled c) then return .fail (notSetUp "the operator did not finish its startup grace period")
      if !(← waitForCondition "the cluster is settled before the outage" 300 (settled c)) then
        return .fail (notSetUp "the cluster was not settled (one master, active replica) at the start")
      c.conditions [s!"apiserver-outage: {k.label}, under a load of 4 x 200/s via the partition Service and 2 x 200/s via the all-pods Service"]
      match ← c.ensureLoadWriter with
      | .error e => return .fail (notSetUp e)
      | .ok () => pure ()
      let ns := c.cfg.«namespace»
      let svcHost := s!"{c.cfg.name}-0.{ns}.svc.cluster.local"
      let peerHost := s!"{c.cfg.name}-nodes-external.{ns}.svc.cluster.local"
      let some (opPod, opNode) ← operatorPod c | return .fail (notSetUp "the operator pod could not be identified")
      let r0 := (← operatorRestarts c opPod).getD 0
      let v0 ← masterMapVersion c
      if !(← c.startLoad "svc" svcHost 4 200) then return .fail (notSetUp "the client-path load did not start")
      if !(← c.startLoad "peer" peerHost 2 200) then return .fail (notSetUp "the all-pods load did not start")
      IO.sleep 10000
      -- API down
      c.event s!"stopping the kube-apiserver on {cp} (master {p.master.name}@{p.master.node}, operator {opPod}@{opNode} restarts {r0}, map v{v0})"
      match ← (if k == .blip then apiDrop cp else apiStop cp) with
      | .error e => return .fail (notSetUp s!"the kube-apiserver could not be stopped: {e.take 200}")
      | .ok _ => pure ()
      let downUs ← nowUs
      match ← pollFor 120 (return !(← apiReady)) with
      | none => return .fail (notSetUp "the kube-apiserver still answered /readyz 120 s after its manifest was moved")
      | some s => c.event s!"/readyz fails after {s} s"
      let mut killUs : Option Nat := none
      let mut killOut := ""
      -- the window is measured from the stop itself (downUs), not from when
      -- /readyz first failed: a dropped port makes that check wait out its 4 s
      -- request timeout first
      let deadline := downUs / 1000000 + k.outageSecs
      if k == .killMaster then
        IO.sleep 15000
        killUs ← some <$> nowUs
        match ← killFlared p.master.node p.master.uid with
        | .ok o => killOut := o.trim
        | .error e => killOut := s!"kill failed: {e.take 200}"
        c.event s!"killed the master's flared on {p.master.node}: {killOut}"
      -- while the API is down: node-side evidence (no kubectl)
      repeat
        if let some _ := killUs then
          match ← hostCmd "docker" ["exec", p.master.node, "sh", "-c", "crictl ps -a --name flared 2>&1 | tail -n 4"] with
          | .ok o => for l in o.splitOn "\n" do if !l.trim.isEmpty then c.art "node-containers.txt" s!"{← epochNow} {l}"
          | .error _ => pure ()
        let now ← epochNow
        if now ≥ deadline then break
        IO.sleep ((min 5 (deadline - now)) * 1000).toUInt32
      -- API back (first, so nothing else lengthens the window)
      if k == .blip then apiUndrop cp else apiStart cp
      let restoreUs ← nowUs
      let leaseLines ← operatorLeaseLines c opNode opPod (downUs / 1000000)
      for l in leaseLines do c.art "operator-lease-lines.txt" l
      let some secs := ← pollFor 300 apiReady
        | return .fail "the kube-apiserver did not answer /readyz within 300 s after its manifest was restored"
      let upUs ← nowUs
      c.event s!"/readyz ok again after {secs} s; stopped for {(restoreUs - downUs) / 1000000} s (stop to restore), {(upUs - downUs) / 1000000} s until /readyz answered"
      let kubectlOk ← waitForCondition "kubectl works again" 120 do
        return (← kubectl ["get", "nodes"]) matches .ok _
      if !kubectlOk then return .fail "kubectl did not work within 120 s after the kube-apiserver returned"
      -- the operator after the API returned
      let opAfter ← operatorPod c
      let rAfter ← match opAfter with
        | some (n, _) => operatorRestarts c n
        | none => pure none
      let restarts := (rAfter.getD r0) - r0
      let exited ← if k == .long then
          pure (match ← pollFor 120 (do return ((← operatorRestarts c opPod).getD r0) > r0) with | some _ => true | none => false)
        else pure (decide (restarts > 0))
      let restarts2 := ((← operatorRestarts c opPod).getD r0) - r0
      c.event s!"operator container restarts during the window: {restarts2} (lease lines: {leaseLines.length}, LOST LEASE seen: {lostLease leaseLines})"
      let settledAfter ← waitForCondition "the cluster is settled after the API returned" 420 (settled c)
      let v1 ← masterMapVersion c
      let masterAfter := (← c.roles).bind (·.1)
      -- the load
      let svc? ← c.stopLoad "svc" 4
      let peer? ← c.stopLoad "peer" 2
      let (some svcRes, some peerRes) := (svc?, peer?)
        | return .fail (unobservable "a load log could not be read or failed its integrity check")
      let svcS := loadStats svcRes
      let peerS := loadStats peerRes
      let recs := svcRes.recs ++ peerRes.recs
      let acks : List WriteRec := (recs.filter (·.ack)).map (·.toWrite)
      -- the copies
      let ps := (← c.pods).getD []
      let newM := (← c.roles).bind (·.1)
      let copyOf := fun (pod : String) => do
        match ps.find? (·.name == pod) with
        | some p => if p.ip.isEmpty then pure none else c.ownCopy p.ip
        | none => pure none
      let masterCopy ← match newM with | some m => copyOf m | none => pure none
      let mm ← match masterCopy with
        | some d =>
          let miss := missingAcks acks d
          for w in miss.take 2000 do c.art "missing.txt" s!"master {w.key}={w.value} acked t={w.t} via {w.ip}"
          pure (some miss.length)
        | none => pure none
      let replicaPod := (ps.find? (fun (r : PodRow) => some r.name != newM)).map (·.name)
      let mr ← do
        let mut last : Option Nat := none
        for _ in [0:12] do
          if last != some 0 then
            match replicaPod with
            | none => pure ()
            | some r =>
              match ← copyOf r with
              | some d =>
                let miss := missingAcks acks d
                last := some miss.length
                if miss.length != 0 then
                  c.art "missing.txt" s!"replica {r}: {miss.length} acknowledged write(s) not yet there"
              | none => last := none
            if last != some 0 then IO.sleep 10000
        pure last
      -- summary
      let errs := svcS.errors + peerS.errors
      let kinds := svcS.errorKinds ++ peerS.errorKinds
      let gap := max svcS.maxStallUs peerS.maxStallUs
      let ms := fun (us : Nat) => s!"{us / 1000} ms"
      let errUs := (recs.filter (!·.ack)).map (·.t0)
      let errWindow := match errUs.min?, errUs.max? with
        | some a, some b => s!"{a / 1000000 - downUs / 1000000} .. {b / 1000000 - downUs / 1000000} s after the API stopped"
        | _, _ => "none"
      let servedBeforeUp := match killUs with
        | some ku => (recs.filter fun (r : LoadRec) => r.ack && r.t0 ≥ ku && r.t1 ≤ upUs).length
        | none => 0
      let summary := s!"SUMMARY [{k.label}]: stopped {(restoreUs - downUs) / 1000000} s (stop to restore, 1 s resolution), errors {errs} by type {kinds} (window {errWindow}), missing on master {mm} / replica {mr}, max no-ACK gap {ms gap}, operator restarts {restarts2}, acks after the kill and before the API returned {servedBeforeUp}, map v{v0} -> v{v1}, settled {settledAfter}"
      IO.eprintln s!"# [apiserver-outage] {summary}"
      c.art "report.txt" summary
      c.art "report.txt" (svcS.summary "svc")
      c.art "report.txt" (peerS.summary "peer")
      -- verdict
      if !settledAfter then return .fail s!"the cluster did not settle (one master, active replica, all pods Ready) within 420 s after the API returned. {summary}"
      match mm, mr with
      | none, _ => return .fail (unobservable "the final master's copy could not be read")
      | _, none => return .fail (unobservable "the replica's copy could not be read")
      | some a, some b =>
        if a != 0 || b != 0 then return .fail s!"DATA: {a} acknowledged write(s) missing on the final master, {b} on the replica. {summary}"
      match k with
      | .long =>
        if errs != 0 then return .fail s!"WRITE ERRORS during the outage. {summary}"
        if !exited || !lostLease leaseLines then
          return .fail s!"the operator did not exit on the lost lease (restarted={exited}, LOST LEASE logged={lostLease leaseLines}; operator-lease-lines.txt). {summary}"
        match v0, v1 with
        | some a, some b => if b < a then return .fail s!"the node map version went back ({a} -> {b}). {summary}"
        | _, _ => return .fail s!"the node map version could not be read ({v0} -> {v1}). {summary}"
      | .blip =>
        if errs != 0 then return .fail s!"WRITE ERRORS during the blip. {summary}"
        c.art "report.txt" s!"blip: operator restarts {restarts2}, LOST LEASE logged {lostLease leaseLines}, master {p.master.name} -> {masterAfter}"
        if restarts2 != 0 || lostLease leaseLines then
          return .fail s!"the operator leader restarted or lost its lease in a 10 s blip (restarts {restarts2}, LOST LEASE {lostLease leaseLines}; operator-lease-lines.txt). {summary}"
        if (opAfter.map (·.1)) != some opPod then
          return .fail s!"the operator pod was replaced in a 10 s blip ({opPod} -> {opAfter.map (·.1)}). {summary}"
        if masterAfter != some p.master.name then
          return .fail s!"the master changed in a 10 s blip ({p.master.name} -> {masterAfter}). {summary}"
        match v0, v1 with
        | some a, some b => if a != b then return .fail s!"the node map version changed in a 10 s blip ({a} -> {b}). {summary}"
        | _, _ => return .fail s!"the node map version could not be read ({v0} -> {v1}). {summary}"
      | .killMaster =>
        if killOut != "killed=1" then return .fail (notSetUp s!"the master's flared was not killed ({killOut})")
      return .pass
  finally
    apiUndrop cp
    apiStart cp

private def flaredRestarts (c : Ctx) (pod : String) : IO (Option Nat) := do
  match ← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.status.containerStatuses[?(@.name==\"flared\")].restartCount}" with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- Seconds the pod's flared container has been running, or `none`. -/
private def flaredUptime (c : Ctx) (pod : String) : IO (Option Nat) := do
  let .ok ts ← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.status.containerStatuses[?(@.name==\"flared\")].state.running.startedAt}"
    | return none
  if ts.isEmpty then return none
  let .ok s ← hostCmd "date" ["-u", "-d", ts, "+%s"] | return none
  return s.trim.toNat?.map ((← epochNow) - ·)

/-- Operator log lines on its node (works with the API unreachable), stamped at
    or after `sinceSec`, matching the extended regular expression `re`. -/
private def operatorLogLines (c : Ctx) (node pod : String) (sinceSec : Nat) (re : String) : IO (List String) := do
  match ← hostCmd "docker" ["exec", node, "sh", "-c",
      s!"s=$(date -u -d @{sinceSec} +%Y-%m-%dT%H:%M:%S); cat /var/log/pods/{c.cfg.«namespace»}_{pod}_*/flare-operator/*.log 2>/dev/null | sort | awk -v s=\"$s\" 'substr($1,1,19) >= s' | grep -E '{re}' | tail -n 80"] with
  | .ok o => return (o.splitOn "\n").filter (!·.trim.isEmpty)
  | .error _ => return []

/-- A4: the order A3 reaches only by chance (44459609204 attempts 1 and 2,
    read from their logs). The API is unreachable but the operator leader still
    runs (its lease renewal waits on the dropped port); the master's flared is
    killed, restarts with the same copy and registers with that operator, whose
    changes now stay in memory; the operator then exits on the failed renewal,
    and the next leader loads the persisted map, which still names that node
    master. The restarted flared takes the role again and starts a new master
    tenure (a new epoch, reason "promotion") with no operator intent. The
    authoritative history must record that tenure ("resumed as the partition's
    master"); before ddd2a0a5 it stayed at the old epoch, the replica's rebuild
    from the master was held forever ("REBUILD HELD (history)") and the replica
    missed acknowledged writes.
    The flared container must restart inside the operator's remaining time
    (the renewal waits 30 s on a dropped port), so the kill waits until the
    container has run 10 minutes and the kubelet's restart back-off is reset. -/
private def resumedMasterTest (c : Ctx) : IO TestResult := do
  let some cp ← cpNode | return .fail (notSetUp "no control-plane container among the kind nodes")
  let ns := c.cfg.«namespace»
  try
    match ← c.placement with
    | .error e => return .fail e
    | .ok p =>
      if !(← operatorSettled c) then return .fail (notSetUp "the operator did not finish its startup grace period")
      if !(← waitForCondition "the cluster is settled before the test" 420 (settled c)) then
        return .fail (notSetUp "the cluster was not settled (one master, active replica) at the start")
      if !(← waitForCondition "the master's flared has run 10 minutes (kubelet back-off reset)" 720 do
          return ((← flaredUptime c p.master.name).getD 0) ≥ 610) then
        return .fail (notSetUp "the master's flared container did not reach 10 minutes of uptime")
      c.conditions ["apiserver-outage A4: API port dropped, the master's flared killed and re-registered with the still-running operator, the operator exits on the failed renewal and the next leader resumes from the persisted map; load 4 x 200/s via the partition Service and 2 x 200/s via the all-pods Service"]
      match ← c.ensureLoadWriter with
      | .error e => return .fail (notSetUp e)
      | .ok () => pure ()
      let svcHost := s!"{c.cfg.name}-0.{ns}.svc.cluster.local"
      let peerHost := s!"{c.cfg.name}-nodes-external.{ns}.svc.cluster.local"
      let some (opPod, opNode) ← operatorPod c | return .fail (notSetUp "the operator pod could not be identified")
      let r0 := (← operatorRestarts c opPod).getD 0
      let v0 ← masterMapVersion c
      if !(← c.startLoad "svc" svcHost 4 200) then return .fail (notSetUp "the client-path load did not start")
      if !(← c.startLoad "peer" peerHost 2 200) then return .fail (notSetUp "the all-pods load did not start")
      IO.sleep 10000
      match ← apiDrop cp with
      | .error e => return .fail (notSetUp s!"the API port could not be dropped: {e.take 200}")
      | .ok _ => pure ()
      let downSec ← epochNow
      c.event s!"API port dropped on {cp} (master {p.master.name}@{p.master.node}, operator {opPod}@{opNode} restarts {r0}, map v{v0})"
      IO.sleep 2000
      let killOut ← match ← killFlared p.master.node p.master.uid with
        | .ok o => pure o.trim
        | .error e => pure s!"kill failed: {e.take 200}"
      c.event s!"killed the master's flared on {p.master.node}: {killOut}"
      -- the API stays unreachable well past the operator's failed renewal
      repeat
        match ← hostCmd "docker" ["exec", p.master.node, "sh", "-c", "crictl ps -a --name flared 2>&1 | tail -n 4"] with
        | .ok o => for l in o.splitOn "\n" do if !l.trim.isEmpty then c.art "node-containers.txt" s!"{← epochNow} {l}"
        | .error _ => pure ()
        if (← epochNow) ≥ downSec + 75 then break
        IO.sleep 5000
      let regLines ← operatorLogLines c opNode opPod downSec "LOST LEASE|Received command: node (add|role)|starting \\(namespace"
      for l in regLines do c.art "operator-outage-lines.txt" l
      apiUndrop cp
      c.event s!"API port restored after {(← epochNow) - downSec} s; operator lines in the window: {regLines.length}"
      if !(← waitForCondition "kubectl works again" 120 (return (← kubectl ["get", "nodes"]) matches .ok _)) then
        return .fail "kubectl did not work within 120 s after the API port was restored"
      let settledAfter ← waitForCondition "the cluster is settled after the API returned" 420 (settled c)
      let v1 ← masterMapVersion c
      let masterAfter := (← c.roles).bind (·.1)
      let opRestarts := ((← operatorRestarts c opPod).getD r0) - r0
      let svc? ← c.stopLoad "svc" 4
      let peer? ← c.stopLoad "peer" 2
      let (some svcRes, some peerRes) := (svc?, peer?)
        | return .fail (unobservable "a load log could not be read or failed its integrity check")
      let svcS := loadStats svcRes
      let peerS := loadStats peerRes
      let acks : List WriteRec := ((svcRes.recs ++ peerRes.recs).filter (·.ack)).map (·.toWrite)
      let ps := (← c.pods).getD []
      let copyOf := fun (pod : String) => do
        match ps.find? (·.name == pod) with
        | some p => if p.ip.isEmpty then pure none else c.ownCopy p.ip
        | none => pure none
      let mm ← match masterAfter with
        | some m => pure ((← copyOf m).map fun d => (missingAcks acks d).length)
        | none => pure none
      let replicaPod := (ps.find? (fun (r : PodRow) => some r.name != masterAfter)).map (·.name)
      let mr ← do
        let mut last : Option Nat := none
        for _ in [0:18] do
          if last != some 0 then
            match replicaPod with
            | none => pure ()
            | some r =>
              match ← copyOf r with
              | some d =>
                let miss := missingAcks acks d
                last := some miss.length
                if miss.length != 0 then
                  c.art "missing.txt" s!"replica {r}: {miss.length} acknowledged write(s) not yet there"
              | none => last := none
            if last != some 0 then IO.sleep 10000
        pure last
      let opLog ← kubectlLogsLabel s!"app={c.cfg.operatorName}" ns 10000000
      let opLines := (opLog.splitOn "\n").filter fun l =>
        containsSubstr l "AUTHORITATIVE HISTORY" || containsSubstr l "REBUILD HELD" || containsSubstr l "PROMOTION"
      for l in opLines do c.art "operator-history-lines.txt" l
      let resumed := opLines.any (containsSubstr · "resumed as the partition's master")
      let held := (opLines.filter (containsSubstr · "REBUILD HELD (history)")).length
      let errs := svcS.errors + peerS.errors
      let summary := s!"SUMMARY [A4 resumed master]: master {p.master.name} -> {masterAfter}, map v{v0} -> v{v1}, operator restarts {opRestarts}, resumed recorded {resumed}, REBUILD HELD (history) {held}, errors {errs} by type {svcS.errorKinds ++ peerS.errorKinds}, missing on master {mm} / replica {mr}, settled {settledAfter}"
      IO.eprintln s!"# [apiserver-outage] {summary}"
      c.art "report.txt" summary
      c.art "report.txt" (svcS.summary "svc")
      c.art "report.txt" (peerS.summary "peer")
      if killOut != "killed=1" then return .fail (notSetUp s!"the master's flared was not killed ({killOut})")
      if !settledAfter then return .fail s!"the cluster did not settle within 420 s after the API returned. {summary}"
      match mm, mr with
      | none, _ => return .fail (unobservable "the final master's copy could not be read")
      | _, none => return .fail (unobservable "the replica's copy could not be read")
      | some a, some b =>
        if a != 0 || b != 0 then return .fail s!"DATA: {a} acknowledged write(s) missing on the final master, {b} on the replica. {summary}"
      if held != 0 then return .fail s!"the replica's rebuild was held on the history ({held} time(s); operator-history-lines.txt). {summary}"
      if masterAfter != some p.master.name || !resumed then
        return .fail (notSetUp s!"the restarted master did not resume under the persisted map, so the path under test was not taken (master {masterAfter}, resumed recorded {resumed}; operator-outage-lines.txt, operator-history-lines.txt, node-containers.txt). {summary}")
      return .pass
  finally
    apiUndrop cp
    apiStart cp

def suite : TestSuite :=
  { name := "node-ops-apiserver-outage"
    setup := do
      deployCluster cfg
      IO.sleep 50000
    teardown := do
      if let some cp ← cpNode then
        apiUndrop cp
        apiStart cp
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics cfg.«namespace» s!"app={cfg.operatorName}"
    afterEach := fun i => saveFullLogs cfg.«namespace» s!"after-test-{i}"
    tests := [
      { name := "(A1) kube-apiserver down ~120 s under load: 0 write errors, 0 missing; the operator leader exits on the lost lease, resumes after the API returns, the cluster settles", run := outageTest ctx .long },
      { name := "(A2) kube-apiserver unreachable 10 s (port dropped) under load: 0 write errors, 0 missing; nothing happens (operator not restarted, no LOST LEASE, same master, same node map version)", run := outageTest ctx .blip },
      { name := "(A3) kube-apiserver down ~90 s and the master's flared killed: errors characterised; after the API returns 0 acknowledged writes missing, one master, settled", run := outageTest ctx .killMaster },
      { name := "(A4) API port dropped, the master's flared restarts under the old leader, the next leader resumes from the persisted map: the new tenure is recorded, no rebuild held on the history, 0 acknowledged writes missing", run := resumedMasterTest ctx } ] }

end FlareOperator.E2E.Tests.ApiserverOutage
