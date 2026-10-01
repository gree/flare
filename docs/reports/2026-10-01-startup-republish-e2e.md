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

## Second CI execution — PR run 36831110279 on 098c00b (merge rev 8ed8f1d): FAIL, test premise

The other four legs passed again (20/20, 47/47, 45/45, 48/48), as did the
other breaker-migration tests (37 of 38, breaker tripped in 5 s). This time
the old pod was gone before the logs were read, and the new test reached its
attribution check:

    resumed at v4294967309; first send:
    [versionMoved=true pending=v8589934592 repairHeld=0 activeNotReady=0]
    topology changed (v8589934592 → v8589934593), broadcasting

The fresh process raised its version to the new leadership generation's base
and seeded pending with it, as designed. Its first pass then advanced the
version again. Cause: the persisted node map carries no read balance, so
the reloaded map has every node at balance 100. The first pass re-applies
spec.readBalance (slave 25 in this test), sees a changed map and advances
the version. The startup seed was therefore one of two reasons for the send.

The test now holds a change to slave weight 100, the one weight a reloaded
map already has, so the reload changes nothing and the seed is the only
reason left. The content marker still moves, 80 to 100. Recorded as FAIL on
CHECK-01-startup with this classification. Log
`2026-10-01-ci-36831110279-breaker-migration-e2e.log`.

### Finding recorded under EV-01 (no code change)

Read balance, including the SAF-10c withholding of non-following replicas,
does not survive an operator restart. Until the first pass, the in-memory map
gives every node balance 100. The operator answers `node add` from that map.
After a takeover its version is the new generation base, newer than any pod
holds. A flared pod that boots in that window adopts a map in which withheld
followers carry balance 100, until the first pass pushes the corrected map a
few seconds later. Running pods are not affected, because flared requests
the map only at boot. Persisting the balance, or holding `node add` replies
until the first pass, would close it. Either is a design change for the
reviewer.

## Fix for the finding (2026-10-01, CI pending)

The node-map ConfigMap now stores each node's committed balance
(`balance=`), which already includes the SAF-10c withholding. A reloaded
map is therefore the last committed map, and a withheld follower stays at 0
across a restart. A line written before this change has no `balance=`
token. It loads conservatively, with the master at 100 and every other node
at 0, until the first pass re-applies the spec. Two proofs cover it:
`nodeMapVersion_roundtrip` (balances 100, 0 and 25 survive) and
`legacy_line_balance_fallback`. The startup-republish E2E uses slave weight
25 again. With the fix its first pass should not move the version, so the
test now also guards the persistence.

## Third CI execution — PR run 36835797814 on fbb3860 (merge rev 37bcb3e): PASS

All five legs passed (20/20, 47/47, 45/45, 48/48, 38/38). The new test, with
slave weight 100 and before the balance-persistence fix:

    before: both pods at node_map_version 4294967308, slave balance 80
    operator pods before [flare-operator-768fdbb4cb-9q6k9],
                  after  [flare-operator-76c4d9c66f-sf675]
    resumed at v4294967309; first send:
      [versionMoved=false pending=v8589934592 repairHeld=0 activeNotReady=0]
      topology changed (v8589934592 → v8589934592), broadcasting
    after: both pods at 8589934592, slave balance 100 (committed 100)

The fresh process's first send was pending-only, with the audit off. It
delivered the withheld weight to both pods. The startup seed alone recovered
a map that was committed and never sent. The test at weight 25, which also
checks balance persistence, is in the next push. Recorded as PASS on
CHECK-01-startup and the nine other checks at 37bcb3e.
