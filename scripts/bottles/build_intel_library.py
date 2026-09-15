#!/usr/bin/env python3
"""Build reviewed Intel library recipes without installing into the host prefix."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / "dist"
RECIPES = Path(__file__).with_name("intel-library-recipes.json")
LIBRARIES = {"xz": ["liblzma.5.dylib"], "lz4": ["liblz4.1.dylib"],
             "openssl@3": ["libssl.3.dylib", "libcrypto.3.dylib"], "zlib": ["libz.1.dylib"]}
CONSUMERS = {
    "xz": '#include <lzma.h>\n#include <string.h>\nint main(void){return strcmp(lzma_version_string(),LZMA_VERSION_STRING);}\n',
    "lz4": '#include <lz4.h>\nint main(void){return LZ4_versionNumber()!=LZ4_VERSION_NUMBER;}\n',
    "openssl@3": '#include <openssl/ssl.h>\n#include <openssl/crypto.h>\nint main(void){return !TLS_method() || OpenSSL_version_num()!=OPENSSL_VERSION_NUMBER;}\n',
    "zlib": '#include <zlib.h>\n#include <string.h>\nint main(void){return strcmp(zlibVersion(),ZLIB_VERSION);}\n',
}


def clean_env():
    env = {k: v for k, v in os.environ.items() if k in ("HOME", "TMPDIR")}
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", CC="/usr/bin/clang",
               CFLAGS="-O2 -arch x86_64 -mmacosx-version-min=12.0",
               LDFLAGS="-arch x86_64 -mmacosx-version-min=12.0", MACOSX_DEPLOYMENT_TARGET="12.0")
    return env


def run(argv, cwd, env):
    print("+", " ".join(map(str, argv)), flush=True)
    subprocess.run(list(map(str, argv)), cwd=cwd, env=env, check=True)


def consumer(name, keg, work, env, staged=False):
    source = work / "consumer.c"
    source.write_text(CONSUMERS[name])
    binary = work / "consumer"
    run(["/usr/bin/clang", "-arch", "x86_64", "-mmacosx-version-min=12.0",
         "-I" + str(keg / "include"), source, *[keg / "lib" / lib for lib in LIBRARIES[name]],
         "-o", binary], work, env)
    run(["/usr/bin/otool", "-L", binary], work, env)
    child_env = {**env, "DYLD_LIBRARY_PATH": str(keg / "lib")} if staged else env
    run([binary], work, child_env)


def verify_install(name):
    evidence = next(DIST.glob(f"{name}-*.macos-x86_64.source.tar.json"))
    info = json.loads(evidence.read_text())
    # Check both version and digest: a fallback bottle with the same version
    # must not accidentally satisfy the installation test.
    state = json.loads(Path("/opt/nanobrew/db/state.json").read_text())
    if info["bottle_sha256"] not in json.dumps(state):
        raise ValueError("Nanobrew did not record the source bottle digest")
    keg = Path(info["prefix"])
    env = clean_env()
    with tempfile.TemporaryDirectory(prefix="nb-library-consumer-") as td:
        work = Path(td)
        consumer(name, keg, work, env)
        payload = b"nanobrew Intel library round-trip\n" * 100
        if name in ("xz", "lz4"):
            binary = keg / "bin" / name
            run([binary, "--version"], work, env)
            compressed = subprocess.check_output([str(binary), "-c"], input=payload, env=env)
            decoded = subprocess.check_output([str(binary), "-d", "-c"], input=compressed, env=env)
            if decoded != payload:
                raise ValueError("Compression round-trip failed")
        if name == "openssl@3":
            binary = keg / "bin/openssl"
            run([binary, "version", "-a"], work, env)
            if not Path("/opt/nanobrew/prefix/etc/openssl@3/cert.pem").is_file():
                raise ValueError("OpenSSL default certificate bundle is not available")
            run([binary, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=nanobrew-test",
                 "-keyout", "key.pem", "-out", "cert.pem", "-days", "1"], work, env)
            run([binary, "verify", "-CAfile", "cert.pem", "cert.pem"], work, env)
    info["installed_tests"] = ["exact bottle digest", "dynamic library consumer"]
    if name in ("xz", "lz4"):
        info["installed_tests"].append("compression round-trip")
    if name == "openssl@3":
        info["installed_tests"] += ["default CA bundle exists", "generate and verify certificate"]
    evidence.write_text(json.dumps(info, indent=2) + "\n")


def build(name, source_file=None):
    if platform.system() != "Darwin":
        raise SystemExit("Intel macOS recipes require macOS and the Apple SDK")
    if name == "zlib":
        import build_zlib_intel
        build_zlib_intel.main()
        return
    recipe = json.loads(RECIPES.read_text())[name]
    version = recipe["version"]
    prefix = f"/opt/nanobrew/prefix/Cellar/{name}/{version}"
    env = clean_env()
    if source_file:
        source = Path(source_file).read_bytes()
    else:
        with urllib.request.urlopen(recipe["source_url"], timeout=180) as response:
            source = response.read()
    if hashlib.sha256(source).hexdigest() != recipe["source_sha256"]:
        raise ValueError("Source checksum mismatch")
    DIST.mkdir(exist_ok=True)
    # Publish corresponding source alongside GPL/LGPL-containing binaries.
    (DIST / f"{name}-{version}.upstream.tar.gz").write_bytes(source)
    commands = []
    with tempfile.TemporaryDirectory(prefix="nb-intel-library-") as td:
        root = Path(td)
        with tarfile.open(fileobj=io.BytesIO(source)) as archive:
            archive.extractall(root, filter="data")
        directories = [p for p in root.iterdir() if p.is_dir()]
        if len(directories) != 1:
            raise ValueError("Expected one source directory")
        src = directories[0]
        stage = root / "stage"

        def build_run(*argv):
            commands.append(list(map(str, argv)))
            run(argv, src, env)

        if name == "xz":
            build_run("./configure", f"--prefix={prefix}", "--host=x86_64-apple-darwin", "--disable-nls")
            build_run("make", "-j4")
            build_run("make", "-j4", "check")
            build_run("make", "install", f"DESTDIR={stage}")
        elif name == "lz4":
            build_run("make", "-j4", "allmost", f"PREFIX={prefix}")
            build_run("make", "check", f"PREFIX={prefix}")
            build_run("make", "install", f"PREFIX={prefix}", f"DESTDIR={stage}")
        elif name == "openssl@3":
            build_run("/usr/bin/perl", "./Configure", "darwin64-x86_64-cc", "shared",
                      f"--prefix={prefix}", "--openssldir=/opt/nanobrew/prefix/etc/openssl@3", "--libdir=lib")
            build_run("make", "-j4")
            build_run("make", "test", "HARNESS_JOBS=4")
            build_run("make", "install_sw", "install_ssldirs", f"DESTDIR={stage}")
        keg = stage / prefix.lstrip("/")
        if name == "openssl@3":
            # Nanobrew already installs .bottle/etc defaults and wires cert.pem.
            shutil.copytree(stage / "opt/nanobrew/prefix/etc", keg / ".bottle/etc")
        for library in LIBRARIES[name]:
            build_run("/usr/bin/lipo", keg / "lib" / library, "-verify_arch", "x86_64")
        binary = keg / "bin" / ("openssl" if name == "openssl@3" else name)
        build_run("/usr/bin/lipo", binary, "-verify_arch", "x86_64")
        license_dir = keg / "share/licenses" / name
        for path in src.rglob("*"):
            if path.is_file() and path.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT")):
                target = license_dir / path.relative_to(src)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
        if not license_dir.exists():
            raise ValueError("Recipe did not capture license notices")
        consumer(name, keg, root, env, staged=True)
        bottle = DIST / f"{name}-{version}.macos-x86_64.source.tar.gz"
        with bottle.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w") as archive:
                for path in sorted(keg.rglob("*")):
                    info = archive.gettarinfo(path, f"{name}/{version}/{path.relative_to(keg)}")
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ""
                    if info.isfile():
                        with path.open("rb") as data:
                            archive.addfile(info, data)
                    else:
                        archive.addfile(info)
    evidence = {"package": name, "version": version, "platform": "macos-x86_64",
                "source_url": recipe["source_url"], "source_sha256": recipe["source_sha256"],
                "bottle_sha256": hashlib.sha256(bottle.read_bytes()).hexdigest(),
                "prefix": prefix, "deployment_target": "12.0", "host_arch": platform.machine(),
                "compiler": subprocess.check_output(["/usr/bin/clang", "--version"], text=True).strip(),
                "sdk": subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-version"], text=True).strip(),
                "build_commands": commands, "build_environment": {k: env[k] for k in ("CC", "CFLAGS", "LDFLAGS")},
                "tests": ["upstream tests", "Intel architecture", "staged dynamic consumer"]}
    bottle.with_suffix(".json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Prepared {bottle}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", choices=["zlib", "xz", "lz4", "openssl@3"])
    parser.add_argument("--source-file", type=Path)
    parser.add_argument("--verify-install", action="store_true")
    args = parser.parse_args()
    if args.verify_install:
        verify_install(args.package)
    else:
        build(args.package, args.source_file)
