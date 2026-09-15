#!/usr/bin/env python3
"""Verify exact registry pins and usable libraries on a disposable macOS runner."""
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from build_intel_library import CONSUMERS, LIBRARIES

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ["zlib", "xz", "lz4", "openssl@3", "ca-certificates"]


def main():
    arch = platform.machine()
    if platform.system() != "Darwin" or arch not in ("arm64", "x86_64"):
        raise SystemExit("Requires native Apple Silicon or Intel macOS")
    target = "macos-" + arch
    registry = json.loads((ROOT / "registry/upstream.json").read_text())
    records = {r["token"]: r for r in registry["records"] if r["kind"] == "formula"}
    state = json.loads(Path("/opt/nanobrew/db/state.json").read_text())
    installed = {r["name"]: r for r in state["kegs"]}
    env = {k: os.environ[k] for k in ("HOME", "TMPDIR") if k in os.environ}
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    evidence = []
    with tempfile.TemporaryDirectory(prefix="nb-core-consumer-") as td:
        work = Path(td)
        def run(*argv):
            print("+", " ".join(map(str, argv)), flush=True)
            return subprocess.check_output(list(map(str, argv)), cwd=work, env=env, text=True)
        for name in PACKAGES:
            resolved = records[name]["resolved"]
            actual = installed[name]
            assert actual["version"] == resolved["version"], (name, actual)
            assert actual["sha256"] == resolved["assets"][target]["sha256"], (name, actual)
            checks = ["exact installed version and bottle digest"]
            keg = Path("/opt/nanobrew/prefix/Cellar") / name / actual["version"]
            if name in LIBRARIES:
                for lib in LIBRARIES[name]:
                    run("/usr/bin/lipo", keg / "lib" / lib, "-verify_arch", arch)
                source = work / "consumer.c"
                source.write_text(CONSUMERS[name])
                binary = work / "consumer"
                run("/usr/bin/clang", "-arch", arch, "-I" + str(keg / "include"), source,
                    *[keg / "lib" / lib for lib in LIBRARIES[name]], "-o", binary)
                print(run("/usr/bin/otool", "-L", binary))
                run(binary)
                checks += ["native architecture", "dynamic consumer without library path overrides"]
            if name in ("xz", "lz4"):
                binary = keg / "bin" / name
                print(run(binary, "--version"))
                payload = b"Nanobrew native compression test\n" * 100
                compressed = subprocess.check_output([str(binary), "-c"], input=payload, env=env)
                assert subprocess.check_output([str(binary), "-d", "-c"], input=compressed, env=env) == payload
                checks.append("compression round-trip")
            if name == "openssl@3":
                binary = keg / "bin/openssl"
                print(run(binary, "version", "-a"))
                assert Path("/opt/nanobrew/prefix/etc/openssl@3/cert.pem").is_file()
                run(binary, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=nanobrew-test",
                    "-keyout", "key.pem", "-out", "cert.pem", "-days", "1")
                run(binary, "verify", "-CAfile", "cert.pem", "cert.pem")
                checks.append("default CA bundle and certificate generation/verification")
            if name == "ca-certificates":
                assert "-----BEGIN CERTIFICATE-----" in Path("/opt/nanobrew/prefix/etc/ca-certificates/cert.pem").read_text()
                checks.append("installed CA bundle")
            evidence.append({"name": name, "version": actual["version"], "sha256": actual["sha256"], "checks": checks})
    (ROOT / "dist").mkdir(exist_ok=True)
    (ROOT / f"dist/core-libraries-{target}.json").write_text(json.dumps({"platform": target,
        "macos": platform.mac_ver()[0], "packages": evidence}, indent=2) + "\n")


if __name__ == "__main__":
    main()
