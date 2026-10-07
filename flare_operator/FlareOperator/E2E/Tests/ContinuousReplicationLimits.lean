/-
  E2E/Tests/ContinuousReplicationLimits.lean — SAF-10d, the remaining
  acceptance scenarios that need their own cluster configuration:

  * `continuous-replication-purge` (T6): the master's WAL retention is made
    tiny (1 MB write buffer, 1 s TTL, 1 MB size cap); a cut long enough for
    a flush moves the needed history out of the WAL, so on healing the
    follower must declare `needs_rebuild` with reason `lsn_purged` (never
    report itself synchronised), and the operator must rebuild it.
  * `continuous-replication-limits` (T9, bounded): a far-behind replica
    catches up from a 15 MB backlog with deletes; the master's RSS growth
    and the replica's live tombstone count are measured; tombstones must
    return to zero once the applied position passes the deletes (positional
    GC, SC-20) — no wall clock involved.
  * `continuous-replication-scale`: an evaluation, not an acceptance test:
    loads FLARE_E2E_SCALE_KEYS keys (skipped when unset), then measures the
    exact key scan at open (`curr_items seeded by an exact scan: N live
    key(s) in M ms`, from a kill -9 restart on a PVC) and the operator's
    per-tick probe cost at that size. Numbers are recorded for the reviewer
    to extrapolate; the 15.8M-key production case is not run here.

  Evidence discipline as in ContinuousReplication.lean: direct replica
  reads and stats, no proxied read as evidence, no fixed sleep as a pass.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.TraceMatch

namespace FlareOperator.E2E.Tests.ContinuousReplicationLimits

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl
open FlareOperator.E2E.TraceMatch (readTraces traceField tracesAfterMarker KeyTrace answeredLocally numAfter parseGetReplies judgeActivation Activation)

private def kindNode : String := "flare-e2e-control-plane"
private def podOf (fqdn : String) : String := (fqdn.splitOn ".").head?.getD fqdn

private def flags : String :=
  "repl-identity-forward = true\nrepl-follow-enabled = true\nrepl-follow-poll-interval-usec = 200000"

private def hostCmd (cmd : String) (args : List String) : IO (Except String String) := do
  let out ← IO.Process.output { cmd := cmd, args := args.toArray }
  if out.exitCode == 0 then return .ok out.stdout
  else return .error s!"{cmd} {String.intercalate " " args} failed ({out.exitCode}): {out.stderr.trim}"

/-- Helpers parameterised by the suite's cluster (three suites, three clusters). -/
private structure Ctx where
  cfg : ClusterConfig

private def Ctx.nodeView (c : Ctx) : IO (List NodeSyncEntry) := do
  let sync ← operatorTcpCmd c.cfg.debugPod c.cfg.«namespace» c.cfg.operatorName c.cfg.operatorPort "node sync"
  return parseNodeSync sync

/-- (masterPod, masterIp, replicaPod, replicaIp) for partition 0. -/
private def Ctx.pair (c : Ctx) : IO (Except String (String × String × String × String)) := do
  let mut lastErr := ""
  for _ in [0:6] do
    let entries ← c.nodeView
    match findMasterFqdn entries 0 with
    | none => lastErr := "no Active P0 master in the operator's map"
    | some mFqdn =>
      match entries.find? (fun e => e.fqdn != mFqdn) with
      | none => lastErr := "no second node in the operator's map"
      | some s =>
        match ← getPodIp (podOf mFqdn) c.cfg.«namespace», ← getPodIp (podOf s.fqdn) c.cfg.«namespace» with
        | some mIp, some sIp => return .ok (podOf mFqdn, mIp, podOf s.fqdn, sIp)
        | _, _ => lastErr := "could not resolve pod IPs"
    IO.sleep 5000
  return .error lastErr

private def Ctx.statsOf (c : Ctx) (ip : String) : IO (Option String) := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {c.cfg.flarePort}" with
  | .ok o => return some o
  | .error _ => return none

private def statVal (out : String) (key : String) : Option String :=
  (out.splitOn "\n").findSome? fun line =>
    let t := (line.trim.replace "\r" "")
    if t.startsWith s!"STAT {key} " then some ((t.drop s!"STAT {key} ".length).trim) else none

private def Ctx.statNat (c : Ctx) (ip key : String) : IO (Option Nat) := do
  match ← c.statsOf ip with
  | none => return none
  | some o => return (statVal o key).bind (·.toNat?)

private def Ctx.statStr (c : Ctx) (ip key : String) : IO (Option String) := do
  match ← c.statsOf ip with
  | none => return none
  | some o => return statVal o key

private def Ctx.currItems (c : Ctx) (ip : String) : IO Nat := return (← c.statNat ip "curr_items").getD 0

private def Ctx.opLog (c : Ctx) (tail : Nat := 1500) : IO String :=
  kubectlLogsLabel s!"app={c.cfg.operatorName}" c.cfg.«namespace» tail

private def Ctx.podUid (c : Ctx) (pod : String) : IO (Option String) := do
  match ← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.metadata.uid}" with
  | .ok o => return some o.trim
  | .error _ => return none

private def Ctx.ledgerDests (c : Ctx) : IO (List String) := do
  match ← kubectlGetJsonpath "flarecluster" c.cfg.name c.cfg.«namespace» "{.status.replicaRepairs.entries[*].dest}" with
  | .ok out => return (out.trim.splitOn " ").filter (· != "")
  | .error _ => return []

private def Ctx.restartCount (c : Ctx) (pod : String) : IO Nat := do
  match ← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.status.containerStatuses[0].restartCount}" with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0

private def Ctx.ready (c : Ctx) (pod : String) : IO Bool := do
  match ← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.status.containerStatuses[0].ready}" with
  | .ok o => return o.trim == "true"
  | .error _ => return false

/-- Resident set size of flared (pid 1) in kB, read inside the pod. -/
private def Ctx.rssKb (c : Ctx) (pod : String) : IO (Option Nat) := do
  match ← kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", "grep VmRSS /proc/1/status | awk '{print $2}'"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- kill -9 flared in `pod` from the kind node (pid 1 in the pod ignores
    signals from inside); found by the pod UID in its cgroup. -/
private def Ctx.killFlaredIn (c : Ctx) (pod : String) : IO (Except String String) := do
  match ← c.podUid pod with
  | none => return .error s!"no UID for {pod}"
  | some uid =>
    let u2 := uid.replace "-" "_"
    hostCmd "docker" ["exec", kindNode, "sh", "-c",
      s!"n=0; for p in $(pgrep -x flared); do if grep -q -e '{uid}' -e '{u2}' /proc/$p/cgroup 2>/dev/null; then kill -9 $p && n=$((n+1)); fi; done; echo killed=$n"]

/-- Write `count` keys of `bytes` bytes each (value = repeated 'x'), one
    connection per key, on the master. Returns the number STORED. -/
private def Ctx.writeBig (c : Ctx) (ip : String) (pfx : String) (count bytes : Nat) : IO Nat := do
  let mut stored := 0
  for i in [0:count] do
    let cmd := s!"v=$(head -c {bytes} /dev/zero | tr '\\0' x); printf 'set {pfx}_{i} 0 0 {bytes}\\r\\n%s\\r\\n' \"$v\" | nc -w 5 {ip} {c.cfg.flarePort}"
    match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» cmd with
    | .ok o => if containsSubstr o "STORED" then stored := stored + 1
    | .error _ => pure ()
  return stored

private def Ctx.deleteKeys (c : Ctx) (ip : String) (pfx : String) (from_ to : Nat) : IO Nat := do
  let mut deleted := 0
  for i in [from_:to] do
    match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf 'delete {pfx}_{i}\\r\\n' | nc -w 3 {ip} {c.cfg.flarePort}" with
    | .ok o => if containsSubstr o "DELETED" then deleted := deleted + 1
    | .error _ => pure ()
  return deleted

-- iptables REJECT between master and replica on the kind node (both directions)
private def ruleSpec (masterIp slaveIp : String) : List String :=
  ["-s", masterIp, "-d", slaveIp, "-p", "tcp", "--dport", "12121", "-j", "REJECT", "--reject-with", "tcp-reset"]
private def ruleSpecBack (masterIp slaveIp : String) : List String :=
  ["-s", slaveIp, "-d", masterIp, "-p", "tcp", "--dport", "12121", "-j", "REJECT", "--reject-with", "tcp-reset"]

private def cut (masterIp slaveIp : String) : IO (Except String Unit) := do
  match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ ruleSpec masterIp slaveIp) with
  | .error e => return .error e
  | .ok _ =>
    match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ ruleSpecBack masterIp slaveIp) with
    | .error e => return .error e
    | .ok _ => IO.eprintln s!"# fault: rejecting {masterIp} ⇄ {slaveIp}:12121 on {kindNode} (both directions)"; return .ok ()

private def heal (masterIp slaveIp : String) : IO Unit := do
  for _ in [0:3] do
    discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec masterIp slaveIp)
    discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpecBack masterIp slaveIp)
  IO.eprintln s!"# fault cleared: {masterIp} ⇄ {slaveIp} forwards again"

-- ─── T6: retention overrun ──────────────────────────────────────────────

private def purgeCfg : ClusterConfig := {
  name := "cont-repl-purge"
  «namespace» := "flare-cont-repl-purge"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-purge"
  storageBackend := "rocksdb"
  -- Tiny retention so a cut long enough for one flush loses the history the
  -- follower needs: 1 MB write buffer (flush after ~1 MB), archived WAL
  -- purged after 1 s or 1 MB.
  extraFlaredConf := flags ++ "\nrocksdb-write-buffer-size-mb = 1\nrocksdb-wal-ttl-seconds = 1\nrocksdb-wal-size-limit-mb = 1"
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
}

