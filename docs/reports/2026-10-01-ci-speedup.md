# E2E CI speed-up (2026-10-01)

Requested by the user after the existing problems were fixed. The workflow
change does not touch any test or operator code. Measured baseline: PR run
36846255460, about 48 min wall-clock (setup ~14 min per leg + up to 34 min of
tests), 112 min of test time in total.

## Changes

1. **Plan job.** A first job decides what runs. It skips the matrix when the
   pushed commits touch only `docs/` or `*.md`. The `pull_request` paths
   filter cannot do this, because it looks at the whole PR diff. Anything
   uncertain runs: a first push, an unknown base after a force-push, or any
   other event.
2. **Per-leg concurrency.** A newer code push cancels each older leg in its
   own group. A docs-only run no longer cancels a running matrix, because its
   legs are skipped and never join a group.
3. **Eight legs instead of five**, balanced on measured suite times, at about
   10-16 min of tests each. The plan job's matrix is the single source; every
   leg checks its union against `flare_e2e --list`.
4. **Cached flared images.** Both flared Dockerfiles now copy only the C++
   build inputs (autotools files, `src/`, `test/`) instead of the whole
   repository. Their layers go to the GitHub Actions cache, and only the
   topology leg writes it. The operator image is built uncached, as before,
   because it pulls the current stable kubectl.
5. **Single-suite run.** `workflow_dispatch` takes `suites=` (for example
   `topology-authority`) and runs only those suites in one leg named
   `custom`. Evaluation profiles still apply only to the
   continuous-replication leg.

## Expected effect (estimates, to be measured)

| Case | Before | Expected |
|---|---|---|
| Docs-only push | ~48 min | skipped |
| C++ unchanged (cache hit) | ~48 min | ~23 min |
| C++ changed, or first run with an empty cache | ~48 min | ~30 min |
| One suite (manual) | ~48 min | ~10 min |

## Where each evidence check now runs

| Check | Suite | Leg (was) |
|---|---|---|
| CHECK-01, CHECK-01-startup | topology-authority | authority (breaker-migration) |
| CHECK-03/04-follow, 16, 17, 18 | continuous-replication | continuous-replication |
| CHECK-06 | pvc-data-survival | failover-data (wal-recovery) |
| CHECK-09 | circuit-breaker | breaker-migration |
| CHECK-18-purge, CHECK-20 | continuous-replication-purge / -limits | replication |

Artifact names keep the pattern `e2e-<leg>-<evaluation>-<attempt>`, and
`tested-sha.txt` is unchanged.

## First run — PR run 36860948511 on 477fc22: all 8 legs PASS, 32 min with an empty cache

| Leg | Finished after |
|---|---|
| continuous-replication | 24.2 min |
| wal-recovery | 27.4 min |
| replication | 29.7 min |
| breaker-migration | 30.2 min |
| failover-data | 30.2 min |
| topology | 31.2 min |
| authority | 31.2 min |
| repair | 32.3 min |

The run took 32 min against about 48 before. The cache was empty, so every
leg rebuilt both flared images. Under the Buildx builder those builds took
about 5 min each, slower than the 3 min of the classic builder. All 198 tests
ran, the same count as before, with none failing. The narrowed Dockerfiles
build. A manual full run follows to measure the cached case.

## Manual run 36864650674: no cache hit, by GitHub's cache scoping; cancelled

Every leg rebuilt the flared images in 3-6 min. The previous PR run had saved
its layers under `refs/pull/144/merge`. A `workflow_dispatch` run on the
branch (`refs/heads/...`) cannot read caches of a pull-request ref, so this
run could only miss. It measured nothing new. Its topology leg failed for an
environment reason: the Lean release server returned HTTP 504 while the
operator image build downloaded the toolchain. The run was cancelled. Two
consequences:

- PR runs read the PR-scope cache, so the cached case is measured on the
  next PR run.
- The operator image build now retries up to three times.

## Cached case measured — PR run 36866790112 on fcbf98d

The flared images came from the cache, at about 6 s each against 3-6 min
before. Seven legs passed and finished in 18.5-22.7 min:

| Leg | Finished after |
|---|---|
| continuous-replication | 18.5 min |
| replication | 19.4 min |
| topology | 19.9 min |
| authority | 21.3 min |
| failover-data | 21.6 min |
| wal-recovery | 21.9 min |
| repair | 22.7 min |

A full run with the C++ sources unchanged takes about 23 min, against about
48 before, which is the estimate.

breaker-migration failed after 3 min for an environment reason, before any
test ran. Docker Hub returned HTTP 503 while buildx resolved `ubuntu:noble`.
Even a cached build resolves the base image's manifest. No test result
exists for that leg, so CHECK-09 has no record from this run. Each flared
image build now retries once after 30 s. The operator image build already
retries three times.

## First complete cached run — PR run 36869793917 on fd76eed: all 8 legs PASS in 22.1 min

All 198 tests passed. Every leg finished between 18.0 min (continuous-replication)
and 22.1 min (wal-recovery). The breaker tripped 10 s after the scale-down.
The image retries were in place and none was needed.

| Case | Before | Measured |
|---|---|---|
| Docs-only push | ~48 min | skipped (e188ee5) |
| C++ unchanged, cache hit | ~48 min | 22.1 min (36869793917) |
| Empty cache, or C++ changed | ~48 min | 32.3 min (36860948511) |
| Single suite, manual | ~48 min | not yet measured |

A manual run on the branch cannot read the PR-scope cache, so a single-suite
run rebuilds the flared images. Expect about 10 min of setup plus the suite
until the branch-scope cache is written. The topology leg of a full manual
run writes it.

## Fix (2026-10-02): a docs-only skip can no longer look like a pass

Problem, raised by the user. A skipped run finished in 12-17 s as "success",
with nothing saying that no tests ran. The skip rule also looked only at the
push's own files. Two consequences:

- A docs push after a failed run would have turned the PR head green.
- A docs push after a base-branch change would have skipped merged base code
  nobody tested.

Neither had happened. The three skipped commits (e188ee5, 6bbdaa5, be382ee)
each differ from the last tested commit only under `docs/`. The base has not
moved since 2026-09-26.

Now:

- Every run's title records its base commit:
  `E2E Tests (base <sha>)`.
- The matrix is skipped only when three things hold:
  - the push touched only docs;
  - the previous push's run completed with conclusion success;
  - that run's title names the same base.
  Anything else runs the full matrix. The plan job logs the reason.
- A skipped run shows a separate check,
  `E2E NOT RUN (docs-only push; tests passed in run <id>)`, and a step
  summary pointing to the run whose result covers the commit.

Dry run of the plan step: skip only for "previous run passed, same base".
It runs for:

- a failed previous run;
- no previous run;
- another base;
- a previous run whose title carries no base, which covers every run before
  this change;
- a code push.

### Confirmed on CI (2026-10-02)

- **Code push 6866c95, PR run 36882921953.** The title was
  `E2E Tests (base a8763cb…)`, and the full matrix ran.
- **Docs-only push a032812, PR run 36895413680.** The plan job logged:

      E2E NOT RUN: docs-only push; previous run 36892024759 on ddeb06e
        passed against the same base a8763cb…

  The test legs were skipped. The run shows the check
  `E2E NOT RUN (docs-only push)` with the notice
  `see run 36892024759`.

The name of that check is static, because GitHub shows a skipped job's
name unevaluated (fixed in aa2262a).
