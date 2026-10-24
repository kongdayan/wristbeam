from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('cleanup', Path(__file__).resolve().parents[2] / 'scripts/prune-actions-artifacts.py')
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)
NOW = datetime(2026, 10, 24, tzinfo=timezone.utc)


def artifact(id, name='showcase-macos15', run_id=1, created='2026-10-15T00:00:00Z'):
    return dict(id=id, name=name, workflow_run={'id': run_id}, size_in_bytes=100, created_at=created, expired=False)


def run(id=1, branch='main', event='push', status='completed', conclusion='success'):
    return dict(id=id, head_branch=branch, event=event, status=status, conclusion=conclusion,
                created_at='2026-10-15T00:00:00Z', path='.github/workflows/ci.yml')


class ArtifactCleanupTests(unittest.TestCase):
    def test_only_old_allowlisted_artifacts_are_selected(self):
        artifacts = [artifact(1), artifact(2, 'native-interface-macos15', created='2026-10-23T00:00:00Z'),
                     artifact(3, 'release-arm64', created='2026-10-20T00:00:00Z'),
                     artifact(4, 'unknown-user-backup'), artifact(5, 'ci-timings'),
                     artifact(6, 'release-x86_64', run_id=999)]
        plan = cleanup.cleanup_plan(artifacts, [run()], set(), NOW)
        self.assertEqual([a['id'] for a in plan['delete']], [1, 5])
        self.assertEqual(plan['deleteBytes'], 200)

    def test_active_unknown_and_expired_artifacts_are_never_deleted(self):
        artifacts = [artifact(1), artifact(2, run_id=2), {**artifact(3), 'expired': True}]
        plan = cleanup.cleanup_plan(artifacts, [run(status='in_progress')], set(), NOW)
        self.assertFalse(plan['delete'])
        self.assertEqual(plan['liveArtifacts'], 2)

    def test_latest_full_main_and_open_pr_primary_packages_are_pinned(self):
        artifacts = [artifact(1, 'release-arm64'), artifact(2, 'release-x86_64'),
                     artifact(3, 'release-arm64', run_id=2), artifact(4, run_id=2),
                     artifact(5, 'release-arm64', run_id=3), artifact(6, 'package-macos14-arm64')]
        runs = [run(), run(2, 'open-feature', 'pull_request'), run(3, 'closed-feature', 'pull_request')]
        plan = cleanup.cleanup_plan(artifacts, runs, {'open-feature'}, NOW)
        self.assertEqual(plan['pinnedRunIDs'], [1, 2])
        self.assertEqual([a['id'] for a in plan['delete']], [4, 5, 6])

    def test_retention_boundary_and_failed_run_are_handled(self):
        artifacts = [artifact(1, created='2026-10-21T00:00:00Z'),
                     artifact(2, created='2026-10-20T23:59:59Z')]
        plan = cleanup.cleanup_plan(artifacts, [run(conclusion='failure')], set(), NOW)
        self.assertEqual([a['id'] for a in plan['delete']], [2])

    def test_cancelled_runs_expire_earlier_but_failure_evidence_is_kept(self):
        artifacts = [artifact(1, created='2026-10-22T00:00:00Z')]
        cancelled = cleanup.cleanup_plan(artifacts, [run(conclusion='cancelled')], set(), NOW)
        failed = cleanup.cleanup_plan(artifacts, [run(conclusion='failure')], set(), NOW)
        self.assertEqual([a['id'] for a in cancelled['delete']], [1])
        self.assertFalse(failed['delete'])
