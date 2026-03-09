/-
  Kubectl.lean - IO.Process kubectl bridge
  Following Gungnir/Main.lean subprocess pattern
-/

import FlareOperator.K8s.FlareCluster

namespace FlareOperator.Kubectl

open FlareOperator.K8s

/-- Simple substring search: find needle in haystack, return byte position. -/
private def findSubstring (haystack : String) (needle : String) : Option Nat :=
  let hLen := haystack.length
  let nLen := needle.length
  if nLen > hLen then none
  else
    let rec go (i : Nat) (fuel : Nat) : Option Nat :=
      match fuel with
      | 0 => none
      | fuel + 1 =>
        if i + nLen > hLen then none
        else if (haystack.drop i).startsWith needle then some i
        else go (i + 1) fuel
    go 0 (hLen + 1)

/-- Extract a natural number value from a JSON-like string for a given key. -/
private def extractJsonNat (json : String) (key : String) : Option Nat :=
  let needle := "\"" ++ key ++ "\":"
  match findSubstring json needle with
  | none => none
  | some pos =>
    let afterKey := json.drop (pos + needle.length)
    let trimmed := afterKey.trim
    -- Extract digits from the start of trimmed
    let digits := trimmed.takeWhile Char.isDigit
    digits.toNat?

/-- Run kubectl with given arguments and return stdout or error. -/
def kubectl (args : List String) : IO (Except String String) := do
  try
    let result ← IO.Process.output { cmd := "kubectl", args := args.toArray }
    if result.exitCode == 0 then
      return .ok result.stdout
    else
      return .error s!"kubectl failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"kubectl error: {e}"

/-- Get a FlareCluster CR by name and namespace. Returns a minimal view. -/
def getFlareCluster (name ns : String) : IO (Except String FlareClusterView) := do
  let result ← kubectl ["get", "flarecluster", name, "-n", ns, "-o", "json"]
  match result with
  | .error e => return .error e
  | .ok output =>
    let partitions := extractJsonNat output "partitions" |>.getD 1
    let replicas := extractJsonNat output "replicas" |>.getD 1
    return .ok {
      metadata := { name := some name, «namespace» := some ns }
      spec := { partitions := partitions, replicas := replicas }
    }

/-- List flared pods matching a label selector. Returns (podName, podIP, port). -/
def listFlaredPods (crName ns : String) : IO (List (String × String × Nat)) := do
  let result ← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
                         "-o", "jsonpath={range .items[*]}{.metadata.name} {.status.podIP} 12121{\"\\n\"}{end}"]
  match result with
  | .error _ => return []
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    return lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
      | [podName, ip, portStr] =>
        match portStr.trim.toNat? with
        | some port => some (podName, ip, port)
        | none => none
      | _ => none

/-- Patch a Service selector to point to a specific pod. -/
def patchServiceSelector (svcName ns podName : String) : IO (Except String Unit) := do
  let patch := s!"\{\"spec\":\{\"selector\":\{\"statefulset.kubernetes.io/pod-name\":\"{podName}\"}}}"
  let result ← kubectl ["patch", "svc", svcName, "-n", ns, "-p", patch]
  match result with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- List all FlareCluster CRs in a namespace. Returns (name, namespace). -/
def listFlareClusters (ns : String) : IO (Except String (List (String × String))) := do
  let result ← kubectl ["get", "flarecluster", "-n", ns,
                         "-o", "jsonpath={range .items[*]}{.metadata.name} {.metadata.namespace}{\"\\n\"}{end}"]
  match result with
  | .error e => return .error e
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    let pairs := lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
      | [crName, crNs] => some (crName.trim, crNs.trim)
      | _ => none
    return .ok pairs

end FlareOperator.Kubectl