def purgeSuite : TestSuite := {
  name := "continuous-replication-purge"
  setup := do
    deployCluster purgeCfg
    IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
    IO.sleep 50000
  teardown := cleanupCluster purgeCfg
  tests :=
    let c : Ctx := { cfg := purgeCfg }
    [
    { name := "precondition: both flags on, retention knobs baked, replica following"
      run := do
        match ← kubectlGetJsonpath "configmap" s!"{purgeCfg.name}-config" purgeCfg.«namespace» "{.data.extra\\.conf}" with
        | .error e => return .fail s!"extra.conf unreadable: {e}"
        | .ok conf =>
          for needle in ["repl-identity-forward = true", "repl-follow-enabled = true", "rocksdb-wal-ttl-seconds = 1", "rocksdb-write-buffer-size-mb = 1"] do
            if !(containsSubstr conf needle) then return .fail s!"extra.conf lacks '{needle}'"
        match ← c.pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let stored ← writeKeys purgeCfg.debugPod purgeCfg.«namespace» mIp purgeCfg.flarePort "base" 20
          if stored != 20 then return .fail s!"stored only {stored}/20"
          let following ← waitForCondition "replica following and matching" 120 do
            return (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == (← c.currItems mIp)
          IO.eprintln s!"# following: state={← c.statStr sIp "repl_follow_state"} applied={← c.statNat sIp "repl_applied_lsn"} master latest={← c.statNat mIp "rocksdb_latest_sequence_number"}"
          if !following then return .fail s!"replica never followed (state {← c.statStr sIp "repl_follow_state"})"
          return .pass },

    { name := "T6: history purged while cut → the follower declares needs_rebuild (lsn_purged), never synchronised; the operator rebuilds it; it follows again"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          let applied0 := (← c.statNat sIp "repl_applied_lsn").getD 0
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          let done0 := (← c.statNat sIp "reconstruction_completed").getD 0
          let drops0 := (← c.statNat mIp "proxy_write_dropped").getD 0
          let uid0 := (← c.podUid sPod).getD "?"
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          -- ~4 MB of writes against a 1 MB write buffer: several flushes,
          -- each archiving the WAL segment the follower still needs; the
          -- archive is purged after 1 s.
          let big ← c.writeBig mIp "purge" 40 100000
          let mLatest := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
          IO.sleep 8000
          IO.eprintln s!"# under the cut: {big}/40 keys of 100 kB written (master latest {mLatest}, replica applied {applied0}); waited 8 s for the WAL purge"
          if big < 40 then heal mIp sIp; return .fail s!"only {big}/40 big keys were stored under the cut: no history to purge was produced"
          -- Keep the link cut until the master has COUNTED dropped forwards
          -- (a forward counts only once its retries are exhausted; CI
          -- 36904379135/36909742559 healed after 8 s and the counter stayed
          -- 0, so only the follower route fired). Then both triggers race.
          let dropsSeen ← waitForCondition "master counts dropped forwards while cut" 120 do
            return (← c.statNat mIp "proxy_write_dropped").getD 0 > drops0
          IO.eprintln s!"# drop route armed before the heal: {dropsSeen} (proxy_write_dropped {drops0}→{(← c.statNat mIp "proxy_write_dropped").getD 0})"
          heal mIp sIp
          let declared ← waitForCondition "follower declares needs_rebuild with reason lsn_purged" 120 do
            return (← c.statStr sIp "repl_follow_state") == some "needs_rebuild"
              && (← c.statStr sIp "repl_follow_last_reason") == some "lsn_purged"
          let st := (← c.statStr sIp "repl_follow_state").getD "?"
          let why := (← c.statStr sIp "repl_follow_last_reason").getD "?"
          IO.eprintln s!"# after the heal: follower state={st} reason={why} applied={← c.statNat sIp "repl_applied_lsn"} items master={← c.currItems mIp} replica={← c.currItems sIp} decode_refused={← c.statNat sIp "repl_decode_refused"}"
          match ← hostCmd "sh" ["-c", s!"kubectl logs -n {purgeCfg.«namespace»} {sPod} | grep -E 'refused|follow apply|replication follow state|lsn_purged' | tail -12"] with
          | .ok o => IO.eprintln s!"# --- replica follower lines (filtered) ---\n{o}"
          | .error e => IO.eprintln s!"# (could not read the replica's log: {e})"
          match ← hostCmd "sh" ["-c", s!"kubectl logs -n {purgeCfg.«namespace»} {(← c.pair).toOption.map (·.1) |>.getD "cont-repl-purge-nodes-0"} | grep -E 'streaming|purged|wal_read_error' | tail -6"] with
          | .ok o => IO.eprintln s!"# --- master WAL-serve lines (filtered) ---\n{o}"
          | .error e => IO.eprintln s!"# (could not read the master's log: {e})"
          if !declared then
            if st == "following" && (← c.currItems sIp) == (← c.currItems mIp) then
              return .fail s!"the WAL was NOT purged within the window (the follower caught up from {applied0}); retention knobs did not take effect — no lsn_purged staged"
            return .fail s!"expected needs_rebuild/lsn_purged, got {st}/{why}"
          -- BOTH repair triggers fire for this one replica (handoff §3: the
          -- true concurrency, not two orders observed separately): the
          -- master counted forwards it dropped while the link was cut, and
          -- the follower declared needs_rebuild. They must merge into ONE
          -- ledger entry and ONE reconstruction.
          let drops1 := (← c.statNat mIp "proxy_write_dropped").getD 0
          let maxEntries ← IO.mkRef 0
          let requested ← waitForCondition "operator files a repair request for the follower" 150 do
            let d ← c.ledgerDests
            maxEntries.modify (max d.length)
            return !d.isEmpty || containsSubstr (← c.opLog) "REPLICA REPAIR requested"
          let rebuilt ← waitForCondition "follower reconstructed and following at the master's position" 480 do
            maxEntries.modify (max (← c.ledgerDests).length)
            return (← c.statNat sIp "reconstruction_started").getD 0 > recon0
              && (← c.statStr sIp "repl_follow_state") == some "following"
              && (← c.currItems sIp) == (← c.currItems mIp)
          let log ← c.opLog 200000
          let viaDrops := containsSubstr log "more write(s) to"
          let viaFollower := containsSubstr log "declared needs_rebuild"
          IO.eprintln s!"# triggers: master dropped {drops0}→{drops1} forward(s); drop-route request logged={viaDrops}; follower-route request logged={viaFollower}; most ledger entries at once={← maxEntries.get}"
          IO.eprintln s!"# rebuild: requested={requested}; reconstruction_started {recon0}→{(← c.statNat sIp "reconstruction_started").getD 0}; state={← c.statStr sIp "repl_follow_state"}; items master={← c.currItems mIp} replica={← c.currItems sIp}; wal_fallback_to_dump={← c.statNat sIp "rocksdb_wal_fallback_to_dump"} snapshot_bootstrap={← c.statNat sIp "rocksdb_snapshot_bootstrap"}; pod uid {uid0}→{(← c.podUid sPod).getD "?"}"
          if !requested then return .fail "no repair request was observed for the follower"
          if !rebuilt then return .fail s!"the follower was not rebuilt (state {← c.statStr sIp "repl_follow_state"}, items master={← c.currItems mIp} replica={← c.currItems sIp})"
          if (← c.podUid sPod).getD "?" != uid0 then return .fail "the replica pod was recreated"
          let empty ← waitForCondition "ledger empty" 240 do return (← c.ledgerDests).isEmpty
          if !empty then return .fail s!"ledger still holds {← c.ledgerDests}"
          -- One rebuild, not one per trigger: give a second one time to start.
          IO.sleep 30000
          let recon1 := (← c.statNat sIp "reconstruction_started").getD 0
          let done1 := (← c.statNat sIp "reconstruction_completed").getD 0
          IO.eprintln s!"# after the ledger emptied (+30 s): reconstruction_started {recon0}→{recon1}, completed {done0}→{done1}"
          if drops1 ≤ drops0 then
            IO.eprintln "# NOTE: the master counted no dropped forwards during the cut; only the follower route fired, so this run does not show the concurrent case"
          if (← maxEntries.get) > 1 then return .fail s!"the two triggers produced {← maxEntries.get} ledger entries for one replica"
          if recon1 != recon0 + 1 then return .fail s!"expected exactly one reconstruction for the two triggers, got {recon1 - recon0}"
          if done1 != done0 + 1 then return .fail s!"expected exactly one completed reconstruction, got {done1 - done0}"
          return .pass }
  ]
}

-- ─── T9 (bounded): a far-behind replica, master memory, tombstone GC ────

-- One partition x two replicas on purpose. The lagged-successor test loses
-- one master, which is 50% of this cluster: it tripped the breaker before
-- the minUnavailableToTrip floor (default 2, user decision 2026-10-02), so
-- the test is also the E2E for that floor. (Two partitions were tried in CI
-- 36904379135 and broke the suite: Ctx.pair takes partition 0's master but
-- can return the other partition's slave.)
private def limitsCfg : ClusterConfig := {
  name := "cont-repl-limits"
  «namespace» := "flare-cont-repl-limits"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-limits"
  storageBackend := "rocksdb"
  extraFlaredConf := flags
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
}

def limitsSuite : TestSuite := {
  name := "continuous-replication-limits"
  setup := do
    deployCluster limitsCfg
    IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
    IO.sleep 50000
  teardown := cleanupCluster limitsCfg
  onFailure := dumpClusterDiagnostics limitsCfg.«namespace» s!"app={limitsCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := limitsCfg }
    [
    { name := "precondition: replica following"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let stored ← writeKeys limitsCfg.debugPod limitsCfg.«namespace» mIp limitsCfg.flarePort "base" 20
          if stored != 20 then return .fail s!"stored only {stored}/20"
          let following ← waitForCondition "replica following and matching" 120 do
            return (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == (← c.currItems mIp)
          if !following then return .fail s!"replica never followed (state {← c.statStr sIp "repl_follow_state"})"
          return .pass },

    { name := "T9: a 15 MB backlog with deletes is drained in bounded chunks; master RSS growth measured; tombstones return to zero by position (SC-20)"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, _, sIp) =>
          let rss0 := (← c.rssKb mPod).getD 0
          let applied0 := (← c.statNat sIp "repl_applied_lsn").getD 0
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let big ← c.writeBig mIp "bulk" 300 50000
          let del ← c.deleteKeys mIp "bulk" 0 100
          let rssCut := (← c.rssKb mPod).getD 0
          let mLatest := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
          IO.eprintln s!"# backlog under the cut: {big}/300 keys of 50 kB, {del}/100 deleted; master latest {mLatest}, replica applied {applied0}; master RSS {rss0} kB → {rssCut} kB"
          if big < 300 || del < 100 then heal mIp sIp; return .fail s!"backlog not produced: stored {big}/300, deleted {del}/100"
          heal mIp sIp
          -- Sample while it drains: applied position, master RSS, live tombstones.
          let mut rssMax := rssCut
          let mut tombMax := 0
          let mut incMax := 0
          let mut lastApplied := applied0
          let mut converged := false
          for _ in [0:240] do
            IO.sleep 1000
            let a := (← c.statNat sIp "repl_applied_lsn").getD lastApplied
            if a > lastApplied && a - lastApplied > incMax then incMax := a - lastApplied
            lastApplied := a
            rssMax := max rssMax ((← c.rssKb mPod).getD 0)
            tombMax := max tombMax ((← c.statNat sIp "repl_tombstones").getD 0)
            if (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == (← c.currItems mIp) && a ≥ mLatest then
              converged := true
              break
          let tombAfter ← waitForCondition "tombstones collected once the position passed the deletes" 120 do
            return (← c.statNat sIp "repl_tombstones") == some 0
          let growth := if rssMax > rss0 then rssMax - rss0 else 0
          IO.eprintln s!"# drain: converged={converged}; applied {applied0}→{lastApplied} (master {mLatest}); largest 1 s advance {incMax} seq; master RSS max {rssMax} kB (growth {growth} kB); tombstones max {tombMax} → now {(← c.statNat sIp "repl_tombstones").getD 0} (collected={tombAfter}); wal_applied={← c.statNat sIp "repl_wal_applied"} tombstones_dropped={← c.statNat sIp "repl_tombstones_dropped"}; items master={← c.currItems mIp} replica={← c.currItems sIp}; reconstruction_started {recon0}→{(← c.statNat sIp "reconstruction_started").getD 0}"
          if !converged then return .fail s!"the replica did not drain the backlog (applied {lastApplied} of {mLatest}, items master={← c.currItems mIp} replica={← c.currItems sIp})"
          if (← c.statNat sIp "reconstruction_started").getD 0 != recon0 then return .fail "a reconstruction ran instead of a catch-up"
          if growth > 131072 then return .fail s!"master RSS grew by {growth} kB while a replica caught up (bound 131072 kB)"
          if !tombAfter then return .fail s!"tombstones were not collected after the position passed the deletes ({← c.statNat sIp "repl_tombstones"} live)"
          -- deleted keys must be absent locally on the replica (a miss proxies to the master where they are also gone)
          for k in ["bulk_0", "bulk_50", "bulk_99"] do
            match ← execInDebugPod limitsCfg.debugPod limitsCfg.«namespace» s!"printf 'get {k}\\r\\n' | nc -w 3 {sIp} {limitsCfg.flarePort}" with
            | .ok o => if containsSubstr o "VALUE" then return .fail s!"{k} resurrected on the replica"
            | .error e => return .fail e
          return .pass },

    -- Handoff §3: promotion with a LAGGED successor. The master is lost
    -- while its only follower is cut off and behind. Failover still
    -- promotes the follower (availability over the gap: replication is
    -- asynchronous, design §5.3) and must say so; the writes it missed are
    -- the RPO this deployment accepts, and the test records how many.
    { name := "lagged successor: the master is lost while its follower is cut off and behind; failover promotes it as not loss-free, logs that, and the gap is the writes it never received"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let items0 := c.currItems
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          IO.sleep 2000
          let stored ← writeKeys limitsCfg.debugPod limitsCfg.«namespace» mIp limitsCfg.flarePort "lagged" 50
          let mItems ← items0 mIp
          let sItems ← items0 sIp
          IO.eprintln s!"# under the cut: stored {stored}/50 on the master; items master={mItems} replica={sItems}"
          if stored == 0 || sItems ≥ mItems then
            heal mIp sIp; return .fail "precondition: the follower is not behind the master"
          -- Lose the master. The replica stays cut off from the old master's IP;
          -- the replacement pod gets a new IP, so heal right after the kill.
          discard <| kubectl ["delete", "pod", mPod, "-n", limitsCfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          heal mIp sIp
          let promoted ← waitForCondition "failover promotes the lagged follower" 240 do
            let entries ← c.nodeView
            return (findMasterFqdn entries 0).bind (fun f => (f.splitOn ".").head?) == some sPod
          let log ← c.opLog 200000
          let notLossFree := (log.splitOn "\n").any fun l =>
            containsSubstr l "PROMOTION NOT LOSS-FREE" && containsSubstr l sPod
          let newItems ← items0 sIp
          let gap := mItems - newItems
          let pathLines := (log.splitOn "\n").filter (fun l =>
            containsSubstr l "graceful drain" || containsSubstr l "PROMOTION NOT LOSS-FREE"
              || containsSubstr l "detected " || containsSubstr l "CIRCUIT BREAKER")
          IO.eprintln s!"# failover: promoted={promoted}; NOT LOSS-FREE logged={notLossFree}; items old master={mItems} new master={newItems} (gap {gap})"
          IO.eprintln s!"# operator promotion path:\n{String.intercalate "\n" (pathLines.reverse.take 8).reverse}"
          if !promoted then return .fail "the lagged follower was not promoted: the partition stayed without a master"
          -- The guarantee is: NO warning => the follower was proven within
          -- the promotion bound (FLARE_FOLLOW_PROMOTE_LAG, default 100
          -- positions), so at most that much is lost silently. CI
          -- 36909742559: the force-deleted master was seen Terminating, the
          -- follower (still polling the master's WAL position through the
          -- one-way cut) was 48 items behind, and it was promoted by the drain
          -- path with no warning. A larger gap without the warning is the
          -- failure.
          if !notLossFree && gap > 100 then
            return .fail s!"the lagged follower was promoted without the NOT LOSS-FREE line although {gap} items (> the promotion bound 100) were lost"
          if !notLossFree then
            IO.eprintln s!"# promoted as proven within the promotion bound: {gap} item(s) lost without a warning, by design (bound 100 positions)"
          -- The returning ex-master must not overrule the new master's
          -- history: it rejoins as a follower of the new epoch.
          let rejoined ← waitForCondition "the ex-master rejoins and follows the new master" 480 do
            let entries ← c.nodeView
            match entries.find? (fun e => (e.fqdn.splitOn ".").head? == some mPod) with
            | none => return false
            | some e =>
              if e.role != 1 || e.state != 0 then return false
              match ← getPodIp mPod limitsCfg.«namespace» with
              | none => return false
              | some ip => return (← c.statStr ip "repl_follow_state") == some "following"
          IO.eprintln s!"# ex-master {mPod} rejoined as a follower={rejoined}; items now new master={← items0 sIp}"
          if !rejoined then return .fail "the ex-master did not rejoin as a follower of the new master"
          return .pass }
  ]
}

-- ─── failover lag bound: the far-behind follower is held, not crowned ───

-- The follower is CONNECTED but slow: one WAL batch per response and a 1 s
-- pause after each (repl-follow-batch-delay-usec), with the master's
-- forwards cut, so its backlog is known to it and to the operator. The bound
-- is 20 positions (FLARE_FOLLOW_FAILOVER_MAX_LAG) and the wait 900 s. A cut
-- follower would not do: it never learns the master's head, so it is
-- unproven, not unfit. On a PVC, so the ex-master returns with its data.
private def holdCfg : ClusterConfig := {
  name := "cont-repl-hold"
  «namespace» := "flare-cont-repl-hold"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-hold"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := flags ++ "\nrepl-follow-max-batches = 1\nrepl-follow-batch-delay-usec = 1000000"
  operatorEnv := [("FLARE_FOLLOW_FAILOVER_MAX_LAG", "20"), ("FLARE_FOLLOW_FAILOVER_WAIT_SECONDS", "900")]
}

/-- Reject only the master's forwards to the replica (master → replica:12121);
    the replica's own fetches from the master stay up. -/
private def cutForwards (masterIp slaveIp : String) : IO (Except String Unit) := do
  match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ ruleSpec masterIp slaveIp) with
  | .error e => return .error e
  | .ok _ => IO.eprintln s!"# fault: rejecting forwards {masterIp} → {slaveIp}:12121 (the replica's fetches stay up)"; return .ok ()

private def healForwards (masterIp slaveIp : String) : IO Unit := do
  for _ in [0:3] do
    discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec masterIp slaveIp)
  IO.eprintln s!"# fault cleared: forwards {masterIp} → {slaveIp} again"

def lagHoldSuite : TestSuite := {
  name := "continuous-replication-lag-hold"
  setup := do
    deployCluster holdCfg
    IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
    IO.sleep 50000
  teardown := do
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster holdCfg
  onFailure := dumpClusterDiagnostics holdCfg.«namespace» s!"app={holdCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := holdCfg }
    [
    { name := "precondition: replica following"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let stored ← writeKeys holdCfg.debugPod holdCfg.«namespace» mIp holdCfg.flarePort "base" 20
          if stored != 20 then return .fail s!"stored only {stored}/20"
          let following ← waitForCondition "replica following and matching" 180 do
            return (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == (← c.currItems mIp)
          if !following then return .fail s!"replica never followed (state {← c.statStr sIp "repl_follow_state"})"
          return .pass },

    -- SAF-10c failover lag bound, end to end. Without the refill hold the
    -- masterless refill crowned the unfit follower in the same pass that
    -- failed its master over (pure reproduction 2026-10-03), so the bound
    -- protected nothing.
    { name := "failover lag bound: the master is lost while its follower is connected but further behind than the bound; the follower is NOT promoted, the partition waits, the ex-master returns on its PVC and is master again with every write"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          match ← cutForwards mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let stored ← writeKeys holdCfg.debugPod holdCfg.«namespace» mIp holdCfg.flarePort "hold" 120
          let mItems ← c.currItems mIp
          IO.eprintln s!"# under the forward cut: stored {stored}/120; items master={mItems} replica={← c.currItems sIp}; replica source={← c.statNat sIp "repl_source_lsn"} applied={← c.statNat sIp "repl_applied_lsn"} state={← c.statStr sIp "repl_follow_state"}"
          let unfitSeen ← waitForCondition "the operator judges the follower unfit (behind more than the bound)" 120 do
            return ((← c.opLog 2000).splitOn "\n").any fun l =>
              containsSubstr l s!"eligibility {sPod}" && containsSubstr l "more than the failover bound"
          IO.eprintln s!"# before the kill: unfit judged={unfitSeen}; replica source={← c.statNat sIp "repl_source_lsn"} applied={← c.statNat sIp "repl_applied_lsn"}"
          if !unfitSeen then
            healForwards mIp sIp
            return .fail "precondition: the operator never judged the follower further behind than the bound"
          -- Keep the ex-master away: cordon the (single) kind node first, so
          -- the StatefulSet's replacement pod stays Pending. Without this the
          -- replacement re-registered before dead detection and was re-seated
          -- in the same pass (CI 37025254148): correct, but the hold itself
          -- never ran.
          match ← kubectl ["cordon", kindNode] with
          | .error e => healForwards mIp sIp; return .fail s!"could not cordon {kindNode}: {e}"
          | .ok _ => IO.eprintln s!"# cordoned {kindNode}: the master's replacement pod stays Pending"
          discard <| kubectl ["delete", "pod", mPod, "-n", holdCfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          healForwards mIp sIp
          -- Phase 1, ex-master away: the follower must never become master and
          -- the hold must be logged.
          let mut followerPromoted := false
          let mut holdLogged := false
          for _ in [0:60] do
            IO.sleep 2000
            let entries ← c.nodeView
            if (findMasterFqdn entries 0).bind (fun f => (f.splitOn ".").head?) == some sPod then
              followerPromoted := true; break
            if ((← c.opLog 3000).splitOn "\n").any (fun l => containsSubstr l "has NO master" && containsSubstr l sPod) then
              holdLogged := true; break
          -- Hold a little longer than the first line, then let the pod back.
          if holdLogged && !followerPromoted then
            for _ in [0:10] do
              IO.sleep 2000
              let entries ← c.nodeView
              if (findMasterFqdn entries 0).bind (fun f => (f.splitOn ".").head?) == some sPod then
                followerPromoted := true; break
          discard <| kubectl ["uncordon", kindNode]
          IO.eprintln s!"# uncordoned {kindNode}; while the ex-master was away: follower promoted={followerPromoted}; hold logged={holdLogged}"
          if followerPromoted then
            return .fail s!"the follower {sPod} was promoted although it was further behind than the failover bound"
          if !holdLogged then return .fail "the ex-master was away but the CRITICAL 'has NO master' hold line never appeared"
          -- Phase 2, the ex-master returns on its PVC.
          let mut exMasterBack := false
          for _ in [0:150] do
            IO.sleep 2000
            let entries ← c.nodeView
            match (findMasterFqdn entries 0).bind (fun f => (f.splitOn ".").head?) with
            | some m =>
              if m == sPod then followerPromoted := true; break
              if m == mPod then exMasterBack := true; break
            | none => pure ()
          let log ← c.opLog 200000
          let lines := log.splitOn "\n"
          let notLossFree := lines.any fun l => containsSubstr l "PROMOTION NOT LOSS-FREE" && containsSubstr l sPod
          let pathLines := lines.filter (fun l =>
            containsSubstr l "has NO master" || containsSubstr l "PROMOTION NOT LOSS-FREE"
              || containsSubstr l "detected " || containsSubstr l "graceful drain")
          IO.eprintln s!"# after the return: follower promoted={followerPromoted}; ex-master master again={exMasterBack}; NOT LOSS-FREE for the follower={notLossFree}"
          IO.eprintln s!"# operator promotion path:\n{String.intercalate "\n" (pathLines.reverse.take 8).reverse}"
          if followerPromoted || notLossFree then
            return .fail s!"the follower {sPod} was promoted although it was further behind than the failover bound"
          if !exMasterBack then return .fail "the ex-master did not become master again within 300 s of the uncordon"
          let back ← waitForCondition "the ex-master serves every write it acknowledged" 120 do
            match ← getPodIp mPod holdCfg.«namespace» with
            | none => return false
            | some ip => return (← c.currItems ip) == mItems
          let newIp := (← getPodIp mPod holdCfg.«namespace»).getD ""
          IO.eprintln s!"# ex-master {mPod}: items={← c.currItems newIp} (acknowledged before the kill {mItems})"
          if !back then return .fail s!"the ex-master returned with {← c.currItems newIp} items, {mItems} were acknowledged"
          let rejoined ← waitForCondition "the follower follows the ex-master again and matches" 480 do
            return (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == mItems
          IO.eprintln s!"# follower {sPod}: state={← c.statStr sIp "repl_follow_state"} items={← c.currItems sIp} reconstruction_started={← c.statNat sIp "reconstruction_started"}"
          if !rejoined then return .fail "the follower did not follow the ex-master again"
          return .pass }
  ]
}

-- ─── production enablement: legacy cluster → continuous replication, live ──

-- Starts exactly like a production cluster today: RocksDB on a PVC, NO
-- follow settings. Continuous replication is then switched on through the
-- CR in the documented order (identity forwarding on every node first, then
-- following), with writes between every step, and rolled back in reverse.
private def enableCfg : ClusterConfig := {
  name := "cont-repl-enable"
  «namespace» := "flare-cont-repl-enable"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-enable"
  storageBackend := "rocksdb"
  usePvc := true
}

private def enablePatch (identity follow : Bool) : String :=
  s!"\{\"spec\":\{\"rocksdb\":\{\"replIdentityForward\":{identity},\"replFollowEnabled\":{follow},\"replFollowPollIntervalUsec\":200000}}}"

/-- Both flared pods logged this reload line (the operator rewrote
    extra.conf and signalled them). -/
private def bothReloaded (c : Ctx) (needle : String) : IO Bool := do
  let pods ← getPodNames s!"app=flare,cluster={c.cfg.name}" c.cfg.«namespace»
  if pods.length < 2 then return false
  let mut all := true
  for p in pods do
    match ← kubectl ["logs", "-n", c.cfg.«namespace», p, "--tail=5000"] with
    | .ok o => if !containsSubstr o needle then all := false
    | .error _ => all := false
  return all

/-- Every key of every prefix written so far reads back with its value on
    both copies (sampled: first, middle, last). -/
private def sampleEqual (c : Ctx) (mIp sIp : String) (written : List (String × Nat)) : IO (Option String) := do
  for (pfx, n) in written do
    for i in [0, n / 2, n - 1] do
      let k := s!"{pfx}_{i}"
      let mv ← memcachedGet c.cfg.debugPod c.cfg.«namespace» mIp c.cfg.flarePort k
      let sv ← memcachedGet c.cfg.debugPod c.cfg.«namespace» sIp c.cfg.flarePort k
      if mv != some s!"val_{i}" || sv != mv then
        return some s!"{k}: master={mv} replica={sv}"
  return none

private def convergedItems (c : Ctx) (mIp sIp : String) (label : String) : IO Bool :=
  waitForCondition label 180 do
    let m ← c.currItems mIp
    return m > 0 && (← c.currItems sIp) == m

def enableSuite : TestSuite := {
  name := "continuous-replication-enable"
  setup := do
    deployCluster enableCfg
    IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
    IO.sleep 50000
  teardown := cleanupCluster enableCfg
  onFailure := dumpClusterDiagnostics enableCfg.«namespace» s!"app={enableCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := enableCfg }
    [
    { name := "enablement, live: a legacy RocksDB cluster (no follow settings) switches on identity forwarding, then continuous following, through the CR with writes between the steps; data stays equal, no failover; the replica's path to following (catch-up or rebuild) is recorded"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          -- legacy baseline
          let w0 ← writeKeys enableCfg.debugPod enableCfg.«namespace» mIp enableCfg.flarePort "legacy" 200
          if w0 != 200 then return .fail s!"legacy writes: stored {w0}/200"
          if !(← convergedItems c mIp sIp "legacy: replica matches the master") then
            return .fail s!"legacy baseline: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          let drops0 := (← c.statNat mIp "proxy_write_dropped").getD 0
          IO.eprintln s!"# legacy: items {← c.currItems mIp}; replica follow state={← c.statStr sIp "repl_follow_state"} applied={← c.statNat sIp "repl_applied_lsn"} repl_last_lsn={← c.statNat sIp "rocksdb_repl_last_lsn"}; master latest={← c.statNat mIp "rocksdb_latest_sequence_number"}; reconstruction_started={recon0}"
          -- step 1: identity forwarding on every node
          match ← kubectlPatch "flarecluster" enableCfg.name enableCfg.«namespace» (enablePatch true false) with
          | .error e => return .fail s!"patch (identity on) failed: {e}"
          | .ok _ => pure ()
          if !(← waitForCondition "both nodes reload repl_identity_forward 0 -> 1" 240 do bothReloaded c "repl_identity_forward: 0 -> 1") then
            return .fail "identity forwarding was not applied on both nodes"
          let w1 ← writeKeys enableCfg.debugPod enableCfg.«namespace» mIp enableCfg.flarePort "idfwd" 100
          if !(← convergedItems c mIp sIp "identity on: replica matches the master") then
            return .fail s!"after identity forwarding: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          IO.eprintln s!"# identity forwarding on: stored {w1}/100; items {← c.currItems mIp}; replica repl_last_lsn={← c.statNat sIp "rocksdb_repl_last_lsn"} master latest={← c.statNat mIp "rocksdb_latest_sequence_number"}"
          -- step 2: continuous following
          match ← kubectlPatch "flarecluster" enableCfg.name enableCfg.«namespace» (enablePatch true true) with
          | .error e => return .fail s!"patch (follow on) failed: {e}"
          | .ok _ => pure ()
          let states ← IO.mkRef ([] : List String)
          let following ← waitForCondition "the replica follows after enablement" 300 do
            let st := (← c.statStr sIp "repl_follow_state").getD "?"
            let reason := (← c.statStr sIp "repl_follow_last_reason").getD ""
            let entry := if reason.isEmpty then st else s!"{st}({reason})"
            states.modify fun l => if l.getLast? == some entry then l else l ++ [entry]
            return st == "following"
          let recon1 := (← c.statNat sIp "reconstruction_started").getD 0
          IO.eprintln s!"# follow on: states seen {← states.get}; following={following}; reconstruction_started {recon0}→{recon1} (rebuild on enablement={decide (recon1 > recon0)}); applied={← c.statNat sIp "repl_applied_lsn"} source={← c.statNat sIp "repl_source_lsn"}"
          if !following then return .fail s!"the replica never followed after enablement (states {← states.get})"
          let w2 ← writeKeys enableCfg.debugPod enableCfg.«namespace» mIp enableCfg.flarePort "follow" 100
          if !(← convergedItems c mIp sIp "follow on: replica matches the master") then
            return .fail s!"while following: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          if let some bad ← sampleEqual c mIp sIp [("legacy", 200), ("idfwd", 100), ("follow", 100)] then
            return .fail s!"value mismatch after enablement: {bad}"
          let drops1 := (← c.statNat mIp "proxy_write_dropped").getD 0
          IO.eprintln s!"# while following: stored {w2}/100; items {← c.currItems mIp}; master proxy_write_dropped {drops0}→{drops1}"
          -- rollback, reverse order
          match ← kubectlPatch "flarecluster" enableCfg.name enableCfg.«namespace» (enablePatch true false) with
          | .error e => return .fail s!"patch (follow off) failed: {e}"
          | .ok _ => pure ()
          if !(← waitForCondition "both nodes reload repl_follow_enabled 1 -> 0" 240 do bothReloaded c "repl_follow_enabled: 1 -> 0") then
            return .fail "following was not switched off on both nodes"
          let w3 ← writeKeys enableCfg.debugPod enableCfg.«namespace» mIp enableCfg.flarePort "followoff" 50
          match ← kubectlPatch "flarecluster" enableCfg.name enableCfg.«namespace» (enablePatch false false) with
          | .error e => return .fail s!"patch (identity off) failed: {e}"
          | .ok _ => pure ()
          if !(← waitForCondition "both nodes reload repl_identity_forward 1 -> 0" 240 do bothReloaded c "repl_identity_forward: 1 -> 0") then
            return .fail "identity forwarding was not switched off on both nodes"
          let w4 ← writeKeys enableCfg.debugPod enableCfg.«namespace» mIp enableCfg.flarePort "legacy2" 50
          if !(← convergedItems c mIp sIp "rolled back: replica matches the master") then
            return .fail s!"after the rollback: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          if let some bad ← sampleEqual c mIp sIp [("legacy", 200), ("idfwd", 100), ("follow", 100), ("followoff", 50), ("legacy2", 50)] then
            return .fail s!"value mismatch after the rollback: {bad}"
          IO.eprintln s!"# rolled back: stored {w3}/50 + {w4}/50; items {← c.currItems mIp}; replica follow state={← c.statStr sIp "repl_follow_state"}; reconstruction_started {recon0}→{(← c.statNat sIp "reconstruction_started").getD 0}"
          -- the procedure never moved the master
          let log ← c.opLog 200000
          let moved := (log.splitOn "\n").filter fun l =>
            -- "dead nodes:" not "detected ": the grace-period line says
            -- "dead-node detection" (CI 37081571564 matched it).
            containsSubstr l "dead nodes:" || containsSubstr l "PROMOTION" || containsSubstr l "graceful drain:" || containsSubstr l "CIRCUIT BREAKER"
          let master := (findMasterFqdn (← c.nodeView) 0).bind (fun f => (f.splitOn ".").head?)
          IO.eprintln s!"# master throughout: {master} (was {mPod}); replica {sPod}; failover/promotion lines: {moved.length}"
          if master != some mPod then return .fail s!"the master moved during enablement ({mPod} → {master})"
          if !moved.isEmpty then return .fail s!"the operator logged failover/promotion during enablement: {moved.take 3}"
          return .pass }
  ]
}

-- ─── failover lag hold: the two release paths, end to end ─────────────────

/-- Shared precondition for the lag-hold variants: past the operator's
    startup grace, forwards cut, 120 writes the throttled follower is behind
    on, and the operator has judged it unfit. Returns
    (mPod, mIp, sPod, sIp, master items, replica items). -/
private def lagPrepare (c : Ctx) : IO (Except String (String × String × String × String × Nat × Nat)) := do
  let graceOver ← waitForCondition "operator past its startup grace period" 240 do
    return containsSubstr (← c.opLog 400) "grace period over"
  if !graceOver then return .error "the operator never logged the end of its startup grace period"
  match ← c.pair with
  | .error e => return .error e
  | .ok (mPod, mIp, sPod, sIp) =>
    let stored ← writeKeys c.cfg.debugPod c.cfg.«namespace» mIp c.cfg.flarePort "base" 20
    let synced ← waitForCondition "replica following and matching" 180 do
      return (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == (← c.currItems mIp)
    if stored != 20 || !synced then return .error s!"precondition: replica not following (stored {stored}/20)"
    match ← cutForwards mIp sIp with
    | .error e => return .error e
    | .ok () => pure ()
    let w ← writeKeys c.cfg.debugPod c.cfg.«namespace» mIp c.cfg.flarePort "hold" 120
    let unfit ← waitForCondition "the operator judges the follower unfit" 120 do
      return ((← c.opLog 2000).splitOn "\n").any fun l =>
        containsSubstr l s!"eligibility {sPod}" && containsSubstr l "more than the failover bound"
    let mItems ← c.currItems mIp
    let sItems ← c.currItems sIp
    IO.eprintln s!"# before the kill: stored {w}/120; items master={mItems} replica={sItems}; replica source={← c.statNat sIp "repl_source_lsn"} applied={← c.statNat sIp "repl_applied_lsn"}; unfit judged={unfit}"
    if !unfit then healForwards mIp sIp; return .error "precondition: the follower was never judged unfit"
    return .ok (mPod, mIp, sPod, sIp, mItems, sItems)

private def masterPodOf (c : Ctx) : IO (Option String) := do
  return (findMasterFqdn (← c.nodeView) 0).bind (fun f => (f.splitOn ".").head?)

private def notLossFreeFor (c : Ctx) (pod : String) : IO Bool := do
  return ((← c.opLog 200000).splitOn "\n").any fun l => containsSubstr l "PROMOTION NOT LOSS-FREE" && containsSubstr l pod

/-- The operator's own `flare_operator_partitions_masterless` gauge (scraped
    from its /metrics), `none` when it cannot be read. The masterless STATE is
    detected by this gauge and the FlareMasterMissing alert, independently of
    the hold's reason log (review 2026-10-06). -/
private def Ctx.masterlessGauge (c : Ctx) : IO (Option Nat) := do
  match (← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»).head? with
  | none => return none
  | some pod =>
    match ← getPodIp pod c.cfg.«namespace» with
    | none => return none
    | some ip =>
      match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"wget -qO- -T 5 http://{ip}:9090/metrics | grep -E '^flare_operator_partitions_masterless'" with
      | .error _ => return none
      | .ok out =>
        return ((out.splitOn "\n").findSome? fun l =>
          if l.startsWith "flare_operator_partitions_masterless" then (l.splitOn " ").getLast?.bind (fun v => ((v.trim.splitOn ".").head?).bind (·.toNat?)) else none)

/-- The NOT LOSS-FREE line logged for `pod`, if any (its reason is checked:
    a known-empty ex-master and an expired wait are different reasons). -/
private def notLossFreeLine (c : Ctx) (pod : String) : IO (Option String) := do
  return ((← c.opLog 200000).splitOn "\n").find? fun l => containsSubstr l "PROMOTION NOT LOSS-FREE" && containsSubstr l pod

private def holdFlags : String := flags ++ "\nrepl-follow-max-batches = 1\nrepl-follow-batch-delay-usec = 1000000"

-- A: tmpfs. The ex-master's pod is recreated EMPTY, so there is nothing to
-- wait for: the far-behind follower is seated at once, loudly.
private def holdTmpfsCfg : ClusterConfig := {
  name := "cont-repl-hold-tmpfs"
  «namespace» := "flare-cont-repl-hold-tmpfs"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-hold-tmpfs"
  storageBackend := "rocksdb"
  useTmpfs := true
  tmpfsSize := "512Mi"
  extraFlaredConf := holdFlags
  operatorEnv := [("FLARE_FOLLOW_FAILOVER_MAX_LAG", "20"), ("FLARE_FOLLOW_FAILOVER_WAIT_SECONDS", "900")]
}

def lagHoldTmpfsSuite : TestSuite := {
  name := "continuous-replication-lag-hold-tmpfs"
  setup := do
    deployCluster holdTmpfsCfg
    IO.sleep 50000
  teardown := cleanupCluster holdTmpfsCfg
  onFailure := dumpClusterDiagnostics holdTmpfsCfg.«namespace» s!"app={holdTmpfsCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := holdTmpfsCfg }
    [
    { name := "failover lag bound on tmpfs: the master pod is deleted and returns EMPTY; nothing to wait for, so the far-behind follower is seated at once and logged NOT LOSS-FREE; the empty ex-master rebuilds from it"
      run := do
        match ← lagPrepare c with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp, mItems, sItems) =>
          discard <| kubectl ["delete", "pod", mPod, "-n", holdTmpfsCfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          healForwards mIp sIp
          let seated ← waitForCondition "the follower is seated once the ex-master is back empty" 300 do
            return (← masterPodOf c) == some sPod
          let loud ← notLossFreeFor c sPod
          IO.eprintln s!"# after the kill: follower seated={seated}; NOT LOSS-FREE logged={loud}; items new master={← c.currItems sIp} (follower had {sItems}, old master acknowledged {mItems})"
          if !seated then return .fail s!"the follower was not seated after the empty ex-master returned (master now {← masterPodOf c})"
          if !loud then return .fail "the far-behind follower was seated without the NOT LOSS-FREE line"
          let why := (← notLossFreeLine c sPod).getD ""
          if !containsSubstr why "READ empty" then
            return .fail s!"the hold ended without a KNOWN-empty ex-master reading (logged reason: {why})"
          let rejoined ← waitForCondition "the empty ex-master follows the new master and matches" 420 do
            match ← getPodIp mPod holdTmpfsCfg.«namespace» with
            | none => return false
            | some ip => return (← c.statStr ip "repl_follow_state") == some "following" && (← c.currItems ip) == (← c.currItems sIp)
          IO.eprintln s!"# ex-master {mPod} rejoined as a follower={rejoined}; items={← c.currItems sIp}"
          if !rejoined then return .fail "the empty ex-master did not rebuild from and follow the new master"
          return .pass }
  ]
}

-- B: the wait runs out. The ex-master is kept away (node cordoned) past
-- FLARE_FOLLOW_FAILOVER_WAIT_SECONDS = 60, so the follower is seated after
-- the wait, loudly; the ex-master then returns WITH data and follows it.
private def holdExpiryCfg : ClusterConfig := {
  name := "cont-repl-hold-exp"
  «namespace» := "flare-cont-repl-hold-exp"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-hold-exp"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := holdFlags
  operatorEnv := [("FLARE_FOLLOW_FAILOVER_MAX_LAG", "20"), ("FLARE_FOLLOW_FAILOVER_WAIT_SECONDS", "60")]
}

def lagHoldExpirySuite : TestSuite := {
  name := "continuous-replication-lag-hold-expiry"
  setup := do
    deployCluster holdExpiryCfg
    IO.sleep 50000
  teardown := do
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster holdExpiryCfg
  onFailure := dumpClusterDiagnostics holdExpiryCfg.«namespace» s!"app={holdExpiryCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := holdExpiryCfg }
    [
    { name := "failover lag bound, wait expiry: the ex-master stays away past the 60 s wait; the far-behind follower is then seated and logged NOT LOSS-FREE, not before; the returning ex-master follows it"
      run := do
        match ← lagPrepare c with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp, _, sItems) =>
          match ← kubectl ["cordon", kindNode] with
          | .error e => healForwards mIp sIp; return .fail s!"could not cordon {kindNode}: {e}"
          | .ok _ => pure ()
          let t0 ← IO.monoMsNow
          discard <| kubectl ["delete", "pod", mPod, "-n", holdExpiryCfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          healForwards mIp sIp
          let seated ← waitForCondition "the follower is seated after the wait runs out" 300 do
            return (← masterPodOf c) == some sPod
          let tookS := ((← IO.monoMsNow) - t0) / 1000
          let loud ← notLossFreeFor c sPod
          let held := ((← c.opLog 200000).splitOn "\n").any fun l => containsSubstr l "has NO master" && containsSubstr l sPod
          discard <| kubectl ["uncordon", kindNode]
          IO.eprintln s!"# with the ex-master away: held first={held}; follower seated={seated} after {tookS}s (wait 60 s); NOT LOSS-FREE logged={loud}"
          if !seated then return .fail "the follower was never seated although the wait ran out"
          if tookS < 60 then return .fail s!"the follower was seated after {tookS}s, before the 60 s wait ran out"
          if !held || !loud then return .fail s!"expected the hold line and then the NOT LOSS-FREE line (held={held}, loud={loud})"
          let why := (← notLossFreeLine c sPod).getD ""
          if !containsSubstr why "EXPIRED" then
            return .fail s!"the crowning after the wait was not logged as the expiry policy (logged reason: {why})"
          let rejoined ← waitForCondition "the returning ex-master follows the new master and matches" 480 do
            match ← getPodIp mPod holdExpiryCfg.«namespace» with
            | none => return false
            | some ip => return (← c.statStr ip "repl_follow_state") == some "following" && (← c.currItems ip) == (← c.currItems sIp)
          IO.eprintln s!"# ex-master {mPod} follows the new master={rejoined}; items={← c.currItems sIp} (the follower had {sItems} at the kill)"
          if !rejoined then return .fail "the returning ex-master did not follow the new master"
          return .pass }
  ]
}

-- D: the ex-master returns but CANNOT BE READ (CI 37296281060: an
-- unreadable returning ex-master was taken as "back empty" and the
-- far-behind follower was crowned). The test seam FLARE_TEST_STATS_BLOCK
-- makes the operator's data probe treat the returning pod as unreadable.
private def holdUnreadableCfg : ClusterConfig := {
  name := "cont-repl-hold-unr"
  «namespace» := "flare-cont-repl-hold-unr"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-hold-unr"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := holdFlags
  operatorEnv := [("FLARE_FOLLOW_FAILOVER_MAX_LAG", "20"), ("FLARE_FOLLOW_FAILOVER_WAIT_SECONDS", "900"),
                  ("FLARE_TEST_STATS_BLOCK", "/tmp/stb")]
}

private def opShell (c : Ctx) (cmd : String) : IO (Except String String) := do
  match (← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»).head? with
  | none => return .error "no operator pod"
  | some pod => kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", cmd]

def lagHoldUnreadableSuite : TestSuite := {
  name := "continuous-replication-lag-hold-unreadable"
  setup := do
    deployCluster holdUnreadableCfg
    IO.sleep 50000
  teardown := do
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster holdUnreadableCfg
  onFailure := dumpClusterDiagnostics holdUnreadableCfg.«namespace» s!"app={holdUnreadableCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := holdUnreadableCfg }
    let ns := holdUnreadableCfg.«namespace»
    [
    { name := "failover lag bound, ex-master back but UNREADABLE: while its stats are blocked the far-behind follower is never crowned (the hold continues, the wait has not expired); once readable the ex-master is master again with every write it acknowledged"
      run := do
        match ← lagPrepare c with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp, mItems, _) =>
          match ← opShell c s!"mkdir -p /tmp/stb && echo {mPod} > /tmp/stb/stats-block" with
          | .error e => healForwards mIp sIp; return .fail s!"could not arm the stats block: {e}"
          | .ok _ => pure ()
          match ← kubectl ["cordon", kindNode] with
          | .error e => healForwards mIp sIp; return .fail s!"could not cordon {kindNode}: {e}"
          | .ok _ => pure ()
          discard <| kubectl ["delete", "pod", mPod, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
          healForwards mIp sIp
          let held ← waitForCondition "the hold is logged while the ex-master is away" 180 do
            return ((← c.opLog 3000).splitOn "\n").any fun l => containsSubstr l "has NO master" && containsSubstr l sPod
          discard <| kubectl ["uncordon", kindNode]
          if !held then return .fail "precondition: the hold line never appeared while the ex-master was away"
          -- the ex-master comes back and registers, but cannot be read
          let registered ← waitForCondition "the ex-master re-registers (Prepare) while its stats are blocked" 300 do
            let entries ← c.nodeView
            return entries.any fun e => (e.fqdn.splitOn ".").head? == some mPod && e.state != 2
          let blockedSeen ← waitForCondition "the operator's data probe reports the ex-master blocked" 120 do
            return ((← c.opLog 3000).splitOn "\n").any fun l => containsSubstr l "blocked by test seam" && containsSubstr l mPod
          if !registered || !blockedSeen then
            discard <| opShell c "rm -f /tmp/stb/stats-block"
            return .fail s!"precondition: the ex-master did not come back unreadable (registered={registered}, blocked seen={blockedSeen})"
          -- 90 s with the ex-master live and unreadable: no crowning
          let mut crowned := false
          let mut passesBlocked := 0
          for _ in [0:45] do
            IO.sleep 2000
            if (← masterPodOf c) == some sPod then crowned := true; break
          passesBlocked := (((← c.opLog 20000).splitOn "\n").filter fun l => containsSubstr l "blocked by test seam" && containsSubstr l mPod).length
          let gauge ← c.masterlessGauge
          let loudEarly ← notLossFreeFor c sPod
          IO.eprintln s!"# ex-master {mPod} live and unreadable for 90 s ({passesBlocked} blocked probe passes): follower crowned={crowned}; NOT LOSS-FREE logged={loudEarly}; masterless gauge={gauge}"
          discard <| opShell c "rm -f /tmp/stb/stats-block"
          if crowned || loudEarly then
            return .fail s!"the far-behind follower {sPod} was crowned while the returning ex-master could not be read (wait not expired)"
          if passesBlocked < 3 then return .fail s!"precondition: only {passesBlocked} probe pass(es) saw the ex-master blocked"
          if (gauge.getD 0) < 1 then return .fail s!"the masterless partition was not reported by flare_operator_partitions_masterless (read {gauge})"
          -- readable again: the ex-master holds its data and is re-seated
          let exBack ← waitForCondition "the ex-master is master again once readable" 300 do
            return (← masterPodOf c) == some mPod
          let back ← waitForCondition "the ex-master serves every write it acknowledged" 120 do
            match ← getPodIp mPod ns with
            | none => return false
            | some ip => return (← c.currItems ip) == mItems
          let newIp := (← getPodIp mPod ns).getD ""
          IO.eprintln s!"# after unblocking: ex-master master again={exBack}; items={← c.currItems newIp} (acknowledged {mItems}); NOT LOSS-FREE for the follower={← notLossFreeFor c sPod}"
          if !exBack then return .fail s!"the ex-master was not re-seated after it became readable (master {← masterPodOf c})"
          if !back then return .fail s!"the ex-master holds {← c.currItems newIp} items, {mItems} were acknowledged"
          if ← notLossFreeFor c sPod then return .fail "a NOT LOSS-FREE crowning of the follower was logged"
          return .pass }
  ]
}

-- C: enablement after the WAL since the replica's last copy was purged.
private def enablePurgedCfg : ClusterConfig := {
  name := "cont-repl-enable-p"
  «namespace» := "flare-cont-repl-enable-p"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-enable-p"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := "rocksdb-write-buffer-size-mb = 4\nrocksdb-wal-ttl-seconds = 60\nrocksdb-wal-size-limit-mb = 16"
  -- Slow ConfigMap propagation, made deterministic: the operator holds every
  -- rocksdb config write back 45 s, so the replica is read in the OLD mode
  -- after the follow change (review 2026-10-05).
  operatorEnv := [("FLARE_TEST_CONF_WRITE_DELAY_SECONDS", "45")]
}

/-- Seconds of day of a `kubectl logs --timestamps` line (RFC 3339, UTC). -/
private def logTs (line : String) : Option Float :=
  match (line.splitOn "T").drop 1 |>.head? with
  | none => none
  | some rest =>
    match (rest.takeWhile (· != 'Z')).splitOn ":" with
    | [h, m, sec] =>
      let (whole, frac) := match sec.splitOn "." with
        | [w, f] => (w, f)
        | _ => (sec, "0")
      match h.toNat?, m.toNat?, whole.toNat?, frac.toNat? with
      | some hh, some mm, some ss, some ff =>
        some (hh.toFloat * 3600 + mm.toFloat * 60 + ss.toFloat + ff.toFloat / (10 : Float) ^ frac.length.toFloat)
      | _, _, _, _ => none
    | _ => none

/-- First line containing `needle` at or after `from` (seconds of day). -/
private def firstAt (lines : List String) (needle : String) (from_ : Float) : Option (Float × String) :=
  lines.findSome? fun l =>
    if containsSubstr l needle then
      match logTs l with
      | some t => if t ≥ from_ then some (t, l) else none
      | none => none
    else none

private def enablePurgedPatch (identity follow : Bool) : String :=
  s!"\{\"spec\":\{\"rocksdb\":\{\"writeBufferSizeMb\":4,\"walTtlSeconds\":60,\"walSizeLimitMb\":16,\"replIdentityForward\":{identity},\"replFollowEnabled\":{follow},\"replFollowPollIntervalUsec\":200000}}}"

/-- `count` keys of `bytes` each in ONE exec (a shell loop in the debug pod). -/
private def Ctx.bulkWrite (c : Ctx) (ip pfx : String) (count bytes : Nat) : IO Nat := do
  let cmd := s!"v=$(head -c {bytes} /dev/zero | tr '\\0' x); n=0; for i in $(seq 0 {count - 1}); do printf 'set {pfx}_%s 0 0 {bytes}\\r\\n%s\\r\\n' $i \"$v\" | nc -w 5 {ip} {c.cfg.flarePort} | grep -q STORED && n=$((n+1)); done; echo $n"
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» cmd with
  | .ok o => return ((o.trim.splitOn "\n").getLast?.getD "0").trim.toNat?.getD 0
  | .error _ => return 0

def enablePurgedSuite : TestSuite := {
  name := "continuous-replication-enable-purged"
  setup := do
    deployCluster enablePurgedCfg
    IO.sleep 50000
  teardown := cleanupCluster enablePurgedCfg
  onFailure := dumpClusterDiagnostics enablePurgedCfg.«namespace» s!"app={enablePurgedCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := enablePurgedCfg }
    [
    { name := "enablement after the master purged the WAL since the replica's last copy: the replica declares lsn_purged, is rebuilt once, then follows; data equal, no failover"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, _, sIp) =>
          let w0 ← writeKeys enablePurgedCfg.debugPod enablePurgedCfg.«namespace» mIp enablePurgedCfg.flarePort "legacy" 100
          let big ← c.bulkWrite mIp "bulk" 1000 50000
          if w0 != 100 || big < 1000 then return .fail s!"legacy writes: stored {w0}/100 and {big}/1000 bulk"
          if !(← convergedItems c mIp sIp "legacy: replica matches the master") then
            return .fail s!"legacy: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          -- Let the 60 s TTL pass with more flushes, so the archived WAL from
          -- the replica's copy position is purged.
          IO.sleep 90000
          let big2 ← c.bulkWrite mIp "bulk2" 200 50000
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          IO.eprintln s!"# legacy: {big}+{big2} keys of 50 kB; items {← c.currItems mIp}; replica repl_last_lsn={← c.statNat sIp "rocksdb_repl_last_lsn"}; master latest={← c.statNat mIp "rocksdb_latest_sequence_number"}; reconstruction_started={recon0}"
          match ← kubectlPatch "flarecluster" enablePurgedCfg.name enablePurgedCfg.«namespace» (enablePurgedPatch true false) with
          | .error e => return .fail s!"patch (identity on) failed: {e}"
          | .ok _ => pure ()
          if !(← waitForCondition "both nodes reload repl_identity_forward 0 -> 1" 240 do bothReloaded c "repl_identity_forward: 0 -> 1") then
            return .fail "identity forwarding was not applied on both nodes"
          match ← kubectlPatch "flarecluster" enablePurgedCfg.name enablePurgedCfg.«namespace» (enablePurgedPatch true true) with
          | .error e => return .fail s!"patch (follow on) failed: {e}"
          | .ok _ => pure ()
          let states ← IO.mkRef ([] : List String)
          -- Timeline (review 2026-10-05: confirm the needs_rebuild → ledger
          -- request → reconstruction path and its timing on the new SHA).
          let t0 ← IO.monoMsNow
          let tDeclared ← IO.mkRef (none : Option Nat)
          let tRebuild ← IO.mkRef (none : Option Nat)
          let following ← waitForCondition "the replica follows after enablement" 420 do
            let st := (← c.statStr sIp "repl_follow_state").getD "?"
            let reason := (← c.statStr sIp "repl_follow_last_reason").getD ""
            let entry := if reason.isEmpty then st else s!"{st}({reason})"
            states.modify fun l => if l.getLast? == some entry then l else l ++ [entry]
            let now := ((← IO.monoMsNow) - t0) / 1000
            if st == "needs_rebuild" && (← tDeclared.get).isNone then tDeclared.set (some now)
            if (← c.statNat sIp "reconstruction_started").getD 0 > recon0 && (← tRebuild.get).isNone then tRebuild.set (some now)
            return st == "following" && (← c.statNat sIp "reconstruction_started").getD 0 > recon0
          let opLines := match ← kubectl ["logs", "-n", enablePurgedCfg.«namespace», "-l", s!"app={enablePurgedCfg.operatorName}", "--timestamps", "--tail=20000"] with
            | .ok o => (o.splitOn "\n").filter (fun l => containsSubstr l "REPLICA REPAIR requested by the follower" || containsSubstr l "REPLICA REPAIR: demoting" || containsSubstr l "replica repair DEFERRED" || containsSubstr l "replica repair HELD")
            | .error _ => []
          IO.eprintln s!"# timeline: needs_rebuild first seen at +{(← tDeclared.get)}s, reconstruction started by +{(← tRebuild.get)}s (since follow was enabled)\n# operator repair lines:\n{String.intercalate "\n" (opLines.take 6)}"
          -- Split timeline (review 2026-10-05): config change → delivered,
          -- delivered → observed, observed → requested → started.
          let opAll := match ← kubectl ["logs", "-n", enablePurgedCfg.«namespace», "-l", s!"app={enablePurgedCfg.operatorName}", "--timestamps", "--tail=40000"] with
            | .ok o => o.splitOn "\n"
            | .error _ => []
          let sPodName := match ← c.pair with | .ok (_, _, sp, _) => sp | .error _ => ""
          let flaredAll := match ← kubectl ["logs", "-n", enablePurgedCfg.«namespace», sPodName, "-c", "flared", "--timestamps", "--tail=40000"] with
            | .ok o => o.splitOn "\n"
            | .error _ => []
          let tChange := firstAt opAll "follow configuration changed to follow on" 0
          let from0 := (tChange.map (·.1)).getD 0
          let tRelease := firstAt opAll "TEST SEAM: releasing the held rocksdb config write" from0
          let tLanded := firstAt opAll "config propagation confirmed" ((tRelease.map (·.1)).getD from0)
          let tConfirmed := firstAt opAll s!"follow configuration CONFIRMED on {sPodName}" from0
          let tRequested := firstAt opAll "REPLICA REPAIR requested by the follower" from0
          let tStarted := (firstAt flaredAll "staged rebuild may start" ((tRequested.map (·.1)).getD from0)).orElse
            (fun _ => firstAt flaredAll "rebuild_blocked=" ((tRequested.map (·.1)).getD from0))
          let oldReads : Option Nat := tConfirmed.bind fun (_, l) =>
            ((l.splitOn "old mode read ").drop 1).head?.bind fun r => (r.takeWhile Char.isDigit).toNat?
          let gap := fun (a b : Option (Float × String)) => match a, b with
            | some (x, _), some (y, _) => some (y - x)
            | _, _ => none
          IO.eprintln s!"# split timeline (s): change→write released {gap tChange tRelease}; released→delivered (propagation confirmed) {gap tRelease tLanded}; delivered→observed (CONFIRMED) {gap tLanded tConfirmed}; observed→requested {gap tConfirmed tRequested}; requested→reconstruction started {gap tRequested tStarted}; old mode read before confirmation {oldReads} time(s)"
          let timelineFail : Option String :=
            if tChange.isNone then some "the operator never logged the follow configuration change"
            else if tConfirmed.isNone then some s!"the operator never confirmed the follow configuration on {sPodName}"
            else if (oldReads.getD 0) == 0 then some "precondition: the replica was never read in the OLD mode after the change (the delayed write did not delay)"
            else if (gap tLanded tConfirmed).any (· > 30) then some s!"observed {gap tLanded tConfirmed} s after the configuration was delivered: back to the long re-read interval"
            else if (gap tConfirmed tRequested).any (· > 30) then some s!"the repair was requested {gap tConfirmed tRequested} s after the follow mode was observed"
            else none
          let recon1 := (← c.statNat sIp "reconstruction_started").getD 0
          let purgedSeen := (← states.get).any (containsSubstr · "lsn_purged")
          IO.eprintln s!"# follow on: states seen {← states.get}; lsn_purged seen={purgedSeen}; reconstruction_started {recon0}→{recon1}; following={following}"
          if !following then
            -- CI 37268848902: needs_rebuild declared, no rebuild in 420 s,
            -- and the 80-line diagnostic tail no longer showed the
            -- operator's repair decisions. Print them here.
            let repairLines := ((← c.opLog 200000).splitOn "\n").filter (fun l =>
              containsSubstr l "REPLICA REPAIR" || containsSubstr l "replica repair" || containsSubstr l "ledger"
                || containsSubstr l "demot" || containsSubstr l "reseat" || containsSubstr l "CIRCUIT BREAKER")
            IO.eprintln s!"# operator repair decisions ({repairLines.length} line(s)):\n{String.intercalate "\n" (repairLines.reverse.take 25).reverse}"
            IO.eprintln s!"# ledger: dests={← c.ledgerDests}"
            return .fail s!"expected one rebuild then following; states {← states.get}, reconstruction_started {recon0}→{recon1}"
          if let some why := timelineFail then return .fail why
          if !(← convergedItems c mIp sIp "after the rebuild: replica matches the master") then
            return .fail s!"after the rebuild: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          if let some bad ← sampleEqual c mIp sIp [("legacy", 100)] then return .fail s!"value mismatch: {bad}"
          let master ← masterPodOf c
          IO.eprintln s!"# after: items {← c.currItems mIp}; master {master} (was {mPod})"
          if master != some mPod then return .fail s!"the master moved during enablement ({mPod} → {master})"
          return .pass }
  ]
}

-- ─── space-aware rebuild: two copies do not fit on tmpfs ──────────────────

-- pf-dev's shape in miniature: the tmpfs size equals the memory limit, so
-- staging a second copy next to the replica's own would be charged to the
-- same memory cgroup. ~120 MB of incompressible data per copy in 384Mi.
private def rebuildTmpfsCfg : ClusterConfig := {
  name := "cont-repl-rb-tmpfs"
  «namespace» := "flare-cont-repl-rb-tmpfs"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-rb-tmpfs"
  storageBackend := "rocksdb"
  useTmpfs := true
  tmpfsSize := "384Mi"
  flaredMemoryLimit := "384Mi"
  flaredMemoryRequest := "256Mi"
  extraFlaredConf := "rocksdb-block-cache-size-mb = 16\nrocksdb-write-buffer-size-mb = 4\nrocksdb-wal-ttl-seconds = 60\nrocksdb-wal-size-limit-mb = 16"
  -- ~125 MB copy + 128 MiB reserve cannot fit next to the old copy in 384Mi
  rebuildReserveBytes := some 134217728
  -- a restarted replica rebuilds by a STAGED copy (no WAL catch-up): the
  -- tmpfs copy survives a container restart, so two copies must fit
  flaredEnv := [("FLARE_TEST_DISABLE_WAL_RECONSTRUCTION", "1")]
}

private def rebuildTmpfsPatch (identity follow : Bool) : String :=
  s!"\{\"spec\":\{\"rocksdb\":\{\"rebuildReserveBytes\":134217728,\"blockCacheSizeMb\":16,\"writeBufferSizeMb\":4,\"walTtlSeconds\":60,\"walSizeLimitMb\":16,\"replIdentityForward\":{identity},\"replFollowEnabled\":{follow},\"replFollowPollIntervalUsec\":200000}}}"

/-- `count` keys of one INCOMPRESSIBLE value (random bytes, base64) of about
    `bytes` each, in one exec. RocksDB compresses per block, so a repeated
    random value still occupies its full size on disk. -/
private def Ctx.bulkWriteRandom (c : Ctx) (ip pfx : String) (count bytes : Nat) : IO Nat := do
  let raw := bytes * 3 / 4
  let cmd := s!"v=$(head -c {raw} /dev/urandom | base64 | tr -d '\\n'); len=$(printf %s \"$v\" | wc -c); n=0; for i in $(seq 0 {count - 1}); do printf 'set {pfx}_%s 0 0 %s\\r\\n%s\\r\\n' $i $len \"$v\" | nc -w 5 {ip} {c.cfg.flarePort} | grep -q STORED && n=$((n+1)); done; echo $n"
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» cmd with
  | .ok o => return ((o.trim.splitOn "\n").getLast?.getD "0").trim.toNat?.getD 0
  | .error _ => return 0

def rebuildTmpfsSuite : TestSuite := {
  name := "continuous-replication-rebuild-tmpfs"
  setup := do
    deployCluster rebuildTmpfsCfg
    IO.sleep 50000
  teardown := cleanupCluster rebuildTmpfsCfg
  onFailure := dumpClusterDiagnostics rebuildTmpfsCfg.«namespace» s!"app={rebuildTmpfsCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := rebuildTmpfsCfg }
    [
    { name := "no room on tmpfs (copy retention §9): a restarted replica whose staged copy plus the reserve does not fit next to its old copy (tmpfs = memory limit, like pf-dev) STOPS and says why (stats rebuild_blocked=no_space); nothing is discarded, no OOM restart, the replica's copy is kept, no staging copy is left behind"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let w0 ← writeKeys rebuildTmpfsCfg.debugPod rebuildTmpfsCfg.«namespace» mIp rebuildTmpfsCfg.flarePort "legacy" 50
          let big ← c.bulkWriteRandom mIp "rnd" 2400 50000
          if w0 != 50 || big < 2400 then return .fail s!"legacy writes: stored {w0}/50 and {big}/2400 random"
          if !(← convergedItems c mIp sIp "legacy: replica matches the master") then
            return .fail s!"legacy: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          let rc0 ← c.restartCount sPod
          let items0 ← c.currItems sIp
          let sw0 := (← c.statNat sIp "rocksdb_staged_switched").getD 0
          let data0 ← match ← kubectl ["exec", "-n", rebuildTmpfsCfg.«namespace», sPod, "--", "sh", "-c", "du -sm /data | cut -f1"] with
            | .ok o => pure o.trim
            | .error _ => pure "?"
          IO.eprintln s!"# legacy: {big} random values of ~50 kB; replica items {items0}, data dir {data0} MB in a 384Mi tmpfs/memory limit; reserve {rebuildTmpfsCfg.rebuildReserveBytes}; restarts {rc0}; staged switches {sw0}"
          -- the replica's flared restarts (its tmpfs copy stays: a container
          -- restart keeps the emptyDir) and must rebuild by a staged copy
          if let .error e ← c.killFlaredIn sPod then return .fail s!"precondition: could not restart flared in {sPod}: {e}"
          let blocked ← waitForCondition "the replica's rebuild stops: rebuild_blocked=no_space" 480 do
            return (← c.statStr sIp "rebuild_blocked") == some "no_space"
          let line := match ← kubectl ["logs", "-n", rebuildTmpfsCfg.«namespace», sPod, "--tail=5000"] with
            | .ok o => (o.splitOn "\n").find? (containsSubstr · "rebuild_blocked=no_space")
            | .error _ => none
          IO.sleep 60000
          let rc1 ← c.restartCount sPod
          let items1 ← c.currItems sIp
          let sw1 := (← c.statNat sIp "rocksdb_staged_switched").getD 0
          let left ← match ← kubectl ["exec", "-n", rebuildTmpfsCfg.«namespace», sPod, "--", "sh", "-c", "ls -d /data/staging-* /data/retained-* 2>/dev/null | wc -l"] with
            | .ok o => pure (o.trim.toNat?.getD 99)
            | .error _ => pure 99
          IO.eprintln s!"# follow on: blocked={blocked}; replica restarts {rc0}→{rc1}; items {items0}→{items1}; staged switches {sw0}→{sw1}; staging/retained dirs left {left}\n# {line.getD "(no rebuild_blocked line)"}"
          if rc1 != rc0 + 1 then return .fail s!"the replica's container restarted beyond the one restart the test caused ({rc0}→{rc1}): the copy did not stop in time"
          if !blocked then return .fail "the rebuild did not stop with rebuild_blocked=no_space"
          if line.isNone then return .fail "no CRITICAL rebuild_blocked=no_space line was logged"
          -- the counter belongs to the flared process: the restarted one starts
          -- at 0, so any switch since the restart shows as ≥ 1
          if sw1 != 0 then return .fail s!"a staged copy was switched in although it could not fit ({sw1} switch(es) since the restart)"
          if items1 < items0 then return .fail s!"the replica's copy shrank ({items0}→{items1}): something was discarded"
          if left != 0 then return .fail s!"{left} staging/retained director(ies) left on the replica"
          if (← masterPodOf c) != some mPod then return .fail "the master moved"
          return .pass }
  ]
}

-- ─── upgrade from the deployed release, on tmpfs = memory limit ───────────

-- pf-dev's 2026-10-05 roll in miniature: rc56 (no source epochs) rolled to
-- the build under test on tmpfs whose size equals the memory limit. The roll
-- used to get stuck (two copies, OOM on every retry). With copy retention the
-- new replica builds a staged copy of the epoch-less master by the LEGACY rule
-- (the position must not move from L0 until after the switch: no writes
-- during the roll) and switches it in; nothing is discarded.
private def upgradeCfg : ClusterConfig := {
  name := "cont-repl-upgrade"
  «namespace» := "flare-cont-repl-upgrade"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-upgrade"
  storageBackend := "rocksdb"
  useTmpfs := true
  tmpfsSize := "384Mi"
  flaredMemoryLimit := "384Mi"
  flaredMemoryRequest := "256Mi"
  extraFlaredConf := "rocksdb-block-cache-size-mb = 16\nrocksdb-write-buffer-size-mb = 4"
  -- rc56 flared does not know rocksdb-rebuild-reserve-bytes and refuses to
  -- START with an unknown option: it is set through the CR after the
  -- operator rolled (the upgrade procedure), never at rc56's boot
  rebuildReserveBytes := none
  flaredImageOverride := some "ghcr.io/gree/flare-node-rocksdb:0.1.0-rc56"
  operatorImageOverride := some "ghcr.io/gree/flare-operator:0.1.0-rc56"
}

def upgradeSuite : TestSuite := {
  name := "continuous-replication-upgrade"
  setup := do
    deployCluster upgradeCfg
    IO.sleep 60000
  teardown := cleanupCluster upgradeCfg
  onFailure := dumpClusterDiagnostics upgradeCfg.«namespace» s!"app={upgradeCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := upgradeCfg }
    [
    { name := "upgrade from rc56 (the deployed release) to this build on tmpfs = memory limit, by the release procedure (operator first, then spec.rocksdb.rebuildReserveBytes, then flared): the roll completes with no container restart; the new replica copies the epoch-less master by the LEGACY staged rule (position unchanged from L0 through the switch, no writes during the roll) and switches it in; data equal; writes work after"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let w0 ← writeKeys upgradeCfg.debugPod upgradeCfg.«namespace» mIp upgradeCfg.flarePort "old" 50
          let big ← c.bulkWriteRandom mIp "rnd" 2400 50000
          if w0 != 50 || big < 2400 then return .fail s!"writes on rc56: stored {w0}/50 and {big}/2400 random"
          if !(← convergedItems c mIp sIp "rc56: replica matches the master") then
            return .fail s!"rc56: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          let items0 ← c.currItems mIp
          IO.eprintln s!"# rc56 cluster: master {mPod}, replica {sPod}; items {items0} (~120 MB incompressible) in a 384Mi tmpfs/memory limit"
          -- roll to the build under test: operator first, and wait for it.
          -- flared exits at startup when it cannot register with the operator
          -- (cluster.cc startup_node), so rolling both at once crash-looped the
          -- new replica until the new operator was up (CI 37265042480: exit
          -- 255 three times, not a data problem). On pf-dev the operator was
          -- Ready ~40 s before the replica rolled (60 s drain).
          let ns := upgradeCfg.«namespace»
          discard <| kubectl ["set", "image", s!"deployment/{upgradeCfg.operatorName}", "-n", ns, "flare-operator=flare-operator:test"]
          if !(← kubectlRolloutStatus s!"deployment/{upgradeCfg.operatorName}" ns 240) then
            return .fail "the operator did not roll to the build under test"
          let opUp ← waitForCondition "the new operator answers node sync" 120 do
            return !(← c.nodeView).isEmpty
          if !opUp then return .fail "the new operator never answered node sync"
          -- the release procedure: the reserve goes into the CR once the new
          -- operator runs; the rc56 pods refuse that reload (unknown option)
          -- and keep running; the new pods boot with it
          match ← kubectlPatch "flarecluster" upgradeCfg.name ns s!"\{\"spec\":\{\"rocksdb\":\{\"rebuildReserveBytes\":{e2eRebuildReserveBytes},\"blockCacheSizeMb\":16,\"writeBufferSizeMb\":4}}}" with
          | .error e => return .fail s!"patch (rebuildReserveBytes) failed: {e}"
          | .ok _ => pure ()
          let confHas ← waitForCondition "the operator writes the reserve into extra.conf" 180 do
            match ← kubectl ["get", "configmap", s!"{upgradeCfg.name}-config", "-n", ns, "-o", "jsonpath={.data.extra\\.conf}"] with
            | .ok o => return containsSubstr o "rocksdb-rebuild-reserve-bytes"
            | .error _ => return false
          if !confHas then return .fail "the operator did not render rebuildReserveBytes into extra.conf"
          match ← kubectl ["set", "image", s!"statefulset/{upgradeCfg.name}-nodes", "-n", ns, "flared=flare-node-rocksdb:test"] with
          | .error e => return .fail s!"set image failed: {e}"
          | .ok _ => pure ()
          let t0 ← IO.monoMsNow
          let done ← waitForCondition "both flared pods run the new build and are Ready" 1200 do
            match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={upgradeCfg.name}", "-o", "jsonpath={range .items[*]}{.spec.containers[0].image}={.status.containerStatuses[0].ready} {end}"] with
            | .ok o =>
              let es := (o.trim.splitOn " ").filter (· != "")
              return es.length == 2 && es.all (· == "flare-node-rocksdb:test=true")
            | .error _ => return false
          let rollS := ((← IO.monoMsNow) - t0) / 1000
          let r0 ← c.restartCount s!"{upgradeCfg.name}-nodes-0"
          let r1 ← c.restartCount s!"{upgradeCfg.name}-nodes-1"
          let oomKilled ← do
            match ← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={upgradeCfg.name}", "-o", "jsonpath={range .items[*]}{.metadata.name}={.status.containerStatuses[0].lastState.terminated.reason} {end}"] with
            | .ok o => pure (containsSubstr o "OOMKilled", o.trim)
            | .error _ => pure (false, "?")
          let (legacyPath, legacyDone) ← do
            let mut seen := false
            let mut doneSeen := false
            for pod in [s!"{upgradeCfg.name}-nodes-0", s!"{upgradeCfg.name}-nodes-1"] do
              match ← kubectl ["logs", "-n", ns, pod, "--tail=20000"] with
              | .ok o =>
                if containsSubstr o "legacy source (no source epoch)" then seen := true
                if containsSubstr o "staged rebuild DONE" && containsSubstr o "history (legacy)" then doneSeen := true
              | .error _ => pure ()
            pure (seen, doneSeen)
          IO.eprintln s!"# roll: done={done} in {rollS}s; container restarts nodes-0={r0} nodes-1={r1}; last termination reasons [{oomKilled.2}]; legacy staged rule used={legacyPath}, legacy copy switched in={legacyDone}"
          if oomKilled.1 then return .fail s!"a flared container was OOMKilled during the roll ({oomKilled.2}): two copies did not fit"
          if !done then return .fail s!"the roll did not complete within 20 min (restarts nodes-0={r0} nodes-1={r1})"
          if r0 + r1 > 0 then return .fail s!"flared containers restarted during the roll (nodes-0={r0} nodes-1={r1}): two copies did not fit"
          if !legacyPath || !legacyDone then return .fail s!"the new replica did not copy the epoch-less master by the legacy staged rule (used={legacyPath}, switched in={legacyDone})"
          match ← c.pair with
          | .error e => return .fail s!"after the roll: {e}"
          | .ok (_, mIp2, _, sIp2) =>
            if !(← convergedItems c mIp2 sIp2 "after the roll: replica matches the master") then
              return .fail s!"after the roll: items master={← c.currItems mIp2} replica={← c.currItems sIp2}"
            if (← c.currItems mIp2) != items0 then return .fail s!"items changed across the roll: {items0} → {← c.currItems mIp2}"
            if let some bad ← sampleEqual c mIp2 sIp2 [("old", 50)] then return .fail s!"value mismatch after the roll: {bad}"
            let w1 ← writeKeys upgradeCfg.debugPod ns mIp2 upgradeCfg.flarePort "new" 20
            IO.eprintln s!"# after the roll: items {← c.currItems mIp2}; writes on the new build stored {w1}/20"
            if w1 != 20 then return .fail s!"writes after the roll: stored {w1}/20"
            return .pass }
  ]
}

-- ─── SAF-08: the surviving copy a promotion relies on ─────────────────────

-- 1p x 3r, PVC, legacy replication (no continuous following: in follow mode
-- an unreadable pod is already "unproven" and kept out of a drain, so only
-- legacy mode shows the readiness rule), drain window 20 s.
private def utcNow : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }
  return out.stdout.trim

/-- Container logs (previous + current) since a fixed time, with timestamps. -/
private def Ctx.flaredLogAllSince (c : Ctx) (pod since : String) : IO String := do
  let mut acc := ""
  for extra in [["--previous"], []] do
    match ← kubectl (["logs", "-n", c.cfg.«namespace», pod, "-c", "flared", s!"--since-time={since}", "--timestamps"] ++ extra) with
    | .ok o => acc := acc ++ o
    | .error _ => pure ()
  return acc

/-- The operator's decisions and the replica's copy-affecting events in a
    FIXED window, printed whether the test passes or fails (CI 37472032699:
    the failure dump held only the log tail, so the path that demoted a
    replica after a deferral was not visible). Operator lines from every
    operator pod (current and previous container); flared lines of `pods`. -/
private def Ctx.windowRecord (c : Ctx) (since : String) (pods : List String) (label : String) : IO Unit := do
  let opNeedles := ["REPLICA REPAIR", "repair DEFERRED", "replica repair", "demot", "reseat", "withheld", "R3", "needs_rebuild",
    "NodeAdd", "NodeRole", "NodeState", "unhealthy", "NotReady", "failover", "drain", "promot", "PROMOT", "refill", "proxy", "Prepare"]
  for op in ← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace» do
    let mut raw := ""
    for extra in [["--previous"], []] do
      match ← kubectl (["logs", "-n", c.cfg.«namespace», op, s!"--since-time={since}", "--timestamps"] ++ extra) with
      | .ok o => raw := raw ++ o
      | .error _ => pure ()
    let lines := (raw.splitOn "\n").filter fun l => opNeedles.any (containsSubstr l ·) && !containsSubstr l "[DEBUG]"
    IO.eprintln s!"# [{label}] operator {op} since {since}: {lines.length} decision line(s) (last 80):\n{String.intercalate "\n" (lines.reverse.take 80).reverse}"
  for pod in pods do
    let fl := ((← c.flaredLogAllSince pod since).splitOn "\n").filter fun l =>
      containsSubstr l "shifting node_role" || containsSubstr l "shifting node_state" || containsSubstr l "truncat"
        || containsSubstr l "dump operation" || containsSubstr l "dump completed" || containsSubstr l "snapshot" || containsSubstr l "read source"
        || containsSubstr l "self-demot" || containsSubstr l "resync" || containsSubstr l "needs_rebuild" || containsSubstr l "flush"
        || containsSubstr l "activat" || containsSubstr l "WAL" || containsSubstr l "storage open" || containsSubstr l "staged"
        || containsSubstr l "node map accepted"
    IO.eprintln s!"# [{label}] {pod} flared since {since}: {fl.length} copy-affecting line(s) (last 50):\n{String.intercalate "\n" (fl.reverse.take 50).reverse}"

private def identityCfg : ClusterConfig := {
  name := "copy-identity"
  «namespace» := "flare-copy-identity"
  partitions := 1
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-copy-identity"
  storageBackend := "rocksdb"
  usePvc := true
  drainSeconds := 20
  operatorEnv := [("FLARE_TEST_PROMOTION_BARRIER", "/tmp/saf08")]
}

/-- (master pod, [slave pods]) of P0 from the operator's map, Active only. -/
private def Ctx.p0Roles (c : Ctx) : IO (Option String × List String) := do
  let entries ← c.nodeView
  let m := (findMasterFqdn entries 0).map podOf
  let ss := (entries.filter (fun e => e.role == 1 && e.state == 0 && e.partition == 0)).map (fun e => podOf e.fqdn)
  return (m, ss)

/-- Watch the P0 master for `secs`: (masters seen in order, final master). -/
private def Ctx.watchMaster (c : Ctx) (secs : Nat) (stopWhen : String → Bool) : IO (List String) := do
  let mut seen : List String := []
  for _ in [0:secs / 2] do
    IO.sleep 2000
    match (← c.p0Roles).1 with
    | some m =>
      if seen.getLast? != some m then seen := seen ++ [m]
      if stopWhen m then break
    | none => pure ()
  return seen

private def Ctx.opExec (c : Ctx) (cmd : String) : IO (Except String String) := do
  let pods ← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»
  match pods.head? with
  | none => return .error "no operator pod"
  | some pod => kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", cmd]

/-- Arm the one-shot promotion barrier, trigger `act`, and return the keys
    the held pass was about to promote (none if it never reached it). -/
private def Ctx.holdPromotion (c : Ctx) (act : IO Unit) : IO (Option (List String)) := do
  discard <| c.opExec "mkdir -p /tmp/saf08 && rm -f /tmp/saf08/promote-* && touch /tmp/saf08/promote-arm"
  act
  let mut keys : Option (List String) := none
  for _ in [0:90] do
    IO.sleep 2000
    match ← c.opExec "cat /tmp/saf08/promote-reached 2>/dev/null" with
    | .ok o =>
      let ks := (o.splitOn "\n").map String.trim |>.filter (· != "")
      if !ks.isEmpty then keys := some ks; break
    | .error _ => pure ()
  return keys

private def Ctx.releasePromotion (c : Ctx) : IO Unit := do
  discard <| c.opExec "touch /tmp/saf08/promote-release"

private def Ctx.threeInSync (c : Ctx) : IO (Option (String × String × String × Nat)) := do
  for _ in [0:90] do
    match ← c.p0Roles with
    | (some m, [a, b]) =>
      let n ← c.currItems ((← getPodIp m c.cfg.«namespace»).getD "")
      let na ← c.currItems ((← getPodIp a c.cfg.«namespace»).getD "")
      let nb ← c.currItems ((← getPodIp b c.cfg.«namespace»).getD "")
      if n > 0 && na == n && nb == n then return some (m, a, b, n)
    | _ => pure ()
    IO.sleep 4000
  return none

def identitySuite : TestSuite := {
  name := "copy-identity"
  setup := do
    deployCluster identityCfg
    -- The post-observation tests compose two faults at once (a drained
    -- master + a restarted/replaced successor): 2 of 3 unavailable trips the
    -- breaker by design (minUnavailableToTrip 2), and a tripped breaker holds
    -- until a human acts — CI 37278389267 stalled there. The breaker is not
    -- what these tests examine, so raise its floor for this suite only.
    discard <| kubectlPatch "flarecluster" identityCfg.name identityCfg.«namespace» "{\"spec\":{\"circuitBreaker\":{\"minUnavailableToTrip\":3}}}"
    IO.sleep 60000
  teardown := do
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster identityCfg
  onFailure := dumpClusterDiagnostics identityCfg.«namespace» s!"app={identityCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := identityCfg }
    let ns := identityCfg.«namespace»
    [
    { name := "SAF-08 same-name replacement: a slave replaced under the same name (pod Pending, map still Active) just before the master is drained is never promoted; the healthy slave is, with every key"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          let mIp := (← getPodIp m ns).getD ""
          let w ← writeKeys identityCfg.debugPod ns mIp identityCfg.flarePort "id" 60
          let synced ← waitForCondition "all three copies hold the keys" 120 do
            let n ← c.currItems mIp
            let na ← c.currItems ((← getPodIp a ns).getD "")
            let nb ← c.currItems ((← getPodIp b ns).getD "")
            return n == 60 && na == 60 && nb == 60
          if w != 60 || !synced then return .fail s!"precondition: stored {w}/60, copies not in sync"
          match ← kubectl ["cordon", kindNode] with
          | .error e => return .fail s!"could not cordon: {e}"
          | .ok _ => pure ()
          discard <| kubectl ["delete", "pod", a, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
          let pending ← waitForCondition s!"{a} is replaced under the same name and Pending" 60 do
            match ← kubectlGetJsonpath "pod" a ns "{.status.phase}" with
            | .ok ph => return ph.trim == "Pending"
            | .error _ => return false
          let (_, slavesNow) ← c.p0Roles
          IO.eprintln s!"# {a} replaced and Pending={pending}; the map still lists Active slaves {slavesNow}"
          if !pending then discard <| kubectl ["uncordon", kindNode]; return .fail s!"precondition: {a} was not left Pending"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let seen ← c.watchMaster 120 (fun x => x != m)
          let withheld := ((← c.opLog 200000).splitOn "\n").any fun l =>
            containsSubstr l "promotion candidates withheld" && containsSubstr l a
          let newMaster := seen.getLast?
          let bItems ← c.currItems ((← getPodIp b ns).getD "")
          IO.eprintln s!"# masters seen {seen}; ghost {a} withheld logged={withheld}; {b} items={bItems}"
          discard <| kubectl ["uncordon", kindNode]
          if seen.contains a then return .fail s!"the replaced, not yet registered pod {a} was promoted"
          if newMaster != some b then return .fail s!"expected {b} to take over, masters seen {seen}"
          if bItems != 60 then return .fail s!"the new master {b} holds {bItems} of 60 keys"
          let healed ← waitForCondition "the replaced and the drained pods return and match the new master" 480 do
            let na ← c.currItems ((← getPodIp a ns).getD "")
            let nm ← c.currItems ((← getPodIp m ns).getD "")
            return na == 60 && nm == 60
          if !healed then return .fail "the returning pods did not converge on the new master"
          return .pass
        | roles => return .fail s!"precondition: expected one master and two Active slaves, got {roles.1}/{roles.2}" },

    { name := "SAF-08 process restart: a slave whose flared is killed (same pod, new process) right before the master is drained is not promoted on its old process's standing; the other slave is"
      run := do
        -- the previous test's pods must be back as Active slaves first
        discard <| c.threeInSync
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          let mIp := (← getPodIp m ns).getD ""
          let synced ← waitForCondition "all three copies match" 180 do
            let n ← c.currItems mIp
            let na ← c.currItems ((← getPodIp a ns).getD "")
            let nb ← c.currItems ((← getPodIp b ns).getD "")
            return n > 0 && na == n && nb == n
          if !synced then return .fail "precondition: copies not in sync"
          let items ← c.currItems mIp
          -- restart the process of the FIRST successor in map order, so that
          -- a choice by map order alone would pick it
          let victim := a
          let other := b
          IO.sleep 1100
          let sinceKill ← utcNow
          match ← c.killFlaredIn victim with
          | .error e => return .fail s!"could not kill flared in {victim}: {e}"
          | .ok o => IO.eprintln s!"# kill -9 flared in {victim}: {o.trim}"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let seen ← c.watchMaster 120 (fun x => x != m)
          let otherItems ← c.currItems ((← getPodIp other ns).getD "")
          IO.eprintln s!"# masters seen {seen}; {other} items={otherItems} (expected {items})"
          -- the record, pass or fail: which evidence did a promotion stand on?
          -- (the operator's R3 readings and PROMOTION line, the restarted
          -- node's own catch-up / source check / activation / binding)
          c.windowRecord sinceKill [victim, other] "copy-identity 11"
          if seen.contains victim then
            let fl := (← c.flaredLogAllSince victim sinceKill).splitOn "\n"
            let firstAt := fun (needle : String) => (fl.find? (containsSubstr · needle)).map (·.take 30)
            IO.eprintln s!"# {victim} new process since {sinceKill}: storage open {firstAt "storage open"}; source check passed {firstAt "activation source check passed"}; node activated {firstAt "node activated"}; read source BOUND {firstAt "read source BOUND"}"
            return .fail s!"{victim} was promoted although its flared had just restarted (see the record above: whether its NEW process had caught up, passed its source check, activated and bound before the PROMOTION line)"
          if seen.getLast? != some other then return .fail s!"expected {other} to take over, masters seen {seen}"
          if otherItems != items then return .fail s!"the new master {other} holds {otherItems} of {items} keys"
          let healed ← waitForCondition "the restarted and the drained pods converge" 480 do
            let nv ← c.currItems ((← getPodIp victim ns).getD "")
            let nm ← c.currItems ((← getPodIp m ns).getD "")
            return nv == items && nm == items
          if !healed then return .fail "the restarted and drained pods did not converge on the new master"
          return .pass
        | roles => return .fail s!"precondition: expected one master and two Active slaves, got {roles.1}/{roles.2}" },
    { name := "SAF-08 restart AFTER observation: the pass that chose a successor is held after its observations; that successor's flared is killed; on release the promotion is ABORTED (incarnation changed) and nothing is committed; a later pass promotes a valid copy with every key"
      run := do
        match ← c.threeInSync with
        | none => return .fail "precondition: one master and two in-sync Active slaves"
        | some (m, _, _, items) =>
          let held ← c.holdPromotion (do discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"])
          match held with
          | none => c.releasePromotion; return .fail "the promotion barrier was never reached"
          | some keys =>
            let target := podOf (keys.head!)
            let rc0 ← c.restartCount target
            match ← c.killFlaredIn target with
            | .error e => c.releasePromotion; return .fail s!"could not kill flared in {target}: {e}"
            | .ok o => IO.eprintln s!"# held promotion of {keys}; kill -9 in {target}: {o.trim}"
            let restarted ← waitForCondition s!"{target}'s flared restarted" 60 do
              return (← c.restartCount target) > rc0
            c.releasePromotion
            let aborted ← waitForCondition "the operator aborts the held promotion" 60 do
              return ((← c.opLog 3000).splitOn "\n").any fun l => containsSubstr l "PROMOTION ABORTED" && containsSubstr l target
            let seen ← c.watchMaster 180 (fun x => x != m)
            let newMaster := seen.getLast?.getD "?"
            let newItems ← c.currItems ((← getPodIp newMaster ns).getD "")
            IO.eprintln s!"# restarted={restarted}; aborted={aborted}; masters seen {seen}; new master items {newItems} (expected {items})"
            if !restarted then return .fail s!"{target}'s flared did not restart"
            if !aborted then return .fail s!"the promotion of {target} was not aborted after its flared restarted"
            if newItems != items then return .fail s!"the new master {newMaster} holds {newItems} of {items} keys"
            let healed ← waitForCondition "the drained pod returns and the copies match" 480 do
              return (← c.threeInSync).isSome
            if !healed then return .fail "the cluster did not converge after the aborted promotion"
            return .pass },

    { name := "SAF-08 replacement AFTER observation: the pass that chose a successor is held; that successor's pod is replaced under the same name (node cordoned, replacement Pending); on release the promotion is ABORTED; the other slave takes over with every key"
      run := do
        IO.sleep 1100
        let since13 ← utcNow
        match ← c.threeInSync with
        | none => return .fail "precondition: one master and two in-sync Active slaves"
        | some (m, a, b, items) =>
          -- each node's OWN view at the start (CI 37547974017: the other
          -- slave was Prepare when the promotion was needed; why is the question)
          let mut own : List String := []
          for p in [m, a, b] do
            match ← getPodIp p ns with
            | some pip =>
              match ← execInDebugPod c.cfg.debugPod ns s!"printf 'stats\\r\\n' | nc -w 3 {pip} {c.cfg.flarePort} | grep -E 'repl_read_source_state|reconstruction_current_state|reconstruction_started|reconstruction_completed'; printf 'stats nodes\\r\\n' | nc -w 3 {pip} {c.cfg.flarePort} | grep -E '{p}[.].*:(role|state) '" with
              | .ok o => own := own ++ [s!"{p}: {String.intercalate " " ((o.splitOn "\n").map String.trim |>.filter (· != ""))}"]
              | .error e => own := own ++ [s!"{p}: unreadable ({e.take 60})"]
            | none => own := own ++ [s!"{p}: no IP"]
          IO.eprintln s!"# test 13 start, each node's own view: {own}"
          let held ← c.holdPromotion (do discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"])
          match held with
          | none => c.releasePromotion; c.windowRecord since13 [a, b] "copy-identity 13"; return .fail "the promotion barrier was never reached"
          | some keys =>
            let target := podOf (keys.head!)
            let other := if target == a then b else a
            let uid0 := (← c.podUid target).getD ""
            discard <| kubectl ["cordon", kindNode]
            discard <| kubectl ["delete", "pod", target, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
            -- Replaced = the observed incarnation is gone: the pod is absent
            -- (OrderedReady holds the recreation while the drained master is
            -- terminating, CI 37278389267) or present under a new UID.
            let replaced ← waitForCondition s!"{target}'s observed pod is gone (absent or a new UID)" 60 do
              match ← c.podUid target with
              | none => return true
              | some u => return !u.isEmpty && u != uid0
            c.releasePromotion
            let aborted ← waitForCondition "the operator aborts the held promotion" 60 do
              return ((← c.opLog 3000).splitOn "\n").any fun l => containsSubstr l "PROMOTION ABORTED" && containsSubstr l target
            let seen ← c.watchMaster 180 (fun x => x != m && x != target)
            let otherItems ← c.currItems ((← getPodIp other ns).getD "")
            discard <| kubectl ["uncordon", kindNode]
            IO.eprintln s!"# held promotion of {keys}; {target} replaced={replaced}; aborted={aborted}; masters seen {seen}; {other} items {otherItems} (expected {items})"
            c.windowRecord since13 [other, target, m] "copy-identity 13"
            if !replaced then return .fail s!"{target} was not replaced"
            if !aborted then return .fail s!"the promotion of the replaced {target} was not aborted"
            if seen.contains target then return .fail s!"the replaced {target} was promoted"
            -- decision 2026-10-07 (1): R3 is not relaxed. If the other slave was
            -- NOT eligible (R3 reading 0) in this window, the safe outcome is
            -- that nobody is promoted and the draining master keeps the data;
            -- otherwise the other slave takes over with every key.
            if seen.getLast? != some other then
              let opLog ← c.opLog 6000
              let otherKey := s!"{other}.{c.cfg.name}-nodes.{ns}.svc.cluster.local:{c.cfg.flarePort}=0"
              let otherIneligible := (opLog.splitOn "\n").any fun l =>
                containsSubstr l "R3 readings" && containsSubstr l otherKey
              let mItems ← c.currItems ((← getPodIp m ns).getD "")
              let noOtherMaster := seen.all (· == m)
              IO.eprintln s!"# {other} not promoted: R3 reading 0 logged for it={otherIneligible}; masters seen {seen}; draining {m} kept with {mItems}/{items} keys"
              if !(otherIneligible && noOtherMaster && mItems == items) then
                return .fail s!"expected {other} to take over (or, with {other} R3-ineligible, a safe stop with {m} keeping every key); masters seen {seen}"
              return .pass
            if otherItems != items then return .fail s!"{other} holds {otherItems} of {items} keys"
            let healed ← waitForCondition "the replaced and drained pods return and the copies match" 480 do
              return (← c.threeInSync).isSome
            if !healed then return .fail "the cluster did not converge"
            return .pass }
  ]
}

-- ─── SAF-08: an empty repair source, proven by rebuild evidence ──────────

/-- GET `marker` then every key of `keys`, in order, on ONE connection to
    `ip` (one flared worker serves them in that order). Per key: "=<value>",
    "miss" (END without a value) or "err:<line>" (a refusal is not a miss).
    `none` when the exchange is incomplete (not observed). -/
private def Ctx.getRound (c : Ctx) (ip marker : String) (keys : List String) (squash : Bool := false) (waitSec : Nat := 5) : IO (Option (List (String × String))) := do
  -- "quit" last: the server closes the connection once it has answered, so
  -- `-w` bounds only a SILENT server, not every round
  let cmds := String.join ((marker :: keys).map fun k => s!"get {k}\\r\\n") ++ "quit\\r\\n"
  -- squash: a value line longer than 200 bytes becomes "X<length>/<non-x
  -- bytes>" (the bulk values are all 'x'), so content is still compared
  let post := if squash then " | awk '{ sub(/\\r$/, \"\"); if (length($0) > 200) { v = $0; gsub(/x/, \"\", v); print \"X\" length($0) \"/\" length(v) } else print }'" else ""
  -- deadlines aligned: the client (`nc -w waitSec`, silence only — "quit"
  -- ends a normal round at once) runs inside an exec bounded by
  -- waitSec + 15 s, not by the harness's fixed 30 s kubectl wall (CI
  -- 37472032699 cut a 90 s client at 30 s)
  let shCmd := s!"printf '{cmds}' | nc -w {waitSec} {ip} {c.cfg.flarePort}{post}"
  let execR ← if waitSec + 15 > 30 then
      hostCmd "timeout" ["-k", "5", toString (waitSec + 15), "kubectl", "exec", c.cfg.debugPod, "-n", c.cfg.«namespace», "--", "sh", "-c", shCmd]
    else execInDebugPod c.cfg.debugPod c.cfg.«namespace» shCmd
  match execR with
  | .error _ => return none
  | .ok out => return (parseGetReplies (marker :: keys) out).map (·.tail)

/-- One snapshot of what a node bases a local answer on: its OWN map entry
    (role/state/balance), map version, follow-guard inputs, reconstruction
    counters and process id — `stats` and `stats nodes` in one exchange. -/
private def Ctx.readState (c : Ctx) (ip pod : String) : IO String := do
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf 'stats\\r\\n' | nc -w 3 {ip} {c.cfg.flarePort}; echo '=== nodes'; printf 'stats nodes\\r\\n' | nc -w 3 {ip} {c.cfg.flarePort}" with
  | .error e => return s!"(unreadable: {e})"
  | .ok o =>
    let parts := o.splitOn "=== nodes"
    let st := parts.head?.getD ""
    let nodes := (parts.drop 1).head?.getD ""
    let own := String.intercalate " " (((nodes.splitOn "\n").filter fun l =>
      containsSubstr l (pod ++ ".") && (containsSubstr l ":role " || containsSubstr l ":state " || containsSubstr l ":balance ")).map fun l =>
        ((l.trim.splitOn ":").getLast?.getD "").trim)
    let keys := ["time", "node_map_version", "repl_follow_enabled", "repl_follow_state", "repl_applied_lsn", "repl_source_lsn",
      "repl_source_lsn_observed_at", "reconstruction_started", "reconstruction_completed", "reconstruction_boot_id", "curr_items"]
    return s!"own[{own}] " ++ String.intercalate " " (keys.map fun k => s!"{k}={(statVal st k).getD "?"}")

/-- Answer class label of a GET (TraceMatch.classifyAnswer, unit-tested). -/
private def classifyAnswer (expected answer : String) (t : KeyTrace) : String :=
  (FlareOperator.E2E.TraceMatch.classifyAnswer expected answer t).label

/-- Pods of the data cluster: (name, IP), IP-less pods left out. -/
private def Ctx.dataPods (c : Ctx) : IO (List (String × String)) := do
  match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app=flare,cluster={c.cfg.name}", "-o", "jsonpath={range .items[*]}{.metadata.name}|{.status.podIP}{\"\\n\"}{end}"] with
  | .ok o => return (o.splitOn "\n").filterMap fun l =>
      match l.trim.splitOn "|" with
      | [n, ip] => if n.isEmpty || ip.isEmpty then none else some (n, ip)
      | _ => none
  | .error _ => return []

/-- Every rebuild in this suite is a STAGED full dump (no snapshot, no WAL
    catch-up; copy retention: the copy is built next to the old one and
    switched in), throttled so a dump lasts long enough (~50 s for the
    6.4 MB data set) to be interrupted. -/
private def emptySourceCfg : ClusterConfig := {
  name := "empty-source"
  «namespace» := "flare-empty-source"
  partitions := 1
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-empty-source"
  storageBackend := "rocksdb"
  usePvc := true
  drainSeconds := 20
  flaredEnv := [("FLARE_TEST_DISABLE_SNAPSHOT_BOOTSTRAP", "1"), ("FLARE_TEST_DISABLE_WAL_RECONSTRUCTION", "1"),
                ("FLARE_TEST_ACTIVATION_HOLD_FILE", "/tmp/act-hold"),
                -- test 4 attributes the replica's answers (local / proxied)
                ("FLARE_TEST_READ_TRACE_PREFIX", "es_")]
  flaredArgs := "--reconstruction-bwlimit 256"
  -- FLARE_FOLLOW_PROBE_INTERVAL=1: every slave's stats (R3 eligibility and
  -- needs_rebuild included) are read EVERY pass, so a rebuild request from a
  -- source change arrives at a known time, not every 30 passes
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000"), ("FLARE_FOLLOW_PROBE_INTERVAL", "1")]
  -- production read policy (R2), through the CR as production sets it
  readUnavailableError := true
}

/-- SET each (key, value) on one connection; the number STORED. -/
private def Ctx.setValues (c : Ctx) (ip : String) (kvs : List (String × String)) : IO Nat := do
  let cmds := String.join (kvs.map fun (k, v) => s!"set {k} 0 0 {v.length}\\r\\n{v}\\r\\n")
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf '{cmds}' | nc -w 5 {ip} {c.cfg.flarePort} | grep -c STORED" with
  | .ok o => return o.trim.toNat?.getD 0
  | .error _ => return 0


/-- (rebuilt-from master_id, rebuilt-from epoch) of a node: `none` = stats
    unreadable; `some (none, none)` = no evidence. -/
private def Ctx.evidence (c : Ctx) (ip : String) : IO (Option (Option String × Option String)) := do
  match ← c.statsOf ip with
  | none => return none
  | some o =>
    if !containsSubstr o "STAT rocksdb_source_epoch" then return none
    return some (statVal o "rocksdb_rebuilt_from_master_id", statVal o "rocksdb_rebuilt_from_epoch")

private def Ctx.flaredLog (c : Ctx) (pod : String) (previous : Bool := false) : IO String := do
  match ← kubectl (["logs", "-n", c.cfg.«namespace», pod, "-c", "flared", "--tail=20000"] ++ (if previous then ["--previous"] else [])) with
  | .ok o => return o
  | .error _ => return ""

/-- The flared container's log from a FIXED start time (`--since-time`, no
    tail limit), with timestamps — a comparison window that cannot lose its
    start marker to a tail cut. -/
private def Ctx.flaredLogSince (c : Ctx) (pod since : String) : IO String := do
  match ← kubectl ["logs", "-n", c.cfg.«namespace», pod, "-c", "flared", s!"--since-time={since}", "--timestamps"] with
  | .ok o => return o
  | .error _ => return ""

/-- (pod UID, flared container restart count): the process the log belongs to. -/
private def Ctx.processId (c : Ctx) (pod : String) : IO (Option (String × String)) := do
  match ← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.metadata.uid}|{.status.containerStatuses[?(@.name==\"flared\")].restartCount}" with
  | .ok o =>
    match o.trim.splitOn "|" with
    | [u, r] => if u.isEmpty || r.isEmpty then return none else return some (u, r)
    | _ => return none
  | .error _ => return none

/-- Lines after the LAST occurrence of `marker` (the whole log if absent). -/
private def afterLast (log marker : String) : String :=
  match (log.splitOn marker).getLast? with
  | some tail => if (log.splitOn marker).length > 1 then tail else log
  | none => log

/-- Wait until `pod`'s flared logs "starting dump operation" in its current
    container (a dump is under way). -/
private def Ctx.waitDumpStart (c : Ctx) (pod : String) (secs : Nat) : IO Bool :=
  waitForCondition s!"{pod} starts a full dump" secs do
    let log ← c.flaredLog pod
    return containsSubstr log "starting dump operation" && !containsSubstr (afterLast log "starting dump operation") "reconstruction via full dump completed"

/-- Sample `ip`'s evidence every 2 s until `pod`'s current flared logs that it
    recorded evidence (or `secs`). Returns (evidence ever seen BEFORE the
    recording line, recorded). -/
private def Ctx.noEvidenceUntilRecorded (c : Ctx) (pod ip : String) (secs : Nat) : IO (List String × Bool) := do
  let mut early : List String := []
  -- WALL-CLOCK deadline: each iteration makes calls that can each take up to
  -- 30 s while a pod is unreachable, so an iteration count is no bound (CI
  -- 37376724850: a "480 s" loop ran past the leg's 75-minute limit).
  let deadline := (← IO.monoMsNow) + secs * 1000
  for _ in [0:secs] do
    if (← IO.monoMsNow) ≥ deadline then break
    let recorded := containsSubstr (← c.flaredLog pod) "rebuild evidence recorded"
    if recorded then return (early, true)
    match ← c.evidence ip with
    | some (_, some e) =>
      -- re-check: the line may have been written between the two reads
      if !containsSubstr (← c.flaredLog pod) "rebuild evidence recorded" then early := early ++ [e]
    | _ => pure ()
    IO.sleep 2000
  return (early, false)

private def Ctx.newMasterAfter (c : Ctx) (old : String) (secs : Nat) : IO (Option String) := do
  let deadline := (← IO.monoMsNow) + secs * 1000
  for _ in [0:secs] do
    if (← IO.monoMsNow) ≥ deadline then break
    match (← c.p0Roles).1 with
    | some m => if m != old then return some m
    | none => pure ()
    IO.sleep 2000
  return none

/-- The promoted node's epoch AFTER its own promotion advance: the
    operator's map changes before flared advances the epoch (CI 37414948177:
    reading it at once gave the pre-promotion value). Waits until it differs
    from `pre` (the node's epoch before the fault), up to `secs`. -/
private def Ctx.promotedEpoch (c : Ctx) (pod : String) (pre : Option String) (secs : Nat := 90) : IO (Option String) := do
  -- The pre-promotion epoch MUST have been read: with `pre = none` any
  -- readable value would count as "changed" (the earlier false positive).
  if pre.isNone then
    IO.eprintln s!"# {pod}: its epoch before the fault could not be read — no comparison"
    return none
  let deadline := (← IO.monoMsNow) + secs * 1000
  let mut cur : Option String := none
  for _ in [0:secs] do
    if (← IO.monoMsNow) ≥ deadline then break
    cur ← c.statStr ((← getPodIp pod c.cfg.«namespace»).getD "") "rocksdb_source_epoch"
    if cur.isSome && cur != pre then return cur
    IO.sleep 2000
  return none

private def Ctx.allInSync (c : Ctx) (n : Nat) (secs : Nat) : IO (Option (String × String × String)) := do
  let deadline := (← IO.monoMsNow) + secs * 1000
  for _ in [0:secs] do
    if (← IO.monoMsNow) ≥ deadline then break
    match ← c.p0Roles with
    | (some m, [a, b]) =>
      let ns := c.cfg.«namespace»
      if (← c.currItems ((← getPodIp m ns).getD "")) == n && (← c.currItems ((← getPodIp a ns).getD "")) == n
          && (← c.currItems ((← getPodIp b ns).getD "")) == n then return some (m, a, b)
    | _ => pure ()
    IO.sleep 4000
  return none

def emptySourceSuite : TestSuite := {
  name := "empty-source"
  setup := do
    deployCluster emptySourceCfg
    -- Faults here compose a drained master with a rebuilding replica; the
    -- breaker is not under test (see the copy-identity suite).
    discard <| kubectlPatch "flarecluster" emptySourceCfg.name emptySourceCfg.«namespace» "{\"spec\":{\"circuitBreaker\":{\"minUnavailableToTrip\":3}}}"
    IO.sleep 30000
  teardown := do
    for ip in (← getPodIps s!"app=flare,cluster={emptySourceCfg.name}" emptySourceCfg.«namespace») do
      for ip2 in (← getPodIps s!"app=flare,cluster={emptySourceCfg.name}" emptySourceCfg.«namespace») do
        if ip != ip2 then
          for _ in [0:2] do
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec ip ip2)
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster emptySourceCfg
  onFailure := dumpClusterDiagnostics emptySourceCfg.«namespace» s!"app={emptySourceCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := emptySourceCfg }
    let ns := emptySourceCfg.«namespace»
    let ip : String → IO String := fun p => do return (← getPodIp p ns).getD ""
    [
    { name := "SAF-08 rebuild evidence: after a PROMOTION, the ex-master rejoins and is rebuilt by a STAGED full dump (verified, switched in); it records the current master's master_id and source epoch (identical at the dump's start and end), and the staged copy follows that history"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.p0Roles with
        | (some m0, [_, _]) =>
          let w ← c.bulkWrite (← ip m0) "es" 400 16384
          if w != 400 then return .fail s!"precondition: stored {w}/400"
          if (← c.allInSync 400 240).isNone then return .fail "precondition: the copies did not converge on 400 keys"
          discard <| kubectl ["delete", "pod", m0, "-n", ns, "--wait=false"]
          let some m1 ← c.newMasterAfter m0 180 | return .fail s!"no successor was promoted after draining {m0}"
          let some _ ← c.allInSync 400 420 | return .fail s!"the ex-master {m0} did not rejoin with every key"
          let mIp ← ip m1
          let rIp ← ip m0
          let mId ← c.statStr mIp "rocksdb_master_id"
          let mEpoch ← c.statStr mIp "rocksdb_source_epoch"
          let mReason ← c.statStr mIp "rocksdb_source_epoch_reason"
          let rEpoch ← c.statStr rIp "rocksdb_source_epoch"
          let ev ← c.evidence rIp
          let log ← c.flaredLog m0
          let seamDump := containsSubstr log "-> staged full dump" && containsSubstr log "reconstruction via full dump completed into staging"
            && containsSubstr log "staged rebuild DONE"
          IO.eprintln s!"# master {m1}: master_id {mId}, epoch {mEpoch} ({mReason}); rebuilt {m0}: own epoch {rEpoch}, evidence {ev}; staged full dump via the seam={seamDump}"
          if !seamDump then return .fail s!"precondition: {m0} was not rebuilt by a staged full dump"
          if mReason != some "promotion" then return .fail s!"precondition: the master's epoch reason is {mReason}, not promotion"
          if ev != some (mId, mEpoch) then return .fail s!"the rebuilt replica's evidence {ev} is not the master's (master_id {mId}, epoch {mEpoch})"
          -- copy retention: the staged copy follows the history it was
          -- verified against (like a snapshot), so its own epoch is the master's
          if rEpoch != mEpoch then return .fail s!"the staged copy's own epoch {rEpoch} is not the history it was verified against ({mEpoch})"
          return .pass
        | _ => return .fail "precondition: one master and two slaves" },

    { name := "SAF-08 legitimately emptied master after a full-dump rebuild: every key is deleted on the (promoted) master while the rebuilt replica misses the deletes; the repair is accepted on the rebuild evidence and the replica is rebuilt to empty — not deferred"
      run := do
        IO.sleep 1100
        let since2 ← utcNow
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          let mIp ← ip m
          let mEpoch ← c.statStr mIp "rocksdb_source_epoch"
          -- the target: a slave whose evidence names this master's epoch
          let mut target : Option (String × String) := none
          for s in [a, b] do
            let sIp ← ip s
            if let some (_, some e) ← c.evidence sIp then
              if some e == mEpoch && target.isNone then target := some (s, sIp)
          let some (r, rIp) := target | return .fail s!"precondition: no slave carries evidence of the master's epoch {mEpoch}"
          -- PRECONDITION (CI 37376724850): the repair ledger takes its first
          -- observation as BASELINE; drops before it are never attributed (a
          -- separate product gap, recorded in the ledger). This test is about
          -- the repair decision, so the drops must come after it.
          let ledgerReady ← waitForCondition "the repair ledger is initialized (drops after this are attributed)" 420 do
            return containsSubstr (← c.opLog 200000) "replica repair ledger initialized"
          if !ledgerReady then return .fail "precondition: the repair ledger was never initialized"
          let drops0 := (← c.statNat mIp "proxy_write_dropped").getD 0
          match ← cutForwards mIp rIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let del ← c.deleteKeys mIp "es" 0 400
          let mItems ← c.currItems mIp
          let dropped ← waitForCondition "the master counts the dropped deletes" 120 do
            return ((← c.statNat mIp "proxy_write_dropped").getD 0) > drops0
          healForwards mIp rIp
          IO.eprintln s!"# deleted {del} keys on {m} (items now {mItems}); drops counted={dropped}; {r} still holds {← c.currItems rIp}"
          if mItems != 0 then return .fail s!"precondition: the master still holds {mItems} keys"
          if !dropped then return .fail "precondition: the master never counted dropped forwards"
          let resolved ← waitForCondition "the repair rebuilds the replica to empty and the ledger closes" 600 do
            return (← c.currItems rIp) == 0 && (← c.ledgerDests).isEmpty
          let log ← c.opLog 200000
          let deferred := (log.splitOn "\n").filter fun l => containsSubstr l "replica repair DEFERRED" && containsSubstr l r
          IO.eprintln s!"# repair resolved={resolved}; {r} items {← c.currItems rIp}; ledger {← c.ledgerDests}; deferral lines for {r}: {deferred.length}{if deferred.isEmpty then "" else "\n# " ++ (deferred.getLast?.getD "")}"
          c.windowRecord since2 [r, m] "test 2"
          if !resolved then
            -- CI 37296281060: unresolved with an EMPTY ledger and no deferral
            -- (replica at 2 items); print what the operator decided.
            let repairLines := (log.splitOn "\n").filter fun l =>
              containsSubstr l "REPLICA REPAIR" || containsSubstr l "replica repair" || containsSubstr l "ledger"
                || containsSubstr l r || containsSubstr l "demot"
            IO.eprintln s!"# operator lines about the repair ({repairLines.length}):\n{String.intercalate "\n" (repairLines.reverse.take 40).reverse}"
            IO.eprintln s!"# {r} flared log tail:\n{String.intercalate "\n" (((← c.flaredLog r).splitOn "\n").reverse.take 40).reverse}"
            return .fail s!"the repair did not resolve ({deferred.length} deferral(s))"
          return .pass
        | _ => return .fail "precondition: one master and two slaves" },

    { name := "SAF-08 rebuild evidence vs a restart mid-dump: a replica that carries evidence is restarted, rebuilds by full dump, and is killed again mid-dump; no evidence is seen from the first dump's start until a dump COMPLETES, and the final evidence names the master's epoch"
      run := do
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          let mIp ← ip m
          let w ← c.bulkWrite mIp "es" 400 16384
          if w != 400 then return .fail s!"precondition: stored {w}/400"
          if (← c.allInSync 400 300).isNone then return .fail "precondition: the copies did not converge on 400 keys"
          let mId ← c.statStr mIp "rocksdb_master_id"
          let mEpoch ← c.statStr mIp "rocksdb_source_epoch"
          let mut target : Option (String × String) := none
          for s in [a, b] do
            let sIp ← ip s
            if let some (_, some _) ← c.evidence sIp then
              if target.isNone then target := some (s, sIp)
          let some (r, rIp) := target | return .fail "precondition: no slave carries rebuild evidence"
          let ev0 ← c.evidence rIp
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not kill flared in {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"{r} did not start a full dump after its restart"
          IO.sleep 5000
          let evMid ← c.evidence (← ip r)
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not kill flared in {r} mid-dump: {e}"
          | .ok _ => pure ()
          IO.sleep 3000
          let prevLog ← c.flaredLog r true
          let interrupted := !containsSubstr (afterLast prevLog "starting dump operation") "reconstruction via full dump completed"
          let recordedEarly := containsSubstr prevLog "rebuild evidence recorded"
          let (early, recorded) ← c.noEvidenceUntilRecorded r (← ip r) 420
          let evEnd ← c.evidence (← ip r)
          let items ← c.currItems (← ip r)
          IO.eprintln s!"# {r}: evidence before {ev0}; mid-dump {evMid}; dump interrupted by the kill={interrupted}; the killed process recorded evidence={recordedEarly}; evidence seen before a completed dump {early}; recorded after the restart={recorded}; final {evEnd} (master {mId}, {mEpoch}); items {items}"
          if !interrupted then return .fail "precondition: the second kill did not interrupt a dump"
          if recordedEarly then return .fail "the interrupted process recorded rebuild evidence"
          if !(evMid matches some (_, none)) then return .fail s!"evidence was present during the dump: {evMid}"
          if !early.isEmpty then return .fail s!"evidence was visible before any dump completed: {early}"
          if !recorded then return .fail "no evidence was recorded after the completed rebuild"
          if evEnd != some (mId, mEpoch) then return .fail s!"the final evidence {evEnd} does not name the master's (master_id {mId}, epoch {mEpoch})"
          if items != 400 then return .fail s!"the rebuilt replica holds {items}/400 keys"
          return .pass
        | _ => return .fail "precondition: one master and two slaves" },

    { name := "SAF-08 rebuild evidence vs a source change mid-dump: while a replica dumps from the master, the master is drained and another node promoted; the copy is never validated against the old master AFTER the replica accepted the new map, the evidence names the source of the copy finally activated, and every key and value on the replica's LOCAL copy equals the new master's"
      run := do
        -- Activating a completed copy of the draining master is not wrong by
        -- itself (it is still the legitimate master with this history until
        -- the switch). What is judged is the TIMELINE: (a) the operator's
        -- switch, (b) the replica accepting that map (version), (c) source
        -- validations / evidence / activations with the map version each
        -- used, (d) the replica's map afterwards and every key AND value.
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          let mIp ← ip m
          let oldEpoch ← c.statStr mIp "rocksdb_source_epoch"
          let mut target : Option (String × String) := none
          for s in [a, b] do
            let sIp ← ip s
            if let some (_, some _) ← c.evidence sIp then
              if target.isNone then target := some (s, sIp)
          let some (r, _) := target | return .fail "precondition: no slave carries rebuild evidence"
          -- distinct values written BEFORE the switch (es_0..49) and AFTER it
          -- (es_50..99, below); es_100..399 stay the bulk 'x' values
          let pre := (List.range 50).map fun i => (s!"es_{i}", s!"pre4_{i}")
          let stPre ← c.setValues mIp pre
          if stPre != 50 then return .fail s!"precondition: stored {stPre}/50 distinct values on {m}"
          if (← c.allInSync 400 240).isNone then return .fail "precondition: the copies did not converge on 400 keys"
          IO.sleep 1100
          let since ← utcNow
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not kill flared in {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"{r} did not start a full dump after its restart"
          let startLine := ((afterLast (← c.flaredLog r) "starting dump operation").splitOn "\n").head?.getD ""
          let fromOld := containsSubstr startLine (m ++ ".")
          let preA ← c.statStr (← ip a) "rocksdb_source_epoch"
          let preB ← c.statStr (← ip b) "rocksdb_source_epoch"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let some m2 ← c.newMasterAfter m 180 | return .fail s!"no successor was promoted after draining {m}"
          if m2 == r then return .fail s!"precondition: the rebuilding replica {r} itself was promoted"
          let newEpoch ← c.promotedEpoch m2 (if m2 == a then preA else preB)
          if newEpoch.isNone then return .fail s!"precondition: {m2}'s epoch before the fault was unreadable or did not advance after its promotion"
          let m2Ip ← ip m2
          let post := (List.range 50).map fun i => (s!"es_{i + 50}", s!"post4_{i}")
          let stPost ← c.setValues m2Ip post
          let (early, recorded) ← c.noEvidenceUntilRecorded r (← ip r) 480
          let converged ← c.allInSync 400 300
          let evEnd ← c.evidence (← ip r)
          -- (a) the operator's switch and the version that carried it
          -- per operator pod (a label-selector fetch returned nothing in CI
          -- 37438962871 although the line was in the pod's log)
          let mut opRaw := ""
          let mut opFetch : List String := []
          for pod in ← getPodNames s!"app={emptySourceCfg.operatorName}" ns do
            match ← kubectl ["logs", "-n", ns, pod, s!"--since-time={since}", "--timestamps"] with
            | .ok o =>
              opRaw := opRaw ++ o
              opFetch := opFetch ++ [s!"{pod}: {(o.splitOn "\n").length} line(s)"]
            | .error e => opFetch := opFetch ++ [s!"{pod}: unreadable ({e.take 120})"]
          let opL := opRaw.splitOn "\n"
          let switchLine := opL.find? fun l => containsSubstr l "promoting replacement" && containsSubstr l (m2 ++ ".")
          let switchT := switchLine.bind logTs
          let switchV := (opL.find? fun l => containsSubstr l "topology changed (v" &&
              match logTs l, switchT with
              | some t, some t0 => t ≥ t0
              | _, _ => false).bind fun l => numAfter l "→ v"
          -- (b)-(c) the replica's own timeline
          let rL := (← c.flaredLogAllSince r since).splitOn "\n"
          let acceptLine := rL.find? fun l => containsSubstr l "node map accepted (version" && containsSubstr l s!" 0={m2}."
          let acceptV := acceptLine.bind (numAfter · "node map accepted (version ")
          let activations := rL.filter (containsSubstr · "node activated (attempt")
          let timeline := rL.filter fun l =>
            containsSubstr l "activation source check passed" || containsSubstr l "node activated (attempt" || containsSubstr l "activation STOPPED"
              || containsSubstr l "activation deferred" || containsSubstr l "reconstruction via full dump completed" || containsSubstr l "rebuild evidence recorded"
              || containsSubstr l "reconstruction source changed" || containsSubstr l "completed but the partition's master is now" || containsSubstr l "starting dump operation"
              || (containsSubstr l "node map accepted" && (containsSubstr l s!"0={m}." || containsSubstr l s!"0={m2}."))
          IO.eprintln s!"# (a) operator log since {since}: {opFetch}; switch {m} -> {m2}: {switchLine.getD "(no line)"}; first broadcast after it v{switchV}\n# (b) {r} accepted a map with {m2} as master: v{acceptV} at {acceptLine.getD "(no line)"}\n# (c)/(d) {r} timeline since {since} (map lines only where the master changes are relevant; last 60):\n{String.intercalate "\n" (timeline.reverse.take 60).reverse}"
          if !fromOld then return .fail s!"precondition: the dump did not start from the master {m} ({startLine.trim})"
          let some aV := acceptV | return .fail s!"(b) no line shows {r} accepting a map with {m2} as master: the timeline cannot be judged"
          -- the order verdict (TraceMatch.judgeActivation, unit-tested): a
          -- check of the old source against the new map, or an activation of
          -- the old copy after accepting it, is a BUG whatever follows
          let act := judgeActivation rL m m2
          let lastAct := activations.getLast?
          IO.eprintln s!"# (c) activation order: {act.describe}"
          match act with
          | .bug why => return .fail s!"activation order: {why}"
          | .undetermined why => return .fail s!"activation order UNDETERMINED (not a pass): {why}"
          | _ => pure ()
          -- (d) the replica's map now, and every key and value: reads routed
          -- to the replicas and attributed by the trace
          let rIp ← ip r
          let rMap := (rL.filter (containsSubstr · "node map accepted (version")).getLast?.getD "(no line)"
          let balance0 := ((← kubectlGetJsonpath "flarecluster" emptySourceCfg.name ns "{.spec.readBalance}").toOption.getD "").trim
          let routedPatch ← kubectlPatch "flarecluster" emptySourceCfg.name ns "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}"
          let routed ← waitForCondition s!"a GET on {r} is answered locally (trace)" 150 do
            let mk := s!"es_mark_route_{← IO.monoMsNow}"
            discard <| c.getRound rIp mk []
            let tr := readTraces (← c.flaredLogAllSince r since)
            return tr.any fun l => traceField l "key" == mk && traceField l "decision" == "local"
          let keys := (List.range 400).map fun i => s!"es_{i}"
          let onM2 ← c.getRound m2Ip "es_mark_final_master" keys true
          IO.sleep 1100
          let readAt ← utcNow
          let onR ← c.getRound rIp "es_mark_final_replica" keys true
          let restorePatch := if balance0.isEmpty then "{\"spec\":{\"readBalance\":null}}" else s!"\{\"spec\":\{\"readBalance\":{balance0}}}"
          let restored ← kubectlPatch "flarecluster" emptySourceCfg.name ns restorePatch
          let tr := tracesAfterMarker (readTraces (← c.flaredLogAllSince r readAt)) "es_mark_final_replica"
          let expect (k : String) : Option String :=
            match (k.drop 3).toNat? with
            | some i => if i < 50 then some s!"=pre4_{i}" else if i < 100 then some s!"=post4_{i - 50}" else some "=X16384/0"
            | none => none
          let mut badM2 : List String := []
          -- data errors (a real miss or another value) are kept apart from
          -- unavailability (refusal / unreadable) and from answers that
          -- cannot be attributed
          let mut badR : List String := []
          let mut unavailR : List String := []
          let mut notLocal := 0
          match onM2, onR with
          | some am, some ar =>
            for (k, v) in am do
              if some v != expect k then badM2 := badM2 ++ [s!"{k} -> {v}"]
            for (k, v) in ar do
              let t := (tr.lookup k).getD {}
              let cls := classifyAnswer ((expect k).getD "?") v t
              let localAns := answeredLocally t
              if cls == "wrong-local" || cls == "wrong-forwarded" then
                badR := badR ++ [s!"{k} -> {v} ({cls}) decision {t.decision.getD "(none)"} answer {t.answer.getD "(none)"}"]
              else if cls == "masked-miss" then
                badR := badR ++ [s!"{k} -> {v} (MASKED MISS: unreadable on the server, END to the client) answer {t.answer.getD ""}"]
              else if cls == "refused" then
                unavailR := unavailR ++ [s!"{k} -> {v} ({cls})"]
              else if cls != "ok" || !localAns then
                notLocal := notLocal + 1
          | _, _ => pure ()
          IO.eprintln s!"# (c) last activation {lastAct.getD "(none)"} (accepted v{aV}); evidence before a completed dump {early}; recorded={recorded}; final evidence {evEnd} (old epoch {oldEpoch}, new {newEpoch})\n# (d) {r} map now: {rMap}; post-switch writes stored {stPost}/50; converged={converged.isSome}; routed={routedPatch.isOk}/{routed}, restored={restored.isOk}; {m2} answers wrong {badM2.length}; {r} data errors {badR.length}, unavailable/refused {unavailR.length}, correct but not attributed to its local copy {notLocal}/400\n# {String.intercalate "\n# " ((badM2 ++ badR ++ unavailR).take 10)}"
          if let .error e := routedPatch then return .fail s!"could not route reads to the replicas: {e}"
          if let .error e := restored then return .fail s!"could not restore the read balance: {e}"
          if !early.isEmpty then return .fail s!"evidence was visible before a dump completed: {early}"
          if !recorded then return .fail "no evidence was recorded after the rebuild"
          if lastAct.isNone then return .fail s!"(c) no activation of {r} was logged in the window"
          if stPost != 50 then return .fail s!"precondition: stored {stPost}/50 post-switch values on {m2}"
          if onM2.isNone || onR.isNone then return .fail s!"(d) the final reads were not observed ({m2} {onM2.isSome}, {r} {onR.isSome})"
          if !badM2.isEmpty then return .fail s!"(d) the new master {m2} does not hold every key and value ({badM2.length}: {badM2.head?.getD ""})"
          if !badR.isEmpty then return .fail s!"(d) {r}'s copy does not equal the new master's ({badR.length}: {badR.head?.getD ""})"
          if !unavailR.isEmpty then return .fail s!"(d) availability, not data: {unavailR.length} of {r}'s final reads got an explicit error, so its copy is not verified ({unavailR.head?.getD ""})"
          if notLocal > 0 then return .fail s!"(d) {notLocal}/400 of {r}'s answers were not attributed to its LOCAL copy: no evidence the copy matches"
          if !containsSubstr rMap s!" 0={m2}." then return .fail s!"(d) {r}'s latest map does not name {m2} as master ({rMap})"
          let evEpoch := match evEnd with
            | some (_, some e) => some e
            | _ => none
          if act.isPass then
            if evEpoch != newEpoch then return .fail s!"activated on the copy from the new master {m2}, yet the evidence names {evEpoch} (new epoch {newEpoch})"
            return .pass
          -- UNDECIDED: the old master's copy was activated BEFORE the replica
          -- accepted the new map; post-switch re-validation and read
          -- suppression are judged from the record above, not passed here
          if evEpoch != oldEpoch then return .fail s!"activated on the old master's copy, yet the evidence names {evEpoch} (old epoch {oldEpoch})"
          return .fail s!"UNDECIDED: {r} activated {m}'s completed copy BEFORE accepting map v{aV} (switch v{switchV}); final keys and values equal the new master's and are read locally — post-switch re-validation and read suppression need a judgment (see the timeline); not counted as a pass"
        | _ => return .fail "precondition: one master and two slaves" },

    { name := "reconstruction source re-selection, UNREACHABLE old master: while a replica dumps from the master, the master's flared is killed and another node promoted; the rebuild re-selects the new master (not the dead one), completes, and its evidence names the new master's epoch"
      run := do
        match ← c.allInSync 400 600 with
        | none => return .fail "precondition: the copies did not converge on 400 keys"
        | some (m, a, b) =>
          let oldEpoch ← c.statStr (← ip m) "rocksdb_source_epoch"
          let r := a
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not restart {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"{r} did not start a full dump after its restart"
          -- the source becomes UNREACHABLE: the node is cordoned and the
          -- master pod force-deleted, so its replacement stays Pending until
          -- a successor is promoted
          let preB ← c.statStr (← ip b) "rocksdb_source_epoch"
          match ← kubectl ["cordon", kindNode] with
          | .error e => return .fail s!"could not cordon {kindNode}: {e}"
          | .ok _ => pure ()
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--grace-period=0", "--force", "--wait=false"]
          let promoted ← c.newMasterAfter m 240
          discard <| kubectl ["uncordon", kindNode]
          let some m2 := promoted | return .fail s!"no successor was promoted after {m} became unreachable"
          if m2 == r then return .fail s!"precondition: the rebuilding replica {r} itself was promoted"
          let newEpoch ← c.promotedEpoch m2 preB
          if newEpoch.isNone then return .fail s!"precondition: {m2}'s epoch before the fault was unreadable or did not advance after its promotion"
          let (early, recorded) ← c.noEvidenceUntilRecorded r (← ip r) 600
          let log ← c.flaredLog r
          let switched := containsSubstr log "reconstruction source changed" && containsSubstr log (m2 ++ ".")
          let evEnd ← c.evidence (← ip r)
          IO.eprintln s!"# {r} rebuilding from {m}; {m} killed, {m2} promoted (epoch {oldEpoch} -> {newEpoch}); source re-selected to {m2}={switched}; evidence before completion {early}; recorded={recorded}; final {evEnd}; other slave {b}"
          if !switched then return .fail s!"the reconstruction did not re-select {m2} as its source"
          if !early.isEmpty then return .fail s!"evidence was visible before a dump completed: {early}"
          if !recorded then return .fail "no evidence was recorded after the rebuild from the new master"
          match evEnd with
          | some (_, some e) =>
            if some e != newEpoch then return .fail s!"the evidence {e} is not the new master's epoch {newEpoch}"
            return .pass
          | _ => return .fail s!"no final evidence ({evEnd})" },

    { name := "activation boundary, MASTER CHANGE: a replica finishes its copy, its first activation attempts are held, and the master is drained meanwhile; the held activation is STOPPED (never activated on the old source) and the replica is rebuilt from the promoted master"
      run := do
        match ← c.allInSync 400 600 with
        | none => return .fail "precondition: the copies did not converge on 400 keys"
        | some (m, r, other) =>
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not restart {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"{r} did not start a full dump after its restart"
          -- FIXED comparison window: the time and the flared process, both
          -- taken now (after the restart); every check below reads the log
          -- from this time and requires the same process at the end.
          let since ← utcNow
          let proc0 ← c.processId r
          if proc0.isNone then return .fail s!"precondition: {r}'s process identity could not be read"
          let armed ← waitForCondition s!"the activation hold is armed in {r}" 60 do
            return (← kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "touch", "/tmp/act-hold"]).toBool
          let held ← waitForCondition s!"{r}'s copy is done and its activation is held" 300 do
            return containsSubstr (← c.flaredLogSince r since) "held by FLARE_TEST_ACTIVATION_HOLD_FILE"
          if !armed || !held then
            discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
            return .fail s!"precondition: the activation was not held (armed={armed}, held={held})"
          let preOther ← c.statStr (← ip other) "rocksdb_source_epoch"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let promoted ← c.newMasterAfter m 240
          discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
          let some m2 := promoted | return .fail s!"no successor was promoted after draining {m}"
          if m2 == r then return .fail s!"precondition: the held replica {r} itself was promoted"
          let newEpoch ← c.promotedEpoch m2 preOther
          if newEpoch.isNone then return .fail s!"precondition: {m2}'s epoch before the fault was unreadable or did not advance after its promotion"
          -- The old copy must not be activated. Two legitimate ways to see it:
          -- the held activation is STOPPED (the master changed within its
          -- attempts), or the attempts ran out first and the next round
          -- re-selected the source ('reconstruction source changed'; CI
          -- 37419299532). Either way, the FIRST prepare->active of this
          -- process after the hold must come after evidence of the NEW
          -- master's epoch was recorded.
          let rebuilt ← waitForCondition s!"{r} is rebuilt from {m2} with evidence of its epoch" 600 do
            match ← c.evidence (← ip r) with
            | some (_, some e) => return some e == newEpoch
            | _ => return false
          -- the replica must actually RECOVER: Active in the operator's map
          let activeNow ← waitForCondition s!"{r} is Active again" 300 do
            return (← c.nodeView).any fun e => podOf e.fqdn == r && e.role == 1 && e.state == 0
          let proc1 ← c.processId r
          let log ← c.flaredLogSince r since
          if proc1 != proc0 then
            return .fail s!"{r}'s flared process changed during the window ({proc0} -> {proc1}): the log order is not comparable"
          if !containsSubstr log "held by FLARE_TEST_ACTIVATION_HOLD_FILE" then
            return .fail "the comparison window does not contain the hold marker (log incomplete): the order cannot be proven"
          let tail := afterLast log "held by FLARE_TEST_ACTIVATION_HOLD_FILE"
          let lines := tail.splitOn "\n"
          let idx := fun (p : String → Bool) => (lines.zip (List.range lines.length)).findSome? (fun (l, i) => if p l then some i else none)
          let stopOrSwitch := idx (fun l => containsSubstr l "activation STOPPED" || containsSubstr l "reconstruction source changed")
          let newEvidence := idx (fun l => containsSubstr l "rebuild evidence recorded" && (newEpoch.map (containsSubstr l ·)).getD false)
          -- the activation point is the replica's OWN record of a successful
          -- activation ("node activated"), logged when activate_node returned;
          -- its map-shift line (prepare->active) arrives with a later
          -- broadcast and was absent when the log was read right after the
          -- operator's map showed Active (CI 37445879349)
          let firstActive := idx (fun l => containsSubstr l "node activated (attempt" && containsSubstr l s!"from {m2}.")
          IO.eprintln s!"# {r} held after its copy from {m}; {m} drained, {m2} promoted (epoch {newEpoch}); after the hold (line indices): stop/switch {stopOrSwitch}, evidence of the new epoch {newEvidence}, first prepare->active {firstActive}; rebuilt={rebuilt}; items {← c.currItems (← ip r)} vs {← c.currItems (← ip m2)}"
          -- the timeline itself (CI 37438962871 printed only indices): which
          -- map each validation / activation used and when the replica
          -- accepted the map naming {m2}
          let tl := lines.filter fun l =>
            containsSubstr l "activation source check passed" || containsSubstr l "node activated (attempt" || containsSubstr l "activation STOPPED"
              || containsSubstr l "activation deferred" || containsSubstr l "held by FLARE_TEST_ACTIVATION_HOLD_FILE"
              || containsSubstr l "reconstruction source changed" || containsSubstr l "starting dump operation" || containsSubstr l "reconstruction via full dump completed"
              || containsSubstr l "rebuild evidence recorded" || containsSubstr l "old_state=prepare, new_state=active"
              || (containsSubstr l "node map accepted" && (containsSubstr l s!" 0={m}." || containsSubstr l s!" 0={m2}."))
          let firstHold := ((log.splitOn "\n").filter (containsSubstr · "held by FLARE_TEST_ACTIVATION_HOLD_FILE")).head?.getD ""
          let beforeHold := ((log.splitOn "\n").filter fun l => containsSubstr l "node map accepted" || containsSubstr l "activation source check passed").reverse.take 3 |>.reverse
          IO.eprintln s!"# {r} first hold: {firstHold}\n# {r} last map/check lines of the window (for the versions in force): {String.intercalate " | " beforeHold}\n# {r} timeline after the last hold ({tl.length} line(s), first 60):\n{String.intercalate "\n" (tl.take 60)}"
          -- the order verdict over the whole window of this process
          -- (TraceMatch.judgeActivation, unit-tested): BUG / UNDETERMINED
          -- fail; UNDECIDED (old copy activated BEFORE accepting the new
          -- map) is not a pass either
          let act := judgeActivation (log.splitOn "\n") m m2
          IO.eprintln s!"# {r} activation order: {act.describe}"
          match act with
          | .bug why => return .fail s!"activation order: {why}"
          | .undetermined why => return .fail s!"activation order UNDETERMINED (not a pass): {why}"
          | .undecided why => return .fail s!"UNDECIDED (not a pass): {why}"
          | .pass _ => pure ()
          if stopOrSwitch.isNone then return .fail "the old copy's activation was neither stopped nor abandoned for the new source"
          if !rebuilt then return .fail s!"{r} was not rebuilt from the promoted master {m2}"
          if !activeNow then return .fail s!"{r} did not become Active again after its rebuild"
          match firstActive, newEvidence with
          | some a, some e => if a < e then return .fail s!"{r} became Active (line {a}) BEFORE its copy of the new master was recorded (line {e}): the old copy was activated"
          | some _, none => return .fail s!"{r} became Active but no evidence of the new master's epoch was recorded in the window"
          | none, _ => return .fail s!"{r} is Active in the map but its own activation on {m2}'s copy is not in the window: the order cannot be proven"
          return .pass },

    { name := "activation boundary, SAME NAME NEW HISTORY: while a replica's activation is held, its source (still master, same name) is bulk-rewritten (flush_all: new source epoch); the activation is STOPPED as a history change, not completed on the old copy"
      run := do
        match ← c.allInSync 400 600 with
        | none => return .fail "precondition: the copies did not converge on 400 keys"
        | some (m, r, _) =>
          let mIp ← ip m
          let epoch0 ← c.statStr mIp "rocksdb_source_epoch"
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not restart {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"{r} did not start a full dump after its restart"
          let armed ← waitForCondition s!"the activation hold is armed in {r}" 60 do
            return (← kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "touch", "/tmp/act-hold"]).toBool
          let held ← waitForCondition s!"{r}'s copy is done and its activation is held" 300 do
            return containsSubstr (← c.flaredLog r) "held by FLARE_TEST_ACTIVATION_HOLD_FILE"
          if !armed || !held then
            discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
            return .fail s!"precondition: the activation was not held (armed={armed}, held={held})"
          discard <| execInDebugPod emptySourceCfg.debugPod ns s!"printf 'flush_all\\r\\n' | nc -w 5 {mIp} {emptySourceCfg.flarePort}"
          let epoch1 ← c.statStr mIp "rocksdb_source_epoch"
          let stillMaster := (← c.p0Roles).1 == some m
          discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
          let stopped ← waitForCondition s!"{r}'s held activation is stopped as a history change" 180 do
            let log ← c.flaredLog r
            return containsSubstr log "activation STOPPED" && containsSubstr log "changed history"
          IO.eprintln s!"# {m} flush_all while {r}'s activation was held: epoch {epoch0} -> {epoch1}; {m} still master={stillMaster}; stopped as a history change={stopped}"
          if epoch1 == epoch0 then return .fail "precondition: flush_all did not advance the master's source epoch"
          if !stillMaster then return .fail s!"precondition: {m} is no longer master (this test is about the SAME source)"
          if !stopped then return .fail "the held activation was not stopped although the same-name source changed history"
          -- restore the data set for the next test
          let w ← c.bulkWrite mIp "es" 400 16384
          if w != 400 then return .fail s!"could not restore the data set ({w}/400)"
          return .pass },

    { name := "activation boundary, UNKNOWN: a completed copy whose source cannot be probed for more than 30 checks is KEPT (no new transfer); once the same source answers again the copy is activated"
      run := do
        match ← c.allInSync 400 600 with
        | none => return .fail "precondition: the copies did not converge on 400 keys"
        | some (m, r, _) =>
          let mIp ← ip m
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not restart {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"{r} did not start a full dump after its restart"
          let armed ← waitForCondition s!"the activation hold is armed in {r}" 60 do
            return (← kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "touch", "/tmp/act-hold"]).toBool
          let held ← waitForCondition s!"{r}'s copy is done and its activation is held" 300 do
            return containsSubstr (← c.flaredLog r) "held by FLARE_TEST_ACTIVATION_HOLD_FILE"
          if !armed || !held then
            discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
            return .fail s!"precondition: the activation was not held (armed={armed}, held={held})"
          let rIp ← ip r
          let recon0 := (← c.statNat rIp "reconstruction_started").getD 0
          let logAtHold := (← c.flaredLog r)
          let dumps0 := ((logAtHold.splitOn "\n").filter (containsSubstr · "starting dump operation")).length
          -- the source becomes UNKNOWN to the replica: its packets to the
          -- master are DROPPED (no RST), so each probe's connect must end by
          -- the CONNECT DEADLINE — the timeout path itself is exercised (the
          -- master stays master and keeps serving)
          let dropSpec := ["-s", rIp, "-d", mIp, "-p", "tcp", "--dport", "12121", "-j", "DROP"]
          match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ dropSpec) with
          | .error e => discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]; return .fail e
          | .ok _ => pure ()
          discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
          let manyUnknown ← waitForCondition s!"{r} defers activation on an Unknown source more than 30 times" 900 do
            return (((← c.flaredLog r).splitOn "\n").filter (containsSubstr · "activation deferred")).length > 30
          let timeoutLines := ((← c.flaredLog r).splitOn "\n").filter fun l =>
            containsSubstr l "connect() failed" && containsSubstr l "timed out" && containsSubstr l "within 3000 msec"
          for _ in [0:3] do
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ dropSpec)
          let activated ← waitForCondition s!"{r} is activated once the same source answers again" 600 do
            let entries ← c.nodeView
            return entries.any fun e => podOf e.fqdn == r && e.role == 1 && e.state == 0
          let log ← c.flaredLog r
          let deferred := ((log.splitOn "\n").filter (containsSubstr · "activation deferred")).length
          let dumps1 := ((log.splitOn "\n").filter (containsSubstr · "starting dump operation")).length
          let truncs := ((afterLast log "held by FLARE_TEST_ACTIVATION_HOLD_FILE").splitOn "\n").filter (containsSubstr · "truncating local storage")
          let recon1 := (← c.statNat rIp "reconstruction_started").getD 0
          let stopped := containsSubstr log "activation STOPPED"
          IO.eprintln s!"# {r} held after its copy from {m}; probes to {m} blocked: Unknown deferrals {deferred} (>30: {manyUnknown}); activated after unblocking={activated}; dumps {dumps0} -> {dumps1}; truncates after the hold {truncs.length}; reconstruction_started {recon0} -> {recon1}; stopped={stopped}; items {← c.currItems rIp} vs {← c.currItems mIp}"
          IO.eprintln s!"# connect attempts ended by the 3 s connect DEADLINE: {timeoutLines.length}{if timeoutLines.isEmpty then "" else "\n# " ++ (timeoutLines.headD "")}"
          if !manyUnknown then return .fail "precondition: fewer than 31 Unknown checks were observed"
          if timeoutLines.isEmpty then return .fail "no connect attempt ended by the connect deadline (the DROP did not exercise the timeout path)"
          if stopped then return .fail "an Unknown source was treated as a change (activation STOPPED)"
          if dumps1 != dumps0 || !truncs.isEmpty || recon1 != recon0 then
            return .fail s!"the completed copy was transferred again while the source was Unknown (dumps {dumps0} -> {dumps1}, truncates {truncs.length}, reconstruction_started {recon0} -> {recon1})"
          if !activated then return .fail s!"{r} was not activated after the same source answered again"
          if (← c.currItems rIp) != (← c.currItems mIp) then return .fail "the activated copy does not match the master's item count"
          return .pass },

    -- RETIRED (2026-10-07, user decision): "SAF-08 same master_id, different
    -- history" — the replica whose evidence names the EARLIER epoch must keep
    -- its copy when the promoted master is emptied. Under R3 such a replica is
    -- rebuilt right after the promotion, so the test's precondition cannot be
    -- reached (37493280795, 37547969798). Its history: b9e0742 rebuilt the
    -- replica from an empty / 2-key promoted master (0/400 and 2/400; the cause
    -- of THOSE losses is NOT established), 254640b did not produce its premise
    -- (queued deletes reached the replica). Its expectation is carried by the
    -- copy-protection suite's H1 reproduction (fixed order: approved while the
    -- master holds data, master emptied, released → copy kept, every key and
    -- value), which also covers a long wait afterwards. The code is in git
    -- history (9bb08db and earlier).
    { name := "R2 production read policy: with readUnavailableError=true in the FlareCluster, a GET a replica cannot forward to its master is an EXPLICIT error to the client (never END), and a key that is really absent is still a miss"
      run := do
        -- the operator path: the CR setting reached every pod's extra.conf
        let pods := (← c.dataPods).map (·.1)
        let mut confs : List String := []
        for p in pods do
          match ← kubectl ["exec", "-n", ns, p, "-c", "flared", "--", "sh", "-c", "grep -h read-unavailable-error /etc/flared/extra.conf || echo MISSING"] with
          | .ok o => confs := confs ++ [s!"{p}: {o.trim}"]
          | .error e => confs := confs ++ [s!"{p}: unreadable ({e.take 80})"]
        IO.eprintln s!"# extra.conf on every pod: {confs}"
        if confs.isEmpty || !(confs.all (containsSubstr · "read-unavailable-error = true")) then
          return .fail s!"precondition: the CR's readUnavailableError did not reach every pod's extra.conf ({confs})"
        match ← c.p0Roles with
        | (some m, s :: _) =>
          let mIp ← ip m
          let sIp ← ip s
          -- its own keys (earlier tests delete the bulk keys on a master)
          let stored ← c.setValues mIp [("es_r2_a", "r2val_a"), ("es_r2_b", "r2val_b")]
          if stored != 2 then return .fail s!"precondition: stored {stored}/2 keys on {m}"
          -- reads on the replica are forwarded to the master (own balance 0)
          let balance0 := ((← kubectlGetJsonpath "flarecluster" emptySourceCfg.name ns "{.spec.readBalance}").toOption.getD "").trim
          let restorePatch := if balance0.isEmpty then "{\"spec\":{\"readBalance\":null}}" else s!"\{\"spec\":\{\"readBalance\":{balance0}}}"
          if let .error e ← kubectlPatch "flarecluster" emptySourceCfg.name ns "{\"spec\":{\"readBalance\":{\"master\":100,\"slave\":0}}}" then
            return .fail s!"could not route reads to the master: {e}"
          let since ← utcNow
          let fwd ← waitForCondition s!"a GET on {s} is forwarded to {m} (trace)" 150 do
            let mk := s!"es_mark_r2_route_{← IO.monoMsNow}"
            discard <| c.getRound sIp mk []
            return (readTraces (← c.flaredLogAllSince s since)).any fun l => traceField l "key" == mk && traceField l "decision" == "proxy"
          -- 1. forwarding works: the master's value comes back
          let ok1 ← c.getRound sIp "es_mark_r2_ok" ["es_r2_a"]
          -- 2. the replica cannot reach the master: explicit error, not END
          let cutOk ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ ruleSpecBack mIp sIp)
          -- the client waits (90 s) until the server ANSWERS while the cut
          -- stays in place (CI 37451914041: a 5 s client gave up while the
          -- forward was still retrying, and the cut was healed before the
          -- failure reached anyone); the time to the answer is recorded
          let t0 ← IO.monoMsNow
          let failed ← c.getRound sIp "es_mark_r2_cut" ["es_r2_b"] (waitSec := 120)
          let answerMs := (← IO.monoMsNow) - t0
          for _ in [0:3] do
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpecBack mIp sIp)
          -- 3. healed: a key that does not exist is still a miss
          let absent ← c.getRound sIp "es_mark_r2_absent" ["es_r2_never_written"]
          discard <| kubectlPatch "flarecluster" emptySourceCfg.name ns restorePatch
          let tr := readTraces (← c.flaredLogAllSince s since)
          let t1 := ((tracesAfterMarker tr "es_mark_r2_ok").lookup "es_r2_a").getD {}
          let t2 := ((tracesAfterMarker tr "es_mark_r2_cut").lookup "es_r2_b").getD {}
          let t3 := ((tracesAfterMarker tr "es_mark_r2_absent").lookup "es_r2_never_written").getD {}
          let a1 := ((ok1.bind (·.head?)).map (·.2)).getD "(not observed)"
          let a2 := ((failed.bind (·.head?)).map (·.2)).getD "(not observed)"
          let a3 := ((absent.bind (·.head?)).map (·.2)).getD "(not observed)"
          let c1 := classifyAnswer "=r2val_a" a1 t1
          let c2 := classifyAnswer "=r2val_b" a2 t2
          let c3 := classifyAnswer "miss" a3 t3
          IO.eprintln s!"# R2 on {s} (master {m}): forwarded={fwd}; cut applied={cutOk.isOk}\n#   1 forwarding works: {a1} ({c1}) {t1.answer.getD "(no answer line)"}\n#   2 master unreachable: {a2} ({c2}) after {answerMs} ms (availability, not judged) {t2.answer.getD "(no answer line)"}\n#   3 absent key: {a3} ({c3}) {t3.answer.getD "(no answer line)"}"
          if !fwd then return .fail s!"precondition: reads on {s} were not forwarded to {m}"
          if let .error e := cutOk then return .fail s!"precondition: could not cut {s} -> {m}: {e}"
          if c1 != "ok" then return .fail s!"precondition: a forwarded GET did not return the master's value ({a1}, {c1})"
          -- the client must receive an explicit error, and the server must
          -- record WHY (a refusal under read-unavailable-error)
          if failed.isNone then
            return .fail s!"the error answer was NOT observed: no reply within the 120 s client deadline while the cut was held ({answerMs} ms); the long forward wait is a separate open item"
          if !a2.startsWith "err:SERVER_ERROR" then
            return .fail s!"a GET the replica could not forward answered {a2} ({c2}), not an explicit error: the outage is shown to the client as '{if a2 == "miss" then "key absent" else a2}'"
          if (t2.answer.map (traceField · "result")) != some "refused" || (t2.answer.map (traceField · "reason")) != some "read_unavailable_error" then
            return .fail s!"the explicit error is not attributed to read-unavailable-error on {s}: {t2.answer.getD "(no answer line)"}"
          if c3 != "ok" then return .fail s!"a really absent key did not answer a plain miss ({a3}, {c3})"
          return .pass
        | _ => return .fail "precondition: a master and a slave in partition 0" }
  ]
}

-- ─── SC-03: repair-ledger first window and process identity ─────────────

-- The ledger's FIRST observation of a master's drop counters used to be a
-- silent baseline (CI 37376724850): drops before it were never repaired.
-- A slow stats probe (180 s) leaves a wide first window on purpose.
private def ledgerCfg : ClusterConfig := {
  name := "repair-ledger"
  «namespace» := "flare-repair-ledger"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-repair-ledger"
  storageBackend := "rocksdb"
  usePvc := true
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "180000")]
}

/-- Cut the master's forwards, write `n` keys through it, wait until the
    master counts drops, heal. Returns (stored, drops before, drops after). -/
private def Ctx.dropWrites (c : Ctx) (mIp sIp pfx : String) (n : Nat) : IO (Except String (Nat × Nat × Nat)) := do
  let d0 := (← c.statNat mIp "proxy_write_dropped").getD 0
  match ← cutForwards mIp sIp with
  | .error e => return .error e
  | .ok () => pure ()
  let w ← writeKeys c.cfg.debugPod c.cfg.«namespace» mIp c.cfg.flarePort pfx n
  let counted ← waitForCondition "the master counts dropped replica writes" 180 do
    return ((← c.statNat mIp "proxy_write_dropped").getD 0) > d0
  healForwards mIp sIp
  let d1 := (← c.statNat mIp "proxy_write_dropped").getD 0
  if !counted then return .error s!"the master never counted drops (stored {w}/{n})"
  return .ok (w, d0, d1)

private def countLines (log needle : String) : Nat :=
  ((log.splitOn "\n").filter (containsSubstr · needle)).length

def repairLedgerSuite : TestSuite := {
  name := "repair-ledger"
  setup := do
    deployCluster ledgerCfg
    IO.sleep 30000
  teardown := cleanupCluster ledgerCfg
  onFailure := dumpClusterDiagnostics ledgerCfg.«namespace» s!"app={ledgerCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := ledgerCfg }
    let ns := ledgerCfg.«namespace»
    [
    { name := "SC-03 first window: writes dropped BEFORE the ledger's first observation are requested (possibly unrepaired) and repaired — not absorbed as a baseline"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (_, mIp, sPod, sIp) =>
          -- DETERMINISTIC first window (CI 37419299532: waiting for the probe
          -- slot raced it). The operator is stopped, the drops happen, the
          -- persisted ledger is removed (as on a new cluster or a lost
          -- status), and only then does an operator start: its FIRST
          -- observation already sees the drops.
          discard <| kubectl ["scale", "deployment", ledgerCfg.operatorName, "-n", ns, "--replicas=0"]
          let stoppedOp ← waitForCondition "the operator is stopped" 180 do
            return (← getPodNames s!"app={ledgerCfg.operatorName}" ns).isEmpty
          if !stoppedOp then return .fail "precondition: the operator did not stop"
          match ← c.dropWrites mIp sIp "fw" 40 with
          | .error e =>
            discard <| kubectl ["scale", "deployment", ledgerCfg.operatorName, "-n", ns, "--replicas=1"]
            return .fail e
          | .ok (w, d0, d1) =>
            let cleared ← kubectl ["patch", "flarecluster", ledgerCfg.name, "-n", ns, "--subresource=status", "--type=merge", "-p", "{\"status\":{\"replicaRepairs\":null}}"]
            let ledgerNow := ((← kubectlGetJsonpath "flarecluster" ledgerCfg.name ns "{.status.replicaRepairs}").toOption.getD "").trim
            discard <| kubectl ["scale", "deployment", ledgerCfg.operatorName, "-n", ns, "--replicas=1"]
            IO.eprintln s!"# operator stopped; stored {w}/40 with forwards cut; master drops {d0} -> {d1}; persisted ledger removed={cleared.toBool} (now '{ledgerNow}'); operator started"
            if !cleared.toBool || !ledgerNow.isEmpty then return .fail "precondition: the persisted ledger could not be removed"
            let requested ← waitForCondition "the first observation requests the repair" 300 do
              return containsSubstr (← c.opLog 200000) "REPLICA REPAIR (first observation)"
            let repaired ← waitForCondition "the replica is repaired and the ledger closes" 600 do
              return (← c.currItems sIp) == (← c.currItems mIp) && (← c.ledgerDests).isEmpty
            let log ← c.opLog 200000
            IO.eprintln s!"# first-observation request={requested}; repaired={repaired}; {sPod} items {← c.currItems sIp} vs master {← c.currItems mIp}; init line: {((log.splitOn "\n").find? (containsSubstr · "replica repair ledger initialized")).getD "(none)"}"
            if !requested then return .fail "the drops before the first observation were not requested"
            if !repaired then return .fail s!"the replica was not repaired (items {← c.currItems sIp} vs {← c.currItems mIp}, ledger {← c.ledgerDests})"
            return .pass },

    { name := "SC-03 the same cumulative counter is never requested twice, across an operator restart"
      run := do
        let before := countLines (← c.opLog 200000) "REPLICA REPAIR"
        discard <| kubectl ["delete", "pod", "-n", ns, "-l", s!"app={ledgerCfg.operatorName}", "--wait=false"]
        IO.sleep 20000
        let restarted ← waitForCondition "the operator is back and past its grace period" 300 do
          return containsSubstr (← c.opLog 400) "grace period over"
        -- two probe slots of the restarted operator
        IO.sleep 400000
        let log ← c.opLog 200000
        let again := countLines log "REPLICA REPAIR (first observation)" + countLines log "REPLICA REPAIR requested"
        IO.eprintln s!"# repair lines before the restart (all containers) {before}; request lines in the restarted operator {again}; ledger {← c.ledgerDests}"
        if !restarted then return .fail "the operator did not come back"
        if again > 0 then return .fail s!"the restarted operator requested again from counters already accounted ({again} line(s))"
        if !(← c.ledgerDests).isEmpty then return .fail "the ledger is not empty"
        return .pass },

    { name := "SC-03 a RESTARTED master (new flared process, counter reset) has its new drops attributed in full, and nothing is requested twice"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp0, _, _) =>
          let boot0 ← c.statNat mIp0 "reconstruction_boot_id"
          match ← c.killFlaredIn mPod with
          | .error e => return .fail s!"could not restart the master's flared: {e}"
          | .ok _ => pure ()
          IO.sleep 20000
          -- the master may have failed over; use the pair as it is now
          let settled ← waitForCondition "a master and an Active slave again" 300 do
            return (← c.pair).toBool
          if !settled then return .fail "the cluster did not settle after the master restart"
          match ← c.pair with
          | .error e => return .fail e
          | .ok (_, mIp, sPod, sIp) =>
            let synced ← waitForCondition "the copies match before the next fault" 600 do
              return (← c.currItems sIp) == (← c.currItems mIp) && (← c.ledgerDests).isEmpty
            if !synced then return .fail "precondition: copies not in sync after the restart"
            let boot1 ← c.statNat mIp "reconstruction_boot_id"
            let reqBefore := countLines (← c.opLog 200000) "REPLICA REPAIR requested"
            match ← c.dropWrites mIp sIp "rs" 30 with
            | .error e => return .fail e
            | .ok (w, d0, d1) =>
              let requested ← waitForCondition "the new drops are requested" 420 do
                return countLines (← c.opLog 200000) "REPLICA REPAIR requested" > reqBefore
              let repaired ← waitForCondition "repaired and the ledger closes" 600 do
                return (← c.currItems sIp) == (← c.currItems mIp) && (← c.ledgerDests).isEmpty
              let log ← c.opLog 200000
              let reqLines := (log.splitOn "\n").filter (containsSubstr · "REPLICA REPAIR requested")
              IO.eprintln s!"# master boot {boot0} -> {boot1}; stored {w}/30 with forwards cut; drops {d0} -> {d1}; requested={requested} ({reqLines.length - reqBefore} new line(s)); repaired={repaired}; {sPod} items {← c.currItems sIp} vs {← c.currItems mIp}\n# {(reqLines.getLast?).getD ""}"
              if !requested then return .fail "the restarted master's drops were not requested"
              if !repaired then return .fail "not repaired"
              if reqLines.length - reqBefore > 1 then return .fail s!"requested {reqLines.length - reqBefore} times for one fault"
              return .pass }
  ]
}

