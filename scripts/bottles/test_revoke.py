"""revoke never picks, or un-revokes, a version that an earlier revoke marked (offline, temp git repo)."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bottles', Path(__file__).with_name('nb_bottles.py'))
bottles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bottles)
GH = {'upstream': {'type': 'github_release', 'repo': 'o/gh'}, 'assets': {'linux-x86_64': {'pattern': 'gh_{version}.tgz'}}}
RELEASES = json.dumps([{'tag_name': f'v{v}', 'assets': [{'name': f'gh_{v}.tgz', 'browser_download_url': f'https://x/gh_{v}.tgz', 'digest': 'sha256:' + '0' * 64}]} for v in ('2.1', '2.0', '1.9')])


def repo(td):
    bottles.REPO_ROOT = Path(td)
    bottles.REGISTRY_JSON = Path(td) / 'src/upstream/registry_default.json'
    bottles.REGISTRY_JSON.parent.mkdir(parents=True)
    git('init', '-q')


def git(*args):
    subprocess.run(['git', '-C', str(bottles.REPO_ROOT), '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', *args], check=True, capture_output=True)


def pin(token, version, **extra):
    record = {'token': token, 'kind': 'formula', 'upstream': {'type': 'homebrew_bottle'}, **extra, 'resolved': {'version': version, 'tag': f'v{version}', 'assets': {}}}
    bottles.REGISTRY_JSON.write_text(json.dumps({'records': [record]}))
    git('add', '-A')
    git('commit', '-qm', f'pin {version}')


def revoke(token, advisory, fallback_version=None, no_fallback=False):
    bottles.cmd_revoke(SimpleNamespace(name=token, advisory=advisory, reason=None, fallback_version=fallback_version, no_fallback=no_fallback))
    git('commit', '-qam', f'revoke {advisory}')
    return json.loads(bottles.REGISTRY_JSON.read_text())['records'][0]['resolved']


with tempfile.TemporaryDirectory() as td:
    repo(td)
    pin('jq', '1.7')
    pin('jq', '1.8.0')
    assert revoke('jq', 'CVE-X')['fallback']['version'] == '1.7'
    pin('jq', '1.8.1')
    fallback = revoke('jq', 'CVE-Y')['fallback']
    assert fallback['version'] == '1.7', f"fell back to {fallback['version']}, already revoked for CVE-X"
    try:
        revoke('jq', 'CVE-Y', fallback_version='1.8.0')
    except SystemExit:
        pass
    else:
        raise AssertionError('--fallback-version accepted a revoked version')

# Git history holds only a revoked previous version: the upstream releases list must skip it too.
with tempfile.TemporaryDirectory() as td, patch.object(bottles, 'http', return_value=(200, {}, RELEASES)), patch.object(bottles, 'pat', return_value=''):
    repo(td)
    pin('gh', '2.0', **GH)
    revoke('gh', 'CVE-A', no_fallback=True)
    pin('gh', '2.1', **GH)
    fallback = revoke('gh', 'CVE-B')['fallback']
    assert fallback['version'] == '1.9', f"fell back to {fallback['version']}, already revoked for CVE-A"
print('Revoke: fallback skips revoked versions (git history and upstream); --fallback-version refuses one')
