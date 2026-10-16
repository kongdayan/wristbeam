#!/usr/bin/env python3
"""Reuse only a successful main-push CI for the exact release commit.

Validate GitHub's artifact digest, a package digest and source/run identity before
handing packages to the existing signature/architecture/version release checks.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import time
import zipfile

from release_support import archive_name, file_digest, release_version


def api(path):
    return subprocess.run(['gh', 'api', path], check=True, capture_output=True).stdout


def validate_run(run, sha, repository):
    return (run.get('event') == 'push' and run.get('head_branch') == 'main'
            and run.get('head_sha') == sha and run.get('conclusion') == 'success'
            and run.get('status') == 'completed' and run.get('path') == '.github/workflows/ci.yml'
            and run.get('repository', {}).get('full_name') == repository)


def unpack_verified(raw, artifact_digest, directory, arch, sha, run_id, version):
    if artifact_digest != 'sha256:' + hashlib.sha256(raw).hexdigest():
        raise ValueError('GitHub artifact digest mismatch')
    name, evidence_name = archive_name(arch), f'build-evidence-{arch}.json'
    with zipfile.ZipFile(io.BytesIO(raw)) as bundle:
        members = bundle.infolist()
        if (len(members) != 2 or {m.filename for m in members} != {name, evidence_name}
                or sum(m.file_size for m in members) > 110_000_000):
            raise ValueError('Unexpected CI artifact members')
        evidence = json.loads(bundle.read(evidence_name))
        package = bundle.read(name)
        if (evidence.get('schemaVersion') != 1 or evidence.get('commit') != sha
                or str(evidence.get('runID')) != str(run_id) or evidence.get('architecture') != arch
                or evidence.get('version') != version
                or evidence.get('sha256') != hashlib.sha256(package).hexdigest()):
            raise ValueError('Package source/run/hash mismatch')
        directory.mkdir(parents=True, exist_ok=True)
        (directory / name).write_bytes(package)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['resolve', 'download', 'evidence', 'audit'])
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    parser.add_argument('--arch', choices=['arm64', 'x86_64'])
    parser.add_argument('--run-id')
    args = parser.parse_args()
    sha, repository = os.environ['GITHUB_SHA'], os.environ['GITHUB_REPOSITORY']
    if args.action == 'evidence':
        if args.arch is None:
            parser.error('--arch required')
        evidence = dict(schemaVersion=1, commit=sha, runID=os.environ['GITHUB_RUN_ID'], architecture=args.arch,
                        version=release_version(), sha256=file_digest(args.directory / archive_name(args.arch)))
        (args.directory / f'build-evidence-{args.arch}.json').write_text(json.dumps(evidence) + '\n')
        return
    prefix = f'repos/{repository}/actions'
    if args.action == 'resolve':
        run_id = ''
        # Release can start immediately after tagging a new main commit. Wait for
        # that existing CI rather than competing for the same macOS executors.
        deadline = time.monotonic() + 35 * 60
        while True:
            runs = json.loads(api(f'{prefix}/workflows/ci.yml/runs?head_sha={sha}&event=push&branch=main&per_page=100'))['workflow_runs']
            ready = next((r for r in runs if validate_run(r, sha, repository)), None)
            if ready:
                artifacts = json.loads(api(f"{prefix}/runs/{ready['id']}/artifacts?per_page=100"))['artifacts']
                valid = {a['name'] for a in artifacts if not a['expired'] and a.get('digest', '').startswith('sha256:')}
                if {'release-arm64', 'release-x86_64'} <= valid:
                    run_id = str(ready['id'])
                break
            if not any(r['status'] != 'completed' for r in runs) or time.monotonic() >= deadline:
                break
            print('Waiting for same-commit main CI', flush=True)
            time.sleep(30)
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'run-id={run_id}\n')
        print('Reusing verified main CI' if run_id else 'No reusable build; full release checks required')
        return
    if not args.run_id or not args.run_id.isdecimal():
        parser.error('--run-id required')
    run = json.loads(api(f'{prefix}/runs/{args.run_id}'))
    if args.action == 'audit':
        # A CI job validates its own freshly uploaded bytes without granting them
        # release eligibility. The publishing path always uses `download` below.
        expected_head = sha
        if os.environ.get('GITHUB_EVENT_NAME') == 'pull_request':
            event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
            expected_head = event['pull_request']['head']['sha']
        checkout = subprocess.run(['git', 'rev-parse', 'HEAD'], check=True, capture_output=True, text=True).stdout.strip()
        if (args.run_id != os.environ['GITHUB_RUN_ID'] or run.get('head_sha') != expected_head or checkout != sha
                or run.get('repository', {}).get('full_name') != repository):
            raise ValueError('Artifact audit must belong to this exact CI run and checkout')
    elif not validate_run(run, sha, repository):
        raise ValueError('Only successful same-commit main CI may be reused')
    artifacts = json.loads(api(f'{prefix}/runs/{args.run_id}/artifacts?per_page=100'))['artifacts']
    for arch in ('arm64', 'x86_64'):
        matches = [a for a in artifacts if a['name'] == f'release-{arch}' and not a['expired']]
        if len(matches) != 1:
            raise ValueError('Expected exactly one verified architecture artifact')
        item = matches[0]
        raw = api(f"{prefix}/artifacts/{item['id']}/zip")
        unpack_verified(raw, item.get('digest'), args.directory, arch, sha, args.run_id, release_version())
    print('Verified source commit, run identity, artifact and package hashes')


if __name__ == '__main__':
    main()