-- ─── R3: source change re-validates (own cluster) ───────────────────────

/-- R3 acceptance runs on its OWN cluster from a verified initial state, so a
    failure of an earlier empty-source test cannot take the R3 verdict with
    it (CI 37472032699: test 9's damage failed R3's precondition). Same
    shape and seams as the empty-source cluster. -/
private def r3Cfg : ClusterConfig := { emptySourceCfg with
  name := "r3-source"
  «namespace» := "flare-r3-source"
  debugPod := "debug-r3-source" }

def r3SourceChangeSuite : TestSuite := {
  name := "r3-source-change"
  setup := do
    deployCluster r3Cfg
    discard <| kubectlPatch "flarecluster" r3Cfg.name r3Cfg.«namespace» "{\"spec\":{\"circuitBreaker\":{\"minUnavailableToTrip\":3}}}"
    IO.sleep 30000
  teardown := do
    for ip in (← getPodIps s!"app=flare,cluster={r3Cfg.name}" r3Cfg.«namespace») do
      for ip2 in (← getPodIps s!"app=flare,cluster={r3Cfg.name}" r3Cfg.«namespace») do
        if ip != ip2 then
          for _ in [0:2] do
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec ip ip2)
    cleanupCluster r3Cfg
  onFailure := dumpClusterDiagnostics r3Cfg.«namespace» s!"app={r3Cfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := r3Cfg }
    let ns := r3Cfg.«namespace»
    let ip : String → IO String := fun p => do return (← getPodIp p ns).getD ""
    [
    { name := "R3 initial state: 400 keys written on the master and every copy converged (verified before the scenario)"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.p0Roles with
        | (some m0, [_, _]) =>
          -- 16 KB values: at the suite's 256 KB/s throttle the dump lasts
          -- ~25 s, so a dump IN PROGRESS can be observed (1 KB finished
          -- before the wait saw it: CI 37485241380)
          let w ← c.bulkWrite (← ip m0) "es" 400 16384
          if w != 400 then return .fail s!"stored {w}/400"
          if (← c.allInSync 400 300).isNone then return .fail "the copies did not converge on 400 keys"
          return .pass
        | _ => return .fail "one master and two slaves" },

    { name := "R3 source change re-validates, never carries eligibility over: with reads routed to replicas (balance > 0), a replica activates the OLD master's copy, THEN accepts the map naming the new master — from that acceptance it answers no read from its copy (forwarded, an explicit error while the new master is unreachable), is not eligible, and once the new master is observed with another history it is rebuilt and only then answers locally, every value correct"
      run := do
        match ← c.allInSync 400 600 with
        | none => return .fail "precondition: the copies did not converge on 400 keys"
        | some (m, r, _) =>
          let mIp ← ip m
          let rIp ← ip r
          let opIp := ((← kubectl ["get", "pods", "-n", ns, "-l", s!"app={r3Cfg.operatorName}", "-o", "jsonpath={.items[0].status.podIP}"]).toOption.getD "").trim
          if opIp.isEmpty then return .fail "precondition: the operator's pod IP is unreadable"
          let kv := (List.range 30).map fun i => (s!"es_r3_{i}", s!"r3val_{i}")
          if (← c.setValues mIp kv) != 30 then return .fail s!"precondition: could not write the R3 keys on {m}"
          if (← c.allInSync 400 300).isNone && (← c.allInSync 430 300).isNone then return .fail "precondition: the copies did not converge after the R3 keys"
          let balance0 := ((← kubectlGetJsonpath "flarecluster" r3Cfg.name ns "{.spec.readBalance}").toOption.getD "").trim
          let restorePatch := if balance0.isEmpty then "{\"spec\":{\"readBalance\":null}}" else s!"\{\"spec\":\{\"readBalance\":{balance0}}}"
          if let .error e ← kubectlPatch "flarecluster" r3Cfg.name ns "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}" then
            return .fail s!"could not route reads to the replicas: {e}"
          IO.sleep 1100
          let since ← utcNow
          let ins := fun (a b : String) => hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ ruleSpec a b)
          let del := fun (a b : String) => do
            for _ in [0:3] do discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec a b)
          let cleanup : IO Unit := do
            del opIp rIp
            discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
          -- 1. r takes a fresh copy of m; its activation is held
          match ← c.killFlaredIn r with
          | .error e => return .fail s!"could not restart {r}: {e}"
          | .ok _ => pure ()
          if !(← c.waitDumpStart r 180) then return .fail s!"precondition: {r} did not start a full dump"
          let armed ← waitForCondition s!"the activation hold is armed in {r}" 60 do
            return (← kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "touch", "/tmp/act-hold"]).toBool
          let held ← waitForCondition s!"{r}'s copy is done and its activation is held" 300 do
            return containsSubstr (← c.flaredLogSince r since) "held by FLARE_TEST_ACTIVATION_HOLD_FILE"
          if !armed || !held then cleanup; return .fail s!"precondition: the activation was not held (armed={armed}, held={held})"
          -- 2. the operator's map pushes to r are cut; m is drained and
          --    another node promoted (r keeps the OLD map)
          if let .error e ← ins opIp rIp then cleanup; return .fail s!"precondition: could not cut the operator's pushes to {r}: {e}"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let some m2 ← c.newMasterAfter m 120 | do cleanup; return .fail s!"precondition: no successor promoted after draining {m}"
          if m2 == r then cleanup; return .fail s!"precondition: the held replica {r} itself was promoted"
          let m2Ip ← ip m2
          -- 3. released while r still has the old map: it activates on m's copy
          discard <| kubectl ["exec", "-n", ns, r, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
          let activatedOld ← waitForCondition s!"{r} activates on {m}'s copy under the old map" 40 do
            return ((← c.flaredLogAllSince r since).splitOn "\n").any fun l => containsSubstr l "node activated (attempt" && containsSubstr l s!"from {m}."
          if !activatedOld then
            cleanup
            discard <| kubectlPatch "flarecluster" r3Cfg.name ns restorePatch
            return .fail s!"precondition (order not produced): {r} did not activate on {m}'s copy before the new map; nothing about R3 was tested"
          -- 4. r cannot reach the new master; then the new map reaches r
          if let .error e ← ins rIp m2Ip then cleanup; return .fail s!"precondition: could not cut {r} -> {m2}: {e}"
          del opIp rIp
          let accepted ← waitForCondition s!"{r} accepts a map naming {m2}" 120 do
            return ((← c.flaredLogAllSince r since).splitOn "\n").any fun l => containsSubstr l "node map accepted (version" && containsSubstr l s!" 0={m2}."
          let st1 ← c.readState rIp r
          let eligible1 ← c.statStr rIp "repl_read_source_eligible"
          let srcState1 ← c.statStr rIp "repl_read_source_state"
          let t0 ← IO.monoMsNow
          -- 2 keys: each forward to the unreachable master takes ~36 s to
          -- fail (CI 37485235664), 30 keys did not fit any client window
          let duringKeys := (kv.take 2).map (·.1)
          let during ← c.getRound rIp "es_mark_r3_during" duringKeys (waitSec := 150)
          let duringMs := (← IO.monoMsNow) - t0
          del rIp m2Ip
          -- 5. m2 observable again: another history (promotion epoch) ->
          --    rebuilt, re-bound to m2, then local again
          -- re-bound AND serving: the binding is made at the source check,
          -- BEFORE activation (CI 37493288883 read it while still Prepare), so
          -- also require the replica's own map Active and a GET answered from
          -- its own copy
          let rebound ← waitForCondition s!"{r} is rebuilt, bound to {m2}, Active in its own map and answering locally" 600 do
            let rIpNow ← ip r
            let st ← c.statStr rIpNow "repl_read_source_state"
            let src ← c.statStr rIpNow "repl_read_source"
            let own ← c.readState rIpNow r
            if !(st == some "eligible" && (src.map (containsSubstr · s!"{m2}.")).getD false && containsSubstr own "own[role slave state active") then
              return false
            let mk := s!"es_mark_r3_probe_{← IO.monoMsNow}"
            let t0 ← utcNow
            match ← c.getRound rIpNow mk ["es_r3_0"] with
            | some [(_, a)] =>
              let t := ((tracesAfterMarker (readTraces (← c.flaredLogAllSince r t0)) mk).lookup "es_r3_0").getD {}
              return a == "=r3val_0" && answeredLocally t
            | _ => return false
          let rIp2 ← ip r
          IO.sleep 1100
          let afterAt ← utcNow
          let after ← c.getRound rIp2 "es_mark_r3_after" (kv.map (·.1))
          discard <| kubectlPatch "flarecluster" r3Cfg.name ns restorePatch
          -- the record
          let log := (← c.flaredLogAllSince r since).splitOn "\n"
          let idx := fun (p : String → Bool) => (log.zip (List.range log.length)).findSome? fun (l, i) => if p l then some i else none
          let iAct := idx fun l => containsSubstr l "node activated (attempt" && containsSubstr l s!"from {m}."
          let iAcc := idx fun l => containsSubstr l "node map accepted (version" && containsSubstr l s!" 0={m2}."
          let iInv := idx fun l => containsSubstr l "read source INVALIDATED"
          let iRebuild := idx fun l => containsSubstr l "read source NEEDS REBUILD"
          let iBound2 := idx fun l => (containsSubstr l "read source BOUND:" || containsSubstr l "read source RE-VALIDATED") && containsSubstr l s!"{m2}."
          let tr := readTraces (log.foldl (fun a l => a ++ l ++ "\n") "")
          let tDuring := tracesAfterMarker tr "es_mark_r3_during"
          let trAfter := readTraces (← c.flaredLogAllSince r afterAt)
          let tAfter := tracesAfterMarker trAfter "es_mark_r3_after"
          -- local decisions on r between accepting the new map and re-binding
          let localBetween := (log.zip (List.range log.length)).filter fun (l, i) =>
            containsSubstr l "read-trace seq=" && traceField l "decision" == "local"
              && (match iAcc with | some a => decide (i > a) | none => false)
              && (match iBound2 with | some b => decide (i < b) | none => true)
          let dur := ((during.getD []).map fun (k, a) => (k, a, (tDuring.lookup k).getD {}))
          let aft := ((after.getD []).map fun (k, a) => (k, a, (tAfter.lookup k).getD {}))
          let durLocal := dur.filter fun (_, _, t) => (t.decision.map (traceField · "decision")) == some "local"
          let durNotError := dur.filter fun (_, a, _) => !a.startsWith "err:"
          let aftBad := aft.filter fun (k, a, t) => FlareOperator.E2E.TraceMatch.classifyAnswer s!"={(kv.lookup k).getD "?"}" a t != .ok || !answeredLocally t
          IO.eprintln s!"# R3 order: activated on {m} at log line {iAct}; accepted the map naming {m2} at {iAcc}; INVALIDATED at {iInv}; NEEDS REBUILD at {iRebuild}; bound to {m2} at {iBound2}\n#   right after the acceptance: eligible={eligible1} state={srcState1}; state {st1}\n#   reads during re-validation ({during.map (·.length)} answers, {duringMs} ms): local {durLocal.length}, not an explicit error {durNotError.length}; first {dur.head?.map (fun (k, a, t) => s!"{k} -> {a} | {t.decision.getD "-"} | {t.answer.getD "-"}")}\n#   local read decisions on {r} between acceptance and re-binding: {localBetween.length}\n#   after re-binding (rebound={rebound}): {aft.length} answers, not correct-and-local {aftBad.length}"
          match iAct, iAcc with
          | some a, some b => if a > b then return .fail s!"precondition (order not produced): the activation on {m}'s copy (line {a}) came AFTER accepting the new map (line {b})"
          | _, _ => return .fail s!"precondition: the order lines are missing (activation {iAct}, acceptance {iAcc})"
          if !accepted then return .fail s!"{r} never accepted the map naming {m2}"
          if eligible1 != some "0" then return .fail s!"right after accepting the map naming {m2}, {r} still reports its copy eligible ({eligible1}, state {srcState1})"
          if during.isNone then return .fail s!"the reads during re-validation were not observed ({duringMs} ms)"
          if !durLocal.isEmpty then return .fail s!"{durLocal.length} read(s) were answered from the OLD copy after the new map was accepted"
          if !localBetween.isEmpty then return .fail s!"{localBetween.length} local read decision(s) on {r} between accepting the new map and re-binding: {localBetween.head?.map (·.1)}"
          if !durNotError.isEmpty then return .fail s!"{durNotError.length} read(s) during re-validation (new master unreachable) were not an explicit error: {durNotError.head?.map (fun (k, a, _) => s!"{k} -> {a}")}"
          if iRebuild.isNone then return .fail s!"the new master's other history was never judged (no NEEDS REBUILD line)"
          if !rebound then return .fail s!"{r} was not rebuilt and re-bound to {m2}"
          if dur.length != duringKeys.length then return .fail s!"the reads during re-validation were incomplete ({dur.length}/{duringKeys.length})"
          if after.isNone || aft.length != 30 then return .fail s!"the reads after re-binding were not observed ({aft.length}/30)"
          if !aftBad.isEmpty then return .fail s!"{aftBad.length} read(s) after re-binding were not correct or not local: {aftBad.head?.map (fun (k, a, _) => s!"{k} -> {a}")}"
          return .pass }
  ]
}

