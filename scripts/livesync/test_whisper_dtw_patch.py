"""Exercise the patch against the actual pinned source supplied by CMake."""

import argparse
import hashlib
import tempfile
from pathlib import Path

from patch_whisper_dtw import GUARD, MARKER, SOURCE_SHA256, generate


def check(source: Path):
    original = source.read_bytes()
    canonical = original.replace(b"\r\n", b"\n")
    assert hashlib.sha256(canonical).hexdigest() == SOURCE_SHA256
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
    print("Pinned DTW patch, idempotence, source-drift rejection and pristine checkout passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    check(parser.parse_args().source)
