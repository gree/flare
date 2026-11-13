"""scripts/flare-restore-hook: the restore provenance check BEFORE the live copy
is replaced (restore-isolated 5). A stub `flared --checkpoint-binding` reads
<dir>/.binding instead of a RocksDB directory ("UNREADABLE" = exit 2)."""

import os
import shutil
import subprocess
import tempfile
import unittest

HOOK = os.path.join(os.path.dirname(__file__), "..", "flare-restore-hook")

STUB = """#!/bin/sh
[ "$1" = "--checkpoint-binding" ] || exit 9
[ -f "$2/.binding" ] || { echo "binding -"; echo "restored_unverified 0"; exit 0; }
b=$(cat "$2/.binding"); [ "$b" = "UNREADABLE" ] && exit 2
echo "binding $b"; echo "restored_unverified 0"
"""

P0 = "v1 partition=0 partitions=1 size=1024 hash=jenkins resolver=modular hint=1 virtual=4096"
P0N2 = "v1 partition=0 partitions=2 size=1024 hash=jenkins resolver=modular hint=1 virtual=4096"
P0SIMPLE = "v1 partition=0 partitions=1 size=1024 hash=simple resolver=modular hint=1 virtual=4096"
P1 = "v1 partition=1 partitions=2 size=1024 hash=jenkins resolver=modular hint=1 virtual=4096"


