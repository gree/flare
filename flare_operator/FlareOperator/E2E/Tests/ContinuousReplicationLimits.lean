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

namespace FlareOperator.E2E.Tests.ContinuousReplicationLimits

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.Kubectl

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
          let rejoined ← waitForCondition "the returning ex-master follows the new master and matches" 480 do
            match ← getPodIp mPod holdExpiryCfg.«namespace» with
            | none => return false
            | some ip => return (← c.statStr ip "repl_follow_state") == some "following" && (← c.currItems ip) == (← c.currItems sIp)
          IO.eprintln s!"# ex-master {mPod} follows the new master={rejoined}; items={← c.currItems sIp} (the follower had {sItems} at the kill)"
          if !rejoined then return .fail "the returning ex-master did not follow the new master"
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
}

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
          let following ← waitForCondition "the replica follows after enablement" 420 do
            let st := (← c.statStr sIp "repl_follow_state").getD "?"
            let reason := (← c.statStr sIp "repl_follow_last_reason").getD ""
            let entry := if reason.isEmpty then st else s!"{st}({reason})"
            states.modify fun l => if l.getLast? == some entry then l else l ++ [entry]
            return st == "following" && (← c.statNat sIp "reconstruction_started").getD 0 > recon0
          let recon1 := (← c.statNat sIp "reconstruction_started").getD 0
          let purgedSeen := (← states.get).any (containsSubstr · "lsn_purged")
          IO.eprintln s!"# follow on: states seen {← states.get}; lsn_purged seen={purgedSeen}; reconstruction_started {recon0}→{recon1}; following={following}"
          if !following then return .fail s!"expected one rebuild then following; states {← states.get}, reconstruction_started {recon0}→{recon1}"
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
}

private def rebuildTmpfsPatch (identity follow : Bool) : String :=
  s!"\{\"spec\":\{\"rocksdb\":\{\"blockCacheSizeMb\":16,\"writeBufferSizeMb\":4,\"walTtlSeconds\":60,\"walSizeLimitMb\":16,\"replIdentityForward\":{identity},\"replFollowEnabled\":{follow},\"replFollowPollIntervalUsec\":200000}}}"

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
    { name := "space-aware rebuild on tmpfs: a live replica rebuild where two copies do not fit (tmpfs = memory limit, like pf-dev) discards the stale copy before staging; the rebuild succeeds without an OOM restart and the data is equal"
      run := do
        match ← c.pair with
        | .error e => return .fail e
        | .ok (mPod, mIp, sPod, sIp) =>
          let w0 ← writeKeys rebuildTmpfsCfg.debugPod rebuildTmpfsCfg.«namespace» mIp rebuildTmpfsCfg.flarePort "legacy" 50
          let big ← c.bulkWriteRandom mIp "rnd" 2400 50000
          if w0 != 50 || big < 2400 then return .fail s!"legacy writes: stored {w0}/50 and {big}/2400 random"
          if !(← convergedItems c mIp sIp "legacy: replica matches the master") then
            return .fail s!"legacy: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          IO.sleep 90000
          let big2 ← c.bulkWriteRandom mIp "rnd2" 100 50000
          let rc0 ← c.restartCount sPod
          let disc0 := (← c.statNat sIp "rocksdb_rebuild_stale_discarded").getD 0
          let snap0 := (← c.statNat sIp "rocksdb_snapshot_bootstrap").getD 0
          let data0 ← match ← kubectl ["exec", "-n", rebuildTmpfsCfg.«namespace», sPod, "--", "sh", "-c", "du -sm /data | cut -f1"] with
            | .ok o => pure o.trim
            | .error _ => pure "?"
          IO.eprintln s!"# legacy: {big}+{big2} random values of ~50 kB; items {← c.currItems mIp}; replica data dir {data0} MB in a 384Mi tmpfs/memory limit; restarts {rc0}; discarded {disc0}; snapshot bootstraps {snap0}"
          match ← kubectlPatch "flarecluster" rebuildTmpfsCfg.name rebuildTmpfsCfg.«namespace» (rebuildTmpfsPatch true false) with
          | .error e => return .fail s!"patch (identity on) failed: {e}"
          | .ok _ => pure ()
          if !(← waitForCondition "both nodes reload repl_identity_forward 0 -> 1" 240 do bothReloaded c "repl_identity_forward: 0 -> 1") then
            return .fail "identity forwarding was not applied on both nodes"
          match ← kubectlPatch "flarecluster" rebuildTmpfsCfg.name rebuildTmpfsCfg.«namespace» (rebuildTmpfsPatch true true) with
          | .error e => return .fail s!"patch (follow on) failed: {e}"
          | .ok _ => pure ()
          let states ← IO.mkRef ([] : List String)
          let following ← waitForCondition "the replica is rebuilt and follows" 480 do
            let st := (← c.statStr sIp "repl_follow_state").getD "?"
            let reason := (← c.statStr sIp "repl_follow_last_reason").getD ""
            let entry := if reason.isEmpty then st else s!"{st}({reason})"
            states.modify fun l => if l.getLast? == some entry then l else l ++ [entry]
            return st == "following" && (← c.statNat sIp "rocksdb_snapshot_bootstrap").getD 0 > snap0
          let rc1 ← c.restartCount sPod
          let disc1 := (← c.statNat sIp "rocksdb_rebuild_stale_discarded").getD 0
          let snap1 := (← c.statNat sIp "rocksdb_snapshot_bootstrap").getD 0
          let discLine := match ← kubectl ["logs", "-n", rebuildTmpfsCfg.«namespace», sPod, "--tail=5000"] with
            | .ok o => (o.splitOn "\n").find? (containsSubstr · "will not fit next to ours")
            | .error _ => none
          IO.eprintln s!"# follow on: states {← states.get}; following={following}; replica restarts {rc0}→{rc1}; stale copy discarded {disc0}→{disc1}; snapshot bootstraps {snap0}→{snap1}\n# {discLine.getD "(no discard line)"}"
          if rc1 != rc0 then return .fail s!"the replica's container restarted during the rebuild ({rc0}→{rc1}): two copies did not fit"
          if disc1 != disc0 + 1 then return .fail s!"expected the stale copy to be discarded once before staging ({disc0}→{disc1})"
          if !following then return .fail s!"the replica was not rebuilt by snapshot and following (states {← states.get})"
          if !(← convergedItems c mIp sIp "after the rebuild: replica matches the master") then
            return .fail s!"after the rebuild: items master={← c.currItems mIp} replica={← c.currItems sIp}"
          if let some bad ← sampleEqual c mIp sIp [("legacy", 50)] then return .fail s!"value mismatch: {bad}"
          if (← masterPodOf c) != some mPod then return .fail "the master moved during the rebuild"
          return .pass }
  ]
}

