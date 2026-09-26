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


if __name__ == "__main__":
    unittest.main()
