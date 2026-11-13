#!/usr/bin/env python3
"""CI-ONLY capture for verification V on a kind cluster (refuses any other
kube context). Not approved for any real environment: capturing a live
cluster is an operational decision (docs/review-cross-cluster-2026-10-11.md
§12).

For one side (source or destination) and its partition master pods:
  1. pre  — every pod's `stats` reply + pod UID + local capture time
  2. per pod, ONE AT A TIME: `repl_snapshot 0 capture <deadline>` (point-in-
     time checkpoint stream; no reap, no iteration slot, no lock). flared
     guards it (see flare_snapshot_receive.py): refused before any pin when
     a rebuild runs there or free space < copy + reserve or unknown; bounded
     by a write-progress timeout and a total deadline; aborted on a drop
     below the reserve. The reply must acknowledge capture mode. Received
     and CRC-checked on this host, then decoded with `flared
     --dump-checkpoint` (same image) in a separate throwaway DECODER pod —
     never in the captured pod (no copy, CPU or memory on the master)
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
CAPTURE_DEADLINE_SEC = 120
SNAP = ("exec 3<>/dev/tcp/localhost/12121; "
        f"printf 'repl_snapshot 0 capture {CAPTURE_DEADLINE_SEC}\\r\\nquit\\r\\n' >&3; "
        f"timeout {CAPTURE_DEADLINE_SEC + 30} cat <&3")


def kubectl(*args, **kw):
    return subprocess.run(["kubectl", *args], check=True, capture_output=True, **kw)


def snapshot(ns, pods):
    nodes = []
    for pod in pods:
        uid = kubectl("get", "pod", pod, "-n", ns, "-o", "jsonpath={.metadata.uid}").stdout.decode().strip()
        raw = kubectl("exec", pod, "-n", ns, "--", "bash", "-c", STATS).stdout.decode()
        nodes.append({"pod": pod, "pod_uid": uid, "captured_at": int(time.time()), "stats": raw})
    return {"nodes": nodes}


def start_decoder(ns, like_pod):
    """A throwaway pod with the captured pod's image (same flared build), no
    data volume and small requests; decoding there keeps the copy, its CPU
    and its memory off the captured master."""
    spec = json.loads(kubectl("get", "pod", like_pod, "-n", ns, "-o", "json").stdout)
    c0 = [c for c in spec["spec"]["containers"] if c.get("name") == "flared"] or spec["spec"]["containers"]
    name = f"vcap-decoder-{int(time.time())}"
    pod = {"apiVersion": "v1", "kind": "Pod",
           "metadata": {"name": name, "namespace": ns, "labels": {"app": "vcap-decoder"}},
           "spec": {"restartPolicy": "Never", "terminationGracePeriodSeconds": 0,
                    "containers": [{"name": "decoder", "image": c0[0]["image"],
                                    "imagePullPolicy": c0[0].get("imagePullPolicy", "IfNotPresent"),
                                    "command": ["sleep", "3600"],
                                    "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}}}]}}
    kubectl("apply", "-f", "-", input=json.dumps(pod).encode())
    kubectl("wait", "--for=condition=Ready", f"pod/{name}", "-n", ns, "--timeout=120s")
    return name


def stop_decoder(ns, name):
    subprocess.run(["kubectl", "delete", "pod", name, "-n", ns, "--wait=false", "--grace-period=0"],
                   capture_output=True)


def capture_pod(ns, pod, out_path, decoder):
    with tempfile.TemporaryDirectory() as d:
        cp_dir = os.path.join(d, "cp")
        os.mkdir(cp_dir)
        snap = subprocess.Popen(["kubectl", "exec", pod, "-n", ns, "--", "bash", "-c", SNAP], stdout=subprocess.PIPE)
        recv = subprocess.run([sys.executable, os.path.join(HERE, "flare_snapshot_receive.py"), "--out", cp_dir,
                               "--require-capture"],
                              stdin=snap.stdout, capture_output=True)
        snap.stdout.close()
        snap.wait(timeout=CAPTURE_DEADLINE_SEC + 60)
        if recv.returncode != 0:
            raise RuntimeError(f"{pod}: snapshot receive failed: {recv.stderr.decode().strip()}")
        info = json.loads(recv.stdout)
        remote = f"/tmp/vcap-{int(time.time() * 1000)}"
        kubectl("cp", cp_dir, f"{ns}/{decoder}:{remote}")
        try:
            dec = subprocess.run(["kubectl", "exec", decoder, "-n", ns, "--", "flared", "--dump-checkpoint", remote],
                                 capture_output=True)
        finally:
            subprocess.run(["kubectl", "exec", decoder, "-n", ns, "--", "rm", "-rf", remote], capture_output=True)
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
    decoder = None
    try:
        decoder = start_decoder(args.ns, args.pods[0])
        pre = snapshot(args.ns, args.pods)
        infos = {p: capture_pod(args.ns, p, os.path.join(args.out, f"{p}.dump"), decoder) for p in args.pods}
        post = snapshot(args.ns, args.pods)
    except (subprocess.CalledProcessError, RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        err = getattr(e, "stderr", b"") or b""
        print(f"capture FAILED: {e} {err.decode(errors='replace')[-400:] if isinstance(err, bytes) else err}",
              file=sys.stderr)
        return 2
    finally:
        if decoder:
            stop_decoder(args.ns, decoder)
    for name, j in (("pre.json", pre), ("post.json", post)):
        with open(os.path.join(args.out, name), "w") as f:
            json.dump(j, f)
    print(json.dumps(infos, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
