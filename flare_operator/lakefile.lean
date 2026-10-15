import Lake
open Lake DSL

package flare_operator where
  leanOptions := #[
    ⟨`pp.unicode.fun, true⟩,
    ⟨`autoImplicit, false⟩
  ]

@[default_target]
lean_lib FlareOperator where
  globs := #[.submodules `FlareOperator]

lean_exe flare_operator where
  root := `FlareOperator.Main

lean_exe flare_e2e where
  root := `FlareOperator.E2E.Main

lean_exe circuit_breaker_sim where
  root := `FlareOperator.StateMachine.CircuitBreakerSimMain

/-- Executable unit checks for the pure decision code (see UnitTests.lean). -/
lean_exe flare_unit where
  root := `FlareOperator.UnitTests

/-- history-tracking 10: deterministic replay of the promotion decision
    (docs/analysis-rc67-matrix-failures-2026-10-15.md). Prints; asserts nothing. -/
lean_exe ht10_replay where
  root := `FlareOperator.Repro.HistoryTracking10
