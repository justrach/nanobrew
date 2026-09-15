#!/usr/bin/env python3
"""Local source-bottle pilot: zlib for Intel macOS, with no Homebrew tools.

Requires macOS, Xcode command-line tools, Python 3.12+, and Rosetta on ARM.
Builds and tests in a temporary directory; never installs into the host prefix
or publishes. Output: dist/zlib-1.3.2.macos-x86_64.source.tar.gz.
"""
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

VERSION = "1.3.2"
URL = f"https://zlib.net/zlib-{VERSION}.tar.gz"
# Pinned from https://formulae.brew.sh/api/formula/zlib.json.
SHA256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
PREFIX = f"/opt/nanobrew/prefix/Cellar/zlib/{VERSION}"


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This pilot requires macOS and the Apple SDK")
    # Exclude Homebrew compilers, libraries and pkg-config paths.
    env = {k: v for k, v in os.environ.items() if k in ("HOME", "TMPDIR")}
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", CC="clang -arch x86_64",
               CFLAGS="-O2 -arch x86_64 -mmacosx-version-min=12.0",
               LDFLAGS="-arch x86_64 -mmacosx-version-min=12.0",
               MACOSX_DEPLOYMENT_TARGET="12.0")
    with urllib.request.urlopen(URL, timeout=120) as response:
        source = response.read()
    if hashlib.sha256(source).hexdigest() != SHA256:
        raise SystemExit("Source checksum mismatch")
    out = Path(__file__).resolve().parents[2] / "dist"
    out.mkdir(exist_ok=True)
    bottle = out / f"zlib-{VERSION}.macos-x86_64.source.tar.gz"
    with tempfile.TemporaryDirectory(prefix="nb-zlib-intel-") as td:
        root = Path(td)
        with tarfile.open(fileobj=io.BytesIO(source)) as archive:
            archive.extractall(root, filter="data")
        src = root / f"zlib-{VERSION}"

        def run(*args):
            subprocess.run(args, cwd=src, env=env, check=True)

        run("./configure", f"--prefix={PREFIX}")
        run("make", "-j4")
        run("make", "test")
        stage = root / "stage"
        run("make", "install", f"DESTDIR={stage}")
        keg = stage / PREFIX.lstrip("/")
        run("lipo", str(keg / "lib/libz.a"), "-verify_arch", "x86_64")
        run("lipo", str(keg / "lib/libz.1.dylib"), "-verify_arch", "x86_64")
        run("otool", "-L", str(keg / "lib/libz.1.dylib"))
        shutil.copy2(src / "LICENSE", keg / "LICENSE")
        # A downstream program must compile against the staged headers/library.
        probe = root / "probe.c"
        probe.write_text('#include <zlib.h>\n#include <string.h>\n'
                         'int main(void) { return strcmp(zlibVersion(), ZLIB_VERSION); }\n')
        run("clang", "-arch", "x86_64", "-mmacosx-version-min=12.0",
            f"-I{keg / 'include'}", str(probe), str(keg / "lib/libz.a"),
            "-o", str(root / "probe"))
        run("arch", "-x86_64", str(root / "probe"))
        # Normalize archive metadata, keeping headers, libraries, pkg-config,
        # man page, symlinks and license rather than just executable files.
        with bottle.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode="w") as archive:
                    for path in sorted(keg.rglob("*")):
                        info = archive.gettarinfo(path, f"zlib/{VERSION}/{path.relative_to(keg)}")
                        info.uid = info.gid = info.mtime = 0
                        info.uname = info.gname = ""
                        if info.isfile():
                            with path.open("rb") as data:
                                archive.addfile(info, data)
                        else:
                            archive.addfile(info)
    digest = hashlib.sha256(bottle.read_bytes()).hexdigest()
    evidence = {"package": "zlib", "version": VERSION, "platform": "macos-x86_64",
                "source_url": URL, "source_sha256": SHA256, "bottle_sha256": digest,
                "prefix": PREFIX, "deployment_target": "12.0",
                "host_arch": platform.machine(),
                "tests": ["make test", "lipo -verify_arch x86_64", "static consumer probe"],
                "compiler": subprocess.check_output(["/usr/bin/clang", "--version"], text=True).strip(),
                "sdk": subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-version"], text=True).strip(),
                "limitation": "nb install/relocation validation is performed separately by CI"}
    bottle.with_suffix(".json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Prepared {bottle}\nsha256={digest}")


if __name__ == "__main__":
    main()
