#!/usr/bin/env python3
"""Evaluate VAD support for recorded anchors on consumed public fixtures only.

This offline experiment never changes mappings or parses private media URLs.
Window PCM is temporary and removed after each observation.
"""
import argparse
import hashlib
import json
import math
import re
import subprocess
import tempfile
import time
import wave
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def speech_intervals(text, duration):
    count = re.search(r'^Detected (\d+) speech segments:$', text, re.M)
    rows = re.findall(r'^Speech segment (\d+): start = ([\d.]+), end = ([\d.]+)$', text, re.M)
    if count is None or int(count[1]) != len(rows):
        raise ValueError('Missing or incomplete VAD output')
    intervals = []
    for expected, (ordinal, start, end) in enumerate(rows):
        start, end = float(start) / 100, float(end) / 100
        # The pinned VAD derives audio_length_samples from whole 512-sample
        # probability frames, then rounds to centiseconds. Clamp this final
        # padded frame to the actual input; it is not observed extra audio.
        padded_end = math.ceil(duration * 16000 / 512) * 512 / 16000 + 0.005
        if int(ordinal) != expected or not 0 <= start < end <= padded_end:
            raise ValueError(f'Invalid VAD interval {ordinal}: {start}..{end}; duration {duration}')
        end = min(end, duration)
        if start >= end:
            continue
        if intervals and start < intervals[-1][1]:
            raise ValueError('Overlapping VAD intervals')
        intervals.append([start, end])
    return intervals


def distance_to_voice(point, intervals):
    if not intervals:
        return None
    return min(max(start - point, point - end, 0) for start, end in intervals)


def cue_starts(srt):
    stamps = re.findall(r'(?m)^\d+\s*\n(\d+):([0-5]\d):([0-5]\d),(\d{3}) --> ', srt)
    if not stamps:
        raise ValueError('No SRT cue starts')
    return [int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000 for h, m, s, ms in stamps]


def evaluate(args):
    probe = json.loads(args.probe.read_text())
    starts = cue_starts(args.srt.read_text(encoding='utf-8-sig'))
    observations = []
    for analysis in probe['analyses']:
        beginning, end = analysis['windowStart'], analysis['windowEnd']
        duration = end - beginning
        if not all(math.isfinite(v) for v in (beginning, end)) or beginning < 0 or not 7.99 <= duration <= 15.01:
            raise ValueError('Only bounded recorded windows are permitted')
        first_sample, last_sample = round(beginning * 16000), round(end * 16000)
        sample_origin = first_sample / 16000
        with tempfile.TemporaryDirectory(prefix='livesync-public-vad-') as directory:
            audio = Path(directory) / 'window.wav'
            # A container seek dropped 65 ms from the short retry. This offline
            # public-fixture replay trims decoded sample indices instead. It
            # does not add a second decode or network stream to production.
            trim = (f'aformat=sample_rates=16000:channel_layouts=mono,'
                    f'atrim=start_sample={first_sample}:end_sample={last_sample},asetpts=PTS-STARTPTS')
            subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-i', str(args.fixture),
                            '-vn', '-af', trim, '-c:a', 'pcm_s16le', str(audio)],
                           check=True, timeout=30)
            with wave.open(str(audio)) as pcm:
                actual_duration = pcm.getnframes() / pcm.getframerate()
                if (pcm.getnchannels() != 1 or pcm.getframerate() != 16000
                        or pcm.getnframes() != last_sample - first_sample):
                    raise ValueError('Incorrect decoded window')
            started = time.monotonic()
            completed = subprocess.run([str(args.binary), '-vm', str(args.model), '-f', str(audio), '-t', '2',
                                        '-vt', '0.5', '-vspd', '250', '-vsd', '100', '-vp', '30', '-np'],
                                       check=True, capture_output=True, text=True, timeout=30)
            elapsed = time.monotonic() - started
            intervals = speech_intervals(completed.stdout, actual_duration)
            media_intervals = [[sample_origin + a, sample_origin + b] for a, b in intervals]
            anchors = []
            for anchor in analysis['anchors']:
                media_time = starts[anchor['cue']] + anchor['offset']
                inside = beginning <= media_time < end
                distance = distance_to_voice(media_time, media_intervals) if inside else None
                anchors.append({**anchor, 'mediaTime': media_time, 'insideCurrentWindow': inside,
                                'distanceToVoiceSeconds': distance,
                                'voiceWithinExistingUncertainty': inside and distance is not None and distance <= 0.35})
            observations.append({'attempt': analysis['attempt'], 'windowStart': beginning, 'windowEnd': end,
                                 'decodedSampleOrigin': sample_origin, 'decodedSamples': last_sample - first_sample,
                                 'windowWavSha256': digest(audio), 'speechIntervals': media_intervals,
                                 'elapsedSecondsIncludingModelLoad': elapsed, 'anchors': anchors})
    return {'schema': 1, 'scope': 'offline VAD on recorded public development windows, not native player validation',
            'whisperRevision': '927cfce34f31707e17f2bff35c349632fb9e2c3a',
            'parameters': {'threads': 2, 'backend': 'cpu', 'threshold': 0.5, 'minimumSpeechMs': 250,
                           'minimumSilenceMs': 100, 'paddingMs': 30, 'existingAnchorUncertaintySeconds': 0.35},
            'hashes': {key: digest(getattr(args, key)) for key in ('probe', 'fixture', 'srt', 'binary', 'model')},
            'observations': observations, 'pcmPersisted': False, 'transcriptPersisted': False,
            'limitation': 'Independent FFmpeg window re-decode, not a retained copy of the original mpv PCM. '
                          'VAD membership is not precise acoustic-onset truth and never grants a text match.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('probe', 'fixture', 'srt', 'binary', 'model', 'output'):
        parser.add_argument(f'--{key}', type=Path, required=True)
    args = parser.parse_args()
    result = evaluate(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
