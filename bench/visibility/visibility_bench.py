#!/usr/bin/env python3
"""Replica-visibility benchmark common to Redis and flare (WSTR-0).

Measures, with ONE monotonic clock in one process, the time from SENDING a
uniquely marked write to the primary/master until the marker is first
observed in the replica's data. This is an END-TO-END VISIBILITY measurement:
it includes network, scheduling and probe cadence; it is not commit-to-apply.
Client write latency (send -> ack) is reported separately, so a slower
primary cannot make replication look faster.

Load is OPEN-LOOP: writes are issued on a fixed schedule whether or not
earlier writes were acknowledged or observed; the scheduler's own lag is
reported, and a growing backlog marks the rate as failed even if the
successful samples look fast. Timeouts and errors are counted, never turned
into zero-latency samples.

Protocols: memcached text (flare) and RESP (Redis). Only SET/GET are used.
The harness does NOT decide whether a flare replica served a read locally:
the orchestrator must prove it (e.g. the master's cmd_get unchanged across a
run) and record the result next to this output.

Python standard library only. `--self-test` runs against in-process fake
servers with a known replica delay to check the timing logic.
"""

import argparse
import asyncio
import json
import os
import platform
import random
import socket
import string
import sys
import time

NS = 1_000_000_000


def now_ns():
    return time.monotonic_ns()


# ---------------------------------------------------------------- protocols

class Proto:
    """One persistent connection speaking memcache text or RESP."""

    def __init__(self, kind, reader, writer):
        self.kind = kind
        self.r = reader
        self.w = writer

    @classmethod
    async def open(cls, kind, host, port):
        r, w = await asyncio.open_connection(host, port)
        sock = w.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return cls(kind, r, w)

    def encode_set(self, key, value):
        if self.kind == "memcache":
            return b"set %s 0 0 %d\r\n%s\r\n" % (key, len(value), value)
        return b"*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n" % (len(key), key, len(value), value)

    def encode_get(self, key):
        if self.kind == "memcache":
            return b"get %s\r\n" % key
        return b"*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n" % (len(key), key)

    async def read_set_reply(self):
        line = await self.r.readline()
        if not line:
            raise ConnectionError("closed")
        if self.kind == "memcache":
            return line == b"STORED\r\n"
        return line == b"+OK\r\n"

    async def read_get_reply(self):
        """Return the value bytes, or None for a miss."""
        line = await self.r.readline()
        if not line:
            raise ConnectionError("closed")
        if self.kind == "memcache":
            if line == b"END\r\n":
                return None
            if not line.startswith(b"VALUE "):
                raise ValueError("unexpected reply %r" % line[:60])
            n = int(line.split()[3])
            data = await self.r.readexactly(n + 2)
            end = await self.r.readline()
            if end != b"END\r\n":
                raise ValueError("unexpected terminator %r" % end[:60])
            return data[:-2]
        if line.startswith(b"$-1"):
            return None
        if not line.startswith(b"$"):
            raise ValueError("unexpected reply %r" % line[:60])
        n = int(line[1:-2])
        data = await self.r.readexactly(n + 2)
        return data[:-2]

    async def get(self, key):
        self.w.write(self.encode_get(key))
        await self.w.drain()
        return await self.read_get_reply()

    def close(self):
        try:
            self.w.close()
        except Exception:
            pass


# ---------------------------------------------------------------- stats

def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def summary_us(vals_ns):
    v = sorted(x / 1000.0 for x in vals_ns)
    return {
        "n": len(v),
        "p50_us": pct(v, 50), "p95_us": pct(v, 95), "p99_us": pct(v, 99),
        "max_us": v[-1] if v else None,
        "mean_us": (sum(v) / len(v)) if v else None,
    }


# ---------------------------------------------------------------- run

class Marker:
    __slots__ = ("i", "key", "value", "sched", "sent", "acked", "ack_ok",
                 "visible", "last_miss_sent", "probes", "timed_out")

    def __init__(self, i, key, value, sched):
        self.i = i
        self.key = key
        self.value = value
        self.sched = sched
        self.sent = None
        self.acked = None
        self.ack_ok = None
        self.visible = None
        self.last_miss_sent = None
        self.probes = 0
        self.timed_out = False


