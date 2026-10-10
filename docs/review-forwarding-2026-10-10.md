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
- E2E full matrix 38072338837: 13 of 14 groups passed; `repair` failed 2 of 17:

| Test | Failure | Cause (from logs) | Fix | Residual |
|---|---|---|---|---|
| replica-repair 4 (SAF-05 gated) | drops 6 → 7 "after the heal" | test baseline race: gated_2's last connect 18:02:52.338 (rule in place), rule removed 52.38, drop counted 52.838; no later drop; repair completed | `b9ddced`: baseline after the counter is unchanged 10 s | that F1 made the race visible is likely, not established |
| continuous-replication-upgrade 9 (rc56 → build) | no P0 master after the roll | approval first evaluated after nodes-1's roll began → never `untracked`; mixed copies HELD; master back empty (tmpfs) → promotion ABORTED (history absent) | `77f9b3b`: test waits for `part 0 untracked`; RUNBOOK #history-record roll gate + stop + recovery | why it passed on 28761ff not established (no pod logs); the recovery (#history-held-masterless) not exercised for this state; a real rc56 upgrade rolled early has the same outcome |

Targeted re-run 38078770419 (`77f9b3b`) pending; a new candidate needs another full run.
