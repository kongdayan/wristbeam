#!/usr/bin/env python3
"""CI timing/resource reports. Only allowlisted metadata is persisted, never logs or credentials."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import time


def measured(name, command, output):
    """Stream normal output, preserve exit status, and measure one command's child resources."""
    start = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.Popen(command)
    while True:
        try:
            code = process.wait(timeout=30)
            break
        except subprocess.TimeoutExpired:
            print(f'CI timing: {name} still running ({time.monotonic() - start:.0f}s)', flush=True)
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    record = dict(schemaVersion=1, name=name, elapsedSeconds=round(time.monotonic() - start, 3),
                  userCPUSeconds=round(usage.ru_utime - before.ru_utime, 3),
                  systemCPUSeconds=round(usage.ru_stime - before.ru_stime, 3),
                  maxChildRSSBytes=int(usage.ru_maxrss * (1 if platform.system() == 'Darwin' else 1024)),
                  exitCode=code, runnerOS=platform.system(), architecture=platform.machine())
    # maxrss is the largest child high-water mark, not aggregate tree RSS.
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(record, indent=2) + '\n')
    print('CI timing: ' + json.dumps(record), flush=True)
    return code if code >= 0 else 128 - code


def timestamp(value):
    if not value or value.startswith('0001'):
        return None
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def duration(item):
    start, end = timestamp(item.get('started_at')), timestamp(item.get('completed_at'))
    if item.get('status') != 'completed' or item.get('conclusion') == 'skipped' or not start or not end:
        return None
    return max(0, round((end - start).total_seconds(), 3))


def summarize(run, jobs, baselines):
    rows = []
    for job in jobs:
        if job['name'].split(' / ')[-1] in ('CI timing report', 'CI passed'):
            continue
        seconds = duration(job)
        history = [duration(old) for baseline in baselines for old in baseline
                   if old['name'] == job['name'] and old.get('conclusion') == 'success' and duration(old) is not None]
        median = statistics.median(history) if history else None
        rows.append(dict(name=job['name'], status=job.get('status'), conclusion=job.get('conclusion'),
                         elapsedSeconds=seconds, baselineSamples=len(history), baselineMedianSeconds=median,
                         changePercent=round((seconds / median - 1) * 100, 1) if seconds is not None and median else None,
                         steps=[dict(name=s['name'], elapsedSeconds=duration(s), conclusion=s.get('conclusion'))
                                for s in job.get('steps', []) if duration(s) is not None]))
    starts = [timestamp(j.get('started_at')) for j in jobs if timestamp(j.get('started_at'))]
    created = timestamp(run.get('created_at'))
    return dict(schemaVersion=1, runID=run['id'], commit=run['head_sha'], event=run['event'],
                sampledAt=datetime.now(timezone.utc).isoformat(),
                initialWaitSeconds=max(0, (min(starts) - created).total_seconds()) if starts and created else None,
                jobElapsedSumSeconds=sum(r['elapsedSeconds'] or 0 for r in rows), jobs=rows)


def markdown(report):
    def cell(value):
        return str(value).replace('|', '\\|').replace('\n', ' ')
    def elapsed(value):
        return 'pending' if value is None else f'{value:.0f}s'
    lines = ['## CI timing', '', f'Run `{report["runID"]}` · `{report["commit"][:12]}`', '',
             'Step/job wall time, including compilation. Parallel job durations must not be added to estimate user wait time.',
             'Initial scheduling/provisioning wait: ' + elapsed(report['initialWaitSeconds']) + '.', '',
             '| Job | Result | Elapsed | Historical median | Change | Samples |',
             '| --- | --- | ---: | ---: | ---: | ---: |']
    for row in report['jobs']:
        change = '—' if row['changePercent'] is None else f'{row["changePercent"]:+.1f}%'
        lines.append('| ' + ' | '.join([cell(row['name']), cell(row['conclusion'] or row['status']),
                                       elapsed(row['elapsedSeconds']), elapsed(row['baselineMedianSeconds']), change,
                                       str(row['baselineSamples'])]) + ' |')
    lines += ['', 'Baseline: up to five recent successful runs of the same workflow and event. Runner/toolchain changes and small samples can affect comparisons.', '',
              '### Slowest steps', '', '| Job / step | Elapsed |', '| --- | ---: |']
    steps = [(s['elapsedSeconds'], row['name'], s['name']) for row in report['jobs'] for s in row['steps']]
    for seconds, job, step in sorted(steps, reverse=True)[:12]:
        lines.append(f'| {cell(job)} / {cell(step)} | {elapsed(seconds)} |')
    return '\n'.join(lines) + '\n'


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def jobs_for(repo, run):
    values, page = [], 1
    while True:
        payload = api(f'repos/{repo}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs?per_page=100&page={page}')
        values.extend(payload['jobs'])
        if len(values) >= payload['total_count'] or not payload['jobs']:
            return values
        page += 1


def report_run(repo, run_id, output):
    run = api(f'repos/{repo}/actions/runs/{run_id}')
    jobs = jobs_for(repo, run)
    past = api(f'repos/{repo}/actions/workflows/{run["workflow_id"]}/runs?status=success&event={run["event"]}&per_page=6')
    candidates = [r for r in past['workflow_runs'] if r['id'] != run['id'] and r['created_at'] < run['created_at']][:5]
    baselines = [jobs_for(repo, old) for old in candidates]
    result = summarize(run, jobs, baselines)
    result['baselineRunIDs'] = [r['id'] for r in candidates]
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, indent=2) + '\n')
    text = markdown(result)
    target.with_suffix('.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(text)
    print(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    measure = commands.add_parser('measure')
    measure.add_argument('--name', required=True)
    measure.add_argument('--output', required=True)
    measure.add_argument('command', nargs=argparse.REMAINDER)
    report = commands.add_parser('report')
    report.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY'))
    report.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID'))
    report.add_argument('--output', default='ci-timings.json')
    args = parser.parse_args()
    if args.mode == 'measure':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        if not command:
            parser.error('a command is required')
        return measured(args.name, command, args.output)
    if not args.repo or not args.run_id:
        parser.error('--repo and --run-id are required')
    report_run(args.repo, args.run_id, args.output)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
