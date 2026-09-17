import unittest
from build_monterey_git import order, ROOTS, RECIPES, deployment_targets


class RecipeTests(unittest.TestCase):
    def test_deployment_audit_ignores_linker_sdk_and_source_versions(self):
        modern = "cmd LC_BUILD_VERSION\n minos 12.0\n sdk 15.5\n ntools 1\n tool LD\n version 1167.5\ncmd LC_SOURCE_VERSION\n version 0.0\n"
        self.assertEqual(deployment_targets(modern), ['12.0'])
        self.assertEqual(deployment_targets('cmd LC_VERSION_MIN_MACOSX\n version 13.0\n sdk 15.0'), ['13.0'])
        self.assertEqual(deployment_targets('cmd LC_SOURCE_VERSION\n version 12.0'), [])

    def test_dependency_graph_complete_and_topological(self):
        resolved = order(ROOTS)
        self.assertEqual(set(resolved), set(RECIPES))
        for name in resolved:
            for dep in RECIPES[name]['dependencies']:
                self.assertLess(resolved.index(dep), resolved.index(name))

    def test_readline_patch_level_matches_pinned_version(self):
        recipe = RECIPES['readline']
        self.assertEqual(int(recipe['version'].split('.')[-1]), len(recipe['patches']))
        self.assertEqual([p['url'].rsplit('-', 1)[1] for p in recipe['patches']],
                         [f'{i:03}' for i in range(1, 7)])

    def test_sources_and_patches_have_digest_pins(self):
        for recipe in RECIPES.values():
            for source in [recipe, *recipe.get('patches', [])]:
                self.assertRegex(source['sha256'], r'^[a-f0-9]{64}$')
                self.assertTrue(source['url'].startswith('https://'))


if __name__ == '__main__':
    unittest.main()
