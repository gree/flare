# SAF-09 increment: fresh recipient observations and startup republish

Baseline: 87f1728 plus accompanying changes. Prior baseline CI completed green:
E2E 36285235090, nix-linux 36285235111, evidence 36285235089. Those runs do
not validate the new changes described here.

Each reconcile audits one mapped node, round-robin. It brackets a complete
stats reply with API Pod UID reads and compares node_map_version with the
committed map. Missing/changing UID, truncated stats, missing or duplicate
version fields are Unknown. A lower version requests delivery through the
existing pending flag and lease fence. Equal is current at observation time.
A higher version logs an authority mismatch: it is NOT overwritten by
inventing a new version, and it is not called a dead or unhealthy node.

The in-memory audit contains node key, observed Pod UID, reported version,
observation time and verdict. A fresh Unknown replaces old confirmation;
removed keys are pruned. Historical samples never suppress a fresh probe or
authorize a destructive operation. No historical samples are restored from
status at process startup: the new operator requests republishing its current
committed map, then starts observing from scratch.

API calls use dedicated 2s UID / 3s stats / 2s UID command budgets (1s kill
grace each), avoiding three generic 30s kubectl waits. An unavailable first
UID skips the other calls. This adds reconcile latency; scale/lease-renewal
impact still needs measurement. A stable N-node map takes approximately N
passes to audit fully. This is not immediate detection or a latest-read guard.

Tests: eleven pure observation checks cover complete/truncated/duplicate
stats, older/equal/newer versions, UID mismatch/missing UID and replacement
of cached confirmations. The continuous-replication normal-following test now
requires a UID-bound current observation from the production audit path.
Runtime acceptance is pending CI; no EV is promoted to verified.

Local validation: flare_unit 165/165, operator/E2E builds, evidence checker
and 21 bookkeeping fixtures pass. Adding CHECK-01-observation exposed two
positive fixtures that hard-coded one check for EV-01; they now synthesize
passing records for every declared check at the same revision, without
relaxing the checker. Early compile errors in test list access and the probe
record layout were corrected before these passing builds.

Residuals: UID reads and stats are not atomic; a container can restart without
changing Pod UID, or immediately after observation. Re-probing, not a permanent
health certificate, is the response. Samples are diagnostic process memory,
not a durable per-recipient delivery ledger or exported lag metric. Unknown
does not itself request a broadcast. New-leader generation regression remains
unresolved; startup republish cannot override a node with a newer version.
The lease check/send race is unchanged. A deterministic E2E isolating startup
republish as the sole recovery path and same-name Pod replacement during the
observation is still needed.
