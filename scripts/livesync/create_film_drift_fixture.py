#!/usr/bin/env python3
"""Prepare bounded film drift regressions from already acquired public sources."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import shutil
import subprocess

from prepare_native import ROOT, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=['aligned', 'faster', 'slower'], required=True)
    args = parser.parse_args()
    manifest_path = ROOT / 'test/fixtures/livesync/film-drift-development.json'
    manifest = json.loads(manifest_path.read_text())
    for key in ['media', 'subtitles']:
        entry = manifest[key]
        path = args.source / entry['name']
        if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError('Film source differs from the frozen development source')
    start, end = manifest['partitionSeconds']
    if start != 0:
        raise ValueError('Review Ogg seek/preroll semantics before changing this partition')
    case = manifest['cases'][args.case]
    slope = Fraction(case['slopeNumerator'], case['slopeDenominator'])
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        # Even an input seek to zero can change Ogg decoder preroll. Decode
        # this frozen initial partition without a seek, as in the baseline.
        'ffmpeg', '-v', 'error', '-y', '-t', str(end - start),
        '-i', str(args.source / manifest['media']['name']), '-vn',
        '-af', f'atempo={float(1 / slope):.15f}', '-ar', '16000', '-ac', '1',
        '-c:a', 'pcm_s16le', str(args.output / 'fixture.wav'),
    ], check=True)
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries',
        'stream=sample_rate,channels,duration_ts,time_base', '-of', 'json',
        str(args.output / 'fixture.wav'),
    ], text=True))['streams'][0]
    if probe['sample_rate'] != '16000' or probe['channels'] != 1 or probe['time_base'] != '1/16000':
        raise ValueError('Unexpected fixture PCM format')
    samples = int(probe['duration_ts'])
    duration_error = samples / 16000 - float((end - start) * slope)
    if abs(duration_error) > 0.2:
        raise ValueError('Tempo output duration exceeds the documented bound')
    subprocess.run([
        'ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i',
        'color=c=0x10151e:s=1280x720:r=24', '-i', str(args.output / 'fixture.wav'),
        '-map', '0:v', '-map', '1:a', '-shortest', '-c:v', 'ffv1', '-c:a', 'copy',
        '-metadata:s:a:0', 'language=eng', str(args.output / 'fixture.mkv'),
    ], check=True)
    shutil.copyfile(args.source / manifest['subtitles']['name'], args.output / 'fixture.srt')
    record = {
        'sourceManifest': manifest, 'sourceManifestSha256': digest(manifest_path),
        'case': args.case, 'expectedSlope': float(slope), 'expectedOffset': -start * float(slope),
        'sampleRate': 16000, 'outputSamples': samples, 'tempoDurationErrorSeconds': duration_error,
        'files': {name: digest(args.output / name) for name in ['fixture.wav', 'fixture.mkv', 'fixture.srt']},
        'ffmpeg': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
        'inferencePerformed': False,
    }
    (args.output / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'case': args.case, 'outputSamples': samples, 'tempoDurationErrorSeconds': duration_error}))


if __name__ == '__main__':
    main()
