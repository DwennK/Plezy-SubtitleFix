#!/usr/bin/env python3
"""Exercise local/authenticated HTTP SRT access and reversible native timing.

Uses the real libmpv subtitle decoder's sub-text output with null audio/video.
This proves timing selection, not visible pixels or Plex/Jellyfin integration.
All data is generated locally; the HTTP server binds only to loopback.
"""

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
import urllib.request

from probe_pcm import Player, create_fixture

SRT = b"1\n00:00:01,000 --> 00:00:02,000\nFIRST PROBE CUE\n\n2\n00:00:04,000 --> 00:00:05,000\nSECOND PROBE CUE\n"
HEADER = "Bearer local-synthetic-fixture"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/fixture.srt" or self.headers.get("Authorization") != HEADER:
            self.send_error(403)
            return
        self.server.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/x-subrip")
        self.send_header("Content-Length", str(len(SRT)))
        self.end_headers()
        self.wfile.write(SRT)

    def log_message(self, *args):
        pass


def wait_for(function, expected, timeout=5):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = function()
            if last == expected:
                return
        except RuntimeError:
            pass
        time.sleep(0.02)
    raise AssertionError(f"Expected {expected!r}, received {last!r}")


def check_source(library, media, source):
    player = Player(library)
    try:
        player.set("http-header-fields", "Authorization: " + HEADER)
        player.command("loadfile", media)
        wait_for(lambda: player.get("audio-codec-name"), "pcm_s16le")
        player.set("pause", "yes")
        player.command("sub-add", source, "select")
        player.command("seek", "1.5", "absolute+exact")
        wait_for(lambda: player.get("sub-text"), "FIRST PROBE CUE")
        selected = [t for t in player.get("track-list") if t["type"] == "sub" and t["selected"]]
        assert len(selected) == 1 and selected[0]["external-filename"] == source
        # Positive delay moves the cue later. Removing only the automatic 2 s
        # must restore the pre-existing manual 0.125 s and the same source.
        player.set("sub-delay", 0.125)
        wait_for(lambda: player.get("sub-text"), "FIRST PROBE CUE")
        player.set("sub-delay", 2.125)
        wait_for(lambda: player.get("sub-text"), "")
        player.set("sub-delay", 0.125)
        wait_for(lambda: player.get("sub-text"), "FIRST PROBE CUE")
        assert abs(player.get("sub-delay") - 0.125) < 1e-9
        # Negative delay selects the later cue at the same media position.
        player.set("sub-delay", -3)
        wait_for(lambda: player.get("sub-text"), "SECOND PROBE CUE")
        player.set("sub-delay", 0.125)
        wait_for(lambda: player.get("sub-text"), "FIRST PROBE CUE")
        return {"completeSrtAccessible": True, "sourceIdentityPreserved": True,
                "positiveAndNegativeDelay": "passed", "manualDelayRestored": 0.125,
                "nativeDecoderSelection": "passed", "visiblePixelsValidated": False}
    finally:
        player.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    media = args.output / "synthetic-317-691hz.wav"
    local = args.output / "fixture.srt"
    create_fixture(media)
    local.write_bytes(SRT)
    original = hashlib.sha256(SRT).hexdigest()
    report = {"kind": "real-native-subtitle-decoder-null-output",
              "local": check_source(args.library, str(media.resolve()), str(local.resolve()))}
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.requests = 0
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_port}/fixture.srt"
        request = urllib.request.Request(url, headers={"Authorization": HEADER})
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.read() == SRT
        report["authenticatedHttp"] = check_source(args.library, str(media.resolve()), url)
        assert server.requests >= 2, "Expected complete-text retrieval and native subtitle loading"
        report["httpRequests"] = server.requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    assert hashlib.sha256(local.read_bytes()).hexdigest() == original, "Source SRT was modified"
    report["sourceHashUnchanged"] = original
    (args.output / "subtitle-probe.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Local/HTTP SRT and reversible decoder timing passed; visible renderer and server clients remain untested.")


if __name__ == "__main__":
    main()
