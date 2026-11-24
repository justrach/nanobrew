#!/usr/bin/env python3
"""Exercise installed upstream tools on a disposable native macOS runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = {
    'gh': ('gh', '--version'),
    'uv': ('uv', '--version'),
    'oras': ('oras', 'version'),
    'ripgrep': ('rg', '--version'),
    'just': ('just', '--version'),
    'fd': ('fd', '--version'),
    'git-lfs': ('git-lfs', 'version'),
    'codedb': ('codedb', '--version'),
    'codegraff': ('graff', '--version'),
}


def expected_packages(mode, target, nb):
    if mode == 'pinned':
        registry = json.loads((ROOT / 'registry/upstream.json').read_text())
        return {r['token']: {'version': r['resolved']['version'],
                             'sha256': r['resolved']['assets'][target]['sha256']}
                for r in registry['records'] if r['kind'] == 'formula' and r['token'] in CHECKS}

    # Compare the installed receipt with the selected archive, not the stale
    # registry pin or the receipt's own copy of the expected values.
    info = json.loads(subprocess.check_output([str(nb), 'info', '--json', *CHECKS], text=True, timeout=60))
    return {r['name']: r for r in info['packages'] if r['kind'] == 'formula'}


def verify_receipt(name, actual, expected):
    sha = expected.get('sha256', '')
    assert re.fullmatch(r'[0-9a-f]{64}', sha), (name, expected)
    assert actual['version'] == expected['version'], (name, actual, expected)
    assert actual['sha256'] == sha, (name, actual, expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('nb', type=Path, nargs='?', default=ROOT / 'zig-out/bin/nb')
    args = parser.parse_args()
    arch = platform.machine()
    assert platform.system() == 'Darwin' and arch in ('arm64', 'x86_64')
    target = 'macos-' + arch
    mode = os.environ.get('NB_TEST_RESOLUTION', 'pinned')
    assert mode in ('pinned', 'default')
    expected = expected_packages(mode, target, args.nb.resolve())
    installed = {r['name']: r for r in json.loads(Path('/opt/nanobrew/db/state.json').read_text())['kegs']}
    prefix = Path('/opt/nanobrew/prefix/bin')
    evidence = []
    (ROOT / 'dist').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='nb-tools-', dir=ROOT / 'dist') as td:
        work = Path(td) / 'project'
        work.mkdir()
        home = Path(td) / 'home'
        home.mkdir()
        env = {'HOME': str(home), 'PATH': str(prefix) + ':/usr/bin:/bin:/usr/sbin:/sbin',
               'CODEDB_NO_TELEMETRY': '1', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
        if 'TMPDIR' in os.environ:
            env['TMPDIR'] = os.environ['TMPDIR']

        def run(*args, input=None):
            print('+', ' '.join(map(str, args)), flush=True)
            return subprocess.check_output(list(map(str, args)), cwd=work, env=env, input=input, text=True, timeout=60)

        for name, (binary, flag) in CHECKS.items():
            verify_receipt(name, installed[name], expected[name])
            path = prefix / binary
            run('/usr/bin/lipo', path, '-verify_arch', arch)
            output = run(path, flag)
            # Homebrew's packaging revision is in the receipt, not the CLI version.
            version = re.sub(r'_[0-9]+$', '', expected[name]['version'])
            assert re.search(r'(?<![0-9.])' + re.escape(version) + r'(?![0-9.])', output), output
            print(output)
            evidence.append({'package': name, 'version': installed[name]['version'],
                             'sha256': installed[name]['sha256'], 'native_arch': arch})

        (work / 'needle.txt').write_text('nanobrew native search\n')
        assert run(prefix / 'rg', '--no-config', '--fixed-strings', 'native', 'needle.txt').strip() == 'nanobrew native search'
        assert run(prefix / 'fd', '--color', 'never', '--type', 'f', '^needle[.]txt$', '.').strip() == './needle.txt'
        (work / 'justfile').write_text('check:\n    @printf "nanobrew recipe ok\\n"\n')
        assert run(prefix / 'just', '--justfile', 'justfile', 'check').strip() == 'nanobrew recipe ok'
        (work / 'fixture.py').write_text('def nanobrew_probe():\n    return "indexed marker"\n')
        run(prefix / 'codedb', work, 'reindex')
        assert 'fixture.py' in run(prefix / 'codedb', work, 'search', 'nanobrew_probe')
        assert 'nanobrew_probe' in run(prefix / 'codedb', work, 'outline', 'fixture.py')
        schema = json.loads(run(prefix / 'graff', '--schema'))
        assert isinstance(schema, dict) and schema, schema
        assert 'usage:' in run(prefix / 'graff', '--help').lower()
        run('/usr/bin/git', 'init', '--quiet', '.')
        payload = 'Nanobrew LFS round trip\n' * 100
        pointer = run(prefix / 'git-lfs', 'clean', '--', 'sample.bin', input=payload)
        assert 'oid sha256:' + hashlib.sha256(payload.encode()).hexdigest() in pointer, pointer
        assert run(prefix / 'git-lfs', 'smudge', '--', 'sample.bin', input=pointer) == payload

    out = ROOT / 'dist' / ('popular-packages-' + target + '-' + mode + '.json')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({'platform': target, 'resolution': mode, 'macos': platform.mac_ver()[0], 'packages': evidence,
                              'functional_checks': ['ripgrep text search', 'fd file search', 'just recipe execution',
                                                    'git-lfs clean/smudge round trip', 'codedb indexing/search/outline', 'graff schema/help']}, indent=2) + '\n')
    print(out.read_text())


if __name__ == '__main__':
    main()
