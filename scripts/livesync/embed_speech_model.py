#!/usr/bin/env python3
"""Embed only the pinned, checksum-verified speech detector in a native build."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def embed(model, output):
    expected = json.loads((ROOT / 'docs/live-subtitle-sync-versions.json').read_text())['speechDetector']
    if model.stat().st_size != expected['bytes']:
        raise ValueError('Unexpected speech model size')
    data = model.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected['sha256']:
        raise ValueError('Unexpected speech model checksum')
    rows = [', '.join(f'0x{value:02x}' for value in data[i:i + 16]) for i in range(0, len(data), 16)]
    content = '// Generated from the verified Silero model; see SILERO-LICENSE.\n'
    content += 'static const unsigned char kSpeechModelBytes[] = {\n' + ',\n'.join(rows) + '\n};\n'
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_text() != content:
        output.write_text(content)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    embed(args.model, args.output)
