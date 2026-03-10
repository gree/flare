/-
  E2E/Framework.lean - Test runner framework with TAP output

  Provides TestCase, TestSuite, TAP output, CLI filtering,
  and a main entry point for running E2E tests.
-/

namespace FlareOperator.E2E

/-- Single test result -/
inductive TestResult where
  | pass
  | fail (reason : String)
  | skip (reason : String)
  deriving Repr

/-- A test case: name + IO action returning result -/
structure TestCase where
  name : String
  run : IO TestResult

/-- A test suite: group of tests with shared setup/teardown -/
structure TestSuite where
  name : String
  setup : IO Unit
  teardown : IO Unit
  tests : List TestCase

/-- Run a single suite, TAP output to stderr, return (total, failures) -/
def runSuite (suite : TestSuite) (startIndex : Nat) : IO (Nat × Nat) := do
  IO.eprintln s!"# === Suite: {suite.name} ==="
  try
    suite.setup
  catch e =>
    IO.eprintln s!"# Setup failed: {e}"
    -- Mark all tests as failed
    let mut idx := startIndex
    for tc in suite.tests do
      idx := idx + 1
      IO.println s!"not ok {idx} - {tc.name} # setup failed"
    try suite.teardown catch _ => pure ()
    return (suite.tests.length, suite.tests.length)

  let mut total := 0
  let mut failures := 0
  let mut idx := startIndex
  for tc in suite.tests do
    idx := idx + 1
    total := total + 1
    try
      let result ← tc.run
      match result with
      | .pass =>
        IO.println s!"ok {idx} - {tc.name}"
      | .fail reason =>
        IO.println s!"not ok {idx} - {tc.name}"
        IO.eprintln s!"#   reason: {reason}"
        failures := failures + 1
      | .skip reason =>
        IO.println s!"ok {idx} - {tc.name} # SKIP {reason}"
    catch e =>
      IO.println s!"not ok {idx} - {tc.name}"
      IO.eprintln s!"#   exception: {e}"
      failures := failures + 1

  try
    suite.teardown
  catch e =>
    IO.eprintln s!"# Teardown failed: {e}"

  return (total, failures)

/-- Count total tests across all suites -/
def totalTests (suites : List TestSuite) : Nat :=
  suites.foldl (fun acc s => acc + s.tests.length) 0

/-- Run multiple suites. Supports --filter <name> to run one suite. -/
def runAll (suites : List TestSuite) (filter : Option String) : IO UInt32 := do
  let filtered := match filter with
    | none => suites
    | some f => suites.filter (fun s => s.name == f)
  if filtered.isEmpty then
    match filter with
    | some f =>
      IO.eprintln s!"# Error: no suite matching '{f}'"
      IO.eprintln "# Available suites:"
      for s in suites do
        IO.eprintln s!"#   {s.name}"
      return 1
    | none =>
      IO.eprintln "# No test suites found"
      return 1

  let total := totalTests filtered
  IO.println s!"1..{total}"

  let mut grandTotal := 0
  let mut grandFailures := 0
  let mut startIdx := 0
  for suite in filtered do
    let (t, f) ← runSuite suite startIdx
    grandTotal := grandTotal + t
    grandFailures := grandFailures + f
    startIdx := startIdx + t

  IO.eprintln s!"# Tests: {grandTotal}, Failures: {grandFailures}"
  if grandFailures > 0 then
    IO.eprintln "# RESULT: FAIL"
    return 1
  else
    IO.eprintln "# RESULT: PASS"
    return 0

/-- Parse CLI args: --filter <name>, --list -/
private def parseE2EArgs (args : List String) : Option String × Bool :=
  let rec go (args : List String) (filter : Option String) (listMode : Bool)
      : Option String × Bool :=
    match args with
    | [] => (filter, listMode)
    | "--filter" :: v :: rest => go rest (some v) listMode
    | "--list" :: rest => go rest filter true
    | _ :: rest => go rest filter listMode
  go args none false

/-- Main entry point: parse args, run filtered or all suites -/
def e2eMain (suites : List TestSuite) (args : List String) : IO UInt32 := do
  let (filter, listMode) := parseE2EArgs args
  if listMode then
    IO.println "Available test suites:"
    for s in suites do
      IO.println s!"  {s.name} ({s.tests.length} tests)"
    return 0
  runAll suites filter

end FlareOperator.E2E
