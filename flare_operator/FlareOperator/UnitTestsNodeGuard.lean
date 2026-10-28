/-
  UnitTestsNodeGuard.lean — checks of StateMachine/NodeGuard.lean and the
  review codec (K8s/Admission.lean), A0 stage 6b. Called from UnitTests.run.
-/
import FlareOperator.StateMachine.NodeGuard
import FlareOperator.K8s.Admission

namespace FlareOperator.UnitTestsNodeGuard

open FlareOperator.K8s
open FlareOperator.NodeGuard

private def has (h n : String) : Bool := (h.splitOn n).length > 1

private def node (name : String) (role : FlareRole) (st : FlareState) (part : Int) : FlareNode :=
  { serverName := name, serverPort := 12121, role := role, state := st, partition := part }

/-- m master, s slave (partition 0), p proxy. -/
private def st : FlareClusterState :=
  { nodeMap := [("m:12121", node "m" .Master .Active 0), ("s:12121", node "s" .Slave .Active 0),
                ("p:12121", node "p" .Proxy .Active (-1))],
    partitionMap := [(0, { master := some "m:12121", slaves := ["s:12121"] })] }

private def ready : List String := ["m:12121", "s:12121", "p:12121"]
private def op : String := "system:serviceaccount:ns:flare-operator"
private def user : String := "kubernetes-admin"

def results : List (String × Bool) := Id.run do
  let mut r : List (String × Bool) := []
  r := r ++ [("node guard: a graceful delete of a master with a caught-up replica is allowed (the handover moves it)",
              (podDelete st ready user op "m:12121" "u1" none none).allowed)]
  r := r ++ [("node guard: a force delete (grace 0) of the master is refused",
              !(podDelete st ready user op "m:12121" "u1" none (some 0)).allowed)]
  r := r ++ [("node guard: a force delete of a replica is refused too (no preStop)",
              !(podDelete st ready user op "s:12121" "u2" none (some 0)).allowed)]
  r := r ++ [("node guard: a force delete of a proxy is allowed (no data)",
              (podDelete st ready user op "p:12121" "u3" none (some 0)).allowed)]
  r := r ++ [("node guard: a pod not in the map is allowed", (podDelete st ready user op "x:12121" "u4" none (some 0)).allowed)]
  r := r ++ [("node guard: the master with its replica not Ready is refused (no successor)",
              !(podDelete st ["m:12121"] user op "m:12121" "u1" none none).allowed)]
  let rebuilding := st.addNode "s:12121" (node "s" .Slave .Prepare 0)
  r := r ++ [("node guard: the master with its replica still rebuilding (Prepare) is refused",
              !(podDelete rebuilding ready user op "m:12121" "u1" none none).allowed)]
  r := r ++ [("node guard: the override annotation with the pod's UID lets it through",
              (podDelete st ready user op "m:12121" "u1" (some "u1") (some 0)).allowed)]
  r := r ++ [("node guard: an override naming another UID does not",
              !(podDelete st ready user op "m:12121" "u1" (some "other") (some 0)).allowed)]
  r := r ++ [("node guard: the operator's own delete is allowed", (podDelete st ["m:12121"] op op "m:12121" "u1" none (some 0)).allowed)]
  r := r ++ [("node guard: Kubernetes controllers are allowed",
              (podDelete st [] "system:serviceaccount:kube-system:namespace-controller" op "m:12121" "u1" none (some 0)).allowed
                && (podDelete st [] "system:kube-controller-manager" op "m:12121" "u1" none none).allowed)]
  -- scale
  let keyOf := fun (i : Nat) => s!"n{i}:12121"
  let sts : FlareClusterState :=
    { nodeMap := [("n0:12121", node "n0" .Master .Active 0), ("n1:12121", node "n1" .Slave .Active 0),
                  ("n2:12121", node "n2" .Proxy .Active (-1)), ("n3:12121", node "n3" .Slave .Active 0)] }
  r := r ++ [("node guard: scaling up or unchanged is allowed", (scale sts user op 3 4 keyOf).allowed && (scale sts user op 3 3 keyOf).allowed)]
  r := r ++ [("node guard: removing a proxy ordinal is allowed", (scale { sts with nodeMap := sts.nodeMap.take 3 } user op 3 2 keyOf).allowed)]
  r := r ++ [("node guard: removing an ordinal that holds data is refused (4 -> 2 removes n2 proxy and n3 slave)",
              match scale sts user op 4 2 keyOf with | .deny why => has why "[3]" | _ => false)]
  r := r ++ [("node guard: the operator may scale down", (scale sts op op 4 1 keyOf).allowed)]
  -- codec
  let body := "{\"request\":{\"uid\":\"r1\",\"operation\":\"DELETE\",\"resource\":{\"group\":\"\",\"version\":\"v1\",\"resource\":\"pods\"},\"name\":\"n-0\",\"namespace\":\"ns\",\"userInfo\":{\"username\":\"kubernetes-admin\"},\"oldObject\":{\"metadata\":{\"name\":\"n-0\",\"uid\":\"u9\",\"annotations\":{\"flare.gree.net/delete-override\":\"u9\"}},\"spec\":{\"hostname\":\"n-0\",\"subdomain\":\"n\"}},\"options\":{\"gracePeriodSeconds\":0}}}"
  r := r ++ [("admission: a pod DELETE review is read (uid, user, pod uid, hostname, override, grace 0)",
              match FlareOperator.Admission.parseReview body with
              | .ok v => v.uid == "r1" && v.operation == "DELETE" && v.resource == "pods" && v.username == "kubernetes-admin"
                  && v.podUid == "u9" && v.podHostname == "n-0" && v.podSubdomain == "n"
                  && v.podAnnotation overrideAnnotation == some "u9" && v.gracePeriodSeconds == some 0
              | .error _ => false)]
  let scaleBody := "{\"request\":{\"uid\":\"r2\",\"operation\":\"UPDATE\",\"resource\":{\"group\":\"apps\",\"version\":\"v1\",\"resource\":\"statefulsets\"},\"subResource\":\"scale\",\"name\":\"c-nodes\",\"namespace\":\"ns\",\"object\":{\"spec\":{\"replicas\":1}},\"oldObject\":{\"spec\":{\"replicas\":2}}}}"
  r := r ++ [("admission: a statefulsets/scale review reads the new and old replicas",
              match FlareOperator.Admission.parseReview scaleBody with
              | .ok v => v.subResource == "scale" && v.replicas == (some 1, some 2)
              | .error _ => false)]
  r := r ++ [("admission: a refusal carries code 403 and the message; malformed input is refused",
              has (FlareOperator.Admission.reviewResponse "r1" false "no") "\"code\":403"
                && has (FlareOperator.Admission.malformedResponse "garbage" "x") "\"allowed\":false")]
  return r

end FlareOperator.UnitTestsNodeGuard
