# Production enablement gate

Status as of 2026-10-01: development/integration, not production-approved.
PR #144 integration and production WAL enablement are separate decisions.
Latest inspected baseline `fd76eed`: PR E2E 36869793917 (new 8-leg layout, all 198 tests, merge rev 13f8fe9) after the 2026-10-01 fixes (balance persisted across restart, SAF-11 breaker count, drain proof of the follower, startup-republish E2E); earlier baseline: `630ccec`: PR E2E 36820029377 (all five legs, tested at
the merge revision 9dc131f), 36816259807 at 0d29589 (merge rev b706686) and
36812371158 at e611531 (merge rev 80e466b), three green matrices in a row on
docs-only commits; the breaker tripped in 5 s, 5 s and 20 s in these runs —
the SAF-11 no-trip finding, 5 CI occurrences, the latest at 36796752122,
stays open.
Outage evaluation 36741586970 at 6e757cb all five legs; earlier fully green
PR matrix 36725742993 at c33fe5d. At b5f1c45: PR E2E 36713376306 (all five
legs, merge rev 89b8cdb), nix-linux 36713376269, evidence 36713376405; at 7e979b0: PR E2E 36707836842 (merge rev
4c78aba), nix-linux 36707836926, evidence 36707837351;
manual `evaluation=sustained` run 36707861123 (sustained lag 0 at 300/900
keys/s, falls behind at 2000 keys/s; one harness-precondition failure in
wal-recovery, see docs/reports/2026-09-30-sustained-after-more-fix.md). These
passes do not cover later commits, the other opt-in evaluations, or every
condition below. All EV verification
states remain unchanged; the evidence register owns their status.

## First decide the required data-loss guarantee

**Decided 2026-10-02 by the user: asynchronous durability is accepted.**
A write the master acknowledged but had not delivered to a replica is lost
if the master's data is lost. RPO equals the replication lag at that moment.
The lagged-successor E2E records that gap.

A promotion that logs no `PROMOTION NOT LOSS-FREE` warning was proven within
the promotion bound (`FLARE_FOLLOW_PROMOTE_LAG`, default 100 positions). It
can still lose up to that many positions without a warning (48 items in CI
36909742559). Set the bound to the loss you accept silently. The text below
is kept as the statement of what was decided.

Continuous replication repairs transient delivery gaps while the authoritative
master/history survives. It does NOT guarantee that a successfully acknowledged
write survives loss of the master's data before replica delivery. If that is
the deployment's requirement, production is blocked on a separate synchronous
acknowledgement/durability, promotion and writer-fencing design. Snapshots,
backups, strict local syncWrites, and a green CI run do not by themselves close
that gap. Record the agreed failure model and RPO/RTO before approval.

## Remaining implementation / policy decisions

- SAF-09: recover safely from leader-generation regression, with a durable
  authority source rather than trusting an arbitrary recipient's high number.
  Delivery retry and fresh UID-bracketed observations are implemented; complete
  restart/lease-loss recovery is not established.
- SAF-08: finish auditing typed observations and promotion/deletion decisions.
  Unit coverage does not close untested concurrent survivor changes.
