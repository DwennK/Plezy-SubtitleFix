#!/usr/bin/env python3
"""Make sample-exact edit fixtures from verified, previously consumed sources.

This offline test helper does not run ASR. Production never uses it to fetch or
decode another stream. Each output retains the complete, original Sintel SRT.
"""
import argparse
import array
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

from prepare_native import ROOT, digest


def frames(seconds, rate):
    value = seconds * rate
    rounded = round(value)
    if abs(value - rounded) > 1e-6:
        raise ValueError('Edit does not fall on a sample boundary')
    return rounded


def edit_plan(manifest, case):
    """Return copy ranges and an independent expected piecewise transform."""
    start, end = manifest['mainSource']['partitionSeconds']
    rate = manifest['sampleRate']
    edit = manifest['cases'][case]
    if edit['kind'] == 'insert':
        at = edit['atSubtitleSeconds']
        if not start < at < end:
            raise ValueError('Insertion outside main partition')
        extra_start, extra_end = manifest['insertSource']['partitionSeconds']
        duration = extra_end - extra_start
        if duration <= 0:
            raise ValueError('Empty insertion')
        copies = [('main', 0, frames(at - start, rate)),
                  ('insert', 0, frames(duration, rate)),
                  ('main', frames(at - start, rate), frames(end - start, rate))]
        segments = [(start, at, -start), (at, end, duration - start)]
        gap = {'kind': 'videoOnly', 'start': at - start, 'end': at - start + duration}
        boundaries = [at]
    elif edit['kind'] == 'remove':
        cut_start, cut_end = edit['startSubtitleSeconds'], edit['endSubtitleSeconds']
        if not start < cut_start < cut_end < end:
            raise ValueError('Removal outside main partition')
        duration = cut_end - cut_start
        copies = [('main', 0, frames(cut_start - start, rate)),
                  ('main', frames(cut_end - start, rate), frames(end - start, rate))]
        segments = [(start, cut_start, -start), (cut_end, end, -start - duration)]
        gap = {'kind': 'subtitleOnly', 'start': cut_start, 'end': cut_end}
        boundaries = [cut_start, cut_end]
    elif edit['kind'] == 'continuous':
        copies = [('main', 0, frames(end - start, rate))]
        segments = [(start, end, -start)]
        gap = None
        boundaries = []
    else:
        raise ValueError('Unknown edit')
    return copies, {
        'segments': [{'subtitleStart': a, 'subtitleEnd': b, 'slope': 1, 'offset': offset}
                     for a, b, offset in segments],
        'gaps': [] if gap is None else [gap], 'sourceBoundaries': boundaries,
        'expectedFrames': sum(b - a for _, a, b in copies),
    }


def edit_pcm(buffers, copies, frame_bytes):
    chunks = []
    for source, start, end in copies:
        data = buffers[source]
        if len(data) % frame_bytes or not 0 <= start < end <= len(data) // frame_bytes:
            raise ValueError('Invalid source sample range')
        chunks.append(data[start * frame_bytes:end * frame_bytes])
    return b''.join(chunks)


def apply_envelope(data, points, rate, channels):
    """Apply a declared sample-domain gain without moving any source sample."""
    if not points:
        return data
    if channels <= 0 or len(data) % (channels * 2):
        raise ValueError('Invalid interleaved PCM')
    knots = [(frames(time, rate), gain) for time, gain in points]
    count = len(data) // (channels * 2)
    if (len(knots) < 2 or knots[0][0] != 0 or knots[-1][0] != count
            or any(not math.isfinite(gain) or not 0 <= gain <= 1 for _, gain in knots)
            or any(a[0] >= b[0] for a, b in zip(knots, knots[1:]))):
        raise ValueError('Envelope must cover PCM once with increasing finite knots')
    samples = array.array('h')
    samples.frombytes(data)
    if sys.byteorder != 'little':
        samples.byteswap()
    for (start, left), (end, right) in zip(knots, knots[1:]):
        if left == right == 1:
            continue
        for frame in range(start, end):
            gain = left + (right - left) * (frame - start) / (end - start)
            for channel in range(channels):
                i = frame * channels + channel
                samples[i] = round(samples[i] * gain)
    if sys.byteorder != 'little':
        samples.byteswap()
    return samples.tobytes()


def cue_projection(srt, truth):
    """Expected display fragments; never supplied to the recognition engine."""
    stamp = r'(\d+):([0-5]\d):([0-5]\d),(\d{3})'
    pattern = re.compile(r'(?m)^(\d+)\r?\n' + stamp + r' --> ' + stamp)
    result = []
    for match in pattern.finditer(srt):
        values = list(map(int, match.groups()))
        def seconds(at):
            h, m, s, ms = values[at:at + 4]
            return h * 3600 + m * 60 + s + ms / 1000
        start, end = seconds(1), seconds(5)
        fragments = []
        for segment in truth['segments']:
            a, b = max(start, segment['subtitleStart']), min(end, segment['subtitleEnd'])
            if a < b:
                fragments.append([a + segment['offset'], b + segment['offset']])
        if fragments or any(start < gap['end'] and end > gap['start']
                            for gap in truth['gaps'] if gap['kind'] == 'subtitleOnly'):
            result.append({'cue': values[0], 'sourceStart': start, 'sourceEnd': end,
                           'crossesEditBoundary': any(start < t < end for t in truth['sourceBoundaries']),
                           'expectedMediaFragments': fragments})
    if not result:
        raise ValueError('No source cues in the chosen partition')
    return result


