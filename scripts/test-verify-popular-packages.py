#!/usr/bin/env python3
"""Regression tests for pinned and default popular package verification."""
import json
import runpy
import unittest
from pathlib import Path
from unittest.mock import patch

VERIFY = runpy.run_path(str(Path(__file__).with_name('verify-popular-packages.py')))


class PopularPackageVerification(unittest.TestCase):
    def test_default_checks_resolved_version_and_digest_instead_of_pin(self):
        nb = Path('/tmp/nb')
        target = 'macos-x86_64'
        pinned = VERIFY['expected_packages']('pinned', target, nb)['gh']
        live = {'name': 'gh', 'kind': 'formula', 'version': '99.1.0_2', 'sha256': 'a' * 64}
        with patch('subprocess.check_output', return_value=json.dumps({'packages': [live]})) as info:
            resolved = VERIFY['expected_packages']('default', target, nb)['gh']
        info.assert_called_once_with([str(nb), 'info', '--json', *VERIFY['CHECKS']], text=True, timeout=60)
        verify = VERIFY['verify_receipt']
        verify('gh', live, resolved)
        verify('gh', pinned, pinned)
        with self.assertRaises(AssertionError):
            verify('gh', live, pinned)
        with self.assertRaises(AssertionError):
            verify('gh', dict(live, sha256=pinned['sha256']), resolved)
        with self.assertRaises(AssertionError):
            verify('gh', dict(live, version=pinned['version']), resolved)
        with self.assertRaises(AssertionError):
            verify('gh', live, {'version': live['version']})


if __name__ == '__main__':
    unittest.main()
