#!/usr/bin/env python3
"""Run the shipped executable without SwiftPM or checkout resources (CI only)."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
dist = Path(os.environ.get('PULSE_OUTPUT_DIR', root / 'dist'))
with tempfile.TemporaryDirectory(prefix='wristbeam-installed-') as temporary:
    stage = Path(temporary)
    app = stage / 'WristBeam.app'
    shutil.copytree(dist / 'WristBeam.app', app)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    hidden = []
    try:
        for source in (root / '.build', root / 'Sources/GarminBar/Resources/Localization/en.json'):
            destination = source.with_name(source.name + '.package-test-hidden')
            if destination.exists():
                raise RuntimeError('Refusing to overwrite hidden resources')
            source.rename(destination)
            hidden.append((source, destination))
        binary = app / 'Contents/MacOS/GarminPulse'
        # Fresh processes cover an English system before any UI is initialized,
        # then repeat the in-process Chinese/English transition that crashed.
        for language in ('en', 'zh-Hans'):
            result = subprocess.run([str(binary), '--verify-localization', '-AppleLanguages', f'({language})'], cwd=stage, capture_output=True, text=True, timeout=30)
            if result.returncode != 0 or 'PASS packaged' not in result.stdout:
                raise RuntimeError(f'Installed {language} startup failed: {result.stderr}')
            print(f'PASS isolated signed application startup and language switching: {language}')
        # A missing catalog must fail the check rather than borrowing resources.
        catalog = app / 'Contents/Resources/Localization/en.json'
        catalog.unlink()
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        result = subprocess.run([str(binary), '--verify-localization'], cwd=stage, capture_output=True, timeout=30)
        assert result.returncode == 1 and b'Packaged localization failed' in result.stderr, 'Missing catalog did not fail cleanly'
        print('PASS missing packaged resource detected')
    finally:
        for source, destination in reversed(hidden):
            destination.rename(source)
