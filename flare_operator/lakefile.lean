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
