#!/usr/bin/env python3
"""Verification V: compare a source cluster's and a destination cluster's
key/value content from CAPTURED `dump` streams, and say whether a cutover
must be refused. Reports and refuses only: it changes nothing, repairs
nothing, and does not connect to anything (capture is a separate, approved
step; docs/review-cross-cluster-2026-10-11.md §8).

Inputs (all files):
  --src-dump / --dst-dump   one raw `dump <wait> <p> <n>` reply per partition
                            master, as flared sent it (binary-safe framing:
                            VALUE <key> <flag> <len> <version> <expire>\\r\\n
                            <len bytes>\\r\\n ... END\\r\\n)
  --src-pre / --src-post / --dst-pre / --dst-post
                            identity snapshots taken right BEFORE and right
                            AFTER the scan: JSON
                            {"nodes": [{"pod", "pod_uid", "captured_at",
                                        "stats": "<raw `stats` reply>"}]}
  --attempt-baseline        the source masters' snapshot taken before
                            replication was enabled for this attempt (same
                            JSON shape), for loss over the WHOLE attempt

Verdicts (exit code):
  0 MATCH        zero missing / extra / different, nothing indeterminate,
                 every precondition held. The cutover MAY proceed — still a
                 human approval.
  1 DIFFERENT    a definite difference, or loss counted during the attempt:
                 refuse; the difference list is in the report.
  2 UNKNOWN      the result is not valid (an identity, position or mutation
                 counter changed during the scan; a stream truncated,
                 unsorted, duplicated or answered an error; counters lost by
                 a restart/reset; a precondition unreadable) or keys are
                 indeterminate near their expiry: refuse. Never a pass.

Expiry semantics (the one reference this tool can define): each side
omits an item that had expired BY ITS OWN SERVER CLOCK when it read it, and
that read happened inside that side's scan window [time at pre, time at
post]. An item present on one side only is a definite difference when it
never expires or expires after the other side's window ends (+ clock skew);
otherwise it may have expired on the other side before being read — it is
INDETERMINATE, counted, and forces UNKNOWN. Items present on both sides are
compared exactly (value bytes, flags, absolute expire, version). Near-expiry
keys are never silently excluded.

Binding: the report carries `binding`, one canonical line naming WHAT was
verified — the attempt (`--attempt-id`, the FlareMigration's
status.attemptBaseline verbatim) and, per partition master on each side as
read AFTER the scan: pod, pod UID, process start, master id, copy id, copy
epoch, sequence number. A MATCH says nothing about any other attempt, node,
copy, history or position: the forward switch must be refused when the live
nodes no longer equal the binding (a write after the scan moves the
sequence number; a restart moves the start; a re-seed moves copy/history;
a new attempt has another baseline). The operator does NOT check this yet
(approveForward is a boolean) — recorded as not implemented; the pure check
exists (Migration/Types.lean forwardBindingHold, unit-tested).

What it does NOT check: that each key lies in the partition its stream
claims (the server-side `dump` filter is trusted); that writes were stopped
by the clients (the caller's premise — this tool only sees mutation
counters unchanged across the scan, which is necessary, not sufficient).
"""

import argparse
import heapq
import json
import sys

# --------------------------------------------------------------- stats ----


def parse_stats(raw):
    """`STAT name value` lines → dict; requires the END line."""
    out = {}
    ended = False
    for line in raw.replace("\r", "").split("\n"):
        line = line.strip()
        if line == "END":
            ended = True
            break
        if line.startswith("STAT "):
            parts = line.split(" ", 2)
            if len(parts) == 3:
                out[parts[1]] = parts[2].strip()
    if not ended:
        raise ValueError("stats reply has no END line (truncated)")
    return out


def load_snapshot(path):
    with open(path) as f:
        j = json.load(f)
    nodes = {}
    for n in j.get("nodes", []):
        pod = n["pod"]
        if pod in nodes:
            raise ValueError(f"{path}: {pod} listed twice")
        nodes[pod] = {
            "pod_uid": n["pod_uid"],
            "captured_at": int(n["captured_at"]),
            "stats": parse_stats(n["stats"]),
        }
    if not nodes:
        raise ValueError(f"{path}: no nodes")
    return nodes


