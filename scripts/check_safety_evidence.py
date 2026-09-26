#!/usr/bin/env python3
"""Validate the safety register without executing its commands or fetching URLs."""

import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys

REGISTER = "docs/safety-evidence.json"
STPA = "docs/STPA-node-state.md"
BEGIN = "<!-- safety-evidence:begin -->"
END = "<!-- safety-evidence:end -->"
SHA = re.compile(r"[0-9a-f]{40}")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def date(value):
    require(isinstance(value, str), "date must be an ISO date")
    require(datetime.date.fromisoformat(value).isoformat() == value,
            "date must be YYYY-MM-DD")


def local_file(root, value):
    require(nonempty(value), "file path is required")
    path = Path(value)
    require(not path.is_absolute() and ".." not in path.parts,
            f"not a repository-relative path: {value}")
    resolved = (root / path).resolve()
    require(resolved.is_relative_to(root.resolve()) and resolved.is_file(),
            f"missing or outside repository: {value}")


def unique(items, pattern, label):
    require(isinstance(items, list) and items, f"{label} must be a nonempty list")
    ids = [item["id"] for item in items]
    require(all(isinstance(x, str) and re.fullmatch(pattern, x) for x in ids),
            f"invalid {label} ID")
    require(len(set(ids)) == len(ids), f"duplicate {label} ID")
    return set(ids)


def strings(values, label):
    require(isinstance(values, list) and values and all(nonempty(x) for x in values),
            f"{label} must contain nonempty strings")


def referenced_paths(control):
    return {r["path"] for r in control["code"]} | {
        r["path"] for check in control["checks"] for r in check["references"]}


def validate(data, root):
    require(data["schema_version"] == 1, "unsupported schema_version")
    require(data["hazards"] == [f"H{x}" for x in range(1, 7)], "expected H1–H6")
    hazards = set(data["hazards"])
    uca_ids = unique(data["ucas"], r"UCA-\d{2}", "UCA")
    ev_ids = unique(data["controls"], r"EV-\d{2}", "evidence")
    unique([c["constraint"] for c in data["controls"]], r"SC-\d{2}", "constraint")
    all_checks = []
    for u in data["ucas"]:
        for field in ("action", "timing", "description"):
            require(nonempty(u[field]), f"{u['id']}: missing {field}")
        strings(u["hazards"], u["id"])
        require(set(u["hazards"]) <= hazards, f"{u['id']}: unknown hazard")
    covered = set()
    for c in data["controls"]:
        label = c["id"]
        require(nonempty(c["title"]) and nonempty(c["constraint"]["text"]),
                f"{label}: missing title/claim")
        require(c["implementation"] in ("gap", "partial", "implemented"),
                f"{label}: invalid implementation state")
        require(c["verification"] in ("unverified", "verified", "stale"),
                f"{label}: invalid verification state")
        for field in ("hazards", "ucas", "scenarios", "assumptions", "residual_risks"):
            strings(c[field], f"{label}.{field}")
        require(set(c["hazards"]) <= hazards, f"{label}: unknown hazard")
        require(set(c["ucas"]) <= uca_ids, f"{label}: unknown UCA")
        covered.update(c["ucas"])
        require(isinstance(c["tasks"], list) and all(
            isinstance(t, str) and re.fullmatch(r"SAF-(0[1-9]|10)", t)
            for t in c["tasks"]), f"{label}: invalid task ID")
        require(isinstance(c["code"], list), f"{label}: code must be a list")
        require(c["implementation"] == "gap" or c["code"],
                f"{label}: implemented/partial controls need code references")
        require(nonempty(c["call_path"]), f"{label}: production call path is required")
        check_ids = unique(c["checks"], r"CHECK-\d{2}(?:-[a-z0-9]+)?", "check")
        all_checks.extend(c["checks"])
        for check in c["checks"]:
            require(check["kind"] in ("proof", "scenario", "operational"),
                    f"{label}: invalid check kind (static review is not execution evidence)")
            require(nonempty(check["procedure"]), f"{label}: missing verification procedure")
            require(isinstance(check["references"], list), f"{label}: references must be a list")
        refs = c["code"] + [r for check in c["checks"] for r in check["references"]]
        for ref in refs:
            local_file(root, ref["path"])
            require(nonempty(ref["symbol"]), f"{label}: reference needs a symbol")
        review = c["review"]
        require(isinstance(review["commit"], str) and SHA.fullmatch(review["commit"]),
                f"{label}: review needs full inspected commit SHA")
        date(review["date"])
        require(nonempty(review["note"]), f"{label}: review needs an impact note")
        require(isinstance(c["runs"], list), f"{label}: runs must be a list")
        passing = {}
        for run in c["runs"]:
            require(run["check"] in check_ids, f"{label}: run references unknown check")
            require(isinstance(run["commit"], str) and SHA.fullmatch(run["commit"]),
                    f"{label}: run needs full tested commit SHA")
            date(run["date"])
            require(nonempty(run["command"]), f"{label}: run needs command/procedure")
            require(run["result"] in ("pass", "fail", "skip"), f"{label}: invalid result")
            report = run["report"]
            require(nonempty(report), f"{label}: run needs durable report")
            if report.startswith("https://"):
                require(re.fullmatch(
                    r"https://github\.com/[^/]+/[^/]+/actions/runs/\d+(?:/attempts/\d+)?", report),
                    f"{label}: use an immutable GitHub Actions run URL or local report")
            else:
                local_file(root, report)
            # Latest recorded outcome for a check on a revision takes precedence.
            passing.setdefault(run["commit"], {})[run["check"]] = run["result"]
        if c["verification"] == "verified":
            require(c["implementation"] != "gap", f"{label}: gap cannot be verified")
            latest = passing.get(c["runs"][-1]["commit"], {}) if c["runs"] else {}
            require(all(latest.get(k) == "pass" for k in check_ids),
                    f"{label}: verified requires all checks passing on one tested revision")
    unique(all_checks, r"CHECK-\d{2}(?:-[a-z0-9]+)?", "check")
    require(covered == uca_ids, "every UCA needs at least one control")
    return ev_ids


