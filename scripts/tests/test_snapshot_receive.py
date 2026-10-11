"""Deterministic fixtures for scripts/flare_snapshot_receive.py (V capture)."""

import io
import os
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import flare_snapshot_receive as r  # noqa: E402


def stream(files, seq=42, mid="mid-a", announce=None, end=True, crc_fix=None):
    out = bytearray(f"SNAPSHOT {seq} {mid} {len(files) if announce is None else announce}\r\n".encode())
    for name, data in files:
        crc = zlib.crc32(data) if crc_fix is None else crc_fix
        out += f"FILE {name} {len(data)} {crc}\r\n".encode() + data
    if end:
        out += b"END\r\n"
    return bytes(out)


class Receive(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def run_(self, data):
        return r.receive(io.BytesIO(data), self.d)

    def test_complete_stream_binary_files(self):
        files = [("000010.sst", bytes(range(256)) * 3), ("MANIFEST-000005", b"FILE x 1 2\r\nEND\r\n"), ("CURRENT", b"")]
        info = self.run_(stream(files))
        self.assertEqual(info, {"seq": 42, "master_id": "mid-a", "files": 3, "bytes": 768 + 17})
        for name, data in files:
            with open(os.path.join(self.d, name), "rb") as f:
                self.assertEqual(f.read(), data)

    def test_busy_or_error_reply(self):
        with self.assertRaisesRegex(r.StreamError, "not a snapshot reply"):
            self.run_(b"SERVER_ERROR busy\r\n")

    def test_truncated_file(self):
        data = stream([("a.sst", b"0123456789")])
        with self.assertRaisesRegex(r.StreamError, "stream ended after"):
            self.run_(data[: data.index(b"0123") + 4])

    def test_missing_end(self):
        with self.assertRaisesRegex(r.StreamError, "stream ended inside a header"):
            self.run_(stream([("a.sst", b"x")], end=False))

    def test_crc_mismatch(self):
        with self.assertRaisesRegex(r.StreamError, "CRC-32"):
            self.run_(stream([("a.sst", b"payload")], crc_fix=1))

    def test_file_count_disagrees(self):
        with self.assertRaisesRegex(r.StreamError, "announced 3"):
            self.run_(stream([("a.sst", b"x")], announce=3))

    def test_suspicious_names(self):
        for bad in ("../x", ".hidden", "a/b"):
            d = tempfile.mkdtemp()
            with self.assertRaisesRegex(r.StreamError, "suspicious"):
                r.receive(io.BytesIO(stream([(bad, b"x")])), d)

    def test_repeated_name(self):
        with self.assertRaisesRegex(r.StreamError, "repeated"):
            self.run_(stream([("a.sst", b"x"), ("a.sst", b"y")]))

    def test_non_empty_directory_refused(self):
        open(os.path.join(self.d, "old"), "w").close()
        with self.assertRaisesRegex(r.StreamError, "empty directory"):
            self.run_(stream([("a.sst", b"x")]))

    def test_desync_garbage_line(self):
        with self.assertRaisesRegex(r.StreamError, "expected FILE or END"):
            self.run_(b"SNAPSHOT 1 m 1\r\nVALUE k 0 1 1 0\r\nx\r\nEND\r\n")


if __name__ == "__main__":
    unittest.main()
