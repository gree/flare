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