def cell(value):
    return value.replace("|", "\\|").replace("\n", " ")


def render(data):
    lines = [BEGIN, "", "<!-- Generated from safety-evidence.json; do not edit this table. -->",
             "| Evidence / constraint | Bounded claim | Hazards / UCA | Implementation | Verification | Code / candidate check |",
             "|---|---|---|---|---|---|"]
    for c in data["controls"]:
        ids = f"<a id=\"{c['id'].lower()}\"></a>{c['id']} / {c['constraint']['id']}"
        links = ", ".join(c["hazards"] + c["ucas"])
        refs = []
        if c["code"]:
            refs.append(f"[code](../{c['code'][0]['path']})")
        if c["checks"][0]["references"]:
            refs.append(f"[check](../{c['checks'][0]['references'][0]['path']})")
        lines.append("| " + " | ".join(map(cell, [ids, c["constraint"]["text"], links,
                      c["implementation"], c["verification"], ", ".join(refs)])) + " |")
    return "\n".join(lines + ["", END])


def sync_document(text, data, write=False):
    require(text.count(BEGIN) == text.count(END) == 1, "STPA needs one generated block")
    start, end = text.index(BEGIN), text.index(END) + len(END)
    require(start < end - len(END), "invalid generated block order")
    expected = render(data)
    if not write:
        require(text[start:end] == expected, "STPA table drift: run --write")
    return text[:start] + expected + text[end:]


def check_impact(old, new, changed):
    previous = {c["id"]: c for c in old["controls"]}
    current = {c["id"]: c for c in new["controls"]}
    old_ucas = {u["id"]: u for u in old["ucas"]}
    new_ucas = {u["id"]: u for u in new["ucas"]}
    require(old_ucas.keys() <= new_ucas.keys(), "do not delete stable UCA IDs")
    require(previous.keys() <= current.keys(),
            "do not delete evidence IDs; retain the record with a supersession note")
    for key, before in previous.items():
        after = current[key]
        require(before["constraint"]["id"] == after["constraint"]["id"],
                f"{key}: do not rename stable constraint IDs")
        impacted = changed & (referenced_paths(before) | referenced_paths(after))
        semantic_fields = ("constraint", "scenarios", "assumptions", "residual_risks",
                           "code", "call_path", "checks", "implementation", "hazards", "ucas")
        semantic_change = any(before[k] != after[k] for k in semantic_fields)
        semantic_change = semantic_change or any(
            old_ucas.get(u) != new_ucas.get(u) for u in set(before["ucas"] + after["ucas"]))
        newly_verified = after["verification"] == "verified" and before["verification"] != "verified"
        if impacted or semantic_change or newly_verified:
            require(before["review"] != after["review"] and
                    before["review"]["note"] != after["review"]["note"],
                    f"{key}: changed references/claim need a new review impact note ({sorted(impacted)})")
            if after["verification"] == "verified":
                new_passes = [r for r in after["runs"] if r not in before["runs"] and r["result"] == "pass"]
                latest_commit = after["runs"][-1]["commit"] if after["runs"] else None
                require({r["check"] for r in new_passes if r["commit"] == latest_commit}
                        >= {check["id"] for check in after["checks"]},
                        f"{key}: revalidate with new passing evidence or mark stale")


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--write", action="store_true", help="regenerate STPA table only")
    parser.add_argument("--base", help="base revision to check referenced-file review updates")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        data = json.loads((root / REGISTER).read_text())
        validate(data, root)
        document = root / STPA
        updated = sync_document(document.read_text(), data, args.write)
        if args.base:
            base = git(root, "rev-parse", "--verify", args.base + "^{commit}").strip()
            listing = git(root, "ls-tree", "--name-only", base, "--", REGISTER).strip()
            # Initial register introduction has no previous review records.
            if listing:
                old = json.loads(git(root, "show", f"{base}:{REGISTER}"))
                changed = set(git(root, "diff", "--name-only", "--no-renames", "-z", base).split("\0"))
                check_impact(old, data, changed)
        if args.write:
            document.write_text(updated)
        print("Safety evidence checks passed (structure and review bookkeeping, not safety verification).")
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"safety-evidence: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
