# Review notes — forwarding (master → replica) fixes, 2026-10-10

Branch `safety/saf-10-restore-provenance`. NOT independently reviewed unless
stated. Production / pf-dev: no change, none approved.

## 1. What the logs established (and what they did not)

| Run | Established | Not established |
|---|---|---|
| forward-window-steps 38048708017 (`2d4215d`, diagnostics on), S2 | The master enqueued 132 forwards to the rejoined ex-master, answered 0, counted 0 drops; the replica received 0. The master's two proxy threads logged nothing until `connect() failed: Connection timed out (110)` at 12:12:35.66 (~133 s after 12:10:22.7), again 12:14:50 and 12:17:05. The markers were missing at the comparison (12:10:5x) and at the final comparison after convergence evidence (12:11:28). | The address that timed out (not logged; "timed out" rather than "refused" while the new pod was reachable is *consistent* with the replaced pod's old IP). The forwards' eventual fate: they were **stalled in the queue for at least 6.7 min**, neither delivered nor counted; whether they would later have been delivered (a later open resolving the new address), dropped, or never is unknown — the cluster was torn down. So this is a **queue stall**, not a proven permanent loss. |
| forward-window-steps 38046122938 (`7875d28`), S3 | 127 forwards to a just-started pod DROPPED (ERR, counted) 11:22:31.80–57.65 because `getaddrinfo` returned "Name or service not known"; the operator made no ledger reading/request after 11:22:00. | Why the name did not resolve for ~26 s (`publishNotReadyAddresses: true` is set; a DNS negative cache is consistent, not proven); whether a later slot reading would have repaired it. |
| forward-window-steps 38051853624 (`026c4c2`) | S1–S3 PASSED; S3: the master counted 80 fast drops to the replaced pod, they were repaired, every acknowledged marker is in every copy. | S2 did NOT exercise the stall in this run (84 enqueued = 84 answered): this pass is no evidence that the stall is fixed — the C++ test is. |

## 2. The fix (`026c4c2` + compile fix `69e789e`)

### 2.1 Connect deadline, retries, name resolution
- `handler_proxy::run` (src/lib/handler_proxy.cc): the forwarding connection gets
  `set_connect_timeout_ms(3000)` and `set_connect_retry_limit(1)` (constants in
  handler_proxy.h). One `open()` is bounded by ~2 × 3 s + 0.5 s wait.
- `connection_tcp::_open` calls `util::gethostbyname` (getaddrinfo) on **every
  open**, so a later open re-resolves the name (unchanged code; verified).
