#!/usr/bin/env python3
"""Choose CI work from trusted event metadata and repository paths, never PR text."""
import json
import os
from pathlib import Path
import subprocess


def plan(event, paths, full=False, showcase=False, package=False, release_tag=''):
    paths = set(paths)
    release_files = {'VERSION', 'project.yml'}
    full = full or bool(release_tag) or (event == 'push' and bool(paths & release_files))
    light = lambda p: (p.startswith(('docs/', '.github/ISSUE_TEMPLATE/', 'Tests/ReleasePipeline/'))
                       or p.endswith('.md') or p in {'LICENSE', '.gitignore', '.github/dependabot.yml'}
                       or p.startswith('scripts/ci-') or p in {
                           'scripts/check-repository.py', 'scripts/check-localization.py',
                           'scripts/check-secrets.py', '.github/workflows/security.yml',
                           '.github/workflows/maintenance.yml', '.swiftlint.yml'})
    native = full or showcase or package or any(not light(p) for p in paths)
    render = native and (full or showcase or any(p.startswith((
        'Sources/GarminBar/UI/', 'Sources/GarminBar/Resources/', 'WidgetExtension/',
        'scripts/test-interface-render.py', 'scripts/test-dashboard-render.py',
        'scripts/render-floating-showcase.swift')) or p in {
            'Sources/GarminBar/Models/AppModel.swift', 'Sources/GarminBar/Models/DisplaySettings.swift',
            'Sources/GarminBar/App/GarminPulseApp.swift'} for p in paths))
    swift_security = full or any(p.endswith('.swift') or p in {
        'Package.swift', 'Package.resolved', '.github/workflows/security.yml'} for p in paths)
    return {'native': native, 'render': render, 'full': full, 'showcase': showcase,
            'packages': native and (event == 'push' or bool(release_tag) or package),
            'swift-security': swift_security}


def changed_paths(event, payload):
    if event == 'pull_request':
        base, head = payload['pull_request']['base']['sha'], payload['pull_request']['head']['sha']
        args = ['git', 'diff', '--name-only', '-z', base + '...' + head]
    elif event == 'push' and payload.get('before', '').strip('0'):
        args = ['git', 'diff', '--name-only', '-z', payload['before'], payload['after']]
    elif event == 'merge_group':
        args = ['git', 'diff', '--name-only', '-z', payload['merge_group']['base_sha'], payload['merge_group']['head_sha']]
    elif event == 'push':
        args = ['git', 'ls-files', '-z']
    else:
        return []
    return subprocess.check_output(args).decode().strip('\0').split('\0')


def main():
    event = os.environ['GITHUB_EVENT_NAME']
    payload = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    result = plan(event, filter(None, changed_paths(event, payload)),
                  full=os.environ.get('CI_FULL_VALIDATION') == 'true',
                  showcase=os.environ.get('CI_SHOWCASE') == 'true',
                  package=os.environ.get('CI_TEST_PACKAGE') == 'true',
                  release_tag=os.environ.get('CI_RELEASE_TAG', ''))
    # Manual standard validation is explicit even if there is no commit diff.
    if event == 'workflow_dispatch':
        result['native'] = True
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in result.items():
            output.write(f'{key}={str(value).lower()}\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
