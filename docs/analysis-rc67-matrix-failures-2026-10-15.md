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

Selection → commit, traced (review of fe9afce/232c92c [P1]; replaces the
earlier "reporting only" conclusion, which was NOT shown)

| step | attempt 1 (R3 still BOUND) | attempt 2 (R3 needs_rebuild) |
|---|---|---|
| FollowEvidence (follow side) | disconnected → **unproven** (its own backlog reads 0: it never saw the 20 writes), not unfit | same |
| PromotionEvidence.classify | `eligible` (stale R3 binding; partition masterless) | `lagging` (same recorded history) |
| Main → followUnfitKeys | not included (eligible is "normal") | included (sourceIneligible) |
| masterless refill tier | **tier 1, Active slave** — `excludedKeys` holds only followUnfitKeys, so the lag hold (`holdUnfit`) is never consulted | tier 1 skipped (excluded); data-bearing last resort; hold ended because the ex-master was READ empty |
| loss report | none: `refillHoldEffects` reports only followUnfitKeys; the AfterHandleFailover "unproven" line covers the failover path, not the refill | `PROMOTION NOT LOSS-FREE … READ empty` |
| commit | `commitAllows` (eligible promotable, binding unchanged) and `reclassifyAllows` (eligible = eligible) pass | same with lagging; extra "LAGGING copy" line |

So the class decides more than the log line. Deterministic replay
(`lake exe ht10_replay`, flare_operator/FlareOperator/Repro/HistoryTracking10.lean;
identical output on rc66 16921a5 — operator and validator code are unchanged
between rc66 and fe9afce):

| case | R3 stale BOUND (eligible) | R3 needs_rebuild (lagging) |
|---|---|---|
| A ex-master back EMPTY (the CI case) | f crowned, **no log** | f crowned, NOT LOSS-FREE (READ empty) |
| B ex-master AWAY (PVC may hold the writes) | f crowned **at once — the lag hold is bypassed**, no log | held, CRITICAL "has NO master" |
| C ex-master BACK WITH DATA (holds the 20 writes) | **f crowned ahead of the ex-master** (tier 1 before the lastMasterOf tier) — the acknowledged writes are discarded, no log | ex-master crowned |

Why R3 stays BOUND (not a timing accident): `decide_source`
(src/lib/source_eligibility.h) KEEPS an eligible binding while the map still
names the same master and that master cannot be probed. R3 moves to
revalidating only when a map naming another master / no master reaches the
replica — and the pass that first sees the partition masterless reads the
replica BEFORE it broadcasts that map. Attempt 2 differed only because the
cut was already healed and the validator probed the returned (empty)
ex-master before the operator's pass.

General effect (not limited to the CI case): a follower that cannot be
proven current (disconnected) is treated by the masterless refill as an
in-sync Active slave: (B) bypasses the failover wait, (C) bypasses the
"newest surviving copy" choice, and neither is reported. The failover path
(dead master detected while the operator runs) does take unproven followers
last and logs them NOT LOSS-FREE (design §5.3, availability first) — the
refill path is the gap. Not attributed to rc67; present on rc66.

Deterministic E2E reproductions (added; expected to FAIL until a fix):
`promotion-disconnected-follower` (C: PVC, ex-master back with every write)
and `promotion-disconnected-follower-empty` (A, attempt-1 order: pod-local,
ex-master back empty). Both keep the cut until the operator has decided, so
R3 stays BOUND by the rule above; the operator is down while the master's
flared restarts, so the refill (not failover) decides. No flared test seam
is needed. They are in the restore-promotion group: the full matrix reports
the open finding as a failure, not a pass.

