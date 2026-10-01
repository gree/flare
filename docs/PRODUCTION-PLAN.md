# Plan to production enablement (from 2026-10-02)

Owner of the gate: [PRODUCTION-READINESS.md](PRODUCTION-READINESS.md). This
file orders the work so CI time is shared. Code is batched so one ~22 min PR
run covers several changes, and long evaluations run as manual jobs in
parallel with PR runs.

## Working assumption, to be confirmed by the user

**A0. Asynchronous durability.** A write acknowledged by the master and not
yet delivered to a replica is lost if the master's data is lost. RPO equals
the replication lag at that moment. Synchronous acknowledgement is out of
scope. If production needs zero loss of acknowledged writes, this plan stops
at phase 1 and a separate design starts.

## Phase 1: close the control-plane gaps (code, CI-verified)

| # | Item | Done when |
|---|---|---|
| 1 | SAF-09: a new leader's generation exceeds every persisted version; a map is sent only after its version is persisted | **Done 2026-10-02.** Proofs, unit cases, Lease-deletion E2E PASS in PR run 36901004232 |
| 2 | SAF-08: bind follow evidence to the flared process. A boot-id change makes a reading Unknown, with no extra API calls per replica | **Done 2026-10-02.** Unit cases; the PR runs pass. A replacement within one pass is not detected |
| 3 | EV-15: per-node role and replication lag as metrics, with an alert on lag | **Implemented**, CI pending (PR run on 779513b) |
| 4 | Memory budget validation: the render fails when the floor reaches the limit, and warns above 70% or when tmpfs plus the floor exceeds the limit | **Implemented** at chart render time, with 4 render tests. CI pending |
| 5 | Client result when a stale slave cannot reach the master | Needs the user's decision; a specification is proposed with item 3 |

## Phase 2: measurements (CI evaluations, run in parallel)

| # | Measurement | How |
|---|---|---|
| 6 | Startup, probe and kill-9 reopen at 15.8M keys | `evaluation=scale-15m8` (started 2026-10-02) |
| 7 | T17: read and proxy latency, reconcile and lease renewal under load | Measurements added to `evaluation=sustained`. Run pending |
| 8 | Both repair triggers at the same time; lagged or Unknown successor gates | T6 extended, plus a lagged-successor failover E2E. CI pending |
| 9 | Outage and resource evaluation on tmpfs | `evaluation=outage-tmpfs` added. Run pending |

## Phase 3: operations (staging needs the user's go-ahead)

| # | Item |
|---|---|
| 10 | Runbook for every alert, and a sizing rule (WAL cap plus bytes between cleanups, memory). Sizing and replica-follow sections written 2026-10-02 |
| 11 | Backup restore and rollback rehearsal in staging |
| 12 | Canary definition with stop and rollback criteria, and a reviewer sign-off on residual risks |

## Decisions taken (user, 2026-10-02)

| Decision | Choice |
|---|---|
| A0, data-loss guarantee | Asynchronous loss accepted. RPO equals the replication lag. |
| Item 5, client result | flared option `read-unavailable-error`, default off (keeps the miss). Enable it where flare is the primary store. |
| 1p × 2r and the breaker | Never trip with fewer than 2 unavailable nodes. CR `circuitBreaker.minUnavailableToTrip`, default 2. |
| SAF-11 definition | Confirmed as implemented. |
| Startup grace | Wall-clock, 120 s. |

## Decisions needed from the user (with options, as asked on 2026-10-02)

1. **A0, data-loss guarantee.**
   - (a) Accept asynchronous loss on master data loss. RPO equals the
     replication lag; the lagged-successor E2E records the gap.
   - (b) Require zero loss of acknowledged writes. This needs a separate
     synchronous-acknowledgement design, so production is blocked on it.
2. **Item 5, client result when a replica cannot serve a read.** Today a
   replica that withholds its local read (follower behind or disconnected)
   and cannot reach the master answers `END`, a plain miss. `op_get` logs
   "pretending not found".
   - (a) Keep the miss. Fine for cache use: the client falls back to its
     source of truth.
   - (b) Return `SERVER_ERROR` in exactly that case, leaving other paths
     unchanged. Needed when flare is the primary store, where a miss reads
     as "the key does not exist".
   - (c) Make it a flared option, defaulting to (a).
3. **1 partition × 2 replicas and the breaker.** One node death is 50%,
   which trips the breaker, so failover never happens automatically.
   - (a) Accept manual failover for such clusters.
   - (b) Do not trip on a single death below a minimum cluster size.
   - (c) Set a higher threshold for small clusters.
4. **SAF-11 definition.** Confirm that the breaker counts nodes unavailable
   now (dead this tick, plus Down, plus Prepare with no pod).
5. **Startup grace.** Count it in seconds instead of reconcile cycles.
   Today it stretches to about 190 s when passes are slow.

## Not decided by this plan

- Any production change, merge of PR #144, or staging deployment.
