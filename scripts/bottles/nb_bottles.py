#!/usr/bin/env python3
"""nb_bottles — manage nanobrew's own GHCR bottle registry.

Subcommands:
  mirror     Tier 1: re-push pinned homebrew_bottle blobs (digest-preserving)
             from ghcr.io/homebrew/core to ghcr.io/<owner>/<prefix>/<name>.
  repackage  Tier 2: turn a github_release registry entry's upstream binary
             into a nanobrew bottle tarball (dist/<name>-<version>.<platform>.tar.gz).
  publish    Push one bottle tarball as an OCI artifact (blob + manifest tag).
  verify     Anonymously pull every mirrored blob digest and compare sha256.
  record     Print the registry JSON snippet pointing a package at our mirror.

Stdlib only. Auth: GHCR_TOKEN env var, or `gh auth token` (needs the
write:packages scope for pushes; reads of public packages are anonymous).
See manage.md at the repo root for the full operating guide.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY_JSON = REPO_ROOT / "src/upstream/registry_default.json"

OWNER = os.environ.get("GHCR_USER", "justrach")
PREFIX = os.environ.get("GHCR_REPO_PREFIX", "nb-bottles")
SOURCE_ANNOTATION = os.environ.get(
    "GHCR_SOURCE", "https://github.com/justrach/nanobrew"
)

UPSTREAM_REPO = "homebrew/core"
GHCR = "https://ghcr.io"
PLATFORMS = ("macos-arm64", "macos-x86_64", "linux-x86_64", "linux-aarch64")

MT_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
MT_CONFIG = "application/vnd.oci.image.config.v1+json"
MT_LAYER = "application/vnd.oci.image.layer.v1.tar+gzip"

UA = "nb-bottles/1.0"


def log(msg):
    print(msg, flush=True)


def die(msg, code=1):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


# ── HTTP / OCI plumbing ──────────────────────────────────────────────────────


def http(method, url, headers=None, data=None, ok=(200,), raw=False):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", UA)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            body = resp.read()
            if resp.status not in ok:
                die(f"{method} {url} -> {resp.status}")
            return resp.status, dict(resp.headers), body
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return e.code, dict(e.headers), e.read()
        body = e.read()[:300]
        die(f"{method} {url} -> {e.code}: {body!r}")


def pat():
    tok = os.environ.get("GHCR_TOKEN", "")
    if not tok:
        try:
            tok = subprocess.run(
                ["gh", "auth", "token"], capture_output=True, text=True, check=True
            ).stdout.strip()
        except Exception:
            pass
    return tok


def bearer_for(repo, pull_only=False, anonymous=False):
    """Registry bearer token for one repository scope."""
    scope = f"repository:{repo}:pull" + ("" if pull_only else ",push")
    url = f"{GHCR}/token?service=ghcr.io&scope={urllib.parse.quote(scope)}"
    headers = {}
    if not anonymous:
        p = pat()
        if not p:
            die("no GHCR_TOKEN and `gh auth token` unavailable")
        basic = base64.b64encode(f"{OWNER}:{p}".encode()).decode()
        headers["Authorization"] = f"Basic {basic}"
    _, _, body = http("GET", url, headers)
    return json.loads(body)["token"]


def blob_exists(repo, digest, token):
    status, _, _ = http(
        "HEAD",
        f"{GHCR}/v2/{repo}/blobs/{digest}",
        {"Authorization": f"Bearer {token}"},
        ok=(200, 404),
    )
    return status == 200


def pull_blob(repo, digest, token):
    _, _, body = http(
        "GET",
        f"{GHCR}/v2/{repo}/blobs/{digest}",
        {"Authorization": f"Bearer {token}"},
    )
    got = "sha256:" + hashlib.sha256(body).hexdigest()
    if got != digest:
        die(f"digest mismatch pulling {repo}@{digest}: got {got}")
    return body


def push_blob(repo, data, token, mount_from=None, digest=None):
    """Upload a blob; tries a cross-repo mount first when mount_from is set."""
    digest = digest or ("sha256:" + hashlib.sha256(data).hexdigest())
    if blob_exists(repo, digest, token):
        return digest, "exists"

    upload_url = f"{GHCR}/v2/{repo}/blobs/uploads/"
    if mount_from:
        status, headers, _ = http(
            "POST",
            f"{upload_url}?mount={digest}&from={mount_from}",
            {"Authorization": f"Bearer {token}"},
            data=b"",
            ok=(201, 202),
        )
        if status == 201:
            return digest, "mounted"
        loc = headers.get("Location")
    else:
        _, headers, _ = http(
            "POST",
            upload_url,
            {"Authorization": f"Bearer {token}"},
            data=b"",
            ok=(202,),
        )
        loc = headers.get("Location")

    if not loc:
        die(f"no upload Location for {repo}")
    if loc.startswith("/"):
        loc = GHCR + loc
    sep = "&" if "?" in loc else "?"
    http(
        "PUT",
        f"{loc}{sep}digest={digest}",
        {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/octet-stream",
        },
        data=data,
        ok=(201,),
    )
    return digest, "uploaded"


def push_manifest(repo, tag, layer_digest, layer_size, platform, token, annotations=None):
    os_name, arch = {
        "macos-arm64": ("darwin", "arm64"),
        "macos-x86_64": ("darwin", "amd64"),
        "linux-x86_64": ("linux", "amd64"),
        "linux-aarch64": ("linux", "arm64"),
    }[platform]
    config = json.dumps({"architecture": arch, "os": os_name}).encode()
    config_digest, _ = push_blob(repo, config, token)
    manifest = {
        "schemaVersion": 2,
        "mediaType": MT_MANIFEST,
        "config": {
            "mediaType": MT_CONFIG,
            "digest": config_digest,
            "size": len(config),
        },
        "layers": [
            {
                "mediaType": MT_LAYER,
                "digest": layer_digest,
                "size": layer_size,
            }
        ],
        "annotations": {
            "org.opencontainers.image.source": SOURCE_ANNOTATION,
            **(annotations or {}),
        },
    }
    http(
        "PUT",
        f"{GHCR}/v2/{repo}/manifests/{tag}",
        {"Authorization": f"Bearer {token}", "Content-Type": MT_MANIFEST},
        data=json.dumps(manifest).encode(),
        ok=(201,),
    )


# ── registry helpers ─────────────────────────────────────────────────────────


def load_registry():
    return json.loads(REGISTRY_JSON.read_text())["records"]


def find_record(name):
    for r in load_registry():
        if r["token"] == name:
            return r
    die(f"'{name}' not in {REGISTRY_JSON.name}")


def ghcr_repo_name(token):
    """OCI repository paths forbid '@'; Homebrew maps versioned formulae the
    same way (node@22 -> .../node/22/...), which also keeps the
    NANOBREW_BOTTLE_DOMAIN URL rewrite path-compatible."""
    return token.replace("@", "/")


def mirror_repo(name):
    return f"{OWNER}/{PREFIX}/{ghcr_repo_name(name)}"


def mirror_url(name, sha256):
    return f"{GHCR}/v2/{mirror_repo(name)}/blobs/sha256:{sha256}"


def upstream_repo_from_url(url):
    """ghcr blob URL -> its repository path (handles versioned formulae)."""
    rest = url.split("/v2/", 1)
    if len(rest) != 2 or "/blobs/" not in rest[1]:
        return None
    return rest[1].split("/blobs/", 1)[0]


# ── subcommands ──────────────────────────────────────────────────────────────


def mirror_one(rec, args, src_token_cache):
    name, ver = rec["token"], rec["resolved"]["version"]
    repo = mirror_repo(name)
    dst_token = None
    for platform, asset in sorted(rec["resolved"]["assets"].items()):
        digest = "sha256:" + asset["sha256"]
        src_repo = upstream_repo_from_url(asset["url"]) or f"{UPSTREAM_REPO}/{ghcr_repo_name(name)}"
        if args.dry_run:
            src = src_token_cache.setdefault(
                src_repo,
                bearer_for(src_repo, pull_only=True, anonymous=True),
            )
            present = blob_exists(src_repo, digest, src)
            log(f"  [dry-run] {name} {ver} {platform}: source blob "
                f"{'OK' if present else 'MISSING'} ({digest[:19]}…)")
            continue
        dst_token = dst_token or bearer_for(repo)
        # Try cross-repo mount first (instant, no transfer); GHCR only
        # mounts across repos it can read with our token, so public
        # homebrew/core usually works. Fall back to pull+push.
        if blob_exists(repo, digest, dst_token):
            how, size = "exists", None
        else:
            _, how = push_blob(repo, b"", dst_token, mount_from=src_repo, digest=digest)
            size = None
            if how == "mounted":
                # GHCR sometimes acks a cross-repo mount with 201 while the
                # blob never lands (observed ~180 packages into a fleet
                # mirror — throttling). Verify; retry once; then do a real
                # pull+push so the run converges instead of half-mounting.
                if not blob_exists(repo, digest, dst_token):
                    time.sleep(1.5)
                    if not blob_exists(repo, digest, dst_token):
                        how = "upload-after-phantom-mount"
            if how != "mounted":
                src = src_token_cache.setdefault(
                    src_repo,
                    bearer_for(src_repo, pull_only=True, anonymous=True),
                )
                data = pull_blob(src_repo, digest, src)
                _, how = push_blob(repo, data, dst_token)
                size = len(data)
        # tag a manifest so GHCR never garbage-collects the blob
        blob_size = size
        if blob_size is None:
            _, h, _ = http("HEAD", f"{GHCR}/v2/{repo}/blobs/{digest}",
                           {"Authorization": f"Bearer {dst_token}"})
            blob_size = int(h.get("Content-Length", "0"))
        push_manifest(repo, f"{ver}.{platform}", digest, blob_size, platform,
                      dst_token, {"sh.brew.bottle.upstream": src_repo})
        log(f"  {name} {ver} {platform}: {how}")


def cmd_mirror(args):
    records = [
        r
        for r in load_registry()
        if r["upstream"]["type"] == "homebrew_bottle"
        and r.get("resolved", {}).get("assets")
    ]
    if args.only:
        wanted = set(args.only.split(","))
        records = [r for r in records if r["token"] in wanted]
        missing = wanted - {r["token"] for r in records}
        if missing:
            die(f"not homebrew_bottle records: {sorted(missing)}")
    if args.limit:
        records = records[: args.limit]
    log(f"mirroring {len(records)} package(s) -> ghcr.io/{OWNER}/{PREFIX}/<name>")

    src_token_cache = {}
    failures = []
    for rec in records:
        # One bad package (renamed upstream repo, GC'd blob, naming edge
        # case) must not abort a fleet-wide run — collect and report.
        try:
            mirror_one(rec, args, src_token_cache)
        except SystemExit:
            failures.append(rec["token"])
            log(f"  {rec['token']}: FAILED — continuing")
        if not args.dry_run:
            time.sleep(0.2)  # pace fleet runs below GHCR's throttling radar
    if args.dry_run:
        log("dry-run complete (no writes)")
    if failures:
        log(f"{len(failures)} package(s) failed: {', '.join(failures)}")
        sys.exit(1)
def cmd_repackage(args):
    rec = find_record(args.name)
    if rec["upstream"]["type"] != "github_release":
        die(f"'{args.name}' is {rec['upstream']['type']}, repackage handles github_release")
    resolved = rec.get("resolved") or die(f"'{args.name}' has no resolved assets")
    ver = resolved["version"]
    artifacts = [a["path"] for a in rec.get("artifacts", []) if a.get("type") == "binary"]
    if not artifacts:
        die(f"'{args.name}' declares no binary artifacts")
    dist = REPO_ROOT / "dist"
    dist.mkdir(exist_ok=True)
    new_assets = {}

    for platform, asset in sorted(resolved["assets"].items()):
        log(f"  {args.name} {ver} {platform}: fetching {asset['url']}")
        _, _, payload = http("GET", asset["url"])
        got = hashlib.sha256(payload).hexdigest()
        if got != asset["sha256"]:
            die(f"upstream sha mismatch for {platform}: {got}")

        # find each declared binary inside the upstream archive by basename
        members = {}
        if asset["url"].endswith(".zip"):
            zf = zipfile.ZipFile(io.BytesIO(payload))
            for info in zf.infolist():
                members[Path(info.filename).name] = ("zip", zf, info)
        else:
            tf = tarfile.open(fileobj=io.BytesIO(payload), mode="r:*")
            for info in tf.getmembers():
                if info.isfile():
                    members[Path(info.name).name] = ("tar", tf, info)

        out = dist / f"{args.name}-{ver}.{platform}.tar.gz"
        with tarfile.open(out, "w:gz") as bottle:
            for rel in artifacts:
                base = Path(rel).name
                if base not in members:
                    die(f"binary '{base}' not found in upstream archive for {platform}")
                kind, archive, info = members[base]
                data = archive.read(info) if kind == "zip" else archive.extractfile(info).read()
                # Bottle kegs link from <name>/<version>/bin/ — normalize
                # whatever layout upstream used (bare 'rg', 'usr/bin/podman')
                # into bin/<basename> so linkFormulaKeg finds it.
                ti = tarfile.TarInfo(f"{args.name}/{ver}/bin/{base}")
                ti.size = len(data)
                ti.mode = 0o755
                bottle.addfile(ti, io.BytesIO(data))
        sha = hashlib.sha256(out.read_bytes()).hexdigest()
        log(f"  wrote {out.name}  sha256={sha}")
        new_assets[platform] = sha
        if not args.no_publish:
            do_publish(args.name, ver, platform, out)

    # Registry snippet with the NEW bottle digests (a repackaged tarball's
    # sha differs from the upstream release asset it was built from).
    log("\nregistry snippet (paste into registry_default.json / registry/upstream.json):")
    print(json.dumps({
        "token": rec["token"],
        "name": rec["name"],
        "kind": "formula",
        "homepage": rec.get("homepage", ""),
        "desc": rec.get("desc", ""),
        "dependencies": rec.get("dependencies", []),
        "upstream": {"type": "homebrew_bottle", "verified": True},
        "resolved": {
            "version": ver,
            "assets": {
                platform: {"url": mirror_url(rec["token"], sha), "sha256": sha}
                for platform, sha in sorted(new_assets.items())
            },
        },
    }, indent=2))


def do_publish(name, ver, platform, path):
    repo = mirror_repo(name)
    token = bearer_for(repo)
    data = Path(path).read_bytes()
    digest, how = push_blob(repo, data, token)
    push_manifest(repo, f"{ver}.{platform}", digest, len(data), platform, token)
    log(f"  published ghcr.io/{repo}@{digest} ({how}, tag {ver}.{platform})")
    return digest


def cmd_publish(args):
    do_publish(args.name, args.version, args.platform, args.file)


def cmd_verify(args):
    rec = find_record(args.name)
    assets = (rec.get("resolved") or {}).get("assets") or die("no resolved assets")
    repo = mirror_repo(args.name)
    try:
        token = bearer_for(repo, pull_only=True, anonymous=True)
    except SystemExit:
        die(
            f"package is PRIVATE (anonymous token refused). Flip it public once:\n"
            f"  https://github.com/users/{OWNER}/packages/container/"
            f"{urllib.parse.quote(f'{PREFIX}/{args.name}', safe='')}/settings\n"
            f"then re-run: nb_bottles.py verify {args.name}"
        )
    ok = True
    for platform, asset in sorted(assets.items()):
        digest = "sha256:" + asset["sha256"]
        try:
            data = pull_blob(repo, digest, token)
            log(f"  {platform}: OK ({len(data)} bytes, anonymous pull, digest verified)")
        except SystemExit:
            ok = False
            log(f"  {platform}: FAILED (not public, missing, or corrupt)")
    sys.exit(0 if ok else 1)


def cmd_pin(args):
    """Create a homebrew_bottle registry record for ANY Homebrew formula by
    reading the live API, optionally mirroring its blobs to our namespace."""
    _, _, body = http("GET", f"https://formulae.brew.sh/api/formula/{args.name}.json")
    api = json.loads(body)
    stable = api["versions"]["stable"]
    revision = api.get("revision", 0)
    version = stable + (f"_{revision}" if revision else "")
    files = api["bottle"]["stable"]["files"]

    tag_preference = {
        "macos-arm64": ("arm64_tahoe", "arm64_sequoia", "arm64_sonoma", "all"),
        "macos-x86_64": ("tahoe", "sequoia", "sonoma", "ventura", "all"),
        "linux-x86_64": ("x86_64_linux", "all"),
        "linux-aarch64": ("arm64_linux", "all"),
    }
    assets = {}
    for platform, tags in tag_preference.items():
        for tag in tags:
            if tag in files:
                assets[platform] = {
                    "url": files[tag]["url"],
                    "sha256": files[tag]["sha256"],
                }
                break
    if not assets:
        die(f"no usable bottle tags for {args.name} (have: {sorted(files)})")

    record = {
        "token": api["name"],
        "name": api["name"],
        "kind": "formula",
        "homepage": api.get("homepage", ""),
        "desc": api.get("desc", ""),
        "revision": revision,
        "rebuild": api["bottle"]["stable"].get("rebuild", 0),
        "dependencies": api.get("dependencies", []),
        "build_dependencies": api.get("build_dependencies", []),
        "upstream": {"type": "homebrew_bottle", "verified": True},
        "verification": {"sha256": "required"},
        "resolved": {"version": version, "assets": assets},
    }

    if args.add:
        reg = json.loads(REGISTRY_JSON.read_text())
        if any(r["token"] == record["token"] for r in reg["records"]):
            die(f"'{record['token']}' already in registry")
        reg["records"].append(record)
        REGISTRY_JSON.write_text(json.dumps(reg, indent=2) + "\n")
        log(f"appended '{record['token']}' to {REGISTRY_JSON.name} ({len(reg['records'])} records)")
    else:
        print(json.dumps(record, indent=2))

    if args.mirror:
        repo = mirror_repo(record["token"])
        token = bearer_for(repo)
        for platform, asset in sorted(assets.items()):
            digest = "sha256:" + asset["sha256"]
            src_repo = upstream_repo_from_url(asset["url"]) or f"{UPSTREAM_REPO}/{ghcr_repo_name(record['token'])}"
            if blob_exists(repo, digest, token):
                how = "exists"
            else:
                _, how = push_blob(repo, b"", token,
                                   mount_from=src_repo, digest=digest)
                if how != "mounted":
                    src = bearer_for(src_repo, pull_only=True, anonymous=True)
                    data = pull_blob(src_repo, digest, src)
                    _, how = push_blob(repo, data, token)
            _, h, _ = http("HEAD", f"{GHCR}/v2/{repo}/blobs/{digest}",
                           {"Authorization": f"Bearer {token}"})
            push_manifest(repo, f"{version}.{platform}", digest,
                          int(h.get("Content-Length", "0")), platform, token,
                          {"sh.brew.bottle.upstream": f"{UPSTREAM_REPO}/{record['token']}"})
            log(f"  {record['token']} {version} {platform}: {how}")


def cmd_tier2(args):
    """Print tokens of every github_release formula eligible for repackage:
    binary artifacts declared, resolved assets present, core (non-tap) name."""
    for r in load_registry():
        if r["kind"] != "formula" or r["upstream"]["type"] != "github_release":
            continue
        if "/" in r["token"]:
            continue  # tap-namespaced — add individually if ever wanted
        if not (r.get("resolved") or {}).get("assets"):
            continue
        if not any(a.get("type") == "binary" for a in r.get("artifacts", [])):
            continue
        print(r["token"])


def cmd_record(args):
    rec = find_record(args.name)
    resolved = rec.get("resolved") or die("no resolved assets")
    out = {
        "token": rec["token"],
        "name": rec["name"],
        "kind": "formula",
        "homepage": rec.get("homepage", ""),
        "desc": rec.get("desc", ""),
        "dependencies": rec.get("dependencies", []),
        "upstream": {"type": "homebrew_bottle", "verified": True},
        "resolved": {
            "version": resolved["version"],
            "assets": {
                platform: {
                    "url": mirror_url(rec["token"], asset["sha256"]),
                    "sha256": asset["sha256"],
                }
                for platform, asset in sorted(resolved["assets"].items())
            },
        },
    }
    print(json.dumps(out, indent=2))


def main():
    p = argparse.ArgumentParser(prog="nb_bottles", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("mirror", help="Tier 1: mirror pinned homebrew bottles")
    m.add_argument("--only", help="comma-separated package names")
    m.add_argument("--limit", type=int, help="stop after N packages")
    m.add_argument("--dry-run", action="store_true")
    m.set_defaults(fn=cmd_mirror)

    r = sub.add_parser("repackage", help="Tier 2: upstream release -> bottle")
    r.add_argument("name")
    r.add_argument("--no-publish", action="store_true", help="build tarballs only")
    r.set_defaults(fn=cmd_repackage)

    pub = sub.add_parser("publish", help="push one bottle tarball")
    pub.add_argument("name")
    pub.add_argument("version")
    pub.add_argument("platform", choices=PLATFORMS)
    pub.add_argument("file")
    pub.set_defaults(fn=cmd_publish)

    v = sub.add_parser("verify", help="anonymous-pull mirrored blobs, check digests")
    v.add_argument("name")
    v.set_defaults(fn=cmd_verify)

    pn = sub.add_parser("pin", help="pin ANY Homebrew formula as a registry record")
    pn.add_argument("name")
    pn.add_argument("--add", action="store_true", help="append to registry_default.json")
    pn.add_argument("--mirror", action="store_true", help="also mirror its blobs to our namespace")
    pn.set_defaults(fn=cmd_pin)

    t2 = sub.add_parser("tier2", help="list github_release formulae eligible for repackage")
    t2.set_defaults(fn=cmd_tier2)

    rc = sub.add_parser("record", help="print registry snippet for the mirror")
    rc.add_argument("name")
    rc.set_defaults(fn=cmd_record)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
