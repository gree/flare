# rc67 working candidate d311227 — full-matrix failures, analysis

Run: E2E MANUAL (full matrix) 38545812141 on d311227 (product = WAL follow
livelock fix c42e960 + SC-16 restated), attempt 1 (all legs) and attempt 2
(the three failed legs only, same commit). Answer to the review of d311227 /
efc1d48, item 4. NOT a review, NOT an approval.

## What the two attempts are, and are not

- No attempt is green. Attempt 1: 11/14 legs passed. Attempt 2: breaker-
  migration 29/29 and restore-promotion 22/22 passed, cross-cluster failed
  4, 5 and 8.
- "Every non-X4 test passed in at least one attempt" is NOT a green run and
  closes nothing. My earlier recap line "CI passed except the known
  cross-cluster" contradicted the ledger text and was wrong; the ledger
  entry is corrected (this commit).
- copy-identity 13, history-tracking 10 and restore 7 are OPEN. Their
  attempt-2 passes say only that each can pass on d311227.
- X4 (cross-cluster 4-5) stays recorded as outside the first per-key move;
  it is not counted as passing and the scope is not widened.

## Can the rc67 diff reach these paths?

The product diff of c42e960/d311227 touches only
`storage_rocksdb::get_updates_since` (skip batches the reader holds
completely), `op_repl_sync_wal::_run_server` (passes the reader's position)
and `handler_wal_follower` (immediate retry only after the position moved).
None of the four failures below involves a follower that was moving
through a large batch; three of them involve a node whose follower was
disconnected or whose pod was going away. That makes a regression
unlikely, but "unlikely" is not shown; the deterministic checks below are
what would show it.

## copy-identity 13 (breaker-migration) — attempt 1 failed, attempt 2 passed

Observed facts
- The pass that chose copy-identity-nodes-2 as successor was held; nodes-2
  was replaced; the held promotion was ABORTED (10:49:34.66Z).
- copy-identity-nodes-0 was logged unfit: repaired (rebuild) in the window
  (it was demoted to proxy by an R3 repair at 10:49:30.88Z).
- No slave promoted; the drain of the master nodes-1 was logged incomplete
  (NO promotable successor); nodes-1 came back on its PVC with 70/70.
- The only failed condition: the master's key count "while draining" read
  as 0 of 70, about 10:49:35Z. The master went Terminating at about
  10:49:18Z; this suite's preStop is `sleep 20`, grace 30 s.

Hypotheses
- H1: the read came after flared on nodes-1 stopped (end of the preStop
  window is about 10:49:38Z, so close but not shown).
- H2: the read failed (pod IP lookup, exec or nc) — the harness turned an
  unread count into 0 (`Ctx.currItems … getD 0`).
- H3: the master's copy really answered curr_items 0.

Missing evidence
- The old nodes-1 container's log (only the replacement pod's log was
  saved), the pod's deletionTimestamp / IP at the read, and whether the
  read failed. H1 is NOT confirmed and the test is NOT declared buggy.

Next deterministic check (done in this commit, diagnostic only)
- The read is now `Option` (unread = `none`, never 0); the pass needs
  `some 70`. The read logs its UTC time, the pod IP, and the pod's
  uid|deletionTimestamp|phase. The next failure tells H1/H2/H3 apart.

## history-tracking 10 (restore-promotion) — attempt 1 failed, attempt 2 passed

Observed facts (artifact logs of both attempts)
- Under the cut the replica's applied position stayed at 40; the 20 writes
  acknowledged by the master under the cut never reached it (follower
  disconnected — peer_unreachable — from 10:51:35Z; never reconnected; the
  master was force-deleted and came back EMPTY).
- The replica's read source (R3) had been BOUND at 10:50:54Z and was not
  re-validated while its follower was disconnected.
- The restarted operator took the lease at 10:52:24Z; at 10:52:34.32Z its
  pass read R3=1 for the replica and classified it `eligible`; PROMOTION
  committed at 10:52:35.24Z — without "NOT LOSS-FREE".
