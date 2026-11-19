"""Synthetic label evidence only; never opens WeChat or uses real contacts."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "skills/wechat-contact-labels/scripts/label_checks.py"
SPEC = importlib.util.spec_from_file_location("label_checks", SCRIPT)
checks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checks)


class MatchingTests(unittest.TestCase):
    def evidence(self, labels):
        return {"source_label": "27 社系示例甲", "results_readable": True,
                "results_complete": True,
                "candidates": [{"candidate_id": f"account-{i}", "label": name}
                               for i, name in enumerate(labels)]}

    def test_space_difference_but_not_prefix_or_near_character(self):
        result = checks.match_candidates(self.evidence(
            ["27社系示例甲", "127社系示例甲", "27社系示例由"]))
        self.assertEqual(result, {"status": "unique_match", "candidate_ids": ["account-0"]})
        self.assertNotEqual(checks.normalized_label("①示例"), checks.normalized_label("1示例"))
        self.assertNotEqual(checks.normalized_label("a示例"), checks.normalized_label("A示例"))

    def test_same_name_accounts_are_not_merged(self):
        result = checks.match_candidates(self.evidence(["27社系示例甲", "27 社系示例甲"]))
        self.assertEqual(result["status"], "ambiguous")
        self.assertEqual(len(result["candidate_ids"]), 2)

    def test_incomplete_first_screen_cannot_claim_uniqueness_or_absence(self):
        for labels in [[], ["27社系示例甲"]]:
            for key in ["results_readable", "results_complete"]:
                data = self.evidence(labels)
                data[key] = False
                self.assertEqual(checks.match_candidates(data)["status"], "unknown")
        self.assertEqual(checks.match_candidates(self.evidence([]))["status"], "not_found")

    def test_duplicate_keys_require_reconciling_observations(self):
        data = self.evidence(["27社系示例甲"])
        data["candidates"].append(data["candidates"][0].copy())
        with self.assertRaises(ValueError):
            checks.match_candidates(data)

    def test_missing_results_and_non_boolean_flags_are_invalid(self):
        data = self.evidence([])
        del data["candidates"]
        with self.assertRaises(ValueError):
            checks.match_candidates(data)
        for value in ["false", 1, None]:
            data = self.evidence([])
            data["results_complete"] = value
            with self.assertRaises(ValueError):
                checks.match_candidates(data)


class MemberAuditTests(unittest.TestCase):
    def evidence(self):
        return {"baseline_complete": True, "baseline_member_ids": ["old"],
                "selected_member_ids": ["old", "new"], "observed_member_ids": ["old", "new"],
                "observed_count": 2, "members_complete": True, "count_stable": True}

    def test_existing_members_do_not_inflate_new_count(self):
        result = checks.audit_members(self.evidence())
        self.assertEqual(result["status"], "verified")
        self.assertEqual(result["expected_count"], 2)
        self.assertEqual(result["expected_new_member_count"], 1)

    def test_correct_count_does_not_hide_wrong_identity(self):
        data = self.evidence()
        data["observed_member_ids"] = ["old", "wrong"]
        result = checks.audit_members(data)
        self.assertEqual(result["status"], "reconcile")
        self.assertEqual(result["missing_member_ids"], ["new"])
        self.assertEqual(result["unexpected_member_ids"], ["wrong"])
        self.assertNotIn("new_member_count", result)

    def test_sync_and_partial_read_are_not_verified(self):
        for key in ["baseline_complete", "members_complete", "count_stable"]:
            data = self.evidence()
            data[key] = False
            self.assertEqual(checks.audit_members(data)["status"], "unknown")
        data = self.evidence()
        data["observed_member_ids"] = ["old"]
        data["observed_count"] = 1
        data["count_stable"] = False
        self.assertEqual(checks.audit_members(data)["status"], "unknown")
        data["count_stable"] = True
        self.assertEqual(checks.audit_members(data)["status"], "reconcile")

    def test_count_and_identity_evidence_must_agree(self):
        data = self.evidence()
        data["observed_count"] = 3
        self.assertEqual(checks.audit_members(data)["status"], "reconcile")
        for value in [True, -1, "2"]:
            data["observed_count"] = value
            with self.assertRaises(ValueError):
                checks.audit_members(data)

    def test_unavailable_count_remains_unknown(self):
        for stable in [True, False]:
            data = self.evidence()
            data["count_stable"] = stable
            data["observed_count"] = None
            result = checks.audit_members(data)
            self.assertEqual(result["status"], "unknown")
            self.assertIsNone(result["observed_count"])
            del data["observed_count"]
            self.assertEqual(checks.audit_members(data)["status"], "unknown")

    def test_cli_uses_local_json_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "audit.json"
            raw = json.dumps(self.evidence())
            path.write_text(raw, encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "audit", str(path)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "verified")
            self.assertEqual(path.read_text(encoding="utf-8"), raw)
            path.write_text("{", encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "audit", str(path)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
