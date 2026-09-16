#!/usr/bin/env python3
"""Score a completed native probe against an offline edit oracle.

The expected timeline is read only after inference. It never supplies anchors,
transcripts, boundaries or offsets to the live learner.
"""
import argparse
import json
import math
import statistics
from pathlib import Path

from prepare_native import digest


def evaluate(report, truth):
    expected_gaps = truth['gaps']
    actual_gaps = report['learnedGaps']
    gap_checks = []
    for expected in expected_gaps:
        matches = [gap for gap in actual_gaps if gap['kind'] == expected['kind']
                   and abs(gap['start'] - expected['start']) <= 0.75
                   and abs(gap['end'] - expected['end']) <= 0.75]
        gap_checks.append({'expected': expected, 'matched': len(matches) == 1})
    samples = []
    gap_samples = []
    for sample in report['trackingSamples']:
        media = sample['mediaTime']
        if any(gap['kind'] == 'videoOnly' and gap['start'] <= media < gap['end'] for gap in expected_gaps):
            gap_samples.append({'mediaTime': media, 'actualRegion': sample['regionKind']})
            continue
        expected = next((s for s in truth['segments']
                         if s['slope'] * s['subtitleStart'] + s['offset'] <= media
                         < s['slope'] * s['subtitleEnd'] + s['offset']), None)
        if expected is None:
            continue
        delay = media - (media - expected['offset']) / expected['slope']
        samples.append({'mediaTime': media, 'expectedDelay': delay,
                        'actualDelay': sample['nativeDelay'], 'actualRegion': sample['regionKind'],
                        'mappingAvailable': sample['mappingAvailable'],
                        'error': abs(sample['nativeDelay'] - delay)})
    errors = sorted(sample['error'] for sample in samples)
    median = statistics.median(errors) if errors else None
    p95 = errors[math.ceil(len(errors) * .95) - 1] if errors else None
    before, after = truth['segments']
    recovery_start = after['slope'] * after['subtitleStart'] + after['offset']
    post = [sample for sample in samples if sample['mediaTime'] >= recovery_start]
    recovered = next((sample for sample in post if sample['mappingAvailable'] and sample['error'] <= .75), None)
    pre = [sample for sample in samples
           if sample['mediaTime'] < before['slope'] * before['subtitleEnd'] + before['offset']]
    acquired_before_edit = bool(pre) and report['acquisitionMs'] <= 45000
    recovery = recovered['mediaTime'] - recovery_start if recovered else None
    return {
        'scope': 'native PCM/ASR and domain tracking only; no production controller or renderer claim',
        'initialAcquisitionBeforeEdit': acquired_before_edit,
        'postEditRecoveryMediaSeconds': recovery,
        'alignedTrackingMedianErrorSeconds': median,
        'alignedTrackingP95ErrorSeconds': p95,
        'alignedSampleCount': len(samples),
        'gapChecks': gap_checks,
        'unexpectedGapCount': len(actual_gaps) - sum(check['matched'] for check in gap_checks),
        'gapPlaybackSamples': gap_samples,
        'alignedPlaybackSamples': samples,
        'cueBoundaryRenderingValidated': False,
        'backwardSeekValidated': False,
        'satisfiesSceneDomainChecks': bool(
            acquired_before_edit and recovery is not None and recovery <= 30
            and len(samples) >= 10 and median <= .25 and p95 <= .75
            and len(actual_gaps) == len(expected_gaps) and all(check['matched'] for check in gap_checks)
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--expected', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Refusing to overwrite existing evidence')
    assessment = evaluate(json.loads(args.probe.read_text()), json.loads(args.expected.read_text()))
    assessment['probeSha256'] = digest(args.probe)
    assessment['expectedTimelineSha256'] = digest(args.expected)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(assessment, indent=2) + '\n')
    print(json.dumps({k: v for k, v in assessment.items() if not k.endswith('Samples')}))


if __name__ == '__main__':
    main()