# identity: must be EQUAL before and after the scan, on every node
IDENTITY_STATS = [
    "rocksdb_master_id",
    "rocksdb_copy_id",
    "rocksdb_latest_sequence_number",
]
# epoch: rocksdb_rebuilt_from_epoch, falling back to rocksdb_source_epoch
# (PromotionEvidence.parseStats)
# mutation counters: equal before and after (a moved counter = a change
# during the scan; expire_reaped also moves when the dump itself reaps an
# expired key on a master — the scan is then invalid and is rerun)
MUTATION_STATS = [
    "cmd_set", "delete_hits", "delete_misses", "touch_hits", "touch_misses",
    "incr_hits", "incr_misses", "decr_hits", "decr_misses", "cas_hits",
    "cas_misses", "cas_badval", "curr_items", "rocksdb_expire_reaped",
]
LOSS_PREFIXES = ("forward_dropped_", "forward_failed_", "forward_missing_")


def epoch_of(stats):
    return stats.get("rocksdb_rebuilt_from_epoch") or stats.get("rocksdb_source_epoch")


def boot_of(stats):
    return int(stats["time"]) - int(stats["uptime"])


def loss_of(stats):
    n = int(stats["proxy_write_dropped"])
    for k, v in stats.items():
        if k.startswith("cluster_replication[") and k.endswith("]"):
            inner = k[len("cluster_replication["):-1]
            if inner.startswith(LOSS_PREFIXES) or inner == "seed_failed":
                n += int(v)
    return n


def same_process(a, b):
    return a["pod_uid"] == b["pod_uid"] and abs(boot_of(a["stats"]) - boot_of(b["stats"])) <= 2


def scan_stability(side, pre, post, problems):
    """Every node identical in identity, position and mutation counters
    between pre and post; appends to problems."""
    if set(pre) != set(post):
        problems.append(f"{side}: node set changed during the scan ({sorted(pre)} → {sorted(post)})")
        return
    for pod in sorted(pre):
        a, b = pre[pod], post[pod]
        try:
            if not same_process(a, b):
                problems.append(f"{side} {pod}: restarted or replaced during the scan")
                continue
            for name in IDENTITY_STATS + MUTATION_STATS:
                if name not in a["stats"] or name not in b["stats"]:
                    problems.append(f"{side} {pod}: {name} not reported (cannot show it unchanged)")
                elif a["stats"][name] != b["stats"][name]:
                    problems.append(f"{side} {pod}: {name} changed during the scan ({a['stats'][name]} → {b['stats'][name]})")
            if epoch_of(a["stats"]) is None or epoch_of(a["stats"]) != epoch_of(b["stats"]):
                problems.append(f"{side} {pod}: copy epoch missing or changed during the scan")
        except (KeyError, ValueError) as e:
            problems.append(f"{side} {pod}: unreadable stat ({e})")


def scan_window(pre, post):
    """[earliest server time at pre, latest server time at post] of a side."""
    return (min(int(n["stats"]["time"]) for n in pre.values()),
            max(int(n["stats"]["time"]) for n in post.values()))


def clock_offset(snaps):
    """Largest |server time - capture time| seen (server clock vs the
    capturing host's clock), +1 s for the server's 1 s timestamp."""
    worst = 0
    for nodes in snaps:
        for n in nodes.values():
            worst = max(worst, abs(int(n["stats"]["time"]) - n["captured_at"]))
    return worst + 1


def attempt_loss(baseline, post, problems):
    """Loss counted on the source over the whole attempt; None if unknown."""
    if set(baseline) != set(post):
        problems.append(f"attempt: source masters differ from the baseline ({sorted(baseline)} → {sorted(post)}) — loss over the attempt is unknown")
        return None
    total = 0
    for pod in sorted(baseline):
        a, b = baseline[pod], post[pod]
        try:
            if a["stats"].get("cluster_replication") == "on":
                problems.append(f"attempt: the baseline of {pod} was read while replication was already on")
                return None
            if not same_process(a, b):
                problems.append(f"attempt: {pod} restarted or was replaced since the baseline — its counters cannot be compared")
                return None
            la, lb = loss_of(a["stats"]), loss_of(b["stats"])
            if lb < la:
                problems.append(f"attempt: {pod} loss counters went down ({la} → {lb})")
                return None
            total += lb - la
            sc_a = int(a["stats"].get("cluster_replication[seed_completed]", "0"))
            sc_b = int(b["stats"].get("cluster_replication[seed_completed]", "0"))
            state = b["stats"].get("cluster_replication_seed", "none")
            if not (sc_b > sc_a and state.startswith("completed_")):
                problems.append(f"attempt: {pod} did not complete a seed during this attempt (state {state}, seed_completed {sc_a} → {sc_b})")
                return None
        except (KeyError, ValueError) as e:
            problems.append(f"attempt: {pod} unreadable ({e})")
            return None
    return total


