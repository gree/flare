/-
  Operator/Parallel.lean - concurrent per-node reads, and a per-pass read
  cache (flare-operator-slow-reconcile).

  A reconcile pass reads each node (`kubectl get pod`, a stats query). Done
  one node after the other, a pass pays the SUM of the node latencies; under
  write load (mon-prod, 2.5 s a read) that was 12 s for one gate decision, and
  the gate was decided again at every commit of the pass (5 times).

  `parMapIO` runs the reads of one batch at once. Each read is a `kubectl`
  call already bounded by `Kubectl.kubectl`'s own wall (30 s + 5 s kill), so
  the batch takes at most the slowest read, and a `chunk` caps how many run at
  the same time. `PassCache` remembers what one pass has read so a second
  decision of the same pass reuses it.
-/

namespace FlareOperator.Parallel

/-- Wait for every task, then return the results in order; the first error is
    raised only after all the tasks have finished (none is left running). -/
private def awaitAll {β : Type} (tasks : List (Task (Except IO.Error β))) : IO (List β) := do
  let mut out : Array β := #[]
  let mut err : Option IO.Error := none
  for t in tasks do
    match ← IO.wait t with
    | .ok v => out := out.push v
    | .error e => if err.isNone then err := some e
  match err with
  | some e => throw e
  | none => pure out.toList

/-- `xs.mapM f` with at most `chunk` calls of `f` running at the same time.
    Results are in the order of `xs`. Each call runs on its own thread, so a
    blocking subprocess read does not occupy the shared task pool. -/
def parMapIO {α β : Type} (xs : List α) (f : α → IO β) (chunk : Nat := 16) : IO (List β) := do
  let chunk := max chunk 1
  let mut out : Array β := #[]
  let mut rest := xs
  while !rest.isEmpty do
    let batch := rest.take chunk
    rest := rest.drop chunk
    let tasks ← batch.mapM fun x => IO.asTask (prio := .dedicated) (f x)
    out := out ++ (← awaitAll tasks).toArray
  pure out.toList

/-- What one pass has read, per key. Cleared at the start of every pass. -/
abbrev PassCache (κ β : Type) := IO.Ref (List (κ × β))

/-- The values of `keys` (in order): a key already read this pass is answered
    from the cache; the others are read now, together, and remembered. A
    reading is one observation of the pass — the caller drops a key
    (`forget`) when it has itself changed what the read would answer. -/
def readOnce {κ β : Type} [BEq κ] (cache : PassCache κ β) (keys : List κ)
    (read : κ → IO β) (chunk : Nat := 16) : IO (List (κ × β)) := do
  let have0 ← cache.get
  let missing := (keys.filter fun k => !(have0.any (·.1 == k))).eraseDups
  if !missing.isEmpty then
    let got ← parMapIO missing read chunk
    cache.modify fun l => l ++ (missing.zip got)
  let now ← cache.get
  pure (keys.filterMap fun k => (now.find? (·.1 == k)).map fun kv => (k, kv.2))

/-- Start of a pass: nothing has been read yet. -/
def PassCache.reset {κ β : Type} (cache : PassCache κ β) : IO Unit := cache.set []

/-- Drop one key: the next `readOnce` reads it again. -/
def PassCache.forget {κ β : Type} [BEq κ] (cache : PassCache κ β) (k : κ) : IO Unit :=
  cache.modify (·.filter (·.1 != k))

end FlareOperator.Parallel
