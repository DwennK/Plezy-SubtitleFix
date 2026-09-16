#!/usr/bin/env python3
"""Extract the predeclared independent film partition from verified local sources.

Never transcribes audio, changes subtitle timings, downloads user media, or
selects a partition based on observed inference results. Sources and derivative
licenses are recorded separately. Fetch the two pinned HTTPS URLs in the manifest
before invoking this script; an existing output directory must be empty.
"""
import argparse
import json
import shutil
import subprocess
import wave
from pathlib import Path

from prepare_native import ROOT, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'test/fixtures/livesync/elephants-dream-validation.json').read_text())
    for kind in ['media', 'subtitles']:
        entry = manifest[kind]
        if Path(entry['name']).name != entry['name']:
            raise ValueError('Unexpected source filename')
        path = args.source / entry['name']
        if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
            raise ValueError(f'Pinned {kind} source differs; preserving it')
    if args.output.exists() and any(args.output.iterdir()):
        raise ValueError('Refusing to overwrite an existing fixture')
    start = manifest['partition']['startSeconds']
    end = manifest['partition']['endSeconds']
    if not 0 <= start < end or end - start > 180:
        raise ValueError('Invalid frozen partition')
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        'ffmpeg', '-v', 'error', '-n', '-ss', str(start),
        '-i', str(args.source / manifest['media']['name']), '-t', str(end - start),
        '-map', '0:a:0', '-vn', '-af', 'asetpts=PTS-STARTPTS', '-ar', '16000', '-ac', '1',
        '-c:a', 'pcm_s16le', str(args.output / 'fixture.wav'),
    ], check=True)
    with wave.open(str(args.output / 'fixture.wav')) as stream:
        if (stream.getframerate(), stream.getnchannels(), stream.getsampwidth(), stream.getnframes()) != (
                16000, 1, 2, (end - start) * 16000):
            raise ValueError('Unexpected decoded sample timeline')
    shutil.copyfile(args.source / manifest['subtitles']['name'], args.output / 'fixture.srt')
    (args.output / 'ATTRIBUTION.txt').write_text('\n\n'.join([
        manifest['media']['attribution'] + '\n' + manifest['media']['licenseUrl']
        + '\nChanges: selected audio partition, downmixed to mono and resampled to 16 kHz PCM.',
        manifest['subtitles']['attribution'] + '\n' + manifest['subtitles']['licenseUrl']
        + '\n' + manifest['subtitles']['sourcePage'] + '\nChanges: none; original subtitle bytes retained.',
    ]) + '\n')
    record = {
        'source': manifest, 'expectedOffsetSeconds': -start, 'expectedSlope': 1,
        'sourcePcmConvertedOfflineForFixtureOnly': True,
        'fullFilmDecoded': False, 'inferencePerformed': False,
        'ffmpeg': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
        'files': {name: digest(args.output / name) for name in ['fixture.wav', 'fixture.srt', 'ATTRIBUTION.txt']},
    }
    (args.output / 'fixture-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'partition': [start, end], 'samples': (end - start) * 16000, 'files': record['files']}))


if __name__ == '__main__':
    main()
