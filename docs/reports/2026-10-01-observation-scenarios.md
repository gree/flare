# Observation scenarios from handoff §3 (2026-10-01)

Three E2E scenarios the handoff listed as missing:

- same-name Pod replacement during a stats read;
- an operator restart while stats cannot be read;
- read recovery in a cluster without follow mode.

## 1. Same-name Pod replacement during the topology probe — PASS (PR run 36874157713, merge rev 0a8c84a)

Test seam `FLARE_TEST_PROBE_BARRIER` holds the audit probe of one pod
after its first UID read, with a 30 s ceiling. The test replaces that pod
under the same name and releases the probe. On CI:

    probe of topo-auth-nodes-1 held after reading uid 1e7a405a-…
    topo-auth-nodes-1 replaced: uid 1e7a405a-… -> 969f129b-…; probe released
    [TopologyAudit] node=topo-auth-nodes-1… uid=(some 969f129b-…)
      desired=4294967307 reported=none verdict=unknown

A later probe observed the new UID as current, and the topology was applied
again. Registered under CHECK-01-observation.

Limit: the follow-evidence stats reads, which drive read and promotion
eligibility, are not bracketed by UID reads. They are re-evaluated every pass
and bounded by flared's local read guard. Recorded as a residual risk under
EV-01.

## 2. Operator restart while the replica's stats cannot be read — PASS (PR run 36877273395, merge rev bff234e)

In continuous-replication, with spec slave=50 and the replica served, the
operator loses `pods/exec` on the replica and its pod is replaced. The test
requires:

- the fresh process withholds the replica (committed balance 0);
- the follower keeps following;
- the master is unchanged and nothing is demoted;
- after `pods/exec` returns, the replica is served at 50 again, with no
  reconstruction and the same pod UID.

Registered under CHECK-04-eligibility.

## 3. Read recovery without follow mode — PASS (PR run 36877273395, merge rev bff234e)

In read-balance, with spec slave=100 and a standby, the operator pod is
replaced. The test requires:

- the fresh operator logs its stats probe;
- every regular slave is back at 100 and the standby at 0 within 120 s;
- no follow-eligibility decision appears in that cluster.

Registered under CHECK-04-eligibility.

## CI evidence for 2 and 3 — PR run 36877273395 on 4f0c9b7: all 8 legs, 201 tests PASS

Scenario 2:

    blind fresh operator: replica balance=0 withheld=true; stored 10/10;
      follower caught up=true; master=cont-repl-nodes-0
    after restoring pods/exec: balance=50 restored=true;
      reconstruction_started 2→2; pod uid unchanged

Scenario 3:

    after the operator restart: probed=true; balances
      rb-test-nodes-0 slave 100, rb-test-nodes-1 master 100,
      rb-test-nodes-2 (standby) slave 0
