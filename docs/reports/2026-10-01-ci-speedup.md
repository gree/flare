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
