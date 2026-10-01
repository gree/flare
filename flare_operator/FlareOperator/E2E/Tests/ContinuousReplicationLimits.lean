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

-- Two partitions: the lagged-successor test loses one master, which must be
-- 25% of the nodes. In a 1-partition x 2-replica cluster one master is 50%,
-- which trips the circuit breaker at its default threshold, and failover is
-- then paused by design (finding recorded under EV-09, 2026-10-02).
private def limitsCfg : ClusterConfig := {
  name := "cont-repl-limits"
  «namespace» := "flare-cont-repl-limits"
  partitions := 2
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
          IO.eprintln s!"# failover: promoted={promoted}; NOT LOSS-FREE logged={notLossFree}; items old master={mItems} new master={newItems} (gap {mItems - newItems})"
          if !promoted then return .fail "the lagged follower was not promoted: the partition stayed without a master"
          if !notLossFree then return .fail "the lagged follower was promoted without the NOT LOSS-FREE line"
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
            let chunk := 20000
            let items0 ← c.currItems mIp
            let mut loaded := 0
            let t0 ← IO.monoMsNow
            let mut i := 0
            while i < n do
              let m := min chunk (n - i)
              let cmd := s!"(awk -v s={i} -v m={m} 'BEGIN\{for(k=s;k<s+m;k++) printf \"set s%d 0 0 16\\r\\n0123456789abcdef\\r\\n\", k}'; sleep 15) | nc -w 60 {mIp} {scaleCfg.flarePort} | grep -c STORED"
              match ← execInDebugPod scaleCfg.debugPod scaleCfg.«namespace» cmd with
              | .ok o => loaded := loaded + (o.trim.toNat?.getD 0)
              | .error e => IO.eprintln s!"# chunk at {i} failed: {e}"
              i := i + m
            let loadMs := (← IO.monoMsNow) - t0
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

/-- T17: client-side latency of single `get`s while the load runs, from the
    debug pod. Each timing includes starting `nc`, so it is an UPPER bound on
    the request latency, comparable between master and replica and between
    rates, not an absolute service time. Returns "p50=… p99=… max=… n=…" in
    microseconds, or why it could not measure. -/
private def Ctx.latencyProbe (c : Ctx) (ip key : String) (n : Nat := 50) : IO String := do
  let cmd := s!"t=$(date +%s%N); case \"$t\" in *N*) echo 'no nanosecond clock in the debug pod'; exit 0;; esac; i=0; while [ $i -lt {n} ]; do s=$(date +%s%N); printf 'get {key}\\r\\n' | nc -w 2 {ip} {c.cfg.flarePort} >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e - s) / 1000 )); i=$((i+1)); done | sort -n | awk '\{a[NR]=$1} END \{if (NR==0) \{print \"no samples\"} else \{p=int((NR+1)/2); q=int(NR*0.99); if (q<1) q=1; print \"p50=\" a[p] \"us p99=\" a[q] \"us max=\" a[NR] \"us n=\" NR}}'"
  match ← execInDebugPod c.cfg.debugPod c.cfg.«namespace» cmd with
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
    let probeS ← IO.asTask (c.latencyProbe sIp "w1")
    let probeM ← IO.asTask (c.latencyProbe mIp "w1")
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
      deployCluster sustainedCfg
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
