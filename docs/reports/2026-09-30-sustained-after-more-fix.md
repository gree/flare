# Sustained-load evaluation after the MORE scheduling fix, and the CI runs at 7e979b0

Recorded 2026-09-30. Tested revision `7e979b0cba45dc103bcad083c2a688941cd77b8a`
(artifact `tested-sha.txt`; manual E2E run 36707861123, `evaluation=sustained`,
attempt 1, leg `continuous-replication`). Logs archived next to this file:
`2026-09-30-ci-36707861123-continuous-replication-sustained-e2e.log`,
`2026-09-30-ci-36707861123-flare-unit.log` (174 checks). Author-recorded CI
output; no EV verification state changes.

## What was measured

`continuous-replication-sustained`: three steady write rates, four minutes each
(eight 30 s windows), sampling the follower's applied position against the
master's head, item counts on both nodes, both RSS figures, the master's WAL
and data-dir bytes and the live tombstone count; then the load stops and the
backlog must drain. Same method as run 1 (2026-09-24, before the MORE fix).

## Result at 7e979b0 (MORE backlog is now re-requested at once even when the
slice was entirely skipped; `handler_wal_follower::retry_immediately`)

| rate | lag, first minute | lag, last minute | verdict (suite heuristic) |
|---|---|---|---|
| 300 keys/s | 0 | 0 | kept up |
| 900 keys/s | 0 | 0 | kept up |
| 2000 keys/s | 0 | 67,016 | fell behind, growing |

2000 keys/s window by window (lag = master head − applied):
0 / 0 / 0 / 7,046 / 15,536 / 29,381 / 47,306 / 67,016. The stream held the
rate for the first ~90 s, then the lag grew monotonically at roughly
+18k per minute, i.e. the follower sustained ≈1,700 changes/s while the load
was 2,000 (it was ≈1,280/s before the fix, when the lag grew ≈+56k/min).
Drain after the load stopped: 35–43 s (run 1: 442 s).

Memory and content: master RSS 33,840 → 133,372 kB over the run, replica
RSS peak 128,976 kB, no master restart, no reconstruction. Item counts were
equal at every sample (768,000 = 768,000): forwarding carried every write
(`forward_applied=768000`, `wal_applied=0`, `wal_skipped=772995`), so the
2000 keys/s deficit is a POSITION deficit (withheld replica reads, repair
entries staying open, longer post-cut catch-up), not a content gap.

## Comparison with run 1 (2026-09-24, before the fix; suite 41ea98e)

| | before (run 1) | after (7e979b0) |
|---|---|---|
| 2000 keys/s lag after 4 min | 294,615 | 67,016 |
| 2000 keys/s first minute | already 35,265–70,020 | 0 |
| drain after load stop | 442 s | 35–43 s |
| 300 / 900 keys/s | lag 0 | lag 0 |

Old numbers stay as history of the old code; they are not measurements of
7e979b0.

## What this run does NOT establish