- SAF-11: implemented 2026-10-01 (breaker counts nodes unavailable now, not only
  this tick's deaths); CI and reviewer confirmation of the definition pending.
- Specify the client-visible result when a stale slave cannot reach its master:
  legacy GET failure can look like a cache miss. Verify client fallback behavior.
- Memory knobs are implemented. Render-time validation exists since
  2026-10-02. The chart fails when the RocksDB floor reaches the flared memory
  limit. The floor is block cache plus 2 column families × write buffer ×
  buffers. The chart warns when the floor is above 70% of the limit, or when
  floor plus tmpfs size exceeds it. Proof of the effective running budgets
  (RSS under load) is still missing. No automatic restart is performed.

## Required acceptance and capacity evidence

- Run CI at the actual release candidate and assess relevant controls. Stage
  startup republish and same-name Pod replacement independently, including
  stats failures and non-WAL read eligibility recovery. Startup republish
  alone has an E2E (CHECK-01-startup, audit off) that passes on CI.
  Same-name Pod replacement (topology probe), an operator restart while stats
  are unreadable, and non-WAL read recovery after a restart now have E2E tests
  that pass on CI (PR runs 36874157713 and 36877273395). Follow-evidence reads
  are not UID-bracketed.
- Sustained 900/2000 writes/s after the MORE fix: measured once on CI (lag 0 at
  900, ≈+18k/min deficit at 2000, drain 35–43 s). With flared at 2 CPU cores
  instead of the E2E default 500m (run 37007519007) lag stayed 0 at 2000/s and
  apply-lock hold max fell from 295 ms to 23 ms, so the deficit was the CPU
  limit. The noreply window for forwards gave no gain (run 37007523321: fell
  behind at 2000/s with CPU 2) and stays off. Still define the target rate,
  acceptable replication lag and recovery time from production traffic, and
  re-measure on production-like hardware; the kind figure bounds nothing.
- Hold a replica offline long enough to force WAL rotation, flush and compaction:
  measured on CI (outage evaluation runs 1-3, 256 MB cap, PVC): 150 MB of retained
  WAL caught up from the cursor in 11 s; 400 MB overshot the cap to 499 MB and stayed
  there on an idle master for 22 min (the cap is enforced by flush/compaction
  cleanup, not by time); with writes continuing, one flush cut it to 250 MB and the
  follower was told lsn_purged and rebuilt by snapshot in 59 s. Data dir 1.07 GB,
  RSS 620 MB high-water. Still needed: the same on production hardware and tmpfs,
  and an archive budget of cap + bytes-between-cleanups in the sizing rule.
- Measure T17 lock hold time/starvation, read/proxy latency and control-loop
  lease renewal under load, including actual configured memory limits.
  Measured on kind on 2026-10-02 (run 36918289515):
  - get p50 2.2–3.6 ms and p99 50–98 ms, the same on replica and master;
  - reconcile 2.1–3.1 s per pass;
  - lease age at most 8 s of 15 s.

  Lock hold time itself is not instrumented. Re-measure on production
  hardware.
- Measure startup and probes with production-scale data; test backup restoration
  and large failover rebuilds rather than extrapolating small-dataset timing.
  At 2M keys on kind (run 36914128803):
  - the reopen exact scan took 1.46 s;
  - the probe took at most 3.46 s;
  - the follower needed 17.7 min after a 26 min load to drain.

  Size follow throughput against the real write rate. 15.8M keys needs a
  faster loader.

  Master memory, 2026-10-02. Without a bound, a master whose follower is
  slower than the write rate buffered every pending forward: 1.7 GB at 6M
  keys, then an OOM and a failover that lost about 1.83M acknowledged
  writes. The chart now defaults `cluster.rocksdb.maxTotalThreadQueue` to
  200000. With the bound:
  - master heap stays at about 200 MB;
  - forwards over the bound are dropped and counted;
  - the follower fills them from the WAL with no rebuild (runs 36985410132
    and 36991784765).

  The cost is slower convergence: 28 min after a 2M-key load, against
  18.5 min without the bound. Failover also refuses a follower more than
  `FLARE_FOLLOW_FAILOVER_MAX_LAG` (default 100000) behind. Until 2026-10-03 the
  masterless refill crowned that follower in the same pass anyway, so the
  bound protected nothing. The refill now holds the partition masterless for
  up to `FLARE_FOLLOW_FAILOVER_WAIT_SECONDS` (default 300) while the
  ex-master is away; E2E `continuous-replication-lag-hold` PASS (PR run
  37035470146: the follower 140 positions behind was never promoted, the
  ex-master returned as master with every acknowledged write).
- Stage both repair triggers concurrently and lagged/unknown promotion and
  deletion gates. Record failures, not just successful reruns.

## Operational rollout gate

- Select storage durability (PVC versus volatile tmpfs), memory/cache/buffer
  budgets, WAL retention, read policy, probes, backup/restore and rollback plan.
  Pod deletion on tmpfs deletes data; a configuration rollback cannot recover it.
- Enable identity-aware forwarding on every relevant node before continuous
  following. Verify the mixed-version rollout path and runtime settings.
  E2E `continuous-replication-enable` (2026-10-03, CI pending) runs this on a
  live legacy cluster through the CR, and back, and records whether enabling
  following rebuilds the replica.
- Install and exercise alerts/runbooks, including topology feedback. Audit one
  node per pass must cover the intended cluster within the freshness window.
- Start with a bounded canary, define stop/rollback criteria, and record an
  explicit reviewer/release-owner acceptance of residual risks. Do not promote
  all EVs to verified or equate mergeability with production approval.

Suggested order: settle RPO/failure model; close control-plane recovery risks;
run sustained/long-outage and resource tests in CI or a production-sized staging
environment; rehearse restore/rollback; then approve a canary.
