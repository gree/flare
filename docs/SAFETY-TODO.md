# Operator safety improvement backlog

This is the current safety backlog. The older operator TODO is historical.
The runtime fixes below are **not implemented by introducing this backlog**.
The evidence register in [safety-evidence.json](safety-evidence.json) owns control
status; [STPA-node-state.md](STPA-node-state.md) owns the hazard analysis.

## Merge gate

SAF-01 through SAF-07 block the operator merge until their acceptance scenarios
have passed on the candidate implementation and a reviewer has assessed the
linked safety constraints. A library build alone does not close these tasks.
All tasks below are open; record completion with evidence IDs and a PR reference.

| Task | Priority | Change and acceptance criteria | Constraints / evidence | Dependencies |
|---|---|---|---|---|
| SAF-01 | Before merge | Consolidate topology sends onto committed state and check leadership on that path. Pause an old reconcile across takeover and resume it; no send after confirmed loss. Document the check/send race and generation fencing limits. | SC-01 / EV-01, SC-02 / EV-02 | None |
| SAF-02 | Before merge | Make reconstruction requests observable by flared even when the replica returns to the same partition. Inject missing writes, verify reconstruction starts and missing keys recover; distinguish requested, started and completed metrics/logs. | SC-03 / EV-03 | Design together with SAF-05 |
| SAF-03 | Before merge | Replace numerical LSN proximity with reconstruction completion evidence bound to master identity and sync generation. Reject close-but-incomplete cursors, different lineages and master changes during observation. | SC-04 / EV-04 | None |
| SAF-04 | Before merge | Represent missing stats as Unknown. Reject empty, truncated, malformed and stale observations for deletion; revalidate target Pod identity and successor before acting. | SC-05 / EV-05 | Design together with SAF-06 |
| SAF-05 | Before merge | Retain pending replica repair until completion, including operator/master restart and counter reset. A drop observed while the breaker is held or a destination cannot be resolved must be repaired later without another drop. | SC-03 / EV-03 | SAF-02 |
| SAF-06 | Before merge | Arbitrate competing repairs. When resync demotes a successor in the same tick as empty-master repair, do not delete using the previous successor snapshot. Cover concurrent re-registration and leadership loss before deletion. | SC-05 / EV-05 | SAF-04 |
| SAF-07 | Before merge | Align documentation with actual guarantees: committed-map uniqueness is not distributed writer fencing; masterless refill can deliberately promote partial Prepare data. State the loss/availability tradeoff and residual risks. Re-audit all old DONE claims. | SC-01, SC-02, SC-04, SC-06 / EV-01, EV-02, EV-04, EV-06 | Final review after SAF-01–06 |
| SAF-08 | Next stage | Type Pod observations, including identity, readiness, data knowledge and observation time; move repair decisions into pure functions. Unknown must not become healthy or empty. | SC-05, SC-07 / EV-05, EV-07 | SAF-03–06 |
| SAF-09 | Next stage | Separate desired topology from per-node applied generation. Retry failed application and expose lag; specify delayed command handling and verify reconnect convergence. | SC-01, SC-02 / EV-01, EV-02 | SAF-01 |
| SAF-10 | Separate design | Compare content anti-entropy, master LSN on proxied writes and continuous WAL shipping by guarantees, compatibility and operating cost. Include write acknowledgements, replica reads and cross-cluster migration. | SC-03, SC-12, SC-13 / EV-03, EV-12, EV-13 | No dependency for the design |

**Status (this branch).** SAF-01 through SAF-06 are implemented with tests on
this branch; the evidence register owns their exact implementation and
verification state, which stays `unverified` until a reviewer signs off.
SAF-01 (topology authority), SAF-02/05 (replica-repair ledger) and SAF-03
(sync-completion evidence) have passing E2E scenarios; SAF-04/06 (typed stats
and delete revalidation) are covered by the pure `flare_unit` checks. SAF-07
(this documentation pass) is folded into the same branch — see the
"Guarantees, and what they are not" section of the [README](../README.md).
SAF-08 through SAF-10 remain out of scope for this branch. Re-audit of older
DONE claims lives in [STPA-node-state.md](STPA-node-state.md#8-what-this-document-got-wrong);
no claim there survived unchecked into this branch.

## Evidence workflow

Each control records a bounded claim, scenarios, assumptions, residual risks,
code references **and the production call path**, proposed verification and
immutable execution evidence. Paths plus symbols identify code; a branch name
or line number alone is insufficient. Empty execution evidence means unverified.

Implementation: `gap`, `partial`, `implemented`. Verification: `unverified`,
`verified`, `stale`. These are independent: a tested partial mitigation still
leaves its stated residual risk. A hazard is never closed just because one
linked control exists. An alert proves detection only, and only when deployed
and routed; a theorem proves its stated model property under its assumptions.

1. Identify the affected SC/EV IDs in the PR (or explain why none apply).
2. Change implementation, tests and the relevant register entries together.
   Update each affected entry's `review` with the inspected full commit SHA,
   date and a substantive impact note. Documentation-only changes in a referenced
   file also need an impact note, but need not run unrelated E2E suites.
3. If previous evidence no longer supports the claim, mark it `stale`. Keep old
   runs as history; add new runs after verification. Each run names the planned
   verification ID, full tested commit SHA, date, command, result and durable
   report location (repository report path or immutable CI run URL).
4. Use `verified` only after every listed verification has a passing run on one
   tested revision and a reviewer has checked reachability, bypasses, failure
   behavior and assumptions. `skip`, failures, static reading and unexecuted
   test definitions are not passing runtime evidence. Narrow theorem evidence
   must not be presented as end-to-end safety.
5. Record results in the same PR where possible. A follow-up evidence-only PR
   may reference the original CI-tested SHA; do not invent a self-referential
   commit SHA. Before merging the operator, rerun required checks on the final
   candidate and reassess evidence after intervening changes.

Run records use the fields `check` (a CHECK ID), `commit` (40 hexadecimal
characters), `date` (YYYY-MM-DD), `command`, `result` (`pass`, `fail`, `skip`)
and `report` (a repository-relative report file or a GitHub Actions run URL).
Append reruns in execution order: the latest recorded revision must have a
passing result for every check before using `verified`. Preserve failed and
skipped attempts. CI URLs identify executions, but their output may expire;
archive important output and reassess evidence if its report is no longer
available. Never place credentials or production data in reports.

From the repository root:

```sh
python3 scripts/check_safety_evidence.py --write
python3 scripts/check_safety_evidence.py
python3 scripts/check_safety_evidence.py --base <base-commit>
python3 -m unittest discover -s scripts/tests -p 'test_safety_evidence.py'
```

`--write` updates only the generated control table in STPA. CI checks structure,
unique IDs, references, required evidence fields, generated-table consistency
and review updates for changed referenced files (using both base and head
references). It does not execute commands from the register or decide whether
a proof, report, or review note is sufficient. For a changed verified control,
provide new execution evidence or mark it stale. Reviewer judgement is still
required for all claims, including newly added code not yet in the register.

## Initial audit

The register is seeded from static inspection of commit
`aaf0b8568b25b1be84c771fc4ea8b1118bee5ff7`. No runtime guarantee is marked verified.
The successful Lean library build reported during review is not an archived
per-control execution report. Existing E2E suites are verification candidates,
not proof that these fault scenarios passed; notably a self-demotion test can
skip the very behavior it names. Deployment-specific alert enablement and
sampled data measurements have no archived evidence here and remain unverified.
