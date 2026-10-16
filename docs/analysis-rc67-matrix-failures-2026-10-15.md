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

Fixed-operator result (single-suite 38703976147 on 117c915; 20/20 E2E in
the eleven suites promotion-disconnected-follower(-empty), lag-hold /
-tmpfs / -expiry / -unreadable, multipart-lag-hold, history-tracking,
history-masterless, promotion-reasons, r3-unreadable; flare_unit including
the history-tracking 10 pairs):
- C1 PASS: cut 09:19:40 → 20 writes acked 09:19:44 → operator stopped and
  master killed 09:20:20 → container restarted / operator back 09:20:25 →
  ex-master registered 09:20:41 (its copy: 50/50 by value) → promotion
  committed 09:20:52 for the EX-MASTER. The cut follower is not crowned; no
  hold line was needed (the ex-master was back and readable); no NOT
  LOSS-FREE for the follower.
- A1 PASS: ex-master verified empty (0 keys); follower promoted with every
  base key and logged PROMOTION NOT LOSS-FREE (masterless refill, last
  resort); accepted loss 20/20 under-the-cut writes absent from every copy.
- The lag-hold, history and promotion-reasons suites still pass (held
  while away / unreadable, seated NOT LOSS-FREE on expiry or an empty
  return, FORBIDDEN copies never seated).
- Observation (open, not changed): in C1 the re-seated ex-master is also
  logged `PROMOTION of a LAGGING copy … writes it never received are lost`.
  Its copy is classified `lagging` because nothing proves it current (it is
  not preferred by name), so the line over-reports: "behind it" is not
  established for the last master's own copy. Safe direction (a false
  alarm, never a hidden loss); rewording or a separate class is a policy
  choice, left to review.

Full matrix at candidate 57d37a1 (38714646714, ee31373 = docs-only after
it): 12 of 14 legs green, flare_unit 534/534 in every leg. Two legs failed:
- cross-cluster: X4 (`cluster-replication-faults` 4/5, snapshot-push seed)
  as before ("the destination master did not come back within 300 s"); the
  per-key control suite passed again. Open, unchanged.
