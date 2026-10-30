#!/usr/bin/env python3
"""Validate version/tag and optionally every native release package."""
import argparse
from pathlib import Path
import subprocess
import tempfile
from release_support import ARCHITECTURES, ROOT, archive_name, extract_and_verify, release_version, write_manifest

parser = argparse.ArgumentParser()
parser.add_argument('--tag', default='')
parser.add_argument('--directory', type=Path)
parser.add_argument('--write-manifest', action='store_true')
args = parser.parse_args()
version = release_version(args.tag)
if args.directory:
    with tempfile.TemporaryDirectory(prefix='pulse-release-verify-') as temporary:
        for architecture in ARCHITECTURES:
            extract_and_verify(args.directory / archive_name(architecture), Path(temporary) / architecture, version, architecture)
            print('PASS package identity, MIT license, deployment target, architecture and signature:', architecture)
    if args.write_manifest:
        commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
        write_manifest(args.directory, version, commit, args.tag)
        print('PASS three-architecture manifest and SHA256SUMS')
elif args.write_manifest:
    parser.error('--write-manifest requires --directory')
print('PASS release version:', version)
