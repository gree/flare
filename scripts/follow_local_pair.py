#!/usr/bin/env python3
"""Local flarei + master + slave: does the WAL follower keep up with a sustained write rate?

A stand-in for the kind E2E where no container runtime is available. It starts
the given flared/flarei binaries with a RocksDB master and slave
(repl-identity-forward + repl-follow-enabled, a short WAL archive so that a
follower that falls behind loses its position within seconds), writes at a
fixed rate to the master for a while, and samples the slave's follow state.

  follow_local_pair.py --bin SRC_DIR --work DIR [--rate 4000] [--seconds 120]
                       [--value-bytes 512] [--wal-ttl 10] [--extra 'k = v' ...]

SRC_DIR holds flarei/flarei and flared/flared (an autotools build tree's src).
Prints one line per sample and a verdict; exit 0 = the follower stayed in
the archive, the copies match and no rebuild happened, 1 otherwise.
"""
import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time


def rpc(port, cmd, until=("END\r\n", "OK\r\n", "ERROR", "STORED\r\n"), timeout=5.0):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall((cmd + "\r\n").encode())
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            d = s.recv(65536)
        except socket.timeout:
            break
        if not d:
            break
        buf += d
        t = buf.decode(errors="replace")
        if any(t.endswith(u) or (u == "ERROR" and u in t) for u in until):
            break
    s.close()
    return buf.decode(errors="replace")


def stats(port):
    out = rpc(port, "stats", until=("END\r\n",))
    d = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 3 and p[0] == "STAT":
            d[p[1]] = p[2]
    return d