- Disk: the master's WAL stayed at exactly 72,092 kB and the data dir at
  76,300–76,664 kB from the first window — 768,000 small records did not fill
  the 64 MB write buffer, so no memtable flush happened and the WAL files are
  preallocated. WAL rotation, flush, compaction and retention for a TRAILING
  follower are still untested (see PRODUCTION-READINESS, "Hold a replica
  offline long enough…").
- The 2000 keys/s ceiling: ≈1,700 changes/s is a single-node kind figure
  with both flared and the operator sharing the runner; it bounds nothing
  about production hardware. The knobs (`repl-follow-max-batches`,
  `repl-follow-poll-interval-usec`) were not tuned.
- Read eligibility was not sampled per window in this suite; the operator's
  lag bound (1000) means the replica was ineligible for reads from window 3 of
  the 2000 keys/s phase onward, by construction.
- Nothing here is a linearizable-read or zero-acknowledged-loss statement.

## The two CI runs

### Normal PR run 36707836842 — PASS, all five legs
https://github.com/gree/flare/actions/runs/36707836842 (event pull_request on
head 7e979b0). Artifact `tested-sha.txt` = `4c78abac0cdb31c82255012b4c7d3837034aa3ab`:
the PR checkout is the MERGE revision of 7e979b0 onto `flare-operator`
(which at that time contained a8763cb, the #143 merge), not 7e979b0 itself.
Legs: topology, replication (incl. continuous-replication-purge and
-limits), wal-recovery (48/48), breaker-migration, continuous-replication
(13 acceptance tests + evaluation SKIPs) — all success. The SKIPs of the
opt-in evaluations are not performance passes.

### Manual run 36707861123 (`evaluation=sustained`) — 4 of 5 legs PASS
https://github.com/gree/flare/actions/runs/36707861123, tested-sha 7e979b0
on every leg. continuous-replication (18 tests incl. the sustained
evaluation above), replication, topology, breaker-migration: success.

**wal-recovery FAIL — one test, classified as a HARNESS PRECONDITION fault,
not data loss.** `pvc-data-survival` test "all 100 keys survive SIMULTANEOUS
death of P0 master and slave" reported `DATA LOSS: 10 missing (0..9)`. The
same test passed in the normal run minutes earlier on equivalent code. What
the log shows:

- The recovery wait ("P0 master available after total P0 loss") returned
  after **15 s** of a force-delete of both P0 pods. Recovery is serial and
  takes minutes (pod-0 re-activates, then pod-2 is recreated and reseeds), so
  the wait was satisfied by STALE state: `statefulset.status.readyReplicas`
  still showed the pre-kill 4 and the operator's map still named nodes-0 as
  P0 master. The pod list in the diagnostics shows nodes-0 at 46 s old and
  nodes-2 at 10 s old, still not Ready.
- The exact-value readback therefore ran against a nodes-0 that had just
  restarted (flared log: "boot map already assigns my role … deferring role
  shift", "could not find reconstruction source node", then "assigned master
  with state active"). The missing keys are exactly the FIRST TEN in read
  order (0..9), then 90 consecutive hits — a boot window, not a hash pattern.
- The P0 item count after recovery was 49 in BOTH runs (49 of the 100 keys
  hash to P0), and both P0 pods reopened their PVCs with "curr_items seeded
  by an exact scan: 49 live key(s)". Nothing on disk was lost. The later
  test in the same suite (graceful slave restart, 100 keys) passed.
- Fix (this commit, harness only): the wait now requires every killed pod to
  carry a NEW UID, all replicas Ready, and the P0 master answering `stats`,
  and it logs how long recovery took. The exact-value assertion is unchanged.
  Re-execution on CI follows the push; the failure itself is kept here.

No EV verification state changes. The register records the sustained leg
under CHECK-16-limits at 7e979b0 and the acceptance legs of the PR run at the
merge revision 4c78aba.

### PR run 36713376306 on b5f1c45 (the recovery-wait fix) — PASS, all five legs
https://github.com/gree/flare/actions/runs/36713376306, event pull_request;
artifact `tested-sha.txt` = `89b8cdb484ee0573f4970de3ce4d7233b3a3fd41` (merge
revision of b5f1c45 onto `flare-operator`). nix-linux 36713376269 and Safety
evidence 36713376405 also PASS on b5f1c45.

wal-recovery 48/48: the fixed pvc-data-survival wait ended after **21 s**
with every killed pod replaced (new UID), all replicas Ready and the P0
master answering stats; the exact-value readback then found all 100 keys
(P0 item count 49, as in every run). Log archived as
`2026-09-30-ci-36713376306-wal-recovery-e2e.log`. One pass of the fixed
wait on one revision; the earlier failure record on CHECK-06 stays.
continuous-replication 18/18 (13 acceptance tests; evaluations SKIP by
design in PR runs). The other three legs PASS.

### PR run 36719136539 on 12886a4 (docs-only commit) — 4 of 5 legs PASS
https://github.com/gree/flare/actions/runs/36719136539; artifact tested-sha
`cb2d51cb840fa7b6f0ab0e46741ce8b7a4401711` (merge revision of 12886a4; code
identical to 89b8cdb apart from documentation). nix-linux 36719136541 and
Safety evidence 36719136627 PASS.

breaker-migration FAIL, one test: circuit-breaker "majority outage (scale
4→1) trips the breaker" — "no CIRCUIT BREAKER TRIPPED log within 480s".
This is the KNOWN intermittent finding filed as SAF-11 (register EV-09:
`circuitBreakerDecision` counts the nodes that became dead in ONE tick, so a
scale-down whose deaths land on different ticks never reaches the threshold).
Third CI occurrence (earlier: 5e80d73 and 72e5cca on 2026-09-14); the same
test passed at b5f1c45 minutes before on the same code. Recorded as a FAIL on
CHECK-09; not a regression of this commit and not erased by the earlier
pass. The fix needs the intended definition (dead fraction over a window vs
per-tick deaths) to be fixed first — see SAF-11.

## Long-outage retention evaluation, run 1 (CI 36725778961, evaluation=outage, tested-sha c33fe5d)

Suite `continuous-replication-outage` (e316232): 256 MB WAL cap, 3600 s TTL,
PVC 4Gi, 2Gi memory, 64 MB block cache; 50 kB values. Log archived as
`2026-09-30-ci-36725778961-continuous-replication-outage-e2e.log`.

**Phase A (150 MB written while cut) — PASS.** Three flushes (SST 1→3), live
WAL constant at 72 MB (preallocated file), archived WAL 8 kB → 124.8 MB,
data dir 4 MB → 326 MB, master RSS 33 → 236 MB. On healing the follower
caught up from its cursor (applied 4 → 3004) in **11 s** with no
reconstruction; items 3000 = 3000; wal_applied 16, wal_skipped 3044. The
retained archive was served as designed.

**Phase B (400 MB written while cut) — FAIL on the expectation, and that is
the finding.** The archive grew to **499 MB against the 256 MB cap** (SSTs
rotated 4→5→2→3→4→5 as compaction ran; data dir 1.07 GB; RSS 557 MB, no
restart) and, healed a few minutes after passing the cap, the follower was
still served every byte: it caught up from 3004 to 11004 instead of being
told `lsn_purged`. RocksDB enforces `WAL_size_limit_MB` on a periodic check,
not at the moment the cap is crossed, so **the cap is an eventual bound with
an overshoot that depends on the write rate between checks** — here at
least 243 MB. For capacity planning the archive must be budgeted as cap +
(write rate × purge interval), not as the cap. The suite now keeps the cut
after the load and watches the archive until it falls under the cap (up to
20 min), recording that time, before healing.

Not established: the actual purge interval and overshoot ceiling (next run),
compaction's effect on the data-dir high-water beyond this 1.07 GB point, and
anything about production hardware.

### PR run 36725742993 on c33fe5d — PASS, all five legs (tested-sha 8f0a4654cd1ee8515a4283142001bebb5912abbe); outage run 36725778961's other four legs PASS at c33fe5d (breaker-migration included: the SAF-11 no-trip did not recur this time).

## 2026-10-01: outage run 2 and the PR run on 0e49cc7

### Long-outage evaluation run 2 (CI 36731930552, tested-sha 0e49cc7) — phase A PASS, phase B FAIL on the expectation
Log `2026-10-01-ci-36731930552-continuous-replication-outage-e2e.log`. Phase A
again caught up from the cursor in 11 s (archive 124.8 MB retained, no
reconstruction). Phase B wrote 400 MB (archive 499 MB, data 1.07 GB, RSS
556 MB) and then — new in this run — kept the cut and watched an IDLE master
for **1,312 s (22 min): the archive did not move at all** (499 MB the whole
time, cap 256 MB). Healed afterwards, the follower again caught up from its
cursor (3004 → 11004) instead of `lsn_purged`. Conclusion for capacity:
RocksDB's archive purge is driven by its obsolete-file cleanup (flush /
compaction) and rate-limited (documented: every 10 min when both TTL and size
cap are set); on a master that stops writing, the archive stays past the cap
indefinitely. On tmpfs that is pinned RAM. Suite changed once more: after the
cap crossing it keeps writing 50 MB bursts every two minutes (each a flush)
for up to 20 min and records when the archive falls under the cap; run 3
dispatched.

