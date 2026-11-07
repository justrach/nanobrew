#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import nb_bottles


def upstream_tarball():
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as archive:
        member = tarfile.TarInfo("tool-1.0/tool")
        member.size = len(b"example executable")
        archive.addfile(member, io.BytesIO(b"example executable"))
    return out.getvalue()


class RepackageTests(unittest.TestCase):
    def test_rerun_builds_identical_bottle(self):
        # push_manifest refuses to move a version tag to a new digest, so a
        # rerun after a partial failure must rebuild the same bytes.
        payload = upstream_tarball()
        record = {
            "token": "tool", "name": "tool",
            "upstream": {"type": "github_release"},
            "artifacts": [{"type": "binary", "path": "bin/tool"}],
            "resolved": {"version": "1.0", "assets": {"macos-arm64": {
                "url": "https://example.invalid/tool-1.0.tar.gz",
                "sha256": hashlib.sha256(payload).hexdigest()}}},
        }
        args = argparse.Namespace(name="tool", no_publish=True)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(nb_bottles, "REPO_ROOT", Path(tmp)), \
                mock.patch.object(nb_bottles, "find_record", return_value=record), \
                mock.patch.object(nb_bottles, "http", return_value=(200, {}, payload)), \
                contextlib.redirect_stdout(io.StringIO()):
            bottle = Path(tmp) / "dist/tool-1.0.macos-arm64.tar.gz"
            builds = []
            for now in (1_000_000_000, 1_000_000_007):
                with mock.patch("time.time", return_value=now):
                    nb_bottles.cmd_repackage(args)
                builds.append(bottle.read_bytes())

        self.assertEqual(hashlib.sha256(builds[0]).hexdigest(), hashlib.sha256(builds[1]).hexdigest())
        with tarfile.open(fileobj=io.BytesIO(builds[0])) as archive:
            [member] = archive.getmembers()
            self.assertEqual(member.name, "tool/1.0/bin/tool")
            self.assertEqual(member.mode, 0o755)
            self.assertEqual(archive.extractfile(member).read(), b"example executable")


if __name__ == "__main__":
    unittest.main()
