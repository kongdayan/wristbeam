import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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