class RestoreHook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "flared"), "w") as f:
            f.write(STUB)
        os.chmod(os.path.join(self.bin, "flared"), 0o755)
        self.d = os.path.join(self.tmp, "data")
        self.live = os.path.join(self.d, "flare.rocksdb")
        self.bak = os.path.join(self.d, "backups", "b")
        os.makedirs(self.live)
        os.makedirs(self.bak)
        self._write(self.live, "data", "live")
        self._write(self.bak, "data", "bak")

    def tearDown(self):
        # a copy that failed part-way can leave unreadable directories (the
        # failed-copy test): make everything removable first
        for root, dirs, _ in os.walk(self.tmp, topdown=True):
            for d in dirs:
                try:
                    os.chmod(os.path.join(root, d), 0o755)
                except OSError:
                    pass
        shutil.rmtree(self.tmp)

    def _write(self, d, name, text):
        with open(os.path.join(d, name), "w") as f:
            f.write(text + "\n")

    def _read(self, path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return None

    def _marker(self, target):
        self._write(self.d, "RESTORE", target)

    def _run(self, **extra):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], **extra)
        return subprocess.run(["sh", HOOK, self.d], env=env, capture_output=True, text=True)

    def _staged(self):
        return sorted(n for n in os.listdir(self.d) if n.startswith("staging-restore-"))

    def _state(self):
        return {
            "live": self._read(os.path.join(self.live, "data")),
            "restored": os.path.exists(os.path.join(self.live, "RESTORED")),
            "marker": os.path.exists(os.path.join(self.d, "RESTORE")),
            "refused": os.path.exists(os.path.join(self.d, "RESTORE.refused")),
        }

    def _kept(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._state(), {"live": "live", "restored": False, "marker": False, "refused": True})
        self.assertIn("RESTORE REFUSED", r.stderr)

    def _replaced(self, r):
        # no live copy before: the backup IS the live copy
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._state(), {"live": "bak", "restored": True, "marker": False, "refused": False})

    def _prepared_in_place(self, r):
        # a live copy existed: it is UNTOUCHED; the backup waits next to it as
        # staging-restore-<ts> (RESTORED + a fresh COPY_ID), named in
        # RESTORE.switch, for flared to switch in and RETAIN the live copy
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self._state(), {"live": "live", "restored": False, "marker": False, "refused": False})
        staged = self._staged()
        self.assertEqual(len(staged), 1, staged)
        st = os.path.join(self.d, staged[0])
        self.assertEqual(self._read(os.path.join(st, "data")), "bak")
        self.assertTrue(os.path.exists(os.path.join(st, "RESTORED")))
        self.assertTrue(self._read(os.path.join(st, "COPY_ID")).endswith(":1"))
        self.assertEqual(self._read(os.path.join(self.d, "RESTORE.switch")), staged[0][len("staging-"):])

    def test_no_marker_is_a_no_op(self):
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self._state(), {"live": "live", "restored": False, "marker": False, "refused": False})

    def test_missing_backup_keeps_the_live_copy(self):
        self._marker(os.path.join(self.d, "backups", "none"))
        self._kept(self._run())

    def test_unbound_backup_keeps_the_live_copy(self):
        self._marker(self.bak)
        r = self._run()
        self._kept(r)
        self.assertIn("no partition binding", self._read(os.path.join(self.d, "RESTORE.refused.reason")))

    def test_unreadable_backup_keeps_the_live_copy(self):
        self._write(self.bak, ".binding", "UNREADABLE")
        self._marker(self.bak)
        self._kept(self._run())

    def test_another_partition_keeps_the_live_copy(self):
        self._write(self.live, ".binding", P0)
        self._write(self.bak, ".binding", P1)
        self._marker(self.bak)
        self._kept(self._run())

    def test_another_routing_rule_keeps_the_live_copy(self):
        self._write(self.live, ".binding", P0)
        self._write(self.bak, ".binding", P0SIMPLE)
        self._marker(self.bak)
        self._kept(self._run())

    def test_same_partition_and_rule_replaces_with_restored_marker(self):
        # the partition COUNT is not compared
        self._write(self.live, ".binding", P0)
        self._write(self.bak, ".binding", P0N2)
        self._marker(self.bak)
        self._prepared_in_place(self._run())

    def test_unreadable_live_copy_is_replaced_by_a_bound_backup(self):
        self._write(self.live, ".binding", "UNREADABLE")
        self._write(self.bak, ".binding", P1)
        self._marker(self.bak)
        # the unreadable live copy is KEPT as well (retained by the switch)
        self._prepared_in_place(self._run())

    def test_no_live_copy_and_a_refused_backup_does_not_start(self):
        shutil.rmtree(self.live)
        self._marker(self.bak)
        r = self._run()
        self.assertEqual(r.returncode, 1)
        self.assertTrue(self._state()["marker"])
        self.assertFalse(os.path.exists(self.live))

    def test_no_live_copy_and_a_bound_backup_is_restored(self):
        shutil.rmtree(self.live)
        self._write(self.bak, ".binding", P1)
        self._marker(self.bak)
        self._replaced(self._run())


    def test_not_enough_space_keeps_the_live_copy_and_prepares_nothing(self):
        self._write(self.live, ".binding", P0)
        self._write(self.bak, ".binding", P0)
        self._marker(self.bak)
        r = self._run(FLARE_RESTORE_RESERVE_BYTES=str(10 ** 18))
        self._kept(r)
        self.assertIn("not enough space", self._read(os.path.join(self.d, "RESTORE.refused.reason")))
        self.assertEqual(self._staged(), [])
        self.assertFalse(os.path.exists(os.path.join(self.d, "RESTORE.switch")))

    def test_not_enough_space_without_a_live_copy_does_not_start(self):
        shutil.rmtree(self.live)
        self._write(self.bak, ".binding", P0)
        self._marker(self.bak)
        r = self._run(FLARE_RESTORE_RESERVE_BYTES=str(10 ** 18))
        self.assertEqual(r.returncode, 1)
        self.assertTrue(self._state()["marker"])
        self.assertFalse(os.path.exists(self.live))

    def test_a_failed_copy_keeps_the_live_copy_and_removes_nothing(self):
        self._write(self.live, ".binding", P0)
        self._write(self.bak, ".binding", P0)
        os.makedirs(os.path.join(self.bak, "sub"))
        self._write(os.path.join(self.bak, "sub"), "f", "x")
        os.chmod(os.path.join(self.bak, "sub"), 0)          # cp -a fails on it
        self._marker(self.bak)
        try:
            r = self._run()
        finally:
            os.chmod(os.path.join(self.bak, "sub"), 0o755)
        if os.geteuid() == 0:
            self.skipTest("running as root: the unreadable directory is readable")
        self._kept(r)
        self.assertEqual(self._staged(), [])
        self.assertTrue(any(n.startswith("restore-incoming-") for n in os.listdir(self.d)),
                        "the incomplete copy must be left in place (not removed)")


if __name__ == "__main__":
    unittest.main()
