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
          IO.eprintln s!"# after the heal: follower state={st} reason={why} applied={← c.statNat sIp "repl_applied_lsn"} items master={← c.currItems mIp} replica={← c.currItems sIp}"
          if !declared then
            if st == "following" && (← c.currItems sIp) == (← c.currItems mIp) then
              return .fail s!"the WAL was NOT purged within the window (the follower caught up from {applied0}); retention knobs did not take effect — no lsn_purged staged"
            return .fail s!"expected needs_rebuild/lsn_purged, got {st}/{why}"
          let requested ← waitForCondition "operator files a repair request for the follower" 150 do
            return !(← c.ledgerDests).isEmpty || containsSubstr (← c.opLog) "REPLICA REPAIR requested"
          let rebuilt ← waitForCondition "follower reconstructed and following at the master's position" 480 do
            return (← c.statNat sIp "reconstruction_started").getD 0 > recon0
              && (← c.statStr sIp "repl_follow_state") == some "following"
              && (← c.currItems sIp) == (← c.currItems mIp)
          IO.eprintln s!"# rebuild: requested={requested}; reconstruction_started {recon0}→{(← c.statNat sIp "reconstruction_started").getD 0}; state={← c.statStr sIp "repl_follow_state"}; items master={← c.currItems mIp} replica={← c.currItems sIp}; wal_fallback_to_dump={← c.statNat sIp "rocksdb_wal_fallback_to_dump"} snapshot_bootstrap={← c.statNat sIp "rocksdb_snapshot_bootstrap"}; pod uid {uid0}→{(← c.podUid sPod).getD "?"}"
          if !requested then return .fail "no repair request was observed for the follower"
          if !rebuilt then return .fail s!"the follower was not rebuilt (state {← c.statStr sIp "repl_follow_state"}, items master={← c.currItems mIp} replica={← c.currItems sIp})"
          if (← c.podUid sPod).getD "?" != uid0 then return .fail "the replica pod was recreated"
          let empty ← waitForCondition "ledger empty" 240 do return (← c.ledgerDests).isEmpty
          if !empty then return .fail s!"ledger still holds {← c.ledgerDests}"
          return .pass }
  ]
}

-- ─── T9 (bounded): a far-behind replica, master memory, tombstone GC ────

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
  extraFlaredConf := flags
  operatorEnv := [("FLARE_STATS_PROBE_INTERVAL_MS", "15000")]
  usePvc := true
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
          | .ok (_, mIp, _, sIp) =>
            let chunk := 100000
            let mut loaded := 0
            let t0 ← IO.monoMsNow
            let mut i := 0
            while i < n do
              let m := min chunk (n - i)
              let cmd := s!"(awk -v s={i} -v m={m} 'BEGIN\{for(k=s;k<s+m;k++) printf \"set s%d 0 0 16\\r\\n0123456789abcdef\\r\\n\", k}'; sleep 8) | nc -w 30 {mIp} {scaleCfg.flarePort} | grep -c STORED"
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
            if loaded < n * 99 / 100 then return .fail s!"loaded only {loaded}/{n}"
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

end FlareOperator.E2E.Tests.ContinuousReplicationLimits
