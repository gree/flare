# SAF-11 — breaker counts capacity unavailable now (EV-09)

Date: 2026-10-01. Status: implemented, proved and unit-tested locally; CI
pending. No EV promoted.

## Problem

The breaker's count came from dead-node detection, which reports only nodes
that became dead in the current tick. It skips nodes already Down (failover
demotes a dead node to Proxy+Down) and nodes in Prepare. A 50% trip therefore
needed half the cluster to vanish inside one 5 s tick. A majority outage
spread over two ticks, 25% + 25% on four nodes, never tripped, and failover
continued one node at a time. Seen five times on CI in the breaker E2E.

## Definition chosen

The breaker counts nodes **unavailable now**:

- nodes dead in this tick, plus
- nodes already Down, whatever their role, plus
- nodes in Prepare whose pod is not live.

Dead-node detection, and therefore failover, is unchanged. The trip and
reset thresholds, the hysteresis and their proofs apply to the new count.
No time window or new state was added. The user asked on 2026-10-01 to fix
the existing problems; this definition was proposed earlier in the session
and is the reviewer's to confirm.

Behavioural consequences:

- A long-standing Down node keeps counting, so it lowers the margin for
  later failures. One Down node in eight is 12% and does not trip.
- While tripped, a tick with no new deaths now still runs the hysteresis.
  Before, such a tick took the no-dead path and the breaker reset silently.
- The "detected N dead nodes" line now also names the breaker's count and
  the earlier unavailable nodes.

## Evidence

- `breakerUnavailableKeys` and `breakerUnavailable_ge_dead` (the count is
  never smaller than this tick's deaths, so every outage that tripped before
  still trips) in `StateMachine/K8sReconciler.lean`. The FSM termination
  proof was updated to the new count.
- Seven unit cases in `flare_unit`, including the four-node, two-tick case
  and the old count for the same tick. 186/186 pass locally.
- The circuit-breaker E2E is unchanged; it should now trip on every run.
  CI pending.

## Related fix in the same push: planned-promotion E2E (EV-04)

The planned-promotion test never logged the graceful drain on CI. Cause: the
operator's startup grace is 24 reconcile cycles, not 120 s. In the
continuous-replication suite a pass takes 2-3 s on top of the 5 s interval,
so the grace lasts about 190 s. The test's wait for a 150 s-old operator
deleted the master inside the grace, where drain and dead detection are
skipped. Once the grace ended, the pod was gone and dead-node failover
promoted the follower about 35 s after the delete. The test now waits for the
operator's own `grace period: 0 cycles remaining` line plus one cycle, and it
now requires the drain line. Earlier passes proved the promotion and the
epoch advance, not the drain path.

### Follow-up finding (CI 36841064685): the drain refused the proven follower

With the grace wait fixed, the drain ran on CI for the first time, and its
guard refused the follower:

    promotion: follower promoted=true; drain logged=true;
    drain blocked (guard refused)=true

The follower was then promoted about 35 s later by dead-node failover. The
probe that proves a follower current read the master's head only from pods
that were Ready and not Terminating. During a drain the master is
Terminating by definition, so no follower could be proven and every planned
promotion in follow mode was refused. In production, a planned restart of a
master in follow mode would not hand off during preStop.

Fix: the master's head is read from any Ready pod, Terminating included. A
Terminating slave is still not read, because it is not a candidate. The
planned-promotion test now fails when the guard refuses. CI pending.
