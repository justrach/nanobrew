#!/usr/bin/env python3
"""Publish the audited Intel Git stack as immutable GHCR bottles.

Opt-in companion to build_monterey_git.py: requires the build registry and the
installed-test evidence, re-validates every bottle against its build evidence
and recipe pins, publishes each blob under nb-bottles/<pkg> with a
run/attempt-scoped tag, pulls it back anonymously, then rewrites the asset
URLs into a publishable registry-monterey.json. No default registry changes.
"""
import hashlib
import json
import os
from pathlib import Path
import re

import nb_bottles as bottles
from build_monterey_git import RECIPES, ROOTS, order

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / 'dist/monterey'


def validate(name, record):
    """Return (bottle, digest, asset) once bottle, evidence, recipe and
    registry record agree; raise ValueError naming the package otherwise."""
    recipe = RECIPES[name]
    version = recipe['version']
    if record['resolved']['version'] != version:
        raise ValueError('Publish version differs: ' + name)
    bottle = DIST / f'{name}-{version}.monterey.bottle.tar.gz'
    evidence_path = bottle.with_suffix('.json')
    if not bottle.exists() or not evidence_path.exists():
        raise ValueError('Publish artifacts missing: ' + name)
    evidence = json.loads(evidence_path.read_text())
    if any(evidence.get(key) != value for key, value in recipe.items()):
        raise ValueError('Publish recipe differs: ' + name)
    if evidence.get('deployment_target') != '12.0' or evidence.get('host_arch') != 'x86_64':
        raise ValueError('Publish target differs: ' + name)
    digest = hashlib.sha256(bottle.read_bytes()).hexdigest()
    asset = record['resolved']['assets']['macos-x86_64']
    if digest != evidence.get('bottle_sha256') or digest != asset.get('sha256'):
        raise ValueError('Publish checksum differs: ' + name)
    return bottle, digest, asset


def publish_records(registry, publisher=bottles.do_publish, puller=None):
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    if not re.fullmatch(r'[0-9]+', run_id) or not re.fullmatch(r'[0-9]+', attempt):
        raise ValueError('Publishing must run in GitHub Actions')
    records = {record['token']: record for record in registry['records']}
    published = []
    for name in order(ROOTS):
        record = records.get(name)
        if record is None:
            raise ValueError('Publish record missing: ' + name)
        bottle, digest, asset = validate(name, record)
        tag = f'{RECIPES[name]["version"]}-monterey-{run_id}-{attempt}'
        publisher(name, tag, 'macos-x86_64', bottle)
        if puller is None:
            repo = bottles.mirror_repo(name)
            pulled = bottles.pull_blob(repo, 'sha256:' + digest,
                                       bottles.bearer_for(repo, pull_only=True, anonymous=True))
        else:
            pulled = puller(name, digest)
        if pulled != bottle.read_bytes():
            raise ValueError('Anonymous pull did not match the built bottle: ' + name)
        asset['url'] = bottles.mirror_url(name, digest)
        asset['sha256'] = digest
        asset['minimum_macos_major'] = 12
        published.append(record)
        print('Verified public bottle: ' + asset['url'])
    (DIST / 'registry-monterey.json').write_text(
        json.dumps({'schema_version': 1, 'records': published}, indent=2) + '\n')
    checksums = [f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
                 for p in sorted(DIST.glob('*.tar.gz'))]
    (DIST / 'SHA256SUMS').write_text(''.join(checksums))


def main():
    if not (DIST / 'installed-tests.json').exists():
        raise ValueError('Installed exact-bottle tests missing')
    registry = json.loads((DIST / 'registry.json').read_text())
    publish_records(registry)


if __name__ == '__main__':
    main()