-- ─── upgrade from the deployed release, on tmpfs = memory limit ───────────

-- pf-dev's 2026-10-05 roll in miniature: rc56 (no source epochs) rolled to
-- the build under test on tmpfs whose size equals the memory limit. The new
-- replica's snapshot from the old master carries no source epoch and is
-- refused; that refusal used to happen AFTER the swap, leaving the source's
-- copy in place for the fallback full dump to write a second one: OOM-killed
-- on every retry, the roll stuck.
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
    { name := "upgrade from rc56 (the deployed release) to this build on tmpfs = memory limit: the roll completes with no container restart; the new replica refuses the old master's epoch-less snapshot BEFORE the swap and rebuilds by full dump; data equal; writes work after"
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
          let refusedBefore ← do
            let mut seen := false
            for pod in [s!"{upgradeCfg.name}-nodes-0", s!"{upgradeCfg.name}-nodes-1"] do
              match ← kubectl ["logs", "-n", ns, pod, "--tail=20000"] with
              | .ok o => if containsSubstr o "refusing BEFORE the swap" then seen := true
              | .error _ => pure ()
            pure seen
          IO.eprintln s!"# roll: done={done} in {rollS}s; container restarts nodes-0={r0} nodes-1={r1}; last termination reasons [{oomKilled.2}]; epoch-less snapshot refused before the swap={refusedBefore}"
          if oomKilled.1 then return .fail s!"a flared container was OOMKilled during the roll ({oomKilled.2}): two copies did not fit"
          if !done then return .fail s!"the roll did not complete within 20 min (restarts nodes-0={r0} nodes-1={r1})"
          if r0 + r1 > 0 then return .fail s!"flared containers restarted during the roll (nodes-0={r0} nodes-1={r1}): two copies did not fit"
          if !refusedBefore then return .fail "the new replica never logged refusing the old master's snapshot before the swap (path not exercised)"
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

end FlareOperator.E2E.Tests.ContinuousReplicationLimits
