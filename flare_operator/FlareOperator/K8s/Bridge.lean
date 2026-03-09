/-
  Bridge.lean - High-level K8s kubectl bridge

  Wraps the low-level kubectl subprocess calls from Kubectl.lean into
  typed, operator-specific operations. Each function issues exactly one
  kubectl call and returns a typed result.

  Functions:
  - getFlareClusterCRD: fetch CRD spec as FlareClusterView
  - listFlaredPods: list pods with PodInfo (name, ip, port, ready)
  - patchClientServiceSelector: point a Service at a specific pod
  - deletePod: force-delete a pod by name
  - updateFlaredConfigMap: update a ConfigMap with node-map data
-/

import FlareOperator.K8s.FlareCluster
import FlareOperator.Kubectl

namespace FlareOperator.K8s.Bridge

open FlareOperator.K8s
open FlareOperator.Kubectl

-- ===========================================================================
-- PodInfo: typed pod metadata returned by listFlaredPods
-- ===========================================================================

/-- Typed pod information returned from K8s API. -/
structure PodInfo where
  name : String
  ip : String
  port : Nat
  ready : Bool := true
  deriving Repr, BEq

/-- Convert a PodInfo to a node key (ip:port). -/
def PodInfo.toNodeKey (p : PodInfo) : String :=
  FlareClusterState.toNodeKey p.ip p.port

-- ===========================================================================
-- Bridge Functions
-- ===========================================================================

/-- Fetch the FlareCluster CRD spec from K8s API.
    Wraps Kubectl.getFlareCluster with error logging. -/
def getFlareClusterCRD (crName ns : String) : IO (Except String FlareClusterView) := do
  getFlareCluster crName ns

/-- List flared pods matching the cluster label selector.
    Returns typed PodInfo list instead of raw tuples.

    kubectl get pods -n <ns> -l app=flare,cluster=<crName>
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP} 12121 {.status.conditions[?(.type=="Ready")].status}{\n}{end}' -/
def listFlaredPods (crName ns : String) : IO (List PodInfo) := do
  let result ← kubectl ["get", "pods", "-n", ns, "-l", s!"app=flare,cluster={crName}",
                         "-o", "jsonpath={range .items[*]}{.metadata.name} {.status.podIP} 12121 {.status.conditions[?(.type==\"Ready\")].status}{\"\\n\"}{end}"]
  match result with
  | .error _ => return []
  | .ok output =>
    let lines := output.splitOn "\n" |>.filter (· != "")
    return lines.filterMap fun line =>
      let parts := line.splitOn " "
      match parts with
      | [podName, ip, portStr, readyStr] =>
        match portStr.trim.toNat? with
        | some port => some {
            name := podName.trim
            ip := ip.trim
            port := port
            ready := readyStr.trim == "True"
          }
        | none => none
      | [podName, ip, portStr] =>
        match portStr.trim.toNat? with
        | some port => some {
            name := podName.trim
            ip := ip.trim
            port := port
            ready := true
          }
        | none => none
      | _ => none

/-- Patch a K8s Service selector to route traffic to a specific pod.

    kubectl patch svc <svcName> -n <ns> -p '{"spec":{"selector":{"statefulset.kubernetes.io/pod-name":"<podName>"}}}' -/
def patchClientServiceSelector (svcName ns podName : String) : IO (Except String Unit) := do
  patchServiceSelector svcName ns podName

/-- Force-delete a pod by name.

    kubectl delete pod <podName> -n <ns> --grace-period=0 --force -/
def deletePod (podName ns : String) : IO (Except String Unit) := do
  let result ← kubectl ["delete", "pod", podName, "-n", ns,
                         "--grace-period=0", "--force"]
  match result with
  | .error e => return .error e
  | .ok _ => return .ok ()

/-- Update (or create) a ConfigMap with the current node-map data.
    Used to persist the operator's view of the cluster for observability.

    kubectl create configmap <name> -n <ns> --from-literal=nodeMap=<data> -o yaml --dry-run=client | kubectl apply -f - -/
def updateFlaredConfigMap (cmName ns : String) (nodeMapData : String) : IO (Except String Unit) := do
  -- Use kubectl apply with dry-run pipe pattern for idempotent create-or-update
  try
    let result ← IO.Process.output {
      cmd := "sh"
      args := #["-c",
        s!"kubectl create configmap {cmName} -n {ns} --from-literal=nodeMap='{nodeMapData}' -o yaml --dry-run=client | kubectl apply -f -"]
    }
    if result.exitCode == 0 then
      return .ok ()
    else
      return .error s!"configmap update failed (exit {result.exitCode}): {result.stderr}"
  catch e =>
    return .error s!"configmap update error: {e}"

-- ===========================================================================
-- Convenience: extract live node keys from PodInfo list
-- ===========================================================================

/-- Extract node keys (ip:port) from a list of ready pods. -/
def liveNodeKeys (pods : List PodInfo) : List String :=
  (pods.filter PodInfo.ready).map PodInfo.toNodeKey

end FlareOperator.K8s.Bridge
