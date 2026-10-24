import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('ci_plan', Path(__file__).resolve().parents[2] / 'scripts/ci-plan.py')
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


class CIPlanTests(unittest.TestCase):
    def test_docs_and_report_changes_do_not_compile_swift(self):
        p = ci.plan('pull_request', ['README.md', 'docs/SETUP.md', 'scripts/ci-metrics.py', 'Tests/ReleasePipeline/test_ci_metrics.py'])
        self.assertFalse(p['native'])
        self.assertFalse(p['swift-security'])
        self.assertFalse(p['packages'])

    def test_protocol_change_keeps_native_tests_and_security_without_renders(self):
        p = ci.plan('pull_request', ['Sources/GarminBar/Protocol/GFDICodec.swift'])
        self.assertTrue(p['native'])
        self.assertTrue(p['swift-security'])
        self.assertFalse(p['render'])
        self.assertFalse(p['full'])
        self.assertFalse(p['packages'])

    def test_ui_change_renders_once_without_uploading_images_or_packages(self):
        p = ci.plan('pull_request', ['Sources/GarminBar/UI/Theme.swift'])
        self.assertTrue(p['render'])
        self.assertFalse(p['showcase'])
        self.assertFalse(p['packages'])

    def test_release_preparation_and_explicit_release_keep_full_coverage(self):
        for p in [ci.plan('push', ['VERSION']), ci.plan('push', ['project.yml']),
                  ci.plan('workflow_call', [], release_tag='v0.3.10')]:
            self.assertTrue(p['full'])
            self.assertTrue(p['native'])
            self.assertTrue(p['render'])
            self.assertTrue(p['swift-security'])
        self.assertTrue(ci.plan('workflow_call', [], release_tag='v0.3.10')['packages'])
        self.assertFalse(ci.plan('pull_request', ['VERSION'])['full'])

    def test_main_keeps_one_package_but_docs_only_main_does_not(self):
        self.assertTrue(ci.plan('push', ['Sources/GarminBar/Cloud/GarminChinaCloud.swift'])['packages'])
        self.assertFalse(ci.plan('push', ['README.cn.md'])['packages'])

    def test_explicit_manual_options_and_unknown_changes_fail_safe(self):
        self.assertTrue(ci.plan('workflow_dispatch', [], package=True)['packages'])
        self.assertTrue(ci.plan('workflow_dispatch', [], full=True)['full'])
        p = ci.plan('workflow_dispatch', [], showcase=True)
        self.assertTrue(p['render'])
        self.assertTrue(p['showcase'])
        self.assertTrue(ci.plan('pull_request', ['new-build-config'])['native'])
        self.assertTrue(ci.plan('pull_request', ['.github/workflows/build.yml'])['native'])