E2E result — REPRODUCED, both, deterministic (single-suite 38687661051 on
509f2c8 = fe9afce product + these tests; 38682940390 and 38685673044 stopped
at test-side preconditions, fixed in 3a58959 / 509f2c8):
- C: ex-master prom-disc-nodes-0 back on its PVC with 50/50 items (20
  acknowledged under the cut). Pass evidence: ex-master `lagging (same
  history)`, follower (R3 eligible=1, follow disconnected, 30 items)
  `eligible` → `PROMOTION committed` for the FOLLOWER; no NOT LOSS-FREE;
  the 20 acknowledged writes are missing on the new master.
- A: ex-master back empty (`FORBIDDEN (rejoining …)`), follower `eligible`
  → promoted (the right copy) with NO NOT LOSS-FREE although 20
  acknowledged writes never reached it.
rc66 control: the operator and validator code are unchanged between rc66
and fe9afce and the decision replay gives the same result on both; an E2E
run of these tests on rc66 would need another branch (pushes go only to
safety/saf-10-restore-provenance) and was not run.

Fix — plan (review of ee8f520 approved the work, 2026-10-15; written
before the change, not a release approval)

Neither "refill only" nor "classification only": the classification makes a
stale R3 `eligible` no evidence of currency, and every selection and commit
path consumes that class.
- Classification (PromotionEvidence.classify): R3 `eligible` makes a copy
  `eligible` only while its partition HAS a master in the map. With no
  master the binding is stale (decide_source keeps it while its master is
  unreachable), so the copy is decided by its history like any other copy:
  the RECORDED last master's master id and epoch → `lagging`; no record or
  no reported history → `unknown` (held, never seated); another history →
  FORBIDDEN (rejoining); rebuild in flight / part-way / quarantine /
  identity disagreement / parked / running / corrupted stay FORBIDDEN
  (checked first). A disconnected copy is NOT "same history" by being
  disconnected. A backend without copy evidence (tch: no WAL follower) keeps
  the narrow legacy rule, without the stale R3 bit.
- Selection: Main already puts every non-normal class (`Class.normal`: not
  eligible / legacy / empty) with the unfit followers, and every
  non-promotable class in the refill's blocked list. So the stale follower
  is out of failover, drain, proxy assignment and the refill's first tier;
  the refill's lastMasterOf tier seats the ex-master only when it is not
  blocked (its CURRENT class: same recorded history and a healthy copy —
  not by name) and holds data; otherwise the data-bearing last resort is
  HELD while the ex-master is away or unreadable, and seats the follower only
  when the ex-master was READ empty or the wait expired — logged PROMOTION
  NOT LOSS-FREE with that reason (refillHoldEffects, unchanged).
- Commit: re-classified with the pass's observation (masterless → the same
  `lagging`; eligible→lagging aborts); a pass that did not read refuses
  `lagging` (commitTimeAllows). Failover with the dead master still in the
  map is unchanged: it never relied on R3 for currency (a disconnected
  follower is FollowEvidence-unproven and its promotion is logged NOT
  LOSS-FREE, design §5.3).
- Pairs: unit checks driving the real classifier through the refill (A
  empty return → seated, NOT LOSS-FREE "READ empty"; B away → held, then
  seated NOT LOSS-FREE "EXPIRED"; C back with data → the ex-master, no
  false NOT LOSS-FREE; ex-master back unhealthy → held, then the follower
  after the wait; no history → never seated). They fail on the old
  classification (10 checks) and pass on the new. E2E: the hardened
  reproductions are run on the old operator first, then on the fix, with
  lag-hold-tmpfs / lag-hold-expiry and the restore-promotion group.

Unfixed-operator result with the hardened observations (single-suite
38699030754 on 671353c = fe9afce operator + tests): both REPRODUCED, as
findings (not unobservable / precondition):
- C1: timeline cut 08:06:16 → 20 writes acked 08:06:20 → operator stopped and
  master killed 08:06:50 → container restarted / operator back 08:06:56 →
  ex-master registered 08:07:17 (its copy: 50/50 keys by value) → promotion
  committed 08:07:22 for the FOLLOWER (R3 eligible=1, follow disconnected).
  Missing on the new master: 20/20. Absent from every copy at read time
  (before the cut was healed): 0 — they were still on the ex-master's copy,
  which had become a slave of the follower's new history (epoch advanced at
  the promotion: followers of the previous history must rebuild). No NOT
  LOSS-FREE.
