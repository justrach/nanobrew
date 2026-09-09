"""The scanner ignores links but still rejects archive traversal (Python 3.12+)."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bottles', Path(__file__).with_name('nb_bottles.py'))
bottles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bottles)
record = {'token': 'fixture', 'resolved': {'version': '1', 'assets': {'arm64_sonoma': {'url': 'unused', 'sha256': 'unused'}}}}

def archive(traversal=False):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz') as tf:
        regular = tarfile.TarInfo('../escape' if traversal else 'pkg/bin/tool')
        regular.size = 7
        tf.addfile(regular, io.BytesIO(b'payload'))
        for kind, name, target in [(tarfile.SYMTYPE, 'absolute', '/usr/local/lib'), (tarfile.SYMTYPE, 'relative', '../../escape'), (tarfile.LNKTYPE, 'hard', 'pkg/bin/tool')]:
            info = tarfile.TarInfo(name)
            info.type, info.linkname = kind, target
            tf.addfile(info)
    return data.getvalue(), 'fixture'

def scanner(args, **kwargs):
    if args[0] == 'syft':
        root = Path(args[2].removeprefix('dir:'))
        assert (root / 'pkg/bin/tool').read_bytes() == b'payload'
        assert sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()) == ['pkg/bin/tool']
        Path(args[-1].split('=', 1)[1]).write_text('{}')
    return SimpleNamespace(stdout=json.dumps({'matches': []}))

with tempfile.TemporaryDirectory() as td:
    with patch.object(bottles, '_bottle_bytes', return_value=archive()), patch.object(bottles.subprocess, 'run', side_effect=scanner):
        assert bottles._scan_one(record, None, Path(td)) == [('arm64_sonoma', [])]
    with patch.object(bottles, '_bottle_bytes', return_value=archive(True)), patch.object(bottles.subprocess, 'run', side_effect=AssertionError('scanner must not run')):
        try:
            bottles._scan_one(record, None, Path(td))
        except tarfile.OutsideDestinationError:
            pass
        else:
            raise AssertionError('path traversal was accepted')
print('Bottle scan: absolute/relative symlinks and hard links skipped; regular payload scanned; traversal rejected')
