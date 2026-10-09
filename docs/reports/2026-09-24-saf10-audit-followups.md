# SAF-10 audit follow-ups — working-tree validation

Base: e2ca4c6 (parked audit branch, based on a6b2a0a), plus uncommitted tests
and documentation. This report is NOT a passing run attributed to an immutable
commit. No control is promoted to verified. PR #144's newer reporting commits
are on another branch and were not merged here.

## Changes and safety links

- EV-16 / SC-16: drain MORE even when the current WAL slice applied no new
  values because forwarding already supplied them. Production path:
  handler_wal_follower::run -> retry_immediately. Errors still back off.
- EV-04 / SC-04, EV-14, UCA-26: unknown-at-startup replicas are withheld;
  observations ahead of the node clock are Unknown. Production path:
  FollowEvidence.classify/judge -> commit read withholding.
- UCA-26: cluster::pre_proxy_read checks follow_allows_local_read and sends
  an ineligible slave's reads to its master, keeping its Slave role and
  continuous follower alive. It does not promise fresh reads when the source
  is unreachable, or linearizability between source observations.

## Executed

- `lake build flare_unit flare_operator flare_e2e`: PASS (existing warnings).
- `flare_operator/.lake/build/bin/flare_unit`: 139/139 PASS.
- `nix build .#flare --no-link`: C++ compilation succeeded; cutter executed
  3556 tests, 2772916 assertions, one failure in
  test_handler_proxy::test_proxy_read_to_proxy (connection-establishment wait).
  The two newly added test_stats_reconstruction tests both passed:
  test_follow_backlog_does_not_poll_sleep_after_superseded_slice and
  test_local_read_guard_disconnect_lag_and_recovery.
  Exact failed derivation: /nix/store/11mbb6dnyb30yryfxwyj69wzfqyxd1xx-flare.drv.
  Do not treat the whole suite as green or assume the failure is unrelated.
- A second full run (/nix/store/8dkyq5csms02q4nmf7i7x7ihcq5a942l-flare.drv)
  also returned 3556 tests / 2772916 assertions / one failure. It is NOT a
  passing rerun. During diagnosis a separate lingering Nix invocation from
  the audit work was found with cutter running for over 85 minutes; its
  identified client (PID 80943) was interrupted. Do not conflate that process
  with the second derivation's completed failure result.
- Evidence checker (plain and `--base a6b2a0a`) passed; 21 checker fixture
  tests passed; `git diff --check` passed.

## Not yet demonstrated / next work

1. Execute the amended continuous-replication read test with freshly built
   images: successful control read, cut/update, no stale local value, heal,
   updated value and restored balance. It has only been compiled here.
2. Stage successful master network delivery with a stale positive-balance
   map. The production-routing unit test below now pins local-read refusal
   and recovery independently of map updates; it deliberately stops at
   enqueue failure, not successful network delivery. The amended E2E waits
   for balance zero, so it does not isolate this guard.
3. Remeasure 900/2000 writes/s after the MORE fix, including backlog drain,
   RSS, WAL retention, flush/compaction and disk high-water marks. Retain old
   measurements as historical, not as measurements of the new code.
4. T17 lock/writer-starvation measurement; large-DB boot and startup probes;
   expose and validate RocksDB memory budgets against container limits.
5. Stage simultaneous rebuild requests and recovery across operator restart.
6. Audit remaining TCP-side promotion bypass and planned-promotion/deletion
   lag allowance. Async failover still cannot promise zero acknowledged loss.
7. A client get sent directly to a replica may proxy: it is not by itself
   evidence of local content. Keep cursor/content evidence separate from read
   routing tests. Master-unreachable reads currently may appear as cache
   misses; changing that protocol behaviour requires a compatibility decision.

## Continuation: proxy harness and production read-path test

The repeated proxy test failure exposed two harness weaknesses, not yet a
proof of the precise cause of the earlier connection failures:

- setup guessed a random port, and start_handler_proxy ignored listen's
  return value. Setup now binds port zero, checks success and keeps the
  kernel-assigned listener open; handlers use that reserved port.
- test_proxy_read_to_proxy required an accepted socket even though its claim
  is that a Proxy-role destination skips the request. It now waits for the
  actual queue reference to complete and checks the unsuccessful result.
  Tests expecting a network response retain their connection assertions.

Added test_stale_balance_read_guard_uses_production_routing_and_recovers in
test_handler_proxy. It invokes cluster::pre_proxy_read with a positive-balance
slave partition and follows these transitions without changing that map:
following/caught-up -> disconnected -> following/behind -> caught-up ->
wrong source. The transport target is deliberately unavailable: ineligible
reads must attempt enqueue and fail, not return local-read permission. This
tests the production routing branch, not successful network delivery. A real
master-response E2E is still required. The full build is run with a 600-second
Nix timeout to avoid another unbounded waiter.

The first continuation build (qx7h67jrpfg71xqlhsxl72nq4dwbby5l-flare.drv)
found a compile error in the new test: enqueue requires a shared_thread_queue
lvalue, not a temporary conversion from shared_queue_proxy_read. Corrected
with an explicit base-typed local variable.
The corrected full run (kh2x3149flap4kmafsqm4mnnf4sz3fnv-flare.drv) reached
cutter but hit the 600-second build timeout. This is a failure/unfinished run,
not evidence that the old connection failure is closed. A separate filtered
derivation is used to isolate the four relevant cases without claiming a
full-suite pass.

### Filtered execution result: PASS

Immutable derivation: `/nix/store/zp3q5alw87pxpbhgf80sxb37xqlfkd6l-flare.drv`.
Source is the working tree described above, including the enqueue type fix;
no uncommitted run is attributed to HEAD alone.

Command:

```sh
nix build --impure --no-link --timeout 600 --expr '(let f = builtins.getFlake "git+file:///Users/junji.hashimoto/git/flare"; in f.packages.${builtins.currentSystem}.flare.overrideAttrs (old: { checkPhase = "./test/run-tests.sh -n \"/(stale_balance_read_guard|local_read_guard|follow_backlog|proxy_read_to_proxy)/\""; }))'
```

C++ compilation and installation succeeded. Cutter output:

```text
test_stats_reconstruction::test_local_read_guard_disconnect_lag_and_recovery PASS
test_stats_reconstruction::test_follow_backlog_does_not_poll_sleep_after_superseded_slice PASS
test_handler_proxy::test_proxy_read_to_proxy PASS
test_handler_proxy::test_stale_balance_read_guard_uses_production_routing_and_recovers PASS
4 test(s), 26 assertion(s), 0 failure(s), 0 error(s), 0 pending(s), 0 omission(s)
```

This is a non-RocksDB build exercising the shared scheduling/read-routing
code. It does NOT replace RocksDB E2E or close the timed-out full suite.

### CI-first validation configuration (not yet executed)

The E2E workflow now builds/runs flare_unit and preserves its output alongside
the E2E log and checked-out SHA. Manual evaluation profiles enable sustained,
2M-key or 15.8M-key evaluation only on the continuous-replication shard; normal
PR runs leave these opt-in tests skipped. Both nix-linux backend jobs now have
bounded test commands and upload logs/SHA even on failure. Artifacts expire
after 30 days and must be copied into durable evidence records as appropriate.

These workflow edits are uncommitted local configuration, not new passing
runs. No CI was dispatched and no verification status changed. T17 and missing
failure scenarios still require actual test implementation; scheduling existing
tests in CI does not close them.