async def run_profile(args, profile):
    """profile: dict(kind=rate|idle|burst, rate, duration, warmup, count, gap)."""
    run_id = "".join(random.choice(string.ascii_lowercase) for _ in range(6))
    pad = args.value_size

    def make_value(i):
        head = b"%d:%s:" % (i, run_id.encode())
        return head + b"x" * max(0, pad - len(head))

    # schedule
    t0 = now_ns() + int(0.2 * NS)
    sched = []
    if profile["kind"] == "rate":
        total = int(profile["rate"] * (profile["warmup"] + profile["duration"]))
        step = NS / profile["rate"]
        sched = [t0 + int(i * step) for i in range(total)]
        warm_until = t0 + int(profile["warmup"] * NS)
    elif profile["kind"] == "idle":
        sched = [t0 + int(i * profile["gap"] * NS) for i in range(profile["count"])]
        warm_until = t0
    elif profile["kind"] == "burst":
        sched = [t0] * profile["count"]
        warm_until = t0
    else:
        raise ValueError(profile["kind"])

    markers = [Marker(i, b"vb:%s:%d" % (run_id.encode(), i), make_value(i), s) for i, s in enumerate(sched)]

    wconns = [await Proto.open(args.proto, args.write_host, args.write_port) for _ in range(args.writers)]
    oconns = [await Proto.open(args.proto, args.read_host, args.read_port) for _ in range(args.observers)]

    pending = [[] for _ in range(args.observers)]   # per observer, markers sent and not yet seen
    wake = [asyncio.Event() for _ in range(args.observers)]
    acks = [asyncio.Queue() for _ in range(args.writers)]
    errors = {"write": 0, "read": 0, "set_not_stored": 0}
    sched_lag = []
    backlog = []
    done_sending = asyncio.Event()
    timeout_ns = int(args.timeout * NS)

    async def ack_reader(k):
        c = wconns[k]
        q = acks[k]
        while True:
            m = await q.get()
            if m is None:
                return
            try:
                ok = await c.read_set_reply()
            except Exception:
                errors["write"] += 1
                m.ack_ok = False
                continue
            m.acked = now_ns()
            m.ack_ok = ok
            if not ok:
                errors["set_not_stored"] += 1

    async def sender():
        for m in markers:
            delay = m.sched - now_ns()
            if delay > 0:
                await asyncio.sleep(delay / NS)
            k = m.i % args.writers
            m.sent = now_ns()
            sched_lag.append(m.sent - m.sched)
            o = m.i % args.observers
            pending[o].append(m)
            wake[o].set()
            try:
                wconns[k].w.write(wconns[k].encode_set(m.key, m.value))
                await acks[k].put(m)
                await wconns[k].w.drain()
            except Exception:
                errors["write"] += 1
        done_sending.set()
        for q in acks:
            await q.put(None)

    async def observer(o):
        c = oconns[o]
        lst = pending[o]
        while True:
            if not lst:
                if done_sending.is_set():
                    return
                wake[o].clear()
                try:
                    await asyncio.wait_for(wake[o].wait(), 0.05)
                except asyncio.TimeoutError:
                    pass
                continue
            # probe every pending marker once per sweep, oldest first
            for m in list(lst):
                t_probe = now_ns()
                if t_probe - m.sent > timeout_ns:
                    m.timed_out = True
                    lst.remove(m)
                    continue
                try:
                    v = await c.get(m.key)
                except Exception:
                    errors["read"] += 1
                    await asyncio.sleep(0.01)
                    try:
                        c.close()
                        c = oconns[o] = await Proto.open(args.proto, args.read_host, args.read_port)
                    except Exception:
                        pass
                    continue
                m.probes += 1
                if v == m.value:
                    m.visible = now_ns()
                    lst.remove(m)
                else:
                    m.last_miss_sent = t_probe

    async def backlog_sampler():
        while not (done_sending.is_set() and all(not p for p in pending)):
            t = now_ns()
            outstanding = sum(len(p) for p in pending)
            backlog.append((t, outstanding))
            await asyncio.sleep(0.1)

    tasks = [asyncio.create_task(ack_reader(k)) for k in range(args.writers)]
    tasks += [asyncio.create_task(observer(o)) for o in range(args.observers)]
    bl = asyncio.create_task(backlog_sampler())
    await sender()
    await asyncio.gather(*tasks)
    bl.cancel()
    for c in wconns + oconns:
        c.close()

    measured = [m for m in markers if m.sched >= warm_until]
    vis = [m.visible - m.sent for m in measured if m.visible is not None]
    vis_lo = [(m.last_miss_sent - m.sent) if m.last_miss_sent is not None else 0
              for m in measured if m.visible is not None]
    ack = [m.acked - m.sent for m in measured if m.acked is not None and m.ack_ok]
    timeouts = sum(1 for m in measured if m.timed_out)
    unobserved = sum(1 for m in measured if m.visible is None and not m.timed_out)
    probes = [m.probes for m in measured if m.visible is not None]
    if measured:
        span = (max(m.sent for m in measured) - min(m.sent for m in measured)) / NS
        achieved = (len(measured) - 1) / span if span > 0 else None
    else:
        achieved = None
    # backlog growth: compare mean outstanding in the last third vs the first
    # third of the sending window
    bl_send = [b for b in backlog if b[0] <= (markers[-1].sent if markers else 0)]
    growing = None
    if len(bl_send) >= 9:
        third = len(bl_send) // 3
        first = sum(b[1] for b in bl_send[:third]) / third
        last = sum(b[1] for b in bl_send[-third:]) / third
        growing = last > max(2 * first, first + 10)
    return {
        "profile": profile,
        "markers_total": len(markers),
        "markers_measured": len(measured),
        "visible": len(vis),
        "timeouts": timeouts,
        "unobserved": unobserved,
        "errors": errors,
        "achieved_write_rate": achieved,
        "write_ack": summary_us(ack),
        "visibility_upper": summary_us(vis),
        "visibility_lower": summary_us(vis_lo),
        "probes_per_sample": {"mean": (sum(probes) / len(probes)) if probes else None, "max": max(probes) if probes else None},
        "scheduler_lag": summary_us(sched_lag),
        "backlog_max": max((b[1] for b in backlog), default=0),
        "backlog_growing": growing,
    }


