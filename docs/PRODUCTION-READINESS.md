# Production enablement gate

Status as of 2026-09-30: development/integration, not production-approved.
PR #144 integration and production WAL enablement are separate decisions.
Latest inspected baseline `4a516e6` passed E2E 36290501385, nix-linux
36290501295 and evidence 36290501403. These passes do not cover new commits,
opt-in performance evaluations, or every condition below. All EV verification
states remain unchanged; the evidence register owns their status.

## First decide the required data-loss guarantee

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
- SAF-11: decide and implement circuit-breaker semantics for a majority outage
  spread over multiple reconcile ticks, not just deaths in one tick.
- Specify the client-visible result when a stale slave cannot reach its master:
  legacy GET failure can look like a cache miss. Verify client fallback behavior.
- Memory knobs are implemented; automatic memory-limit validation and proof of
  the effective running budgets are not. No automatic restart is performed.

## Required acceptance and capacity evidence

- Run CI at the actual release candidate and assess relevant controls. Stage
  startup republish and same-name Pod replacement independently, including
  stats failures and non-WAL read eligibility recovery.
- Rerun sustained 900/2000 writes/s after the MORE scheduling fix. Define target
  rate, acceptable replication lag and recovery time using production traffic.
- Hold a replica offline long enough to force WAL rotation, flush and compaction;
  prove memory/disk bounds, history-purge classification, rebuild and convergence.
  A small backlog test or flat disk usage before the first flush is insufficient.
- Measure T17 lock hold time/starvation, read/proxy latency and control-loop
  lease renewal under load, including actual configured memory limits.
- Measure startup and probes with production-scale data; test backup restoration
  and large failover rebuilds rather than extrapolating small-dataset timing.
- Stage both repair triggers concurrently and lagged/unknown promotion and
  deletion gates. Record failures, not just successful reruns.

## Operational rollout gate

- Select storage durability (PVC versus volatile tmpfs), memory/cache/buffer
  budgets, WAL retention, read policy, probes, backup/restore and rollback plan.
  Pod deletion on tmpfs deletes data; a configuration rollback cannot recover it.
- Enable identity-aware forwarding on every relevant node before continuous
  following. Verify the mixed-version rollout path and runtime settings.
- Install and exercise alerts/runbooks, including topology feedback. Audit one
  node per pass must cover the intended cluster within the freshness window.
- Start with a bounded canary, define stop/rollback criteria, and record an
  explicit reviewer/release-owner acceptance of residual risks. Do not promote
  all EVs to verified or equate mergeability with production approval.

Suggested order: settle RPO/failure model; close control-plane recovery risks;
run sustained/long-outage and resource tests in CI or a production-sized staging
environment; rehearse restore/rollback; then approve a canary.
