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

/-- Real-API race check of the promotion intent CAS adapter: creates, uses and
    deletes ONE ConfigMap (args: namespace, name). Not run by CI. -/
lean_exe promotion_intent_store_check where
  root := `FlareOperator.StateMachine.PromotionIntentStoreCheckMain

/-- history-tracking 10: deterministic replay of the promotion decision
    (docs/analysis-rc67-matrix-failures-2026-10-15.md). Prints; asserts nothing. -/
lean_exe ht10_replay where
  root := `FlareOperator.Repro.HistoryTracking10