### PR run 36731888436 on 0e49cc7 — 4 of 5 legs PASS (tested-sha 8691be6, merge revision)
breaker-migration FAIL, one test, topology-authority "lease unreadable: the
stopped pass fails closed and does not send": the lease-fence correctly
suppressed v…307 ("held for retry once authority returns"), but before the
retry a new commit produced v…308; the retry then published and confirmed
v…308 ("retrying an unconfirmed topology send (pending v…306; publishing
v…308)") and the test's assertion — that a publishing pass names the
suppressed v…307 — found nothing. Data-wise the survivors received the newer
superseding map (308 ⊇ 307); no node was left behind. Whether the retry must
carry the withheld map itself or may carry its successor is a semantics
question for the delivery-retry work (87f1728 / 4a516e6; SAF-09 lease and
generation recovery) — not changed here. Passed on 7e979b0, b5f1c45 and
c33fe5d; recorded as a FAIL on the topology-authority check with this
classification. Log `2026-10-01-ci-36731888436-breaker-migration-e2e.log`.

### Long-outage evaluation run 3 (CI 36741586970, tested-sha 6e757cb) — PASS, both phases
Log `2026-10-01-ci-36741586970-continuous-replication-outage-e2e.log`.

Phase A as before: 150 MB retained, caught up from the cursor in 11 s, no
reconstruction.

Phase B, now with writes continuing after the cap crossing: after ONE more
50 MB burst (one flush), 172 s after the load ended, the archive dropped
**499 MB → 250 MB** (under the 256 MB cap; data dir 1.07 → 0.89 GB). Healed
then, the follower declared `needs_rebuild` with reason `lsn_purged` (its
cursor 3004 lay in the purged range; head 12004), the operator filed the
request and the node was rebuilt by snapshot bootstrap in **59 s**
(reconstruction_started 1→2, snapshot_bootstrap 2, pod UID unchanged), items
12,000 = 12,000, master RSS high-water 620 MB, no master restart.

What the three runs establish together: the WAL size cap is enforced only
when the master's flush/compaction cleanup runs (run 2: an idle master kept a
499 MB archive for 22 min past a 256 MB cap); once it runs, the archive is
cut to the cap and a follower whose cursor lies in the purged range is told
lsn_purged and rebuilt — the history-loss path works end to end under a
production-shaped configuration. Capacity budget for the archive is
therefore cap + (bytes written between cleanups), and on a quiet master the
overshoot persists until the next write burst. Not measured: production
hardware, tmpfs, compaction's steady-state disk high-water beyond ~1.07 GB
for 550 MB of values.
