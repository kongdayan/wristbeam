#!/usr/bin/env python3
"""Prune known disposable Actions artifacts; dry-run unless --apply is explicit.

Never touch releases, logs, caches, unknown artifact types or active/unknown runs.
Pin primary packages from the latest successful full main build and each open PR.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time

PRIMARY = {'release-arm64', 'release-x86_64'}
PACKAGE = re.compile(r'^(release-(arm64|x86_64)|package-macos\d+-arm64|GarminPulse-macOS)$')
IMAGES = ('showcase-', 'native-interface-', 'native-interaction-failure-')
METRICS = {'ci-timings', 'codeql-swift-timing'}


def api(path, method='GET'):
    for attempt in range(3):
        result = subprocess.run(['gh', 'api', '--method', method, path], capture_output=True, text=True, timeout=45)
        if result.returncode == 0:
            return json.loads(result.stdout) if result.stdout.strip() else None
        if method == 'DELETE' and 'HTTP 404' in result.stderr:
            return None  # Expired/deleted after inventory: the desired state already holds.
        if attempt == 2 or not re.search(r'HTTP (429|500|502|503|504)', result.stderr):
            raise RuntimeError(f'GitHub artifact maintenance request failed ({method})')
        time.sleep(2 ** attempt)


def pages(path, key=None):
    values, page = [], 1
    while True:
        payload = api(f'{path}?per_page=100&page={page}')
        items = payload[key] if key else payload
        values.extend(items)
        if len(items) < 100:
            return values
        page += 1


def cleanup_plan(artifacts, runs, open_branches, now):
    runs = {r['id']: r for r in runs}
    live = [a for a in artifacts if not a.get('expired')]
    by_run = {}
    for artifact in live:
        by_run.setdefault(artifact.get('workflow_run', {}).get('id'), set()).add(artifact['name'])
    successful_ci = sorted((r for r in runs.values() if r.get('status') == 'completed'
                            and r.get('conclusion') == 'success'
                            and r.get('path') == '.github/workflows/ci.yml'),
                           key=lambda r: r['created_at'], reverse=True)
    pinned = set()
    full_main = next((r for r in successful_ci if r.get('event') == 'push' and r.get('head_branch') == 'main'
                      and PRIMARY <= by_run.get(r['id'], set())), None)
    if full_main:
        pinned.add(full_main['id'])
    for branch in open_branches:
        recent = next((r for r in successful_ci if r.get('head_branch') == branch
                       and PRIMARY & by_run.get(r['id'], set())), None)
        if recent:
            pinned.add(recent['id'])
    delete, retained = [], []
    for artifact in live:
        run_id = artifact.get('workflow_run', {}).get('id')
        run = runs.get(run_id)
        name = artifact['name']
        if not run or run.get('status') != 'completed':
            retained.append(artifact['id'])
            continue
        if name.startswith(IMAGES):
            days = 3
        elif PACKAGE.fullmatch(name) or name in METRICS:
            days = 7
        else:
            retained.append(artifact['id'])
            continue
        if run.get('conclusion') == 'cancelled':
            days = 1
        if run_id in pinned and name in PRIMARY:
            retained.append(artifact['id'])
            continue
        created = datetime.fromisoformat(artifact['created_at'].replace('Z', '+00:00'))
        if created >= now - timedelta(days=days):
            retained.append(artifact['id'])
            continue
        delete.append({k: artifact[k] for k in ('id', 'name', 'size_in_bytes', 'created_at')}
                      | {'run_id': run_id, 'retentionDays': days})
    return dict(schemaVersion=1, sampledAt=now.isoformat(), pinnedRunIDs=sorted(pinned),
                liveArtifacts=len(live), liveBytes=sum(a['size_in_bytes'] for a in live),
                delete=delete, deleteBytes=sum(a['size_in_bytes'] for a in delete),
                retainedArtifactIDs=retained)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY'))
    parser.add_argument('--output', type=Path, default=Path('artifact-cleanup-plan.json'))
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not args.repo or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('--repo owner/repo is required')
    prefix = f'repos/{args.repo}'
    artifacts = pages(prefix + '/actions/artifacts', 'artifacts')
    runs = pages(prefix + '/actions/runs', 'workflow_runs')
    branches = {pr['head']['ref'] for pr in pages(prefix + '/pulls')}
    plan = cleanup_plan(artifacts, runs, branches, datetime.now(timezone.utc))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(plan, indent=2) + '\n')
    print(f'{plan["liveArtifacts"]} live artifacts, {plan["liveBytes"] / 1048576:.1f} MiB; '
          f'{len(plan["delete"])} eligible for removal, {plan["deleteBytes"] / 1048576:.1f} MiB')
    if not args.apply:
        print('Dry run: no artifacts deleted.')
        return
    # Recheck each candidate run immediately before deletion; reruns may have started.
    eligible = set()
    for run_id in sorted({a['run_id'] for a in plan['delete']}):
        if api(f'{prefix}/actions/runs/{run_id}').get('status') == 'completed':
            eligible.add(run_id)
    targets = [a for a in plan['delete'] if a['run_id'] in eligible]
    def remove(artifact):
        api(f'{prefix}/actions/artifacts/{artifact["id"]}', method='DELETE')
        return artifact['id']
    with ThreadPoolExecutor(max_workers=2) as pool:
        removed = list(pool.map(remove, targets))
    plan['deletedArtifactIDs'] = removed
    args.output.write_text(json.dumps(plan, indent=2) + '\n')
    print(f'Deleted {len(removed)} obsolete Actions artifacts; releases and pinned packages untouched.')


if __name__ == '__main__':
    main()
