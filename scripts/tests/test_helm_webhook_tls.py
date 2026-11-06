"""Render checks of the node guard's TLS modes (nodeGuard.tls.mode), no cluster."""
import pathlib
import shutil
import subprocess
import unittest

try:
    import yaml  # PyYAML: in the GitHub Ubuntu runner image (python3-yaml)
except ImportError:  # pragma: no cover
    yaml = None

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHART = str(ROOT / "helm/flare-operator")


def render(*settings):
    args = ["helm", "template", "rel", CHART, "--set", "namespace=ns"]
    for setting in settings:
        args.extend(["--set", setting])
    return subprocess.run(args, text=True, capture_output=True)


def docs(text):
    return [d for d in yaml.safe_load_all(text) if d]


def one(ds, kind, name=None):
    found = [d for d in ds if d["kind"] == kind and (name is None or d["metadata"]["name"] == name)]
    if len(found) != 1:
        raise AssertionError(f"{len(found)} {kind} {name or ''} rendered")
    return found[0]


def pod_spec(ds):
    return one(ds, "Deployment")["spec"]["template"]["spec"]


@unittest.skipUnless(shutil.which("helm") and yaml, "helm and PyYAML are required")
class WebhookTlsModeTest(unittest.TestCase):
    def ok(self, *settings):
        r = render(*settings)
        self.assertEqual(r.returncode, 0, r.stderr)
        return docs(r.stdout)

    def test_helm_mode_is_the_default(self):
        ds = self.ok()
        sec = one(ds, "Secret", "rel-flare-operator-webhook-tls")
        self.assertEqual(sorted(sec["data"]), ["tls.crt", "tls.key"])
        vwc = one(ds, "ValidatingWebhookConfiguration")
        bundles = {w["clientConfig"].get("caBundle") for w in vwc["webhooks"]}
        self.assertEqual(len(bundles), 1)
        self.assertTrue(next(iter(bundles)))
        spec = pod_spec(ds)
        self.assertEqual([c["name"] for c in spec["containers"]], ["flare-operator", "webhook-tls"])
        self.assertEqual(spec["volumes"], [{"name": "webhook-tls", "secret": {"secretName": "rel-flare-operator-webhook-tls"}}])
        # no webhook-cert Role in this mode; only the handover-fence receipt
        # key and the (unbound) break-glass Role
        self.assertEqual(sorted(d["metadata"]["name"] for d in ds if d["kind"] == "Role"),
                         ["rel-flare-operator-handover-fence", "rel-flare-operator-receipt-key"])
        mwc = one(ds, "MutatingWebhookConfiguration", "rel-flare-operator-handover-fence-ns")
        self.assertEqual({w["clientConfig"].get("caBundle") for w in mwc["webhooks"]}, bundles)

    def test_handover_fence_webhook_and_rbac(self):
        ds = self.ok()
        mwc = one(ds, "MutatingWebhookConfiguration", "rel-flare-operator-handover-fence-ns")
        [w] = mwc["webhooks"]
        # never blocks a FlareCluster update without the operator; writes nothing
        self.assertEqual(w["failurePolicy"], "Ignore")
        self.assertEqual(w["sideEffects"], "None")
        self.assertEqual(w["rules"], [{"apiGroups": ["flare.gree.net"], "apiVersions": ["*"], "operations": ["UPDATE"],
                                       "resources": ["flareclusters"], "scope": "Namespaced"}])
        self.assertEqual(w["clientConfig"]["service"]["path"], "/flareclusters")
        bg = one(ds, "Role", "rel-flare-operator-handover-fence")
        self.assertEqual(bg["rules"], [{"apiGroups": ["flare.gree.net"], "resources": ["flareclusters/handover-fence"],
                                        "verbs": ["break-glass"]}])
        # unbound by default (addendum 9)
        self.assertFalse(any(d["kind"] == "RoleBinding" and d["roleRef"]["name"] == "rel-flare-operator-handover-fence" for d in ds))
        key = one(ds, "Role", "rel-flare-operator-receipt-key")
        self.assertIn({"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["rel-flare-operator-receipt-key"],
                       "verbs": ["get"]}, key["rules"])
        self.assertEqual(one(ds, "RoleBinding", "rel-flare-operator-receipt-key")["roleRef"]["name"], "rel-flare-operator-receipt-key")
        self.assertIn({"apiGroups": ["authorization.k8s.io"], "resources": ["subjectaccessreviews"], "verbs": ["create"]},
                      one(ds, "ClusterRole")["rules"])
        env = {e["name"]: e.get("value") for e in pod_spec(ds)["containers"][0]["env"]}
        self.assertEqual(env["FLARE_RECEIPT_KEY_SECRET"], "rel-flare-operator-receipt-key")

    def test_operator_mode_renders_no_secret_and_no_ca_bundle(self):
        ds = self.ok("nodeGuard.tls.mode=operator")
        self.assertEqual([d for d in ds if d["kind"] == "Secret"], [])
        vwc = one(ds, "ValidatingWebhookConfiguration")
        self.assertEqual(len(vwc["webhooks"]), 3)
        for w in vwc["webhooks"]:
            self.assertNotIn("caBundle", w["clientConfig"])
        spec = pod_spec(ds)
        cert = [c for c in spec["containers"] if c["name"] == "webhook-cert"]
        self.assertEqual(len(cert), 1)
        self.assertEqual(cert[0]["image"], one(ds, "Deployment")["spec"]["template"]["spec"]["containers"][0]["image"])
        env = {e["name"]: e.get("value") for e in cert[0]["env"]}
        self.assertEqual(env["SECRET"], "rel-flare-operator-webhook-tls-operator")
        self.assertEqual(env["WEBHOOK_CONFIG"], "rel-flare-operator-node-guard-ns")
        self.assertEqual(env["FENCE_WEBHOOK_CONFIG"], "rel-flare-operator-handover-fence-ns")
        for w in one(ds, "MutatingWebhookConfiguration")["webhooks"]:
            self.assertNotIn("caBundle", w["clientConfig"])
        self.assertIn("--field-manager=flare-webhook-cert", cert[0]["args"][0])
        self.assertIn("resources", cert[0])
        vol = [v for v in spec["volumes"] if v["name"] == "webhook-tls"][0]
        self.assertEqual(vol["secret"], {"secretName": "rel-flare-operator-webhook-tls-operator", "optional": True})
        role = one(ds, "Role", "rel-flare-operator-webhook-cert")
        self.assertIn({"apiGroups": [""], "resources": ["secrets"],
                       "resourceNames": ["rel-flare-operator-webhook-tls-operator"], "verbs": ["get"]}, role["rules"])
        self.assertEqual(one(ds, "RoleBinding", "rel-flare-operator-webhook-cert")["roleRef"]["name"], role["metadata"]["name"])
        cr = one(ds, "ClusterRole")
        self.assertIn({"apiGroups": ["admissionregistration.k8s.io"], "resources": ["validatingwebhookconfigurations"],
                       "resourceNames": ["rel-flare-operator-node-guard-ns"], "verbs": ["get", "patch"]}, cr["rules"])
        self.assertIn({"apiGroups": ["admissionregistration.k8s.io"], "resources": ["mutatingwebhookconfigurations"],
                       "resourceNames": ["rel-flare-operator-handover-fence-ns"], "verbs": ["get", "patch"]}, cr["rules"])
        self.assertFalse(any("secrets" in r["resources"] for r in cr["rules"]))

    def test_operator_mode_render_is_stable(self):
        # the point of the mode: a re-render (an ArgoCD refresh) is identical
        a = render("nodeGuard.tls.mode=operator")
        b = render("nodeGuard.tls.mode=operator")
        self.assertEqual(a.returncode, 0, a.stderr)
        self.assertEqual(a.stdout, b.stdout)

    def test_other_modes_have_no_webhook_rbac(self):
        for mode in ["helm", "certManager"]:
            ds = self.ok(f"nodeGuard.tls.mode={mode}")
            self.assertFalse(any("validatingwebhookconfigurations" in r["resources"] for r in one(ds, "ClusterRole")["rules"]), mode)
            self.assertFalse(any("mutatingwebhookconfigurations" in r["resources"] for r in one(ds, "ClusterRole")["rules"]), mode)

    def test_secret_mode(self):
        ds = self.ok("nodeGuard.tls.mode=secret", "nodeGuard.tls.secretName=mine", "nodeGuard.tls.caBundle=Q0E=")
        self.assertEqual([d for d in ds if d["kind"] == "Secret"], [])
        for w in one(ds, "ValidatingWebhookConfiguration")["webhooks"]:
            self.assertEqual(w["clientConfig"]["caBundle"], "Q0E=")
        vol = [v for v in pod_spec(ds)["volumes"] if v["name"] == "webhook-tls"][0]
        self.assertEqual(vol["secret"]["secretName"], "mine")

    def test_secret_mode_needs_both_values(self):
        for settings in [(), ("nodeGuard.tls.secretName=mine",), ("nodeGuard.tls.caBundle=Q0E=",)]:
            r = render("nodeGuard.tls.mode=secret", *settings)
            self.assertNotEqual(r.returncode, 0, settings)
            self.assertIn("nodeGuard.tls.mode=secret needs", r.stderr)

    def test_cert_manager_mode_self_signed(self):
        ds = self.ok("nodeGuard.tls.mode=certManager")
        self.assertEqual([d for d in ds if d["kind"] == "Secret"], [])
        cert = one(ds, "Certificate", "rel-flare-operator-node-guard")
        self.assertEqual(cert["spec"]["secretName"], "rel-flare-operator-webhook-tls")
        self.assertEqual(cert["spec"]["dnsNames"], ["rel-flare-operator-webhook.ns.svc",
                                                    "rel-flare-operator-webhook.ns.svc.cluster.local"])
        issuer = one(ds, "Issuer")
        self.assertEqual(cert["spec"]["issuerRef"], {"name": issuer["metadata"]["name"], "kind": "Issuer"})
        vwc = one(ds, "ValidatingWebhookConfiguration")
        self.assertEqual(vwc["metadata"]["annotations"]["cert-manager.io/inject-ca-from"], "ns/rel-flare-operator-node-guard")
        for w in vwc["webhooks"]:
            self.assertNotIn("caBundle", w["clientConfig"])

    def test_cert_manager_mode_issuer_ref(self):
        ds = self.ok("nodeGuard.tls.mode=certManager", "nodeGuard.tls.certManager.issuerRef.name=corp",
                     "nodeGuard.tls.certManager.issuerRef.kind=ClusterIssuer")
        self.assertEqual([d for d in ds if d["kind"] == "Issuer"], [])
        self.assertEqual(one(ds, "Certificate")["spec"]["issuerRef"], {"name": "corp", "kind": "ClusterIssuer"})

    def test_unknown_mode_fails(self):
        r = render("nodeGuard.tls.mode=Operator")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('nodeGuard.tls.mode "Operator" is not one of helm, operator, secret, certManager', r.stderr)


if __name__ == "__main__":
    unittest.main()
