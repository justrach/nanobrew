"""Registry publication must not drop or relabel other platforms."""
import copy
import unittest
from unittest.mock import patch

from source_bottle_release import prepare_registry, add_recipe_identity, recipe_for


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.evidence = {"version": "1.3.2", "bottle_sha256": "a" * 64}
        self.registry = {"schema_version": 1, "records": [
            {"token": "other", "kind": "formula"},
            {"token": "zlib", "kind": "formula", "upstream": {"type": "homebrew_bottle"},
             "resolved": {"version": "1.3.2", "assets": {
                 "macos-arm64": {"url": "arm", "sha256": "b" * 64},
                 "macos-x86_64": {"url": "old", "sha256": "c" * 64}}}}]}

    def test_preserves_other_packages_and_platforms(self):
        before = copy.deepcopy(self.registry)
        result = prepare_registry(self.registry, self.evidence, "new")
        self.assertEqual(result["records"][0], before["records"][0])
        assets = result["records"][1]["resolved"]["assets"]
        self.assertEqual(assets["macos-arm64"], before["records"][1]["resolved"]["assets"]["macos-arm64"])
        self.assertEqual(assets["macos-x86_64"], {"url": "new", "sha256": "a" * 64})

    def test_explicit_source_deployment_target_survives_promotion(self):
        result = prepare_registry(self.registry, {**self.evidence, "deployment_target": "12.0"}, "new")
        intel = result["records"][1]["resolved"]["assets"]["macos-x86_64"]
        self.assertEqual(intel["minimum_macos_major"], 12)

    def test_rejects_mismatched_version_or_revision(self):
        for field, value in [("version", "1.3.3"), ("revision", 1)]:
            registry = copy.deepcopy(self.registry)
            registry["records"][1]["resolved"][field] = value
            with self.assertRaises(ValueError):
                prepare_registry(registry, self.evidence, "new")

    def test_adds_missing_formula(self):
        result = prepare_registry({"schema_version": 1, "records": []}, self.evidence, "new")
        self.assertEqual(result["records"][0]["token"], "zlib")
        self.assertEqual(list(result["records"][0]["resolved"]["assets"]), ["macos-x86_64"])

    def test_explicit_scan_identity_is_idempotent(self):
        evidence = {**self.evidence, "source_url": "https://zlib.net/source", "source_sha256": "b" * 64}
        sbom = {"SPDXID": "SPDXRef-DOCUMENT", "packages": [{"SPDXID": "SPDXRef-root"}]}
        add_recipe_identity(sbom, evidence)
        add_recipe_identity(sbom, evidence)
        self.assertEqual(len(sbom["packages"]), 2)
        self.assertEqual(len(sbom["relationships"]), 1)
        package = sbom["packages"][1]
        self.assertEqual(package["versionInfo"], "1.3.2")
        self.assertIn("cpe:2.3:a:zlib:zlib:1.3.2:", package["externalRefs"][0]["referenceLocator"])

    def test_library_upgrade_replaces_old_companion_assets(self):
        recipe = recipe_for("xz")
        evidence = {"package": "xz", "version": recipe["version"], "bottle_sha256": "a" * 64}
        registry = {"records": [{"token": "xz", "kind": "formula", "resolved": {
            "version": "old", "assets": {"macos-arm64": {"url": "old-arm", "sha256": "b" * 64}}}}]}
        prepare_registry(registry, evidence, "intel")
        resolved = registry["records"][0]["resolved"]
        self.assertEqual(resolved["version"], recipe["version"])
        self.assertNotEqual(resolved["assets"]["macos-arm64"]["url"], "old-arm")
        self.assertEqual(resolved["assets"]["macos-x86_64"]["url"], "intel")

    def test_missing_new_companion_fails_without_mutation(self):
        recipe = copy.deepcopy(recipe_for("xz"))
        recipe["metadata"]["bottle"]["stable"]["files"] = {}
        registry = {"records": [{"token": "xz", "kind": "formula", "resolved": {
            "version": "old", "assets": {"linux-x86_64": {"url": "old"}}}}]}
        before = copy.deepcopy(registry)
        with patch("source_bottle_release.recipe_for", return_value=recipe):
            with self.assertRaises(ValueError):
                prepare_registry(registry, {"package": "xz", "version": recipe["version"], "bottle_sha256": "a" * 64}, "intel")
        self.assertEqual(registry, before)

    def test_openssl_scan_identity_uses_product_name(self):
        recipe = recipe_for("openssl@3")
        evidence = {"package": "openssl@3", **recipe}
        sbom = add_recipe_identity({"SPDXID": "SPDXRef-DOCUMENT"}, evidence)
        self.assertEqual(sbom["packages"][0]["name"], "openssl")
        self.assertIn(":openssl:openssl:", sbom["packages"][0]["externalRefs"][0]["referenceLocator"])


if __name__ == "__main__":
    unittest.main()
