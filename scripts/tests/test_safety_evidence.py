"""Regression tests for the bookkeeping gate; these are not operator safety tests."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("safety", ROOT / "scripts/check_safety_evidence.py")
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / safety.REGISTER).read_text())

    def run_record(self, check="CHECK-01", result="pass", commit="1" * 40):
        return {"check": check, "result": result, "commit": commit,
                "date": "2026-09-10", "command": "run fault-injection scenario",
                "report": "https://github.com/example/flare/actions/runs/123"}

    def test_repository_register_is_valid(self):
        safety.validate(self.data, ROOT)

    def test_duplicate_ids_rejected(self):
        for field in ("controls", "ucas"):
            with self.subTest(field=field):
                data = copy.deepcopy(self.data)
                data[field].append(copy.deepcopy(data[field][0]))
                with self.assertRaisesRegex(ValueError, "duplicate"):
                    safety.validate(data, ROOT)

    def test_unknown_uca_rejected(self):
        self.data["controls"][0]["ucas"] = ["UCA-99"]
        with self.assertRaisesRegex(ValueError, "unknown UCA"):
            safety.validate(self.data, ROOT)

    def test_broken_or_external_code_reference_rejected(self):
        for path in ("missing.cc", "../outside.cc", str(ROOT / "README.md")):
            with self.subTest(path=path):
                self.data["controls"][0]["code"][0]["path"] = path
                with self.assertRaises(ValueError):
                    safety.validate(self.data, ROOT)

    def test_test_reference_checked_too(self):
        self.data["controls"][0]["checks"][0]["references"] = [
            {"path": "missing-test.lean", "symbol": "test"}]
        with self.assertRaisesRegex(ValueError, "missing"):
            safety.validate(self.data, ROOT)

    def test_verified_needs_execution_evidence(self):
        self.data["controls"][0]["verification"] = "verified"
        for runs in ([], [self.run_record(result="skip")], [self.run_record(result="fail")]):
            self.data["controls"][0]["runs"] = runs
            with self.assertRaisesRegex(ValueError, "all checks passing"):
                safety.validate(self.data, ROOT)

    def test_complete_passing_record_is_structurally_valid(self):
        c = self.data["controls"][0]
        c["verification"] = "verified"
        c["runs"] = [self.run_record()]
        safety.validate(self.data, ROOT)

    def test_branch_sha_missing_report_and_static_evidence_rejected(self):
        for field, value in (("commit", "master"), ("report", ""),
                             ("report", "https://github.com/example/flare/actions"),
                             ("check", "CHECK-99"), ("date", "yesterday")):
            with self.subTest(field=field, value=value):
                run = self.run_record()
                run[field] = value
                self.data["controls"][0]["runs"] = [run]
                with self.assertRaises(ValueError):
                    safety.validate(self.data, ROOT)
        self.data["controls"][0]["runs"] = []
        self.data["controls"][0]["checks"][0]["kind"] = "static"
        with self.assertRaisesRegex(ValueError, "static review"):
            safety.validate(self.data, ROOT)

    def test_all_checks_must_pass_on_same_revision(self):
        c = self.data["controls"][0]
        extra = copy.deepcopy(c["checks"][0])
        extra["id"] = "CHECK-01-extra"
        c["checks"].append(extra)
        c["verification"] = "verified"
        c["runs"] = [self.run_record(), self.run_record("CHECK-01-extra", commit="2" * 40)]
        with self.assertRaisesRegex(ValueError, "one tested revision"):
            safety.validate(self.data, ROOT)

    def test_failed_rerun_supersedes_pass_on_same_revision(self):
        c = self.data["controls"][0]
        c["verification"] = "verified"
        c["runs"] = [self.run_record(), self.run_record(result="fail")]
        with self.assertRaisesRegex(ValueError, "all checks passing"):
            safety.validate(self.data, ROOT)

    def test_failed_new_revision_cannot_reuse_old_pass(self):
        c = self.data["controls"][0]
        c["verification"] = "verified"
        c["runs"] = [self.run_record(), self.run_record(result="fail", commit="2" * 40)]
        with self.assertRaisesRegex(ValueError, "all checks passing"):
            safety.validate(self.data, ROOT)

    def test_table_drift_and_duplicate_markers_rejected(self):
        document = "intro\n" + safety.render(self.data) + "\nanalysis\n"
        self.assertEqual(safety.sync_document(document, self.data), document)
        with self.assertRaisesRegex(ValueError, "table drift"):
            safety.sync_document(document.replace("unverified", "verified", 1), self.data)
        with self.assertRaisesRegex(ValueError, "one generated block"):
            safety.sync_document(document + safety.BEGIN, self.data)
        repaired = safety.sync_document(document.replace("unverified", "verified", 1), self.data, True)
        self.assertEqual(document, repaired)

    def test_changed_reference_requires_per_control_review(self):
        changed = {self.data["controls"][0]["code"][0]["path"]}
        with self.assertRaisesRegex(ValueError, "review impact note"):
            safety.check_impact(self.data, copy.deepcopy(self.data), changed)
        new = copy.deepcopy(self.data)
        for c in new["controls"]:
            if safety.referenced_paths(c) & changed:
                c["review"]["note"] = "Re-read changed Main; claim remains unverified."
        safety.check_impact(self.data, new, changed)

    def test_removing_reference_cannot_evade_review(self):
        new = copy.deepcopy(self.data)
        changed = {new["controls"][0]["code"][0]["path"]}
        new["controls"][0]["code"] = []
        with self.assertRaisesRegex(ValueError, "review impact note"):
            safety.check_impact(self.data, new, changed)

    def test_changed_claim_also_requires_review(self):
        new = copy.deepcopy(self.data)
        new["controls"][0]["constraint"]["text"] = "Stronger claim"
        with self.assertRaisesRegex(ValueError, "review impact note"):
            safety.check_impact(self.data, new, set())

    def test_changed_uca_meaning_requires_control_review(self):
        new = copy.deepcopy(self.data)
        new["ucas"][0]["description"] += " Expanded scenario."
        with self.assertRaisesRegex(ValueError, "review impact note"):
            safety.check_impact(self.data, new, set())

    def test_verified_impact_accepts_complete_new_evidence(self):
        old = copy.deepcopy(self.data)
        old["controls"][0]["verification"] = "verified"
        old["controls"][0]["runs"] = [self.run_record()]
        new = copy.deepcopy(old)
        new["controls"][0]["constraint"]["text"] += " Clarified scope."
        new["controls"][0]["review"]["note"] = "Revalidated clarified scope on new revision."
        new["controls"][0]["runs"].append(self.run_record(commit="2" * 40))
        safety.validate(new, ROOT)
        safety.check_impact(old, new, set())

    def test_verified_impact_needs_new_pass_or_stale(self):
        old = copy.deepcopy(self.data)
        old["controls"][0]["verification"] = "verified"
        old["controls"][0]["runs"] = [self.run_record()]
        new = copy.deepcopy(old)
        new["controls"][0]["constraint"]["text"] += " Clarified scope."
        new["controls"][0]["review"]["note"] = "Changed scope; old run needs reassessment."
        with self.assertRaisesRegex(ValueError, "mark stale"):
            safety.check_impact(old, new, set())
        new["controls"][0]["verification"] = "stale"
        safety.check_impact(old, new, set())

    def test_unrelated_changes_do_not_require_evidence_churn(self):
        safety.check_impact(self.data, copy.deepcopy(self.data), {"README.md"})

    def test_removing_evidence_record_rejected(self):
        new = copy.deepcopy(self.data)
        new["controls"].pop()
        with self.assertRaisesRegex(ValueError, "do not delete"):
            safety.check_impact(self.data, new, set())

    def test_cli_detects_renamed_reference_against_git_base(self):
        # An isolated fixture exercises real --base diff handling, including deletion
        # of the old path. No tracked project files are changed by this test.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # Every LOCAL path the register points at has to exist in the
            # fixture, or the checker stops on a missing file before it can
            # reach the behaviour under test. referenced_paths covers code
            # and check references; run reports are local files too.
            local_paths = {p for c in self.data["controls"] for p in safety.referenced_paths(c)}
            local_paths |= {run["report"] for c in self.data["controls"] for run in c["runs"]
                            if not run["report"].startswith("https://")}
            for path in local_paths:
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture\n")
            (root / "docs").mkdir(exist_ok=True)
            (root / safety.REGISTER).write_text(json.dumps(self.data))
            (root / safety.STPA).write_text(safety.render(self.data))
            def git(*args):
                return subprocess.check_output(["git", "-C", tmp, *args], text=True,
                                               stderr=subprocess.DEVNULL)
            git("init")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture")
            base = git("rev-parse", "HEAD").strip()
            old_path = self.data["controls"][0]["code"][0]["path"]
            new_path = old_path + ".renamed"
            (root / old_path).rename(root / new_path)
            for c in self.data["controls"]:
                for ref in c["code"]:
                    if ref["path"] == old_path:
                        ref["path"] = new_path
            (root / safety.REGISTER).write_text(json.dumps(self.data))
            (root / safety.STPA).write_text(safety.render(self.data))
            result = subprocess.run(["python3", str(ROOT / "scripts/check_safety_evidence.py"),
                                     "--root", tmp, "--base", base], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("review impact note", result.stderr)


if __name__ == "__main__":
    unittest.main()