async def probe_floor(args, n=500):
    """Round-trip time of a GET miss on the read endpoint: the probe cadence
    and therefore the measurement floor/resolution."""
    c = await Proto.open(args.proto, args.read_host, args.read_port)
    rtts = []
    for i in range(n):
        t = now_ns()
        await c.get(b"vb:floor:none")
        rtts.append(now_ns() - t)
    c.close()
    return summary_us(rtts)


PROFILES = {
    "idle": {"kind": "idle", "count": 100, "gap": 0.3},
    "low": {"kind": "rate", "rate": 100, "duration": 20, "warmup": 5},
    "normal": {"kind": "rate", "rate": 500, "duration": 20, "warmup": 5},
    "peak": {"kind": "rate", "rate": 2000, "duration": 20, "warmup": 5},
    "burst": {"kind": "burst", "count": 2000},
    "sat-4000": {"kind": "rate", "rate": 4000, "duration": 10, "warmup": 3},
    "sat-8000": {"kind": "rate", "rate": 8000, "duration": 10, "warmup": 3},
}


async def main_async(args):
    out = {
        "harness": "visibility_bench.py",
        "measurement": "end-to-end visibility: write SEND to first replica observation, one monotonic clock; NOT commit-to-apply",
        "label": args.label,
        "proto": args.proto,
        "write": "%s:%d" % (args.write_host, args.write_port),
        "read": "%s:%d" % (args.read_host, args.read_port),
        "value_size": args.value_size, "writers": args.writers, "observers": args.observers,
        "timeout_s": args.timeout,
        "env": {"python": sys.version.split()[0], "host": platform.node(), "cpus": os.cpu_count()},
        "floor_get_rtt": await probe_floor(args),
        "runs": [],
    }
    for rep in range(args.repeat):
        for name in args.profiles.split(","):
            p = dict(PROFILES[name])
            p["name"] = name
            p["repeat"] = rep
            res = await run_profile(args, p)
            out["runs"].append(res)
            print("# %s %s rep%d: vis p50/p99 %s/%s us, ack p99 %s us, timeouts %d, backlog growing %s, achieved %s/s"
                  % (args.label, name, rep, fmt(res["visibility_upper"]["p50_us"]), fmt(res["visibility_upper"]["p99_us"]),
                     fmt(res["write_ack"]["p99_us"]), res["timeouts"], res["backlog_growing"], fmt(res["achieved_write_rate"])),
                  file=sys.stderr)
    return out


def fmt(x):
    return "-" if x is None else ("%.0f" % x)


# ---------------------------------------------------------------- self-test

