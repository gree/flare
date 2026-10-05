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


IMPL_STAGE = {"gap": "no", "partial": "partial", "implemented": "yes"}

# Paths whose change cannot alter what a test exercised. A run at revision X
# counts for candidate C only if X == C or every path changed between them
# is one of these (verified with git; an unknown revision never counts).
DOCS_ONLY = re.compile(r"^(docs/.*|[^/]*\.md|.*/[^/]*\.md)$")
_equiv_cache = {}


def equivalent(root, rev, candidate):
    """rev and candidate are the same revision, or differ in docs only."""
    if not rev or not candidate:
        return False
    if rev == candidate:
        return True
    key = (rev, candidate)
    if key not in _equiv_cache:
        try:
            changed = git(root, "diff", "--name-only", rev, candidate).split()
            _equiv_cache[key] = all(DOCS_ONLY.match(p) for p in changed)
        except (subprocess.CalledProcessError, OSError):
            _equiv_cache[key] = False
    return _equiv_cache[key]


ACTIONS_URL = re.compile(r"https://github\.com/[^/]+/[^/]+/actions/runs/\d+(?:/attempts/\d+)?")
_tree_cache = {}


def tree_of(root, rev):
    if rev not in _tree_cache:
        try:
            _tree_cache[rev] = git(root, "rev-parse", f"{rev}^{{tree}}").strip()
        except (subprocess.CalledProcessError, OSError):
            _tree_cache[rev] = None
    return _tree_cache[rev]


def counts_for(run, candidate, root):
    """A run counts for the candidate only if it is a CI run (source=ci with
    an immutable Actions run URL) and the TREE it tested is the candidate's
    tree — or the tested revision is available locally and differs from the
    candidate in docs only. A PR job tests a merge commit, so the branch
    `head` is informational and never enough on its own."""
    if run.get("source") != "ci" or not ACTIONS_URL.fullmatch(str(run.get("run_url", ""))):
        return False
    cand_tree = tree_of(root, candidate["commit"])
    if run.get("tree") and cand_tree and run["tree"] == cand_tree:
        return True
    return equivalent(root, run["commit"], candidate["commit"])


def ci_stage(control, candidate=None, root=None):
    """CI stage for the release CANDIDATE, derived from recorded runs (see
    counts_for). yes = every check's latest counting run passed; partial =
    some; no = none."""
    ids = [k["id"] for k in control["checks"]]
    if not candidate:
        return "no", f"no release candidate set (0/{len(ids)} checks counted)"
    latest = {}
    for run in control["runs"]:
        if counts_for(run, candidate, root):
            latest[run["check"]] = run["result"]
    passed = [i for i in ids if latest.get(i) == "pass"]
    state = "yes" if ids and len(passed) == len(ids) else ("partial" if passed else "no")
    return state, (f"{len(passed)}/{len(ids)} checks pass in CI runs that tested candidate "
                   f"{candidate.get('label', '?')} ({candidate['commit'][:10]})'s tree or a docs-only equivalent")


def derive_status(control, candidate=None, root=None):
    """The derived stage (CI) and the transcribed one (implemented), written by
    --write and required by the check. `implemented` is NOT computed: it is the
    hand-set implementation field, labelled as declared."""
    status = control.setdefault("status", {})
    status["implemented"] = {"state": IMPL_STAGE[control["implementation"]], "source": "declared"}
    state, evidence = ci_stage(control, candidate, root)
    status["ci_passed"] = {"state": state, "evidence": evidence}
    status.setdefault("reviewed", {"state": "no", "note": "no independent review recorded (the review field holds change-impact notes)"})
    status.setdefault("production_approved", {"state": "no", "note": "not approved for production"})


