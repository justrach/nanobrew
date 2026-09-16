#!/usr/bin/env python3
"""Wrap checksum-pinned CodeDB executables as reproducible Nanobrew bottles."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

from nb_bottles import bearer_for, do_publish, http, mirror_repo, mirror_url

ROOT = Path(__file__).resolve().parents[2]


def fetch(asset):
    data = urllib.request.urlopen(asset['url'], timeout=90).read()
    if hashlib.sha256(data).hexdigest() != asset['sha256']:
        raise ValueError('Checksum mismatch: ' + asset['url'])
    return data


def package(version, binary, license_text):
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode='wb', filename='', mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for path, data, mode in [('bin/codedb', binary, 0o755), ('LICENSE', license_text, 0o644)]:
                member = tarfile.TarInfo('codedb/' + version + '/' + path)
                member.size, member.mode = len(data), mode
                archive.addfile(member, io.BytesIO(data))
    return out.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    recipe = json.loads((ROOT / 'scripts/bottles/codedb-recipe.json').read_text())
    license_text = fetch(recipe['license'])
    assets = {}
    dist = ROOT / 'dist/codedb'
    dist.mkdir(parents=True, exist_ok=True)
    for platform, upstream in recipe['assets'].items():
        data = package(recipe['version'], fetch(upstream), license_text)
        digest = hashlib.sha256(data).hexdigest()
        path = dist / ('codedb-' + recipe['version'] + '.' + platform + '.tar.gz')
        path.write_bytes(data)
        url = mirror_url('codedb', digest)
        if args.publish:
            assert do_publish('codedb', recipe['version'], platform, path) == 'sha256:' + digest
            token = bearer_for(mirror_repo('codedb'), pull_only=True, anonymous=True)
            _, _, pulled = http('GET', url, headers={'Authorization': 'Bearer ' + token})
            assert hashlib.sha256(pulled).hexdigest() == digest
        assets[platform] = {'url': url, 'sha256': digest}
        print(platform, digest, flush=True)
    record = {'token': 'codedb', 'name': 'codedb', 'kind': 'formula',
              'homepage': 'https://github.com/justrach/codedb',
              'desc': 'Code intelligence CLI and MCP server', 'dependencies': [],
              'upstream': {'type': 'homebrew_bottle', 'verified': True},
              'resolved': {'version': recipe['version'], 'assets': assets},
              'verification': {'sha256': 'required'}}
    (dist / 'record.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
