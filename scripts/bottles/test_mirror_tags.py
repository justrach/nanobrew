#!/usr/bin/env python3
import unittest
from nb_bottles import bottle_manifest_tag


class MirrorTags(unittest.TestCase):
    def test_unrebuilt_tag_stays_compatible(self):
        self.assertEqual(bottle_manifest_tag({"resolved": {"version": "1.0"}}, "macos-arm64"),
                         "1.0.macos-arm64")

    def test_rebuild_does_not_overwrite_old_tag(self):
        original = {"resolved": {"version": "1.10.0"}}
        rebuilt = {"resolved": {"version": "1.10.0", "rebuild": 2}}
        self.assertNotEqual(bottle_manifest_tag(original, "linux-aarch64"),
                            bottle_manifest_tag(rebuilt, "linux-aarch64"))
        self.assertEqual(bottle_manifest_tag(rebuilt, "linux-aarch64"), "1.10.0.r0.b2.linux-aarch64")

    def test_legacy_top_level_metadata_and_resolved_precedence(self):
        rec = {"revision": 1, "rebuild": 2, "resolved": {"version": "1.0"}}
        self.assertEqual(bottle_manifest_tag(rec, "macos-arm64"), "1.0.r1.b2.macos-arm64")
        rec["resolved"].update(revision=0, rebuild=0)
        self.assertEqual(bottle_manifest_tag(rec, "macos-arm64"), "1.0.macos-arm64")


if __name__ == "__main__":
    unittest.main()