def validate_status(c, label, candidate=None, root=None):
    st = c.get("status")
    require(isinstance(st, dict) and set(st) == {"implemented", "ci_passed", "reviewed", "production_approved"},
            f"{label}: status needs implemented/ci_passed/reviewed/production_approved (run --write)")
    require(st["implemented"] == {"state": IMPL_STAGE[c["implementation"]], "source": "declared"},
            f"{label}: status.implemented does not match implementation (run --write)")
    state, evidence = ci_stage(c, candidate, root)
    require(st["ci_passed"] == {"state": state, "evidence": evidence},
            f"{label}: status.ci_passed must be derived from the runs at the candidate (run --write)")
    rv = st["reviewed"]
    require(rv["state"] in ("no", "yes"), f"{label}: invalid reviewed state")
    if rv["state"] == "yes":
        require(nonempty(rv.get("by", "")) and SHA.fullmatch(str(rv.get("commit", ""))),
                f"{label}: reviewed=yes needs the reviewer (role) and the full reviewed commit SHA")
        date(rv["date"])
        require(candidate is not None and equivalent(root, rv["commit"], candidate["commit"]),
                f"{label}: reviewed=yes must be a review of the release candidate (or a docs-only equivalent)")
    ap = st["production_approved"]
    require(ap["state"] in ("no", "yes"), f"{label}: invalid production_approved state")
    if ap["state"] == "yes":
        require(candidate is not None, f"{label}: production approval needs a release candidate")
        require(rv["state"] == "yes" and state == "yes",
                f"{label}: production approval requires reviewed=yes and ci_passed=yes")
        require(nonempty(ap.get("by", "")) and nonempty(ap.get("note", "")),
                f"{label}: production approval needs the approver (role) and a note")
        require(ap.get("commit") == candidate["commit"],
                f"{label}: production approval must name the candidate commit")
        date(ap["date"])


def validate(data, root):
    require(data["schema_version"] == 1, "unsupported schema_version")
    candidate = data.get("candidate")
    if candidate is not None:
        require(isinstance(candidate, dict) and SHA.fullmatch(str(candidate.get("commit", "")))
                and nonempty(candidate.get("label", "")),
                "candidate needs a full commit SHA and a label")
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
            if "head" in run:
                require(isinstance(run["head"], str) and SHA.fullmatch(run["head"]),
                        f"{label}: run head must be a full branch SHA")
            if "tree" in run:
                require(isinstance(run["tree"], str) and SHA.fullmatch(run["tree"]),
                        f"{label}: run tree must be the full tested tree SHA")
            if "source" in run:
                require(run["source"] in ("ci", "local"), f"{label}: run source must be ci or local")
                if run["source"] == "ci":
                    require(ACTIONS_URL.fullmatch(str(run.get("run_url", ""))),
                            f"{label}: a ci run needs its immutable GitHub Actions run_url")
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
        validate_status(c, label, candidate, root)
    unique(all_checks, r"CHECK-\d{2}(?:-[a-z0-9]+)?", "check")
    require(covered == uca_ids, "every UCA needs at least one control")
    return ev_ids


def cell(value):
    return value.replace("|", "\\|").replace("\n", " ")


def render(data):
    lines = [BEGIN, "", "<!-- Generated from safety-evidence.json; do not edit this table. -->",
             "| Evidence / constraint | Bounded claim | Hazards / UCA | Implemented (declared) | CI passed at candidate | Reviewed | Production approved | Verification | Code / candidate check |",
             "|---|---|---|---|---|---|---|---|---|"]
    for c in data["controls"]:
        ids = f"<a id=\"{c['id'].lower()}\"></a>{c['id']} / {c['constraint']['id']}"
        links = ", ".join(c["hazards"] + c["ucas"])
        refs = []
        if c["code"]:
            refs.append(f"[code](../{c['code'][0]['path']})")
        if c["checks"][0]["references"]:
            refs.append(f"[check](../{c['checks'][0]['references'][0]['path']})")
        st = c["status"]
        ev = st["ci_passed"]["evidence"]
        ci = f"{st['ci_passed']['state']} ({'no candidate' if ev.startswith('no release candidate') else ev.split(' ')[0]})"
        lines.append("| " + " | ".join(map(cell, [ids, c["constraint"]["text"], links,
                      st["implemented"]["state"], ci, st["reviewed"]["state"],
                      st["production_approved"]["state"], c["verification"], ", ".join(refs)])) + " |")
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
    parser.add_argument("--write", action="store_true", help="derive the implemented/CI stages and regenerate the STPA table")
    parser.add_argument("--base", help="base revision to check referenced-file review updates")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        data = json.loads((root / REGISTER).read_text())
        if args.write:
            # The implemented and CI stages are derived, never hand-set: the
            # register cannot claim a CI pass its runs do not record.
            for control in data["controls"]:
                derive_status(control, data.get("candidate"), root)
            (root / REGISTER).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
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
