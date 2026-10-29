/-
  UnitTestsNodeGuard.lean — checks of StateMachine/NodeGuard.lean and the
  review codec (K8s/Admission.lean), A0 stage 6b. Called from UnitTests.run.
-/
import FlareOperator.StateMachine.NodeGuard
import FlareOperator.K8s.Admission
import FlareOperator.StateMachine.Handover

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

/-- the replicas Main proved caught up (Ready, R3 eligible, no repair) -/
private def caughtUp : List String := ["s:12121"]
private def op : String := "system:serviceaccount:ns:flare-operator"
private def user : String := "kubernetes-admin"

private def pod (key uid : String) (grace : Option Nat := none) (ov : Option String := none)
    (nodeName : String := "w1") (terminating : Bool := false) : PodFacts :=
  { nodeKey := key, uid, overrideUid := ov, gracePeriod := grace, nodeName, terminating }

private def del (p : PodFacts) (cu : List String := caughtUp) (who : String := user) (init : Bool := true) : Verdict :=
  podDelete init st cu who op p

def results : List (String × Bool) := Id.run do
  let mut r : List (String × Bool) := []
  -- review of 9756855 (TOCTOU): the master is handed over BEFORE its delete
  r := r ++ [("node guard: a graceful delete of a master with a caught-up replica is refused and asks for the handover first",
              !(del (pod "m:12121" "u1")).allowed
                && requestsHandover true st caughtUp user op (pod "m:12121" "u1"))]
  let handedOver := (st.addNode "m:12121" (node "m" .Proxy .Active (-1))).addNode "s:12121" (node "s" .Master .Active 0)
  r := r ++ [("node guard: once handed over (the old master is a proxy) the retried delete is allowed and asks for nothing",
              (podDelete true handedOver caughtUp user op (pod "m:12121" "u1")).allowed
                && !requestsHandover true handedOver caughtUp user op (pod "m:12121" "u1"))]
  r := r ++ [("node guard (review of 7ae666c): a master running a flared from before the handover is refused unless legacyMasterSwitch accepts it, and asks for no handover",
              !(del { pod "m:12121" "u1" with predatesHandover := true }).allowed
                && !requestsHandover true st caughtUp user op { pod "m:12121" "u1" with predatesHandover := true })]
  r := r ++ [("node guard: with legacyMasterSwitch it is allowed with a caught-up replica (NOT loss-free), and still refused without one",
              (del { pod "m:12121" "u1" with predatesHandover := true, legacySwitchAllowed := true }).allowed
                && !(del { pod "m:12121" "u1" with predatesHandover := true, legacySwitchAllowed := true } []).allowed)]
  r := r ++ [("node guard (998dc30 G1): a pod whose handover is still completing is refused although the map already shows it as a proxy",
              !(podDelete true handedOver caughtUp user op { pod "m:12121" "u1" with handoverUnfinished := true }).allowed
                && (podDelete true handedOver caughtUp user op (pod "m:12121" "u1")).allowed)]
  -- review of 3dcfc5c: a ledger entry without oldUid (older / damaged JSON)
  -- holds every pod at its key; a known different UID (recreated) is not held
  let ledgerOf := fun (s : String) =>
    ((Lean.Json.parse s).toOption.bind Handover.Ledger.fromJson?).getD {}
  let noUid := ledgerOf "{\"entries\":[{\"partition\":0,\"oldMaster\":\"m:12121\",\"successor\":\"s:12121\",\"phase\":\"promoting\"}]}"
  let withUid := ledgerOf "{\"entries\":[{\"partition\":0,\"oldMaster\":\"m:12121\",\"successor\":\"s:12121\",\"phase\":\"promoting\",\"oldUid\":\"u0\"}]}"
  let doneNoUid := ledgerOf "{\"entries\":[{\"partition\":0,\"oldMaster\":\"m:12121\",\"successor\":\"s:12121\",\"phase\":\"done\"}]}"
  r := r ++ [("node guard (review of 3dcfc5c): a promoting ledger entry with no oldUid refuses the delete of the pod the map already shows as a proxy",
              noUid.entries.length == 1 && noUid.unfinishedFor "m:12121" "u1"
                && !(podDelete true handedOver caughtUp user op
                      { pod "m:12121" "u1" with handoverUnfinished := noUid.unfinishedFor "m:12121" "u1" }).allowed)]
  r := r ++ [("node guard (review of 3dcfc5c): an entry's known old UID holds that pod and a request without a UID, not a recreated pod with another UID; a done entry holds nothing",
              withUid.unfinishedFor "m:12121" "u0" && withUid.unfinishedFor "m:12121" ""
                && !withUid.unfinishedFor "m:12121" "u1"
                && (podDelete true handedOver caughtUp user op
                      { pod "m:12121" "u1" with handoverUnfinished := withUid.unfinishedFor "m:12121" "u1" }).allowed
                && !withUid.unfinishedFor "s:12121" "u0"
                && !doneNoUid.unfinishedFor "m:12121" "u1")]
  r := r ++ [("node guard: no handover is requested without a caught-up successor, before the first pass, for a force delete, an override, the operator or a terminating pod",
              !requestsHandover true st [] user op (pod "m:12121" "u1")
                && !requestsHandover false st caughtUp user op (pod "m:12121" "u1")
                && !requestsHandover true st caughtUp user op (pod "m:12121" "u1" (some 0))
                && !requestsHandover true st caughtUp user op (pod "m:12121" "u1" none (some "u1"))
                && !requestsHandover true st caughtUp op op (pod "m:12121" "u1")
                && !requestsHandover true st caughtUp user op (pod "m:12121" "u1" none none "w1" true)
                && !requestsHandover true st caughtUp user op (pod "s:12121" "u2"))]
  r := r ++ [("node guard: a force delete (grace 0) of the master is refused",
              !(del (pod "m:12121" "u1" (some 0))).allowed)]
  r := r ++ [("node guard: a force delete of a replica is refused too (no preStop)",
              !(del (pod "s:12121" "u2" (some 0))).allowed)]
  r := r ++ [("node guard: a force delete of a proxy is allowed (no data)",
              (del (pod "p:12121" "u3" (some 0))).allowed)]
  r := r ++ [("node guard: a pod not in the map is refused (unknown is not empty: it may hold data on its volume)",
              !(del (pod "x:12121" "u4")).allowed)]
  r := r ++ [("node guard: a pod not in the map is let through by its override",
              (del (pod "x:12121" "u4" (some 0) (some "u4"))).allowed)]
  r := r ++ [("node guard: before the operator's first full pass every data-pod delete is refused (the map may be the empty default)",
              !(podDelete false {} [] user op (pod "m:12121" "u1")).allowed
                && !(podDelete false st caughtUp user op (pod "s:12121" "u2")).allowed)]
  r := r ++ [("node guard: before the first pass the override and the operator still pass",
              (podDelete false {} [] user op (pod "m:12121" "u1" (some 0) (some "u1"))).allowed
                && (podDelete false {} [] op op (pod "m:12121" "u1" (some 0))).allowed)]
  r := r ++ [("node guard: the master with no caught-up replica is refused (Active Slave in the map is not enough)",
              !(del (pod "m:12121" "u1") []).allowed)]
  r := r ++ [("node guard: a caught-up key that is not an Active Slave of the partition does not count",
              !(del (pod "m:12121" "u1") ["p:12121"]).allowed)]
  let rebuilding := st.addNode "s:12121" (node "s" .Slave .Prepare 0)
  r := r ++ [("node guard: the master with its replica still rebuilding (Prepare) is refused",
              !(podDelete true rebuilding caughtUp user op (pod "m:12121" "u1")).allowed)]
  r := r ++ [("node guard: the override annotation with the pod's UID lets it through",
              (del (pod "m:12121" "u1" (some 0) (some "u1"))).allowed)]
  r := r ++ [("node guard: an override naming another UID does not",
              !(del (pod "m:12121" "u1" (some 0) (some "other"))).allowed)]
  r := r ++ [("node guard: the operator's own delete is allowed", (del (pod "m:12121" "u1" (some 0)) [] op).allowed)]
  r := r ++ [("node guard: the kubelet of the pod's node confirming a pod already terminating is allowed",
              (del (pod "m:12121" "u1" (some 0) none "worker-1" true) [] "system:node:worker-1").allowed)]
  r := r ++ [("node guard: the kubelet of ANOTHER node is not trusted",
              !(del (pod "m:12121" "u1" (some 0) none "worker-1" true) [] "system:node:worker-2").allowed)]
  r := r ++ [("node guard: the kubelet deleting a pod that is NOT terminating yet is judged like anyone",
              !(del (pod "m:12121" "u1" (some 0) none "worker-1" false) [] "system:node:worker-1").allowed)]
  r := r ++ [("node guard: Kubernetes controllers are allowed",
              (del (pod "m:12121" "u1" (some 0)) [] "system:serviceaccount:kube-system:namespace-controller").allowed
                && (del (pod "m:12121" "u1") [] "system:kube-controller-manager").allowed)]
  -- codec
  let body := "{\"request\":{\"uid\":\"r1\",\"operation\":\"DELETE\",\"resource\":{\"group\":\"\",\"version\":\"v1\",\"resource\":\"pods\"},\"name\":\"n-0\",\"namespace\":\"ns\",\"userInfo\":{\"username\":\"kubernetes-admin\"},\"oldObject\":{\"metadata\":{\"name\":\"n-0\",\"uid\":\"u9\",\"annotations\":{\"flare.gree.net/delete-override\":\"u9\"}},\"spec\":{\"hostname\":\"n-0\",\"subdomain\":\"n\",\"nodeName\":\"w7\"}},\"options\":{\"gracePeriodSeconds\":0}}}"
  r := r ++ [("admission: a pod DELETE review is read (uid, user, pod uid, hostname, override, grace 0)",
              match FlareOperator.Admission.parseReview body with
              | .ok v => v.uid == "r1" && v.operation == "DELETE" && v.resource == "pods" && v.username == "kubernetes-admin"
                  && v.podUid == "u9" && v.podHostname == "n-0" && v.podSubdomain == "n"
                  && v.podAnnotation overrideAnnotation == some "u9" && v.gracePeriodSeconds == some 0
                  && v.podNodeName == "w7" && !v.podTerminating
              | .error _ => false)]
  let scaleBody := "{\"request\":{\"uid\":\"r2\",\"operation\":\"UPDATE\",\"resource\":{\"group\":\"apps\",\"version\":\"v1\",\"resource\":\"statefulsets\"},\"subResource\":\"scale\",\"name\":\"c-nodes\",\"namespace\":\"ns\",\"object\":{\"spec\":{\"replicas\":1}},\"oldObject\":{\"spec\":{\"replicas\":2}}}}"
  let termBody := "{\"request\":{\"uid\":\"r3\",\"operation\":\"DELETE\",\"resource\":{\"resource\":\"pods\"},\"name\":\"n-0\",\"namespace\":\"ns\",\"oldObject\":{\"metadata\":{\"name\":\"n-0\",\"deletionTimestamp\":\"2026-10-29T00:00:00Z\"}}}}"
  r := r ++ [("admission: a pod with a deletionTimestamp reads as terminating",
              match FlareOperator.Admission.parseReview termBody with
              | .ok v => v.podTerminating
              | .error _ => false)]
  r := r ++ [("admission: a statefulsets/scale review reads the new and old replicas",
              match FlareOperator.Admission.parseReview scaleBody with
              | .ok v => v.subResource == "scale" && v.replicas == (some 1, some 2)
              | .error _ => false)]
  r := r ++ [("admission: a refusal carries code 403 and the message; malformed input is refused",
              has (FlareOperator.Admission.reviewResponse "r1" false "no") "\"code\":403"
                && has (FlareOperator.Admission.malformedResponse "garbage" "x") "\"allowed\":false")]
  return r

end FlareOperator.UnitTestsNodeGuard
