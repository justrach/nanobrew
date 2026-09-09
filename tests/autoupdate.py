#!/usr/bin/env python3
"""Test user schedules with fake service managers; never touch a host schedule."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='nb scheduler & % $ ') as temp:
    root = Path(temp)
    home, commands = root / 'home', root / 'commands'
    home.mkdir()
    commands.mkdir()
    nb = root / 'nb & % $ executable'
    shutil.copy2(sys.argv[1], nb)
    log, state = root / 'calls.jsonl', root / 'state'
    env = {**os.environ, 'HOME': str(home), 'XDG_CONFIG_HOME': str(home / 'custom config'), 'PATH': str(commands) + os.pathsep + os.environ['PATH'], 'NB_TEST_LOG': str(log), 'NB_TEST_STATE': str(state)}
    fake = '#!' + sys.executable + '\n' + '''import json, os, pathlib, sys
state = pathlib.Path(os.environ['NB_TEST_STATE'])
args = sys.argv[1:]
with open(os.environ['NB_TEST_LOG'], 'a') as log: log.write(json.dumps(args) + '\\n')
if 'list' in args or 'is-enabled' in args: sys.exit(0 if state.exists() else 1)
if os.environ.get('NB_TEST_FAIL'): sys.exit(1)
if 'load' in args or 'enable' in args: state.touch()
if 'unload' in args or 'disable' in args: state.unlink(missing_ok=True)
'''
    for name in ('launchctl', 'systemctl'):
        command = commands / name
        command.write_text(fake)
        command.chmod(0o755)
    def run(*args, fail=False):
        result = subprocess.run([str(nb), *args], env={**env, **({'NB_TEST_FAIL': '1'} if fail else {})}, capture_output=True, text=True, timeout=15)
        assert (result.returncode != 0) == fail, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout
    version = run('version').strip()
    assert len(version.split('.')) == 3 and all(p.isdigit() for p in version.split('.'))
    for alias in ('version', '--version', '-v'):
        assert run(alias).strip() == version
    assert 'autoupdate' in run('help')
    assert not state.exists()
    assert 'not installed' in run('autoupdate', 'status')
    run('autoupdate', 'enable', '--upgrade')
    assert state.exists()
    if sys.platform == 'darwin':
        schedule = home / 'Library/LaunchAgents/ai.trilok.nanobrew.autoupdate.plist'
        plist = plistlib.loads(schedule.read_bytes())
        assert plist['ProgramArguments'] == [str(nb), 'autoupdate', 'run', '--upgrade']
        assert plist['StartCalendarInterval'] == {'Hour': 3, 'Minute': 0}
        assert Path(plist['StandardOutPath']).parent.is_dir()
    else:
        units = home / 'custom config/systemd/user'
        schedule = units / 'nanobrew-autoupdate.timer'
        assert 'OnCalendar=*-*-* 03:00:00' in schedule.read_text()
        service = (units / 'nanobrew-autoupdate.service').read_text()
        assert '%%' in service and '$$' in service and '--upgrade' in service
    assert 'installed, enabled' in run('autoupdate', 'status')
    run('autoupdate', 'disable', fail=True)
    assert state.exists() and schedule.exists()  # failure must not claim removal
    run('autoupdate', 'disable')
    assert not state.exists() and not schedule.exists()
    run('autoupdate', 'disable')
    assert 'not installed' in run('autoupdate', 'status')
    assert log.exists()  # prove the fakes were used

    if len(sys.argv) > 2:
        runner = str(Path(sys.argv[2]).resolve())
        action_log, executable = root / 'actions', root / 'replace-me'
        replacement = '#!/bin/sh\nprintf "new %s\\n" "$1" >> "$NB_ACTION_LOG"\n'
        executable.write_text('#!' + sys.executable + '\nimport os, pathlib, sys\npathlib.Path(os.environ["NB_ACTION_LOG"]).write_text("old " + sys.argv[1] + "\\n")\npathlib.Path(sys.argv[0]).write_text(' + repr(replacement) + ')\n')
        executable.chmod(0o755)
        action_env = {**env, 'NB_ACTION_LOG': str(action_log)}
        result = subprocess.run([runner, str(executable)], env=action_env, capture_output=True, timeout=15)
        assert result.returncode == 0, result.stderr
        assert action_log.read_text() == 'old update\nnew upgrade\n'
        executable.write_text('#!/bin/sh\nprintf "%s\\n" "$1" > "$NB_ACTION_LOG"\nexit 7\n')
        result = subprocess.run([runner, str(executable)], env=action_env, capture_output=True, timeout=15)
        assert result.returncode == 7
        assert action_log.read_text() == 'update\n'
print('Autoupdate: fake-manager enable/status/disable, escaped paths, failure preservation, fresh executable and exit status passed')
