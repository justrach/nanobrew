#!/usr/bin/env python3
"""Live cask regression: installs/removes unique fixtures in /opt/nanobrew.

Requires an initialized, writable nanobrew prefix on macOS. Uses local cached
metadata and verified fixture blobs; telemetry and upstream lookup are disabled.
The real install/remove commands exercise package staging, links, fonts and DB
lifecycle. HOME points to a temporary directory for the font fixture.
"""

import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import uuid
import tarfile
import zipfile
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 tests/cask-archive-staging.py /path/to/nb")
nb = str(pathlib.Path(sys.argv[1]).resolve())
root = pathlib.Path("/opt/nanobrew")
prefix = root / "prefix"
env = dict(os.environ, NANOBREW_DISABLE_UPSTREAM="1", NANOBREW_NO_TELEMETRY="1")
with tempfile.TemporaryDirectory(prefix="nb-cask-regression-") as tmp:
    tmp = pathlib.Path(tmp)
    env["HOME"] = str(tmp)
    (tmp / "Library/Fonts").mkdir(parents=True)
    for fmt in ("tar.gz", "tar.xz", "zip"):
        token = "nb-regression-" + uuid.uuid4().hex[:10]
        payload = tmp / token
        (payload / "bin").mkdir(parents=True)
        (payload / "resources").mkdir()
        (payload / "platform-tools").mkdir()
        (payload / "fonts").mkdir()
        (payload / "bin" / token).write_text(
            '#!/bin/sh\ncd "$(dirname "$0")/.."\ncat bin/host package.json resources/data\n'
        )
        (payload / "bin" / token).chmod(0o755)
        (payload / "bin/host").write_text("helper")
        (payload / "package.json").write_text("metadata")
        (payload / "resources/data").write_text("resource")
        (payload / "platform-tools/adb").write_text("#!/bin/sh\necho adb\n")
        (payload / "platform-tools/adb").chmod(0o755)
        font = f"{token}[wght].ttf"
        (payload / "fonts" / font).write_text("font")
        archive = tmp / (token + "." + fmt)
        if fmt == "zip":
            with zipfile.ZipFile(archive, "w") as z:
                for p in payload.rglob("*"):
                    z.write(p, p.relative_to(payload))
        else:
            with tarfile.open(archive, "w:" + ("gz" if fmt == "tar.gz" else "xz")) as t:
                for p in payload.iterdir():
                    t.add(p, arcname=p.name)
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        blob = root / "cache/blobs" / sha
        cache = root / "cache/api" / f"cask-{token}.json"
        arts = [{"binary": [f"bin/{token}"]}]
        if fmt == "zip":
            arts += [
                {"binary": ["platform-tools/adb", {"target": token + "-adb"}]},
                {"font": [f"fonts/{font}"]},
            ]
        meta = {
            "token": token,
            "name": [token],
            "version": "1.0",
            "url": f"https://example.invalid/{token}.{fmt}",
            "sha256": sha,
            "homepage": "https://example.invalid",
            "artifacts": arts,
        }
        try:
            blob.write_bytes(archive.read_bytes())
            cache.write_text(json.dumps(meta))
            r = subprocess.run(
                [nb, "install", "--cask", token],
                env=env,
                text=True,
                capture_output=True,
            )
            print(r.stdout, r.stderr, flush=True)
            assert r.returncode == 0
            staged = prefix / "Caskroom" / token / "1.0"
            assert (prefix / "bin" / token).resolve() == staged / "bin" / token
            assert (
                subprocess.check_output(
                    [str((prefix / "bin" / token).resolve())], text=True
                )
                == "helpermetadataresource"
            )
            for rel in [
                "bin/host",
                "package.json",
                "resources/data",
                "platform-tools/adb",
                "fonts/" + font,
            ]:
                assert (staged / rel).exists(), rel
            if fmt == "zip":
                assert (
                    subprocess.check_output(
                        [str(prefix / "bin" / (token + "-adb"))], text=True
                    )
                    == "adb\n"
                )
                assert (tmp / "Library/Fonts" / font).read_text() == "font"
            r = subprocess.run(
                [nb, "remove", "--cask", token], env=env, text=True, capture_output=True
            )
            print(r.stdout, r.stderr, flush=True)
            assert r.returncode == 0
            assert not staged.exists()
            assert not (prefix / "bin" / token).is_symlink()
            print("PASS", fmt, flush=True)
        finally:
            try:
                subprocess.run(
                    [nb, "remove", "--cask", token], env=env, capture_output=True
                )
            finally:
                cache.unlink(missing_ok=True)
                blob.unlink(missing_ok=True)
