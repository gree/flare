/-
  Operator/Parallel.lean - concurrent per-node reads for one decision
  (flare-operator-slow-reconcile).

  A reconcile pass reads each node (`kubectl get pod`, a stats query). Done
  one node after the other, a pass pays the SUM of the node latencies; under
  write load (mon-prod, 2.5 s a read) that was 12 s for one gate decision, and
  the gate was decided again at every commit of the pass (5 times).

  `parMapIO` runs the reads of one batch at once. Each read is a `kubectl`
  call already bounded by `Kubectl.kubectl`'s own wall (30 s + 5 s kill), so
  the batch takes at most the slowest read, and a `chunk` caps how many run at
  the same time. Nothing is cached across decisions: an observation that
  admits a new assignment must be read at that decision (a reconstruction can
  start between two gates of one pass), so `readFresh` reads every key again.
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

/-- The values of `keys` (in order), every key read NOW, together. Nothing is
    remembered: a caller that decides on the answer (admitting a new
    assignment, resuming a parked rebuild) shares one call between the nodes
    of THAT decision only, and reads again for the next decision. -/
def readFresh {κ β : Type} [BEq κ] (keys : List κ)
    (read : κ → IO β) (chunk : Nat := 16) : IO (List (κ × β)) := do
  let ks := keys.eraseDups
  let got ← parMapIO ks read chunk
  pure (ks.zip got)

end FlareOperator.Parallel
