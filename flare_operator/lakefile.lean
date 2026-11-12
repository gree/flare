import Lake
open Lake DSL

package flare_operator where
  leanOptions := #[
    ⟨`pp.unicode.fun, true⟩,
    ⟨`autoImplicit, false⟩
  ]

/-- The operator: every module but the E2E harness (FlareOperator.E2E is
    its own library below). A new top-level directory under FlareOperator/
    is listed here. -/
@[default_target]
lean_lib FlareOperator where
  globs := #[.one `FlareOperator.Main, .one `FlareOperator.Kubectl, .one `FlareOperator.TcpServer,
    .submodules `FlareOperator.Crypto, .submodules `FlareOperator.Flare,
    .submodules `FlareOperator.Health, .submodules `FlareOperator.K8s,
    .submodules `FlareOperator.Metrics, .submodules `FlareOperator.Migration,
    .submodules `FlareOperator.Operator, .submodules `FlareOperator.Repro,
    .submodules `FlareOperator.Server, .submodules `FlareOperator.StateMachine]

lean_exe flare_operator where
  root := `FlareOperator.Main

/-- The E2E harness, compiled at -O0 like the unit checks: its suites are
    long constant scripts (E2E/Tests/ContinuousReplicationLimits.c took 28 min
    of C compile at -O3 in a cache-miss build, kjob-run-flare-operator-8ad1);
    it drives kubectl and waits, so -O0 costs nothing at run time. Nothing in
    the operator imports it. -/
lean_lib FlareOperatorE2E where
  globs := #[.submodules `FlareOperator.E2E]
  moreLeancArgs := #["-O0"]

lean_exe flare_e2e where
  root := `FlareOperator.E2E.Main
  moreLeancArgs := #["-O0"]

lean_exe circuit_breaker_sim where
  root := `FlareOperator.StateMachine.CircuitBreakerSimMain

/-- The unit checks, a library of their own compiled at -O0: each constant
    check is specialised into tens of thousands of C lines (UnitTests.lean
    ~2,900 lines -> UnitTests.c ~520,000 lines), which -O3 compiled in ~75 min
    on CI and -O0 in about a minute. The checks run in well under a second
    either way. Not part of FlareOperator, so the operator never builds them. -/
lean_lib FlareOperatorTests where
  globs := #[.submodules `FlareOperatorTests]
  moreLeancArgs := #["-O0"]

/-- Executable unit checks for the pure decision code (see UnitTests.lean). -/
lean_exe flare_unit where
  root := `FlareOperatorTests.UnitTests
  moreLeancArgs := #["-O0"]

/-- history-tracking 10: deterministic replay of the promotion decision
    (docs/analysis-rc67-matrix-failures-2026-10-15.md). Prints; asserts nothing. -/
lean_exe ht10_replay where
  root := `FlareOperator.Repro.HistoryTracking10