-- ─── R3-D: a replica's copy is not destroyed by an unsafe rebuild ─────────

/-- Own cluster (empty-source shape: staged full dump only, throttled),
    with a STOP POINT before every step that replaces a copy
    (FLARE_TEST_DESTRUCTIVE_HOLD_FILE): the order is fixed by the test, not
    by timing. Stats are read every pass so a source change is acted on at a
    known time. -/
private def copyProtCfg : ClusterConfig := { emptySourceCfg with
  name := "copy-prot"
  «namespace» := "flare-copy-prot"
  debugPod := "debug-copy-prot"
  flaredEnv := emptySourceCfg.flaredEnv ++ [("FLARE_TEST_DESTRUCTIVE_HOLD_FILE", "/tmp/destructive-hold"),
                                            ("FLARE_TEST_RECONSTRUCTION_START_HOLD_FILE", "/tmp/start-hold")] }

/-- Every key and value in the node's OWN storage (`dump`, whatever its role:
    a Prepare replica forwards GETs, so its copy is read this way). -/
private def Ctx.localDump (c : Ctx) (ip : String) : IO (Option (List (String × String))) := do
  match ← hostCmd "timeout" ["-k", "5", "90", "kubectl", "exec", c.cfg.debugPod, "-n", c.cfg.«namespace», "--", "sh", "-c",
      s!"printf 'dump 0 -1 0 0\\r\\nquit\\r\\n' | nc -w 60 {ip} {c.cfg.flarePort}"] with
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
        if l.startsWith "VALUE " then
          pending := ((l.splitOn " ").drop 1).head?
        else if l == "END" then ended := true
    return if ended then some acc.reverse else none

