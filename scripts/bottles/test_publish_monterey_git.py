import unittest
import hashlib
import json
import os
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

import nb_bottles as bottles
import publish_monterey_git as pub
from build_monterey_git import RECIPES, ROOTS, order

ENV = {'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '3'}


def write_dist(dist):
    records, blobs = [], {}
    for name in order(ROOTS):
        recipe = RECIPES[name]
        bottle = dist / f'{name}-{recipe["version"]}.monterey.bottle.tar.gz'
        data = (name + ' bottle bytes').encode()
        bottle.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        blobs['sha256:' + digest] = data
        evidence = {**recipe, 'bottle_sha256': digest, 'host_arch': 'x86_64', 'deployment_target': '12.0'}
        bottle.with_suffix('.json').write_text(json.dumps(evidence))
        records.append({'token': name, 'resolved': {'version': recipe['version'],
                        'assets': {'macos-x86_64': {'url': 'https://example.invalid/' + name,
                                                   'sha256': digest, 'minimum_macos_major': 12}}}})
    (dist / 'registry.json').write_text(json.dumps({'schema_version': 1, 'records': records}))
    (dist / 'installed-tests.json').write_text('{}')
    return records, blobs


class PublishTests(unittest.TestCase):
    def test_mismatched_bottle_digest_raises_before_any_publish(self):
        with tempfile.TemporaryDirectory() as td, patch.object(pub, 'DIST', Path(td)), \
                patch.dict(os.environ, ENV, clear=False):
            records, _ = write_dist(Path(td))
            first = order(ROOTS)[0]
            for record in records:
                if record['token'] == first:
                    record['resolved']['assets']['macos-x86_64']['sha256'] = '0' * 64
            (Path(td) / 'registry.json').write_text(json.dumps({'schema_version': 1, 'records': records}))
            publisher = Mock()
            with self.assertRaisesRegex(ValueError, first):
                pub.publish_records({'records': records}, publisher=publisher,
                                    puller=lambda name, digest: b'x')
            publisher.assert_not_called()

    def test_missing_installed_tests_raises(self):
        with tempfile.TemporaryDirectory() as td, patch.object(pub, 'DIST', Path(td)), \
                patch.dict(os.environ, ENV, clear=False):
            write_dist(Path(td))
            (Path(td) / 'installed-tests.json').unlink()
            with self.assertRaisesRegex(ValueError, 'tests missing'):
                pub.main()

    def test_publish_rewrites_urls_and_writes_registry_and_sums(self):
        with tempfile.TemporaryDirectory() as td, patch.object(pub, 'DIST', Path(td)), \
                patch.dict(os.environ, ENV, clear=False):
            dist = Path(td)
            records, blobs = write_dist(dist)
            publisher = Mock()
            pulled = lambda repo, digest, token: blobs[digest]
            with patch.object(bottles, 'bearer_for', return_value='anon-token'), \
                    patch.object(bottles, 'pull_blob', side_effect=pulled):
                pub.publish_records({'records': records}, publisher=publisher)
            self.assertEqual(publisher.call_count, len(records))
            publisher.assert_any_call('expat', f'{RECIPES["expat"]["version"]}-monterey-42-3',
                                      'macos-x86_64', dist / f'expat-{RECIPES["expat"]["version"]}.monterey.bottle.tar.gz')
            out = json.loads((dist / 'registry-monterey.json').read_text())
            self.assertEqual(out['schema_version'], 1)
            for record in out['records']:
                asset = record['resolved']['assets']['macos-x86_64']
                expected = f'https://ghcr.io/v2/justrach/nb-bottles/{bottles.ghcr_repo_name(record["token"])}/blobs/sha256:{asset["sha256"]}'
                self.assertEqual(asset['url'], expected)
                self.assertEqual(asset['minimum_macos_major'], 12)
            sums = (dist / 'SHA256SUMS').read_text()
            self.assertIn('expat-', sums)
            self.assertEqual(len(sums.strip().splitlines()), len(records))


if __name__ == '__main__':
    unittest.main()
