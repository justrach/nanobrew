#!/usr/bin/env python3
"""CLI regression using one unique binary cask in an initialized macOS prefix.
Uses cached metadata/blobs and cleans up only its own package and cache files.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import uuid

nb = str(pathlib.Path(sys.argv[1]).resolve())
root = pathlib.Path("/opt/nanobrew")
token = "nb-upgrade-test-" + uuid.uuid4().hex[:12]
cache = root / "cache/api" / ("cask-" + token + ".json")
blobs = []
env = dict(os.environ, NANOBREW_DISABLE_UPSTREAM="1", NANOBREW_NO_TELEMETRY="1")


def run(*args, expected=0):
    result = subprocess.run([nb, *args], env=env, text=True, capture_output=True, timeout=40)
    if args[0] == "outdated":
        print("\n".join(line for line in result.stdout.splitlines() if token in line or line.startswith("==>")), flush=True)
    else:
        print(result.stdout, result.stderr, flush=True)
    assert result.returncode == expected, result
    return result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix="nb-cask-cli-") as temp:
    temp = pathlib.Path(temp)
    env["HOME"] = str(temp)

    def metadata(version, script):
        payload = temp / version
        (payload / "dist").mkdir(parents=True)
        (payload / "dist" / token).write_text(script)
        (payload / "dist" / token).chmod(0o755)
        (payload / "dist/companion").write_text(version + "\n")
        archive = temp / (version + ".tar.gz")
        with tarfile.open(archive, "w:gz") as t:
            t.add(payload / "dist", arcname="dist")
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        blob = root / "cache/blobs" / sha
        assert not blob.exists()
        blob.write_bytes(archive.read_bytes())
        blobs.append(blob)
        data = {"token": token, "name": [token], "version": version,
                "url": "https://example.invalid/fixture.tar.gz", "sha256": sha,
                "homepage": "https://example.invalid", "artifacts": [{"binary": ["dist/" + token]}]}
        cache.write_text(json.dumps(data))
        return data

    def record():
        return next(c for c in json.loads((root / "db/state.json").read_text())["casks"] if c["token"] == token)

    healthy = '#!/bin/sh\nif [ ! -f cold-complete ]; then sleep 2.2; touch cold-complete; fi\ncat "$(dirname "$0")/companion"\n'
    try:
        metadata("1.0", healthy)
        output = run("install", "--cask", token)
        assert "cask probe passed" in output and "unverified" not in output
        assert record()["probe_success"]
        output = run("doctor", "--probe", token)
        assert "cask probe passed" in output
        candidate = metadata("2.0", healthy)
        output = run("outdated", "--cask", token)
        assert token in output and "2.0" in output
        output = run("upgrade", "--cask", token)
        assert "Upgraded " + token in output and "cask probe passed" in output
        assert record()["version"] == "2.0" and record()["sha256"] == candidate["sha256"]
        assert not (root / "prefix/Caskroom" / token / "1.0").exists()
        assert (root / "prefix/bin" / token).resolve() == root / "prefix/Caskroom" / token / "2.0/dist" / token
        assert token not in run("outdated", "--cask", token)
        # Unsupported candidates are skipped outside the actionable plan.
        candidate["version"] = "3.0"
        candidate["artifacts"] = [{"pkg": ["Installer.pkg"]}]
        cache.write_text(json.dumps(candidate))
        output = run("upgrade", "--cask", token)
        assert "unsupported, skipping" in output and "No packages upgraded" in output
        assert "==> Upgrading " not in output and record()["version"] == "2.0"
        # A timeout remains a failed health check after a successful install.
        run("remove", "--cask", token)
        metadata("4.0", "#!/bin/sh\nwhile :; do sleep 0.05; done\n")
        output = run("install", "--cask", token)
        assert "probe timed out after" in output and "--version" in output
        assert "installation completed; runtime health unverified" in output
        assert not record()["probe_success"]
        print("PASS CLI cold startup, upgrade, outdated, unsupported plan and timeout diagnostics")
    finally:
        subprocess.run([nb, "remove", "--cask", token], env=env, capture_output=True, timeout=30)
        cache.unlink(missing_ok=True)
        for blob in blobs:
            blob.unlink(missing_ok=True)