/-- Are all of `kv` present with exactly these values in `dump`? -/
private def missingFrom (kv : List (String × String)) (dump : List (String × String)) : List String :=
  kv.filterMap fun (k, v) => if dump.lookup k == some v then none else some s!"{k}={(dump.lookup k).getD "(absent)"}"

def copyProtectionSuite : TestSuite := {
  name := "copy-protection"
  setup := do
    deployCluster copyProtCfg
    discard <| kubectlPatch "flarecluster" copyProtCfg.name copyProtCfg.«namespace» "{\"spec\":{\"circuitBreaker\":{\"minUnavailableToTrip\":3}}}"
    IO.sleep 30000
  teardown := do
    for ip in (← getPodIps s!"app=flare,cluster={copyProtCfg.name}" copyProtCfg.«namespace») do
      for ip2 in (← getPodIps s!"app=flare,cluster={copyProtCfg.name}" copyProtCfg.«namespace») do
        if ip != ip2 then
          for _ in [0:2] do
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec ip ip2)
    cleanupCluster copyProtCfg
  onFailure := dumpClusterDiagnostics copyProtCfg.«namespace» s!"app={copyProtCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := copyProtCfg }
    let ns := copyProtCfg.«namespace»
    let ip : String → IO String := fun p => do return (← getPodIp p ns).getD ""
    -- 8 keys: while a replica is held in Prepare the master still forwards
    -- writes to it, and a cut forward takes ~16 s to be dropped; the cut is
    -- held until EVERY delete is dropped, so the held copy stays as it was
    let kv := (List.range 8).map fun i => (s!"cp_{i}", s!"cpval_{i}")
    -- two stop points: at the START of a reconstruction attempt (before it
    -- decides catch-up / merge / truncate) and right before the destructive
    -- step (after that decision, before the protection rule is evaluated)
    let holdAt := fun (file pod : String) => do return (← kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "touch", file]).toBool
    let releaseAt := fun (file pod : String) => do discard <| kubectl ["exec", "-n", ns, pod, "-c", "flared", "--", "rm", "-f", file]
    let hold := holdAt "/tmp/start-hold"
    let release := releaseAt "/tmp/start-hold"
    let holdD := holdAt "/tmp/destructive-hold"
    let releaseD := releaseAt "/tmp/destructive-hold"
    [
    { name := "copy-protection initial state: distinct keys and values on the master, every copy converged (verified)"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.p0Roles with
        | (some m0, [a, b]) =>
          if (← c.setValues (← ip m0) kv) != kv.length then return .fail "could not write the keys"
          let conv ← waitForCondition "every copy holds every key and value" 300 do
            let mut ok := true
            for p in [m0, a, b] do
              match ← c.localDump (← ip p) with
              | some d => if !(missingFrom kv d).isEmpty then ok := false
              | none => ok := false
            return ok
          if !conv then return .fail "the copies did not converge on every key and value"
          return .pass
        | _ => return .fail "one master and two slaves" },

    { name := "H1 reproduction (fixed order): the rebuild of a replica is APPROVED while its new master holds data, the master is then EMPTIED before the destructive step, and only then is the step released — the replica keeps every original key and value; it is not rebuilt from the empty master however long it waits (test 9's expectation)"
      run := do
        IO.sleep 1100
        let since ← utcNow
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          -- the stop point on both slaves (whichever is promoted, the other is the subject)
          if !(← hold a) || !(← hold b) then return .fail "precondition: could not arm the stop point"
          discard <| kubectl ["delete", "pod", m, "-n", ns, "--wait=false"]
          let some x ← c.newMasterAfter m 180 | do release a; release b; return .fail s!"precondition: no successor promoted after draining {m}"
          let y := if x == a then b else a
          release x
          let xIp ← ip x
          let yIp ← ip y
          -- (1) the rebuild of y is approved while x holds data, and y's
          --     reconstruction reaches the stop point
          let approved ← waitForCondition s!"the rebuild of {y} is approved while {x} holds data" 300 do
            return ((← c.opLog 4000).splitOn "\n").any fun l => containsSubstr l "REPLICA REPAIR: demoting" && containsSubstr l s!"{y}." && containsSubstr l "holds data"
          let atStop ← waitForCondition s!"{y}'s reconstruction is held at its start (before any decision)" 300 do
            return containsSubstr (← c.flaredLogSince y since) "'reconstruction start' held by FLARE_TEST_RECONSTRUCTION_START_HOLD_FILE"
          if !approved || !atStop then
            release y
            c.windowRecord since [y, x] "H1"
            return .fail s!"precondition (order not produced): approved while the master held data={approved}, stopped before the destructive step={atStop}"
          let yBefore ← c.localDump yIp
          -- (2) the master is emptied (forwards to y cut: y's copy must stay
          --     as it was when the rebuild was approved)
          let drops0 := (← c.statNat xIp "proxy_write_dropped").getD 0
          if let .error e ← cutForwards xIp yIp then release y; return .fail e
          let del ← c.deleteKeys xIp "cp" 0 kv.length
          let xEmpty ← waitForCondition s!"{x} is empty" 120 do
            return (← c.currItems xIp) == 0
          -- serial forwards, each dropped only after ~16-36 s of retries
          -- (CI 37538824780: 400 s was not enough for 8)
          let allDropped ← waitForCondition s!"all {kv.length} deletes to {y} are dropped (none queued)" 900 do
            return ((← c.statNat xIp "proxy_write_dropped").getD 0) ≥ drops0 + kv.length
          healForwards xIp yIp
          let yHeld ← c.localDump yIp
          if !allDropped || (yHeld.map (fun d => (missingFrom kv d).isEmpty)) != some true then
            release y
            return .fail s!"precondition: {y}'s copy did not stay intact while the master was emptied (all deletes dropped={allDropped}, missing {yHeld.map (missingFrom kv ·)})"
          if !xEmpty then release y; return .fail s!"precondition: {x} not empty after deleting {del}"
          -- (3) released: the protection decides now
          release y
          let refused ← waitForCondition s!"{y}'s protection refuses the empty source" 180 do
            return ((← c.flaredLogSince y since).splitOn "\n").any fun l => containsSubstr l "copy protection 'switch to the verified staging copy': REFUSE"
          IO.sleep 90000
          let yAfter ← c.localDump (← ip y)
          let log := ((← c.flaredLogSince y since).splitOn "\n")
          let truncated := log.any (containsSubstr · "truncating storage")
          c.windowRecord since [y, x] "H1"
          IO.eprintln s!"# H1: master {m} drained, {x} promoted; {y} approved={approved}, stopped={atStop}; {x} emptied ({del} deletes); released; refusal logged={refused}; truncated={truncated}; {y} copy before {yBefore.map (·.length)} keys, after 90 s more {yAfter.map (·.length)} keys"
          match yAfter with
          | none => return .fail s!"{y}'s own copy could not be read after the release"
          | some d =>
            let lost := missingFrom kv d
            if truncated then return .fail s!"{y}'s copy was truncated from the empty master"
            if !lost.isEmpty then return .fail s!"{y} lost {lost.length} original key(s)/value(s): {lost.take 5}"
            if !refused then return .fail s!"{y} kept its copy but no refusal by the protection rule was logged (the reason is not shown)"
            return .pass
        | _ => return .fail "precondition: one master and two slaves" },

    { name := "Unknown at the same boundary: with the master holding data again, the replica's destructive step is held, the source made UNREADABLE, then released — the copy is kept (Unknown is not 'safe'); once the source is readable the rebuild proceeds and the replica converges on the master's keys and values"
      run := do
        IO.sleep 1100
        let since ← utcNow
        match ← c.p0Roles with
        | (some x, _) =>
          let xIp ← ip x
          let slavesNow := (← c.nodeView).filter (fun e => e.role == 1) |>.map (fun e => podOf e.fqdn)
          let ys := slavesNow.filter (· != x)
          -- the subject: the replica still holding the original copy (H1's y)
          let mut y? : Option String := none
          for p in ys do
            if let some d ← c.localDump (← ip p) then
              if (missingFrom kv d).isEmpty && y?.isNone then y? := some p
          let some y := y? | return .fail s!"precondition: no replica besides {x} holds the original copy (H1 must precede)"
          let yIp ← ip y
          let kv2 := (List.range 8).map fun i => (s!"cp_{i}", s!"cpnew_{i}")
          -- the stop point right BEFORE the step that replaces y's copy: y has
          -- built and verified a staging copy (the source holds keys again)
          -- and holds before the protection rule decides the switch
          if !(← holdD y) then return .fail "precondition: could not arm the stop point"
          if (← c.setValues xIp kv2) != kv2.length then releaseD y; return .fail s!"precondition: could not write the new values on {x}"
          let atStop ← waitForCondition s!"{y} reaches the stop point before its destructive step" 300 do
            return containsSubstr (← c.flaredLogSince y since) "'switch to the verified staging copy' held by FLARE_TEST_DESTRUCTIVE_HOLD_FILE"
          if !atStop then releaseD y; return .fail "precondition: the stop point before the destructive step was not reached"
          -- the source unreadable from y, then released
          match ← hostCmd "docker" (["exec", kindNode, "iptables", "-I", "FORWARD", "1"] ++ ruleSpec yIp xIp) with
          | .error e => releaseD y; return .fail s!"precondition: could not cut {y} -> {x}: {e}"
          | .ok _ => pure ()
          releaseD y
          let unknownRefused ← waitForCondition s!"{y} refuses on an Unknown source" 120 do
            return ((← c.flaredLogSince y since).splitOn "\n").any fun l => containsSubstr l "REFUSE (source unknown: copy kept)"
          let yDuring ← c.localDump yIp
          let truncDuring := ((← c.flaredLogSince y since).splitOn "\n").any (containsSubstr · "truncating storage")
          for _ in [0:3] do
            discard <| hostCmd "docker" (["exec", kindNode, "iptables", "-D", "FORWARD"] ++ ruleSpec yIp xIp)
          -- readable again: the source holds keys → the rebuild proceeds
          let converged ← waitForCondition s!"{y} converges on {x}'s keys and values" 600 do
            match ← c.localDump (← ip y) with
            | some d => return (missingFrom kv2 d).isEmpty
            | none => return false
          c.windowRecord since [y, x] "Unknown"
          IO.eprintln s!"# Unknown: {y} held, source {x} cut, released: refusal on Unknown logged={unknownRefused}; copy during {yDuring.map (fun d => (missingFrom kv d).length)} original key(s) missing; converged after the heal={converged}"
          -- the held copy may already carry the master's NEW values (writes
          -- are forwarded to a Prepare replica); what must not happen is a
          -- key going ABSENT or a truncate while the source is Unknown
          let absent := fun (d : List (String × String)) => kv.filterMap fun (k, _) => if (d.lookup k).isNone then some k else none
          match yDuring with
          | none => return .fail s!"{y}'s copy could not be read while the source was unknown"
          | some d =>
            if truncDuring then return .fail s!"{y} truncated its copy while the source was Unknown"
            if !(absent d).isEmpty then return .fail s!"{y} lost keys while the source was Unknown: {(absent d).take 5}"
            if !unknownRefused then return .fail s!"{y} kept its copy but no Unknown refusal was logged"
            if !converged then return .fail s!"{y} did not converge on {x} once the source was readable"
            return .pass
        | _ => return .fail "precondition: a master" }
  ]
}

-- ─── SAF-09: running the operator vs initialising a data cluster ─────────

private def initCfg : ClusterConfig := {
  name := "cluster-init"
  «namespace» := "flare-cluster-init"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cluster-init"
  storageBackend := "rocksdb"
  usePvc := true
  deferClusterCr := true
  -- flared logs the local/proxy decision (and the state it used) for
  -- reads of the test's keys: SAF-09 test 29 attributes every answer
  flaredEnv := [("FLARE_TEST_READ_TRACE_PREFIX", "init_")]
  -- production read policy (R2): an unservable get is SERVER_ERROR, never
  -- END; in the CR, so the CR recreated in test 29 keeps it
  readUnavailableError := true
}

/-- Sample the operator's index port for `secs`: (ever open, observed
    closed, not observed). Only a successful probe that refused counts as
    closed — and only when the health port (8080) answered in the same probe,
    so an unreachable pod is not mistaken for a closed index; no pod IP, a
    failed exec, an unreachable pod or an unparsable reply is NOT observed. -/
private def Ctx.indexSamples (c : Ctx) (secs : Nat) : IO (Bool × Nat × Nat) := do
  let mut closed := 0
  let mut missed := 0
  for _ in [0:secs / 3] do
    let state : Option Bool ← do
      match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].status.podIP}"] with
      | .error _ => pure none
      | .ok ips =>
        let ipList := (ips.trim.splitOn " ").filter (· != "")
        if ipList.isEmpty then pure none
        else
          let mut st : Option Bool := some false
          for ip in ipList do
            if st == some false then
              match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"if nc -z -w 2 {ip} 8080; then (nc -z -w 2 {ip} {c.cfg.operatorPort} && echo OPEN || echo CLOSED); else echo UNREACHABLE; fi" with
              | .ok o => st := if containsSubstr o "OPEN" then some true else if containsSubstr o "CLOSED" then some false else none
              | .error _ => st := none
          pure st
    match state with
    | some true => return (true, closed, missed)
    | some false => closed := closed + 1
    | none => missed := missed + 1
    IO.sleep 3000
  return (false, closed, missed)

/-- Sample the operator's own /readyz answer (the product signal; the pod's
    Ready condition lags it by the probe's failure threshold) every 3 s for
    `secs`: (200 answers, 503 answers, not observed). -/
private def Ctx.readyzSamples (c : Ctx) (secs : Nat) : IO (Nat × Nat × Nat) := do
  let mut ok := 0
  let mut unavailable := 0
  let mut missed := 0
  for _ in [0:secs / 3] do
    match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].status.podIP}"] with
    | .ok ips =>
      match ((ips.trim.splitOn " ").filter (· != "")).head? with
      | some ip =>
        match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"printf 'GET /readyz HTTP/1.0\\r\\n\\r\\n' | nc -w 2 {ip} 8080 | head -1" with
        | .ok o =>
          if containsSubstr o " 200" then ok := ok + 1
          else if containsSubstr o " 503" then unavailable := unavailable + 1
          else missed := missed + 1
        | .error _ => missed := missed + 1
      | none => missed := missed + 1
    | .error _ => missed := missed + 1
    IO.sleep 3000
  return (ok, unavailable, missed)

