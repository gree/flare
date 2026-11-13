# Contributing to this fork

This repository is upstream **flare** plus a Kubernetes **operator** that
replaces the classic `flarei` index server. Both halves ship together, so a
change is rarely "just C++" or "just Lean" — read [README](README.md#layout)
first if you have not.

## Build and test

| What | Command | Notes |
|---|---|---|
| flared (C++) | `nix build .#flare -L` | The same build CI runs. Do this before pushing C++ — the autotools build is not exercised by the Lean tooling |
| flared unit tests | `nix build .#test-flare -L` | cppcutter suites under `test/` |
| RocksDB variants | `nix build .#flare-rocksdb -L`, `nix build .#test-flare-rocksdb -L` | The backend production uses |
| Operator library + proofs | `cd flare_operator && lake build FlareOperator` | Elaborating the library **is** checking the proofs |
| Operator binaries | `lake build flare_operator && lake build flare_e2e` | Separate invocations on purpose — see the note in the E2E workflow |
| E2E (needs kind + docker) | `.lake/build/bin/flare_e2e --filter <suite>[,<suite>]` | `--list` prints the 26 suites |

CI runs the C++ build through nix and the operator through four parallel E2E
shards. A full E2E round is ~45 minutes of wall clock, so **verify locally
before pushing**: a broken build discovered by CI costs an hour, and a
broken build discovered by CI *after* a tag costs a re-tag.

## Working on the operator

The operator is a state machine in Lean 4, deliberately split so that the
decisions are pure and the effects are not:

- `StateMachine/` — pure transforms plus the proofs about them. No IO.
- `Main.lean` — the IO shell: fetch, decide, apply, measure.
- `Server/` — the flarei-compatible TCP surface flared talks to.
- `K8s/Bridge.lean` — every `kubectl` call the operator makes.

Rules that exist because breaking them cost us incidents:

1. **Anything that can change roles goes through the pure layer.** If you
   find yourself mutating the node map from `Main.lean`, ask whether the
   decision belongs in `StateMachine/` where it can be reasoned about.
2. **Touching promotion, demotion or failover means re-reading the proofs.**
   `StateMachine/GeneralSafety.lean` bounds "at most one master per
   partition" over the commit path. This is a property of the committed map,
   not proof that distributed flared processes cannot serve concurrently as
   master. Reassess assumptions and production call paths as well as proofs.
3. **Normal drain/failover promotion requires an Active successor.** Use
   `findActiveSuccessor`. Emergency masterless refill currently permits a
   partial Prepare copy to become authoritative to restore availability.
   That exception can lose data and is tracked separately in SC-06; do not
   generalize it to ordinary promotion. Active itself needs valid sync evidence.
4. **Never take a destructive action on feedback you cannot trust.** If the
   operator cannot reach a node, the fault may be the operator's. Alert,
   do not fail over. See [STPA-node-state.md](docs/STPA-node-state.md).
5. **Deleting a pod deletes data** on a tmpfs cluster. Every pod-delete path
   is gated on every partition having an Active master and the circuit
   breaker being clear. Those gates alone do not prove data preservation:
   unknown/stale stats and changes to the successor can invalidate them.
   SAF-04/06 track revalidation before deletion.
6. **A log must not claim an action the code did not take.** We shipped a
   `self-demoting to state_down` line for a call that could never work; a
   misleading log during an incident is worse than silence.

## Working on flared (C++)

- Live master→replica replication is **op-level proxying**, not WAL. The WAL
  path (`op_repl_sync_wal`) runs at reconstruction and at cluster-replication
  initial transfer only. Comments claiming otherwise have been wrong before.
- A write the master fails to forward is **dropped after four retries**. It
  is counted (`proxy_write_dropped`, and per destination) precisely because
  nothing else notices. If you add another internal write path, ask how a
  replica learns about it.
- Anything reachable from the client port is **attacker-shaped input**. A
  wire-supplied `partition_size` indexed an array unchecked and crashed a
  serving node from one request. Validate at parse time.

## Vendor neutrality

This repository stays vendor-neutral: no bucket names, account ids, cluster
names, issuer URLs or provider-specific assumptions. Those belong in the
deployment repository. The Helm chart takes them as values.

## Releasing

1. Push to the working branch; wait for build/E2E and safety-evidence CI to go green.
2. Tag `v0.1.0-rcN` on the green commit. Tagging publishes the chart to
   `ghcr.io/gree/charts` and five images to `ghcr.io/gree`.
3. Bump the deployment repository's overlay to the new chart version, render
   it (`kustomize build --enable-helm`) and open a PR. Never push to that
   repository's main branch.

Two rules learned the hard way: **do not push again while CI is running**
unless you intend to cancel it (the concurrency group cancels in progress),
and **make verification gate the push** — chaining a render and a `git push`
with `;` runs the push even when the render failed.

## Documentation

Docs live in `docs/`. Keep [RUNBOOK.md](docs/RUNBOOK.md) in step with
alerting: an alert without a runbook section is an alert nobody can act on.
When an incident teaches something structural, write it into
[STPA-node-state.md](docs/STPA-node-state.md) rather than a commit message,
and mark what the code actually does. The evidence register owns control
status; the STPA status table is generated from it.

## Safety evidence review

Use [SAFETY-TODO.md](docs/SAFETY-TODO.md) for the improvement backlog and full
workflow. In every relevant PR, link the safety constraint (SC), evidence (EV)
and task (SAF) IDs. Update the affected register entries with code symbols,
production call paths, assumptions, residual risks and a new review impact note.
If none apply, explain why in the PR template; reviewers check for missing coverage.

Reference changes require a review even if they only change comments. Keep the
inspection commit and verification commit distinct. Mark invalidated evidence
`stale`; `verified` requires passing evidence for every listed check on a common
tested revision. Record skipped/failed checks honestly. Never turn a source
inspection, test name, or alert definition into proof of successful recovery.

```sh
python3 scripts/check_safety_evidence.py --write
python3 scripts/check_safety_evidence.py --base <base-commit>
python3 -m unittest discover -s scripts/tests -p 'test_safety_evidence.py'
```

The lightweight CI checks files, fields, generated content and review updates.
It does not run evidence commands or certify their conclusions. A reviewer must
check that the guard is reached on the live path and that failures or concurrent
repairs cannot bypass it. Documentation-only edits need these checks, not an
unrelated full E2E run. Operator runtime changes still need their relevant tests.

### CI-first runtime validation

Prefer CI for full cutter and kind E2E runs; keep local feedback to focused
tests and static checks. The E2E workflow builds and runs `flare_unit`, then
runs the five E2E shards. The `nix-linux` workflow tests both legacy and RocksDB
builds. Result artifacts retain the checked-out SHA and command logs for 30 days;
copy durable evidence into the register/reports before artifacts expire.

For longer evaluations, manually run **E2E Tests** on the intended branch and
select `evaluation`: `sustained`, `scale-2m`, or `scale-15m8`. The selected
evaluation is enabled only on the continuous-replication shard; the other
shards still run normally. `none` (the PR default) skips opt-in evaluations.
A skipped evaluation is not a passing performance result. Large profiles may
exceed hosted-runner resources; report that outcome rather than treating it as
production capacity evidence. These runs do not measure T17 lock contention.

Workflow changes must first reach the remote branch before CI can test them.
Attach the run URL, actual tested SHA (PR checkout may be a merge revision),
profile and results to the evidence register; CI green does not itself promote
an EV to `verified`.
