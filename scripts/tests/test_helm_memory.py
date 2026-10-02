"""Check startup memory configuration without a Kubernetes cluster."""
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("helm"), "helm is required")
class MemoryConfigTest(unittest.TestCase):
    def render(self, *settings):
        args = ["helm", "template", "memory-test", str(ROOT / "helm/flare-operator"),
                "--set", "cluster.enabled=true"]
        for setting in settings:
            args.extend(["--set", setting])
        return subprocess.check_output(args, text=True)

    def test_unset_preserves_defaults(self):
        text = self.render()
        self.assertNotIn("rocksdb-block-cache-size-mb =", text)
        self.assertNotIn("rocksdb-write-buffer-size-mb =", text)
        self.assertNotIn("rocksdb-max-write-buffer-number =", text)

    def test_topology_alerts_render_with_runbooks(self):
        text = self.render("monitoring.prometheusRule.enabled=true")
        for alert, metric in [
            ("FlareTopologyDeliveryLag", "flare_operator_topology_observed_behind_nodes"),
            ("FlareTopologyGenerationMismatch", "flare_operator_topology_observed_ahead_nodes"),
            ("FlareTopologyFeedbackUnknown", "flare_operator_topology_unknown_nodes"),
        ]:
            self.assertIn(f"alert: {alert}", text)
            self.assertIn(f"expr: {metric} > 0", text)
        self.assertEqual(text.count("runbook: docs/RUNBOOK.md#topology-observation"), 3)

    def test_replica_follow_alerts_render_with_runbooks(self):
        text = self.render("monitoring.prometheusRule.enabled=true")
        self.assertIn("alert: FlareReplicaFollowLag", text)
        self.assertIn("expr: flare_node_repl_follow_enabled == 1 and flare_node_repl_follow_lag > 1000", text)
        self.assertIn("alert: FlareReplicaNotFollowing", text)
        self.assertIn('flare_operator_node_role{role="slave",state="active"} == 1', text)
        self.assertEqual(text.count("runbook: docs/RUNBOOK.md#replica-follow"), 2)

    def test_initial_config_and_cr_both_have_memory_settings(self):
        text = self.render("cluster.rocksdb.blockCacheSizeMb=64",
                           "cluster.rocksdb.writeBufferSizeMb=16",
                           "cluster.rocksdb.maxWriteBufferNumber=3")
        config = next(doc for doc in text.split("\n---")
                      if "kind: ConfigMap" in doc and "extra.conf:" in doc)
        self.assertIn('"helm.sh/hook": pre-install', config)
        for option, value in [("block-cache-size-mb", 64),
                              ("write-buffer-size-mb", 16),
                              ("max-write-buffer-number", 3)]:
            self.assertIn(f"rocksdb-{option} = {value}", config)
        cr = next(doc for doc in text.split("\n---") if "kind: FlareCluster" in doc.splitlines())
        for field, value in [("blockCacheSizeMb", 64), ("writeBufferSizeMb", 16),
                             ("maxWriteBufferNumber", 3)]:
            self.assertIn(f"{field}: {value}", cr)


    def test_forward_queue_bounded_by_default(self):
        text = self.render()
        cr = next(doc for doc in text.split("\n---") if "kind: FlareCluster" in doc.splitlines())
        self.assertIn("maxTotalThreadQueue: 200000", cr)

@unittest.skipUnless(shutil.which("helm"), "helm is required")
class MemoryBudgetCheckTest(unittest.TestCase):
    """Render-time memory budget check for the flared container (plan item 4)."""

    def render(self, *settings, check=True):
        args = ["helm", "template", "t", str(ROOT / "helm/flare-operator"), "--set", "cluster.enabled=true",
                "--set", "namespace=ns"]
        for setting in settings:
            args.extend(["--set", setting])
        return subprocess.run(args, text=True, capture_output=True)

    def test_defaults_warn_above_70_percent(self):
        r = self.render()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("RocksDB memory floor (896 MiB) is above 70% of the flared memory limit (1024 MiB)", r.stdout)

    def test_floor_at_or_above_limit_fails(self):
        r = self.render("cluster.resources.limits.memory=512Mi")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("at or below the RocksDB memory floor of 896 MiB", r.stderr)

    def test_small_budgets_under_small_limit_pass_quietly(self):
        r = self.render("cluster.resources.limits.memory=512Mi",
                        "cluster.rocksdb.blockCacheSizeMb=64",
                        "cluster.rocksdb.writeBufferSizeMb=16",
                        "cluster.rocksdb.maxWriteBufferNumber=3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("WARNING: the RocksDB memory floor", r.stdout)

    def test_tmpfs_counts_against_memory(self):
        r = self.render("cluster.resources.limits.memory=4Gi",
                        "cluster.persistence.enabled=false",
                        "cluster.tmpfs.enabled=true", "cluster.tmpfs.sizeLimit=4Gi")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("RocksDB floor 896 MiB + tmpfs.sizeLimit 4096 MiB exceeds the memory limit 4096 MiB", r.stdout)


if __name__ == "__main__":
    unittest.main()