- repair: `continuous-replication-upgrade` 9 (rc56 → this build on tmpfs,
  release procedure) — CAUSED BY THE FIX. Sequence: the new replica nodes-1
  copied the rc56 master nodes-0 by the legacy staged rule and was BOUND to
  it (source epoch "(legacy, lineage only)"); nodes-0's roll brought it back
  EMPTY (tmpfs, READ empty; its rc56 preStop `shutdown` is not understood by
  the operator, so no handoff); the partition is UNTRACKED (an rc56 master
  has no copy evidence: no history record can exist). With no master in
  the map, nodes-1's binding is stale (flared itself turned it
  `revalidating`: "map names no master"), and with no record the fix
  classified it `unknown`: never seated, not even after the wait — the
  partition stayed masterless (CRITICAL, RUNBOOK #history-held-masterless).
  The old code passed only when its first pass read the stale `eligible`
  before flared's invalidation (a normal promotion, no NOT LOSS-FREE).

Decision (user, 2026-10-16): narrow `lagging`, not unknown, for exactly
this shape (PromotionEvidence.legacyCopyOfUntrackedLastMaster): no master
in the map, NO recorded history, the partition explicitly UNTRACKED in the
store, exactly one node with lastMasterOf = the partition, the copy's R3
source (`repl_read_source`) IS that node and was a LEGACY peer
(`repl_read_source_epoch` empty), state eligible or revalidating, the copy
Active and non-empty, no forbidden marker. Then it is the refill's held,
logged last resort: seated only when the ex-master is READ empty or the
wait expired, PROMOTION NOT LOSS-FREE. Anything else without a record stays
`unknown` (another source node, a source with an epoch, a tracked or
undecided partition, an empty copy). With a master present the same
reading is `eligible` (unchanged). Unit pairs (540/540): the four positive
checks fail with the rule disabled; the negatives hold either way. The
upgrade test now waits up to 300 s for the master and, when the masterless
refill engaged, requires the NOT LOSS-FREE line for the seated replica.

Targeted run 38775718162 on c090cc1 (8 suites, 16/16, flare_unit 540/540):
the upgrade test passed — nodes-1 seated "by the masterless refill as a
LAST RESORT", PROMOTION NOT LOSS-FREE, items equal across the roll, 20/20
writes after it; C1 / A1, lag-hold-tmpfs / -expiry, history-masterless,
promotion-reasons and history-tracking still pass. The test's masterless
detector only looked for the hold line, which a READ-empty ex-master never
produces (seated at once); 66b749a detects the refill's per-pass inputs
line instead (test-only). Candidate: 66b749a (`rc67-candidate-66b749a`);
57d37a1's ledger is kept in
docs/reports/2026-10-16-ledger-candidate-57d37a1-snapshot.json. Full matrix
and nix-linux (for the C++-referenced checks) are dispatched at the
candidate's docs-only successor.

Full matrix 38791047421 at 7641f76 (docs-only after 66b749a) and nix-linux
38791053760 (success, test programs legacy 134/134, RocksDB 134/134):
9 of 14 legs green, flare_unit 540/540 in every leg; at candidate 66b749a
7 controls yes, 8 partial, 5 no (snapshot
docs/reports/2026-10-16-ledger-candidate-66b749a-snapshot.json). The
C++-referenced checks count now (nix-linux at the same tree).
- continuous-replication-upgrade 9 PASSED in the full matrix: nodes-1
  seated "by the masterless refill as a LAST RESORT", PROMOTION NOT
  LOSS-FREE. Its detector printed engaged=false: the inputs line is logged
  only for a partition STILL masterless after the refill, so a same-pass
  seat (READ-empty ex-master) logs neither line — the requirement was not
  armed; it held only because the line was there. 7f6affe also arms it
  from the class the new master had in the last PROMOTION EVIDENCE pass
  before its last "PROMOTION committed" (lagging / unknown / FORBIDDEN =
  NOT LOSS-FREE required), independently of the line it requires.
- cross-cluster: X4 (4/5, snapshot-push seed) as before. Open, unchanged.
- breaker-migration: copy-identity 13 — a PRECONDITION failure of the test,
  not an operator defect. At its start both slaves were FORBIDDEN
  ("confirmed different history against the present master": test 12 had
  just promoted nodes-2; nodes-1 then declared needs_rebuild and was
  demoted for repair); `threeInSync` compares item counts only. The drain
  of nodes-2 had NO promotable successor (CRITICAL, kept as master — the
  safe outcome); nodes-2 came back on its PVC as Slave/Prepare, `lagging
  (same history)`, and the held pass was ITS re-seat — the test then
  force-deleted the master itself (cordoned, Pending) and saw no master
  for 180 s. a911172: the test starts only with both slaves R3 `eligible`
  against the current master (bounded wait, else PRECONDITION NOT MET) and
  refuses a held promotion that is not a slave's.
- continuous-replication 10 — a PRECONDITION failure of the test: the wait
  saw a stable balance-50 snapshot, then a SECOND read saw a later map
  version. a911172 keeps the snapshot the wait confirmed; the check after
  the rules are in force (same version, still 50) is unchanged.
- wal-recovery and restore-promotion: cut by the 120-min job timeout (the
  runner's Lean build took ~90 min; ~15 min in 38714646714). Incomplete,
  not failures; every test they reached passed (restore-promotion 19/19
  incl. C1 and A1; wal-recovery 22 passed, 3 skipped, 0 failed).

Candidate: 7f6affe (`rc67-candidate-7f6affe`, test-only changes after
66b749a). The full matrix and nix-linux are re-run at its docs-only
successor.

Full matrix 38808521263 at c419077 (docs-only after 7f6affe) and nix-linux
38808525868 (success, legacy 134/134, RocksDB 134/134): 11 of 14 legs
green, flare_unit 540/540 in every leg; at candidate 7f6affe 14 controls
yes, 4 partial, 2 no (snapshot
docs/reports/2026-10-16-ledger-candidate-7f6affe-snapshot.json). X4
(4/5) passed for the first time with the snapshot-push seed — one run,
closes nothing. copy-identity 13 and continuous-replication 10 passed
with the a911172 preconditions.
- failover-data: pvc-data-survival 17 — an OPERATOR DEFECT
  (F-proxy-excluded-master-slot). The P0 master and slave were killed
  together on PVC. The replica re-registered as a Proxy (partition -1);
  since 117c915 such a copy always classifies `unknown` (no record for
  partition -1). autoAssign still put it into P0's empty master slot on
  every pass — its exclusion guard looked only at Active slaves, not at
  the Proxy itself — and the commit gate aborted every pass, so the
  returning ex-master (lagging, same history, every key) was never
  re-seated by the refill: no master within 420 s; 18 and 20 failed after
  it. b4e6a49: an excluded Proxy is not placed in a master slot (the
  refill decides), the matching proof case in GeneralSafety, 3 unit checks
  built from this run's map (fail without the fix; 543 pass). Verified by
  single-suite 38824621386 on b4e6a49: 22/22 (pvc-data-survival,
  data-survival-failover, replace-nodes, lag-hold-tmpfs, multipart-enable,
  upgrade, C1, A1, history-masterless).
- failover-data: continuous-replication-multipart-enable 26 (503 keys,
  P0 140 at the legacy stage instead of 137) — a test race, not an
  operator defect. The test wrote from 22:56:32.5; the P0 master accepted
  the map with P1 Active only at 22:56:33.73 (until then
  `1(prepare): master`), and a master holding a partition in prepare keeps
  the keys it forwards to it in its own store as well: 3 P1 keys stayed on
  P0. 0e41e97: the test writes only after every node has accepted a map
  with all four entries active (bounded, else PRECONDITION NOT MET).
  Passed at 137/163 in 38824858293 and 38824621386 (before the fix: the
  race is timing-dependent).
- cross-cluster 13: forward_server_error_retried did not move — the known
  open item (cross-cluster 8 type), unchanged.
- restore-promotion: cut by the job timeout again (Lean build ~65 min).
  history-tracking (1): the operator logged intent persisted, commit and
  adoption, but the test's read of the persisted map had no `transition=`
  line; (R), 3a, 4, 15, 3b followed (the replica stayed a repair-held
  Proxy, which the refill never considers). Not reproduced on b4e6a49:
  38824858293 history-tracking 7/7. Cause UNDETERMINED; open.
- Not fixed, recorded: a data-holding Proxy (repair-held or re-registered)
  is classified against partition -1, so it is always `unknown` and is not
  a refill candidate. If the master dies while the only data copy is such
  a Proxy and the ex-master is empty, no path seats it (before 117c915 the
  stale eligible class did). Whether it may be seated as a last resort is
  a policy decision, not taken here.

Candidate: 0e41e97 (`rc67-candidate-0e41e97`: b4e6a49 operator fix +
0e41e97 test fix after 7f6affe). Full matrix and nix-linux at its
docs-only successor.

Full matrix 38835210953 at 25ec074 (docs-only after 0e41e97) and nix-linux
38835213805 (success, legacy 134/134, RocksDB 134/134): flare_unit 543/543
in every leg; at candidate 0e41e97 16 controls yes, 2 partial (EV-07: two
checks without a test reference; EV-16-limits: evaluation-only skips),
2 no (EV-11 / EV-13: a skipped test each, as before). EV-06 counts yes
with F-proxy-excluded-master-slot fixed (pvc-data-survival passed in the
matrix).
- 11 legs green in attempt 1, including failover-data (pvc-data-survival
  and multipart-enable with 0e41e97) and breaker-migration.
- cross-cluster: X4 (4/5, snapshot-push seed) FAILED again — "the
  destination master did not come back within 300 s"; the per-key control
  passed, cross-cluster 13 passed. X4 is 1 pass in 3 matrices: open,
  unchanged, not re-run.
- copy-protection and restore-promotion were cut by the 120-min job
  timeout in attempt 1 (Lean build 63-65 min) with no test failed, and
  were re-run in the same run. copy-protection attempt 2: 16/16, recorded.
  restore-promotion attempt 3 was cut again, earlier (19 ok), so attempt 1
  is recorded (21 ok, 0 failed): history-masterless (b)(c) and
  history-firstbuild were reached in none of them (history-masterless
  passed 3/3 in the targeted 38824621386 on b4e6a49, which is not
  docs-only equivalent and does not count). The ledger rule now marks only
  the suite RUNNING at the cut as incomplete (finished suites in a cut leg
  keep their result; unreached suites are not run).
- The restore-promotion leg cannot finish inside 120 min on these runners
  (three cuts in a row). Raising the limit or splitting the leg is a
  workflow change outside docs/, so it would make a new candidate and need
  another full matrix: not done here.

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

Candidate moved to 57d37a1 (`rc67-candidate-57d37a1`) = fe9afce + the
history-tracking 10 fix (117c915) + the reproduction / X4-control tests
(671353c) + the ledger checker (57d37a1: an OPEN finding caps ci_passed; a
finding marked fixed lifts the cap only when its fixing commit is an
ancestor of the candidate). Later commits are docs only. fe9afce's ledger
is kept in docs/reports/2026-10-15-ledger-candidate-fe9afce-snapshot.json
(14 yes / 4 partial / 2 no; EV-04 and EV-06 capped by the OPEN finding).
F-ht10-stale-r3 is `fixed` (fixed_in 117c915). The targeted run 38703976147
does not count for the candidate (its tree differs by the checker script);
every control is `no` until the full matrix at the candidate is recorded.

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
