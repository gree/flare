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
| 1 | SAF-09: a new leader's generation exceeds every persisted version; a map is sent only after its version is persisted | Unit proof plus an E2E with a deleted lease; a fresh leader's maps are accepted |
| 2 | SAF-08: bracket follow-evidence stats reads with UID reads, like the topology probe | Unit cases plus an E2E with the same-name replacement seam |
| 3 | EV-15: per-node role and replication lag as metrics, with an alert on lag | Rendering test, plus the metric seen in the native-metrics E2E |
| 4 | Memory budget validation: warn when the configured budgets exceed the container limit | Unit cases plus a status condition or warning event |
| 5 | Client result when a stale slave cannot reach the master | Needs the user's decision; a specification is proposed with item 3 |

## Phase 2: measurements (CI evaluations, run in parallel)

| # | Measurement | How |
|---|---|---|
| 6 | Startup, probe and kill-9 reopen at 15.8M keys | `evaluation=scale-15m8` (started 2026-10-02) |
| 7 | T17: read and proxy latency, reconcile and lease renewal under load | New evaluation |
| 8 | Both repair triggers at the same time; lagged or Unknown successor gates | New E2E |
| 9 | Outage and resource evaluation on tmpfs | Outage evaluation with tmpfs storage |

## Phase 3: operations (staging needs the user's go-ahead)

| # | Item |
|---|---|
| 10 | Runbook for every alert, and a sizing rule (WAL cap plus bytes between cleanups, memory) |
| 11 | Backup restore and rollback rehearsal in staging |
| 12 | Canary definition with stop and rollback criteria, and a reviewer sign-off on residual risks |

## Not decided by this plan

- A0 above.
- The SAF-11 breaker definition.
- Item 5.
- Whether the startup grace should be counted in seconds.
- Any production change, merge of PR #144, or staging deployment.
