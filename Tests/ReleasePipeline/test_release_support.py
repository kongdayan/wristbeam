import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from release_support import APP_NAME, ARCHITECTURES, BUNDLE_ID, archive_name, file_digest, read_archive, release_version, safe_member, write_manifest


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pulse-release-unit-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version_file = self.root / 'VERSION'
        self.version_file.write_text('0.3.1\n')

    def package(self, name='valid.zip', changes=None, extra=None):
        info = {'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': 'GarminPulse', 'CFBundleShortVersionString': '0.3.1', 'LSMinimumSystemVersion': '13.0'}
        info.update(changes or {})
        path = self.root / name
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(APP_NAME + '/Contents/Info.plist', plistlib.dumps(info))
            archive.writestr(APP_NAME + '/Contents/Resources/LICENSE', 'MIT License\nCopyright (c) test\n')
            if extra:
                archive.writestr(*extra)
        return path

    def test_exact_stable_version_tag(self):
        self.assertEqual(release_version('v0.3.1', self.version_file), '0.3.1')
        for tag in ['v0.3.0', 'v0.3.1-beta', '0.3.1', 'v0.3.1/../bad', 'v0.3.1\n']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version(tag, self.version_file)

    def test_malformed_source_version(self):
        for value in ['0.03.1', '1', '1.2.3-beta', '1.2.3\n4', 'v1.2.3']:
            self.version_file.write_text(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                release_version(version_file=self.version_file)

    def test_archive_names_are_bounded(self):
        self.assertEqual(archive_name('universal'), 'WristBeam-macOS-universal.zip')
        for name in ['../arm64', 'armv7', 'x64', '']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                archive_name(name)

    def test_safe_paths_reject_traversal_control_and_foreign_roots(self):
        for name in ['/tmp/escape', APP_NAME + '/../escape', APP_NAME + '//Contents', APP_NAME + '/./Contents', APP_NAME + '\\Contents', APP_NAME + '/Contents\nfile', 'Other.app/Contents']:
            with self.subTest(name=name):
                self.assertFalse(safe_member(zipfile.ZipInfo(name)))
        self.assertTrue(safe_member(zipfile.ZipInfo(APP_NAME + '/Contents/')))
        self.assertTrue(safe_member(zipfile.ZipInfo('__MACOSX/._WristBeam.app')))

    def test_symlinks_and_encryption_rejected(self):
        link = zipfile.ZipInfo(APP_NAME + '/Contents/link')
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.assertFalse(safe_member(link))
        encrypted = zipfile.ZipInfo(APP_NAME + '/Contents/private')
        encrypted.flag_bits |= 1
        self.assertFalse(safe_member(encrypted))

    def test_production_archive_metadata(self):
        self.assertEqual(read_archive(self.package(), '0.3.1')['CFBundleIdentifier'], BUNDLE_ID)

    def test_identity_version_minimum_and_demo_mismatch(self):
        for changes in [{'CFBundleIdentifier': 'other.app'}, {'CFBundleExecutable': 'Other'}, {'CFBundleShortVersionString': '0.3.0'}, {'LSMinimumSystemVersion': '14.0'}, {'GarminPulsePreview': False}, {'WristBeamPreviewOnboarding': True}, {'GarminPulseUpdateFixture': '/tmp/test.json'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                read_archive(self.package(changes=changes), '0.3.1')

    def test_private_data_and_extensions_rejected(self):
        for name in ['Resources/secret.FIT', 'Resources/events.jsonl', 'Resources/runtime-state.json', 'Resources/auth/session.json', 'Resources/Received/data', 'Resources/Widget.appex/Contents/test']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                read_archive(self.package(extra=(APP_NAME + '/Contents/' + name, b'private')), '0.3.1')

    def test_duplicate_members_rejected(self):
        path = self.package()
        with zipfile.ZipFile(path, 'a') as archive:
            archive.writestr(APP_NAME + '/Contents/Info.plist', b'bad')
        with self.assertRaises(ValueError):
            read_archive(path, '0.3.1')

    def test_compression_expansion_budget(self):
        path = self.package()
        original = zipfile.ZipFile.infolist
        def enlarged(archive):
            members = original(archive)
            members[0].file_size = 500_000_000
            return members
        from unittest.mock import patch
        with patch.object(zipfile.ZipFile, 'infolist', enlarged), self.assertRaises(ValueError):
            read_archive(path, '0.3.1')

    def test_missing_or_non_mit_license_rejected(self):
        path = self.root / 'without-license.zip'
        info = read_archive(self.package(), '0.3.1')
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr(APP_NAME + '/Contents/Info.plist', plistlib.dumps(info))
            archive.writestr(APP_NAME + '/Contents/Resources/LICENSE', 'Different License')
        with self.assertRaises(ValueError):
            read_archive(path, '0.3.1')

    def test_manifest_requires_all_architectures_and_full_commit(self):
        with self.assertRaises(ValueError):
            write_manifest(self.root, '0.3.1', 'abc123')
        with self.assertRaises(ValueError):
            write_manifest(self.root, '0.3.1', 'a' * 40)

    def test_manifest_has_digests_for_exact_public_assets(self):
        for architecture in ARCHITECTURES:
            self.package(archive_name(architecture))
        manifest = write_manifest(self.root, '0.3.1', 'a' * 40)
        self.assertEqual(manifest['tag'], 'v0.3.1')
        self.assertEqual(len(manifest['assets']), 3)
        for asset in manifest['assets']:
            self.assertEqual(asset['sha256'], file_digest(self.root / asset['name']))
        self.assertEqual(json.loads((self.root / 'release-manifest.json').read_text()), manifest)
        self.assertEqual(len((self.root / 'SHA256SUMS.txt').read_text().splitlines()), 3)

    def test_unexpected_zip_not_silently_published(self):
        for architecture in ARCHITECTURES:
            self.package(archive_name(architecture))
        self.package('Demo.zip')
        with self.assertRaises(ValueError):
            write_manifest(self.root, '0.3.1', 'a' * 40)

    def test_streaming_checksum_changes_when_content_changes(self):
        p = self.root / 'bytes'
        p.write_bytes(b'abc')
        self.assertEqual(file_digest(p), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        p.write_bytes(b'abd')
        self.assertNotEqual(file_digest(p), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
