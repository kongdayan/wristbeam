"""Shared validation for release archives. Never executes packaged application code."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = 'cn.wenyankong.garminpulse'
APP_NAME = 'WristBeam.app'
ARCHITECTURES = ('arm64', 'x86_64', 'universal')
SEMVER = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')


def release_version(tag: str = '', version_file: Path | None = None) -> str:
    version = (version_file or ROOT / 'VERSION').read_text().strip()
    if SEMVER.fullmatch(version) is None:
        raise ValueError('VERSION must contain a stable major.minor.patch version')
    validate_tag(version, tag)
    return version


def validate_tag(version: str, tag: str = '') -> str:
    tag = tag or 'v' + version
    if SEMVER.fullmatch(version) is None or re.fullmatch(r'v' + re.escape(version) + r'(?:-beta\.[1-9][0-9]*)?', tag) is None:
        raise ValueError('Release tag must match v + VERSION, optionally followed by -beta.N')
    return tag


def publication_flags(version: str, tag: str) -> list[str]:
    beta = '-beta.' in validate_tag(version, tag)
    return ['--prerelease=true', '--latest=false'] if beta else ['--prerelease=false', '--latest']


def archive_name(architecture: str) -> str:
    if architecture not in ARCHITECTURES:
        raise ValueError('Unexpected architecture')
    return f'WristBeam-macOS-{architecture}.zip'


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def safe_member(info: zipfile.ZipInfo) -> bool:
    name = info.filename
    parts = name.rstrip('/').split('/')
    mode = info.external_attr >> 16
    return (
        bool(name)
        and not name.startswith('/')
        and '\\' not in name
        and not any(ord(c) < 32 or ord(c) == 127 for c in name)
        and not any(part in ('', '.', '..') for part in parts)
        and parts[0] in (APP_NAME, '__MACOSX')
        and not stat.S_ISLNK(mode)
        and not (info.flag_bits & 1)
    )


def read_archive(path: Path, expected_version: str) -> dict:
    if not path.is_file() or path.stat().st_size > 100_000_000:
        raise ValueError('Missing or oversized archive')
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if not members or len(members) > 10_000 or sum(i.file_size for i in members) >= 500_000_000:
            raise ValueError('Archive expands beyond release limits')
        if not all(safe_member(i) for i in members):
            raise ValueError('Unsafe archive path, link or encryption')
        if len({i.filename for i in members}) != len(members):
            raise ValueError('Duplicate archive members')
        for member in members:
            parts = member.filename.lower().split('/')
            if (member.filename.lower().endswith(('.fit', '.jsonl', '.log', '.appex'))
                    or any(p in {'auth', 'received', 'uploadqueue', 'telemetry', 'diagnostics', 'charts', '.env'} for p in parts)
                    or 'runtime-state.json' in parts or any(p.endswith('.appex') for p in parts)):
                raise ValueError('Runtime data or unsupported extension found in archive')
        info = plistlib.loads(archive.read(APP_NAME + '/Contents/Info.plist'))
        if 'WristBeamReleaseTag' in info:
            validate_tag(expected_version, info['WristBeamReleaseTag'])
        if (info.get('CFBundleIdentifier') != BUNDLE_ID
                or info.get('CFBundleExecutable') != 'GarminPulse'
                or info.get('CFBundleShortVersionString') != expected_version
                or info.get('LSMinimumSystemVersion') != '13.0'
                or 'GarminPulsePreview' in info or 'WristBeamPreviewOnboarding' in info or 'GarminPulseUpdateFixture' in info):
            raise ValueError('Unexpected application identity, version, platform or preview mode')
        license_text = archive.read(APP_NAME + '/Contents/Resources/LICENSE').decode('utf-8')
        if not license_text.startswith('MIT License\n'):
            raise ValueError('MIT license missing from application package')
        return info


def command(arguments: list[str]) -> str:
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def extract_and_verify(archive: Path, destination: Path, version: str, architecture: str) -> Path:
    read_archive(archive, version)
    destination.mkdir(parents=True, exist_ok=True)
    command(['/usr/bin/ditto', '-x', '-k', str(archive), str(destination)])
    app = destination / APP_NAME
    binary = app / 'Contents/MacOS/GarminPulse'
    actual = set(command(['/usr/bin/lipo', '-archs', str(binary)]).split())
    expected = {'arm64', 'x86_64'} if architecture == 'universal' else {architecture}
    if actual != expected:
        raise ValueError('Mach-O architecture does not match asset name')
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    loads = command(['/usr/bin/otool', '-l', str(binary)])
    minimums = re.findall(r'^\s*minos ([0-9.]+)\s*$', loads, flags=re.MULTILINE)
    if not minimums or any(tuple(int(n) for n in v.split('.')) > (13, 0, 0) for v in minimums):
        raise ValueError('Mach-O deployment target exceeds advertised macOS 13')
    return app


def write_manifest(directory: Path, version: str, commit: str, tag: str = '') -> dict:
    tag = validate_tag(version, tag)
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Expected a full Git commit SHA')
    expected = {archive_name(a) for a in ARCHITECTURES}
    if {p.name for p in directory.glob('*.zip')} != expected:
        raise ValueError('Release must contain exactly arm64, x86_64 and universal ZIPs')
    assets = []
    for architecture in ARCHITECTURES:
        path = directory / archive_name(architecture)
        info = read_archive(path, version)
        if info.get('WristBeamReleaseTag', 'v' + version) != tag:
            raise ValueError('Application release tag does not match the manifest')
        assets.append({'name': path.name, 'architecture': architecture, 'bytes': path.stat().st_size, 'sha256': file_digest(path)})
    manifest = {'version': version, 'tag': tag, 'commit': commit, 'minimum_macos': '13.0', 'assets': assets}
    (directory / 'SHA256SUMS.txt').write_text(''.join(f"{a['sha256']}  {a['name']}\n" for a in assets))
    (directory / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest
