/-
  E2E/Tests/WebhookTls.lean — the node guard's TLS from the operator pod
  (chart nodeGuard.tls.mode=operator), on a real `helm install`.

  Why: with the default mode (helm) the chart generates a CA on every render.
  Under ArgoCD (re-rendering on every refresh) the app never synced and each
  sync rotated the CA: the API server trusted the new caBundle at once while
  socat still served the old certificate for up to a minute, and with
  failurePolicy Fail every guarded delete, eviction and StatefulSet update of
  the namespace was refused. In operator mode the chart renders neither the
  Secret nor caBundle; the webhook-cert container in the operator pod makes
  <op>-webhook-tls-operator once and keeps every webhook's caBundle equal to
  its ca.crt.

  Checked here (W1):
  - the Secret exists and every webhook's caBundle equals its ca.crt; the
    chart's release carries no caBundle and no <op>-webhook-tls Secret;
  - the guard answers (a server-side dry run of a force delete of a data pod
    is refused by the guard, not by a TLS failure);
  - `helm upgrade --reuse-values` (a re-render) leaves the Secret and every
    caBundle as they were, and the guard still answers;
  - deleting the Secret (rotation) brings it back with a new CA, every
    caBundle follows within 60 s, and the guard answers again;
  - `helm upgrade` to mode=secret with a CA and certificate made here: the
    caBundle is the given one and the guard answers.
  certManager mode is checked by the chart render test only
  (scripts/tests/test_helm_webhook_tls.py): no cert-manager runs in kind.
-/
import FlareOperator.E2E.Framework
import FlareOperator.E2E.Helpers
import FlareOperator.E2E.Setup
import FlareOperator.E2E.NodeOpsHarness
import FlareOperator.E2E.LoadWriter
import FlareOperator.Kubectl

namespace FlareOperator.E2E.Tests.WebhookTls

open FlareOperator.E2E
open FlareOperator.E2E.Helpers
open FlareOperator.E2E.Setup
open FlareOperator.E2E.NodeOps
open FlareOperator.Kubectl

/-- 1 partition x 2 replicas on tmpfs, the multi-node kind (the chart's
    hostnameSpread=hard needs a worker per pod), the chart's own release with
    the node guard on. -/
def cfg : ClusterConfig :=
  { name := "node-wtls", «namespace» := "flare-node-wtls", partitions := 1, replicas := 2,
    debugPod := "debug-node-wtls", storageBackend := "rocksdb", useTmpfs := true, usePvc := false,
    drainSeconds := 60, pdbMaxUnavailable := some 1, multiNode := true,
    operatorName := "flare-operator-wtls", nodeGuard := true }

private def ns : String := cfg.«namespace»
private def opSecret : String := s!"{cfg.operatorName}-webhook-tls-operator"
private def helmSecret : String := s!"{cfg.operatorName}-webhook-tls"
private def userSecret : String := "e2e-webhook-tls"
private def webhookConfig : String := s!"{cfg.operatorName}-node-guard-{ns}"
/-- a data pod (master or replica once the cluster is up) -/
private def dataPod : String := s!"{cfg.name}-nodes-0"

/-- The operator-mode Secret: (uid, ca.crt, tls.crt), base64 as stored. -/
private def opSecretData : IO (Option (String × String × String)) := do
  match ← kubectl ["get", "secret", opSecret, "-n", ns, "-o", "jsonpath={.metadata.uid}|{.data.ca\\.crt}|{.data.tls\\.crt}"] with
  | .ok o => match o.trim.splitOn "|" with
    | [u, ca, crt] => return if u.isEmpty || ca.isEmpty || crt.isEmpty then none else some (u, ca, crt)
    | _ => return none
  | .error _ => return none

/-- Every webhook's (name, caBundle); `none` if the configuration is unreadable. -/
private def bundles : IO (Option (List (String × String))) := do
  match ← kubectl ["get", "validatingwebhookconfiguration", webhookConfig, "-o",
      "jsonpath={range .webhooks[*]}{.name}={.clientConfig.caBundle}{\"\\n\"}{end}"] with
  | .ok o =>
    return some ((o.splitOn "\n").filterMap fun l => match l.trim.splitOn "=" with
      | n :: rest => if n.isEmpty then none else some (n, String.intercalate "=" rest)
      | [] => none)
  | .error _ => return none

/-- All three webhooks trust exactly `ca`. -/
private def allBundlesAre (ca : String) : IO Bool := do
  match ← bundles with
  | some bs => return bs.length == 3 && bs.all (·.2 == ca)
  | none => return false

private def bundlesText : IO String := do
  match ← bundles with
  | some bs => return String.intercalate ", " (bs.map fun (n, b) => s!"{n}={if b.isEmpty then "(none)" else b.takeRight 24}")
  | none => return "unreadable"

/-- The guard answers: a server-side dry run of a force delete of a data pod
    is refused with the guard's own message ("flare: ..."). A TLS failure
    reads `failed calling webhook`; an accepted dry run means the guard did
    not judge it. Nothing is deleted either way (dry run). -/
private def guardOnce : IO (Except String String) := do
  match ← kubectlLong 60 ["delete", "pod", dataPod, "-n", ns, "--grace-period=0", "--force", "--wait=false", "--dry-run=server"] with
  | .ok o => return .error s!"the dry-run force delete was ACCEPTED: {o.trim.take 200}"
  | .error e =>
    if containsSubstr e "flare: " && !containsSubstr e "failed calling webhook" then return .ok (e.trim.take 200)
    else return .error (e.trim.take 400)

/-- Wait until the guard answers; the last answer either way. -/
private def guardAnswers (what : String) (secs : Nat) : IO (Bool × String) := do
  let last ← IO.mkRef ""
  let ok ← waitForCondition s!"the node guard answers ({what})" secs do
    match ← guardOnce with
    | .ok m => last.set m; return true
    | .error e => last.set e; return false
  return (ok, ← last.get)

/-- A CA and a serving certificate for the webhook Service, made with openssl
    on the runner, as the user of mode=secret would; the Secret is created
    and the CA returned (base64 of the PEM). -/
