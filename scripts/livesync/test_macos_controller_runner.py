import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from run_macos_controller import run_case, validate_report


class MacControllerRunnerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {'case': 'calibration', 'expectedOffsetSeconds': -100, 'introSilenceSeconds': 0}
        self.report = {
            'passed': True, 'kind': 'actual-plezy-production-controller-calibration',
            'platform': 'macos', 'flutterBuildMode': 'release', 'fixtureCase': 'calibration',
            'expectedOffset': -100, 'acquisitionMs': 21000, 'acquisitionTargetMs': 45000,
            'acquisitionTargetPassed': True, 'absoluteOffsetError': 0.21,
            **{key: True for key in ('wrongCachedGapRecoveryValidated', 'knownRegionRestoredAfterSeek',
                                    'unknownSeekClearsAutomaticOnly', 'audioDelayCompositionAndPreservation',
                                    'persistentCacheKnownAndUnknownRegions', 'manualDelayDuringAndAfter',
                                    'tapDisabledOnClose')},
        }

    def test_final_controller_success_must_also_meet_acquisition_budget(self):
        self.assertIsNone(validate_report(self.report, self.fixture, 'release'))
        self.report['acquisitionMs'] = 45001
        self.assertEqual(validate_report(self.report, self.fixture, 'release'), 'acquisition-budget')

    def test_intro_budget_and_identity_are_checked_from_fixture(self):
        self.fixture.update(case='intro-90', expectedOffsetSeconds=90, introSilenceSeconds=90)
        self.assertEqual(validate_report(self.report, self.fixture, 'release'), 'report-identity')
        self.report.update(fixtureCase='intro-90', expectedOffset=90, acquisitionMs=125000, acquisitionTargetMs=135000)
        self.assertIsNone(validate_report(self.report, self.fixture, 'release'))

    def test_non_finite_timing_and_missing_control_checks_cannot_pass(self):
        for value in (float('nan'), float('inf'), -1, True, 0.75):
            with self.subTest(value=value):
                self.assertEqual(validate_report({**self.report, 'absoluteOffsetError': value}, self.fixture, 'release'),
                                 'offset-error')
        self.report.pop('manualDelayDuringAndAfter')
        self.assertEqual(validate_report(self.report, self.fixture, 'release'), 'missing-manualDelayDuringAndAfter')

    def test_stale_success_is_removed_and_partial_report_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture_dir = Path(directory) / 'fixture'
            fixture_dir.mkdir()
            evidence = Path(directory) / 'evidence'
            result = fixture_dir / 'result.json'
            (fixture_dir / 'fixture-provenance.json').write_text(json.dumps(self.fixture))
            result.write_text(json.dumps(self.report))
            process = Mock()
            process.poll.return_value = None

            def launch(*args, **kwargs):
                self.assertFalse(result.exists())
                result.write_text('{"passed":')
                return process

            with patch('run_macos_controller.subprocess.Popen', side_effect=launch), \
                    patch('run_macos_controller.time.monotonic', side_effect=[0, 2]):
                self.assertFalse(run_case(Path('/fixture/app'), fixture_dir, evidence, 'release', 1))
            process.terminate.assert_called_once()
            self.assertEqual((evidence / 'calibration-player-calibration.json').read_text(), '{"passed":')
            self.assertEqual(json.loads((evidence / 'controller-runner-calibration.json').read_text())['failure'],
                             'observation-timeout')

    def test_completed_report_is_preserved_and_only_owned_process_is_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture_dir = Path(directory)
            (fixture_dir / 'fixture-provenance.json').write_text(json.dumps(self.fixture))
            process = Mock()
            process.poll.return_value = None

            def launch(*args, **kwargs):
                (fixture_dir / 'result.json').write_text(json.dumps(self.report))
                return process

            with patch('run_macos_controller.subprocess.Popen', side_effect=launch):
                self.assertTrue(run_case(Path('/fixture/app'), fixture_dir, fixture_dir / 'out', 'release', 1))
            process.terminate.assert_called_once()
            process.kill.assert_not_called()
            self.assertEqual(json.loads((fixture_dir / 'out/calibration-player-calibration.json').read_text()), self.report)

    def test_process_exit_cannot_be_mistaken_for_success(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture_dir = Path(directory)
            (fixture_dir / 'fixture-provenance.json').write_text(json.dumps(self.fixture))
            process = Mock()
            process.poll.return_value = 1
            with patch('run_macos_controller.subprocess.Popen', return_value=process):
                self.assertFalse(run_case(Path('/fixture/app'), fixture_dir, fixture_dir / 'out', 'release', 1))
            process.terminate.assert_not_called()
            result = json.loads((fixture_dir / 'out/controller-runner-calibration.json').read_text())
            self.assertEqual(result['failure'], 'process-exited-before-final-report')

    def test_other_platform_or_debug_result_cannot_validate_mac_release(self):
        for change in ({'platform': 'windows'}, {'flutterBuildMode': 'debug'}, {'fixtureCase': 'intro-90'}):
            with self.subTest(change=change):
                self.assertEqual(validate_report({**self.report, **change}, self.fixture, 'release'), 'report-identity')


if __name__ == '__main__':
    unittest.main()
