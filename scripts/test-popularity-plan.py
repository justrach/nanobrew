import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("plan", Path(__file__).with_name("popularity-plan.py"))
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class PlanTests(unittest.TestCase):
    def test_rank_groups_options_and_reconciles(self):
        data = {"total_count": 1200, "items": [
            {"formula": "homebrew/core/gh", "count": "1,000"},
            {"formula": "gh --HEAD", "count": "100"},
            {"formula": "jq", "count": "100"}]}
        rows = plan.ranked(data, "formula", 2)
        self.assertEqual(rows[0], {"rank": 1, "token": "gh", "events_30d": 1100})
        data["total_count"] = 1199
        with self.assertRaises(ValueError):
            plan.ranked(data, "formula", 2)

    def test_dependency_cycle_and_diamond_count_once(self):
        meta = {"a": {"dependencies": ["b", "c"]}, "b": {"dependencies": ["d"]},
                "c": {"dependencies": ["d", "missing"]}, "d": {"dependencies": ["a"]}}
        nodes, missing = plan.dependency_closure("a", meta)
        self.assertEqual(nodes, {"a", "b", "c", "d", "missing"})
        self.assertEqual(missing, {"missing"})

    def test_arm_bottle_is_not_intel(self):
        self.assertEqual(plan.intel_tags({"bottle": {"stable": {"files": {"arm64_sonoma": {}}}}}), [])

    def test_old_pin_is_not_install_validation(self):
        row = {"token": "tool", "rank": 1, "events_30d": 100}
        record = {"upstream": {"type": "homebrew_bottle"}, "resolved": {
            "version": "1", "assets": {"macos-x86_64": {"sha256": "a" * 64}}}}
        result = plan.assess(row, "formula", record, {"versions": {"stable": "2"}})
        self.assertTrue(result["pin_differs_from_live"])
        self.assertEqual(result["action"], "source build candidate")
        self.assertEqual(result["runtime_validation"], "not tested by this report")

    def test_newer_upstream_pin_requires_review_not_downgrade(self):
        result = plan.assess({"token": "tool"}, "formula", {
            "upstream": {"type": "github_release"}, "resolved": {"version": "3", "assets": {}}},
            {"versions": {"stable": "2"}})
        self.assertEqual(result["action"], "review upstream pin")


if __name__ == "__main__":
    unittest.main()
