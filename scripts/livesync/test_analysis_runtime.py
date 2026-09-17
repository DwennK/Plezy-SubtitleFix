"""Packaging guards for explicit CPU/Metal profiles and immutable runtime bytes."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_analysis_runtime as runtime
from prepare_native import digest


class RuntimeVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='livesync-runtime-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'build/livesync/runtime/macos-arm64'
        self.directory.mkdir(parents=True)
        self.names = ['capture.dylib', 'inference.dylib']
        self.files = self.names + ['whisper-ggml-LICENSE', 'SILERO-LICENSE']
        for name in self.files:
            (self.directory / name).write_bytes(b'inert packaging test bytes')
        self.inputs = {'target': 'macos-arm64', 'profile': 'portable-cpu', 'sourceSha256': 'current-source'}
        self.record = {'inputs': self.inputs, 'files': {name: digest(self.directory / name) for name in self.files}}
        self.write_record()
        # Replace only source-input discovery, not profile selection, expected
        # profile comparison, file-set validation or file hashing under test.
        self.root_patch = patch.object(runtime, 'ROOT', self.root)
        self.settings_patch = patch.object(runtime, 'settings', side_effect=self.expected_settings)
        self.root_patch.start()
        self.settings_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.settings_patch.stop)

    def expected_settings(self, target, profile):
        self.assertEqual(target, 'macos-arm64')
        self.assertIn(profile, ('cpu', 'metal'))
        expected = {'target': target, 'sourceSha256': 'current-source',
                    'profile': 'portable-cpu' if profile == 'cpu' else 'metal-preferred-with-cpu-fallback'}
        return self.root, self.names, expected

    def write_record(self):
        (self.directory / 'provenance.json').write_text(json.dumps(self.record))

    def test_cpu_profile_remains_default_compatible(self):
        self.assertEqual(runtime.verify('macos-arm64'), self.directory)
        self.assertEqual(runtime.verify('macos-arm64', 'cpu'), self.directory)

    def test_explicit_profile_cannot_silently_reuse_other_backend(self):
        with self.assertRaises(ValueError):
            runtime.verify('macos-arm64', 'metal')
        self.inputs['profile'] = 'metal-preferred-with-cpu-fallback'
        self.write_record()
        self.assertEqual(runtime.verify('macos-arm64'), self.directory)
        self.assertEqual(runtime.verify('macos-arm64', 'metal'), self.directory)
        with self.assertRaises(ValueError):
            runtime.verify('macos-arm64', 'cpu')

    def test_unknown_profile_and_stale_sources_fail_closed(self):
        for key, value in [('profile', 'unreviewed-backend'), ('sourceSha256', 'old-source')]:
            with self.subTest(key=key):
                original = self.inputs[key]
                self.inputs[key] = value
                self.write_record()
                with self.assertRaises(ValueError):
                    runtime.verify('macos-arm64')
                self.inputs[key] = original

    def test_corrupt_runtime_and_missing_license_are_rejected(self):
        (self.directory / self.names[0]).write_bytes(b'changed bytes')
        with self.assertRaises(ValueError):
            runtime.verify('macos-arm64')
        (self.directory / self.names[0]).write_bytes(b'inert packaging test bytes')
        self.record['files'].pop('SILERO-LICENSE')
        self.write_record()
        with self.assertRaises(ValueError):
            runtime.verify('macos-arm64')

    def test_symlink_is_not_a_verified_bundled_file(self):
        destination = self.directory / self.names[0]
        outside = self.root / 'external-bytes'
        destination.rename(outside)
        try:
            destination.symlink_to(outside)
        except OSError:
            self.skipTest('Creating symbolic links is unavailable on this test host')
        with self.assertRaises(ValueError):
            runtime.verify('macos-arm64')


class ProfileSelectionTests(unittest.TestCase):
    def test_metal_cannot_be_selected_for_windows_or_unknown_targets(self):
        for target in ('windows-x64', 'macos-x64', 'linux-x64'):
            with self.subTest(target=target), self.assertRaises(ValueError):
                runtime.settings(target, 'metal')


if __name__ == '__main__':
    unittest.main()