def verify(path, entry):
    if path.stat().st_size != entry['bytes'] or digest(path) != entry['sha256']:
        raise ValueError('Pinned public source differs; preserving it')


def decode(source, partition, output, rate, channels):
    start, end = partition
    subprocess.run([
        'ffmpeg', '-v', 'error', '-n', '-ss', str(start), '-i', str(source),
        '-t', str(end - start), '-map', '0:a:0', '-vn', '-af', 'asetpts=PTS-STARTPTS',
        '-ar', str(rate), '-ac', str(channels), '-c:a', 'pcm_s16le', str(output),
    ], check=True)
    with wave.open(str(output)) as stream:
        if (stream.getframerate(), stream.getnchannels(), stream.getsampwidth(), stream.getnframes()) != (
                rate, channels, 2, frames(end - start, rate)):
            raise ValueError('Decoded PCM timeline differs from frozen source interval')
        return stream.readframes(stream.getnframes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sintel-source', type=Path, required=True)
    parser.add_argument('--elephants-source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', required=True)
    parser.add_argument('--manifest', type=Path,
                        default=ROOT / 'test/fixtures/livesync/scene-edits-development.json')
    parser.add_argument('--video', action='store_true', help='Also mux a neutral video for native player probes')
    args = parser.parse_args()
    manifest_path = args.manifest
    manifest = json.loads(manifest_path.read_text())
    if args.case not in manifest['cases']:
        parser.error('Case is not declared in the fixture manifest')
    main_source, insert_source = manifest['mainSource'], manifest['insertSource']
    main_path = args.sintel_source / main_source['media']['name']
    srt_path = args.sintel_source / main_source['subtitles']['name']
    insert_path = args.elephants_source / insert_source['media']['name']
    copies, truth = edit_plan(manifest, args.case)
    verify(main_path, main_source['media'])
    verify(srt_path, main_source['subtitles'])
    has_insert = any(source == 'insert' for source, _, _ in copies)
    if has_insert:
        verify(insert_path, insert_source['media'])
    if args.output.exists() and any(args.output.iterdir()):
        raise ValueError('Refusing to overwrite an existing fixture')
    rate, channels = manifest['sampleRate'], manifest['channels']
    with tempfile.TemporaryDirectory(prefix='livesync-scene-sources-') as scratch:
        scratch = Path(scratch)
        buffers = {'main': decode(main_path, main_source['partitionSeconds'], scratch / 'main.wav', rate, channels)}
        if has_insert:
            buffers['insert'] = decode(insert_path, insert_source['partitionSeconds'], scratch / 'insert.wav', rate, channels)
        data = edit_pcm(buffers, copies, channels * 2)
        data = apply_envelope(data, manifest['cases'][args.case].get('gainEnvelope'), rate, channels)
    assert len(data) == truth['expectedFrames'] * channels * 2
    args.output.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output / 'fixture.wav'), 'wb') as stream:
        stream.setparams((channels, 2, rate, 0, 'NONE', 'not compressed'))
        stream.writeframes(data)
    shutil.copyfile(srt_path, args.output / 'fixture.srt')
    truth['cues'] = cue_projection(srt_path.read_text(encoding='utf-8-sig'), truth)
    (args.output / 'expected-timeline.json').write_text(json.dumps(truth, indent=2) + '\n')
    notices = [main_source['attribution'] + '\n' + main_source['licenseUrl']
               + '\nAudio changes: extract Sintel 100-175 s; stereo 48 kHz PCM; sample edits described in provenance. '
               + 'Subtitle changes: none; complete original bytes retained.']
    if manifest['cases'][args.case].get('gainEnvelope'):
        notices.append('Additional audio changes: the sample-domain gain envelope declared in '
                       'fixture-provenance.json; sample timing and subtitle bytes are unchanged.')
    if has_insert:
        extra = insert_source['media']
        notices.append(extra['attribution'] + '\n' + extra['licenseUrl'] + '\n' + extra['sourcePage']
                       + '\nChanges: extract audio 14-44 s, stereo 48 kHz PCM, insert into Sintel development excerpt.'
                       + '\nThis audio adaptation is offered under CC BY-SA 4.0: https://creativecommons.org/licenses/by-sa/4.0/')
    (args.output / 'ATTRIBUTION.txt').write_text('\n\n'.join(notices) + '\n')
    files = ['fixture.wav', 'fixture.srt', 'expected-timeline.json', 'ATTRIBUTION.txt']
    if args.video:
        duration = truth['expectedFrames'] / rate
        subprocess.run(['ffmpeg', '-v', 'error', '-n', '-f', 'lavfi', '-i',
                        f'color=c=0x10151e:s=1280x720:r=24:d={duration}', '-i', str(args.output / 'fixture.wav'),
                        '-map', '0:v', '-map', '1:a', '-c:v', 'ffv1', '-c:a', 'copy',
                        '-metadata:s:a:0', 'language=eng', '-t', str(duration), str(args.output / 'fixture.mkv')], check=True)
        files.append('fixture.mkv')
    record = {'sourceManifest': manifest, 'sourceManifestSha256': digest(manifest_path), 'case': args.case,
              'sampleCopies': copies, 'inferencePerformed': False, 'fullFilmDecoded': False,
              'expectedFrames': truth['expectedFrames'], 'durationSeconds': truth['expectedFrames'] / rate,
              'ffmpeg': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
              'files': {name: digest(args.output / name) for name in files}}
    (args.output / 'fixture-provenance.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'case': args.case, 'durationSeconds': record['durationSeconds'], 'files': record['files']}))


if __name__ == '__main__':
    main()
