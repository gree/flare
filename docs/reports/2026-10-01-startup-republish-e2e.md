# Startup republish alone — deterministic E2E (SAF-09 / EV-01)

Date: 2026-10-01. Branch `safety/saf-10-wal-replication`. Status: implemented and
unit-tested locally; the E2E has **not run yet** (CI pending). No EV promoted.

## Why a new test

On startup the operator seeds its pending-send flag with the committed map
version (`pendingBroadcastRef` in `Main.lean`), so a map that was committed
but never sent by the previous process is republished. Nothing tested that
the seed alone delivers such a map:

- The takeover test in `topology-authority` ends on "every pod names the same
  master". Its held change is a read-balance weight, so the old map already
  passes that check. It proves the exit and re-acquisition, not delivery.
- A fresh process has other reasons to send: a version change in its first
  pass, a replica-repair hold, an Active node whose pod is not Ready, and the
  topology audit marking a behind pod as pending. Any of them would hide a
  missing seed.

## What changed

- `BroadcastTriggers` (pure, `Server/TopologyBroadcast.lean`) replaces the
  four-way send condition. The pass sends exactly when `any` holds, and logs
  `broadcast trigger: versionMoved=… pending=… repairHeld=… activeNotReady=…`
  with every send. Five unit cases in `flare_unit` (179/179 pass locally).
- Test seam `FLARE_TEST_TOPOLOGY_AUDIT_OFF` skips the audit probe. One
  `getEnv` per pass when unset; it logs when set.
- New last test in `topology-authority`: hold a committed pass (weight 25)
  at the pre-send barrier, roll the operator with the seam set while the
  pass is held, then require
  1. the operator pod was replaced, the seam is reported, no audit probe ran;
  2. the fresh process resumed at a version ≥ the held one;
  3. its first send is pending-only and the broadcast line is `(vX → vX)`;
  4. every pod reports version X and the operator's committed slave balance,
     which must differ from what the pods showed before.

The old process cannot send: lease renewal runs in the held loop, so the new
pod takes the lease after it expires, and a barrier timeout in the old
process meets a foreign holder and fences.

## Residuals

- Tested only with the audit off; the interaction of the seed and the audit
  is not tested.
- Attribution rests on the logged trigger record, not a wire capture.
- The first pass could legitimately move the version (for example a
  re-registration). The test then fails as "not attributable"; that outcome
  would be a finding about the test's premise, not a delivery failure.

## First CI execution — PR run 36826494031 on a87aea3 (merge rev 6f1edf0): FAIL, harness precondition

The other four legs passed (continuous-replication 20/20, topology 47/47,
replication 45/45, wal-recovery 48/48), and breaker-migration passed 37 of 38;
its breaker tripped in 5 s. The new test failed before any delivery assertion:

    precondition: operator was not replaced (rollout complete=true,
    pods before [flare-operator-768fdbb4cb-vdcb7],
    after [flare-operator-768fdbb4cb-vdcb7, flare-operator-76c4d9c66f-f5j99])

`kubectl rollout status` returns once the new pod is available. The operator
reports Ready before it holds the lease, so the old pod was still terminating
when the test listed pods. The old process's last line is
`TEST BARRIER: holding before the pre-send lease check (v4294967309)`, so it
never sent the held version. This is a test-premise failure, not a delivery
failure, and says nothing yet about the startup republish. Fix: wait
up to 180 s for the old pod to disappear before reading logs. Log
`2026-10-01-ci-36826494031-breaker-migration-e2e.log`. Recorded as FAIL on
CHECK-01-startup with this classification. The other nine checks are recorded
as PASS at 6f1edf0.
