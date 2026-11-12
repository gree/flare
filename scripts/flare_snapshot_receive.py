#!/usr/bin/env python3
"""Receive one `repl_snapshot` reply (flared's point-in-time RocksDB
checkpoint stream) from stdin into an EMPTY directory, for verification V
capture (docs/review-cross-cluster-2026-10-11.md §12). Decode the directory
afterwards with `flared --dump-checkpoint <dir>` (same flared build), which
writes the `dump` framing scripts/flare_verify_copy.py reads.

Why not `dump`: on a master `dump` deletes the expired keys it meets (a WAL
write that moves the sequence number), takes the single iteration slot,
holds the whole-DB read lock for the scan, and reads values LIVE while the
keys come from a snapshot. `repl_snapshot` writes no data: keys and values
come from one checkpoint, nothing is reaped. Its cost on the source: a forced
memtable flush, file deletions pinned for the transfer, a checkpoint whose
hard links pin space (memory on tmpfs) until the stream ends, the single
snapshot-serve slot (a concurrent reseed waits "busy"), and the transfer
(throttled by rocksdb-snapshot-bwlimit). It is an unauthenticated op on the
data port like every other: running it against a live cluster is an
operational decision this tool does not make (used in CI only so far).

Capture mode (the request `repl_snapshot <bw> capture [<deadline_sec>]`):
flared refuses before pinning anything when a rebuild runs on the node or
when free space (tmpfs: cgroup memory headroom) < copy + reserve or any of
them is unknown ("SERVER_ERROR capture_refused <reason>"); it bounds the
serve with a write-progress timeout and a total deadline, aborts on a drop
below the reserve, and marks the header with a 5th token "capture".
`--require-capture` refuses a header without it (an older flared that
ignored the mode served WITHOUT those guards).

Stream: SNAPSHOT <seq> <master_id> <nfiles>[ capture]\\r\\n
        (FILE <name> <size> <crc32>\\r\\n <size raw bytes>)*
        END\\r\\n
Anything else — an error reply ("SERVER_ERROR busy"), a short file, a CRC
mismatch, a suspicious name, a missing END, a file count that disagrees —
exits 2 and the directory must not be used. Prints a JSON summary
{"seq", "master_id", "files", "bytes"} on success (exit 0).
"""

import argparse
import json
import os
import sys
import zlib


class StreamError(Exception):
    pass


def _line(f):
    buf = bytearray()
    while True:
        c = f.read(1)
        if not c:
            raise StreamError("stream ended inside a header line")
        buf += c
        if buf.endswith(b"\r\n"):
            return buf[:-2].decode("ascii", "replace")
        if len(buf) > 4096:
            raise StreamError("header line too long (desync)")


def receive(f, out_dir, require_capture=False):
    if not os.path.isdir(out_dir) or os.listdir(out_dir):
        raise StreamError(f"{out_dir}: not an existing empty directory")
    head = _line(f).split(" ")
    capture = len(head) == 5 and head[4] == "capture"
    if len(head) not in (4, 5) or head[0] != "SNAPSHOT" or (len(head) == 5 and not capture):
        raise StreamError(f"not a snapshot reply: {' '.join(head)!r}")
    if require_capture and not capture:
        raise StreamError("the server did not acknowledge capture mode (no capture guards): refused")
    head = head[:4]
    try:
        seq, nfiles = int(head[1]), int(head[3])
    except ValueError:
        raise StreamError(f"bad SNAPSHOT line: {' '.join(head)!r}")
    master_id = head[2]
    seen, total = [], 0
    while True:
        parts = _line(f).split(" ")
        if parts == ["END"]:
            break
        if len(parts) != 4 or parts[0] != "FILE":
            raise StreamError(f"expected FILE or END, got {' '.join(parts)!r}")
        name = parts[1]
        if not name or name.startswith(".") or "/" in name or name in seen:
            raise StreamError(f"suspicious or repeated file name {name!r}")
        try:
            size, want_crc = int(parts[2]), int(parts[3])
        except ValueError:
            raise StreamError(f"bad FILE line: {' '.join(parts)!r}")
        crc, left = 0, size
        with open(os.path.join(out_dir, name), "wb") as w:
            while left:
                chunk = f.read(min(left, 1 << 20))
                if not chunk:
                    raise StreamError(f"{name}: stream ended after {size - left} of {size} bytes")
                crc = zlib.crc32(chunk, crc)
                w.write(chunk)
                left -= len(chunk)
        if crc != want_crc:
            raise StreamError(f"{name}: CRC-32 {crc} != announced {want_crc}")
        seen.append(name)
        total += size
    if len(seen) != nfiles:
        raise StreamError(f"{len(seen)} files received, SNAPSHOT announced {nfiles}")
    return {"seq": seq, "master_id": master_id, "files": len(seen), "bytes": total, "capture": capture}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="an existing EMPTY directory")
    ap.add_argument("--require-capture", action="store_true",
                    help="refuse a reply whose header does not acknowledge capture mode")
    args = ap.parse_args(argv)
    try:
        info = receive(sys.stdin.buffer, args.out, args.require_capture)
    except (StreamError, OSError) as e:
        print(f"snapshot receive FAILED: {e}", file=sys.stderr)
        return 2
    print(json.dumps(info, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
