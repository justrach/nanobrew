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
  scan       SBOM (syft) + vulnerability match (grype) for pinned bottles;
             exits non-zero when findings meet the severity gate.
  revoke     Mark a pinned version revoked (CVE'd) and record the previous
             known-good version from git history as the install fallback.
  unrevoke   Clear a revocation after the pin moves to a patched version.

Stdlib only (scan additionally shells out to syft + grype on PATH). Auth:
GHCR_TOKEN env var, or `gh auth token` (needs the write:packages scope for
pushes; reads of public packages are anonymous).
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
MT_INDEX = "application/vnd.oci.image.index.v1+json"
MT_EMPTY = "application/vnd.oci.empty.v1+json"
AT_SBOM = "application/spdx+json"
AT_SCAN = "application/vnd.nanobrew.scan-report+json"

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
    # Version tags are immutable contracts. nb itself never trusts tags (it
    # pulls by pinned digest), but the tag is what pins the blob against GC
    # and what humans audit — re-tagging different bytes under an existing
    # version corrupts both. A version bump is a NEW tag; same-digest
    # re-pushes stay idempotent.
    status, _, existing = http(
        "GET",
        f"{GHCR}/v2/{repo}/manifests/{tag}",
        {"Authorization": f"Bearer {token}", "Accept": MT_MANIFEST},
        ok=(200, 404),
    )
    if status == 200:
        try:
            old_layers = [l["digest"] for l in json.loads(existing).get("layers", [])]
        except json.JSONDecodeError:
            old_layers = []
        if old_layers and layer_digest not in old_layers:
            die(
                f"refusing to overwrite tag '{tag}' on {repo}: it points at "
                f"{old_layers[0][:19]}…, not {layer_digest[:19]}… — version "
                f"tags are immutable; bump the version instead"
            )

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


def merged_dependencies(api):
    """Runtime dependency closure nb should install for a pinned formula.

    Homebrew's ``dependencies`` is the macOS closure. ``uses_from_macos`` deps
    are provided by macOS but are real runtime dependencies on Linux
    (autoconf->perl, perl->libxcrypt) -- and nb folds them in on macOS too, so
    storing the union keeps the pinned record consistent with the live-API
    resolver on both platforms (#324). Object-form entries ({"bison": "build"})
    are build/test scoped, not runtime, and are skipped.
    """
    deps = list(api.get("dependencies", []) or [])
    for u in api.get("uses_from_macos", []) or []:
        if isinstance(u, str) and u not in deps:
            deps.append(u)
    return deps


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
        "dependencies": merged_dependencies(api),
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


# ── security: attestation / provenance verification ─────────────────────────

BULK_CHECKSUM_HINTS = ("checksums", "sha256sums", "shasums", "sha256sum.txt")


def _release_assets_by_tag(repo, tag):
    headers = {"Accept": "application/vnd.github+json"}
    tok = pat()
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    _, _, body = http(
        "GET", f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers
    )
    return json.loads(body).get("assets", [])


def _checksum_from_release(rel_assets, asset_name, expected_sha):
    """Cross-check our pinned sha256 against the checksum file upstream
    published alongside the release. Returns 'checksum-file' on a match,
    None when no checksum asset covers this file; dies on a mismatch
    (a mismatch means the pin and upstream's own statement disagree —
    never ship that)."""
    candidates = []
    for a in rel_assets:
        low = a["name"].lower()
        if low in (f"{asset_name.lower()}.sha256", f"{asset_name.lower()}.sha256sum"):
            candidates.append(a)  # per-file digest
        elif any(h in low for h in BULK_CHECKSUM_HINTS) and not low.endswith((".sig", ".pem", ".asc")):
            candidates.append(a)  # bulk digest list
    for a in candidates:
        _, _, body = http("GET", a["browser_download_url"])
        for line in body.decode(errors="replace").splitlines():
            parts = line.strip().split()
            if not parts or len(parts[0]) != 64:
                continue
            listed = parts[1].lstrip("*").lstrip("./") if len(parts) > 1 else asset_name
            if listed == asset_name or listed.endswith("/" + asset_name):
                if parts[0].lower() != expected_sha.lower():
                    die(
                        f"CHECKSUM MISMATCH for {asset_name}: upstream "
                        f"{a['name']} says {parts[0][:16]}…, our pin says "
                        f"{expected_sha[:16]}… — refusing to continue"
                    )
                return "checksum-file"
    return None


def _gh_attestation_verify(path, repo):
    """GitHub artifact attestation (sigstore provenance) via the gh CLI.
    Returns True (verified), False (attestation exists but failed / none
    found), or None (gh unavailable — can't say)."""
    import shutil

    if not shutil.which("gh"):
        return None
    r = subprocess.run(
        ["gh", "attestation", "verify", str(path), "--repo", repo],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        return True
    # "no attestations found" is an expected miss, not a failure to scream about
    return False


def _verify_upstream_asset(repo, tag, asset_name, payload, expected_sha, rel_assets):
    """Strongest provenance statement available for one release asset:
    github-attestation > checksum-file > pin-only. The pinned sha256 is
    always enforced by the caller; this adds upstream's own vouching."""
    import tempfile

    with tempfile.NamedTemporaryFile(suffix="-" + asset_name) as tf:
        tf.write(payload)
        tf.flush()
        attested = _gh_attestation_verify(tf.name, repo)
    if attested:
        return "github-attestation"
    if _checksum_from_release(rel_assets, asset_name, expected_sha):
        return "checksum-file"
    return "pin-only"


def cmd_attest(args):
    """Verify provenance of every pinned upstream asset for a package."""
    rec = find_record(args.name)
    if rec["upstream"]["type"] != "github_release":
        die(f"'{args.name}' is {rec['upstream']['type']} — attest covers github_release records")
    resolved = rec.get("resolved") or die(f"'{args.name}' has no resolved assets")
    repo = rec["upstream"]["repo"]
    tag = resolved.get("tag") or "v" + resolved["version"]
    rel_assets = _release_assets_by_tag(repo, tag)
    worst, methods = "github-attestation", {}
    rank = {"github-attestation": 2, "checksum-file": 1, "pin-only": 0}
    for platform, asset in sorted(resolved["assets"].items()):
        name = asset["url"].rsplit("/", 1)[-1]
        _, _, payload = http("GET", asset["url"])
        got = hashlib.sha256(payload).hexdigest()
        if got != asset["sha256"]:
            die(f"pin mismatch downloading {name}: {got}")
        method = _verify_upstream_asset(repo, tag, name, payload, asset["sha256"], rel_assets)
        methods[platform] = method
        if rank[method] < rank[worst]:
            worst = method
        log(f"  {args.name} {resolved['version']} {platform}: {method}")
    log(f"\nweakest link: {worst}")
    if args.require and rank[worst] < rank[args.require]:
        die(f"verification below --require {args.require}")


# ── security: scan + revoke ──────────────────────────────────────────────────

SEVERITIES = ("negligible", "low", "medium", "high", "critical")


def _require_tool(name, hint):
    import shutil

    if not shutil.which(name):
        die(f"'{name}' not on PATH — install it first ({hint})")


def _bottle_bytes(rec, platform, asset):
    """Bottle tarball bytes for one platform: local dist/ build if present,
    else anonymous pull from whichever GHCR namespace the registry points at,
    else direct download. Always digest-verified."""
    name, ver = rec["token"], rec["resolved"]["version"]
    local = REPO_ROOT / "dist" / f"{name}-{ver}.{platform}.tar.gz"
    if local.exists():
        data = local.read_bytes()
        if hashlib.sha256(data).hexdigest() == asset["sha256"]:
            return data, "dist"
    url = asset["url"]
    repo = upstream_repo_from_url(url)
    if repo:
        token = bearer_for(repo, pull_only=True, anonymous=True)
        return pull_blob(repo, "sha256:" + asset["sha256"], token), "ghcr"
    _, _, data = http("GET", url)
    got = hashlib.sha256(data).hexdigest()
    if got != asset["sha256"]:
        die(f"digest mismatch downloading {url}: {got}")
    return data, "upstream"


def _scan_one(rec, platforms, outdir):
    """syft SBOM + grype match for every requested platform of one package.
    Returns [(platform, [finding, ...]), ...]; writes SBOMs + reports under
    outdir so CI can attach them and the weekly rescan can reuse them."""
    import tempfile

    name, ver = rec["token"], rec["resolved"]["version"]
    results = []
    for platform, asset in sorted(rec["resolved"]["assets"].items()):
        if platforms and platform not in platforms:
            continue
        data, origin = _bottle_bytes(rec, platform, asset)
        sbom_path = outdir / f"{name}-{ver}.{platform}.spdx.json"
        # Extract and scan as a directory: syft's binary catalogers (Go
        # buildinfo, cargo-auditable, ELF/Mach-O classifiers) only run on
        # real files, not on an opaque tarball path.
        with tempfile.TemporaryDirectory() as td:
            if data[:4] == b"PK\x03\x04":
                zipfile.ZipFile(io.BytesIO(data)).extractall(td)
            else:
                with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tf:
                    tf.extractall(td, filter="data")
            subprocess.run(
                ["syft", "scan", f"dir:{td}", "-q", "-o", f"spdx-json={sbom_path}"],
                check=True,
            )
        out = subprocess.run(
            ["grype", f"sbom:{sbom_path}", "-q", "-o", "json"],
            check=True, capture_output=True, text=True,
        ).stdout
        report_path = outdir / f"{name}-{ver}.{platform}.grype.json"
        report_path.write_text(out)
        findings = []
        for match in json.loads(out).get("matches", []):
            vuln = match.get("vulnerability", {})
            art = match.get("artifact", {})
            fix = vuln.get("fix", {})
            findings.append({
                "id": vuln.get("id", ""),
                "severity": vuln.get("severity", "Unknown").lower(),
                "package": art.get("name", ""),
                "version": art.get("version", ""),
                "fixed_in": ", ".join(fix.get("versions", [])),
            })
        log(f"  {name} {ver} {platform}: {len(findings)} finding(s) "
            f"(bottle from {origin}, sbom {sbom_path.name})")
        for f in findings:
            log(f"    [{f['severity']}] {f['id']} {f['package']} {f['version']}"
                + (f" (fixed in {f['fixed_in']})" if f["fixed_in"] else ""))
        results.append((platform, findings))
    return results


def cmd_scan(args):
    _require_tool("syft", "nb install syft / brew install syft")
    _require_tool("grype", "nb install grype / brew install grype")
    platforms = args.platforms.split(",") if args.platforms else None
    for p in platforms or []:
        if p not in PLATFORMS:
            die(f"unknown platform '{p}' (have: {', '.join(PLATFORMS)})")
    gate_rank = SEVERITIES.index(args.gate)

    if args.all:
        records = [r for r in load_registry()
                   if r["kind"] == "formula" and (r.get("resolved") or {}).get("assets")]
    elif args.names:
        records = [find_record(n) for n in args.names]
    else:
        die("pass package names or --all")

    outdir = REPO_ROOT / "dist" / "scan"
    outdir.mkdir(parents=True, exist_ok=True)
    summary, gated = {}, []
    for rec in records:
        for platform, findings in _scan_one(rec, platforms, outdir):
            summary[f"{rec['token']}.{platform}"] = findings
            for f in findings:
                if f["severity"] in SEVERITIES and SEVERITIES.index(f["severity"]) >= gate_rank:
                    gated.append((rec["token"], rec["resolved"]["version"], platform, f))
        if args.push_evidence:
            # Evidence goes up even when the gate will fail — a bad verdict
            # is exactly the one consumers most need to see on the registry.
            try:
                _push_evidence_for(rec, platforms)
            except SystemExit:
                log(f"  {rec['token']}: evidence push failed (no write token?) — continuing")

    (outdir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    log(f"\nscanned {len(records)} package(s); summary -> {outdir / 'summary.json'}")
    if gated:
        log(f"\nGATE FAILED — {len(gated)} finding(s) at or above '{args.gate}':")
        for name, ver, platform, f in gated:
            log(f"  {name} {ver} ({platform}): [{f['severity']}] {f['id']} "
                f"in {f['package']} {f['version']}"
                + (f" — fixed in {f['fixed_in']}" if f["fixed_in"] else ""))
        log("\nto pull the affected pin while keeping installs working:")
        for name in sorted({g[0] for g in gated}):
            log(f"  python3 scripts/bottles/nb_bottles.py revoke {name} "
                f"--advisory <CVE-id> --reason '<summary>'")
        sys.exit(1)


def _manifest_descriptor(repo, tag, token):
    """Digest + size of an existing (bottle) manifest, for use as a subject."""
    status, headers, body = http(
        "GET",
        f"{GHCR}/v2/{repo}/manifests/{tag}",
        {"Authorization": f"Bearer {token}", "Accept": MT_MANIFEST},
        ok=(200, 404),
    )
    if status == 404:
        return None
    return {
        "mediaType": headers.get("Content-Type", MT_MANIFEST),
        "digest": headers.get("Docker-Content-Digest")
        or ("sha256:" + hashlib.sha256(body).hexdigest()),
        "size": len(body),
    }


def _push_referrer(repo, subject, artifact_type, payload, annotations, token):
    """Push one evidence artifact (SBOM / scan report) referring to `subject`.

    GHCR's OCI-1.1 referrers endpoint is broken (303 to a URL its own router
    can't parse — probed 2026-06-12), so after pushing the manifest-with-
    subject we also maintain the spec's fallback: an OCI image index tagged
    `sha256-<subject digest>` listing every referrer. `oras discover` and
    friends use exactly that tag when the API is missing. Returns the
    referrer manifest digest."""
    layer_digest, _ = push_blob(repo, payload, token)
    empty_digest, _ = push_blob(repo, b"{}", token)
    manifest = {
        "schemaVersion": 2,
        "mediaType": MT_MANIFEST,
        "artifactType": artifact_type,
        "config": {"mediaType": MT_EMPTY, "digest": empty_digest, "size": 2},
        "layers": [{
            "mediaType": artifact_type,
            "digest": layer_digest,
            "size": len(payload),
        }],
        "subject": subject,
        "annotations": {
            "org.opencontainers.image.source": SOURCE_ANNOTATION,
            **annotations,
        },
    }
    body = json.dumps(manifest).encode()
    digest = "sha256:" + hashlib.sha256(body).hexdigest()
    http(
        "PUT",
        f"{GHCR}/v2/{repo}/manifests/{digest}",
        {"Authorization": f"Bearer {token}", "Content-Type": MT_MANIFEST},
        data=body,
        ok=(201,),
    )

    # Fallback-tag index: read-modify-write the sha256-<digest> tag.
    fallback_tag = subject["digest"].replace(":", "-")
    status, _, idx_body = http(
        "GET",
        f"{GHCR}/v2/{repo}/manifests/{fallback_tag}",
        {"Authorization": f"Bearer {token}", "Accept": MT_INDEX},
        ok=(200, 404),
    )
    manifests = []
    if status == 200:
        try:
            manifests = json.loads(idx_body).get("manifests", [])
        except json.JSONDecodeError:
            manifests = []
    descriptor = {
        "mediaType": MT_MANIFEST,
        "digest": digest,
        "size": len(body),
        "artifactType": artifact_type,
        "annotations": annotations,
    }
    # Idempotent re-push; also drop stale referrers of the same artifact
    # type + version (a re-scan supersedes the previous report).
    same_kind = lambda m: (
        m.get("artifactType") == artifact_type
        and m.get("annotations", {}).get("vnd.nanobrew.version")
        == annotations.get("vnd.nanobrew.version")
    )
    manifests = [m for m in manifests if m.get("digest") != digest and not same_kind(m)]
    manifests.append(descriptor)
    index = {"schemaVersion": 2, "mediaType": MT_INDEX, "manifests": manifests}
    http(
        "PUT",
        f"{GHCR}/v2/{repo}/manifests/{fallback_tag}",
        {"Authorization": f"Bearer {token}", "Content-Type": MT_INDEX},
        data=json.dumps(index).encode(),
        ok=(201,),
    )
    return digest


def _push_evidence_for(rec, platforms=None):
    """Attach dist/scan/ SBOMs + grype reports for one package to its bottle
    manifests on GHCR (referrer manifests + fallback tag). Returns the count
    of artifacts pushed."""
    scan_dir = REPO_ROOT / "dist" / "scan"
    name, ver = rec["token"], rec["resolved"]["version"]
    repo = mirror_repo(name)
    token = bearer_for(repo)
    pushed = 0
    for platform in sorted(rec["resolved"]["assets"]):
        if platforms and platform not in platforms:
            continue
        subject = _manifest_descriptor(repo, f"{ver}.{platform}", token)
        if not subject:
            log(f"  {name} {ver} {platform}: no bottle manifest on GHCR — skipped")
            continue
        annotations = {
            "vnd.nanobrew.version": f"{ver}.{platform}",
            "org.opencontainers.image.created":
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        for suffix, artifact_type in ((".spdx.json", AT_SBOM), (".grype.json", AT_SCAN)):
            path = scan_dir / f"{name}-{ver}.{platform}{suffix}"
            if not path.exists():
                log(f"  {name} {ver} {platform}: {path.name} missing — run scan first")
                continue
            digest = _push_referrer(
                repo, subject, artifact_type, path.read_bytes(), annotations, token
            )
            log(f"  {name} {ver} {platform}: {suffix.lstrip('.')} -> {digest[:19]}…")
            pushed += 1
    return pushed


def cmd_push_evidence(args):
    rec = find_record(args.name)
    if not _push_evidence_for(rec):
        die("nothing pushed (no scan output and/or no bottle manifests)")
    log(f"\ndiscover with: oras discover ghcr.io/{mirror_repo(args.name)}:"
        f"{rec['resolved']['version']}.<platform>")


def _registry_files():
    paths = [REGISTRY_JSON]
    published = REPO_ROOT / "registry" / "upstream.json"
    if published.exists():
        paths.append(published)
    return paths


def _previous_resolved_from_git(token, current_version, want=None):
    """Most recent resolved block for `token` (in the embedded registry's git
    history) whose version differs from the current pin — the natural
    fallback when the current pin gets revoked. Pass `want` to demand one
    specific historical version instead of the most recent."""
    rel = REGISTRY_JSON.relative_to(REPO_ROOT)
    shas = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "log", "--format=%H", "-n", "500", "--", str(rel)],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    for sha in shas:
        show = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "show", f"{sha}:{rel}"],
            capture_output=True, text=True,
        )
        if show.returncode != 0:
            continue
        try:
            records = json.loads(show.stdout)["records"]
        except (json.JSONDecodeError, KeyError):
            continue
        for r in records:
            if r["token"] != token:
                continue
            resolved = r.get("resolved") or {}
            version = resolved.get("version")
            if version and version != current_version and (want is None or version == want):
                resolved.pop("revoked", None)
                resolved.pop("fallback", None)
                return resolved, sha
    return None, None


def _previous_resolved_from_upstream(rec, want=None):
    """Previous stable release of a github_release record, straight from the
    GitHub API — covers pins whose registry git history only ever saw one
    version. Asset digests come from the API when present, else from
    downloading + hashing (the same trust the original pin had)."""
    import fnmatch

    if rec["upstream"]["type"] != "github_release":
        return None, None
    patterns = rec.get("assets") or {}
    if not patterns:
        return None, None
    repo = rec["upstream"]["repo"]
    headers = {"Accept": "application/vnd.github+json"}
    tok = pat()
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    _, _, body = http("GET", f"https://api.github.com/repos/{repo}/releases?per_page=30", headers)
    cur_tag = rec["resolved"].get("tag") or ""
    cur_ver = rec["resolved"]["version"]
    seen_current = False
    for rel in json.loads(body):
        if rel.get("draft") or rel.get("prerelease"):
            continue
        tag = rel["tag_name"]
        version = tag[1:] if tag.startswith("v") else tag
        if not seen_current:
            if tag == cur_tag or version == cur_ver:
                seen_current = True
            continue
        if want and version != want:
            continue
        assets = {}
        rel_assets = rel.get("assets", [])
        for platform, rule in patterns.items():
            pattern = (rule.get("pattern") or "").replace("{tag}", tag).replace("{version}", version)
            hit = next((a for a in rel_assets if fnmatch.fnmatch(a["name"], pattern)), None)
            if not hit:
                continue
            digest = hit.get("digest") or ""
            if digest.startswith("sha256:"):
                sha = digest[len("sha256:"):]
            else:
                log(f"  hashing {hit['name']} (no API digest)…")
                _, _, data = http("GET", hit["browser_download_url"])
                sha = hashlib.sha256(data).hexdigest()
            assets[platform] = {"url": hit["browser_download_url"], "sha256": sha}
        if not assets:
            return None, None  # previous release lacks matching assets
        return {"tag": tag, "version": version, "assets": assets}, f"github:{repo}@{tag}"
    return None, None


def _previous_resolved(rec, want=None):
    """Fallback pin for a revocation: registry git history first (covers
    homebrew_bottle pins; digests were already vetted), then the upstream
    GitHub releases list (covers young registries with single-version
    history)."""
    fallback, src = _previous_resolved_from_git(rec["token"], rec["resolved"]["version"], want=want)
    if fallback:
        return fallback, f"git {src[:12]}"
    return _previous_resolved_from_upstream(rec, want=want)


def _edit_resolved(token, mutate):
    """Apply `mutate(resolved)` to `token`'s record in every registry file."""
    touched = 0
    for path in _registry_files():
        reg = json.loads(path.read_text())
        for r in reg["records"]:
            if r["token"] == token and r.get("resolved"):
                mutate(r["resolved"])
                touched += 1
        path.write_text(json.dumps(reg, indent=2) + "\n")
        log(f"  updated {path.relative_to(REPO_ROOT)}")
    if not touched:
        die(f"'{token}' has no resolved pin in any registry file")


def cmd_revoke(args):
    rec = find_record(args.name)
    resolved = rec.get("resolved") or die(f"'{args.name}' has no resolved pin")
    if not (args.advisory or args.reason):
        die("provide --advisory and/or --reason")
    ver = resolved["version"]

    fallback = None
    if args.fallback_version:
        fallback, src = _previous_resolved(rec, want=args.fallback_version)
        if not fallback:
            die(f"version '{args.fallback_version}' not found in registry git "
                f"history or upstream releases")
    elif not args.no_fallback:
        fallback, src = _previous_resolved(rec)
        if not fallback:
            log(f"  no previous version of '{args.name}' in registry git history "
                f"or upstream releases — revoking WITHOUT fallback (installs fail closed)")

    def mutate(resolved):
        resolved["revoked"] = {
            "advisory": args.advisory or "",
            "reason": args.reason or "",
        }
        if fallback:
            resolved["fallback"] = fallback
        else:
            resolved.pop("fallback", None)

    _edit_resolved(args.name, mutate)
    if fallback:
        log(f"revoked {args.name} {ver} -> installs fall back to {fallback['version']} "
            f"(from {src})")
    else:
        log(f"revoked {args.name} {ver} with NO fallback — `nb install {args.name}` "
            f"now fails closed until the pin is bumped")


def cmd_unrevoke(args):
    def mutate(resolved):
        resolved.pop("revoked", None)
        resolved.pop("fallback", None)

    _edit_resolved(args.name, mutate)
    log(f"cleared revocation on {args.name}")


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

    sc = sub.add_parser("scan", help="SBOM + vulnerability scan for pinned bottles")
    sc.add_argument("names", nargs="*", help="package tokens (or use --all)")
    sc.add_argument("--all", action="store_true", help="every formula with resolved assets")
    sc.add_argument("--platforms", help="comma-separated subset (default: all four)")
    sc.add_argument("--gate", choices=SEVERITIES, default="high",
                    help="exit non-zero at/above this severity (default: high)")
    sc.add_argument("--push-evidence", action="store_true",
                    help="also attach SBOM + report to the bottle on GHCR (needs write token)")
    sc.set_defaults(fn=cmd_scan)

    rv = sub.add_parser("revoke", help="revoke a CVE'd pin, fall back to previous version")
    rv.add_argument("name")
    rv.add_argument("--advisory", default="", help="CVE/GHSA id")
    rv.add_argument("--reason", default="", help="one-line summary")
    rv.add_argument("--fallback-version", help="pin a specific historical version as fallback")
    rv.add_argument("--no-fallback", action="store_true",
                    help="revoke without fallback (installs fail closed)")
    rv.set_defaults(fn=cmd_revoke)

    ur = sub.add_parser("unrevoke", help="clear a revocation (after the pin is bumped)")
    ur.add_argument("name")
    ur.set_defaults(fn=cmd_unrevoke)

    at = sub.add_parser("attest", help="verify provenance of pinned upstream assets")
    at.add_argument("name")
    at.add_argument("--require", choices=("checksum-file", "github-attestation"),
                    help="exit non-zero unless every asset meets this level")
    at.set_defaults(fn=cmd_attest)

    pe = sub.add_parser("push-evidence",
                        help="attach dist/scan/ SBOM + report to the bottle on GHCR (OCI referrers)")
    pe.add_argument("name")
    pe.set_defaults(fn=cmd_push_evidence)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