- **NOT covered by the deadline:**
  - the name resolution itself (`getaddrinfo` is blocking; bounded only by the
    resolver's own timeouts);
  - a peer that ACCEPTS the connection and never answers: bounded by the read
    timeout — 30 s in the k8s build at startup (flared.cc:206), but
    `flared::reload()` (SIGHUP, which the operator sends on a RocksDB config
    change) sets it back to `net_read_timeout` (600 s default, flared.cc:504).
    That reset is a separate, open finding (not changed here).

### 2.2 The queue after a failed open
- `queue_proxy_write::run` (src/lib/queue_proxy_write.cc): if the connection is
  down AND its last `open()` **timed out** less than 2 s ago
  (`connection_tcp::open_failed_within`, stamped in `connection_tcp::open()`
  only when `_errno == ETIMEDOUT`), the forward is dropped at once instead of
  queueing behind another connect that would time out.
- A **refused** connect or a **failed lookup** does NOT arm it: those fail fast
  by themselves, and a destination that comes straight back must be reached
  again at once. The first version (`69e789e`) armed it on every failure and
  hung `test_handler_proxy::test_proxy_state_machine_for_node_state` (node
  down → back → the next forward must reconnect): nix-linux 38054441657 timed
  out; reproduced locally; fixed in `aa4f0f4`.
- Otherwise the existing loop: up to `max_retry` (4) attempts, each re-opening a
  down connection (each open bounded as above) → worst case ~26 s for one
  forward, after which the forwards behind it within 2 s of that failure drop
  at once. The queue therefore drains instead of stalling for minutes.
- When an open succeeds, the next forwards are sent normally; nothing dropped
  before is re-sent (it is counted, see 2.3).

### 2.3 Attribution of a drop (master → replica only)
- Counted (`proxy_write_dropped[<dest>]`) only for a POST-proxy forward (master
  → replica: `_post_proxy`). A client write forwarded TO a master (pre-proxy)
  that fails fast returns failure to the client and is NOT counted as a replica
  drop.
- Each forward is counted **at most once**: the fail-fast path returns before
  the retry loop; the retry loop counts only on exhaustion.
- **Over-count possible (safe direction):** a forward sent whose reply was lost
  can be counted as dropped although the replica applied it → an unnecessary
  repair, never a hidden gap.

### 2.4 What is still not counted (stranded forwards)
- `handler_proxy` "skip to proxy" (destination role became proxy): queued
  forwards are skipped with a notice and `diag[fwd_skipped_as_proxy:...]`, NOT
  counted. Covered only if the node's next reconstruction (when re-seated)
  starts at or before them — argued from the rebuild paths (snapshot / WAL from
  its cursor), NOT proven by a test.
- Forwards still queued when a proxy thread is shut down (node removed): not
  counted. Not tested.

### 2.5 From a counted drop to a repaired copy (operator)
- `c1c9bbc`: every Active master's per-destination drop counters are read every
  pass (was: once per 300 s slot, and only with an Active slave).
- `7875d28`: while a repair is in flight its master is read on the pass that
  decides completion; an unreadable master holds completion.
- Existing rule: drops after the reseat → completion requeues the increment.
- Unit checks (flare_unit 421): drop after the completing reading; master boot
  change; lost status write (older / empty ledger); drop right after the ledger
  emptied. These show **attribution**, not "no loss".

## 3. Tests

| Test | On the fix | On the old behaviour (control) |
|---|---|---|
| C++ `test_handler_proxy::test_proxy_write_to_an_unanswering_address_is_a_counted_drop_within_seconds` (listener with a full accept queue: Linux drops further SYNs) | 38054441657 (`69e789e`): TIMEOUT — a hang in `test_proxy_state_machine_for_node_state` caused by the too-broad fail-fast; re-run on `aa4f0f4`: 38058611462 — pending; control re-run 38058625697 (`d513bd5`) — pending | 38054462382 (`211155b` = fix disabled): **FAILED on both backends** (legacy 3607 tests / RocksDB 5338 tests, 1 failure each = this test): "the forward was neither sent nor dropped within 20 s (it queued behind a hanging connect)" — the intended counterexample, not a regression |
| C++ `test_proxy_write_to_down_node` (existing) | must still pass (pre-proxy: failure returned, not counted) | — |
| E2E forward-window-steps | 38051853624 PASSED S1–S3 (S2 did not hit the stall) | 38048708017 S2 stall (see §1) |
| flare_unit drop accounting (4 checks) | 421 passed locally | — |

## 4. Unreviewed changes on the branch (this round)

| SHA | Paths | Residuals |
|---|---|---|
| `308f149` | storage_rocksdb (batch slot locks) | Reviewed: no defect. Counters only. |
| `91ba62b` `2878705` | history choice / CRITICAL hold / RUNBOOK | `2878705` unreviewed; copies registered as proxy/unassigned not counted (shared with establish). |
| `e683892` | Main: slaves read 5 passes after a master change | rebuild time window remains. |
| `4e229dd` | refill prefers the recorded holder | — |
| `7875d28` `c1c9bbc` | Main: drop counters per pass | one stats read per Active master per pass. |
| `7d9d9c1` | forward diagnostics (off by default) | diagnostic only. |
| `026c4c2` `69e789e` `aa4f0f4` | proxy connect deadline + fail-fast counted drop (timed-out opens only) + C++ test | §2.1 not-covered items; §2.4 stranded forwards. |
| `1526ae2` `2d4215d` `f585848` `22312ad` | E2E suites | — |

## 5. Open items (production readiness), unchanged boundaries
- authority 29: cause of the ORIGINAL failure NOT established (history-masterless
  38043914126 is evidence for the three defined conditions only).
- Forwards dropped for ~26 s after a pod starts (NXDOMAIN): recorded and now
  repaired, not prevented.
- Read timeout reset to 600 s by a SIGHUP reload in the k8s build (§2.1).
- Stranded / skipped forwards not counted (§2.4).
- In-place restore retention: plan only.
- Old-backup compatibility and partition-count choice: **awaiting the user's
  decision**. pf-dev / production changes, environment creation: **not approved**.
- History-record write Conflict source; (R) earlier failure: not established.

## 6. Round 2026-10-11 — review list (candidate `3123bd5`, full CI 38072338837 / nix 38072344816)

Each row: change → test that FAILS on the old code (control) → result on the new code → residuals.
Nothing below is independently reviewed.

| # | SHA | Change | Fails on old code | New code | Residuals |
|---|---|---|---|---|---|
| F1 | `026c4c2` `69e789e` `aa4f0f4` | proxy connect deadline (3 s, 1 retry, re-resolve per open); fail-fast counted drop only after a TIMED-OUT open | `test_proxy_write_to_an_unanswering_address_is_a_counted_drop_within_seconds` (controls 38054462382, 38058625697, 38061497949: "neither sent nor dropped within 20 s") | 38058611462, 38062701272: pass | DNS resolution time and a connected-but-silent peer are not bounded by the deadline (read timeout: see F4) |
| F2 | `fbc9501` | drops counted ONLY for post-proxy forwards: pre-proxy (client → master) failure not counted (was, on retry exhaustion); skipped-to-proxy counted; abandoned at thread shutdown counted per destination | 5 tests: reconnect after a timed-out open; pre-proxy unanswering / refused master not counted; skipped-to-proxy counted; abandoned counted (control 38061497949: all fail, both backends) | 38062701272 (after the test-timing fix `40aa977`): pass | a forced shutdown counts abandoned forwards only in the thread destructor (later); skipped / abandoned forwards are COUNTED, i.e. repaired by a rebuild, not delivered |
| F3 | `865e3ae` | CRITICAL for drops to a destination outside this cluster (cross-cluster replication); RUNBOOK #foreign-drops | — (log only) | — | **neither operator repairs cross-cluster drops** (open) |
| F4 | `11ab634` | one read-timeout rule at startup and reload (explicit wins; k8s 30 s; classic net_read_timeout) | none runnable (the shared function is new; the defect is the old `flared.cc:504`, by reading) | `test_effective_read_timeout_is_the_same_rule_at_startup_and_reload`: pass (38062701272) | `flared::reload()` itself not exercised by a test |
| F5 | `7875d28` `c1c9bbc` | operator reads every Active master's drop counters every pass; completion needs a fresh reading | unit boundary checks (drop after the completing read, master boot change, lost status write, drop after the ledger emptied) | flare_unit 421 | detection only; not a claim of no loss |
| F6 | `4e229dd` | masterless refill prefers the recorded history holder within a tier | history-masterless (c) failed on `91ba62b` (38040348416) | 38043914126, 38060663630: pass | — |
| R1 | `e70043a` `cb5bb44` `9655fbd` `99c9c3c` `ef58309` | IN-PLACE restore keeps the live copy: capacity check, prepared next to the live copy, switched in at open by the existing copy switch, replaced copy retained without a record (never reaped) | the old hook replaced the live copy (`rm -rf` + `cp -a`): no runnable control | hook tests 13 (CI, none skipped); C++ 4 (38062701272); E2E restore-isolated 38069285176: refusal (6) after a REAL restart, accepted (7): 25 backup items live, new identity, retained copy with the old identity, kept 60 s, verified, write acknowledged | open decisions (old backups, auto-deletion, tmpfs capacity policy, rollback authority); a live copy without a readable COPY_ID refuses to open (manual procedure) |
| T1 | `ef58309` | restore-isolated waits for a NEW pod UID after deleting a pod | test 6 passed on the OLD pod (38066520694) — earlier passes of test 6 are not evidence | 38069285176: pass with a real restart | — |

### 6.1 Full candidate CI on `3123bd5` — NOT green

- nix-linux 38072344816: passed (both backends).
- E2E full matrix 38072338837: 12 of 13 groups passed; `repair` failed 2 of 17:

| Test | Failure | Cause (from logs) | Fix | Residual |
|---|---|---|---|---|
| replica-repair 4 (SAF-05 gated) | drops 6 → 7 "after the heal" | test baseline race: gated_2's last connect 18:02:52.338 (rule in place), rule removed 52.38, drop counted 52.838; no later drop; repair completed | `b9ddced`: baseline after the counter is unchanged 10 s | that F1 made the race visible is likely, not established |
| continuous-replication-upgrade 9 (rc56 → build) | no P0 master after the roll | approval first evaluated after nodes-1's roll began → never `untracked`; mixed copies HELD; master back empty (tmpfs) → promotion ABORTED (history absent) | `77f9b3b`: test waits for `part 0 untracked`; RUNBOOK #history-record roll gate + stop + recovery | why it passed on 28761ff not established (no pod logs); the recovery (#history-held-masterless) not exercised for this state; a real rc56 upgrade rolled early has the same outcome |

Targeted re-run 38078770419 (`77f9b3b`) pending; a new candidate needs another full run.

## 6.2 Round 2026-10-11 (2) — review list since `3123bd5` (nothing below is independently reviewed)

Green comparison base: `0491d3e` (full E2E 38090211947: 13/13 groups, 291 ok of which 22 SKIP = 269 executed passes; nix 38090213871). New candidate: code `86ae331` (nix-linux 38104628148: 0 failures, 3613 legacy / 5348 RocksDB tests).

| # | SHA | Change | Fails on old code | New code | Residuals |
|---|---|---|---|---|---|
| G1 | `0582f2d` | a pass sends its snapshot only while the live map still has its version (snapshotStillLive) | history-firstbuild 38081479454 (product race, from logs) | 38086982419 24/24 | superseded by G2/G3 for registrations |
| G2 | `2965aaf` (test + insend seam) `2f591b0` | PublicationGate: no registration answered while a send is out; no send while a registration is answered; node add waits on the send's promise (≤ 20 s), node state is NOT held (flared sends it from inside its sync handler) | topology-authority test 8, 38098872757: nodes-1 accepted the held v…185 with `state=active` (an empty restarted replica Active) | 38098999795: STILL FAILED test 8 — the registration waited, but v…185 was accepted (`state=prepare`, cause of the content NOT established) | needed G3 |
| G3 | `e0f4f0c` | flared (k8s build): listen only after the registration reply (a send queued in the listen backlog was applied after the reply) | as G2 | 38102484970: test 8 passes (accepted [0, v…187]); topology-authority 12/12, failover 13, operator-restart 3, history-firstbuild, cluster-init 5, replace-nodes 5 + 1 SKIP | node state/role moving the map during a send: logged, not prevented; a registration past the 20 s ceiling proceeds (WARNING); a port already in use now fails AFTER registering (pod readiness shows it); full matrix pending |
| T2 | `4555a7c` | history-firstbuild requires an Active P0 SLAVE | passed with a proxy (38081479454) | 38087061976, 38098999795: pass | — |
| T3 | `b9ddced` | repair test: drop baseline after the counter is unchanged 10 s | 3123bd5 test 4 | 38078770419, 38090211947 ('6 → 8' absorbed) | — |
| T4 | `77f9b3b` | upgrade test waits for `part 0 untracked` | 3123bd5 test 9 | 38078770419, 38090211947 | why it passed on 28761ff not established |
| X1 | `32dffd4` (test) `c2971d4` `ffb9137` `86ae331` (unit test) | cross-cluster: forwarding thread stays when its first connect fails; an unqueued forward is counted | cluster-replication-faults 38099336800: 30 acknowledged, 0 arrived, 0 counted; unit test encoded the old exit (38102252669) | 38099346715: 10 counted, 20 arrived; cluster-replication, snapshot-push-seed pass; unit test rewritten to the new contract (38104628148) | detection only, no repair; non-storing answers and seed early exit uncounted; empty-returned destination undetected (docs/review-cross-cluster-2026-10-11.md) |
| F4b | `f5e61f5` `754f114` | flared::reload() exercised: 30 s kept across SIGHUP; explicit value applied and kept | pre-11ab634 reload (counter branch) 38102234807: 30 s before, no close within 75 s after, reload line 600000 ms | 38102237236: 30 s / 30 s; 8 s / 8 s / 8 s | first runs 38099186230 / 38099188121 were a harness failure (30 s kubectl wall, busybox nc); removing the line keeps the explicit value |
| D1 | `2f2c326` `949eb1d` | RUNBOOK #history-holder-reseated; recovery exercised from the symptom by history-tracking 3a (`03d0b62`) | — | 38099482037: 10 REBUILD HELD lines, then recovered, 7/7 | not exercised after a re-seat with a new epoch; save step |
| D2 | `fdfad64` | RUNBOOK #foreign-drops: no cutover on a foreign drop increase; verify before cutover; re-seed destructive | — | — | procedure not exercised |

## 6.3 Round 2026-10-11 (3) — review list since `4db8e29` (nothing below is independently reviewed)

Comparison base unchanged: `c9b59ed` full CI (nix 38105677340; E2E 38105675619, 13/13 groups, 273 executed passes + 22 SKIP). No full CI on this round yet — targeted runs only.

| # | SHA | Change | Fails on old code | New code | Residuals |
|---|---|---|---|---|---|
| X2 | `50f65f1` (tests) `4024a6c` `5345666` `b573101` (unit-test timing) `73e7252` (diagnostics) | cross-cluster: per-op answer classes (NOT_STORED / delete NOT_FOUND not counted; other non-success counted); noreply not passed on; no answer or SERVER_ERROR resent ≤ 120 s then counted, destination given up after; bounded connects; seed state in stats + bounded retries before anything is sent | 38120285667: destination restart = SILENT LOSS, 21/30 keys differ, 0 counted (SERVER_ERROR answers ignored) | 38120334275 / 38122732042 / 38124283442: DNS 30/30 arrived; breaks pass/pass; cluster-replication 1-11, snapshot-push-seed pass; restart FAILED — destination masterless after restart (X4); nix 38122716005 pass | SERVER_ERROR resend not exercised against a returning destination; touch NOT_FOUND only a signal; empty-return detection none; NOT_STORED cannot tell same version from a destination-side write |
| X3 | `4024a6c` | seed "Phase 1" removed (pulled the destination's WAL into the source) | re-enable test PASSED on old code: master_id equal after the push (confirmed) but refused as lsn_purged — rollback NOT observed | pass (no exchange; re-seeded) | necessity from code only |
| X4 | — (finding) | a snapshot-push-seeded destination stays masterless after its master restarts: the copy holds the source's history, the destination's authority gate forbids it | exposed by X2 (the seed now runs) | 38124283442 evidence | **decision needed** (authority rule) |
| P1 | `96f196b` (test) `7a1a792` `7ac0ef2` (harness) | the DURING-the-send warning names the TCP report that moved the map; activation during a held send exercised | 38124218132 (old operator + harness): order reached, no rollback, failed only attribution | 38124220209: topology-authority 13/13 | **scope:** the old code failed ONLY the warning-attribution check (a diagnostic) — every safety check (no rollback, no second copy, slave held Active) PASSED on it, so this pair is NOT control evidence for any safety fix: 7a1a792 changes a log message, and the no-rollback checks are regression guards that discriminate nothing between old and new; 2 of the 3 earlier warnings unattributed (not closed by this run); first runs 38120557531/38120559531 were harness failures; 38120557531 SAF-09 10-13 failures not explained |
| X5 | `51d17e7` `054e373` `b939777` (tests) | isolated SERVER_ERROR-resend fixture: per-key-seeded destination, destination operator held 45 s | 38142587820 (tests + 50f65f1 C++): SILENT LOSS 29/30 differ, 25 counted; precondition reached | 38142537078: 3/3, resent 2, 0 differ; 38140445297 (no hold): order not reached | per-key-seeded only; X4 open |
| M1 | `637bb7a` + binding check | FlareMigration forward switch (client-visible) gated on seed + attempt-wide loss + approveForward; abort refused after forward | old step: equal counts → switchForward (by code, not run) | 38140891471 blue-green 11/11; units | (4th round: see V2) |
| V1 | `711b449` + binding | offline comparator V, 28 fixtures; §7.5 corrections | — (new) | CI unit step | (4th round: see V2, C1) |
| A4 | — (proposal) | snapshot-push as a history transition: A receipt / B re-approval / per-key-only for the move (review §13) | — | — | **one decision needed** (may history change at a push during the move?); X4 stays failing (38145285059 T4/T5) |
| V2 | (4th round) | forwardApproval = V's MATCH line bound to status.attemptId + every source/target master's pod UID/start/master id/copy id/epoch/seq; checked at the switch AND after forward is applied; boolean refused | old: approveForward bool switched (by code; 38140891471 passed on the bool) | units 477; blue-green E2E pending | line not signed; switch-window write is held, not undone; no consumed record |
| C1 | (4th round) | capture without changing the master: repl_snapshot + `flared --dump-checkpoint`; CI-only kind driver | `dump` reaps / moves seq (by code) | C++ test + receiver fixtures pending CI | no partition filter; not approved for real environments |
| D3 | docs | review-cross-cluster §7 (answer table, retry, seed, enable→Dumping audit, merge-dump delete limits, minimal specs V and R), RUNBOOK #foreign-drops | — | — | V and R not implemented / not exercised |

