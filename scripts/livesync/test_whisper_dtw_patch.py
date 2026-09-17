"""Test offline patch contracts, or the pinned source supplied by CMake."""

import argparse
import hashlib
import tempfile
from pathlib import Path
from unittest.mock import patch

import patch_whisper_dtw

from patch_whisper_dtw import GUARD, MARKER, SOURCE_SHA256, generate


def check(source: Path, expected_sha: str = SOURCE_SHA256):
    original = source.read_bytes()
    canonical = original.replace(b"\r\n", b"\n")
    assert hashlib.sha256(canonical).hexdigest() == expected_sha
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        output = root / "generated" / "whisper.cpp"
        generate(source, output)
        patched = output.read_bytes()
        assert patched.replace(GUARD.encode(), MARKER.encode()) == canonical
        before = output.stat().st_mtime_ns
        generate(source, output)
        assert output.stat().st_mtime_ns == before
        windows_source = root / "windows.cpp"
        windows_source.write_bytes(canonical.replace(b"\n", b"\r\n"))
        generate(windows_source, output)
        assert output.read_bytes() == patched
        for altered in (original + b"\n", patched):
            changed = root / "changed.cpp"
            changed.write_bytes(altered)
            try:
                generate(changed, output)
            except ValueError:
                pass
            else:
                raise AssertionError("Changed source was accepted")
            assert output.read_bytes() == patched
        try:
            generate(source, source)
        except ValueError:
            pass
        else:
            raise AssertionError("In-place modification was accepted")
    assert source.read_bytes() == original


def check_offline():
    # The generic script roster has no native checkout. Exercise file-safety
    # and idempotence with a synthetic source; CTest still supplies --source
    # to verify the actual pinned Whisper implementation without mocking it.
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary) / "synthetic.cpp"
        source.write_text("// synthetic fixture\n" + MARKER + "}\n", encoding="utf-8")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        with patch.object(patch_whisper_dtw, "SOURCE_SHA256", digest):
            check(source, digest)
        try:
            generate(source, source.with_name("output.cpp"))
        except ValueError:
            pass
        else:
            raise AssertionError("Synthetic source passed the real upstream pin")
    print("Offline DTW patch file-safety, idempotence and checksum contracts passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    source = parser.parse_args().source
    if source is None:
        check_offline()
    else:
        check(source)
        print("Pinned DTW patch, idempotence, source-drift rejection and pristine checkout passed")
