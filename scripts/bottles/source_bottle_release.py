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


def add_recipe_identity(sbom, evidence):
    # Syft does not currently discover zlib from this C library's Mach-O files.
    # Add the identity established by the checksum-pinned recipe, preserving
    # the scanner's file inventory. Grype can match this explicit CPE.
    package_id = "SPDXRef-nanobrew-zlib"
    package = {"SPDXID": package_id, "name": "zlib", "versionInfo": evidence["version"],
               "downloadLocation": evidence["source_url"], "filesAnalyzed": False,
               "licenseConcluded": "NOASSERTION", "licenseDeclared": "Zlib",
               "copyrightText": "NOASSERTION",
               "sourceInfo": "Identity from the checksum-verified Nanobrew source recipe",
               "checksums": [{"algorithm": "SHA256", "checksumValue": evidence["source_sha256"]}],
               "externalRefs": [
                   {"referenceCategory": "SECURITY", "referenceType": "cpe23Type",
                    "referenceLocator": f"cpe:2.3:a:zlib:zlib:{evidence['version']}:*:*:*:*:*:*:*"},
                   {"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                    "referenceLocator": f"pkg:generic/zlib@{evidence['version']}"}]}
    sbom["packages"] = [p for p in sbom.get("packages", []) if p["SPDXID"] != package_id] + [package]
    relation = {"spdxElementId": sbom["SPDXID"], "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_id}
    relations = sbom.setdefault("relationships", [])
    if relation not in relations:
        relations.append(relation)
    return sbom


def prepare_registry(registry, evidence, url):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "publish", "annotate-sbom"])
    args = parser.parse_args()
    evidence = json.loads(EVIDENCE.read_text())
    digest = hashlib.sha256(BOTTLE.read_bytes()).hexdigest()
    if (digest != evidence["bottle_sha256"] or evidence["package"] != "zlib"
            or evidence["version"] != "1.3.2" or evidence["platform"] != "macos-x86_64"):
        raise ValueError("Bottle/evidence identity mismatch")
    if args.command == "annotate-sbom":
        sbom_path = DIST / "zlib.spdx.json"
        sbom = add_recipe_identity(json.loads(sbom_path.read_text()), evidence)
        sbom_path.write_text(json.dumps(sbom, indent=2) + "\n")
        return
    repo = bottles.mirror_repo("zlib")
    url = f"https://ghcr.io/v2/{repo}/blobs/sha256:{digest}"
    registry = json.loads(bottles.REGISTRY_JSON.read_text())
    prepare_registry(registry, evidence, url)
    if args.command == "publish":
        if evidence["host_arch"] != "x86_64":
            raise ValueError("Publishing requires native Intel build evidence")
        # Distinct tags preserve existing Homebrew mirror tags and previous builds.
        build_id = os.environ.get("GITHUB_RUN_ID", "")
        attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
        if not re.fullmatch(r"[0-9]+", build_id) or not re.fullmatch(r"[0-9]+", attempt):
            raise ValueError("Publishing must run in GitHub Actions")
        version_tag = f"1.3.2-source-{build_id}-{attempt}"
        bottles.do_publish("zlib", version_tag, "macos-x86_64", BOTTLE)
        anonymous = bottles.bearer_for(repo, pull_only=True, anonymous=True)
        pulled = bottles.pull_blob(repo, "sha256:" + digest, anonymous)
        if pulled != BOTTLE.read_bytes():
            raise ValueError("Anonymous pull did not match the built bottle")
        print(f"Verified public bottle: {url}")
    (DIST / "registry-intel.json").write_text(json.dumps(registry, indent=2) + "\n")
    (DIST / "SHA256SUMS").write_text(f"{digest}  {BOTTLE.name}\n")


if __name__ == "__main__":
    main()
