#!/usr/bin/env python3
"""Prepare a source-bottle registry, or publish and verify its immutable blob."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

import nb_bottles as bottles

DIST = Path(__file__).resolve().parents[2] / "dist"
BOTTLE = DIST / "zlib-1.3.2.macos-x86_64.source.tar.gz"
EVIDENCE = BOTTLE.with_suffix(".json")
PACKAGES = ("zlib", "xz", "lz4", "openssl@3")
RECIPE_PATH = Path(__file__).with_name("intel-library-recipes.json")


def recipe_for(name):
    return None if name == "zlib" else json.loads(RECIPE_PATH.read_text())[name]


def add_recipe_identity(sbom, evidence):
    # Syft does not currently discover zlib from this C library's Mach-O files.
    # Add the identity established by the checksum-pinned recipe, preserving
    # the scanner's file inventory. Grype can match this explicit CPE.
    name = evidence.get("package", "zlib")
    recipe = recipe_for(name)
    vendor, product = {"zlib": ("zlib", "zlib"), "xz": ("tukaani", "xz"),
                       "lz4": ("lz4_project", "lz4"), "openssl@3": ("openssl", "openssl")}[name]
    package_id = "SPDXRef-nanobrew-" + name.replace("@", "-")
    package = {"SPDXID": package_id, "name": product, "versionInfo": evidence["version"],
               "downloadLocation": evidence["source_url"], "filesAnalyzed": False,
               "licenseConcluded": "NOASSERTION", "licenseDeclared": recipe["source_license"] if recipe else "Zlib",
               "copyrightText": "NOASSERTION",
               "sourceInfo": "Identity from the checksum-verified Nanobrew source recipe",
               "checksums": [{"algorithm": "SHA256", "checksumValue": evidence["source_sha256"]}],
               "externalRefs": [
                   {"referenceCategory": "SECURITY", "referenceType": "cpe23Type",
                    "referenceLocator": f"cpe:2.3:a:{vendor}:{product}:{evidence['version']}:*:*:*:*:*:*:*"},
                   {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                    "referenceLocator": f"pkg:generic/{product}@{evidence['version']}"}]}
    sbom["packages"] = [p for p in sbom.get("packages", []) if p["SPDXID"] != package_id] + [package]
    relation = {"spdxElementId": sbom["SPDXID"], "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_id}
    relations = sbom.setdefault("relationships", [])
    if relation not in relations:
        relations.append(relation)
    return sbom


def prepare_registry(registry, evidence, url):
    name = evidence.get("package", "zlib")
    if name != "zlib":
        return prepare_library_registry(registry, evidence, url)
    records = registry["records"]
    record = next((r for r in records if r["token"] == "zlib" and r["kind"] == "formula"), None)
    if record is None:
        record = {"token": "zlib", "name": "zlib", "kind": "formula",
                  "homepage": "https://zlib.net/", "desc": "General-purpose lossless data-compression library",
                  "dependencies": [], "upstream": {"type": "homebrew_bottle", "verified": True},
                  "resolved": {"version": evidence["version"], "assets": {}},
                  "verification": {"sha256": "required"}}
        records.append(record)
    resolved = record["resolved"]
    if (resolved["version"] != evidence["version"] or resolved.get("revision", 0) != 0
            or record["upstream"]["type"] != "homebrew_bottle"):
        raise ValueError("zlib registry version/type changed; review the recipe before publishing")
    resolved["assets"]["macos-x86_64"] = {"url": url, "sha256": evidence["bottle_sha256"]}
    return registry


def prepare_library_registry(registry, evidence, url):
    name = evidence["package"]
    recipe = recipe_for(name)
    meta = recipe["metadata"]
    if evidence["version"] != recipe["version"] or meta["versions"]["stable"] != recipe["version"]:
        raise ValueError("Recipe, metadata and source bottle versions must match")
    record = next((r for r in registry["records"] if r["token"] == name and r["kind"] == "formula"), None)
    old = (record or {}).get("resolved", {})
    if old.get("revoked"):
        raise ValueError("Revoked package requires explicit review before source promotion")
    # Each replacement version gets matching companion assets. Never attach an
    # old ARM/Linux binary to a new global version in the registry schema.
    files = meta["bottle"]["stable"]["files"]
    assets = {}
    for platform, tags in {"macos-arm64": ["arm64_sonoma", "arm64_sequoia", "arm64_tahoe", "arm64_golden_gate", "all"],
                           "linux-x86_64": ["x86_64_linux", "all"],
                           "linux-aarch64": ["arm64_linux", "aarch64_linux", "all"]}.items():
        asset = next((files[tag] for tag in tags if tag in files), None)
        if asset:
            assets[platform] = {"url": asset["url"], "sha256": asset["sha256"]}
        elif platform in old.get("assets", {}):
            raise ValueError(f"No matching-version companion for {name} {platform}")
    assets["macos-x86_64"] = {"url": url, "sha256": evidence["bottle_sha256"]}
    replacement = {"token": name, "name": name, "kind": "formula", "homepage": meta["homepage"],
                   "desc": meta["desc"], "dependencies": meta["dependencies"],
                   "upstream": {"type": "homebrew_bottle", "verified": True},
                   "verification": {"sha256": "required"},
                   "resolved": {"version": recipe["version"], "revision": meta["revision"],
                                "rebuild": meta["bottle"]["stable"]["rebuild"], "assets": assets}}
    if meta["revision"] != 0:
        raise ValueError("Recipe keg layout currently requires revision zero")
    if record is None:
        registry["records"].append(replacement)
    else:
        record.clear()
        record.update(replacement)
    return registry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "publish", "annotate-sbom"])
    parser.add_argument("--package", choices=PACKAGES, default="zlib")
    parser.add_argument("--merge", action="store_true", help="extend dist/registry-intel.json when present")
    args = parser.parse_args()
    name = args.package
    recipe = recipe_for(name)
    version = recipe["version"] if recipe else "1.3.2"
    bottle = DIST / f"{name}-{version}.macos-x86_64.source.tar.gz"
    evidence = json.loads(bottle.with_suffix(".json").read_text())
    digest = hashlib.sha256(bottle.read_bytes()).hexdigest()
    if (digest != evidence["bottle_sha256"] or evidence["package"] != name
            or evidence["version"] != version or evidence["platform"] != "macos-x86_64"):
        raise ValueError("Bottle/evidence identity mismatch")
    if recipe and evidence["source_sha256"] != recipe["source_sha256"]:
        raise ValueError("Evidence source checksum does not match the reviewed recipe")
    if args.command == "annotate-sbom":
        sbom_path = DIST / f"{name}.spdx.json"
        sbom = add_recipe_identity(json.loads(sbom_path.read_text()), evidence)
        sbom_path.write_text(json.dumps(sbom, indent=2) + "\n")
        return
    repo = bottles.mirror_repo(name)
    url = f"https://ghcr.io/v2/{repo}/blobs/sha256:{digest}"
    registry_file = DIST / "registry-intel.json" if args.merge and (DIST / "registry-intel.json").exists() else bottles.REGISTRY_JSON
    registry = json.loads(registry_file.read_text())
    prepare_registry(registry, evidence, url)
    if args.command == "publish":
        if evidence["host_arch"] != "x86_64":
            raise ValueError("Publishing requires native Intel build evidence")
        if name != "zlib" and not evidence.get("installed_tests"):
            raise ValueError("Publishing libraries requires installed consumer evidence")
        # Distinct tags preserve existing Homebrew mirror tags and previous builds.
        build_id = os.environ.get("GITHUB_RUN_ID", "")
        attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
        if not re.fullmatch(r"[0-9]+", build_id) or not re.fullmatch(r"[0-9]+", attempt):
            raise ValueError("Publishing must run in GitHub Actions")
        version_tag = f"{version}-source-{build_id}-{attempt}"
        bottles.do_publish(name, version_tag, "macos-x86_64", bottle)
        anonymous = bottles.bearer_for(repo, pull_only=True, anonymous=True)
        pulled = bottles.pull_blob(repo, "sha256:" + digest, anonymous)
        if pulled != bottle.read_bytes():
            raise ValueError("Anonymous pull did not match the built bottle")
        print(f"Verified public bottle: {url}")
    (DIST / "registry-intel.json").write_text(json.dumps(registry, indent=2) + "\n")
    checksums = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in sorted(DIST.glob("*.tar.gz"))]
    (DIST / "SHA256SUMS").write_text("".join(checksums))


if __name__ == "__main__":
    main()
