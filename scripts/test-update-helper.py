#!/usr/bin/env python3
"""Exercise the production shell helper with isolated apps and mocked launching."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parent.parent
helper = (root / 'scripts/update-helper.sh').read_text()
register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
with tempfile.TemporaryDirectory(prefix='wristbeam-helper-') as temporary:
    base = Path(temporary)
    # The PID is genuinely reaped, so the helper does not wait on an active app.
    ended = subprocess.Popen(['/usr/bin/true'])
    ended.wait()
    for scenario in ('success', 'replacement-failure', 'relaunch-failure', 'archive-failure'):
        case = base / scenario
        case.mkdir()
        target, stage, updates = case / 'WristBeam.app', case / 'Staged.app', case / 'Updates'
        updates.mkdir()
        for app, version in ((target, 'old'), (stage, 'new')):
            app.mkdir()
            (app / 'version').write_text(version)
        launch = case / 'launch.sh'
        launch.write_text('#!/bin/sh\n' + ('if [ "$(cat "$1/version")" = new ]; then exit 1; fi\n' if scenario == 'relaunch-failure' else '') + 'exit 0\n')
        launch.chmod(0o700)
        source = helper.replace('/usr/bin/open', str(launch)).replace(register, '/usr/bin/true')
        if scenario == 'archive-failure':
            source = source.replace('/usr/bin/ditto', '/usr/bin/false')
        if scenario == 'replacement-failure':
            shutil.rmtree(stage)
        script = case / 'helper.sh'
        script.write_text(source)
        result = updates / 'result.txt'
        outcome = subprocess.run(['/bin/sh', str(script), str(ended.pid), str(stage), str(target), str(updates), str(result)], capture_output=True, text=True, timeout=30)
        assert outcome.returncode == (0 if scenario == 'success' else 1), (scenario, outcome.stderr)
        assert (target / 'version').read_text() == ('new' if scenario == 'success' else 'old'), scenario
        assert result.read_text().strip(), scenario
        if scenario != 'archive-failure':
            with zipfile.ZipFile(updates / 'Previous.zip') as archive:
                assert archive.read('WristBeam.app/version') == b'old'
        if scenario == 'success':
            assert not list(updates.rglob('*.app')), 'Update left duplicate app bundles'
            assert not stage.exists()
        print('PASS update helper:', scenario)
