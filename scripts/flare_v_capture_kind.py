#!/usr/bin/env python3
"""CI-ONLY capture for verification V on a kind cluster (refuses any other
kube context). Not approved for any real environment: capturing a live
cluster is an operational decision (docs/review-cross-cluster-2026-10-11.md
§12).

For one side (source or destination) and its partition master pods:
  1. pre  — every pod's `stats` reply + pod UID + local capture time
  2. per pod: `repl_snapshot` (point-in-time checkpoint stream; no reap, no
     iteration slot, no lock — see flare_snapshot_receive.py for its costs)
     received and CRC-checked on this host, copied into the pod's /tmp and
     decoded there with `flared --dump-checkpoint` (same flared build) into
     the `dump` framing; the copy is removed afterwards
  3. post — every pod's `stats` reply again
Writes <out>/pre.json, <out>/post.json, <out>/<pod>.dump — the inputs of
scripts/flare_verify_copy.py. Any failure exits non-zero (no partial set).
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STATS = ("exec 3<>/dev/tcp/localhost/12121; printf 'stats\\r\\n' >&3; "
         "timeout 5 bash -c 'while IFS= read -r l; do printf \"%s\\n\" \"$l\"; "
         "case \"$l\" in END*) break;; esac; done' <&3")
# `quit` after the op: flared closes the connection once the stream is sent
SNAP = ("exec 3<>/dev/tcp/localhost/12121; printf 'repl_snapshot\\r\\nquit\\r\\n' >&3; "
        "timeout 120 cat <&3")


def kubectl(*args, **kw):
    return subprocess.run(["kubectl", *args], check=True, capture_output=True, **kw)


def snapshot(ns, pods):
    nodes = []
    for pod in pods:
        uid = kubectl("get", "pod", pod, "-n", ns, "-o", "jsonpath={.metadata.uid}").stdout.decode().strip()
        raw = kubectl("exec", pod, "-n", ns, "--", "bash", "-c", STATS).stdout.decode()
        nodes.append({"pod": pod, "pod_uid": uid, "captured_at": int(time.time()), "stats": raw})
    return {"nodes": nodes}


def capture_pod(ns, pod, out_path):
    with tempfile.TemporaryDirectory() as d:
        cp_dir = os.path.join(d, "cp")
        os.mkdir(cp_dir)
        snap = subprocess.Popen(["kubectl", "exec", pod, "-n", ns, "--", "bash", "-c", SNAP], stdout=subprocess.PIPE)
        recv = subprocess.run([sys.executable, os.path.join(HERE, "flare_snapshot_receive.py"), "--out", cp_dir],
                              stdin=snap.stdout, capture_output=True)
        snap.stdout.close()
        snap.wait(timeout=180)
        if recv.returncode != 0:
            raise RuntimeError(f"{pod}: snapshot receive failed: {recv.stderr.decode().strip()}")
        info = json.loads(recv.stdout)
        remote = f"/tmp/vcap-{int(time.time() * 1000)}"
        kubectl("cp", cp_dir, f"{ns}/{pod}:{remote}")
        try:
            dec = subprocess.run(["kubectl", "exec", pod, "-n", ns, "--", "flared", "--dump-checkpoint", remote],
                                 capture_output=True)
        finally:
            subprocess.run(["kubectl", "exec", pod, "-n", ns, "--", "rm", "-rf", remote], capture_output=True)
        if dec.returncode != 0:
            raise RuntimeError(f"{pod}: --dump-checkpoint failed: {dec.stderr.decode().strip()[-400:]}")
        with open(out_path, "wb") as f:
            f.write(dec.stdout)
        info["decode"] = dec.stderr.decode().strip().splitlines()[-1:] or [""]
        return info


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ns", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--stats-only", action="store_true",
                    help="write only <out>/stats.json (e.g. the attempt baseline, before replication is enabled)")
    ap.add_argument("pods", nargs="+")
    args = ap.parse_args(argv)
    ctx = subprocess.run(["kubectl", "config", "current-context"], capture_output=True).stdout.decode().strip()
    if not ctx.startswith("kind-"):
        print(f"refused: kube context {ctx!r} is not a kind cluster (CI-only capture)", file=sys.stderr)
        return 3
    os.makedirs(args.out, exist_ok=True)
    if args.stats_only:
        try:
            j = snapshot(args.ns, args.pods)
        except subprocess.CalledProcessError as e:
            print(f"stats FAILED: {e}", file=sys.stderr)
            return 2
        with open(os.path.join(args.out, "stats.json"), "w") as f:
            json.dump(j, f)
        return 0
    try:
        pre = snapshot(args.ns, args.pods)
        infos = {p: capture_pod(args.ns, p, os.path.join(args.out, f"{p}.dump")) for p in args.pods}
        post = snapshot(args.ns, args.pods)
    except (subprocess.CalledProcessError, RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        err = getattr(e, "stderr", b"") or b""
        print(f"capture FAILED: {e} {err.decode(errors='replace')[-400:] if isinstance(err, bytes) else err}",
              file=sys.stderr)
        return 2
    for name, j in (("pre.json", pre), ("post.json", post)):
        with open(os.path.join(args.out, name), "w") as f:
            json.dump(j, f)
    print(json.dumps(infos, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
