import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location('ci_reuse', SCRIPTS / 'reuse-ci-artifacts.py')
reuse = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reuse)


class CIReuseTests(unittest.TestCase):
    def test_only_successful_exact_main_push_is_trusted(self):
        run = dict(event='push', head_branch='main', head_sha='a' * 40, conclusion='success',
                   status='completed', path='.github/workflows/ci.yml', repository={'full_name': 'owner/repo'})
        self.assertTrue(reuse.validate_run(run, 'a' * 40, 'owner/repo'))
        for field, value in [('event', 'pull_request'), ('head_branch', 'feature'), ('head_sha', 'b' * 40),
                             ('conclusion', 'cancelled'), ('status', 'in_progress'), ('path', 'other.yml')]:
            with self.subTest(field=field):
                self.assertFalse(reuse.validate_run({**run, field: value}, 'a' * 40, 'owner/repo'))

    def artifact(self, evidence_change=None, extra=False):
        package = b'synthetic package; native validation runs separately'
        evidence = dict(schemaVersion=1, commit='a' * 40, runID='123', architecture='arm64',
                        version='0.3.7', sha256=hashlib.sha256(package).hexdigest())
        evidence.update(evidence_change or {})
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as bundle:
            bundle.writestr('WristBeam-macOS-arm64.zip', package)
            bundle.writestr('build-evidence-arm64.json', json.dumps(evidence))
            if extra:
                bundle.writestr('../escape', 'no')
        raw = stream.getvalue()
        return raw, 'sha256:' + hashlib.sha256(raw).hexdigest()

    def test_package_must_match_artifact_hash_source_run_version_and_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            raw, digest = self.artifact()
            reuse.unpack_verified(raw, digest, Path(directory), 'arm64', 'a' * 40, '123', '0.3.7')
            self.assertTrue((Path(directory) / 'WristBeam-macOS-arm64.zip').is_file())
            with self.assertRaises(ValueError):
                reuse.unpack_verified(raw, 'sha256:bad', Path(directory), 'arm64', 'a' * 40, '123', '0.3.7')
            for field, value in [('commit', 'b' * 40), ('runID', '456'), ('version', '9.9.9'),
                                 ('architecture', 'x86_64'), ('sha256', '0' * 64)]:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    raw, digest = self.artifact({field: value})
                    reuse.unpack_verified(raw, digest, Path(directory), 'arm64', 'a' * 40, '123', '0.3.7')
            raw, digest = self.artifact(extra=True)
            with self.assertRaises(ValueError):
                reuse.unpack_verified(raw, digest, Path(directory), 'arm64', 'a' * 40, '123', '0.3.7')