- A1: ex-master verified empty (0 keys, curr_items 0); follower promoted
  with every base key; 20/20 under-the-cut writes absent from every copy
  (the accepted loss) — but no NOT LOSS-FREE.

Repro hardening (review of ee8f520, item 1): every required observation
(ex-master registration, the decision, every copy's dump, the node view)
failing stops the test as UNOBSERVABLE / PRECONDITION NOT MET, never as a
count of 0 or as data loss. Before the kill the master's copy must hold all
50 keys by value and the follower exactly the 30 base keys; on return the
ex-master's own copy must hold all 50 by value (PVC) or be verified EMPTY
(pod-local). Every copy is read after the decision and BEFORE the cut is
healed; the result separates "missing on the new master" from "absent from
every copy", and records the timeline.

## Ledger (review [P2])

The ledger candidate is now fe9afce (`rc67-candidate-fe9afce`). be60dbb's
state is kept in docs/reports/2026-10-15-ledger-candidate-be60dbb-snapshot.json
and `previous_candidates` (it had 0/57 counting runs). Per-check CI runs at
fe9afce were recorded from 38664258590 (E2E, all 14 legs; flare_unit 523/523
and `lake build FlareOperator` in every leg) and nix-linux 38657543197 on
192f37f (differs from fe9afce in docs/ only). A check passes only if every
suite it references executed with no failure and no non-evaluation skip.
Result: 16 controls yes; EV-07 partial 3/5 (retention / quarantine checks
have no test reference); EV-16 partial 6/7 (CHECK-16-limits: the scale suite
ran evaluation-only skips); EV-11 no (resync self-demote test skipped); EV-13
no (wal-purged fallback test skipped). X4's suite is referenced by no check.
EV-06 carries the refill finding above as an OPEN residual risk: its
ci_passed=yes does not cover it. Candidate update ≠ review or approval.

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

## X4 (cross-cluster 4-5) — scope

Facts (38664258590 and the earlier full runs)

| run | X4 (snapshot-push seed, restart with writes) | restart-dump 7/9 (merge-dump seed, restart with writes, operator held 45 s) | per-key-only 13 (switch off, per-key seed, restart) |
|---|---|---|---|
| 38338541303 rc66 16921a5 | fail | pass | pass |
| 38545812141 d311227 att. 1 | fail | pass | pass |
| 38545812141 d311227 att. 2 | fail | 7 pass, 8 fail (not reached), 9 pass | pass |
| 38664258590 fe9afce | fail | pass | pass |

- Test 4 failed because the destination master did not come back within
  300 s; test 5 did not compare anything (4 recorded no outcome). Test 5's
  absence of a comparison is NOT evidence of a match or a mismatch.
- Destination operator: `FORBIDDEN (rejoining: the copy holds <source
  master id>/<epoch>, not the authoritative history)`, refill inputs
  `unfit=true blocked=true`, `CRITICAL: partition 0 has NO master`, held
  until and past the wait expiry.

Code path (why it is seed-specific): only `swap_in_snapshot` (snapshot
push, and the in-cluster snapshot rebuild) replaces a copy's history
identity — it adopts the SOURCE's master id and epoch (`inherited`) and a
new copy id. The destination operator's authoritative record is not moved
by a push (AuthoritativeHistory: no transition for a foreign prefix), so the
first restart of that master reads as "rejoining" another history →
FORBIDDEN → masterless. A per-key / merge-dump seed only writes keys
through the normal path; the destination keeps its own master id, epoch and
copy id (per-key-only 13 asserts the lineage is unchanged across the
restart). rc67 does not touch any of these files.

Scope statement
- X4 = a destination seeded by SNAPSHOT PUSH cannot get its master back
  after that master restarts. It is a history-identity (authority) gap of
  the snapshot-push seed, not a general restart defect.
- The first per-key move uses `snapshotPush: false` (per-key seed); its
  restart is covered by per-key-only 13 (4/4 runs pass) and the restart
  WITH writes while the operator is held by restart-dump 7/9 (merge-dump
  seed, 4/4 pass on 7/9). Not covered: the exact X4 body (writes during the
  restart, operator running) on a `snapshotPush: false` destination — a
  control test for that is the next step; until it runs, "per-key seed is
  not affected" rests on the code path and the two neighbouring tests.
- This is NOT a statement that the snapshot push is acceptable in
  production: any restart of a push-seeded destination master before the
  cutover takes the destination down (review-cross-cluster §7.6). The
  first-move limitation stays: snapshot push must not be used (switch off).
- X4 stays recorded as failing; not counted as passing.

Control — RUN (review of ee8f520, item 3; single-suite 38699030754 on
671353c, both suites in one job, same kind cluster):

| suite | seed | destination identity across the seed | test 4 (restart with writes, operator running) | test 5 (final per-key match) |
|---|---|---|---|---|
| cluster-replication-faults (X4) | snapshot push (default) | not read before (the push replaces it) | FAIL: master not back within 300 s | FAIL: no comparison (not a data verdict) |
| cluster-replication-faults-per-key (control) | per-key, `snapshotPush: false` | unchanged (master id, epoch, copy id verified before the restart) | pass: back in ~17 s, 60 → 65 items, forwarding resumed | pass: every tracked key matches |

Same body (unresolvable name, four connection breaks, then the destination
master pod deleted with data kept while 15 changes are written, operator
running). Conclusion boundary: with this procedure the restart failure needs
the snapshot-push seed; the per-key seed does not reproduce it, so no common
recovery defect is shown for the first per-key move (its limitations are
unchanged). One run; not a statement about other restart procedures or about
production. Snapshot push stays out of the first move.

## What the logs already settle, and the next deterministic step (13 / 7 / 8)

- copy-identity 13: settled — the only failed condition was the draining
  master's count read as 0 (the old `getD 0` read; an unread value and a
  real 0 were indistinguishable). Open — H1 (read after flared stopped) vs
  H2 (read failed) vs H3 (real 0). Next: the Option read with pod UID /
  deletionTimestamp / phase is in (c5f0143); to decide without waiting for a
  repeat, a fixed-order variant reads the count once inside the preStop
  window and once after the container has stopped (pod Terminating, flared
  gone) and asserts the harness reports `none` (H2-type) for the second —
  proposed, not built.
- restore 7: settled — the restore itself completed (25 items, new copy id,
  retained copy, no marker). Open — H1 (never named master) vs H2 (named,
  binding check refused). Next: the failure path now saves the src2 map and
  every log; a deterministic check reads `node sync` on src2 while
  `rocksdb_restored_unverified` is 1 and asserts whether P0 is named master
  and, if so, the flared binding check's log line — proposed.
- cross-cluster 8: settled — attempt 2 never produced a SERVER_ERROR window
  (0 no-partition lines; refusals only); test 9's match does not satisfy 8.
  Next: release the operator hold only after the restarted destination
  flared answers `stats` (bounded wait), so the window is guaranteed —
  proposed.

## Out of scope of rc67, kept as explicit tasks

- Monitoring gap: a replica reported `following` while its applied
  position does not move (pf-dev 2026-10-14: frozen for 52 min) raises
  nothing. Separate task.
- rc67 is the WAL follow stop / hot-loop fix only. It is not WAL-stream-only
  replication, not a latency SLO (the <1 ms requirement is unaddressed),
  and pf-dev CPU / lag improvement is NOT measured. Not a production
  approval.
