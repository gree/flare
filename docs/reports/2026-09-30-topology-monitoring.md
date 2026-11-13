# Topology monitoring and production readiness

Baseline: 4a516e6 plus these working-tree changes. Its three CI workflows
passed; that result does not certify the current changes.

Added `flare_operator_topology_observed_behind_nodes`,
`flare_operator_topology_observed_ahead_nodes`, and
`flare_operator_topology_unknown_nodes`, exported with existing cluster labels.
The summary counts only mapped keys and recomputes comparison with the current
desired version. Missing/invalid/future/over-60s samples are Unknown; an old
current verdict cannot hide a new desired topology. Added three diagnostic
PrometheusRule alerts and an operational runbook. No action is triggered by
these metrics or alerts.

Local validation: 174 unit checks, 3 Helm rendering checks, operator build and
Helm lint pass. Unit tests cover expiry, clock reversal, invalid observations,
desired-map changes, removed nodes and actual exporter TYPE headers. Helm tests
check rendered expressions and runbook links. This is NOT live Prometheus
evaluation or notification-delivery evidence. Runtime tests remain on CI.

Limits: gauge values update on reconcile; they can freeze if the operator
stalls. One observation per pass means large clusters can exceed the fixed
60s freshness window. Monitor reconcile progress/availability and measure
coverage; do not reinterpret Unknown as healthy or dead. A zero lag gauge
does not establish content equality, safe failover or zero acknowledged loss.

`docs/PRODUCTION-READINESS.md` consolidates the remaining implementation,
acceptance, capacity and rollout gates. No new production approval or verified
EV is claimed. Sustained performance after the MORE fix remains to be executed.
