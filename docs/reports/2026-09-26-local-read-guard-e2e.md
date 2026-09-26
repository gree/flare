# Selective-fault local read-guard acceptance

Implementation baseline: `3cb1d5ad5448152cdb7b4dbef90d50d9e7760169` plus
the accompanying test changes. No production behavior is changed.

The continuous-replication suite now contains a separate scenario that:

1. Observes balance 50 in the replica's own `stats nodes`, and a caught-up
   follower (not just the operator's desired map).
2. Rejects `node sync` requests to that replica, forwarded writes from the
   master, and `repl_sync_wal` requests from the replica. Ordinary replica-to-
   master GET traffic is not blocked.
3. Requires the follower to report disconnected, writes a new key on the
   master, and requires an increased dropped-forward counter and a WAL gap.
4. Reads the key through the replica and requires the master's value while
   local balance remains 50 and both applied cursor and forwarded-apply
   counter remain unchanged. Neither a cache miss nor a stale local read
   passes. If the payload-matching fault fails, these preconditions fail.
5. Removes faults and restores slave balance 0 in `finally`; waits for the
   actual local map and follower to recover before the next scenario.

Validation: the Lean E2E executable builds locally. Runtime validation is
pending CI; no E2E pass or verified control is claimed. Full builds, cutter,
and kind E2E are intentionally left to CI.

Limits: this is not a linearizable-read proof, a master-unreachable error
semantics test, or the operator-restart/non-WAL recovery acceptance scenario.
Those remain separate tasks. The string rules target small plaintext protocol
requests in kind, not a production network-fault mechanism.

## First CI execution: routing passed, cleanup failed

Head `0ed3193`, E2E run 36228379804, scenario 9: local balance stayed 50,
cursor stayed 123, forward-applied stayed 58, master head was 124, and GET
returned `from_master`. The routing assertion passed. Cleanup timed out,
so the scenario and overall run are FAIL, not a passing acceptance run.

The initial cleanup immediately set spec.slave=0 while the operator could
already have committed withheld balance 0 during the fault. This is consistent
with the known SAF-09 lost-map retransmission gap. Cleanup now waits for
following/caught-up at balance 50 before requesting a distinct 50-to-0
transition. This is a harness recovery change, not a SAF-09 production fix;
the revised scenario requires another CI run.
