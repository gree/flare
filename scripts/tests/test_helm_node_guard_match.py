"""Render checks of the node guard's matchConditions, no cluster: only the
release's own flared pods, their evictions and its StatefulSet reach the
webhook, so an operator that does not answer does not hold the other pods
of the namespace."""
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


def webhooks(text):
    vwcs = [d for d in yaml.safe_load_all(text) if d and d["kind"] == "ValidatingWebhookConfiguration"]
    if len(vwcs) != 1:
        raise AssertionError(f"{len(vwcs)} ValidatingWebhookConfiguration rendered")
    return {w["name"]: w for w in vwcs[0]["webhooks"]}


@unittest.skipUnless(shutil.which("helm") and yaml, "helm and PyYAML are required")
class NodeGuardMatchConditionsTest(unittest.TestCase):
    def ok(self, *settings):
        r = render(*settings)
        self.assertEqual(r.returncode, 0, r.stderr)
        return webhooks(r.stdout)

    def test_each_webhook_matches_only_this_clusters_objects(self):
        ws = self.ok("clusterName=mon", "cluster.name=mon")
        self.assertEqual(ws["pods.node-guard.flare.gree.net"]["matchConditions"], [{
            "name": "flared-pod-of-this-cluster",
            "expression": 'oldObject != null && has(oldObject.spec) && has(oldObject.spec.subdomain) && oldObject.spec.subdomain == "mon-nodes"',
        }])
        self.assertEqual(ws["evictions.node-guard.flare.gree.net"]["matchConditions"], [{
            "name": "flared-pod-of-this-cluster",
            "expression": 'request.name.startsWith("mon-nodes-")',
        }])
        self.assertEqual(ws["statefulsets.node-guard.flare.gree.net"]["matchConditions"], [{
            "name": "flared-statefulset-of-this-cluster",
            "expression": 'request.name == "mon-nodes"',
        }])
        # unchanged: still fail closed, still the whole namespace's rules
        for w in ws.values():
            self.assertEqual(w["failurePolicy"], "Fail")
            self.assertEqual(w["namespaceSelector"], {"matchLabels": {"kubernetes.io/metadata.name": "ns"}})

    def test_the_default_cluster_name_is_used_as_the_operator_uses_it(self):
        # clusterName defaults to "default" and reaches the operator as
        # --cluster-name: the conditions name the same cluster
        ws = self.ok()
        self.assertIn('"default-nodes"', ws["pods.node-guard.flare.gree.net"]["matchConditions"][0]["expression"])

    def test_no_cluster_name_keeps_the_whole_namespace(self):
        # the operator then discovers its FlareCluster: the chart cannot name
        # it, so every pod/eviction/StatefulSet reaches the webhook as before
        ws = self.ok("clusterName=")
        for w in ws.values():
            self.assertNotIn("matchConditions", w)


if __name__ == "__main__":
    unittest.main()