# ---------------------------------------------------------------- dump ----


class StreamError(Exception):
    pass


def read_dump(path, label):
    """Yield (key bytes, flag, version, expire, value bytes), streaming.
    Raises StreamError on any framing defect, error reply, unsorted or
    duplicate key, or a missing END."""
    prev = None
    with open(path, "rb") as f:
        while True:
            line = f.readline()
            if not line:
                raise StreamError(f"{label}: stream ended without END (truncated)")
            if not line.endswith(b"\r\n"):
                raise StreamError(f"{label}: header line not terminated by CRLF: {line[:80]!r}")
            head = line[:-2]
            if head == b"END":
                if f.read(1):
                    raise StreamError(f"{label}: data after END")
                return
            if head.startswith((b"SERVER_ERROR", b"CLIENT_ERROR", b"ERROR")):
                raise StreamError(f"{label}: the server answered {head[:80]!r}")
            parts = head.split(b" ")
            if len(parts) != 6 or parts[0] != b"VALUE":
                raise StreamError(f"{label}: not a dump item header: {head[:80]!r}")
            key = parts[1]
            try:
                flag, size, version, expire = (int(x) for x in parts[2:])
            except ValueError:
                raise StreamError(f"{label}: non-numeric field in {head[:80]!r}")
            if min(flag, size, version, expire) < 0:
                raise StreamError(f"{label}: negative field in {head[:80]!r}")
            data = f.read(size + 2)
            if len(data) != size + 2 or data[-2:] != b"\r\n":
                raise StreamError(f"{label}: value of {key!r} truncated or not CRLF-terminated")
            if prev is not None and key <= prev:
                kind = "duplicate" if key == prev else "unsorted"
                raise StreamError(f"{label}: {kind} key {key!r} after {prev!r} (needs a RocksDB bytewise-ordered dump)")
            prev = key
            yield key, flag, version, expire, data[:-2]


def merged(paths, side):
    """Merge one side's partition streams in key order; a key in two
    partition streams is a duplicate (StreamError)."""
    streams = [read_dump(p, f"{side} dump {p}") for p in paths]
    prev = None
    for item in heapq.merge(*streams, key=lambda t: t[0]):
        if prev is not None and item[0] == prev:
            raise StreamError(f"{side}: key {item[0]!r} appears in two partition streams")
        prev = item[0]
        yield item


# ------------------------------------------------------------- compare ----


def compare(src_items, dst_items, src_window, dst_window, skew, keep=50):
    """Merge-join two key-ordered streams. Returns counts and the first
    `keep` entries of each difference class."""
    res = {"compared": 0, "missing": 0, "extra": 0, "different": 0, "indeterminate": 0,
           "samples": {"missing": [], "extra": [], "different": [], "indeterminate": []}}

    def note(kind, entry):
        res[kind] += 1
        if len(res["samples"][kind]) < keep:
            res["samples"][kind].append(entry)

    def one_sided(item, other_window, kind):
        key, _flag, _ver, expire, _v = item
        k = key.decode("utf-8", "backslashreplace")
        if expire == 0 or expire > other_window[1] + skew:
            note(kind, {"key": k, "expire": expire})
        else:
            note("indeterminate", {"key": k, "expire": expire, "on": "source" if kind == "missing" else "destination",
                                   "why": f"expires at {expire}, within the other side's scan window ending {other_window[1]} (+{skew} s skew): it may have expired there before it was read"})

    s, d = next(src_items, None), next(dst_items, None)
    while s is not None or d is not None:
        if d is None or (s is not None and s[0] < d[0]):
            one_sided(s, dst_window, "missing")
            s = next(src_items, None)
        elif s is None or d[0] < s[0]:
            one_sided(d, src_window, "extra")
            d = next(dst_items, None)
        else:
            res["compared"] += 1
            diffs = []
            if s[4] != d[4]:
                diffs.append(f"value ({len(s[4])} vs {len(d[4])} bytes)")
            if s[1] != d[1]:
                diffs.append(f"flags {s[1]} vs {d[1]}")
            if s[3] != d[3]:
                diffs.append(f"expire {s[3]} vs {d[3]}")
            if s[2] != d[2]:
                diffs.append(f"version {s[2]} vs {d[2]}")
            if diffs:
                note("different", {"key": s[0].decode("utf-8", "backslashreplace"), "fields": diffs})
            s, d = next(src_items, None), next(dst_items, None)
    return res


