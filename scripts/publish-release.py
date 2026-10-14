#!/usr/bin/env python3
"""Publish only validated tag assets. Never replace an already public release."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from release_support import ARCHITECTURES, ROOT, archive_name, file_digest, release_version

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True, type=Path)
parser.add_argument('--tag', required=True)
args = parser.parse_args()
version = release_version(args.tag)
repo = 'kongdayan/wristbeam'
manifest = json.loads((args.directory / 'release-manifest.json').read_text())
commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
if manifest['tag'] != args.tag or manifest['commit'] != commit:
    raise ValueError('Release manifest does not match checked-out tag')
if len(manifest['assets']) != 3 or {a['name'] for a in manifest['assets']} != {archive_name(a) for a in ARCHITECTURES}:
    raise ValueError('Incomplete release asset set')
for asset in manifest['assets']:
    if file_digest(args.directory / asset['name']) != asset['sha256']:
        raise ValueError('Release artifact changed after validation')
current = subprocess.run(['gh', 'release', 'view', args.tag, '--repo', repo, '--json', 'isDraft'], capture_output=True, text=True)
if current.returncode == 0 and not json.loads(current.stdout)['isDraft']:
    raise ValueError('Published releases are immutable; create a new version instead')
with tempfile.TemporaryDirectory(prefix='pulse-release-notes-') as temporary:
    notes = Path(temporary) / 'notes.md'
    notes.write_text(f'''Native macOS companion for Garmin watches.\n\nDownload a ZIP for Apple Silicon, Intel, or Universal (both). Requires macOS 13+. Allow Bluetooth access and use the app pairing guide. These builds are ad hoc signed and are not Apple notarized.\n\nAll PR/release quality checks, full-history secret scanning, CodeQL, native XCTest and signed-package tests must pass before publication. China account sync is verified on Instinct 2 Solar; real Global account uploads and other watch models remain unverified.\n\nSee [README](https://github.com/{repo}#readme), [verification scope](https://github.com/{repo}/blob/{args.tag}/VERIFICATION.md), SHA256SUMS.txt and release-manifest.json. The ZIPs have GitHub build-provenance attestations.\n''')
    if current.returncode != 0:
        subprocess.run(['gh', 'release', 'create', args.tag, '--repo', repo, '--verify-tag', '--draft', '--title', 'WristBeam ' + version, '--generate-notes', '--notes-file', str(notes)], check=True)
    assets = [args.directory / archive_name(a) for a in ARCHITECTURES]
    assets += [args.directory / 'SHA256SUMS.txt', args.directory / 'release-manifest.json']
    subprocess.run(['gh', 'release', 'upload', args.tag, '--repo', repo, '--clobber', *map(str, assets)], check=True)
    uploaded = json.loads(subprocess.run(['gh', 'release', 'view', args.tag, '--repo', repo, '--json', 'assets'], check=True, capture_output=True, text=True).stdout)['assets']
    by_name = {a['name']: a for a in uploaded}
    for path in assets:
        asset = by_name.get(path.name)
        if asset is None or asset.get('size') != path.stat().st_size or asset.get('digest') != 'sha256:' + file_digest(path):
            raise ValueError('GitHub asset size/digest does not match validated file')
    subprocess.run(['gh', 'release', 'edit', args.tag, '--repo', repo, '--draft=false', '--latest'], check=True)
print('PASS published validated release:', args.tag)
