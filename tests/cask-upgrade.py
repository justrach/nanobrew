#!/usr/bin/env python3
"""Cask upgrade integration under temporary roots, including process crashes.
No network access, installed packages, or production database are used.
"""
import hashlib
import json
import pathlib
import subprocess
import shutil
import sys
import tarfile
import tempfile
import zipfile

fixture = str(pathlib.Path(sys.argv[1]).resolve())


def run_case(fault="none", fmt="tar.gz", bad=None, activation_moves=0, rollback_moves=0):
    with tempfile.TemporaryDirectory(prefix="nb-upgrade-") as temp:
        root = pathlib.Path(temp).resolve()
        old = root / "Caskroom/fixture/1.0"
        old.mkdir(parents=True)
        (old / "companion").write_text("old")
        (old / "cli").write_text('#!/bin/sh\ncat "$(dirname "$0")/companion"\n')
        (old / "cli").chmod(0o755)
        apps = root / "Applications"
        (apps / "Fixture.app/Contents/MacOS").mkdir(parents=True)
        (apps / "Fixture.app/Contents/MacOS/tool").write_text("old-app")
        (apps / "Retired.app").mkdir()
        (apps / "Retired.app/resource").write_text("retired")
        (root / "bin").mkdir()
        (root / "bin/fixture").symlink_to(old / "cli")
        (root / "bin/retired").symlink_to(old / "cli")
        (root / "bin/app-tool").symlink_to(apps / "Fixture.app/Contents/MacOS/tool")
        original = {"kegs": [{"name": "untouched", "version": "8"}], "casks": [{
            "token": "fixture", "canonical_token": "fixture", "version": "1.0", "sha256": "a" * 64,
            "apps": ["Fixture.app", "Retired.app"], "binaries": ["fixture", "retired", "app-tool"],
            "probe_success": True, "probed_at": 123, "probe_schema": 4, "probe_platform": 5,
        }]}
        (root / "state.json").write_text(json.dumps(original))
        original_bytes = (root / "state.json").read_bytes()
        payload = root / "archive-payload"
        (payload / "dist/bin").mkdir(parents=True)
        (payload / "Fixture.app/Contents/MacOS").mkdir(parents=True)
        (payload / "dist/bin/cli").write_text('#!/bin/sh\ncat "$(dirname "$0")/../companion"\n')
        (payload / "dist/bin/cli").chmod(0o755)
        (payload / "dist/companion").write_text("new")
        (payload / "dist/helper").symlink_to("companion")
        (payload / "Fixture.app/Contents/MacOS/tool").write_text("#!/bin/sh\necho new-app\n")
        (payload / "Fixture.app/Contents/MacOS/tool").chmod(0o755)
        blob = root / ("fixture." + fmt)
        if fmt == "binary":
            blob.write_text("#!/bin/sh\necho new\n")
        elif fmt == "zip":
            with zipfile.ZipFile(blob, "w") as z:
                for p in payload.rglob("*"):
                    z.write(p, p.relative_to(payload))
        else:
            with tarfile.open(blob, "w:" + ("gz" if fmt == "tar.gz" else "xz")) as t:
                for p in payload.iterdir():
                    t.add(p, arcname=p.name)
        artifacts = [
            {"app": "Fixture.app"},
            {"binary": {"source": "dist/bin/cli", "target": "fixture"}},
            {"binary": {"source": "$APPDIR/Fixture.app/Contents/MacOS/tool", "target": "app-tool"}},
            {"binary": {"source": "dist/bin/cli", "target": "added"}},
        ]
        if fmt == "binary":
            artifacts = [{"binary": {"source": "fixture", "target": "fixture"}}]
        if bad == "missing-source":
            artifacts[1]["binary"]["source"] = "dist/missing"
        if bad == "external-installer":
            artifacts.append({"pkg": "Installer.pkg"})
        if bad == "foreign-link":
            (root / "bin/fixture").unlink()
            (root / "bin/fixture").symlink_to("/usr/bin/true")
        if bad == "foreign-app":
            (apps / "Foreign.app").mkdir()
            (apps / "Foreign.app/keep").write_text("foreign")
            artifacts.append({"app": "Foreign.app"})
        metadata = {
            "token": "fixture", "name": "Fixture", "version": "2.0", "url": "https://invalid/fixture." + fmt,
            "sha256": hashlib.sha256(blob.read_bytes()).hexdigest(), "homepage": "", "desc": "",
            "auto_updates": False, "artifacts": artifacts, "min_macos": None,
        }
        if bad == "checksum":
            metadata["sha256"] = "0" * 64
        meta = root / "cask.json"
        meta.write_text(json.dumps(metadata))
        result = subprocess.run([fixture, str(root), str(blob), str(meta), fault], capture_output=True, text=True)
        success = fault in ("none", "crash-committed-0", "fail-committed-0") and bad is None
        if fault.startswith("crash-"):
            assert result.returncode == 75, result.stderr
            assert (root / "transaction/journal.json").exists()
        elif success:
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode != 0, (fault, bad, result.stdout, result.stderr)
        # Exercise disk states between the two renames of an activation and
        # between rollback actions. The upgrade process is already dead; only
        # its journal and filesystem state are used by the recovery process.
        if activation_moves or rollback_moves:
            journal = json.loads((root / "transaction/journal.json").read_text())
            actions = []
            if activation_moves:
                for step in journal["steps"]:
                    if step["had_old"]:
                        actions.append(("rename", step["destination"], step["backup"]))
                    if not step["remove_only"]:
                        actions.append(("rename", step["staged"], step["destination"]))
            else:
                for step in reversed(journal["steps"]):
                    if step["had_old"]:
                        actions.append(("remove", step["destination"], None))
                        actions.append(("rename", step["backup"], step["destination"]))
                    else:
                        actions.append(("rename", step["destination"], step["staged"]))
            for kind, source, dest in actions[:activation_moves or rollback_moves]:
                source = pathlib.Path(source)
                if kind == "rename":
                    source.rename(dest)
                elif source.is_symlink() or source.is_file():
                    source.unlink()
                elif source.is_dir():
                    shutil.rmtree(source)
        # A fresh process must recover, and a second recovery must be harmless.
        for _ in range(2):
            subprocess.run([fixture, str(root), str(blob), str(meta), "recover"], check=True)
        state = json.loads((root / "state.json").read_text())
        record = state["casks"][0]
        assert state["kegs"][0]["name"] == "untouched"
        assert record["version"] == ("2.0" if success else "1.0"), (fault, bad, state)
        if success:
            new = root / "Caskroom/fixture/2.0"
            assert not old.exists()
            if fmt == "binary":
                assert (root / "bin/fixture").resolve() == new / "fixture"
                assert subprocess.check_output([str(root / "bin/fixture")], text=True) == "new\n"
                assert not (apps / "Fixture.app").exists()
                assert not (root / "bin/app-tool").is_symlink()
            else:
                assert (root / "bin/fixture").resolve() == new / "dist/bin/cli"
                assert subprocess.check_output([str((root / "bin/fixture").resolve())], text=True) == "new"
                assert (new / "dist/helper").read_text() == "new"
                assert subprocess.check_output([str(root / "bin/app-tool")], text=True) == "new-app\n"
            assert not (root / "bin/retired").is_symlink()
            assert not (apps / "Retired.app").exists()
            assert not record["probe_success"]
            assert record["sha256"] == metadata["sha256"]
        else:
            assert (root / "state.json").read_bytes() == original_bytes
            assert not (root / "Caskroom/fixture/2.0").exists()
            if bad != "foreign-link":
                assert (root / "bin/fixture").resolve() == old / "cli"
                assert subprocess.check_output([str(old / "cli")], text=True) == "old"
            else:
                assert (root / "bin/fixture").readlink() == pathlib.Path("/usr/bin/true")
            assert (apps / "Fixture.app/Contents/MacOS/tool").read_text() == "old-app"
            assert (root / "bin/retired").resolve() == old / "cli"
            assert (apps / "Retired.app/resource").read_text() == "retired"
            assert not (root / "bin/added").is_symlink()
            if fault == "late-conflict":
                assert (root / "bin/added").read_text() == "foreign"
            if bad == "foreign-app":
                assert (apps / "Foreign.app/keep").read_text() == "foreign"
        assert not (root / "transaction").exists()
        assert not list(root.rglob("*.nb-upgrade-*"))
        print("PASS", fmt, fault, bad or "", activation_moves, rollback_moves, flush=True)


for fmt in ("tar.gz", "tar.xz", "zip", "binary"):
    run_case(fmt=fmt)
for bad in ("missing-source", "checksum", "foreign-link", "foreign-app", "external-installer"):
    run_case(bad=bad)
for fault in ["late-conflict", "crash-activating-0", "database-failure", "fail-staged-0", "crash-staged-0", "crash-database-7", "fail-committed-0", "crash-committed-0"]:
    run_case(fault)
# Payload, app, three links, two removed artifacts, then the database.
for index in range(8):
    run_case(f"fail-activated-{index}")
    run_case(f"crash-activated-{index}")

for moves in range(1, 13):
    run_case("crash-activating-0", activation_moves=moves)
for moves in range(1, 15):
    run_case("crash-activated-7", rollback_moves=moves)