private def makeUserSecret : IO (Except String String) := do
  let svc := s!"{cfg.operatorName}-webhook"
  let dir := s!"/tmp/flare-wtls-{ns}"
  let script := s!"set -e; rm -rf {dir}; mkdir -p {dir}; cd {dir}; " ++
    "openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=flare-e2e-user-ca -keyout ca.key -out ca.crt 2>>err.txt; " ++
    "openssl req -newkey rsa:2048 -nodes -subj /CN=flare-node-guard -keyout tls.key -out tls.csr 2>>err.txt; " ++
    s!"printf 'subjectAltName=DNS:{svc}.{ns}.svc,DNS:{svc}.{ns}.svc.cluster.local\\n' > ext.cnf; " ++
    "openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile ext.cnf -out tls.crt 2>>err.txt; " ++
    s!"kubectl -n {ns} create secret tls {userSecret} --cert tls.crt --key tls.key >/dev/null; " ++
    "base64 < ca.crt | tr -d '\\n'"
  let out ← IO.Process.output { cmd := "sh", args := #["-c", script] }
  if out.exitCode == 0 && !out.stdout.trim.isEmpty then return .ok out.stdout.trim
  let err ← try IO.FS.readFile s!"{dir}/err.txt" catch _ => pure ""
  return .error s!"exit {out.exitCode}: {out.stderr.trim.take 300} {err.trim.take 300}"

/-- W1: mode=operator end to end, then the switch to mode=secret. -/
def operatorModeTest : IO TestResult := do
  let mut fails : List String := []
  -- 1. the cluster is up and the guard answers through the operator's certificate
  let up ← waitForCondition s!"{cfg.name}-nodes has 2 ready pods" 600 do
    match ← kubectlGetJsonpath "statefulset" s!"{cfg.name}-nodes" ns "{.status.readyReplicas}" with
    | .ok v => return (v.trim.toNat?.getD 0) >= 2
    | .error _ => return false
  if !up then return .fail "PRECONDITION NOT MET: the flared pods did not become ready"
  let made ← waitForCondition s!"{opSecret} exists" 120 (return (← opSecretData).isSome)
  let some (uid0, ca0, crt0) ← opSecretData
    | return .fail s!"the operator-mode Secret {opSecret} was not created within 120 s (made={made})"
  if !(← waitForCondition "every webhook's caBundle equals the Secret's ca.crt" 60 (allBundlesAre ca0)) then
    return .fail s!"the caBundles did not follow {opSecret}'s ca.crt within 60 s: {← bundlesText}"
  match ← kubectl ["get", "secret", helmSecret, "-n", ns, "-o", "name"] with
  | .ok o => fails := fails ++ [s!"the helm-mode Secret exists in operator mode: {o.trim}"]
  | .error _ => pure ()
  match ← helmCmd ["get", "manifest", helmRelease cfg, "--namespace", ns] 60 with
  | .ok m =>
    if containsSubstr m "caBundle" then fails := fails ++ ["the release's manifest carries a caBundle in operator mode"]
  | .error e => fails := fails ++ [s!"helm get manifest: {e.take 200}"]
  let (g1, m1) ← guardAnswers "operator mode, first certificate" 600
  IO.eprintln s!"# W1 guard (first certificate): {g1} {m1}"
  if !g1 then return .fail s!"the node guard did not answer with the operator's certificate: {m1}"
  -- 2. a re-render changes nothing
  let chart ← helmChartDir
  match ← helmCmd ["upgrade", helmRelease cfg, chart, "--namespace", ns, "--reuse-values"] 300 with
  | .error e => return .fail s!"helm upgrade --reuse-values failed: {e.take 300}"
  | .ok _ => pure ()
  let _ ← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" ns 300
  -- three passes of the container's loop (10 s each)
  IO.sleep 35000
  match ← opSecretData with
  | some (u, ca, crt) =>
    if u != uid0 || ca != ca0 || crt != crt0 then
      fails := fails ++ [s!"the re-render changed {opSecret} (uid {uid0} -> {u}, ca same={ca == ca0}, crt same={crt == crt0})"]
  | none => fails := fails ++ [s!"{opSecret} is gone after the re-render"]
  if !(← allBundlesAre ca0) then
    fails := fails ++ [s!"the re-render changed a caBundle: {← bundlesText}"]
  let (g2, m2) ← guardAnswers "after a re-render" 30
  IO.eprintln s!"# W1 guard (after helm upgrade --reuse-values): {g2} {m2}"
  if !g2 then fails := fails ++ [s!"the node guard did not answer after the re-render: {m2}"]
  -- 3. rotation: delete the Secret
  match ← kubectl ["delete", "secret", opSecret, "-n", ns] with
  | .error e => return .fail s!"could not delete {opSecret}: {e.take 200}"
  | .ok _ => pure ()
  let rotated ← waitForCondition s!"{opSecret} recreated with a new CA and every caBundle on it" 60 do
    match ← opSecretData with
    | some (u, ca, _) => if u != uid0 && ca != ca0 then allBundlesAre ca else return false
    | none => return false
  if !rotated then
    return .fail s!"after deleting {opSecret}: not recreated with a new CA and followed by every caBundle within 60 s ({← bundlesText})"
  -- socat reloads when the kubelet refreshes the mounted Secret (about a minute)
  let (g3, m3) ← guardAnswers "after the rotation" 240
  IO.eprintln s!"# W1 guard (after rotation): {g3} {m3}"
  if !g3 then fails := fails ++ [s!"the node guard did not answer within 240 s of the rotation: {m3}"]
  -- 4. switch to mode=secret with a user's Secret
  match ← makeUserSecret with
  | .error e => return .fail s!"PRECONDITION NOT MET: the user's certificate: {e}"
  | .ok userCa =>
    match ← helmCmd ["upgrade", helmRelease cfg, chart, "--namespace", ns, "--reuse-values",
        "--set", "nodeGuard.tls.mode=secret", "--set", s!"nodeGuard.tls.secretName={userSecret}",
        "--set", s!"nodeGuard.tls.caBundle={userCa}"] 300 with
    | .error e => return .fail s!"helm upgrade to mode=secret failed: {e.take 300}"
    | .ok _ => pure ()
    if !(← kubectlRolloutStatus s!"deployment/{cfg.operatorName}" ns 300) then
      fails := fails ++ ["the operator did not roll out in mode=secret"]
    if !(← waitForCondition "every caBundle is the user's CA" 60 (allBundlesAre userCa)) then
      fails := fails ++ [s!"mode=secret: the caBundles are not the given CA: {← bundlesText}"]
    let (g4, m4) ← guardAnswers "mode=secret" 300
    IO.eprintln s!"# W1 guard (mode=secret): {g4} {m4}"
    if !g4 then fails := fails ++ [s!"the node guard did not answer in mode=secret: {m4}"]
    -- the old pod's webhook-cert container lost its patch right with the
    -- mode: nothing puts the operator's CA back
    IO.sleep 20000
    if !(← allBundlesAre userCa) then
      fails := fails ++ [s!"mode=secret: a caBundle changed away from the given CA after the switch: {← bundlesText}"]
  if fails.isEmpty then return .pass else return .fail (String.intercalate "; " fails)

def suite : TestSuite :=
  { name := "node-ops-webhook-tls"
    setup := do
      deployHelmCluster cfg (← helmChartDir) ["nodeGuard.tls.mode=operator"]
    teardown := do
      cleanupHelmCluster cfg
      for s in [opSecret, userSecret] do kubectlDelete "secret" s ns
      cleanupCluster cfg
    onFailure := dumpClusterDiagnostics ns s!"app={cfg.operatorName}"
    tests := [{ name := "W1: nodeGuard.tls.mode=operator: Secret + caBundle kept by the operator pod, stable over a re-render, rotation by delete, then mode=secret", run := operatorModeTest }] }

end FlareOperator.E2E.Tests.WebhookTls