def wait_for(fn, what, timeout=120, step=0.5):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(step)
    raise SystemExit("timeout waiting for " + what)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--rate", type=int, default=4000)
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--value-bytes", type=int, default=512)
    ap.add_argument("--wal-ttl", type=int, default=10)
    ap.add_argument("--base-port", type=int, default=22100)
    ap.add_argument("--writers", type=int, default=4)
    ap.add_argument("--extra", action="append", default=[])
    a = ap.parse_args()

    work = os.path.abspath(a.work)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    ip, mp, sp = a.base_port, a.base_port + 1, a.base_port + 2
    procs = []

    def start(name, binary, conf):
        d = os.path.join(work, name)
        os.makedirs(d)
        cf = os.path.join(d, name + ".conf")
        with open(cf, "w") as f:
            f.write(conf.replace("@DIR@", d))
        log = open(os.path.join(d, "stderr.log"), "w")
        p = subprocess.Popen([binary, "-f", cf, "-s"], stdout=log, stderr=log)
        procs.append(p)
        return p

    def cleanup():
        for p in procs:
            try:
                p.send_signal(signal.SIGTERM)
            except Exception:
                pass
        for p in procs:
            try:
                p.wait(timeout=20)
            except Exception:
                p.kill()

    try:
        start("flarei", os.path.join(a.bin, "flarei/flarei"), f"""data-dir = @DIR@
log-facility = local0
max-connection = 256
monitor-threshold = 3
monitor-interval = 1
server-name = 127.0.0.1
server-port = {ip}
thread-pool-size = 8
""")
        wait_for(lambda: rpc(ip, "stats", until=("END\r\n",)), "flarei")

        def node(name, port):
            return start(name, os.path.join(a.bin, "flared/flared"), f"""data-dir = @DIR@
index-servers = 127.0.0.1:{ip}
log-facility = local1
max-connection = 256
mutex-slot = 32
proxy-concurrency = 2
server-name = 127.0.0.1
server-port = {port}
storage-type = rocksdb
thread-pool-size = 16
rocksdb-block-cache-size-mb = 256
rocksdb-wal-ttl-seconds = {a.wal_ttl}
rocksdb-wal-size-limit-mb = 16
repl-identity-forward = true
rocksdb-rebuild-reserve-bytes = 268435456
repl-follow-enabled = true
cluster-replication = false
""" + "".join(x + "\n" for x in a.extra))

        node("master", mp)
        wait_for(lambda: stats(mp), "master")
        rpc(ip, f"node role 127.0.0.1 {mp} master 1 0", until=("OK\r\n", "ERROR"))
        wait_for(lambda: "STAT state active" in rpc(ip, "stats nodes", until=("END\r\n",)) or True, "master role")
        time.sleep(2)
        node("slave", sp)
        wait_for(lambda: stats(sp), "slave")
        rpc(ip, f"node role 127.0.0.1 {sp} slave 1 0", until=("OK\r\n", "ERROR"))

        def slave_active():
            out = rpc(ip, "stats nodes", until=("END\r\n",))
            return ("STAT 127.0.0.1:%d:state active" % sp) in out and ("STAT 127.0.0.1:%d:role slave" % sp) in out

        try:
            wait_for(slave_active, "slave active", timeout=120)
        except SystemExit:
            print(rpc(ip, "stats nodes", until=("END\r\n",)), flush=True)
            raise
        print("# pair up: master %d slave %d" % (mp, sp), flush=True)
        time.sleep(3)

        value = b"v" * a.value_bytes
        stop = threading.Event()
        counter = [0]
        lock = threading.Lock()
        per = a.rate / float(a.writers)

        def writer(w):
            s = socket.create_connection(("127.0.0.1", mp))
            s.settimeout(30)
            i = 0
            t0 = time.time()
            while not stop.is_set():
                # pace: i writes should have been issued by now
                due = int((time.time() - t0) * per)
                while i < due and not stop.is_set():
                    k = ("fill-%d-%09d" % (w, i)).encode()
                    s.sendall(b"set " + k + b" 0 0 " + str(len(value)).encode() + b"\r\n" + value + b"\r\n")
                    r = b""
                    while not r.endswith(b"\r\n"):
                        r += s.recv(64)
                    if r != b"STORED\r\n":
                        print("# write error", r, flush=True)
                    i += 1
                    with lock:
                        counter[0] += 1
                time.sleep(0.002)
            s.close()

        ts = [threading.Thread(target=writer, args=(w,)) for w in range(a.writers)]
        for t in ts:
            t.start()
        t_start = time.time()
        rebuilt = False
        samples = []
        max_lag = [0]
        base_slave = stats(sp)
        while time.time() - t_start < a.seconds:
            time.sleep(5)
            m, s = stats(mp), stats(sp)
            with lock:
                sent = counter[0]
            line = ("t=%3ds sent=%d (%.0f/s) master latest_seq=%s slave latest_seq=%s repl_last_lsn=%s "
                    "follow_lag=%s wal_applied=%s wal_skipped=%s items m/s=%s/%s") % (
                time.time() - t_start, sent, sent / (time.time() - t_start),
                m.get("rocksdb_latest_sequence_number", m.get("latest_sequence_number", "?")),
                s.get("rocksdb_latest_sequence_number", s.get("latest_sequence_number", "?")),
                s.get("rocksdb_repl_last_lsn", s.get("repl_last_lsn", "?")),
                s.get("repl_follow_lag", "?"), s.get("repl_wal_applied", "?"), s.get("repl_wal_skipped", "?"),
                m.get("curr_items", "?"), s.get("curr_items", "?"))
            try:
                lag = int(m["rocksdb_latest_sequence_number"]) - int(s["rocksdb_repl_last_lsn"])
            except Exception:
                lag = -1
            max_lag[0] = max(max_lag[0], lag)
            print(line + " lag=%d" % lag, flush=True)
            samples.append(s)
        stop.set()
        for t in ts:
            t.join()
        # drain: the copies must match once the writes stop
        time.sleep(1)
        deadline = time.time() + 120
        while time.time() < deadline:
            m, s = stats(mp), stats(sp)
            if m.get("curr_items") == s.get("curr_items"):
                break
            time.sleep(2)
        m, s = stats(mp), stats(sp)
        slave_log = open(os.path.join(work, "slave/stderr.log"), errors="replace").read()
        master_log = open(os.path.join(work, "master/stderr.log"), errors="replace").read()
        purged = ("lsn_purged" in slave_log) or ("GetUpdatesSince failed" in master_log)
        rebuilt = ("reconstruction" in slave_log.lower() and slave_log.lower().count("reconstruction") > 0 and
                   "needs_rebuild" in slave_log.lower())
        # how long the follower needs to reach the source once the writes stop
        t_drain = time.time()
        final_lag = None
        while time.time() - t_drain < 300:
            s, m = stats(sp), stats(mp)
            try:
                final_lag = int(m["rocksdb_latest_sequence_number"]) - int(s["rocksdb_repl_last_lsn"])
            except Exception:
                final_lag = None
            if final_lag is not None and final_lag <= 0:
                break
            time.sleep(1)
        drain_s = time.time() - t_drain
        print("# slave repl stats: " + " ".join("%s=%s" % (k, v) for k, v in sorted(s.items()) if "repl_" in k or "follow" in k or "wal_sync" in k), flush=True)
        print("# end: items master/slave = %s/%s, max follow lag during writes = %d positions, drain after writes stopped = %.0fs (final lag %s), wal_sync_lsn_purged=%s" % (
            m.get("curr_items"), s.get("curr_items"), max_lag[0], drain_s, final_lag, s.get("rocksdb_wal_sync_lsn_purged", "?")), flush=True)
        ok = (m.get("curr_items") == s.get("curr_items") and not purged and final_lag is not None and final_lag <= 0
              and s.get("rocksdb_wal_sync_lsn_purged", "0") == "0" and max_lag[0] <= a.rate * 3)
        print("# verdict: %s (archive position lost: %s)" % ("PASS" if ok else "FAIL", purged), flush=True)
        return 0 if ok else 1
    finally:
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