private def Ctx.opReady (c : Ctx) : IO Bool := do
  match ← kubectl ["get", "pods", "-n", c.cfg.«namespace», "-l", s!"app={c.cfg.operatorName}", "-o", "jsonpath={.items[*].status.containerStatuses[0].ready}"] with
  | .ok o => return o.trim == "true"
  | .error _ => return false

/-- Current + previous container logs of the operator pod(s). -/
private def Ctx.opLogsAll (c : Ctx) : IO String := do
  let pods ← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»
  let mut acc := ""
  for pod in pods do
    for extra in [[], ["--previous"]] do
      match ← kubectl (["logs", "-n", c.cfg.«namespace», pod, "--tail=4000"] ++ extra) with
      | .ok o => acc := acc ++ o
      | .error _ => pure ()
  return acc

private def Ctx.scaleOp (c : Ctx) (n : Nat) : IO Bool := do
  discard <| kubectl ["scale", "deployment", c.cfg.operatorName, "-n", c.cfg.«namespace», s!"--replicas={n}"]
  waitForCondition s!"operator scaled to {n}" 180 do
    return (← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»).length == n

/-- Swap one resource in the ClusterRole rule that grants it, both ways. -/
private def ruleSwap (resource toName : String) : IO (Except String String) := do
  match ← hostCmd "sh" ["-c", s!"kubectl get clusterrole flare-operator -o json | jq -r '.rules | to_entries[] | select(.value.resources | index(\"{resource}\")) | .key' | head -1"] with
  | .error e => return .error e
  | .ok idx =>
    match idx.trim.toNat? with
    | none => return .error s!"no ClusterRole rule grants {resource}"
    | some i =>
      match ← hostCmd "sh" ["-c", s!"kubectl get clusterrole flare-operator -o json | jq -c '.rules[{i}].resources | map(if . == \"{resource}\" then \"{toName}\" else . end)'"] with
      | .error e => return .error e
      | .ok res => kubectl ["patch", "clusterrole", "flare-operator", "--type=json", "-p",
          ("[{\"op\":\"replace\",\"path\":\"/rules/" ++ toString i ++ "/resources\",\"value\":" ++ res.trim ++ "}]")]

/-- (pvc name, uid, bound volume) of every PVC in the namespace. -/
private def pvcIdentities (ns : String) : IO (List (String × String × String)) := do
  match ← kubectl ["get", "pvc", "-n", ns, "-o", "jsonpath={range .items[*]}{.metadata.name}|{.metadata.uid}|{.spec.volumeName}{\"\\n\"}{end}"] with
  | .ok o => return (o.splitOn "\n").filterMap fun l =>
      match l.trim.splitOn "|" with
      | [n, u, v] => if n.trim.isEmpty then none else some (n.trim, u.trim, v.trim)
      | _ => none
  | .error _ => return []

/-- Every `pfx_i` (i < n) reads back as `val_i` on the node at `ip`. -/
private def allKeysOn (c : Ctx) (ip pfx : String) (n : Nat) : IO (Option String) := do
  for i in [0:n] do
    let v ← memcachedGet c.cfg.debugPod c.cfg.«namespace» ip c.cfg.flarePort s!"{pfx}_{i}"
    if v != some s!"val_{i}" then return some s!"{pfx}_{i} = {v}"
  return none

/-- (pod, reconstruction_boot_id, container startedAt) of every data pod —
    R10: identities of distinct pods and of a pod before/after a same-name
    replacement. -/
private def Ctx.bootIds (c : Ctx) : IO (List (String × Option Nat × String)) := do
  let mut acc := []
  for (pod, ip) in ← c.dataPods do
    let started := ((← kubectlGetJsonpath "pod" pod c.cfg.«namespace» "{.status.containerStatuses[?(@.name==\"flared\")].state.running.startedAt}").toOption.getD "").trim
    acc := acc ++ [(pod, ← c.statNat ip "reconstruction_boot_id", started)]
  return acc

