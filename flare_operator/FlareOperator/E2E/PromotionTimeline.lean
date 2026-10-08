/-
  copy-identity 11 (review 2026-10-08, round 2): was a RESTARTED node
  promoted on its NEW process's own fresh evidence? Pure, unit tested.

  Inputs are logs taken WITH real timestamps (`kubectl logs --timestamps`):
  * the operator's log (PROMOTION EVIDENCE lines carry each candidate's
    class and the flared boot id it was read from: `<key>=<class> [boot <id>]`);
  * the CURRENT flared container's log only (never `--previous`: an old
    process's lines are not evidence about the new one).
  A line without a valid RFC 3339 timestamp is ignored, never accepted.
-/
namespace FlareOperator.E2E.PromotionTimeline

private def allDigits (s : String) : Bool := !s.isEmpty && s.all Char.isDigit

/-- `YYYY-MM-DDTHH:MM:SS[.frac]Z rest` → (timestamp normalised to 9
    fractional digits, rest). `none` when the line does not start with one. -/
def parseTs (line : String) : Option (String × String) :=
  let l := (line.replace "\r" "").trim
  match l.splitOn " " with
  | ts :: rest =>
    if ts.length < 20 || !ts.endsWith "Z" then none else
    let body := ts.dropRight 1
    let dt := body.take 19
    let ok := dt.length == 19 && allDigits (dt.take 4) && dt.get ⟨4⟩ == '-' && allDigits ((dt.drop 5).take 2)
      && dt.get ⟨7⟩ == '-' && allDigits ((dt.drop 8).take 2) && dt.get ⟨10⟩ == 'T'
      && allDigits ((dt.drop 11).take 2) && dt.get ⟨13⟩ == ':' && allDigits ((dt.drop 14).take 2)
      && dt.get ⟨16⟩ == ':' && allDigits ((dt.drop 17).take 2)
    if !ok then none else
    let frac := body.drop 19
    let fracDigits := if frac.isEmpty then some "" else if frac.startsWith "." && allDigits (frac.drop 1) then some (frac.drop 1) else none
    match fracDigits with
    | none => none
    | some f =>
      if f.length > 9 then none
      else some (dt ++ "." ++ f ++ String.mk (List.replicate (9 - f.length) '0'), String.intercalate " " rest)
  | [] => none

/-- The class and boot id recorded for `key` in one PROMOTION EVIDENCE line. -/
def evidenceFor (rest key : String) : Option (String × String) :=
  match rest.splitOn s!"{key}=" with
  | _ :: after :: _ =>
    match after.splitOn " [boot " with
    | cls :: b :: _ => some (cls, (b.splitOn "]").head?.getD "")
    | _ => none
  | _ => none

/-- `.ok summary` only when: a timestamped commit of `key`; the last
    timestamped PROMOTION EVIDENCE reading of it at or before that commit
    says eligible and was read from boot `bootNow`; and the current
    process's activation and read-source binding are both logged, with
    timestamps, at or before that reading. -/
def judge (opLog flaredCurrentLog key bootNow : String) : Except String String := do
  let op := (opLog.splitOn "\n").filterMap parseTs
  let fl := (flaredCurrentLog.splitOn "\n").filterMap parseTs
  let some (commitTs, _) := op.find? fun (_, r) => (r.splitOn "PROMOTION committed").length > 1 && (r.splitOn key).length > 1
    | throw "no timestamped PROMOTION committed line for it"
  let readings := op.filterMap fun (t, r) =>
    if (r.splitOn "PROMOTION EVIDENCE").length > 1 && decide (t ≤ commitTs) then (evidenceFor r key).map (t, ·) else none
  let some (readTs, (cls, boot)) := readings.getLast?
    | throw s!"no timestamped reading of it at or before the commit ({commitTs})"
  if !cls.startsWith "eligible" then throw s!"the reading that stood ({readTs}) was {cls}, not eligible"
  if boot != bootNow then throw s!"the reading that stood was of boot {boot}, the promoted process is boot {bootNow}"
  let firstAt := fun (needle : String) => (fl.find? fun (_, r) => (r.splitOn needle).length > 1).map (·.1)
  let some act := firstAt "node activated" | throw "the current process logged no timestamped activation"
  let some bound := firstAt "read source BOUND" | throw "the current process logged no timestamped read-source binding"
  if !(decide (act ≤ readTs) && decide (bound ≤ readTs)) then
    throw s!"the reading ({readTs}) predates the current process's activation ({act}) or binding ({bound})"
  return s!"read {readTs} (eligible, boot {boot}) after activation {act} and binding {bound}; committed {commitTs}"

end FlareOperator.E2E.PromotionTimeline
