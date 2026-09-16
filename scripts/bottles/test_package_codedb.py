#!/usr/bin/env python3
import io
import tarfile
import unittest
from package_codedb import package


class PackageTests(unittest.TestCase):
    def test_reproducible_bottle_preserves_binary_and_license(self):
        data = package('1.2.3', b'example executable', b'BSD license')
        self.assertEqual(data, package('1.2.3', b'example executable', b'BSD license'))
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            self.assertEqual(archive.getnames(), ['codedb/1.2.3/bin/codedb', 'codedb/1.2.3/LICENSE'])
            self.assertEqual(archive.extractfile(archive.getmembers()[0]).read(), b'example executable')
            self.assertEqual(archive.extractfile(archive.getmembers()[1]).read(), b'BSD license')
            self.assertEqual(archive.getmembers()[0].mode, 0o755)
            self.assertEqual(archive.getmembers()[1].mode, 0o644)


if __name__ == '__main__':
    unittest.main()