- The replica's own validator logged NEEDS REBUILD (lineage differs: the
  returned empty ex-master) at 10:52:35.40Z — 160 ms AFTER the commit.
- Attempt 2: NEEDS REBUILD at 14:31:14.1Z came BEFORE the operator's pass
  at 14:31:19.8Z → `lagging` → "PROMOTION NOT LOSS-FREE" → pass.

Conclusion from the facts (an ordering race, not attributed to rc67)
- The verdict depends on whether the replica's validator re-runs before
  the operator's first pass. The promotion itself is the intended action
  (the replica is the only data holder), but in the losing order the
  operator records a replica that is missing 20 acknowledged writes as
  `eligible` (loss-free) — the loss is NOT reported. That is a defect in
  the loss accounting (stale R3 BOUND is treated as current while the
  follower is disconnected), independent of the follow fix.

Missing evidence
- Whether rc66 can lose the same race (expected yes: neither the operator
  nor the validator changed), and how often.

Next deterministic check (proposed, NOT implemented — new test seam)
- Hold the replica's source validator (test seam) so the operator's pass
  runs first, on rc66 and on rc67: expected today on both = promoted as
  `eligible` with no NOT LOSS-FREE (the defect reproduced), not a timing
  matter. The fix (e.g. a disconnected follower's R3 is not "eligible"
  evidence) is a product decision for review, not part of rc67.

## restore 7 (restore-promotion) — attempt 1 failed, attempt 2 passed

Observed facts
- The in-place restore itself passed every earlier check: the backup's 25
  items live under a new copy id, the replaced copy retained as
  retained-restore-*, no marker left, still present 60 s later.
- rocksdb_restored_unverified stayed 1 for 240 s.
- The flag is cleared only by `check_partition_binding(as_master=true)`
  (storage_rocksdb.cc), i.e. when the map names the restored pod P0's
  master of the matching binding.

Hypotheses
- H1: the operator did not name the restarted pod P0's master within
  240 s (registration / history hold of a copy with a new identity).
- H2: it was named, but the binding check did not run or refused.

Missing evidence
- Nothing of the flare-rst-src2 namespace was saved (neither operator nor
  flared log, nor the map), so H1/H2 cannot be told apart.

Next deterministic check (done in this commit, diagnostic only)
- On this failure the test now logs the src2 operator's `node sync` map
  and saves every log of flare-rst-src2 (saveFullLogs "after-test-7").

## cross-cluster 8 — attempt 1 passed, attempt 2 failed

Observed facts
- Test 8 is a reach check: the restarted destination must answer
  SERVER_ERROR (no partition while its operator is held) so that the
  source's SERVER_ERROR resend is exercised.
- Attempt 2: the destination operator was held 45 s; "restarted flared
  lines about no partition: 0"; the destination answered again ~72 s after
  the restart; the source saw connection refusals only;
  forward_server_error_retried 0 → 0.
- Test 9 (final per-key match, 0 counted drops) passed — this does NOT
  satisfy test 8's requirement: the resend path was not executed.

Hypothesis
- The restarted flared came up only after the 45 s hold ended, so the
  no-partition window never happened (timing of the restart, not a
  product change; cross-cluster forwarding is untouched by rc67).

Missing evidence
- The destination flared's start time relative to the hold's release.

Next deterministic check (proposed, not implemented)
- Release the hold only after the restarted destination flared is up and
  answering (bounded wait), so the SERVER_ERROR window is guaranteed.

## X4 (cross-cluster 4-5)

Same signature as on be60dbb and 16921a5 ("no node partition for this
slave … deactivating"). Recorded as outside the first per-key move; not
fixed, not counted as passing.

## Out of scope of rc67, kept as explicit tasks

- Monitoring gap: a replica reported `following` while its applied
  position does not move (pf-dev 2026-10-14: frozen for 52 min) raises
  nothing. Separate task.
- rc67 is the WAL follow stop / hot-loop fix only. It is not WAL-stream-only
  replication, not a latency SLO (the <1 ms requirement is unaddressed),
  and pf-dev CPU / lag improvement is NOT measured. Not a production
  approval.
