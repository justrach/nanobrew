#!/usr/bin/env python3
"""CLI regression using one unique binary cask in an initialized macOS prefix.
Uses cached metadata/blobs and cleans up only its own package and cache files.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid
import zipfile

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
        assert token in output and "2.0" in output and "==> 1 outdated package(s)" in output
        assert "==> 1 outdated package(s)" in run("outdated", token)
        assert "unknown flag" in run("outdated", "--bogus", expected=1)
        assert "cannot be combined" in run("outdated", "--cask", "--deb", expected=1)
        assert "is not installed" in run("outdated", "--cask", token + "-missing", expected=1)
        assert "is not installed" in run("outdated", "--deb", token, expected=1)
        output = run("upgrade", "--cask", token)
        assert "Upgraded " + token in output and "cask probe passed" in output
        assert record()["version"] == "2.0" and record()["sha256"] == candidate["sha256"]
        assert not (root / "prefix/Caskroom" / token / "1.0").exists()
        assert (root / "prefix/bin" / token).resolve() == root / "prefix/Caskroom" / token / "2.0/dist" / token
        assert "All packages are up to date." in run("outdated", "--cask", token)
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


# An auto-updating app that updated itself past the published version is not
# outdated, and `nb upgrade` must not downgrade it (#449).
app_token = "nb-autoupdate-test-" + uuid.uuid4().hex[:12]
app_cache = root / "cache/api" / ("cask-" + app_token + ".json")
installed_app = pathlib.Path("/Applications") / (app_token + ".app")


def app_run(*args, expected=0):
    result = subprocess.run([nb, *args], env=env, text=True, capture_output=True, timeout=60)
    print("\n".join(line for line in (result.stdout + result.stderr).splitlines() if app_token in line or line.startswith("==>")), flush=True)
    assert result.returncode == expected, result
    return result.stdout + result.stderr


def set_bundle_version(app, version):
    plist = app / "Contents/Info.plist"
    data = plistlib.loads(plist.read_bytes())
    data["CFBundleShortVersionString"] = version
    plist.write_bytes(plistlib.dumps(data))


def app_zip(temp, version, xattr_file=None):
    """Ad-hoc signed app zipped by ditto, like a release zip."""
    stage = temp / ("app-" + version)
    app = stage / (app_token + ".app")
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Resources/en.lproj").mkdir(parents=True)
    shutil.copy("/usr/bin/true", app / "Contents/MacOS" / app_token)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": app_token, "CFBundleIdentifier": "dev.nanobrew.test." + app_token,
        "CFBundleName": app_token, "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": version}))
    (app / "Contents/Resources/en.lproj/Main.strings").write_text('"key" = "value";\n')
    subprocess.check_call(["codesign", "--force", "--deep", "--sign", "-", str(app)])
    if xattr_file:
        subprocess.check_call(["xattr", "-w", "dev.nanobrew.test", "1", str(app / xattr_file)])
    subprocess.check_call(["codesign", "--verify", "--deep", "--strict", str(app)])
    archive = temp / (version + ".zip")
    # --sequesterRsrc puts the AppleDouble data under __MACOSX/ (documented in ditto(1));
    # inline_apple_double then moves it next to each file.
    subprocess.check_call(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    if xattr_file:
        inline_apple_double(archive)
    return archive


def inline_apple_double(archive):
    """Store AppleDouble entries next to their files (`dir/._name`), as release
    zips such as hiddenbar's do, whether or not ditto sequestered them."""
    with zipfile.ZipFile(archive) as z:
        entries = [(info, z.read(info)) for info in z.infolist()]
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for info, data in entries:
            name = info.filename
            if name.startswith("__MACOSX/"):
                name = name[len("__MACOSX/"):]
                if not name or name.endswith("/"):
                    continue
            copy = zipfile.ZipInfo(name, info.date_time)
            copy.external_attr = info.external_attr
            copy.create_system = info.create_system
            copy.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(copy, data)
    names = zipfile.ZipFile(archive).namelist()
    assert any(pathlib.PurePosixPath(n).name.startswith("._") for n in names), names


def publish_app(temp, version, auto_updates, xattr_file=None):
    archive = app_zip(temp, version, xattr_file)
    sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    blob = root / "cache/blobs" / sha
    blob.write_bytes(archive.read_bytes())
    blobs.append(blob)
    data = {"token": app_token, "name": [app_token], "version": version,
            "url": "https://example.invalid/fixture.zip", "sha256": sha, "auto_updates": auto_updates,
            "homepage": "https://example.invalid", "artifacts": [{"app": [app_token + ".app"]}]}
    app_cache.write_text(json.dumps(data))
    return archive


def app_record():
    return next(c for c in json.loads((root / "db/state.json").read_text())["casks"] if c["token"] == app_token)


assert not installed_app.exists()
with tempfile.TemporaryDirectory(prefix="nb-cask-app-") as temp:
    temp = pathlib.Path(temp)
    env["HOME"] = str(temp)
    blobs = []
    try:
        publish_app(temp, "1.0", True)
        output = app_run("install", "--cask", app_token)
        assert "cask probe passed" in output, output
        assert app_record()["version"] == "1.0"
        # The app updates itself to 3.0 while the API still publishes 2.0.
        set_bundle_version(installed_app, "3.0")
        publish_app(temp, "2.0", True)
        output = app_run("outdated", "--cask", app_token)
        assert "app updated itself to 3.0" in output and "All packages are up to date." in output, output
        output = app_run("upgrade", "--cask", app_token)
        assert "Upgraded " + app_token not in output, output
        assert app_record()["version"] == "1.0"
        assert plistlib.loads((installed_app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "3.0"
        # An app still older than the candidate is outdated as before.
        set_bundle_version(installed_app, "1.5")
        output = app_run("outdated", "--cask", app_token)
        assert "==> 1 outdated package(s)" in output and "2.0" in output, output
        print("PASS CLI auto-updating app is not downgraded (#449)")
        # A zip with AppleDouble entries must still install a validly signed
        # app (#425). First show that plain unzip damages this very fixture.
        app_run("remove", "--cask", app_token)
        assert not installed_app.exists()
        archive = publish_app(temp, "4.0", False, xattr_file="Contents/Resources/en.lproj/Main.strings")
        raw = temp / "raw-unzip"
        subprocess.check_call(["unzip", "-q", str(archive), "-d", str(raw)])
        raw_app = raw / (app_token + ".app")
        assert list(raw_app.rglob("._*")), "fixture should make unzip write AppleDouble files"
        assert subprocess.run(["codesign", "--verify", "--deep", "--strict", str(raw_app)], capture_output=True).returncode != 0
        output = app_run("install", "--cask", app_token)
        assert "codesign verification failed" not in output and "cask probe passed" in output, output
        assert not list(installed_app.rglob("._*"))
        subprocess.check_call(["codesign", "--verify", "--deep", "--strict", str(installed_app)])
        print("PASS CLI zip with AppleDouble entries installs a validly signed app (#425)")
    finally:
        subprocess.run([nb, "remove", "--cask", app_token], env=env, capture_output=True, timeout=30)
        if installed_app.exists():
            shutil.rmtree(installed_app)
        app_cache.unlink(missing_ok=True)
        for blob in blobs:
            blob.unlink(missing_ok=True)
