"""Deterministic fixtures for scripts/flare_verify_copy.py (verification V).

Every fixture is built in-process from fixed bytes: no cluster, no clock.
The dump framing is the one flared's op_dump serves
(test/lib/test_op_dump.cc run_server_output_test:
"VALUE key0 0 1 0 0\\r\\n" "o\\r\\n" ... "END\\r\\n").
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import flare_verify_copy as V  # noqa: E402

T0 = 1_800_000_000  # server time at the pre snapshot
T1 = T0 + 30        # server time at the post snapshot


def item(key, value, flag=0, version=1, expire=0):
    if isinstance(value, str):
        value = value.encode()
    return b"VALUE %s %d %d %d %d\r\n" % (key.encode(), flag, len(value), version, expire) + value + b"\r\n"


def dump(*items, end=True):
    return b"".join(items) + (b"END\r\n" if end else b"")


BASE_STATS = {
    "pid": "1", "uptime": "1000", "time": str(T0), "proxy_write_dropped": "0",
    "rocksdb_master_id": "mid-a", "rocksdb_copy_id": "copy-a:1", "rocksdb_source_epoch": "1:ep-a",
    "rocksdb_latest_sequence_number": "500", "cmd_set": "10", "delete_hits": "0", "delete_misses": "0",
    "touch_hits": "0", "touch_misses": "0", "incr_hits": "0", "incr_misses": "0", "decr_hits": "0",
    "decr_misses": "0", "cas_hits": "0", "cas_misses": "0", "cas_badval": "0", "curr_items": "3",
    "rocksdb_expire_reaped": "0", "cluster_replication": "on",
    "cluster_replication[seed_completed]": "1", "cluster_replication_seed": "completed_dump",
}


def stats_raw(over):
    s = dict(BASE_STATS)
    s.update(over)
    return "".join(f"STAT {k} {v}\r\n" for k, v in s.items() if v is not None) + "END\r\n"


def node(pod, over=None, uid=None, captured_at=None, time=T0):
    o = {"time": str(time), "uptime": str(time - (T0 - 1000))}
    o.update(over or {})
    return {"pod": pod, "pod_uid": uid or f"{pod}-uid", "captured_at": captured_at if captured_at is not None else time,
            "stats": stats_raw(o)}


class Fixture:
    """Writes one verification's files; each test overrides a part."""

    def __init__(self, tmp):
        self.tmp = tmp
        self.src = {"s0": dump(item("a", "1"), item("b", "2"), item("c", "3"))}
        self.dst = {"d0": dump(item("a", "1"), item("b", "2"), item("c", "3"))}
        self.src_pre = [node("s0")]
        self.src_post = [node("s0", time=T1)]
        self.dst_pre = [node("d0", {"cluster_replication": None, "cluster_replication[seed_completed]": None})]
        self.dst_post = [node("d0", {"cluster_replication": None, "cluster_replication[seed_completed]": None}, time=T1)]
        self.baseline = [node("s0", {"cluster_replication": "off", "cluster_replication[seed_completed]": "0",
                                     "cluster_replication_seed": "none"}, time=T0 - 600)]

    def _w(self, name, data):
        p = os.path.join(self.tmp, name)
        with open(p, "wb" if isinstance(data, bytes) else "w") as f:
            f.write(data)
        return p

    def run(self):
        args = []
        for k, v in self.src.items():
            args += ["--src-dump", self._w(f"src-{k}.dump", v)]
        for k, v in self.dst.items():
            args += ["--dst-dump", self._w(f"dst-{k}.dump", v)]
        for flag, nodes in (("src-pre", self.src_pre), ("src-post", self.src_post), ("dst-pre", self.dst_pre),
                            ("dst-post", self.dst_post), ("attempt-baseline", self.baseline)):
            args += [f"--{flag}", self._w(f"{flag}.json", json.dumps({"nodes": nodes}))]
        rep = os.path.join(self.tmp, "report.json")
        code = V.main(args + ["--report", rep])
        with open(rep) as f:
            return code, json.load(f)


class VerifyCopyTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.f = Fixture(self._td.name)

    def tearDown(self):
        self._td.cleanup()

    def assertVerdict(self, code, verdict, problem=None):
        c, r = self.f.run()
        self.assertEqual((c, r["verdict"]), (code, verdict), json.dumps(r, indent=1))
        if problem:
            self.assertTrue(any(problem in p for p in r["problems"]), r["problems"])
        return r

    # ---- MATCH -----------------------------------------------------------
    def test_identical_content_matches(self):
        r = self.assertVerdict(0, "MATCH")
        self.assertEqual(r["comparison"]["compared"], 3)

    def test_wire_format_of_op_dump(self):
        # the exact bytes flared's op_dump test expects for one 1-byte item
        self.f.src = {"s0": b"VALUE key0 0 1 0 0\r\no\r\nEND\r\n"}
        self.f.dst = {"d0": b"VALUE key0 0 1 0 0\r\no\r\nEND\r\n"}
        self.assertVerdict(0, "MATCH")

    def test_binary_value_with_crlf_and_end_inside(self):
        v = b"\x00\xff\r\nEND\r\nVALUE x 0 1 0 0\r\n"
        self.f.src = {"s0": dump(item("a", v), item("b", "2"))}
        self.f.dst = {"d0": dump(item("a", v), item("b", "2"))}
        self.assertVerdict(0, "MATCH")

    def test_two_source_partitions_against_one_destination(self):
        self.f.src = {"s0": dump(item("a", "1"), item("c", "3")), "s1": dump(item("b", "2"))}
        self.f.src_pre = [node("s0"), node("s1")]
        self.f.src_post = [node("s0", time=T1), node("s1", time=T1)]
        self.f.baseline = self.f.baseline + [node("s1", {"cluster_replication": "off", "cluster_replication[seed_completed]": "0",
                                                         "cluster_replication_seed": "none"}, time=T0 - 600)]
        self.assertVerdict(0, "MATCH")

    # ---- DIFFERENT ---------------------------------------------------------
    def test_delete_not_applied_on_destination_is_extra(self):
        self.f.src = {"s0": dump(item("a", "1"), item("c", "3"))}
        r = self.assertVerdict(1, "DIFFERENT")
        self.assertEqual(r["comparison"]["extra"], 1)
        self.assertEqual(r["comparison"]["samples"]["extra"][0]["key"], "b")

    def test_missing_on_destination(self):
        self.f.dst = {"d0": dump(item("a", "1"), item("c", "3"))}
        r = self.assertVerdict(1, "DIFFERENT")
        self.assertEqual(r["comparison"]["missing"], 1)

    def test_value_flags_expire_version_each_differ(self):
        far = T1 + 86400
        for src_i, dst_i, field in [
            (item("b", "2"), item("b", "X"), "value"),
            (item("b", "2", flag=1), item("b", "2", flag=2), "flags"),
            (item("b", "2", expire=far), item("b", "2", expire=far + 1), "expire"),
            (item("b", "2", version=7), item("b", "2", version=8), "version"),
        ]:
            with self.subTest(field=field):
                self.f.src = {"s0": dump(item("a", "1"), src_i, item("c", "3"))}
                self.f.dst = {"d0": dump(item("a", "1"), dst_i, item("c", "3"))}
                r = self.assertVerdict(1, "DIFFERENT")
                self.assertTrue(r["comparison"]["samples"]["different"][0]["fields"][0].startswith(field))

    def test_one_sided_key_expiring_after_the_window_is_a_definite_difference(self):
        self.f.dst = {"d0": dump(item("a", "1"), item("c", "3"))}
        self.f.src = {"s0": dump(item("a", "1"), item("b", "2", expire=T1 + 3600), item("c", "3"))}
        r = self.assertVerdict(1, "DIFFERENT")
        self.assertEqual((r["comparison"]["missing"], r["comparison"]["indeterminate"]), (1, 0))

    def test_loss_counted_during_the_attempt_refuses_even_when_content_matches(self):
        self.f.src_post = [node("s0", {"cluster_replication[forward_failed_set_server_error]": "1"}, time=T1)]
        self.f.src_pre = [node("s0", {"cluster_replication[forward_failed_set_server_error]": "1"})]
        self.assertVerdict(1, "DIFFERENT", "counted as lost")

    def test_loss_during_the_seed_counts_baseline_is_before_enable(self):
        # a drop that happened during the seed: above the pre-enable baseline
        self.f.src_pre = [node("s0", {"proxy_write_dropped": "2"})]
        self.f.src_post = [node("s0", {"proxy_write_dropped": "2"}, time=T1)]
        self.assertVerdict(1, "DIFFERENT", "2 writes counted as lost")

    # ---- UNKNOWN: near expiry --------------------------------------------
    def test_one_sided_key_expiring_inside_the_window_is_indeterminate_not_excluded(self):
        self.f.dst = {"d0": dump(item("a", "1"), item("c", "3"))}
        self.f.src = {"s0": dump(item("a", "1"), item("b", "2", expire=T0 + 10), item("c", "3"))}
        r = self.assertVerdict(2, "UNKNOWN", "indeterminate")
        self.assertEqual((r["comparison"]["missing"], r["comparison"]["indeterminate"]), (0, 1))

    def test_clock_offset_widens_the_indeterminate_band(self):
        # expiring 5 s after the destination's window: definite with a
        # synchronized clock, indeterminate when a server is 10 s off
        self.f.dst = {"d0": dump(item("a", "1"), item("c", "3"))}
        self.f.src = {"s0": dump(item("a", "1"), item("b", "2", expire=T1 + 5), item("c", "3"))}
        self.assertVerdict(1, "DIFFERENT")
        self.f.dst_post = [node("d0", {"cluster_replication": None, "cluster_replication[seed_completed]": None},
                                time=T1, captured_at=T1 + 10)]
        self.assertVerdict(2, "UNKNOWN", "indeterminate")

    # ---- UNKNOWN: streams --------------------------------------------------
    def test_stream_defects_are_unknown(self):
        cases = {
            "truncated": dump(item("a", "1"), item("b", "2"), end=False),
            "server_error": dump(item("a", "1")) [:-5] + b"SERVER_ERROR database busy\r\n",
            "unsorted": dump(item("b", "2"), item("a", "1"), item("c", "3")),
            "short_value": b"VALUE a 0 5 1 0\r\n12\r\nEND\r\n",
            "bad_header": b"VALUE a 0 1\r\n1\r\nEND\r\n",
            "after_end": dump(item("a", "1")) + b"x",
        }
        for name, data in cases.items():
            with self.subTest(case=name):
                self.f.dst = {"d0": data}
                self.assertVerdict(2, "UNKNOWN", "stream")

    def test_key_in_two_partition_streams_is_unknown(self):
        self.f.src = {"s0": dump(item("a", "1"), item("b", "2")), "s1": dump(item("b", "2"), item("c", "3"))}
        self.f.src_pre = [node("s0"), node("s1")]
        self.f.src_post = [node("s0", time=T1), node("s1", time=T1)]
        self.f.baseline = self.f.baseline + [node("s1", {"cluster_replication": "off", "cluster_replication[seed_completed]": "0",
                                                         "cluster_replication_seed": "none"}, time=T0 - 600)]
        self.assertVerdict(2, "UNKNOWN", "two partition streams")

    def test_stream_count_must_match_partition_masters(self):
        self.f.src_pre = [node("s0"), node("s1")]
        self.f.src_post = [node("s0", time=T1), node("s1", time=T1)]
        self.assertVerdict(2, "UNKNOWN", "dump streams for 2 partition masters")

    # ---- UNKNOWN: change during the scan ---------------------------------
    def test_change_during_the_scan_invalidates(self):
        for side, over, needle in [
            ("src", {"rocksdb_latest_sequence_number": "501"}, "rocksdb_latest_sequence_number changed"),
            ("dst", {"rocksdb_copy_id": "copy-b:1"}, "rocksdb_copy_id changed"),
            ("dst", {"rocksdb_master_id": "mid-z"}, "rocksdb_master_id changed"),
            ("src", {"rocksdb_source_epoch": "2:ep-b"}, "copy epoch"),
            ("src", {"cmd_set": "11"}, "cmd_set changed"),
            ("dst", {"delete_hits": "1"}, "delete_hits changed"),
            ("dst", {"rocksdb_expire_reaped": "4"}, "rocksdb_expire_reaped changed"),
            ("src", {"rocksdb_copy_id": None}, "not reported"),
        ]:
            with self.subTest(side=side, over=over):
                f = Fixture(self._td.name)
                extra = {} if side == "src" else {"cluster_replication": None, "cluster_replication[seed_completed]": None}
                post = node("s0" if side == "src" else "d0", {**extra, **over}, time=T1)
                if side == "src":
                    f.src_post = [post]
                else:
                    f.dst_post = [post]
                self.f = f
                self.assertVerdict(2, "UNKNOWN", needle)

    def test_differences_from_an_invalid_scan_are_listed_but_unknown(self):
        self.f.dst = {"d0": dump(item("a", "1"), item("c", "3"))}
        self.f.src_post = [node("s0", {"cmd_set": "11"}, time=T1)]
        r = self.assertVerdict(2, "UNKNOWN", "cmd_set changed")
        self.assertEqual(r["comparison"]["missing"], 1)

    def test_restart_during_the_scan_invalidates(self):
        self.f.dst_post = [node("d0", {"cluster_replication": None, "cluster_replication[seed_completed]": None,
                                       "uptime": "5"}, time=T1)]
        self.assertVerdict(2, "UNKNOWN", "restarted or replaced during the scan")

    def test_stats_without_end_is_unreadable(self):
        n = node("s0", time=T1)
        n["stats"] = n["stats"].replace("END\r\n", "")
        self.f.src_post = [n]
        self.assertVerdict(2, "UNKNOWN", "no END")

    # ---- UNKNOWN: attempt-wide counters ------------------------------------
    def test_source_restarted_since_the_attempt_baseline_is_unknown(self):
        self.f.baseline = [node("s0", {"cluster_replication": "off", "cluster_replication[seed_completed]": "0"},
                                uid="older-uid", time=T0 - 600)]
        self.assertVerdict(2, "UNKNOWN", "restarted or was replaced since the baseline")

    def test_baseline_read_while_replicating_is_unknown(self):
        self.f.baseline = [node("s0", {"cluster_replication": "on", "cluster_replication[seed_completed]": "0"}, time=T0 - 600)]
        self.assertVerdict(2, "UNKNOWN", "already on")

    def test_counter_reset_is_unknown(self):
        self.f.baseline = [node("s0", {"cluster_replication": "off", "cluster_replication[seed_completed]": "0",
                                       "proxy_write_dropped": "9"}, time=T0 - 600)]
        self.assertVerdict(2, "UNKNOWN", "went down")

    def test_seed_not_completed_in_this_attempt_is_unknown(self):
        for over in ({"cluster_replication_seed": "failed_transfer"},
                     {"cluster_replication[seed_completed]": "0"}):
            with self.subTest(over=over):
                self.f.src_pre = [node("s0", over)]
                self.f.src_post = [node("s0", over, time=T1)]
                self.assertVerdict(2, "UNKNOWN", "did not complete a seed")

    def test_streaming_reader_is_lazy(self):
        p = os.path.join(self._td.name, "lazy.dump")
        with open(p, "wb") as f:
            f.write(item("a", "1") + b"VALUE broken")
        gen = V.read_dump(p, "x")
        self.assertEqual(next(gen)[0], b"a")  # the defect is only met when read
        with self.assertRaises(V.StreamError):
            next(gen)


if __name__ == "__main__":
    unittest.main()
