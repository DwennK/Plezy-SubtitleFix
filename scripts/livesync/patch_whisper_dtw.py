#!/usr/bin/env python3
"""Generate a reviewed DTW guard without modifying the pinned Whisper checkout."""

import argparse
import hashlib
from pathlib import Path


SOURCE_SHA256 = "c48686fbc2cba1b0ac0f9c8e964188c691e67fff5906f2629f3223ff64f92d16"
MARKER = """{
    const int n_audio_ctx = state->exp_n_audio_ctx > 0 ? state->exp_n_audio_ctx : ctx->model.hparams.n_audio_ctx;
    WHISPER_ASSERT(medfilt_width % 2);
"""
GUARD = """{
    // LiveSync: a decoded tail can be shorter than the DTW median filter,
    // even when the submitted PCM window is long. Its audio-token axis must
    // be strictly wider than the filter. Keep recognition, but no timing
    // evidence, instead of aborting the process or padding invented audio.
    if (n_frames / 2 <= medfilt_width) {
        for (size_t i = i_segment; i < i_segment + n_segments; ++i) {
            for (auto & token : state->result_all[i].tokens) {
                token.t_dtw = -1;
            }
        }
        return;
    }
    const int n_audio_ctx = state->exp_n_audio_ctx > 0 ? state->exp_n_audio_ctx : ctx->model.hparams.n_audio_ctx;
    WHISPER_ASSERT(medfilt_width % 2);
"""


def generate(source: Path, output: Path):
    # Git for Windows can materialize CRLF even at the exact reviewed revision.
    # Normalize only that checkout conversion before validating source content.
    raw = source.read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError("Whisper DTW source changed; review the guard for the new pin")
    text = raw.decode("utf-8")
    if text.count(MARKER) != 1:
        raise ValueError("Expected exactly one pinned DTW implementation")
    patched = text.replace(MARKER, GUARD).encode("utf-8")
    if source.resolve() == output.resolve():
        raise ValueError("Never patch the source checkout in place")
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_bytes() != patched:
        output.write_bytes(patched)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    generate(args.source, args.output)
