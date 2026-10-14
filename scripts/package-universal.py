#!/usr/bin/env python3
"""Merge only validated native packages; keep both originals intact."""
import argparse
from pathlib import Path
import shutil
import tempfile
from release_support import BUNDLE_ID, archive_name, command, extract_and_verify, release_version

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--tag', required=True)
args = parser.parse_args()
version = release_version(args.tag)
with tempfile.TemporaryDirectory(prefix='pulse-universal-') as temporary:
    stage = Path(temporary)
    arm = extract_and_verify(args.directory / archive_name('arm64'), stage / 'arm64', version, 'arm64')
    intel = extract_and_verify(args.directory / archive_name('x86_64'), stage / 'x86_64', version, 'x86_64')
    for relative in ['Contents/Resources/LICENSE', 'Contents/Resources/Localization/en.json', 'Contents/Resources/update-helper.sh']:
        if (arm / relative).read_bytes() != (intel / relative).read_bytes():
            raise ValueError('Native packages do not share the same release resources')
    app = stage / 'universal' / 'WristBeam.app'
    shutil.copytree(arm, app)
    binary = 'Contents/MacOS/GarminPulse'
    command(['/usr/bin/lipo', '-create', str(arm / binary), str(intel / binary), '-output', str(app / binary)])
    command(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', BUNDLE_ID, str(app)])
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    output = args.directory / archive_name('universal')
    command(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(output)])
    extract_and_verify(output, stage / 'verify', version, 'universal')
print('PASS assembled and verified universal macOS package')
