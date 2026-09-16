#!/usr/bin/env python3
"""Run the dedicated controller harness on a hosted Mac, preserving failures.

The ordinary application archive must be preserved before the harness build.
Only this script's child process is terminated; no installed application is used.
"""
import argparse
import json
import math
import plistlib
import shutil
import subprocess
import time
from pathlib import Path


def validate_report(report, fixture, mode):
    if report.get('passed') is not True:
        return 'controller-failed'
    if (report.get('kind') != 'actual-plezy-production-controller-calibration'
            or report.get('platform') != 'macos' or report.get('flutterBuildMode') != mode
            or report.get('fixtureCase') != fixture['case']
            or report.get('expectedOffset') != fixture['expectedOffsetSeconds']):
        return 'report-identity'
    target = 45000 + fixture['introSilenceSeconds'] * 1000
    elapsed = report.get('acquisitionMs')
    error = report.get('absoluteOffsetError')
    if (type(elapsed) not in (int, float) or not math.isfinite(elapsed)
            or elapsed < 0 or elapsed > target or report.get('acquisitionTargetMs') != target
            or report.get('acquisitionTargetPassed') is not True):
        return 'acquisition-budget'
    if type(error) not in (int, float) or not math.isfinite(error) or not 0 <= error < 0.75:
        return 'offset-error'
    for key in ('wrongCachedGapRecoveryValidated', 'knownRegionRestoredAfterSeek',
                'unknownSeekClearsAutomaticOnly', 'audioDelayCompositionAndPreservation',
                'persistentCacheKnownAndUnknownRegions', 'manualDelayDuringAndAfter', 'tapDisabledOnClose'):
        if report.get(key) is not True:
            return f'missing-{key}'
    return None


def run_case(executable, fixture_dir, evidence_dir, mode, timeout):
    fixture = json.loads((fixture_dir / 'fixture-provenance.json').read_text())
    case = fixture['case']
    if case not in ('calibration', 'intro-90'):
        raise ValueError('Unexpected calibration case')
    result = fixture_dir / 'result.json'
    result.unlink(missing_ok=True)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    assessment = {'case': case, 'passed': False, 'scope': 'native production controller; null audio output'}
    process = None
    try:
        with (evidence_dir / f'controller-{case}.log').open('wb') as log:
            process = subprocess.Popen([str(executable)], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + timeout
            while True:
                try:
                    report = json.loads(result.read_text())
                except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
                    report = {}
                code = process.poll()
                if 'passed' in report:
                    failure = validate_report(report, fixture, mode)
                    if code not in (None, 0):
                        failure = 'process-exited-with-error'
                    assessment.update(passed=failure is None, failure=failure)
                    break
                if code is not None:
                    assessment['failure'] = 'process-exited-before-final-report'
                    break
                if time.monotonic() >= deadline:
                    assessment['failure'] = 'observation-timeout'
                    break
                time.sleep(0.5)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        shutil.copyfile(fixture_dir / 'fixture-provenance.json', evidence_dir / f'calibration-fixture-{case}.json')
        if result.exists():
            shutil.copyfile(result, evidence_dir / f'calibration-player-{case}.json')
        (evidence_dir / f'controller-runner-{case}.json').write_text(json.dumps(assessment, indent=2) + '\n')
    return assessment['passed']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--mode', choices=('debug', 'release'), required=True)
    parser.add_argument('--timeout', type=int, required=True)
    args = parser.parse_args()
    with (args.bundle / 'Contents/Info.plist').open('rb') as source:
        name = plistlib.load(source)['CFBundleExecutable']
    if Path(name).name != name:
        raise ValueError('Invalid bundle executable')
    executable = (args.bundle / 'Contents/MacOS' / name).resolve(strict=True)
    if not 1 <= args.timeout <= 300:
        raise ValueError('Invalid observation timeout')
    return 0 if run_case(executable, args.fixture, args.evidence, args.mode, args.timeout) else 1


if __name__ == '__main__':
    raise SystemExit(main())
