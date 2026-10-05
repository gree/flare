#!/usr/bin/env python3
"""Tabulate visibility_bench.py results: absolute values per arm, profile and
repeat, and flare-vs-Redis deltas. Applies NO tolerance: the tolerances are
for the reviewer to set. Usage: report.py <dir-with-*.json>"""

import glob
import json
import os
import sys

REF = "redis-aof"   # the durability profile closest to flare's WAL without per-write sync


def f(x):
    return "-" if x is None else ("%.0f" % x)


def load(d):
    arms = {}
    for p in sorted(glob.glob(os.path.join(d, "*.json"))):
        with open(p) as fh:
            data = json.load(fh)
        v = p[:-5] + ".validity.txt"
        data["validity"] = open(v).read().strip() if os.path.exists(v) else "(no validity record)"
        arms[data["label"]] = data
    return arms


def by_profile(arm):
    out = {}
    for r in arm["runs"]:
        out.setdefault(r["profile"]["name"], []).append(r)
    return out


def main():
    d = sys.argv[1]
    arms = load(d)
    if not arms:
        print("no results in %s" % d)
        return
    print("# Replica visibility baseline (WSTR-0)\n")
    print("End-to-end visibility = write SEND to first replica observation (upper bound of the probe")
    print("window), one monotonic clock; NOT commit-to-apply. Times in microseconds. CI kind numbers are")
    print("relative only. No tolerance is applied here.\n")
    print("## Arms\n")
    print("| arm | floor GET RTT p50/p99 | validity |")
    print("|---|---|---|")
    for k, a in arms.items():
        fl = a.get("floor_get_rtt", {})
        print("| %s | %s / %s | %s |" % (k, f(fl.get("p50_us")), f(fl.get("p99_us")), a["validity"].replace("|", "/")))
    print("\n## Results per profile and repeat\n")
    print("| arm | profile | rep | measured | visible | timeouts | vis p50 | vis p95 | vis p99 | vis max | vis-lower p99 | ack p99 | achieved/s | sched-lag p99 | backlog max | growing |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for k, a in arms.items():
        for name, runs in by_profile(a).items():
            for r in runs:
                v = r["visibility_upper"]
                print("| %s | %s | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s |" % (
                    k, name, r["profile"].get("repeat", 0), r["markers_measured"], r["visible"], r["timeouts"],
                    f(v["p50_us"]), f(v["p95_us"]), f(v["p99_us"]), f(v["max_us"]), f(r["visibility_lower"]["p99_us"]),
                    f(r["write_ack"]["p99_us"]), f(r["achieved_write_rate"]), f(r["scheduler_lag"]["p99_us"]),
                    r["backlog_max"], r["backlog_growing"]))
    if REF in arms:
        print("\n## Deltas vs %s (worst repeat per profile; flare − redis, and ratio)\n" % REF)
        print("| arm | profile | p95 Δ µs | p95 ratio | p99 Δ µs | p99 ratio | ack p99 Δ µs |")
        print("|---|---|---|---|---|---|---|")
        ref = by_profile(arms[REF])
        for k, a in arms.items():
            if k == REF or "floor" in k:
                continue
            for name, runs in by_profile(a).items():
                if name not in ref:
                    continue
                def worst(rs, key, q):
                    vals = [r[key][q] for r in rs if r[key][q] is not None]
                    return max(vals) if vals else None
                a95, r95 = worst(runs, "visibility_upper", "p95_us"), worst(ref[name], "visibility_upper", "p95_us")
                a99, r99 = worst(runs, "visibility_upper", "p99_us"), worst(ref[name], "visibility_upper", "p99_us")
                aa, ra = worst(runs, "write_ack", "p99_us"), worst(ref[name], "write_ack", "p99_us")
                d = lambda x, y: None if x is None or y is None else x - y
                q = lambda x, y: "-" if x is None or not y else "%.2f" % (x / y)
                print("| %s | %s | %s | %s | %s | %s | %s |" % (k, name, f(d(a95, r95)), q(a95, r95), f(d(a99, r99)), q(a99, r99), f(d(aa, ra))))


if __name__ == "__main__":
    main()
