"""The object-storage transfer cap (cluster.objectStorage.maxBandwidth) reaches
every container that runs `aws s3`, and nothing renders when it is unset."""
import pathlib
import shutil
import subprocess
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]

BASE = [
    "cluster.enabled=true",
    "cluster.name=bw",
    "clusterName=bw",
    "namespace=bw",
    "cluster.objectStorage.url=s3://bucket/prefix",
    "cluster.objectStorage.projectedTokenAudience=sts.amazonaws.com",
    "cluster.backup.enabled=true",
    "cluster.backup.walArchive.enabled=true",
    "cluster.backupBootstrap.enabled=true",
    "cluster.analysis.enabled=true",
    "cluster.partitions=1",
]

# (kind, container name, init container?) of every container that runs aws s3
AWS_CONTAINERS = [
    ("CronJob", "backup"),
    ("Deployment", "upload"),
    ("StatefulSet", "backup-bootstrap"),
    ("CronJob", "pull"),
    ("CronJob", "upload"),
]


@unittest.skipUnless(shutil.which("helm"), "helm is required")
class S3BandwidthTest(unittest.TestCase):
    def render(self, *settings, check=True):
        args = ["helm", "template", "bw", str(ROOT / "helm/flare-operator")]
        for setting in BASE + list(settings):
            args.extend(["--set", setting])
        proc = subprocess.run(args, text=True, capture_output=True)
        if check and proc.returncode != 0:
            self.fail(proc.stderr)
        return proc

    def docs(self, text):
        return [d for d in yaml.safe_load_all(text) if d]

    def pod_spec(self, doc):
        spec = doc["spec"]
        if doc["kind"] == "CronJob":
            spec = spec["jobTemplate"]["spec"]
        return spec["template"]["spec"]

    def containers(self, docs):
        """(kind, container, pod spec) for every container of the cluster."""
        out = []
        for d in docs:
            if d["kind"] not in ("CronJob", "Deployment", "StatefulSet"):
                continue
            ps = self.pod_spec(d)
            for c in ps.get("initContainers", []) + ps.get("containers", []):
                out.append((d["kind"], c, ps))
        return out

    def test_cap_reaches_every_aws_container(self):
        docs = self.docs(self.render("cluster.objectStorage.maxBandwidth=50MB/s").stdout)
        cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "bw-s3-config"]
        self.assertEqual(len(cm), 1)
        self.assertIn("max_bandwidth = 50MB/s", cm[0]["data"]["config"])
        self.assertTrue(cm[0]["data"]["config"].startswith("[default]\ns3 =\n"))
        found = set()
        for kind, c, ps in self.containers(docs):
            if (kind, c["name"]) not in AWS_CONTAINERS:
                continue
            found.add((kind, c["name"]))
            env = {e["name"]: e.get("value") for e in c.get("env", [])}
            self.assertEqual(env.get("AWS_CONFIG_FILE"), "/etc/flare-s3/config", (kind, c["name"]))
            mounts = {m["name"]: m["mountPath"] for m in c.get("volumeMounts", [])}
            self.assertEqual(mounts.get("s3-config"), "/etc/flare-s3", (kind, c["name"]))
            vols = {v["name"]: v for v in ps.get("volumes", [])}
            self.assertEqual(vols["s3-config"]["configMap"]["name"], "bw-s3-config", (kind, c["name"]))
            # the token mount still sits next to it
            self.assertIn("/var/run/secrets/sts", mounts.values(), (kind, c["name"]))
        self.assertEqual(found, set(AWS_CONTAINERS))

    def test_every_container_running_aws_s3_is_covered(self):
        # a new `aws s3` caller must be added to AWS_CONTAINERS (and wired)
        docs = self.docs(self.render("cluster.objectStorage.maxBandwidth=50MB/s").stdout)
        for kind, c, _ in self.containers(docs):
            script = " ".join(c.get("command", []) + c.get("args", []))
            image = c.get("image", "")
            if "aws s3" in script or "flare-backup-run" in script or "flare-wal-upload" in script:
                self.assertIn((kind, c["name"]), AWS_CONTAINERS, (kind, c["name"], image))

    def test_unset_renders_nothing(self):
        text = self.render().stdout
        self.assertNotIn("s3-config", text)
        self.assertNotIn("AWS_CONFIG_FILE", text)

    def test_bad_value_fails(self):
        for bad in ["50", "50MB", "fast", "0MB/s", "50 MB/s"]:
            proc = self.render(f"cluster.objectStorage.maxBandwidth={bad}", check=False)
            self.assertNotEqual(proc.returncode, 0, bad)
            self.assertIn("maxBandwidth", proc.stderr, bad)

    def test_extra_env_aws_config_file_conflicts(self):
        proc = self.render("cluster.objectStorage.maxBandwidth=50MB/s",
                           "cluster.objectStorage.extraEnv[0].name=AWS_CONFIG_FILE",
                           "cluster.objectStorage.extraEnv[0].value=/x", check=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("AWS_CONFIG_FILE", proc.stderr)

    def test_bytes_per_second_accepted(self):
        self.render("cluster.objectStorage.maxBandwidth=1048576/s")


if __name__ == "__main__":
    unittest.main()