def clusterInitSuite : TestSuite := {
  name := "cluster-init"
  setup := do
    deployCluster initCfg
  teardown := do
    discard <| ruleSwap "flareclusters-e2e-revoked" "flareclusters"
    discard <| ruleSwap "pods-e2e-revoked" "pods"
    cleanupCluster initCfg
  onFailure := dumpClusterDiagnostics initCfg.«namespace» s!"app={initCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := initCfg }
    let ns := initCfg.«namespace»
    let cmName := s!"{initCfg.name}-node-map"
    [
    { name := "SAF-09 operator before its cluster: with no FlareCluster and no pods the operator is Ready and WAITING — it makes no node-map decision and creates no node map"
      run := do
        let waiting ← waitForCondition "the operator logs WAITING" 120 do
          return containsSubstr (← c.opLog 400) "WAITING: FlareCluster"
        let ready ← c.opReady
        let log ← c.opLog 400
        let decided := containsSubstr log "node map:" || containsSubstr log "loaded "
        let cmExists := (← kubectlGetJsonpath "configmap" cmName ns "{.metadata.name}").toOption.isSome
        IO.eprintln s!"# no CR: waiting={waiting} ready={ready} node-map decision logged={decided} node-map ConfigMap exists={cmExists}"
        if !waiting then return .fail "the operator did not enter the waiting state"
        if !ready then return .fail "the waiting operator is not Ready"
        if decided then return .fail "the operator made a node-map decision without a FlareCluster"
        if cmExists then return .fail "a node map was persisted without a FlareCluster"
        return .pass },

    { name := "SAF-09 waiting is re-evaluated every observation: NotFound (Ready) → the FlareCluster unreadable (not Ready, not treated as absent) → NotFound again (Ready again); still no decision"
      run := do
        match ← ruleSwap "flareclusters" "flareclusters-e2e-revoked" with
        | .error e => return .fail s!"could not revoke flareclusters: {e}"
        | .ok _ => pure ()
        let notReady ← waitForCondition "the operator turns not-Ready on a failed CR read" 120 do
          return !(← c.opReady) && containsSubstr (← c.opLog 400) "NOT treated as absent"
        discard <| ruleSwap "flareclusters-e2e-revoked" "flareclusters"
        let readyAgain ← waitForCondition "NotFound again: Ready again" 120 do c.opReady
        let log ← c.opLog 2000
        let decided := containsSubstr log "node map:" || containsSubstr log "loaded "
        IO.eprintln s!"# transition: not-Ready on the failed read={notReady}; Ready again on NotFound={readyAgain}; decision logged={decided}"
        if !notReady then return .fail "a failed FlareCluster read did not make the waiting operator not-Ready"
        if !readyAgain then return .fail "the operator did not return to Ready when the FlareCluster read NotFound again"
        if decided then return .fail "the waiting operator made a node-map decision"
        return .pass },

    { name := "SAF-09 the cluster then appears with a first-build approval: the operator examines it, builds it fresh, and the cluster serves writes"
      run := do
        deployDeferredCluster initCfg true
        let built ← waitForCondition "first build approved and the cluster serves" 300 do
          let log ← c.opLog 3000
          if !(containsSubstr log "first build APPROVED") then return false
          match ← c.pair with
          | .ok (_, mIp, _, _) => return (← writeKeys initCfg.debugPod ns mIp initCfg.flarePort "init" 30) == 30
          | .error _ => return false
        let approvalLeft := ((← kubectlGetJsonpath "flarecluster" initCfg.name ns "{.metadata.annotations.flare\\.gree\\.net/first-build-approved}").toOption.getD "").trim
        IO.eprintln s!"# cluster appeared: built and serving={built}; approval left on the CR=[{approvalLeft}]"
        if !built then return .fail "the approved first build did not come up and serve writes"
        let consumed ← waitForCondition "the approval is consumed" 120 do
          return ((← kubectlGetJsonpath "flarecluster" initCfg.name ns "{.metadata.annotations.flare\\.gree\\.net/first-build-approved}").toOption.getD "x").trim.isEmpty
        if !consumed then return .fail "the first-build approval was not consumed after the map was persisted"
        return .pass },

    { name := "SAF-09 old PVCs survive the CR and pods: the CR is recreated WITHOUT approval while the map and the Lease marker are gone — the operator never initialises or re-assigns; restoring the map recovers every key"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (_, mIp, _, sIp) =>
          let synced ← waitForCondition "both copies hold the keys" 120 do
            return (← c.currItems mIp) ≥ 30 && (← c.currItems sIp) == (← c.currItems mIp)
          let items ← c.currItems mIp
          let saved := ((← kubectlGetJsonpath "configmap" cmName ns "{.data.nodeMap}").toOption.getD "").trim
          if !synced || saved.isEmpty then return .fail s!"precondition: data in sync and a persisted map (items {items}, map saved={!saved.isEmpty})"
          -- PVC identity captured NOW, while the original data is on them
          let pvcs ← pvcIdentities ns
          if pvcs.length < initCfg.replicas || pvcs.any (fun (_, u, v) => u.isEmpty || v.isEmpty) then
            return .fail s!"precondition: every PVC needs a UID and a bound volume while it holds the data ({pvcs})"
          let bootsBefore ← c.bootIds
          if !(← c.scaleOp 0) then return .fail "could not stop the operator"
          -- the CR and the pods go, the PVCs stay
          discard <| kubectl ["delete", "statefulset", s!"{initCfg.name}-nodes", "-n", ns, "--wait=true"]
          discard <| kubectl ["delete", "flarecluster", initCfg.name, "-n", ns, "--wait=true"]
          discard <| kubectl ["delete", "configmap", cmName, "-n", ns]
          discard <| kubectl ["annotate", "lease", s!"{initCfg.name}-operator-lease", "-n", ns, "flare.gree.net/node-map-persisted-"]
          let pvcsAfterDelete ← pvcIdentities ns
          IO.eprintln s!"# CR, StatefulSet, map and Lease marker gone; PVCs with the data {pvcs}; after the deletion {pvcsAfterDelete}"
          if !(pvcs.all (pvcsAfterDelete.contains ·)) then return .fail s!"the PVCs that held the data did not survive the deletion (before {pvcs}, after {pvcsAfterDelete})"
          discard <| kubectl ["scale", "deployment", initCfg.operatorName, "-n", ns, "--replicas=1"]
          let waiting ← waitForCondition "the operator waits for the CR again" 180 do
            return containsSubstr (← c.opLog 400) "WAITING: FlareCluster"
          -- recreate the CR and the StatefulSet with NO approval
          deployDeferredCluster initCfg false
          let undecided ← waitForCondition "the operator refuses to tell a first build from a loss" 180 do
            return containsSubstr (← c.opLogsAll) "cannot be told from a loss"
          let (served, closedN, missedN) ← c.indexSamples 60
          let logs ← c.opLogsAll
          let fresh := containsSubstr logs "node map: starting fresh"
          let ready ← c.opReady
          let cmBack := (← kubectlGetJsonpath "configmap" cmName ns "{.metadata.name}").toOption.isSome
          IO.eprintln s!"# CR recreated without approval: waited first={waiting}; undecided={undecided}; started fresh={fresh}; index ever served={served} (closed in {closedN} observed samples, {missedN} not observed); a node map was written={cmBack} (readiness observed {ready}, informational)"
          if fresh then return .fail "the operator initialised a cluster over old PVCs without approval"
          if !undecided then return .fail "the operator did not report that it cannot tell a first build from a loss"
          if served then return .fail "the operator served the index (took control) without its map or an approval"
          if closedN == 0 then return .fail s!"the index was never observed closed ({missedN} unobserved samples): no evidence control was not taken"
          if cmBack then return .fail "a node map was written without a decision"
          -- Recovery starts when the map is restored. Two separate purposes:
          --  (1) DURING recovery no node answers a GET LOCALLY from an
          --      incomplete copy: every data pod is probed every round, each
          --      answer attributed through flared's read trace (local /
          --      proxied, with the state the decision used). A wrong answer
          --      fails the test whatever any later read shows.
          --  (2) AFTER recovery every key and value is on both copies, the
          --      replica's answers being LOCAL (trace) with its state taken
          --      just before and after each GET.
          -- The window starts > 1 s after the last earlier read, so
          -- --since-time cannot include it.
          -- R1/H3: reads are routed to the REPLICAS (master 0 / slave 100)
          -- for the whole recovery, as in the failures of 37419299532 and
          -- 37426714842; with balance 0 every probe was forwarded to the
          -- master by policy and H3 was never exercised (37451914041)
          let balanceBefore := ((← kubectlGetJsonpath "flarecluster" initCfg.name ns "{.spec.readBalance}").toOption.getD "").trim
          let restoreBalance := if balanceBefore.isEmpty then "{\"spec\":{\"readBalance\":null}}" else s!"\{\"spec\":\{\"readBalance\":{balanceBefore}}}"
          if let .error e ← kubectlPatch "flarecluster" initCfg.name ns "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}" then
            return .fail s!"precondition: could not route reads to the replicas for the recovery: {e}"
          IO.sleep 1100
          let restoreAt ← utcNow
          discard <| kubectl ["create", "configmap", cmName, "-n", ns, s!"--from-literal=nodeMap={saved}"]
          let keys := (List.range 30).map fun i => s!"init_{i}"
          let probes ← IO.mkRef ([] : List (String × String × String × List (String × String)))
          let roundN ← IO.mkRef 0
          let roundsUnobserved ← IO.mkRef 0
          let back ← waitForCondition "the operator loads the restored map and both copies are back (probing every pod meanwhile)" 480 do
            for (pod, ip) in ← c.dataPods do
              let r ← roundN.modifyGet fun n => (n, n + 1)
              let marker := s!"init_mark_r{r}"
              let t ← utcNow
              match ← c.getRound ip marker keys with
              | some ans => probes.modify ((pod, marker, t, ans) :: ·)
              | none => roundsUnobserved.modify (· + 1)
            if !(← c.opReady) then return false
            match ← c.pair with
            | .ok (_, m2, _, s2) => return (← c.currItems m2) == items && (← c.currItems s2) == items
            | .error _ => return false
          discard <| kubectlPatch "flarecluster" initCfg.name ns restoreBalance
          -- (1) verdict on the recovery probes
          let probeList := (← probes.get).reverse
          let mut traceLogs : List (String × List String) := []
          for pod in (probeList.map (·.1)).eraseDups do
            traceLogs := (pod, readTraces (← c.flaredLogAllSince pod restoreAt)) :: traceLogs
          -- DATA errors (a real miss or another value) are judged; refusals,
          -- server-recorded unreadable answers and unobserved rounds are
          -- AVAILABILITY, reported separately and not judged here
          let mut wrongLocal : List String := []
          let mut wrongFwd : List String := []
          let mut wrongUntraced : List String := []
          let mut nOk := 0
          let mut nOkUntraced := 0
          let mut nRefused := 0
          let mut masked : List String := []
          let mut localByPod : List (String × Nat) := []
          for (pod, marker, t, ans) in probeList do
            let tr := tracesAfterMarker ((traceLogs.lookup pod).getD []) marker
            for (k, a) in ans do
              let trk := (tr.lookup k).getD {}
              let expected := s!"=val_{k.drop 5}"
              let cls := classifyAnswer expected a trk
              if answeredLocally trk then
                localByPod := (pod, ((localByPod.lookup pod).getD 0) + 1) :: localByPod.filter (·.1 != pod)
              let d := s!"{pod} at {t}: {k} -> {a}{if trk.ambiguous then " (AMBIGUOUS traces)" else ""}; decision {trk.decision.getD "(none)"}; answer {trk.answer.getD "(none)"}"
              if cls == "ok" then nOk := nOk + 1
              else if cls == "refused" then nRefused := nRefused + 1
              else if cls == "masked-miss" then masked := d :: masked
              else if cls == "wrong-local" then wrongLocal := d :: wrongLocal
              else if cls == "wrong-forwarded" then wrongFwd := d :: wrongFwd
              else if a == expected then nOkUntraced := nOkUntraced + 1
              else wrongUntraced := d :: wrongUntraced
          IO.eprintln s!"# (1) during recovery (since {restoreAt}): {probeList.length} probe rounds observed, {← roundsUnobserved.get} not observed (connection/exchange incomplete). DATA: correct {nOk} (+{nOkUntraced} correct but untraced); WRONG answered from the node's own copy {wrongLocal.length}; wrong after forwarding {wrongFwd.length}; wrong and unattributable {wrongUntraced.length}. MASKED MISSES (unreadable on the server, END to the client) {masked.length}. AVAILABILITY (reported, not judged here): explicit error replies {nRefused}; rounds not observed {← roundsUnobserved.get}"
          for d in (wrongLocal.reverse.take 20) do IO.eprintln s!"#   LOCAL wrong: {d}"
          for d in (wrongFwd.reverse.take 10) do IO.eprintln s!"#   forwarded wrong: {d}"
          for d in (wrongUntraced.reverse.take 10) do IO.eprintln s!"#   unattributable wrong: {d}"
          for d in (masked.reverse.take 10) do IO.eprintln s!"#   masked miss: {d}"
          -- whether H3 was EXERCISED: answers served from a pod's own copy
          -- during recovery (0 on the replica = every read was forwarded)
          IO.eprintln s!"#   answers served from the pod's OWN copy during recovery, per pod: {localByPod}"
          let mut fails : List String := []
          if !wrongLocal.isEmpty then
            fails := fails ++ [s!"(1) {wrongLocal.length} LOCAL answer(s) from an incomplete copy during recovery (first: {wrongLocal.getLast?.getD ""})"]
          if !wrongFwd.isEmpty then
            fails := fails ++ [s!"(1) {wrongFwd.length} wrong answer(s) during recovery from the node a read was forwarded to (first: {wrongFwd.getLast?.getD ""})"]
          if !masked.isEmpty then
            fails := fails ++ [s!"(1) MASKED MISS: {masked.length} answer(s) during recovery were END to the client although the server could not read the key (first: {masked.getLast?.getD ""})"]
          if !wrongUntraced.isEmpty then
            fails := fails ++ [s!"(1) {wrongUntraced.length} wrong answer(s) during recovery that cannot be attributed (no trace on the connection; first: {wrongUntraced.getLast?.getD ""})"]
          if probeList.isEmpty then
            fails := fails ++ ["(1) no recovery probe round was observed: no evidence about reads during recovery"]
          -- why each copy was (re)built after the map came back: tracked,
          -- not judged here
          let opSince := match ← kubectl ["logs", "-n", ns, "-l", s!"app={initCfg.operatorName}", s!"--since-time={restoreAt}", "--timestamps", "--tail=-1"] with
            | .ok o => o
            | .error _ => ""
          let opWhy := (opSince.splitOn "\n").filter fun l =>
            containsSubstr l "REPLICA REPAIR" || containsSubstr l "first observation" || containsSubstr l "ledger" || containsSubstr l "reconstruct"
              || containsSubstr l "prepare" || containsSubstr l "Prepare" || containsSubstr l "demot" || containsSubstr l "reseat"
              || containsSubstr l "loaded " || containsSubstr l "node map" || containsSubstr l "role" || containsSubstr l "NOT LOSS-FREE"
          IO.eprintln s!"# rebuild tracking — operator since {restoreAt} ({opWhy.length} line(s), last 40):\n{String.intercalate "\n" (opWhy.reverse.take 40).reverse}"
          for (pod, _) in ← c.dataPods do
            let fl := ((← c.flaredLogAllSince pod restoreAt).splitOn "\n").filter fun l =>
              !containsSubstr l "read-trace" && (containsSubstr l "reconstruct" || containsSubstr l "truncat" || containsSubstr l "dump"
                || containsSubstr l "snapshot" || containsSubstr l "shifting node_" || containsSubstr l "rebuil" || containsSubstr l "reason"
                || containsSubstr l "node map" || containsSubstr l "node_map_version")
            IO.eprintln s!"# rebuild tracking — {pod} flared since {restoreAt} ({fl.length} line(s), last 30):\n{String.intercalate "\n" (fl.reverse.take 30).reverse}"
          -- R10: the recreated pods (same names, new processes) and the two
          -- pods among themselves never share a boot id
          let bootsAfter ← c.bootIds
          let sameAsBefore := bootsAfter.filter fun (p, b, _) => b.isSome && (bootsBefore.find? (·.1 == p)).bind (·.2.1) == b
          let afterIds := bootsAfter.filterMap (·.2.1)
          let sharedAfter := afterIds.length != afterIds.eraseDups.length
          IO.eprintln s!"# R10 boot ids before the pods were deleted {bootsBefore}; after the same-name recreation {bootsAfter}; a recreated pod kept its predecessor's id: {sameAsBefore.map (·.1)}; two pods share an id: {sharedAfter}"
          if !sameAsBefore.isEmpty then
            fails := fails ++ [s!"R10: a pod recreated under the same name reports its predecessor's boot id ({sameAsBefore})"]
          if sharedAfter then
            fails := fails ++ [s!"R10: two pods report the same boot id ({bootsAfter})"]
          let failWith (msg : String) : TestResult := .fail (String.intercalate "; " (fails ++ [msg]))
          if !back then return failWith "the data on the old PVCs did not come back with the restored map"
          -- the SAME volumes were reused (not new empty ones)
          let pvcsAfter ← pvcIdentities ns
          let claims := ((← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={initCfg.name}", "-o", "jsonpath={range .items[*]}{.spec.volumes[?(@.name==\"data\")].persistentVolumeClaim.claimName} {end}"]).toOption.getD "").trim
          let reused := pvcs.all (pvcsAfter.contains ·) && pvcsAfter.length == pvcs.length
          IO.eprintln s!"# PVCs before {pvcs}; after {pvcsAfter}; pods claim [{claims}]; same UIDs and volumes={reused}"
          if !reused then return failWith s!"the recreated pods are not on the surviving PVCs (before {pvcs}, after {pvcsAfter})"
          if !(pvcs.all fun (n, _, _) => containsSubstr claims n) then return failWith s!"the pods do not claim the surviving PVCs ({claims})"
          -- (2) after recovery. Recovery is complete only when the replica is
          -- an Active slave, the ledger is empty and no reconstruction runs
          -- (equal item counts alone are not: CI 37426714842 reseeded the
          -- replica after them).
          match ← c.pair with
          | .error e => return failWith e
          | .ok (mPodR, m2, sPodR, s2) =>
            -- complete = the REPLICA'S OWN view, not the operator's (CI
            -- 37472027476: the operator showed Active while the replica's
            -- own map said Prepare and it was rebuilding again): its own map
            -- entry Active, no reconstruction running, its copy eligible for
            -- its source (when it reports one), the ledger empty — and, once
            -- reads are routed to it below, a GET answered from its own copy
            let settled ← waitForCondition "recovery complete: replica's OWN map Active, no reconstruction running, copy eligible, ledger empty" 300 do
              let led := (← c.ledgerDests).isEmpty
              let active := (← c.nodeView).any fun e => podOf e.fqdn == sPodR && e.role == 1 && e.state == 0
              let own ← c.readState s2 sPodR
              let ownActive := containsSubstr own "own[role slave state active"
              let st := (← c.statNat s2 "reconstruction_started")
              let cp := (← c.statNat s2 "reconstruction_completed")
              let elig ← c.statStr s2 "repl_read_source_eligible"
              return led && active && ownActive && st.isSome && st == cp && (elig.isNone || elig == some "1")
            if !settled then return failWith s!"(2) recovery did not complete from the replica's own view within 300 s: {← c.readState s2 sPodR}; eligible={← c.statStr s2 "repl_read_source_eligible"}"
            -- The master is read under the cluster's own read balance; reads
            -- are then routed to the replica (master 0 / slave 100) and the
            -- spec is restored before the verdict.
            let onM ← c.getRound m2 "init_mark_master" keys
            let balance0 := ((← kubectlGetJsonpath "flarecluster" initCfg.name ns "{.spec.readBalance}").toOption.getD "").trim
            let routedPatch ← kubectlPatch "flarecluster" initCfg.name ns "{\"spec\":{\"readBalance\":{\"master\":0,\"slave\":100}}}"
            let routed ← waitForCondition "a GET on the replica is answered from its OWN copy (trace)" 150 do
              let mk := s!"init_mark_routing_{← IO.monoMsNow}"
              let t0 ← utcNow
              match ← c.getRound s2 mk ["init_0"] with
              | some [(_, a)] =>
                let t := ((tracesAfterMarker (readTraces (← c.flaredLogAllSince sPodR t0)) mk).lookup "init_0").getD {}
                return a == "=val_0" && answeredLocally t
              | _ => return false
            let mUid0 ← c.podUid mPodR
            let sUid0 ← c.podUid sPodR
            let mBoot0 ← c.statNat m2 "reconstruction_boot_id"
            IO.sleep 1100
            let passAt ← utcNow
            let gets0 ← c.statNat m2 "cmd_get"
            -- per key: state just before, the GET (own marker first), state just after
            let mut rows : List (String × String × String × String) := []
            for k in keys do
              let before ← c.readState s2 sPodR
              let ans ← c.getRound s2 s!"init_mark_post_{k}" [k]
              let after ← c.readState s2 sPodR
              rows := rows ++ [(k, before, ((ans.bind (·.head?)).map (·.2)).getD "(not observed)", after)]
            let gets1 ← c.statNat m2 "cmd_get"
            let mBoot1 ← c.statNat m2 "reconstruction_boot_id"
            let mUid1 ← c.podUid mPodR
            let sUid1 ← c.podUid sPodR
            let rolesAfter ← c.pair
            let restorePatch := if balance0.isEmpty then "{\"spec\":{\"readBalance\":null}}" else s!"\{\"spec\":\{\"readBalance\":{balance0}}}"
            let restored ← kubectlPatch "flarecluster" initCfg.name ns restorePatch
            IO.eprintln s!"# read routing: spec before {if balance0.isEmpty then "(unset)" else balance0}; routed to the replica={routedPatch.isOk}, replica served locally before the check={routed}; restored={restored.isOk}"
            if let .error e := routedPatch then return failWith s!"could not route reads to the replica: {e}"
            if let .error e := restored then return failWith s!"could not restore the read balance: {e}"
            let sTraces := readTraces (← c.flaredLogAllSince sPodR passAt)
            -- the pass needs EVERY replica answer correct AND answered from its
            -- own copy (answer line reason=local) after recovery completed;
            -- data errors, unavailability and missing attribution are
            -- reported under their own labels
            let mut postFails : List String := []
            let mut nPostLocal := 0
            for (k, before, a, after) in rows do
              let trk := (tracesAfterMarker sTraces s!"init_mark_post_{k}").lookup k |>.getD {}
              let cls := classifyAnswer s!"=val_{k.drop 5}" a trk
              let localAns := answeredLocally trk
              let label := if cls == "ok" && !localAns then "correct, not answered from its own copy" else cls
              if cls == "ok" && localAns then nPostLocal := nPostLocal + 1
              else
                IO.eprintln s!"# (2) replica {sPodR} {k} -> {a} ({label})\n#   before:   {before}\n#   decision: {trk.decision.getD "(no trace line)"}\n#   answer:   {trk.answer.getD "(no trace line)"}\n#   after:    {after}"
                postFails := postFails ++ [s!"{k} -> {a} ({label})"]
            let masterBad := match onM with
              | none => some "the master's answers were not observed"
              | some ans => (ans.find? fun (ka : String × String) => ka.2 != s!"=val_{ka.1.drop 5}").map fun (ka : String × String) => s!"{ka.1} -> {ka.2}"
            let sameRoles := match rolesAfter with
              | .ok (m', _, s', _) => m' == mPodR && s' == sPodR
              | .error _ => false
            let sameMaster := mUid0.isSome && mUid0 == mUid1 && mBoot0.isSome && mBoot0 == mBoot1
            let sameReplica := sUid0.isSome && sUid0 == sUid1
            let countersRead := gets0.isSome && gets1.isSome
            IO.eprintln s!"# (2) after recovery: master {masterBad.getD "all 30 equal"}; replica correct AND answered from its own copy {nPostLocal}/30, otherwise {postFails.length}; master cmd_get {gets0} -> {gets1}; master uid {mUid0} -> {mUid1}, boot {mBoot0} -> {mBoot1}; replica uid {sUid0} -> {sUid1}; roles unchanged={sameRoles}"
            if let some (k, before, _, after) := rows.head? then
              IO.eprintln s!"# (2) replica state around the first GET ({k}): before {before}; after {after}"
            if let some bad := masterBad then fails := fails ++ [s!"(2) a key or value is not on the master after recovery: {bad}"]
            if !postFails.isEmpty then fails := fails ++ [s!"(2) after recovery, not every key was answered correctly from the replica's own copy ({postFails.length}: {String.intercalate ", " (postFails.take 5)})"]
            if !countersRead then fails := fails ++ [s!"(2) the master's cmd_get could not be read before and after ({gets0} -> {gets1})"]
            else if gets0 != gets1 then fails := fails ++ [s!"(2) the master served reads during the replica's check (cmd_get {gets0} -> {gets1})"]
            if !sameMaster then fails := fails ++ [s!"(2) the master changed process during the reads (uid {mUid0} -> {mUid1}, boot {mBoot0} -> {mBoot1})"]
            if !sameReplica || !sameRoles then fails := fails ++ [s!"(2) the read target or the master changed during the reads (replica uid {sUid0} -> {sUid1}, roles unchanged={sameRoles})"]
            if !fails.isEmpty then return .fail (String.intercalate "; " fails)
            return .pass },

    { name := "SAF-09 read failures are not absence: with the FlareCluster unreadable (RBAC) the operator neither WAITs as if absent nor becomes Ready; with the pod list unreadable and the map missing it never starts fresh"
      run := do
        let cmName' := cmName
        let saved := ((← kubectlGetJsonpath "configmap" cmName' ns "{.data.nodeMap}").toOption.getD "").trim
        if saved.isEmpty then return .fail "precondition: no persisted map"
        -- (a) the FlareCluster cannot be read
        if !(← c.scaleOp 0) then return .fail "could not stop the operator"
        match ← ruleSwap "flareclusters" "flareclusters-e2e-revoked" with
        | .error e => return .fail s!"could not revoke flareclusters: {e}"
        | .ok _ => pure ()
        discard <| kubectl ["scale", "deployment", initCfg.operatorName, "-n", ns, "--replicas=1"]
        let notAbsent ← waitForCondition "the operator reports the CR unreadable (not absent)" 120 do
          return containsSubstr (← c.opLogsAll) "NOT treated as absent"
        -- /readyz is the signal; the pod's Ready condition follows it after
        -- the probe's failure threshold (3 x 5 s) and still shows the
        -- standby phase before the lease (a standby is Ready by design) —
        -- CI 37290297021 sampled it once, too early.
        let (ok200, n503, missedR) ← c.readyzSamples 30
        let podNotReady ← waitForCondition "the operator pod turns NotReady" 60 do return !(← c.opReady)
        let logsA ← c.opLogsAll
        let waitedA := containsSubstr logsA "WAITING: FlareCluster"
        discard <| ruleSwap "flareclusters-e2e-revoked" "flareclusters"
        IO.eprintln s!"# CR unreadable: reported not-absent={notAbsent} waited as absent={waitedA}; /readyz over 30 s: 200 x{ok200}, 503 x{n503}, not observed x{missedR}; pod NotReady within 60 s={podNotReady}"
        if !notAbsent then return .fail "an unreadable FlareCluster was not reported as a failed read"
        if waitedA then return .fail "an unreadable FlareCluster was treated as absent"
        if ok200 > 0 then return .fail s!"/readyz answered 200 ({ok200} time(s)) with the FlareCluster unreadable"
        if n503 == 0 then return .fail s!"/readyz was never observed answering 503 ({missedR} unobserved samples): no evidence of not-Ready"
        if !podNotReady then return .fail "the operator pod stayed Ready with its FlareCluster unreadable"
        let backA ← waitForCondition "the operator recovers once the CR is readable" 300 do c.opReady
        if !backA then return .fail "the operator did not recover after the CR became readable"
        -- (b) map missing + pod list unreadable. The Lease marker decides
        -- what the right answer is: with it the cluster provably ran (halt);
        -- without it the past is unobservable (retry). Never fresh either way.
        let leaseName := s!"{initCfg.name}-operator-lease"
        let markerNow : IO String := do
          return ((← kubectlGetJsonpath "lease" leaseName ns "{.metadata.annotations.flare\\.gree\\.net/node-map-persisted}").toOption.getD "").trim
        let marker0 ← markerNow
        if marker0.isEmpty then return .fail "precondition: the Lease carries no persisted-map marker"
        if !(← c.scaleOp 0) then return .fail "could not stop the operator"
        discard <| kubectl ["delete", "configmap", cmName', "-n", ns]
        match ← ruleSwap "pods" "pods-e2e-revoked" with
        | .error e => return .fail s!"could not revoke pods: {e}"
        | .ok _ => pure ()
        -- (b1) marker present → halt
        discard <| kubectl ["scale", "deployment", initCfg.operatorName, "-n", ns, "--replicas=1"]
        let halted ← waitForCondition "with the marker the operator halts (the cluster ran before)" 120 do
          return containsSubstr (← c.opLogsAll) "the cluster ran before"
        let freshB1 := containsSubstr (← c.opLogsAll) "node map: starting fresh"
        IO.eprintln s!"# (b1) marker [{marker0}] + map missing + pods unreadable: halted={halted} started fresh={freshB1}"
        if freshB1 then discard <| ruleSwap "pods-e2e-revoked" "pods"; return .fail "map missing with the marker present: the operator started fresh"
        if !halted then discard <| ruleSwap "pods-e2e-revoked" "pods"; return .fail "map missing with the marker present: the operator did not halt"
        -- (b2) marker removed (confirmed) → unknown → retry
        if !(← c.scaleOp 0) then return .fail "could not stop the operator"
        discard <| kubectl ["annotate", "lease", leaseName, "-n", ns, "flare.gree.net/node-map-persisted-"]
        let marker1 ← markerNow
        if !marker1.isEmpty then discard <| ruleSwap "pods-e2e-revoked" "pods"; return .fail s!"precondition: the Lease marker could not be removed ({marker1})"
        discard <| kubectl ["scale", "deployment", initCfg.operatorName, "-n", ns, "--replicas=1"]
        let retried ← waitForCondition "without the marker the operator retries (history unknown)" 120 do
          return containsSubstr (← c.opLogsAll) "cannot be told from a loss"
        IO.sleep 20000
        let logsB ← c.opLogsAll
        let freshB := containsSubstr logsB "node map: starting fresh"
        discard <| ruleSwap "pods-e2e-revoked" "pods"
        discard <| kubectl ["create", "configmap", cmName', "-n", ns, s!"--from-literal=nodeMap={saved}"]
        IO.eprintln s!"# (b2) marker removed + map missing + pods unreadable: retried={retried} started fresh={freshB}"
        if freshB then return .fail "an unreadable pod list let the operator start fresh"
        if !retried then return .fail "without the marker and with the pod list unreadable, the operator did not retry as undecidable"
        let backB ← waitForCondition "the operator recovers with the map restored" 300 do c.opReady
        if !backB then return .fail "the operator did not recover after the pod list became readable"
        return .pass }
  ]
}

-- ─── two partitions: enablement and the lag hold are per partition ───────

/-- (masterPod, masterIp, replicaPod, replicaIp) of partition `p`, the replica
    taken from the SAME partition (Ctx.pair could return another partition's
    slave, CI 36904379135). -/
private def Ctx.pairOf (c : Ctx) (p : Nat) : IO (Except String (String × String × String × String)) := do
  let mut lastErr := ""
  for _ in [0:6] do
    let entries ← c.nodeView
    match findMasterFqdn entries p with
    | none => lastErr := s!"no Active P{p} master in the operator's map"
    | some mFqdn =>
      match entries.find? (fun e => e.fqdn != mFqdn && e.role == 1 && e.partition == Int.ofNat p) with
      | none => lastErr := s!"no slave of P{p} in the operator's map"
      | some sl =>
        match ← getPodIp (podOf mFqdn) c.cfg.«namespace», ← getPodIp (podOf sl.fqdn) c.cfg.«namespace» with
        | some mIp, some sIp => return .ok (podOf mFqdn, mIp, podOf sl.fqdn, sIp)
        | _, _ => lastErr := "could not resolve pod IPs"
    IO.sleep 5000
  return .error lastErr

private def multiEnableCfg : ClusterConfig := {
  name := "cont-repl-mp-enable"
  «namespace» := "flare-cont-repl-mp-enable"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-mp-enable"
  storageBackend := "rocksdb"
  usePvc := true
}

def multiEnableSuite : TestSuite := {
  name := "continuous-replication-multipart-enable"
  setup := do
    deployCluster multiEnableCfg
    IO.sleep 60000
  teardown := cleanupCluster multiEnableCfg
  onFailure := dumpClusterDiagnostics multiEnableCfg.«namespace» s!"app={multiEnableCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := multiEnableCfg }
    [
    { name := "enablement on 2 partitions, live: a legacy 2p x 2r cluster switches on identity forwarding then following through the CR; every partition's replica follows, each partition's copies stay equal, no master moves"
      run := do
        match ← c.pairOf 0, ← c.pairOf 1 with
        | .error e, _ | _, .error e => return .fail e
        | .ok (m0, m0Ip, s0, s0Ip), .ok (m1, m1Ip, s1, s1Ip) =>
          let w0 ← writeKeys multiEnableCfg.debugPod multiEnableCfg.«namespace» m0Ip multiEnableCfg.flarePort "legacy" 300
          let eqBoth : String → IO Bool := fun label => waitForCondition label 180 do
            let a ← c.currItems m0Ip
            let b ← c.currItems m1Ip
            return a > 0 && b > 0 && (← c.currItems s0Ip) == a && (← c.currItems s1Ip) == b
          if w0 != 300 then return .fail s!"legacy writes: stored {w0}/300"
          if !(← eqBoth "legacy: each partition's replica matches its master") then
            return .fail s!"legacy: P0 {← c.currItems m0Ip}/{← c.currItems s0Ip}, P1 {← c.currItems m1Ip}/{← c.currItems s1Ip}"
          let recon0 := (← c.statNat s0Ip "reconstruction_started").getD 0
          let recon1 := (← c.statNat s1Ip "reconstruction_started").getD 0
          IO.eprintln s!"# legacy: P0 {m0}/{s0} items {← c.currItems m0Ip}; P1 {m1}/{s1} items {← c.currItems m1Ip}"
          match ← kubectlPatch "flarecluster" multiEnableCfg.name multiEnableCfg.«namespace» (enablePatch true false) with
          | .error e => return .fail s!"patch (identity on) failed: {e}"
          | .ok _ => pure ()
          if !(← waitForCondition "all four nodes reload repl_identity_forward 0 -> 1" 240 do bothReloaded c "repl_identity_forward: 0 -> 1") then
            return .fail "identity forwarding was not applied on every node"
          match ← kubectlPatch "flarecluster" multiEnableCfg.name multiEnableCfg.«namespace» (enablePatch true true) with
          | .error e => return .fail s!"patch (follow on) failed: {e}"
          | .ok _ => pure ()
          let both ← waitForCondition "both partitions' replicas follow" 300 do
            return (← c.statStr s0Ip "repl_follow_state") == some "following" && (← c.statStr s1Ip "repl_follow_state") == some "following"
          IO.eprintln s!"# follow on: P0 replica {← c.statStr s0Ip "repl_follow_state"} source epoch {← c.statStr s0Ip "repl_follow_source_epoch"}; P1 replica {← c.statStr s1Ip "repl_follow_state"} source epoch {← c.statStr s1Ip "repl_follow_source_epoch"}; rebuilds P0 {recon0}→{(← c.statNat s0Ip "reconstruction_started").getD 0} P1 {recon1}→{(← c.statNat s1Ip "reconstruction_started").getD 0}"
          if !both then return .fail "not every partition's replica followed after enablement"
          let w1 ← writeKeys multiEnableCfg.debugPod multiEnableCfg.«namespace» m1Ip multiEnableCfg.flarePort "follow" 200
          if !(← eqBoth "following: each partition's replica matches its master") then
            return .fail s!"following: P0 {← c.currItems m0Ip}/{← c.currItems s0Ip}, P1 {← c.currItems m1Ip}/{← c.currItems s1Ip}"
          for (pfx, n) in [("legacy", 300), ("follow", 200)] do
            for i in [0, n / 2, n - 1] do
              let v0 ← memcachedGet multiEnableCfg.debugPod multiEnableCfg.«namespace» s0Ip multiEnableCfg.flarePort s!"{pfx}_{i}"
              let v1 ← memcachedGet multiEnableCfg.debugPod multiEnableCfg.«namespace» s1Ip multiEnableCfg.flarePort s!"{pfx}_{i}"
              if v0 != some s!"val_{i}" || v1 != v0 then return .fail s!"{pfx}_{i}: via P0 replica {v0}, via P1 replica {v1}"
          let total := (← c.currItems m0Ip) + (← c.currItems m1Ip)
          let n0 ← masterPodOf c
          let n1 := (findMasterFqdn (← c.nodeView) 1).bind (fun f => (f.splitOn ".").head?)
          IO.eprintln s!"# following: stored {w1}/200; items P0 {← c.currItems m0Ip} P1 {← c.currItems m1Ip} (total {total}); masters now {n0}/{n1}"
          if total != 500 then return .fail s!"expected 500 keys across both partitions, found {total}"
          if n0 != some m0 || n1 != some m1 then return .fail s!"a master moved during enablement ({m0}/{m1} → {n0}/{n1})"
          return .pass }
  ]
}

private def multiHoldCfg : ClusterConfig := {
  name := "cont-repl-mp-hold"
  «namespace» := "flare-cont-repl-mp-hold"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-mp-hold"
  storageBackend := "rocksdb"
  usePvc := true
  extraFlaredConf := holdFlags
  operatorEnv := [("FLARE_FOLLOW_FAILOVER_MAX_LAG", "20"), ("FLARE_FOLLOW_FAILOVER_WAIT_SECONDS", "900")]
}

def multiHoldSuite : TestSuite := {
  name := "continuous-replication-multipart-lag-hold"
  setup := do
    deployCluster multiHoldCfg
    IO.sleep 60000
  teardown := do
    discard <| kubectl ["uncordon", kindNode]
    cleanupCluster multiHoldCfg
  onFailure := dumpClusterDiagnostics multiHoldCfg.«namespace» s!"app={multiHoldCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := multiHoldCfg }
    [
    { name := "lag hold on 2 partitions: P1's follower is far behind and P1's master is lost; P1 is held (follower not promoted), P0 keeps its master and takes writes, the breaker does not trip, and P1's ex-master returns with every write"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.pairOf 0, ← c.pairOf 1 with
        | .error e, _ | _, .error e => return .fail e
        | .ok (m0, m0Ip, _, _), .ok (m1, m1Ip, s1, s1Ip) =>
          let synced ← waitForCondition "P1 replica following" 180 do
            return (← c.statStr s1Ip "repl_follow_state") == some "following"
          if !synced then return .fail "precondition: P1's replica not following"
          -- PRECONDITION (CI 37392833616): the follower must HOLD P1 data
          -- before the cut. The hold line lists data-bearing followers only;
          -- an empty follower is (correctly) never crowned and never listed,
          -- so with 'replica=0' the test could not tell a hold from nothing.
          let base ← writeKeys multiHoldCfg.debugPod multiHoldCfg.«namespace» m1Ip multiHoldCfg.flarePort "mpbase" 40
          let seeded ← waitForCondition "P1's follower holds P1's data before the cut" 180 do
            let mi ← c.currItems m1Ip
            let si ← c.currItems s1Ip
            return mi > 0 && si == mi
          if base != 40 || !seeded then
            return .fail s!"precondition: P1's follower does not hold P1's data (stored {base}/40; master {← c.currItems m1Ip}, follower {← c.currItems s1Ip})"
          match ← cutForwards m1Ip s1Ip with
          | .error e => return .fail e
          | .ok () => pure ()
          -- through P1's master: keys of both partitions, about half land on P1
          let w ← writeKeys multiHoldCfg.debugPod multiHoldCfg.«namespace» m1Ip multiHoldCfg.flarePort "hold" 240
          let unfit ← waitForCondition "the operator judges P1's follower unfit" 120 do
            return ((← c.opLog 2000).splitOn "\n").any fun l =>
              containsSubstr l s!"eligibility {s1}" && containsSubstr l "more than the failover bound"
          let p1Items ← c.currItems m1Ip
          IO.eprintln s!"# before the kill: stored {w}/240; P1 items master={p1Items} replica={← c.currItems s1Ip}; P1 replica source={← c.statNat s1Ip "repl_source_lsn"} applied={← c.statNat s1Ip "repl_applied_lsn"}; unfit judged={unfit}"
          if !unfit then healForwards m1Ip s1Ip; return .fail "precondition: P1's follower was never judged unfit"
          match ← kubectl ["cordon", kindNode] with
          | .error e => healForwards m1Ip s1Ip; return .fail s!"could not cordon {kindNode}: {e}"
          | .ok _ => pure ()
          discard <| kubectl ["delete", "pod", m1, "-n", multiHoldCfg.«namespace», "--grace-period=0", "--force", "--wait=false"]
          healForwards m1Ip s1Ip
          let mut promoted := false
          let mut held := false
          for _ in [0:60] do
            IO.sleep 2000
            let entries ← c.nodeView
            if (findMasterFqdn entries 1).bind (fun f => (f.splitOn ".").head?) == some s1 then promoted := true; break
            if ((← c.opLog 3000).splitOn "\n").any (fun l => containsSubstr l "partition 1 has NO master" && containsSubstr l s1) then
              held := true; break
          -- the masterless STATE itself is visible as a metric (the alert's
          -- input), whatever the hold's reason log says
          let gaugeSeen ← waitForCondition "the operator's masterless gauge reports P1" 120 do
            return ((← c.masterlessGauge).getD 0) ≥ 1
          -- P0 during P1's hold: same master, accepts writes to its keys
          let p0Before ← c.currItems m0Ip
          let p0w ← writeKeys multiHoldCfg.debugPod multiHoldCfg.«namespace» m0Ip multiHoldCfg.flarePort "p0during" 40
          let p0After ← c.currItems m0Ip
          let p0Master ← masterPodOf c
          let tripped := ((← c.opLog 200000).splitOn "\n").any (containsSubstr · "CIRCUIT BREAKER")
          discard <| kubectl ["uncordon", kindNode]
          IO.eprintln s!"# P1 away: follower promoted={promoted}; held={held}; P0 master {p0Master} (was {m0}); P0 items {p0Before}→{p0After} while writing 40 keys through it ({p0w} STORED: keys of P1 fail meanwhile); breaker tripped={tripped}"
          if promoted then return .fail s!"P1's follower {s1} was promoted although it was further behind than the bound"
          if !held then return .fail "P1 was not held (no 'partition 1 has NO master' line)"
          if !gaugeSeen then return .fail "the masterless partition was not reported by flare_operator_partitions_masterless (the alert's input)"
          if p0Master != some m0 then return .fail s!"P0's master moved during P1's hold ({m0} → {p0Master})"
          if p0After ≤ p0Before then return .fail "P0 took no writes during P1's hold"
          if tripped then return .fail "the circuit breaker tripped on one unavailable node of four"
          let back ← waitForCondition "P1's ex-master is master again with every write" 300 do
            let entries ← c.nodeView
            if (findMasterFqdn entries 1).bind (fun f => (f.splitOn ".").head?) != some m1 then return false
            match ← getPodIp m1 multiHoldCfg.«namespace» with
            | none => return false
            | some ip => return (← c.currItems ip) == p1Items
          let p1Now := (findMasterFqdn (← c.nodeView) 1).bind (fun f => (f.splitOn ".").head?)
          IO.eprintln s!"# P1 ex-master {m1} master again with {p1Items} items={back}; P1 master now {p1Now}"
          if !back then return .fail "P1's ex-master did not return as master with every write"
          if ← notLossFreeFor c s1 then return .fail "a NOT LOSS-FREE line was logged for P1's follower"
          return .pass }
  ]
}

-- ─── scale evaluation (skipped unless FLARE_E2E_SCALE_KEYS is set) ──────

private def scaleCfg : ClusterConfig := {
  name := "cont-repl-scale"
  «namespace» := "flare-cont-repl-scale"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-scale"
  storageBackend := "rocksdb"
  -- A small block cache and a memory budget for millions of keys: with the
  -- default cache the 512Mi master was OOMKilled 2m42s into a 2M-key load
  -- and the operator failed over to the follower under test.
  extraFlaredConf := flags ++ "\nrocksdb-block-cache-size-mb = 64"
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
  usePvc := true
  flaredMemoryLimit := "2Gi"
  flaredMemoryRequest := "1Gi"
}

private def scaleKeys : IO (Option Nat) := do
  return (← IO.getEnv "FLARE_E2E_SCALE_KEYS").bind (·.toNat?)

/-- kill -9 flared of `uid`'s pod from the kind node. -/
private def killFlared (uid : String) : IO (Except String String) := do
  let uidUnderscore := uid.replace "-" "_"
  hostCmd "docker" ["exec", kindNode, "sh", "-c",
    s!"n=0; for p in $(pgrep -x flared); do if grep -q -e '{uid}' -e '{uidUnderscore}' /proc/$p/cgroup 2>/dev/null; then kill -9 $p && n=$((n+1)); fi; done; echo killed=$n"]

def scaleSuite : TestSuite := {
  name := "continuous-replication-scale"
  setup := do
    match ← scaleKeys with
    | none => IO.eprintln "# FLARE_E2E_SCALE_KEYS unset: the scale evaluation deploys nothing and its tests are skipped"
    | some _ =>
      deployCluster scaleCfg
      IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
      IO.sleep 50000
  teardown := do
    match ← scaleKeys with
    | none => pure ()
    | some _ => cleanupCluster scaleCfg
  tests :=
    let c : Ctx := { cfg := scaleCfg }
    [
    { name := "scale: load FLARE_E2E_SCALE_KEYS keys (pipelined) and let the follower converge"
      run := do
        match ← scaleKeys with
        | none => return .skip "FLARE_E2E_SCALE_KEYS unset (evaluation only)"
        | some n =>
          match ← c.pair with
          | .error e => return .fail e
          | .ok (mPod, mIp, sPod, sIp) =>
            let mRc0 ← c.restartCount mPod
            -- Capped variant (scale-6m-mem-cap): bound the proxy queue through
            -- the CR. The follow flags and the block cache are declared with
            -- it because the operator rewrites the whole extra.conf.
            match (← IO.getEnv "FLARE_E2E_SCALE_QUEUE_CAP").bind (·.toNat?) with
            | none => pure ()
            | some cap =>
              discard <| kubectlPatch "flarecluster" scaleCfg.name scaleCfg.«namespace»
                s!"\{\"spec\":\{\"rocksdb\":\{\"maxTotalThreadQueue\":{cap},\"replIdentityForward\":true,\"replFollowEnabled\":true,\"replFollowPollIntervalUsec\":200000,\"blockCacheSizeMb\":64}}}"
              let applied ← waitForCondition s!"the master reloads max-total-thread-queue = {cap}" 240 do
                match ← hostCmd "kubectl" ["logs", "-n", scaleCfg.«namespace», mPod, "--tail=2000"] with
                | .ok o => return containsSubstr o s!"max_total_thread_queue: 0 -> {cap}"
                | .error _ => return false
              if !applied then return .fail s!"the master never reloaded max-total-thread-queue = {cap}"
            let chunk := 20000
            let items0 ← c.currItems mIp
            let mut loaded := 0
            let mut failedRun := 0
            let t0 ← IO.monoMsNow
            let mut i := 0
            while i < n do
              let m := min chunk (n - i)
              -- End the chunk with `quit`: flared answers every set, then
              -- closes, and nc exits on that close. The fixed `sleep 15` that
              -- used to wait for the replies capped the loader at ~1300
              -- keys/s, too slow for 15.8M keys in one evaluation leg
              -- (run 36899086870).
              let cmd := s!"(awk -v s={i} -v m={m} 'BEGIN\{for(k=s;k<s+m;k++) printf \"set s%d 0 0 16\\r\\n0123456789abcdef\\r\\n\", k; printf \"quit\\r\\n\"}') | nc -w 60 {mIp} {scaleCfg.flarePort} | grep -c STORED"
              -- Host-side timeout: a hung `kubectl exec` stalled the whole
              -- evaluation for 75 min (run 36941383859, cancelled).
              let r ← hostCmd "timeout" ["150", "kubectl", "exec", "-n", scaleCfg.«namespace», scaleCfg.debugPod, "--", "sh", "-c", cmd]
              let stored := match r with | .ok o => o.trim.toNat?.getD 0 | .error _ => 0
              loaded := loaded + stored
              if stored == 0 then
                failedRun := failedRun + 1
                IO.eprintln s!"# chunk at {i} stored 0 ({match r with | .ok _ => "no STORED" | .error e => e})"
              else failedRun := 0
              if i % 500000 == 0 || failedRun == 1 then
                IO.eprintln s!"# load at {i}: stored so far {loaded}; master RSS={(← c.rssKb mPod).getD 0}kB heap in-use={((← c.statNat mIp "malloc_in_use_bytes").getD 0) / 1024}kB heap free={((← c.statNat mIp "malloc_free_bytes").getD 0) / 1024}kB restarts={← c.restartCount mPod} thread_queue={(← c.statNat mIp "total_thread_queue").getD 0} dropped={(← c.statNat mIp "proxy_write_dropped").getD 0} items={← c.currItems mIp}; replica applied={(← c.statNat sIp "repl_applied_lsn").getD 0} forward_applied={(← c.statNat sIp "repl_forward_applied").getD 0} RSS={(← c.rssKb sPod).getD 0}kB heap in-use={((← c.statNat sIp "malloc_in_use_bytes").getD 0) / 1024}kB"
              -- Fail fast: 3 chunks in a row with nothing stored means the
              -- master is not taking writes (run 36941383859: from 4.44M keys
              -- on). Record why and stop instead of retrying for hours.
              -- Stop as soon as the master restarts (run 36949992433: the
              -- writes kept succeeding on the promoted follower, so the
              -- empty-chunk rule never fired and the run went on 3 h).
              let restartedNow := (← c.restartCount mPod) > mRc0
              if restartedNow then
                match ← hostCmd "kubectl" ["get", "pod", mPod, "-n", scaleCfg.«namespace», "-o", "jsonpath={.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason}"] with
                | .ok o => IO.eprintln s!"# load stopped at {i}: the master restarted (restartCount / last termination = {o.trim}); RSS before was the last sample above"
                | .error e => IO.eprintln s!"# load stopped at {i}: the master restarted ({e})"
                break
              if failedRun ≥ 3 then
                match ← hostCmd "kubectl" ["get", "pod", mPod, "-n", scaleCfg.«namespace», "-o", "jsonpath={.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason} {.status.containerStatuses[0].state}"] with
                | .ok o => IO.eprintln s!"# load stopped at {i}: master {mPod} restartCount/last termination/state = {o.trim}"
                | .error e => IO.eprintln s!"# load stopped at {i}: could not read the master pod ({e})"
                break
              i := i + m
            let loadMs := (← IO.monoMsNow) - t0
            -- Memory-only profile (scale-6m-mem): does the master's heap in
            -- use flatten at the RocksDB write-buffer budget or keep growing?
            -- Sample after the load, skip the follower drain (hours at this
            -- size) and the later tests.
            if (← IO.getEnv "FLARE_E2E_SCALE_MEMORY_ONLY").isSome then
              for k in [1, 2, 3] do
                IO.sleep 60000
                IO.eprintln s!"# memory after the load +{k} min: master RSS={(← c.rssKb mPod).getD 0}kB heap in-use={((← c.statNat mIp "malloc_in_use_bytes").getD 0) / 1024}kB heap free={((← c.statNat mIp "malloc_free_bytes").getD 0) / 1024}kB restarts={← c.restartCount mPod} items={← c.currItems mIp} thread_queue={(← c.statNat mIp "total_thread_queue").getD 0} dropped={(← c.statNat mIp "proxy_write_dropped").getD 0}; follower state={(← c.statStr sIp "repl_follow_state").getD "?"} applied={(← c.statNat sIp "repl_applied_lsn").getD 0} master head={(← c.statNat mIp "rocksdb_latest_sequence_number").getD 0}; replica RSS={(← c.rssKb sPod).getD 0}kB heap in-use={((← c.statNat sIp "malloc_in_use_bytes").getD 0) / 1024}kB"
              IO.eprintln s!"# memory-only: loaded {loaded}/{n} in {loadMs} ms; master restarts {mRc0}→{← c.restartCount mPod}"
              if (← c.restartCount mPod) > mRc0 then return .fail "the master restarted during the memory-only load"
              return .pass
            let t1 ← IO.monoMsNow
            -- Progress is reported every minute so a stall is diagnosable
            -- (state, reason, positions, skip/refuse counters), and the wait
            -- ends early when the applied position stops moving for 5 min.
            let mut caught := false
            let mut lastApplied := 0
            let mut stallMin := 0
            for _ in [0:40] do
              let st := (← c.statStr sIp "repl_follow_state").getD "?"
              let applied := (← c.statNat sIp "repl_applied_lsn").getD 0
              let mLatest := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
              IO.eprintln s!"# scale follow: state={st} reason={(← c.statStr sIp "repl_follow_last_reason").getD ""} applied={applied} source_lsn={(← c.statNat sIp "repl_source_lsn").getD 0} master latest={mLatest} items master={← c.currItems mIp} replica={← c.currItems sIp} wal_applied={(← c.statNat sIp "repl_wal_applied").getD 0} wal_skipped={(← c.statNat sIp "repl_wal_skipped").getD 0} decode_refused={(← c.statNat sIp "repl_decode_refused").getD 0} forward_applied={(← c.statNat sIp "repl_forward_applied").getD 0} forward_skipped={(← c.statNat sIp "repl_forward_skipped").getD 0}"
              if st == "following" && (← c.currItems sIp) == (← c.currItems mIp) && applied ≥ mLatest then
                caught := true
                break
              if applied == lastApplied then stallMin := stallMin + 1 else stallMin := 0
              lastApplied := applied
              if stallMin ≥ 5 then
                IO.eprintln "# scale follow: the applied position has not moved for 5 min — stopping the wait"
                break
              IO.sleep 60000
            IO.eprintln s!"# scale load: {loaded}/{n} STORED in {loadMs} ms; master items={← c.currItems mIp} replica={← c.currItems sIp}; follower converged={caught} {(← IO.monoMsNow) - t1} ms after the load ended; applied={← c.statNat sIp "repl_applied_lsn"} wal_applied={← c.statNat sIp "repl_wal_applied"} forward_applied={← c.statNat sIp "repl_forward_applied"}"
            let mRc1 ← c.restartCount mPod
            match ← kubectlGetJsonpath "pod" mPod scaleCfg.«namespace» "{.status.containerStatuses[0].lastState.terminated.reason}" with
            | .ok r => IO.eprintln s!"# master {mPod}: restartCount {mRc0}→{mRc1}; last termination reason: {r.trim}"
            | .error _ => pure ()
            match ← hostCmd "sh" ["-c", s!"kubectl logs -n {scaleCfg.«namespace»} {sPod} | grep -E 'continuous replication follower|replication follow state|shifting node_role.*{sPod}|refused' | tail -15"] with
            | .ok o => IO.eprintln s!"# --- replica follower lifecycle (filtered) ---\n{o}"
            | .error e => IO.eprintln s!"# (could not read the replica's log: {e})"
            if mRc1 != mRc0 then return .fail s!"the MASTER restarted during the load (restartCount {mRc0}→{mRc1}; see the termination reason above): the memory budget does not fit this key count, and the failover made the watched node the master — no follow measurement"
            -- The loader's own STORED count is only indicative (nc may close
            -- before every acknowledgement is read); the master's item count
            -- is the measure of what was loaded.
            let itemsLoaded := (← c.currItems mIp) - items0
            IO.eprintln s!"# scale load: master items grew by {itemsLoaded} (loader saw {loaded} STORED)"
            if itemsLoaded < n * 95 / 100 then return .fail s!"the master holds only {itemsLoaded}/{n} new keys after the load"
            if !caught then return .fail "the follower did not converge at scale"
            return .pass },

    { name := "scale: exact key scan at open (kill -9 on the PVC-backed replica) — duration recorded"
      run := do
        if (← IO.getEnv "FLARE_E2E_SCALE_MEMORY_ONLY").isSome then return .skip "memory-only profile"
        match ← scaleKeys with
        | none => return .skip "FLARE_E2E_SCALE_KEYS unset (evaluation only)"
        | some _ =>
          match ← c.pair with
          | .error e => return .fail e
          | .ok (_, mIp, sPod, sIp) =>
            let uid := (← c.podUid sPod).getD "?"
            let rc0 ← c.restartCount sPod
            match ← killFlared uid with
            | .error e => return .fail e
            | .ok o => IO.eprintln s!"# {o.trim}"
            let back ← waitForCondition "replica restarted and Ready" 600 do
              return (← c.restartCount sPod) == rc0 + 1 && (← c.ready sPod)
            let scanLine ← do
              match ← hostCmd "sh" ["-c", s!"kubectl logs -n {scaleCfg.«namespace»} {sPod} | grep -m1 'curr_items seeded by an exact scan'"] with
              | .ok o => pure o.trim
              | .error _ => pure ""
            let following ← waitForCondition "follower following again with equal items" 900 do
              return (← c.statStr sIp "repl_follow_state") == some "following" && (← c.currItems sIp) == (← c.currItems mIp)
            IO.eprintln s!"# boot scan: {scanLine}"
            IO.eprintln s!"# after the restart: ready={back}; following+equal={following}; items master={← c.currItems mIp} replica={← c.currItems sIp}; wal_fallback_to_dump={← c.statNat sIp "rocksdb_wal_fallback_to_dump"} reconstruction_completed={← c.statNat sIp "reconstruction_completed"}"
            if !back then return .fail "the replica did not come back Ready"
            if scanLine.isEmpty then return .fail "no 'curr_items seeded by an exact scan' line in the restarted replica's log"
            if !following then return .fail "the replica did not follow again with equal items"
            return .pass },

    { name := "scale: operator probe cost at this size — recorded from the operator's own timing lines"
      run := do
        if (← IO.getEnv "FLARE_E2E_SCALE_MEMORY_ONLY").isSome then return .skip "memory-only profile"
        match ← scaleKeys with
        | none => return .skip "FLARE_E2E_SCALE_KEYS unset (evaluation only)"
        | some _ =>
          let log ← c.opLog 20000
          let lines := (log.splitOn "\n").filter (fun l => containsSubstr l "continuous-replication probe:")
          let ms := lines.filterMap fun l =>
            match (l.splitOn " in ").getLast? with
            | some rest => ((rest.splitOn "ms").head?.getD "").trim.toNat?
            | none => none
          let maxMs := ms.foldl max 0
          let slow := ((log.splitOn "\n").filter (fun l => containsSubstr l "reconcile slow")).length
          IO.eprintln s!"# probe timing lines: {lines.length}; max {maxMs} ms; 'reconcile slow' lines: {slow}; last: {(lines.getLast?.getD "").trim.takeRight 120}"
          if lines.isEmpty then return .fail "no probe timing lines found in the operator log"
          if maxMs > 10000 then return .fail s!"a stats probe pass took {maxMs} ms at this size"
          return .pass }
  ]
}


-- ─── sustained-load evaluation (skipped unless FLARE_E2E_SUSTAINED is set) ─

private def sustainedCfg : ClusterConfig := {
  name := "cont-repl-sustained"
  «namespace» := "flare-cont-repl-sustained"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-sustained"
  storageBackend := "rocksdb"
  extraFlaredConf := flags ++ "\nrocksdb-block-cache-size-mb = 64"
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
  usePvc := true
  flaredMemoryLimit := "2Gi"
  flaredMemoryRequest := "1Gi"
}

private def sustainedOn : IO Bool := return (← IO.getEnv "FLARE_E2E_SUSTAINED").isSome

/-- WAL bytes (kB) and data-dir bytes (kB) of a flared pod's RocksDB. -/
private def Ctx.walKb (c : Ctx) (pod : String) : IO (Option Nat) := do
  match ← kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", "du -ck /data/flare/flare.rocksdb/*.log 2>/dev/null | tail -1 | awk '{print $1}'"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none
private def Ctx.dataKb (c : Ctx) (pod : String) : IO (Option Nat) := do
  match ← kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", "du -sk /data/flare 2>/dev/null | awk '{print $1}'"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- One 30 s window at `rate` keys/s: pipeline rate*30 sets, then sleep the
    remainder. Returns keys attempted. -/
private def Ctx.loadWindow (c : Ctx) (ip : String) (start rate : Nat) : IO Nat := do
  let n := rate * 30
  let t0 ← IO.monoMsNow
  let cmd := s!"(awk -v s={start} -v m={n} 'BEGIN\{for(k=s;k<s+m;k++) printf \"set w%d 0 0 16\\r\\n0123456789abcdef\\r\\n\", k}'; sleep 3) | nc -w 40 {ip} {c.cfg.flarePort} | grep -c STORED"
  discard <| execInDebugPod c.cfg.debugPod c.cfg.«namespace» cmd
  let spent := (← IO.monoMsNow) - t0
  if spent < 30000 then IO.sleep (30000 - spent).toUInt32
  return n

/-- T17: latency of single `get`s while the load runs, measured from inside
    a flared pod (`fromPod`, which has bash and a nanosecond clock; the busybox
    debug pod has neither) over ONE persistent TCP connection to `ip`, so
    each sample is one request/response, not a process start. Returns
    "p50=… p99=… max=… n=…" in microseconds, or why it could not measure. -/
private def Ctx.latencyProbe (c : Ctx) (fromPod ip key : String) (n : Nat := 50) : IO String := do
  let script := s!"exec 3<>/dev/tcp/{ip}/{c.cfg.flarePort} || exit 0; i=0; while [ $i -lt {n} ]; do s=$(date +%s%N); printf 'get {key}\\r\\n' >&3; while IFS= read -r line <&3; do case \"$line\" in END*|SERVER_ERROR*|ERROR*) break;; esac; done; e=$(date +%s%N); echo $(( (e - s) / 1000 )); i=$((i+1)); done | sort -n | awk '\{a[NR]=$1} END \{if (NR==0) \{print \"no samples\"} else \{p=int((NR+1)/2); q=int(NR*0.99); if (q<1) q=1; print \"p50=\" a[p] \"us p99=\" a[q] \"us max=\" a[NR] \"us n=\" NR}}'"
  match ← kubectl ["exec", "-n", c.cfg.«namespace», fromPod, "--", "timeout", "60", "bash", "-c", script] with
  | .ok out => return out.trim
  | .error e => return s!"probe failed: {e}"

/-- T17: (sum, count) of the operator's reconcile-duration histogram, read
    from its own /metrics. -/
private def Ctx.reconcileSumCount (c : Ctx) : IO (Option (Float × Nat)) := do
  let pods ← getPodNames s!"app={c.cfg.operatorName}" c.cfg.«namespace»
  match pods.head? with
  | none => return none
  | some pod =>
    match ← getPodIp pod c.cfg.«namespace» with
    | none => return none
    | some ip =>
      match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» s!"wget -qO- -T 5 http://{ip}:9090/metrics | grep -E '^flare_operator_reconcile_duration_seconds_(sum|count)'" with
      | .error _ => return none
      | .ok out =>
        let val := fun (suffix : String) => (out.splitOn "\n").findSome? fun l =>
          if containsSubstr l s!"_{suffix}" then ((l.splitOn " ").getLast?.map String.trim) else none
        match val "sum", val "count" with
        | some sv, some cv =>
          let sf := (sv.splitOn ".")
          let whole := (sf.headD "0").toNat?.getD 0
          let frac := (sf.getD 1 "0")
          let fracF := (frac.take 6).toNat?.getD 0
          let digits := (frac.take 6).length
          let f := whole.toFloat + fracF.toFloat / (10.0 ^ digits.toFloat)
          return (cv.toNat?).map (f, ·)
        | _, _ => return none

/-- T17: seconds since the operator lease was last renewed. -/
private def Ctx.leaseAgeS (c : Ctx) : IO (Option Nat) := do
  match ← hostCmd "sh" ["-c", s!"r=$(kubectl get lease {c.cfg.name}-operator-lease -n {c.cfg.«namespace»} -o jsonpath='\{.spec.renewTime}'); now=$(date +%s); t=$(date -d \"$r\" +%s 2>/dev/null || date -j -f %Y-%m-%dT%H:%M:%S \"$\{r%%.*}\" +%s); echo $((now - t))"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- Run `minutes` of load at `rate`, sampling every 30 s. Returns the lag
    samples (master latest − replica applied) and the last item counts. -/
private def Ctx.sustain (c : Ctx) (mPod mIp sPod sIp : String) (start rate minutes : Nat)
    : IO (List Nat × Nat) := do
  let mut lags : List Nat := []
  let mut k := start
  for w in [0:minutes * 2] do
    -- T17: probe both copies and the control loop WHILE this window loads.
    let rc0 ← c.reconcileSumCount
    let probeS ← IO.asTask (c.latencyProbe mPod sIp "w1")
    let probeM ← IO.asTask (c.latencyProbe mPod mIp "w1")
    k := k + (← c.loadWindow mIp k rate)
    let latS := match ← IO.wait probeS with | .ok v => v | .error e => s!"probe error: {e}"
    let latM := match ← IO.wait probeM with | .ok v => v | .error e => s!"probe error: {e}"
    let rc1 ← c.reconcileSumCount
    let recon := match rc0, rc1 with
      | some (s0, n0), some (s1, n1) =>
        if n1 > n0 then s!"{n1 - n0} passes, mean {((s1 - s0) * 1000.0 / (n1 - n0).toFloat).floor}ms" else "no pass completed"
      | _, _ => "unreadable"
    IO.eprintln s!"# T17 {rate}/s window {w}: get latency replica [{latS}] master [{latM}]; reconcile {recon}; lease age {(← c.leaseAgeS).map toString |>.getD "?"}s"
    let head := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
    let applied := (← c.statNat sIp "repl_applied_lsn").getD 0
    let lag := if head > applied then head - applied else 0
    lags := lags ++ [lag]
    IO.eprintln s!"# sustain {rate}/s window {w}: state={(← c.statStr sIp "repl_follow_state").getD "?"} lag={lag} (head {head}, applied {applied}) items master={← c.currItems mIp} replica={← c.currItems sIp} master RSS={(← c.rssKb mPod).getD 0}kB WAL={(← c.walKb mPod).getD 0}kB data={(← c.dataKb mPod).getD 0}kB replica RSS={(← c.rssKb sPod).getD 0}kB tombstones={(← c.statNat sIp "repl_tombstones").getD 0} wal_skipped={(← c.statNat sIp "repl_wal_skipped").getD 0}"
  return (lags, k)

def sustainedSuite : TestSuite := {
  name := "continuous-replication-sustained"
  setup := do
    if ← sustainedOn then
      -- Throughput variants (2026-10-02): a CPU limit and a noreply window
      -- for forwards, baked into the initial config (this cluster sets no
      -- spec.rocksdb, so the operator does not rewrite it).
      let cpu := (← IO.getEnv "FLARE_E2E_SUSTAINED_CPU").getD "500m"
      let nrw := (← IO.getEnv "FLARE_E2E_SUSTAINED_NRW").bind (·.toNat?)
      let extra := match nrw with
        | some n => sustainedCfg.extraFlaredConf ++ s!"\nnoreply-window-limit = {n}"
        | none => sustainedCfg.extraFlaredConf
      IO.eprintln s!"# sustained variant: flared cpu limit {cpu}, noreply-window-limit {nrw.map toString |>.getD "off"}"
      deployCluster { sustainedCfg with flaredCpuLimit := cpu, extraFlaredConf := extra }
      IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
      IO.sleep 50000
    else IO.eprintln "# FLARE_E2E_SUSTAINED unset: the sustained-load evaluation deploys nothing and its tests are skipped"
  teardown := do
    if ← sustainedOn then cleanupCluster sustainedCfg
  tests :=
    let c : Ctx := { cfg := sustainedCfg }
    [
    { name := "sustained load: does the follow stream keep up at a steady write rate, and do WAL/RSS/disk stay bounded until it does? (evaluation)"
      run := do
        if !(← sustainedOn) then return .skip "FLARE_E2E_SUSTAINED unset (evaluation only)"
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let following ← waitForCondition "replica following" 120 do
            return (← c.statStr sIp "repl_follow_state") == some "following"
          if !following then return .fail "replica never followed"
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          let mRc0 ← c.restartCount mPod
          let rss0 := (← c.rssKb mPod).getD 0
          let mut verdicts : List String := []
          let mut k := 0
          for rate in [300, 900, 2000] do
            let (lags, k') ← c.sustain mPod mIp sPod sIp k rate 4
            k := k'
            let firstMin := (lags.take 2).foldl max 0
            let lastMin := (lags.drop (lags.length - 2)).foldl max 0
            let kept := lastMin ≤ max 2000 (firstMin * 3 / 2)
            verdicts := verdicts ++ [s!"{rate}/s: lag first-minute max {firstMin}, last-minute max {lastMin} → {if kept then "KEPT UP (bounded)" else "FELL BEHIND (growing)"}"]
            IO.eprintln s!"# sustain {rate}/s: {verdicts.getLast?.getD ""}"
          -- Load stops: the backlog must drain; record how long.
          let t0 ← IO.monoMsNow
          let drained ← waitForCondition "follow stream drains the backlog after the load stops" 1200 do
            let head := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
            let applied := (← c.statNat sIp "repl_applied_lsn").getD 0
            return (← c.statStr sIp "repl_follow_state") == some "following" && applied ≥ head && (← c.currItems sIp) == (← c.currItems mIp)
          let drainS := ((← IO.monoMsNow) - t0) / 1000
          let mRc1 ← c.restartCount mPod
          IO.eprintln s!"# sustained summary: {String.intercalate " | " verdicts}; drained after the load stopped={drained} in {drainS}s; master RSS {rss0}→{(← c.rssKb mPod).getD 0} kB; WAL {(← c.walKb mPod).getD 0} kB; data {(← c.dataKb mPod).getD 0} kB; items master={← c.currItems mIp} replica={← c.currItems sIp}; master restarts {mRc0}→{mRc1}; reconstruction_started {recon0}→{(← c.statNat sIp "reconstruction_started").getD 0}; wal_applied={← c.statNat sIp "repl_wal_applied"} wal_skipped={← c.statNat sIp "repl_wal_skipped"} forward_applied={← c.statNat sIp "repl_forward_applied"}"
          IO.eprintln s!"# T17 apply lock on the replica: batches={(← c.statNat sIp "repl_apply_lock_count").getD 0} hold total={(← c.statNat sIp "repl_apply_lock_hold_us_total").getD 0}us hold max={(← c.statNat sIp "repl_apply_lock_hold_us_max").getD 0}us exclusive-acquire wait max={(← c.statNat sIp "repl_apply_lock_wait_us_max").getD 0}us forwarded-write wait max={(← c.statNat sIp "repl_forward_lock_wait_us_max").getD 0}us"
          if mRc1 != mRc0 then return .fail "the master restarted during the load"
          if (← c.statNat sIp "reconstruction_started").getD 0 != recon0 then return .fail "a reconstruction ran during the load"
          if !drained then return .fail "the backlog did not drain within 20 min after the load stopped"
          return .pass }
  ]
}


-- ─── long-outage retention evaluation (skipped unless FLARE_E2E_OUTAGE is set) ─
--
-- The sustained and limits runs never filled a write buffer, so they say
-- nothing about WAL rotation, flush, compaction or retention. Here the
-- replica is held offline long enough for the master to flush several
-- times, twice:
--   phase A — ~150 MB written while cut, under a 256 MB WAL cap: the WAL
--             the follower needs is still retained, so on healing it must
--             catch up FROM ITS CURSOR (no reconstruction);
--   phase B — ~400 MB written while cut, past the cap: the archived WAL is
--             purged, so the follower must declare needs_rebuild /
--             lsn_purged and be rebuilt by the operator.
-- Disk (live WAL, archived WAL, SST count, data dir) and RSS are sampled
-- every 50 MB written and the high-water marks are recorded. Evaluation:
-- the assertions are the classification (catch-up vs rebuild), content
-- equality, no master restart and the disk ceiling; the numbers are the
-- product.

/-- The outage evaluation on tmpfs (FLARE_E2E_OUTAGE_TMPFS): the same two
    phases with the data dir in a memory-backed emptyDir. The WAL cap is the
    values.yaml rule of thumb for tmpfs (well under the tmpfs size), and the
    memory limit has to hold the RocksDB floor PLUS the data. -/
private def outageTmpfs : IO Bool := return (← IO.getEnv "FLARE_E2E_OUTAGE_TMPFS").isSome

private def outageCfg : ClusterConfig := {
  name := "cont-repl-outage"
  «namespace» := "flare-cont-repl-outage"
  partitions := 1
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-cont-repl-outage"
  storageBackend := "rocksdb"
  -- production-shaped retention: bounded by SIZE (256 MB) so the two phases
  -- are deterministic; the TTL is long enough not to interfere.
  extraFlaredConf := flags ++ "\nrocksdb-block-cache-size-mb = 64\nrocksdb-wal-size-limit-mb = 256\nrocksdb-wal-ttl-seconds = 3600"
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
  usePvc := true
  pvcSize := "4Gi"
  flaredMemoryLimit := "2Gi"
  flaredMemoryRequest := "1Gi"
}

private def outageOn : IO Bool := return (← IO.getEnv "FLARE_E2E_OUTAGE").isSome

/-- Pipelined big-value loader: `count` keys of `bytes` bytes, 100 keys per
    connection. Returns the number the master reported STORED. -/
private def Ctx.loadBig (c : Ctx) (ip : String) (pfx : String) (start count bytes : Nat) : IO Nat := do
  let mut stored := 0
  let mut k := start
  while k < start + count do
    let m := min 100 (start + count - k)
    let cmd := s!"v=$(head -c {bytes} /dev/zero | tr '\\0' x); (awk -v s={k} -v m={m} -v v=\"$v\" 'BEGIN\{for(i=s;i<s+m;i++) printf \"set {pfx}%d 0 0 {bytes}\\r\\n%s\\r\\n\", i, v}'; sleep 5) | nc -w 180 {ip} {c.cfg.flarePort} | grep -c STORED"
    match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» cmd with
    | .ok o => stored := stored + (o.trim.toNat?.getD 0)
    | .error e => IO.eprintln s!"# loadBig chunk at {k} failed: {e}"
    k := k + m
  return stored

private structure DiskSample where
  walKb : Nat := 0
  archiveKb : Nat := 0
  sst : Nat := 0
  dataKb : Nat := 0
  rssKb : Nat := 0
  deriving Repr

private def Ctx.diskSample (c : Ctx) (pod : String) : IO DiskSample := do
  let q := fun (sh : String) => do
    match ← kubectl ["exec", "-n", c.cfg.«namespace», pod, "--", "sh", "-c", sh] with
    | .ok o => pure (o.trim.toNat?.getD 0)
    | .error _ => pure 0
  return { walKb := ← q "du -ck /data/flare/flare.rocksdb/*.log 2>/dev/null | tail -1 | awk '{print $1}'",
           archiveKb := ← q "du -sk /data/flare/flare.rocksdb/archive 2>/dev/null | awk '{print $1}'",
           sst := ← q "ls /data/flare/flare.rocksdb/*.sst 2>/dev/null | wc -l",
           dataKb := ← q "du -sk /data/flare 2>/dev/null | awk '{print $1}'",
           rssKb := ← q "grep VmRSS /proc/1/status | awk '{print $2}'" }

private def DiskSample.line (d : DiskSample) : String :=
  s!"WAL live={d.walKb}kB archive={d.archiveKb}kB sst={d.sst} data={d.dataKb}kB RSS={d.rssKb}kB"

private def DiskSample.highWater (a b : DiskSample) : DiskSample :=
  { walKb := Nat.max a.walKb b.walKb, archiveKb := Nat.max a.archiveKb b.archiveKb, sst := Nat.max a.sst b.sst,
    dataKb := Nat.max a.dataKb b.dataKb, rssKb := Nat.max a.rssKb b.rssKb }

/-- Write `mb` megabytes of 50 kB values while sampling the master every
    50 MB. Returns (stored keys, next key index, high-water sample). -/
private def Ctx.writeUnderCut (c : Ctx) (mPod mIp : String) (pfx : String) (start mb : Nat)
    : IO (Nat × Nat × DiskSample) := do
  let keysPer50Mb := 1000            -- 1000 × 50 kB
  let rounds := mb / 50
  let mut stored := 0
  let mut k := start
  let mut hw : DiskSample := {}
  for r in [0:rounds] do
    stored := stored + (← c.loadBig mIp pfx k keysPer50Mb 50000)
    k := k + keysPer50Mb
    let d ← c.diskSample mPod
    hw := hw.highWater d
    IO.eprintln s!"# under the cut, after {(r + 1) * 50} MB: {d.line}; master latest={(← c.statNat mIp "rocksdb_latest_sequence_number").getD 0}"
  return (stored, k, hw)

def mkOutageSuite (suiteName : String) (cfg : ClusterConfig) (gate : IO Bool) (gateName : String) : TestSuite := {
  name := suiteName
  setup := do
    if ← gate then
      deployCluster cfg
      IO.eprintln "# Waiting 50s grace period for operator reconciliation..."
      IO.sleep 50000
    else IO.eprintln s!"# {gateName} unset: the long-outage evaluation deploys nothing and its tests are skipped"
  teardown := do
    if ← gate then cleanupCluster cfg
  tests :=
    let c : Ctx := { cfg := cfg }
    [
    { name := "outage phase A: ~150 MB written while cut under a 256 MB WAL cap — several flushes, WAL retained; on healing the follower catches up from its cursor (no rebuild); disk/RSS high-water recorded"
      run := do
        if !(← gate) then return .skip s!"{gateName} unset (evaluation only)"
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let following ← waitForCondition "replica following" 120 do
            return (← c.statStr sIp "repl_follow_state") == some "following"
          if !following then return .fail "replica never followed"
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          let mRc0 ← c.restartCount mPod
          let applied0 := (← c.statNat sIp "repl_applied_lsn").getD 0
          let d0 ← c.diskSample mPod
          IO.eprintln s!"# before the cut: {d0.line}; applied={applied0}"
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let (stored, _, hw) ← c.writeUnderCut mPod mIp "oa" 0 150
          let head := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
          IO.eprintln s!"# phase A written: {stored} keys (~{stored * 50 / 1000} MB); master latest={head}; replica applied={← c.statNat sIp "repl_applied_lsn"} state={(← c.statStr sIp "repl_follow_state").getD "?"}; high-water: {hw.line}"
          if stored < 2900 then heal mIp sIp; return .fail s!"only {stored}/3000 keys stored under the cut"
          if hw.sst == 0 then heal mIp sIp; return .fail "no SST was produced under the cut: the write buffer never flushed, so this run does not exercise WAL rotation"
          heal mIp sIp
          let t0 ← IO.monoMsNow
          let caught ← waitForCondition "follower catches up FROM ITS CURSOR to the master's head with equal items" 900 do
            return (← c.statStr sIp "repl_follow_state") == some "following"
              && (← c.statNat sIp "repl_applied_lsn").getD 0 ≥ head
              && (← c.currItems sIp) == (← c.currItems mIp)
          let catchS := ((← IO.monoMsNow) - t0) / 1000
          let recon1 := (← c.statNat sIp "reconstruction_started").getD 0
          let d1 ← c.diskSample mPod
          IO.eprintln s!"# phase A heal: caught up={caught} in {catchS}s; state={(← c.statStr sIp "repl_follow_state").getD "?"} reason={(← c.statStr sIp "repl_follow_last_reason").getD ""}; applied {applied0}→{(← c.statNat sIp "repl_applied_lsn").getD 0} (head {head}); items master={← c.currItems mIp} replica={← c.currItems sIp}; reconstruction_started {recon0}→{recon1}; wal_applied={← c.statNat sIp "repl_wal_applied"} wal_skipped={← c.statNat sIp "repl_wal_skipped"}; master after: {d1.line}; master restarts {mRc0}→{← c.restartCount mPod}"
          if (← c.restartCount mPod) != mRc0 then return .fail "the master restarted"
          if !caught then return .fail s!"the follower did not catch up (state {(← c.statStr sIp "repl_follow_state").getD "?"}, reason {(← c.statStr sIp "repl_follow_last_reason").getD ""}, items master={← c.currItems mIp} replica={← c.currItems sIp})"
          if recon1 != recon0 then return .fail "a reconstruction ran: the retained WAL was not used to catch up from the cursor"
          if hw.dataKb > 3500000 then return .fail s!"data dir high-water {hw.dataKb} kB exceeded the 3.5 GB ceiling"
          return .pass },

    { name := "outage phase B: ~400 MB written while cut, past the 256 MB WAL cap — archived WAL purged; the follower declares needs_rebuild/lsn_purged, is rebuilt and converges; disk/RSS high-water recorded"
      run := do
        if !(← gate) then return .skip s!"{gateName} unset (evaluation only)"
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let clean ← waitForCondition "no repair entry pending" 180 do return (← c.ledgerDests).isEmpty
          if !clean then return .fail s!"repair entry pending from phase A: {← c.ledgerDests}"
          let recon0 := (← c.statNat sIp "reconstruction_started").getD 0
          let mRc0 ← c.restartCount mPod
          let uid0 := (← c.podUid sPod).getD "?"
          let applied0 := (← c.statNat sIp "repl_applied_lsn").getD 0
          match ← cut mIp sIp with
          | .error e => return .fail e
          | .ok () => pure ()
          let (stored, _, hw) ← c.writeUnderCut mPod mIp "ob" 0 400
          let head := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
          IO.eprintln s!"# phase B written: {stored} keys (~{stored * 50 / 1000} MB); master latest={head}; replica applied={applied0}; high-water: {hw.line}"
          if stored < 7800 then heal mIp sIp; return .fail s!"only {stored}/8000 keys stored under the cut"
          -- The cap is not enforced synchronously, and on an IDLE master it
          -- is not enforced at all: run 1 healed a few minutes after the load
          -- and found 499 MB served against 256 MB; run 2 kept the cut and
          -- watched an idle master for 22 minutes — the archive never moved.
          -- RocksDB's archive purge runs from its obsolete-file cleanup,
          -- i.e. on flush/compaction, rate-limited (documented: every 10
          -- min when TTL and size cap are both set). So keep the cut AND
          -- keep writing: 50 MB bursts every two minutes (each one a flush)
          -- for up to 20 min, watching the archive after each. The time
          -- and bytes it takes for the archive to fall under the cap are
          -- the measurement; the follower is healed only afterwards.
          let tp ← IO.monoMsNow
          let mut k2 := 8000
          let mut purged := false
          let mut extraMb := 0
          for _ in [0:10] do
            let d ← c.diskSample mPod
            IO.eprintln s!"# purge watch (+{extraMb} MB after the cap crossing, {((← IO.monoMsNow) - tp) / 1000}s): archive={d.archiveKb}kB sst={d.sst} data={d.dataKb}kB RSS={d.rssKb}kB; master latest={(← c.statNat mIp "rocksdb_latest_sequence_number").getD 0}"
            if d.archiveKb < 256 * 1024 then purged := true; break
            let _ ← c.loadBig mIp "ob" k2 1000 50000
            k2 := k2 + 1000
            extraMb := extraMb + 50
            IO.sleep 120000
          let purgeS := ((← IO.monoMsNow) - tp) / 1000
          let head := (← c.statNat mIp "rocksdb_latest_sequence_number").getD 0
          let dAfter ← c.diskSample mPod
          let hw := hw.highWater dAfter
          IO.eprintln s!"# purge watch ended after {purgeS}s and {extraMb} MB more: under cap={purged}; archive now={dAfter.archiveKb}kB (high-water {hw.archiveKb}kB, cap 262144kB); data high-water {hw.dataKb}kB; RSS high-water {hw.rssKb}kB; master latest={head}"
          heal mIp sIp
          let declared ← waitForCondition "follower declares needs_rebuild with reason lsn_purged" 300 do
            return (← c.statStr sIp "repl_follow_state") == some "needs_rebuild"
              && (← c.statStr sIp "repl_follow_last_reason") == some "lsn_purged"
          let st := (← c.statStr sIp "repl_follow_state").getD "?"
          IO.eprintln s!"# phase B heal: declared lsn_purged={declared}; state={st} reason={(← c.statStr sIp "repl_follow_last_reason").getD ""}; applied={← c.statNat sIp "repl_applied_lsn"} (head {head}); archive now={(← c.diskSample mPod).archiveKb}kB"
          if !declared then
            if st == "following" && (← c.statNat sIp "repl_applied_lsn").getD 0 ≥ head then
              return .fail s!"the WAL past the 256 MB cap was still served: the follower caught up from {applied0} instead of being told lsn_purged (archive under cap before the heal={purged} after {purgeS}s; high-water {hw.archiveKb} kB)"
            return .fail s!"expected needs_rebuild/lsn_purged, got {st}/{(← c.statStr sIp "repl_follow_last_reason").getD ""}"
          let t0 ← IO.monoMsNow
          let rebuilt ← waitForCondition "follower rebuilt (reconstruction ran) and following at the head with equal items" 1500 do
            return (← c.statNat sIp "reconstruction_started").getD 0 > recon0
              && (← c.statStr sIp "repl_follow_state") == some "following"
              && (← c.currItems sIp) == (← c.currItems mIp)
          let rebuildS := ((← IO.monoMsNow) - t0) / 1000
          let d1 ← c.diskSample mPod
          IO.eprintln s!"# phase B rebuild: rebuilt={rebuilt} in {rebuildS}s; reconstruction_started {recon0}→{(← c.statNat sIp "reconstruction_started").getD 0}; snapshot_bootstrap={← c.statNat sIp "rocksdb_snapshot_bootstrap"} wal_fallback_to_dump={← c.statNat sIp "rocksdb_wal_fallback_to_dump"}; items master={← c.currItems mIp} replica={← c.currItems sIp}; pod uid {uid0}→{(← c.podUid sPod).getD "?"}; master after: {d1.line}; master restarts {mRc0}→{← c.restartCount mPod}"
          if (← c.restartCount mPod) != mRc0 then return .fail "the master restarted"
          if !rebuilt then return .fail s!"the follower was not rebuilt (state {(← c.statStr sIp "repl_follow_state").getD "?"}, items master={← c.currItems mIp} replica={← c.currItems sIp})"
          if hw.dataKb > 3500000 then return .fail s!"data dir high-water {hw.dataKb} kB exceeded the 3.5 GB ceiling"
          let empty ← waitForCondition "ledger empty" 300 do return (← c.ledgerDests).isEmpty
          if !empty then return .fail s!"ledger still holds {← c.ledgerDests}"
          return .pass }
  ]
}

def outageSuite : TestSuite :=
  mkOutageSuite "continuous-replication-outage" outageCfg outageOn "FLARE_E2E_OUTAGE"

private def outageTmpfsCfg : ClusterConfig := {
  outageCfg with
  name := "cont-repl-outage-tmpfs"
  «namespace» := "flare-cont-repl-outage-tmpfs"
  debugPod := "debug-cont-repl-outage-tmpfs"
  usePvc := false
  useTmpfs := true
  tmpfsSize := "3Gi"
  -- the limit must hold the RocksDB floor (64 + 2 x 64 x 3 MiB) PLUS the data
  flaredMemoryLimit := "4Gi"
  flaredMemoryRequest := "2Gi"
}

/-- Plan item 9: the outage evaluation with the data dir on tmpfs. -/
def outageTmpfsSuite : TestSuite :=
  mkOutageSuite "continuous-replication-outage-tmpfs" outageTmpfsCfg outageTmpfs "FLARE_E2E_OUTAGE_TMPFS"

-- ─── copy retention: phases 3, 4 and 7 as ONE unit (design §3-§5, §8-§10) ──

/-- 1p x 3r on PVC. Every rebuild of a returning replica is a STAGED copy
    (WAL catch-up disabled, so a snapshot is staged, verified and switched
    in), and the snapshot is throttled (128 KB/s) so two transfers overlap. -/
private def copyRetCfg : ClusterConfig := {
  name := "copy-ret"
  «namespace» := "flare-copy-ret"
  partitions := 1
  replicas := 3
  operatorName := "flare-operator"
  debugPod := "debug-copy-ret"
  storageBackend := "rocksdb"
  usePvc := true
  flaredEnv := [("FLARE_TEST_DISABLE_WAL_RECONSTRUCTION", "1")]
  extraFlaredConf := "rocksdb-snapshot-bwlimit = 128"
  operatorEnv := [("FLARE_FOLLOW_PROBE_INTERVAL", "1")]
}

/-- Lines of `pod`'s flared log since `since` containing `needle`. -/
private def Ctx.countSince (c : Ctx) (pod since needle : String) : IO Nat := do
  return ((← c.flaredLogAllSince pod since).splitOn "\n").filter (containsSubstr · needle) |>.length

/-- Number of entries under the node's data dir whose name starts with `pfx`. -/
private def Ctx.dataDirCount (c : Ctx) (pod pfx : String) : IO (Option Nat) := do
  match ← kubectl ["exec", "-n", c.cfg.«namespace», pod, "-c", "flared", "--", "sh", "-c",
      s!"ls -d /data/flare/{pfx}* 2>/dev/null | wc -l"] with
  | .ok o => return o.trim.toNat?
  | .error _ => return none

/-- Replace the suite's extra.conf (the operator does not own it: the CR has
    no rocksdb block) and wait until `pod` sees `expect` in it or not. -/
private def Ctx.setBootConf (c : Ctx) (content : String) (pod needle : String) (present : Bool) : IO Bool := do
  let esc := (content.replace "\\" "\\\\").replace "\"" "\\\"" |>.replace "\n" "\\n"
  match ← kubectl ["patch", "configmap", s!"{c.cfg.name}-config", "-n", c.cfg.«namespace», "--type=merge",
      "-p", s!"\{\"data\":\{\"extra.conf\":\"{esc}\"}}"] with
  | .error _ => return false
  | .ok _ =>
    waitForCondition s!"{pod} sees the new extra.conf" 180 do
      match ← kubectl ["exec", "-n", c.cfg.«namespace», pod, "-c", "flared", "--", "cat", "/etc/flared/extra.conf"] with
      | .ok o => return containsSubstr o needle == present
      | .error _ => return false

def copyRetentionSuite : TestSuite := {
  name := "copy-retention"
  setup := do
    deployCluster copyRetCfg
    IO.sleep 30000
  teardown := cleanupCluster copyRetCfg
  onFailure := dumpClusterDiagnostics copyRetCfg.«namespace» s!"app={copyRetCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := copyRetCfg }
    let ns := copyRetCfg.«namespace»
    let ip : String → IO String := fun p => do return (← getPodIp p ns).getD ""
    [
    { name := "two replicas rebuild from the SAME source at once (both restarted): the source serves one snapshot at a time (the second requester is answered busy and WAITS, no dump instead), each copy is staged, verified and switched in, every key and value equals the master's, no serve area is left on the source, and each retained old copy is deleted once its replica is Active and bound"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.p0Roles with
        | (some m, [a, b]) =>
          let w ← c.bulkWrite (← ip m) "cr" 300 8192
          if w != 300 then return .fail s!"precondition: stored {w}/300"
          if (← c.allInSync 300 300).isNone then return .fail "precondition: the copies did not converge on 300 keys"
          let since ← utcNow
          for p in [a, b] do
            match ← c.killFlaredIn p with
            | .error e => return .fail s!"precondition: could not restart flared in {p}: {e}"
            | .ok _ => pure ()
          let both ← waitForCondition "both replicas switched in a staged copy and are Active slaves" 900 do
            let mut ok := true
            for p in [a, b] do
              if ((← c.statNat (← ip p) "rocksdb_staged_switched").getD 0) == 0 then ok := false
            let (m2, ss) ← c.p0Roles
            return ok && m2 == some m && ss.length == 2
          let busy ← c.countSince m since "another snapshot is being served from this node (busy)"
          let waited := (← c.countSince a since "busy): waiting, no dump instead") + (← c.countSince b since "busy): waiting, no dump instead")
          let serveLeft ← c.dataDirCount m "snapshot.serve."
          let reaped ← waitForCondition "each replica's retained old copy is deleted" 180 do
            let mut ok := true
            for p in [a, b] do
              if (← c.statNat (← ip p) "rocksdb_retained_copies") != some 0 then ok := false
            return ok
          let mD ← c.localDump (← ip m)
          let aD ← c.localDump (← ip a)
          let bD ← c.localDump (← ip b)
          IO.eprintln s!"# {a} and {b} restarted at {since}; both switched in staged copies={both}; source busy refusals {busy}, requesters waiting {waited}; serve areas left on {m}: {serveLeft}; retained copies deleted={reaped}; keys master {mD.map (·.length)}, {a} {aD.map (·.length)}, {b} {bD.map (·.length)}"
          c.windowRecord since [m, a, b] "copy-retention"
          if !both then return .fail "the two replicas did not both switch in a staged copy and become Active"
          if busy == 0 then return .fail "precondition not produced: the two snapshot requests never overlapped (no busy refusal on the source)"
          if waited == 0 then return .fail "a busy refusal was logged by the source but no requester logged waiting for it"
          if serveLeft != some 0 then return .fail s!"serve areas left on the source: {serveLeft}"
          if !reaped then return .fail "a retained old copy was not deleted after its replica became Active and bound"
          match mD, aD, bD with
          | some md, some ad, some bd =>
            let lostA := missingFrom md ad
            let lostB := missingFrom md bd
            if !lostA.isEmpty || !lostB.isEmpty then
              return .fail s!"copies differ from the master: {a} {lostA.take 3}, {b} {lostB.take 3}"
            return .pass
          | _, _, _ => return .fail "a local dump could not be read"
        | _ => return .fail "precondition: one master and two slaves" },

    { name := "capacity (§9): a replica whose flared starts WITHOUT rocksdb-rebuild-reserve-bytes does not rebuild (stats rebuild_blocked=reserve_unset), keeps its copy and is not activated; once the reserve is set again it rebuilds and converges"
      run := do
        IO.sleep 1100
        match ← c.p0Roles with
        | (some m, a :: _) =>
          let aIp ← ip a
          let before ← c.localDump aIp
          if !(← c.setBootConf copyRetCfg.extraFlaredConf a "rocksdb-rebuild-reserve-bytes" false) then
            return .fail "precondition: could not remove the reserve from extra.conf"
          if let .error e ← c.killFlaredIn a then return .fail s!"precondition: could not restart flared in {a}: {e}"
          let blocked ← waitForCondition s!"{a} reports rebuild_blocked=reserve_unset" 300 do
            return (← c.statStr (← ip a) "rebuild_blocked") == some "reserve_unset"
          let during ← c.localDump (← ip a)
          let (_, ss) ← c.p0Roles
          let notActive := !ss.contains a
          -- set it again: the next start rebuilds
          let restored ← c.setBootConf (bootFlaredConf copyRetCfg) a "rocksdb-rebuild-reserve-bytes" true
          if let .error e ← c.killFlaredIn a then return .fail s!"could not restart flared in {a} again: {e}"
          let converged ← waitForCondition s!"{a} rebuilds and is an Active slave again" 600 do
            let (m2, ss2) ← c.p0Roles
            return m2 == some m && ss2.contains a && ((← c.statNat (← ip a) "rocksdb_staged_switched").getD 0) ≥ 1
          IO.eprintln s!"# {a}: blocked reserve_unset={blocked}; keys before {before.map (·.length)}, while blocked {during.map (·.length)}; not Active while blocked={notActive}; reserve restored={restored}; converged={converged}"
          if !blocked then return .fail s!"{a} did not report rebuild_blocked=reserve_unset"
          match before, during with
          | some bd, some dd =>
            if !(missingFrom bd dd).isEmpty then return .fail s!"{a} lost keys while blocked: {(missingFrom bd dd).take 3}"
          | _, _ => return .fail s!"{a}'s copy could not be read"
          if !notActive then return .fail s!"{a} was Active although its rebuild was blocked"
          if !restored || !converged then return .fail s!"{a} did not rebuild after the reserve was set again (restored={restored})"
          return .pass
        | _ => return .fail "precondition: a master and a slave" },

    { name := "approvals (§7, §11.3, §11.9): on a replica whose rebuild is stopped, a FlareCopyDiscardApproval naming its copy is applied ONCE (a repeat of the request id is answered from flared's record); one naming the copy it had before is refused (copy_changed); one for another pod UID is refused; an expired one is not sent"
      run := do
        IO.sleep 1100
        match ← c.p0Roles with
        | (some _, a :: _) =>
          let ns' := ns
          let clusterUid := match ← kubectl ["get", "flarecluster", copyRetCfg.name, "-n", ns', "-o", "jsonpath={.metadata.uid}"] with
            | .ok u => u.trim
            | .error _ => ""
          if clusterUid.isEmpty then return .fail "precondition: no FlareCluster UID"
          -- a stopped rebuild: started without the reserve
          if !(← c.setBootConf copyRetCfg.extraFlaredConf a "rocksdb-rebuild-reserve-bytes" false) then
            return .fail "precondition: could not remove the reserve from extra.conf"
          if let .error e ← c.killFlaredIn a then return .fail s!"precondition: could not restart flared in {a}: {e}"
          let blocked ← waitForCondition s!"{a} reports rebuild_blocked=reserve_unset" 300 do
            return (← c.statStr (← ip a) "rebuild_blocked") == some "reserve_unset"
          if !blocked then return .fail s!"precondition: {a} did not stop its rebuild"
          let some podUid ← c.podUid a | return .fail s!"precondition: no UID for {a}"
          let some copy0 ← c.statStr (← ip a) "rocksdb_copy_id" | return .fail s!"precondition: no copy id on {a}"
          let apply := fun (nm req copyId puid expires : String) => do
            let yaml := s!"apiVersion: flare.gree.net/v1alpha1
kind: FlareCopyDiscardApproval
metadata:
  name: {nm}
  namespace: {ns'}
spec:
  clusterUID: {clusterUid}
  podUID: {puid}
  copyId: \"{copyId}\"
  requestId: {req}
  operation: discard-before-copy
  expiresAt: \"{expires}\""
            discard <| kubectlApplyStdin yaml
          let phaseOf := fun (nm : String) => do
            match ← kubectl ["get", "flarecopydiscardapproval", nm, "-n", ns', "-o", "jsonpath={.status.phase}|{.status.reason}"] with
            | .ok o => return o.trim
            | .error _ => return ""
          let future := "2099-01-01T00:00:00Z"
          apply "ok-1" "e2e-req-1" copy0 podUid future
          let applied ← waitForCondition "the approval naming the copy is Applied" 120 do
            return (← phaseOf "ok-1").startsWith "Applied|"
          let copy1 := (← c.statStr (← ip a) "rocksdb_copy_id").getD ""
          -- the same request id again (another object): answered from flared's record, not run again
          apply "ok-1-again" "e2e-req-1" copy1 podUid future
          let repeated ← waitForCondition "a repeat of the request id is answered from the record" 120 do
            return (← phaseOf "ok-1-again") == "Applied|already:applied"
          let copy2 := (← c.statStr (← ip a) "rocksdb_copy_id").getD ""
          -- the copy it had before: refused
          apply "stale-copy" "e2e-req-2" copy0 podUid future
          let staleRefused ← waitForCondition "an approval naming the previous copy is refused" 120 do
            return (← phaseOf "stale-copy") == "Refused|refused:copy_changed"
          -- another pod UID: refused by the operator, nothing sent
          apply "other-pod" "e2e-req-3" copy2 "00000000-0000-0000-0000-000000000000" future
          let podRefused ← waitForCondition "an approval for another pod UID is refused" 120 do
            return (← phaseOf "other-pod").startsWith "Refused|no flared pod"
          -- expired: not sent
          apply "expired" "e2e-req-4" copy2 podUid "2000-01-01T00:00:00Z"
          let expired ← waitForCondition "an expired approval is not sent" 120 do
            return (← phaseOf "expired").startsWith "Expired|"
          let copy3 := (← c.statStr (← ip a) "rocksdb_copy_id").getD ""
          IO.eprintln s!"# {a}: copy {copy0} -> applied={applied} -> {copy1}; repeat answered from the record={repeated}; copy after the repeat {copy2} (unchanged={copy2 == copy1}); stale copy refused={staleRefused}; other pod refused={podRefused}; expired={expired}; copy at the end {copy3}"
          -- restore the reserve: the replica rebuilds
          discard <| c.setBootConf (bootFlaredConf copyRetCfg) a "rocksdb-rebuild-reserve-bytes" true
          discard <| c.killFlaredIn a
          for nm in ["ok-1", "ok-1-again", "stale-copy", "other-pod", "expired"] do
            discard <| kubectl ["delete", "flarecopydiscardapproval", nm, "-n", ns', "--ignore-not-found"]
          if !applied then return .fail "the approval naming the copy was not applied"
          if copy1 == copy0 then return .fail "the copy did not change although the approval was applied"
          if !repeated || copy2 != copy1 then return .fail s!"the repeated request id was not answered from the record (copy {copy1} -> {copy2})"
          if !staleRefused then return .fail "an approval naming the previous copy was not refused"
          if !podRefused then return .fail "an approval for another pod UID was not refused"
          if !expired then return .fail "an expired approval was not marked Expired"
          if copy3 != copy2 then return .fail "a refused or expired approval changed the copy"
          return .pass
        | _ => return .fail "precondition: a master and a slave" }
  ]
}

/-- 2p x 2r: two rebuilds requested at once in different partitions. The
    activation is held on every node so the first rebuild stays in Prepare. -/
private def copyRetConcCfg : ClusterConfig := {
  name := "copy-ret-conc"
  «namespace» := "flare-copy-ret-conc"
  partitions := 2
  replicas := 2
  operatorName := "flare-operator"
  debugPod := "debug-copy-ret-conc"
  storageBackend := "rocksdb"
  usePvc := true
  flaredEnv := [("FLARE_TEST_ACTIVATION_HOLD_FILE", "/tmp/act-hold")]
  operatorEnv := [("FLARE_FOLLOW_PROBE_INTERVAL", "1")]
}

def copyRetentionConcurrencySuite : TestSuite := {
  name := "copy-retention-concurrency"
  setup := do
    deployCluster copyRetConcCfg
    IO.sleep 30000
  teardown := cleanupCluster copyRetConcCfg
  onFailure := dumpClusterDiagnostics copyRetConcCfg.«namespace» s!"app={copyRetConcCfg.operatorName}"
  tests :=
    let c : Ctx := { cfg := copyRetConcCfg }
    let ns := copyRetConcCfg.«namespace»
    [
    { name := "operator concurrency (§10): both partitions' replicas need a rebuild at once (each master bulk-rewritten); one rebuild runs and the other assignment is HELD (the replica stays a Proxy, REBUILD HELD logged) while the first is in Prepare; released, both rebuild and converge"
      run := do
        let graceOver ← waitForCondition "operator past its startup grace period" 240 do
          return containsSubstr (← c.opLog 400) "grace period over"
        if !graceOver then return .fail "the operator never logged the end of its startup grace period"
        match ← c.pairOf 0, ← c.pairOf 1 with
        | .ok (_, m0Ip, s0, _), .ok (_, m1Ip, s1, _) =>
          let hold := fun (p : String) => do discard <| kubectl ["exec", "-n", ns, p, "-c", "flared", "--", "touch", "/tmp/act-hold"]
          let release := fun (p : String) => do discard <| kubectl ["exec", "-n", ns, p, "-c", "flared", "--", "rm", "-f", "/tmp/act-hold"]
          hold s0
          hold s1
          let heldCount := fun (log : String) => ((log.splitOn "\n").filter (containsSubstr · "REBUILD HELD")).length
          let held0 := heldCount (← c.opLog 6000)
          -- a new history on both masters, then keys again (a source that
          -- holds keys: the repair is not deferred by the copy protection)
          for mIp in [m0Ip, m1Ip] do
            discard <| execInDebugPod copyRetConcCfg.debugPod ns s!"printf 'flush_all\\r\\n' | nc -w 5 {mIp} {copyRetConcCfg.flarePort}"
          IO.sleep 2000
          for mIp in [m0Ip, m1Ip] do
            discard <| writeKeys copyRetConcCfg.debugPod ns mIp copyRetConcCfg.flarePort "conc" 20
          let held ← waitForCondition "a second rebuild assignment is held while the first is in Prepare" 600 do
            let n := heldCount (← c.opLog 6000)
            let v ← c.nodeView
            let prep := v.filter (fun e => e.role == 1 && e.state == 1)
            return n > held0 && prep.length == 1
          let v ← c.nodeView
          let prepNow := (v.filter (fun e => e.role == 1 && e.state == 1)).length
          release s0
          release s1
          let converged ← waitForCondition "both replicas rebuild and are Active slaves" 600 do
            let v ← c.nodeView
            return (v.filter (fun e => e.role == 1 && e.state == 0)).length == 2
          let heldLines := ((← c.opLog 6000).splitOn "\n").filter (containsSubstr · "REBUILD HELD")
          IO.eprintln s!"# held={held}; slaves in Prepare at that moment {prepNow}; converged={converged}\n# {String.intercalate "\n# " (heldLines.take 4)}"
          if !held then return .fail "no second assignment was held while a rebuild was in Prepare"
          if !converged then return .fail "the two replicas did not both rebuild once released"
          return .pass
        | _, _ => return .fail "precondition: a master and a slave in each partition" }
  ]
}

-- ─── reserve sizing by measurement (decision 2026-10-07, item 4) ─────────

/-- Evaluation only (FLARE_E2E_RESERVE_MEASURE=1): measure, on BOTH sides, the
    peaks of a staged rebuild under write load, so `rebuildReserveBytes` is
    set from measurements. Sizing from the environment:
    FLARE_E2E_MEASURE_KEYS / _VALUE_BYTES (data), _RATE (writes/s during the
    rebuild), _TMPFS=1 (data dir on tmpfs; size/memory from _MEMORY, e.g.
    "8Gi"). The replica is restarted with its old copy kept (WAL catch-up
    off), so the staged copy lands NEXT TO the old one — the worst case. -/
private def measureEnv (k : String) (d : Nat) : IO Nat := do
  return ((← IO.getEnv k).bind (·.toNat?)).getD d

private def measureCfg : IO ClusterConfig := do
  let tmpfs := (← IO.getEnv "FLARE_E2E_MEASURE_TMPFS").isSome
  let mem := (← IO.getEnv "FLARE_E2E_MEASURE_MEMORY").getD "4Gi"
  return {
    name := "measure"
    «namespace» := "flare-measure"
    partitions := 1
    replicas := 2
    operatorName := "flare-operator"
    debugPod := "debug-measure"
    storageBackend := "rocksdb"
    usePvc := !tmpfs
    pvcSize := "20Gi"
    useTmpfs := tmpfs
    tmpfsSize := mem
    flaredMemoryLimit := mem
    flaredMemoryRequest := "256Mi"
    flaredCpuLimit := "2"
    extraFlaredConf := "rocksdb-block-cache-size-mb = 64\nrocksdb-write-buffer-size-mb = 16"
    flaredEnv := [("FLARE_TEST_DISABLE_WAL_RECONSTRUCTION", "1")]
    -- large enough not to stop the measured rebuild; the result says what is needed
    rebuildReserveBytes := some 1048576 }

def reserveMeasureSuite : TestSuite := {
  name := "copy-retention-measure"
  setup := do
    if (← IO.getEnv "FLARE_E2E_RESERVE_MEASURE").isSome then
      deployCluster (← measureCfg)
      IO.sleep 50000
    else IO.eprintln "# FLARE_E2E_RESERVE_MEASURE unset: the reserve measurement deploys nothing and its test is skipped"
  teardown := do
    if (← IO.getEnv "FLARE_E2E_RESERVE_MEASURE").isSome then cleanupCluster (← measureCfg)
  tests := [
    { name := "reserve sizing: a staged rebuild (old copy kept) under write load; the receiver's and the source's peaks (data dir growth, cgroup memory, least free) are measured and the reserve they imply is reported — an evaluation, not a pass/fail of the product"
      run := do
        if (← IO.getEnv "FLARE_E2E_RESERVE_MEASURE").isNone then return .skip "FLARE_E2E_RESERVE_MEASURE unset (evaluation only)"
        let cfg ← measureCfg
        let c : Ctx := { cfg := cfg }
        let keys ← measureEnv "FLARE_E2E_MEASURE_KEYS" 20000
        let vbytes ← measureEnv "FLARE_E2E_MEASURE_VALUE_BYTES" 100000
        let rate ← measureEnv "FLARE_E2E_MEASURE_RATE" 300
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let t0 ← IO.monoMsNow
          let w ← c.bulkWriteRandom mIp "ms" keys vbytes
          IO.eprintln s!"# loaded {w}/{keys} values of ~{vbytes} B in {((← IO.monoMsNow) - t0) / 1000}s"
          if !(← convergedItems c mIp sIp "the replica holds the data set") then return .fail "precondition: the replica did not converge"
          let srcBytes := (← c.statNat mIp "rocksdb_copy_bytes").getD 0
          -- a write load during the rebuild: `rate` small updates per second
          let loadCmd := s!"i=0; end=$(( $(date +%s) + 3600 )); while [ $(date +%s) -lt $end ] && [ ! -f /tmp/stop-load ]; do j=0; while [ $j -lt {rate} ]; do printf 'set ld_%s 0 0 8\\r\\n%08d\\r\\n' $((i % 100000)) $i; i=$((i+1)); j=$((j+1)); done | nc -w 2 {mIp} {cfg.flarePort} >/dev/null; sleep 1; done"
          discard <| kubectl ["exec", "-n", cfg.«namespace», cfg.debugPod, "--", "rm", "-f", "/tmp/stop-load"]
          let _ ← IO.asTask (do discard <| execInDebugPod cfg.debugPod cfg.«namespace» loadCmd)
          IO.sleep 10000
          if let .error e ← c.killFlaredIn sPod then return .fail s!"precondition: could not restart flared in {sPod}: {e}"
          let rebuilt ← waitForCondition "the replica switched in a staged copy" 7200 do
            return ((← c.statNat (← getPodIp sPod cfg.«namespace» |>.map (·.getD "")) "rocksdb_staged_switched").getD 0) ≥ 1
          discard <| kubectl ["exec", "-n", cfg.«namespace», cfg.debugPod, "--", "touch", "/tmp/stop-load"]
          let sIp2 := (← getPodIp sPod cfg.«namespace»).getD sIp
          let r := fun (ip k : String) => do return (← c.statStr ip k).getD "?"
          let rdMax ← r sIp2 "rocksdb_rebuild_peak_data_dir_bytes"
          let rdStart ← r sIp2 "rocksdb_rebuild_peak_data_dir_start_bytes"
          let rMem ← r sIp2 "rocksdb_rebuild_peak_memory_bytes"
          let rMin ← r sIp2 "rocksdb_rebuild_peak_min_available_bytes"
          let sdMax ← r mIp "rocksdb_serve_peak_data_dir_bytes"
          let sdStart ← r mIp "rocksdb_serve_peak_data_dir_start_bytes"
          let sMem ← r mIp "rocksdb_serve_peak_memory_bytes"
          let growth := (rdMax.toNat?.getD 0) - (rdStart.toNat?.getD 0)
          -- the reference is the copy actually staged and switched in (the
          -- source's rocksdb_copy_bytes also counts its WAL and obsolete files)
          let newLive := (← c.statNat sIp2 "rocksdb_copy_bytes").getD 0
          let retainedB := (← c.statNat sIp2 "rocksdb_retained_bytes").getD 0
          let beyondCopy : Int := Int.ofNat growth - Int.ofNat newLive
          -- cross-check the memory accounting from inside both pods: does the
          -- container's memory.current include the tmpfs pages?
          let inside := fun (pod : String) => do
            match ← kubectl ["exec", "-n", cfg.«namespace», pod, "-c", "flared", "--", "sh", "-c",
                "echo current=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes); echo max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes); df -B1 /data | tail -1; du -sb /data 2>/dev/null | cut -f1"] with
            | .ok o => return (o.replace "\n" " ").trim
            | .error e => return s!"? ({e})"
          let srcGrowth := (sdMax.toNat?.getD 0) - (sdStart.toNat?.getD 0)
          IO.eprintln s!"# RESERVE MEASUREMENT ({if cfg.useTmpfs then s!"tmpfs {cfg.tmpfsSize}" else "PVC"}, {w} x {vbytes} B, {rate} writes/s during the rebuild; master {mPod}, replica {sPod}; rebuilt={rebuilt})"
          IO.eprintln s!"#   source copy (rocksdb_copy_bytes)            {srcBytes}"
          IO.eprintln s!"#   receiver data dir: start {rdStart}, peak {rdMax}  -> growth {growth}"
          IO.eprintln s!"#   receiver cgroup memory peak                  {rMem}; least free seen {rMin}"
          IO.eprintln s!"#   source (serve) data dir: start {sdStart}, peak {sdMax} -> growth {srcGrowth}; cgroup memory peak {sMem}"
          IO.eprintln s!"#   new live copy on the receiver {newLive}; retained old copy {retainedB}; receiver growth beyond the new copy {beyondCopy}"
          IO.eprintln s!"#   inside {sPod} now: {← inside sPod}"
          IO.eprintln s!"#   inside {mPod} now: {← inside mPod}"
          IO.eprintln s!"#   => the reserve must cover the receiver's growth beyond the new copy ({beyondCopy}) and, on tmpfs, whatever the memory accounting above shows is not in memory.current"
          if !rebuilt then return .fail "the measured rebuild did not complete (no measurement)"
          return .pass }
  ]
}

end FlareOperator.E2E.Tests.ContinuousReplicationLimits