async def self_test():
    """Fake primary/replica in-process: the replica learns each SET after a
    fixed delay. The measured visibility must sit at or above that delay, and
    a replica that never learns must produce timeouts, not samples."""
    store_p, store_r = {}, {}
    delay = 0.004

    async def handle(reader, writer, store, primary, kind):
        try:
            while True:
                line = await reader.readline()
                if not line:
                    return
                if kind == "memcache":
                    parts = line.split()
                    if parts[0] == b"set":
                        n = int(parts[4])
                        data = (await reader.readexactly(n + 2))[:-2]
                        store[parts[1]] = data
                        if primary:
                            asyncio.get_running_loop().call_later(delay, store_r.__setitem__, parts[1], data)
                        writer.write(b"STORED\r\n")
                    elif parts[0] == b"get":
                        v = store.get(parts[1])
                        if v is None:
                            writer.write(b"END\r\n")
                        else:
                            writer.write(b"VALUE %s 0 %d\r\n%s\r\nEND\r\n" % (parts[1], len(v), v))
                else:
                    n = int(line[1:-2])
                    items = []
                    for _ in range(n):
                        ln = await reader.readline()
                        items.append((await reader.readexactly(int(ln[1:-2]) + 2))[:-2])
                    if items[0] == b"SET":
                        store[items[1]] = items[2]
                        if primary:
                            asyncio.get_running_loop().call_later(delay, store_r.__setitem__, items[1], items[2])
                        writer.write(b"+OK\r\n")
                    else:
                        v = store.get(items[1])
                        writer.write(b"$-1\r\n" if v is None else b"$%d\r\n%s\r\n" % (len(v), v))
                await writer.drain()
        except (ConnectionError, asyncio.IncompleteReadError):
            return

    ok = True
    for kind in ("memcache", "redis"):
        store_p.clear(); store_r.clear()
        sp = await asyncio.start_server(lambda r, w: handle(r, w, store_p, True, kind), "127.0.0.1", 0)
        sr = await asyncio.start_server(lambda r, w: handle(r, w, store_r, False, kind), "127.0.0.1", 0)
        pp = sp.sockets[0].getsockname()[1]
        rp = sr.sockets[0].getsockname()[1]
        a = argparse.Namespace(proto=kind, write_host="127.0.0.1", write_port=pp, read_host="127.0.0.1", read_port=rp,
                               value_size=100, writers=2, observers=2, timeout=1.0)
        res = await run_profile(a, {"kind": "rate", "rate": 200, "duration": 1, "warmup": 0.2, "name": "t"})
        p50 = res["visibility_upper"]["p50_us"]
        lo = res["visibility_lower"]["p50_us"]
        good = res["visible"] == res["markers_measured"] and res["timeouts"] == 0 and p50 is not None \
            and p50 >= delay * 1e6 and p50 < delay * 1e6 + 20000 and lo is not None and lo <= p50
        print("self-test %s: visible %d/%d, vis p50 %.0f us (injected %.0f us), lower p50 %.0f us -> %s"
              % (kind, res["visible"], res["markers_measured"], p50 or -1, delay * 1e6, lo or -1, "ok" if good else "FAIL"))
        ok = ok and good
        # a replica that never learns: every sample must time out
        store_r_frozen = {}
        sr.close()
        sr2 = await asyncio.start_server(lambda r, w: handle(r, w, store_r_frozen, False, kind), "127.0.0.1", 0)
        a.read_port = sr2.sockets[0].getsockname()[1]
        a.timeout = 0.3
        res2 = await run_profile(a, {"kind": "idle", "count": 5, "gap": 0.05, "name": "t2"})
        good2 = res2["visible"] == 0 and res2["timeouts"] == res2["markers_measured"] and res2["visibility_upper"]["n"] == 0
        print("self-test %s: frozen replica -> visible %d, timeouts %d/%d -> %s"
              % (kind, res2["visible"], res2["timeouts"], res2["markers_measured"], "ok" if good2 else "FAIL"))
        ok = ok and good2
        sp.close(); sr2.close()
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--proto", choices=["memcache", "redis"])
    ap.add_argument("--write", help="host:port of the primary/master")
    ap.add_argument("--read", help="host:port of the replica (must serve locally)")
    ap.add_argument("--label", default="")
    ap.add_argument("--profiles", default="idle,low,normal,peak,burst,sat-4000,sat-8000")
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--value-size", type=int, default=100)
    ap.add_argument("--writers", type=int, default=4)
    ap.add_argument("--observers", type=int, default=4)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--out", default="-")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(0 if asyncio.run(self_test()) else 1)
    if not (args.proto and args.write and args.read):
        ap.error("--proto, --write and --read are required")
    args.write_host, wp = args.write.rsplit(":", 1)
    args.read_host, rp = args.read.rsplit(":", 1)
    args.write_port, args.read_port = int(wp), int(rp)
    out = asyncio.run(main_async(args))
    text = json.dumps(out, indent=1)
    if args.out == "-":
        print(text)
    else:
        with open(args.out, "w") as f:
            f.write(text)


if __name__ == "__main__":
    main()
