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
   partition" over the commit path. A change that only ever promotes *fewer*
   nodes keeps the bound for free; anything else needs the proof re-checked,
   not just re-run.
3. **Never promote a node that is not Active.** The partition map lists
   slaves of every state; a reconstructing one is not a successor. Use
   `findActiveSuccessor`.
4. **Never take a destructive action on feedback you cannot trust.** If the
   operator cannot reach a node, the fault may be the operator's. Alert,
   do not fail over. See [STPA-node-state.md](docs/STPA-node-state.md).
5. **Deleting a pod deletes data** on a tmpfs cluster. Every pod-delete path
   is gated on every partition having an Active master and the circuit
   breaker being clear. Keep it that way.
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

1. Push to the working branch; wait for **both** CI workflows to go green.
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
and mark what the code actually does — that document carries a status per
row for exactly this reason.
