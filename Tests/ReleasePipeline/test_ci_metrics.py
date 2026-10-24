import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/ci-metrics.py'
SPEC = importlib.util.spec_from_file_location('ci_metrics', SCRIPT)
metrics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metrics)


class CITimingTests(unittest.TestCase):
    def job(self, name='Build', seconds=60, status='completed', conclusion='success'):
        return dict(name=name, started_at='2026-10-19T00:01:00Z',
                    completed_at=f'2026-10-19T00:{1 + seconds // 60:02d}:{seconds % 60:02d}Z',
                    status=status, conclusion=conclusion,
                    steps=[dict(name='Compile', status='completed', conclusion='success',
                                started_at='2026-10-19T00:01:00Z', completed_at='2026-10-19T00:01:20Z')])

    def test_pending_skipped_and_missing_times_are_not_finished_durations(self):
        for changes in [dict(status='in_progress'), dict(conclusion='skipped'),
                        dict(completed_at='0001-01-01T00:00:00Z'), dict(started_at=None)]:
            self.assertIsNone(metrics.duration({**self.job(), **changes}))
        self.assertEqual(metrics.duration(self.job()), 60)

    def test_history_is_job_matched_and_failed_jobs_do_not_pollute_median(self):
        run = dict(id=123, head_sha='a' * 40, event='pull_request', created_at='2026-10-19T00:00:00Z')
        baseline = [[self.job(seconds=30)], [self.job(seconds=50)],
                    [self.job(seconds=300, conclusion='failure')], [self.job(name='Other', seconds=500)]]
        report = metrics.summarize(run, [self.job(), self.job(name='CI timing report'), self.job(name='Release checks / CI timing report')], baseline)
        self.assertEqual(len(report['jobs']), 1)
        row = report['jobs'][0]
        self.assertEqual(row['baselineSamples'], 2)
        self.assertEqual(row['baselineMedianSeconds'], 40)
        self.assertEqual(row['changePercent'], 50)
        self.assertEqual(report['initialWaitSeconds'], 60)
        self.assertEqual(report['jobElapsedSumSeconds'], 60)
        self.assertIn('Slowest steps', metrics.markdown(report))

    def test_process_failure_propagates_and_arguments_are_not_recorded(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'timing.json'
            result = subprocess.run([sys.executable, str(SCRIPT), 'measure', '--name', 'fixture',
                                     '--output', str(output), '--', sys.executable, '-c',
                                     'import sys; sys.exit(7)', 'fixture-secret-not-for-report'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            payload = output.read_text()
            self.assertNotIn('fixture-secret-not-for-report', payload + result.stdout)
            value = json.loads(payload)
            self.assertEqual(value['exitCode'], 7)
            self.assertGreaterEqual(value['elapsedSeconds'], 0)
            self.assertGreaterEqual(value['maxChildRSSBytes'], 0)

    def test_api_paginates_jobs_for_the_requested_attempt(self):
        calls = []
        original = metrics.api
        def fake(path):
            calls.append(path)
            return {'total_count': 2, 'jobs': [self.job(name=str(len(calls)))]}
        try:
            metrics.api = fake
            rows = metrics.jobs_for('owner/repo', {'id': 42, 'run_attempt': 2})
        finally:
            metrics.api = original
        self.assertEqual(len(rows), 2)
        self.assertIn('/attempts/2/jobs?', calls[0])
        self.assertTrue(calls[1].endswith('page=2'))

    def test_transient_api_failure_retries_then_succeeds(self):
        failed = subprocess.CompletedProcess([], 1, 'private response', 'gh: Server Error (HTTP 502)')
        success = subprocess.CompletedProcess([], 0, '{"jobs": []}', '')
        with patch.object(metrics.subprocess, 'run', side_effect=[failed, success]) as run, \
             patch.object(metrics.time, 'sleep') as sleep:
            self.assertEqual(metrics.api('fixture'), {'jobs': []})
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.kwargs['timeout'], 20)
        sleep.assert_called_once_with(1)

    def test_timeout_retries_are_bounded_and_do_not_expose_output(self):
        failure = subprocess.TimeoutExpired(['gh', 'api', 'fixture'], 20, output='secret')
        with patch.object(metrics.subprocess, 'run', side_effect=failure) as run, \
             patch.object(metrics.time, 'sleep') as sleep:
            with self.assertRaises(metrics.GitHubAPIError) as caught:
                metrics.api('fixture')
        self.assertEqual(run.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertTrue(caught.exception.retryable)
        self.assertNotIn('secret', str(caught.exception))

    def test_authentication_and_malformed_json_are_not_retried(self):
        for status in (401, 403):
            failed = subprocess.CompletedProcess([], 1, 'private response', f'secret (HTTP {status})')
            with patch.object(metrics.subprocess, 'run', return_value=failed) as run, \
                 patch.object(metrics.time, 'sleep') as sleep:
                with self.assertRaises(metrics.GitHubAPIError) as caught:
                    metrics.api('fixture')
            self.assertFalse(metrics.optional_history_error(caught.exception))
            self.assertNotIn('secret', str(caught.exception))
            run.assert_called_once()
            sleep.assert_not_called()
        with patch.object(metrics.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'invalid', '')):
            with self.assertRaises(json.JSONDecodeError):
                metrics.api('fixture')

    def test_missing_historical_jobs_keep_current_measurements_and_label_gap(self):
        run = dict(id=123, run_attempt=2, workflow_id=7, head_sha='a' * 40,
                   event='pull_request', created_at='2026-10-19T00:00:00Z')
        old = [{**run, 'id': i, 'created_at': '2026-10-18T00:00:00Z'} for i in (121, 122)]
        for status in (502, 404):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temp, \
                 patch.object(metrics, 'api', side_effect=[run, {'workflow_runs': old}]), \
                 patch.object(metrics, 'jobs_for', side_effect=[
                     [self.job()], metrics.GitHubAPIError(status, status == 502), [self.job(seconds=30)]]), \
                 patch.dict(metrics.os.environ, {'GITHUB_STEP_SUMMARY': ''}):
                output = Path(temp) / 'timing.json'
                metrics.report_run('owner/repo', 123, output)
                report = json.loads(output.read_text())
                self.assertEqual(report['baselineRunIDs'], [122])
                self.assertEqual(report['jobs'][0]['elapsedSeconds'], 60)
                self.assertEqual(report['jobs'][0]['baselineSamples'], 1)
                self.assertEqual(report['jobs'][0]['baselineMedianSeconds'], 30)
                self.assertIn('121', report['baselineWarnings'][0])
                self.assertIn('Historical comparison is incomplete', output.with_suffix('.md').read_text())

    def test_current_jobs_and_historical_authentication_failure_remain_fatal(self):
        run = dict(id=123, run_attempt=1, workflow_id=7, head_sha='a' * 40,
                   event='pull_request', created_at='2026-10-19T00:00:00Z')
        old = {**run, 'id': 122, 'created_at': '2026-10-18T00:00:00Z'}
        for responses in ([metrics.GitHubAPIError(502, True)],
                          [[self.job()], metrics.GitHubAPIError(403)]):
            with tempfile.TemporaryDirectory() as temp, \
                 patch.object(metrics, 'api', side_effect=[run, {'workflow_runs': [old]}]), \
                 patch.object(metrics, 'jobs_for', side_effect=responses):
                output = Path(temp) / 'timing.json'
                with self.assertRaises(metrics.GitHubAPIError):
                    metrics.report_run('owner/repo', 123, output)
                self.assertFalse(output.exists())

    def test_unavailable_history_listing_has_no_fabricated_baseline(self):
        run = dict(id=123, run_attempt=1, workflow_id=7, head_sha='a' * 40,
                   event='pull_request', created_at='2026-10-19T00:00:00Z')
        with tempfile.TemporaryDirectory() as temp, \
             patch.object(metrics, 'api', side_effect=[run, metrics.GitHubAPIError(503, True)]), \
             patch.object(metrics, 'jobs_for', return_value=[self.job()]), \
             patch.dict(metrics.os.environ, {'GITHUB_STEP_SUMMARY': ''}):
            output = Path(temp) / 'timing.json'
            metrics.report_run('owner/repo', 123, output)
            report = json.loads(output.read_text())
            self.assertEqual(report['baselineRunIDs'], [])
            self.assertEqual(report['jobs'][0]['baselineSamples'], 0)
            self.assertIsNone(report['jobs'][0]['baselineMedianSeconds'])
            self.assertTrue(report['baselineWarnings'])
