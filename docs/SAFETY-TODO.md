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
| SAF-10 | Separate design | Parent task: op-level forwarding for low-latency propagation KEPT, plus continuous WAL replication for gap-free recovery, so a replica that lost connectivity catches up automatically while the master survives. Both paths must deliver identified changes through one apply rule; the current verbatim WriteBatch apply must not run alongside forwarding. Decomposed into SAF-10a..d below. Guarantees excluded up front: acknowledged-write survival against master data loss, synchronous ACK, latest-read from coexistence alone, cross-partition placement, Tokyo Cabinet. | SC-03, SC-04, SC-13 / EV-03, EV-04, EV-13 (+ proposed SC-14..16) | No dependency for the design |
| SAF-10a | Separate design | Audit the existing recovery code with call paths and produce the continuous-replication design: replication path choice (WAL-only for WAL-mode replicas vs. coexistence with op-level proxy), guarantee scope, open hazards. Review gate before any implementation. | SC-13 / EV-13 | None |
| SAF-10b | Next stage | flared: the COMMON APPLY RULE for both delivery paths (decode every change to `{key, type, value, flag, expire, version, session, src_seq}`; apply iff `src_seq` exceeds the key's applied source sequence; persistent tombstones carrying the delete's sequence, dropped only once the applied position has passed the delete; a change at or below the applied position is refused whichever path delivered it; read-decide-write in one critical section with GC inside the applier's exclusive window; reserved keys never applied as data) plus continuous fetch/apply — follow mode with bounded responses, contiguous cursor that no forwarded write may advance, crash-atomic position in one WriteBatch with the changes, self-driven reconnect that needs no new writes, session validation at apply time, explicit needs-rebuild on lost history, resource ceilings and tombstone GC. Verbatim WriteBatch application is removed. | SC-03, SC-13 / EV-03, EV-13 (+ SC-14..17) | SAF-10a |
| SAF-10c | Next stage | Operator interface: source/generation, contiguous applied position, master position with observation time, stream state, last progress, reason codes; purpose-specific eligibility for reads, promotion and copy deletion with Unknown handling; suppress the replica-repair ledger for WAL-mode nodes so only one rebuild runs. | SC-04, SC-05 / EV-04, EV-05, EV-11, EV-15 | SAF-10b |
| SAF-10d | Next stage | Acceptance tests on RocksDB, inspecting the replica directly (never a proxied read): snapshot-to-continuous hand-off, link cut with create/update/delete, catch-up with no further writes, mid-batch disconnect and crash at an apply boundary, repeated cuts, retention overrun, stale source refusal, operator restart, resource limits under a slow replica, and the coexistence rule (forwarded-newer-then-older-WAL, delete-then-older-put, same change by both paths, touch/incr cross-delivery, old put after tombstone GC, a forwarded change stalled across a GC, and an old-session forwarded change after a snapshot restore). | SC-03, SC-04, SC-13 / EV-03, EV-04, EV-12, EV-13 | SAF-10b, SAF-10c |
| SAF-11 | Next stage | Circuit breaker counts the nodes that became dead in ONE tick against the whole map, not the cluster's dead fraction (`detectDeadNodesPure` excludes Down and Prepare), so a majority outage whose pod deaths straddle 5s ticks never trips and is handled as serial failover. Found by CI on the SAF-01..07 branch (2 of 8 executions did not trip). Decide the intended semantics, then change the count or the claim. | SC-09 / EV-09 | None |

**Status (this branch).** SAF-01 through SAF-07 are implemented with tests on
this branch. A review of the first cut (HEAD ffa2a05) reopened SAF-02 to
SAF-06 with six findings, all confirmed and fixed on the same branch in three
groups: sync-evidence generation (a past reconstruction credited as the
current copy; missing RocksDB lineage/cursor accepted), ledger fault
tolerance (late drops declared recovered; a failed save never retried; a
failed or corrupt read treated as "no ledger"), and delete revalidation (live
map read before the stats; no lease or pod-UID check). A second review (HEAD
ccca200) found four more, fixed in three commits: the pod UID is now an
API-side delete precondition (DeleteOptions.preconditions.uid, refused with
409 for a same-name replacement) instead of a client re-read; a partially
corrupt ledger fails as a whole instead of loading smaller; and completion is
judged from an explicit per-process reconstruction record flared now exposes
(boot id, latest id and state, last success id and source) instead of
cumulative counters, which could neither recognise a success after a failure
nor tell a restart with identical counters. A third review (HEAD d08fe06)
found two defects in that new code, fixed in two commits: flared's completion
notifications now carry the handler's own id (an older handler finishing
after a newer one started can no longer record the newer id as succeeded;
the record is read as one locked snapshot), and the direct-API UID-precondition
delete has connect/overall deadlines and reports transport failures instead
of stalling the reconcile. A fourth review (HEAD 48245be) confirmed those two
and asked for two finishing touches, done on the same branch: a timed-out or
failed DELETE is reported as an UNKNOWN deletion outcome (the API may have
accepted it and only the reply was lost; re-observe before retry), and the
deadline E2E now requires a timeout (curl exit 28) on a connection the black
hole provably accepted, so a refused connection no longer passes it. A last
harness-only fix (22fd148) captures that acceptance evidence before the black
hole's pod is deleted, not after. The first CI run of the branch (PR #143)
failed one test, the SAF-01 lease-takeover scenario, on a harness race
(the fence line was read from the wrong container after the designed exit)
fixed together with a second ordering fault it uncovered; the second CI
run failed the sibling read-failure scenario on a negative check that also
matched the operator's legitimate retry. All three are harness-only, the
operator's logged behaviour was the specified one in every run, and the runs
are recorded under EV-01 with the log-timing dependence added as a residual
risk. The third CI run and its re-run (same revision) each failed one
different thing: the pre-existing circuit-breaker E2E once (a FINDING, recorded
under EV-09: the breaker counts nodes that became dead in one tick, not the
cluster's dead fraction, so a 4→1 outage whose deaths straddle ticks never trips;
not changed on this branch), and the replica-repair harness once (its `pair`
helper required role Slave in the instant after the repair had demoted the
replica to a held Proxy — fixed in the harness). The fourth CI run
(c148c6c) was the branch's first fully green matrix; the register records it
per control, with the reviewer's assessment of the round-4 fixes, and nothing
is promoted to `verified` by it. The fifth run (docs-only) failed again: the
breaker did not trip a second time (2 of 6 executions), and the SAF-05
save-failure test had assumed a runner-side impersonated `can-i` mirrors the
operator's authorization — it does not: the operator's own status patch stayed
Forbidden for over two minutes after the grant returned. The test now probes
from inside the operator pod as its own service account; the two-minute
window is recorded as a residual risk under EV-03. The PR went back to draft.
The sixth run (f7d327f, 2026-09-16) was fully green; the two-minute RBAC
latency did not occur in it, so the in-pod probe remains unexercised under
that condition (noted in EV-03). Still nothing promoted to `verified`. The
seventh run (evidence-only commit) failed a general E2E outside the SAF
controls, partition-reduction test 5: a fixed 15s sleep raced a 14s reconcile
tick, so the operator had not yet seen the patched CRD when the log was read
once (the diagnostics confirm neither the 'CRD changed' line nor the warning
existed yet). The suite now waits for the operator's own evidence; harness
only (docs/reports/2026-09-16-ci-e2e-replication-685853e-fail.txt). The PR
went back to draft again. The eighth run failed the SAF-05 save-failure test
again, and this time the cause corrects an earlier reading: the request HAD
landed (silently, through the normal per-pass persist) while the test waited
for the retry path's log line; the "~2 minutes of RBAC latency for the
operator" attributed to CI runs 5 and 8 was that harness artefact, and the
only real latency observation is a single local one. The test now judges the
outcome. The operator's silence about a landing after it announced an
unsaved ledger is recorded under EV-03 as an observability gap with a
proposed one-line follow-up (not made here). The evidence register
owns exact implementation and verification state, which stays `unverified`
until a reviewer signs off; EV-03 is held at `partial` because two scenarios
are pinned only by `flare_unit` and not staged end to end (a drop in the last
stretch of a reconstruction; a change interposed between the delete's
observation and the delete). SAF-07 is the "Guarantees, and what they are
not" section of the [README](../README.md). SAF-08 through SAF-10 remain out
of scope; SAF-10 is now decomposed (SAF-10a..d) and its design stage is
[design-continuous-wal-replication.md](design-continuous-wal-replication.md),
which is a DRAFT for review — audit and design only, no implementation, and
no register entry is promoted by it. Revision 2 records the reviewer's
decision to keep both delivery paths and adds the common apply rule they
require; the audit establishes that the existing per-key `version` orders
updates of a live key and nothing else (delete/re-create, touch, incr,
internal deletes and a master change are all outside it), which is why the
rule uses the master's commit sequence instead. Revision 3 replaces the
time-based tombstone GC with refusal by applied position, specifies the
serialization from decision to write, and records the four preconditions
without which the sequence comparison is unsound — session identity needs a
generation token (`regenerate_master_id` fires only when the cursor exceeds
the node's own sequence, so two DBs can share a `master_id` over unrelated
sequence spaces), the forwarded sequence must be captured inside the key's
critical section (otherwise a set and the delete that follows it can carry the
same number and a deleted key is resurrected), per-entry numbering must match
the batch's own count, and metadata inherited through a snapshot swap must be
cleared. Re-audit of older DONE claims lives in
[STPA-node-state.md](STPA-node-state.md#8-what-this-document-got-wrong).

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
