# Canary plan for continuous WAL replication (draft, 2026-10-02)

Draft for the release owner. Nothing here has been run. Staging rehearsal and
any production step need an explicit go-ahead.

## Scope of the canary

One cluster, one partition with one master and one follower, on PVC. The
chart must render without the memory-budget failure. Prefer a cluster whose
clients treat a miss as a cache miss. Where flare is the primary store, set
`spec.rocksdb.readUnavailableError: true` first.

## Preconditions

- PR #144 merged and an image built from the merged commit, with CI green at
  that commit.
- `repl-identity-forward` on for every node before `repl-follow-enabled`.
- Alerts installed, each with its runbook:
  - `FlareReplicaFollowLag` and `FlareReplicaNotFollowing`;
  - `FlareTopology*`;
  - `FlareCircuitBreakerTripped`;
  - `FlareProxyWriteDropped`;
  - `FlareMasterMissing`.
- A backup taken and its restore rehearsed in staging (plan item 11).
- `FLARE_FOLLOW_PROMOTE_LAG` set to the loss the owner accepts silently on
  a promotion. The default is 100 positions.

## Steps

1. Enable follow mode on the canary's follower only, and watch for 24 h.
2. Do one planned master restart. The drain must promote the follower with
   no `NO promotable successor` line.
3. Run for 7 days at production write rate.

## Stop and roll back when

- `flare_node_repl_follow_lag` grows for 15 min at normal write rate.
  Measured on kind: kept up at 900 writes/s, fell behind at 2000 writes/s.
- `FlareReplicaNotFollowing` fires and the follower does not recover
  without a rebuild.
- Any `PROMOTION NOT LOSS-FREE`, `CRITICAL`, `PERSIST FENCE` or
  `LEASE FENCE` line that the runbook does not explain.
- Reconcile passes are slower than 2× the pre-canary baseline, or the
  operator lease age exceeds half its duration. Measured on kind under
  load: up to 3.4 s per pass, and lease age up to 8 s of 15 s.
- The data volume or RSS exceeds the sizing rule in RUNBOOK.md#sizing.

**Rollback.** Set `repl-follow-enabled = false` with a SIGHUP; it is
dynamic. The live op-forwarding path keeps replicating. Do not delete tmpfs
pods: that deletes their data.

## Sign-off

The release owner accepts the residual risks listed in
`docs/safety-evidence.json` for EV-01, EV-04, EV-09, EV-13 and EV-16. Above
all, they accept the asynchronous RPO (decision A0) and the silent loss up
to the promotion bound.