def node_binding(pod, n):
    st = n["stats"]
    return ",".join([pod, n["pod_uid"], str(boot_of(st)), st["rocksdb_master_id"], st["rocksdb_copy_id"],
                     epoch_of(st) or "", st["rocksdb_latest_sequence_number"]])


def binding_line(attempt_id, src_post, dst_post):
    """Canonical: attempt=<id>|src=<node>;..|dst=<node>;.. (nodes sorted by
    pod; node = pod,uid,start,master_id,copy_id,epoch,sequence). The same
    format is parsed by the operator's pure check (Migration/Types.lean)."""
    src = ";".join(node_binding(p, src_post[p]) for p in sorted(src_post))
    dst = ";".join(node_binding(p, dst_post[p]) for p in sorted(dst_post))
    return f"attempt={attempt_id}|src={src}|dst={dst}"


def verify(args):
    report = {"verdict": "UNKNOWN", "problems": [], "attempt_loss": None, "comparison": None,
              "note": "reports and refuses only; changes nothing"}
    problems = report["problems"]
    try:
        src_pre, src_post = load_snapshot(args.src_pre), load_snapshot(args.src_post)
        dst_pre, dst_post = load_snapshot(args.dst_pre), load_snapshot(args.dst_post)
        baseline = load_snapshot(args.attempt_baseline)
    except (OSError, ValueError, KeyError) as e:
        problems.append(f"snapshot unreadable: {e}")
        return report, 2
    scan_stability("source", src_pre, src_post, problems)
    scan_stability("destination", dst_pre, dst_post, problems)
    if len(args.src_dump) != len(src_pre):
        problems.append(f"source: {len(args.src_dump)} dump streams for {len(src_pre)} partition masters")
    if len(args.dst_dump) != len(dst_pre):
        problems.append(f"destination: {len(args.dst_dump)} dump streams for {len(dst_pre)} partition masters")
    loss = attempt_loss(baseline, src_post, problems)
    report["attempt_loss"] = loss
    try:
        src_w, dst_w = scan_window(src_pre, src_post), scan_window(dst_pre, dst_post)
        skew = clock_offset([src_pre, src_post, dst_pre, dst_post]) * 2 + args.extra_skew
    except (KeyError, ValueError) as e:
        problems.append(f"server time unreadable: {e}")
        return report, 2
    report["windows"] = {"source": src_w, "destination": dst_w, "skew_s": skew}
    try:
        report["binding"] = binding_line(args.attempt_id, src_post, dst_post)
    except KeyError as e:
        problems.append(f"binding: identity stat missing ({e})")
    try:
        cmp = compare(merged(args.src_dump, "source"), merged(args.dst_dump, "destination"), src_w, dst_w, skew)
    except (StreamError, OSError) as e:
        problems.append(f"stream: {e}")
        return report, 2
    report["comparison"] = cmp
    definite = cmp["missing"] + cmp["extra"] + cmp["different"]
    if loss:
        # counted loss is known regardless of this scan's validity
        problems.append(f"attempt: {loss} writes counted as lost on the source during this attempt")
        report["verdict"] = "DIFFERENT"
        return report, 1
    if problems or loss is None:
        # differences from an invalid scan may be artifacts of the change
        # during it: listed, but the verdict is UNKNOWN (refused all the same)
        return report, 2
    if definite > 0:
        report["verdict"] = "DIFFERENT"
        return report, 1
    if cmp["indeterminate"] > 0:
        problems.append(f"{cmp['indeterminate']} keys indeterminate near expiry — no zero-difference claim")
        return report, 2
    report["verdict"] = "MATCH"
    return report, 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src-dump", action="append", required=True)
    ap.add_argument("--dst-dump", action="append", required=True)
    for n in ("src-pre", "src-post", "dst-pre", "dst-post", "attempt-baseline"):
        ap.add_argument(f"--{n}", required=True)
    ap.add_argument("--attempt-id", required=True,
                    help="the FlareMigration's status.attemptBaseline, verbatim (binds the result to this attempt)")
    ap.add_argument("--extra-skew", type=int, default=0, help="seconds added to the measured clock skew bound")
    ap.add_argument("--report", help="write the JSON report here (default: stdout)")
    args = ap.parse_args(argv)
    report, code = verify(args)
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.report:
        with open(args.report, "w") as f:
            f.write(text + "\n")
    else:
        print(text)
    print(f"verdict: {report['verdict']} — cutover {'MAY proceed (human approval still required)' if code == 0 else 'REFUSED'}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
