"""Native contracts for the disposable Windows exception observer."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

exe = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="livesync-debugger-") as temporary:
    root = Path(temporary)
    reports = []
    for mode in ("handled", "crash", "hang"):
        output = root / mode
        output.mkdir()
        process = subprocess.run(
            [str(exe), str(output), str(exe), f"--fixture-{mode}"], timeout=20,
            capture_output=True,
        )
        events = [json.loads(line) for line in (output / "debug-events.jsonl").read_text().splitlines()]
        assert int((output / "debuggee.pid").read_text()) > 0
        exceptions = [e for e in events if e["event"] == "exception" and not e["loaderBreakpoint"]]
        if mode == "handled":
            assert process.returncode == 0, events
            raised = [e for e in exceptions if e["code"] == "0xe0421001"]
            assert len(raised) == 1 and raised[0]["firstChance"], events
            assert events[-1] == {"event": "exit", "code": "0x0"}, events
        elif mode == "crash":
            assert process.returncode == 1, events
            raised = [e for e in exceptions if e["code"] == "0xc0000005"]
            assert [e["firstChance"] for e in raised] == [True, False], events
            assert all(e["module"] != "unknown" and e["moduleOffset"] is not None for e in raised), events
            assert all(e["accessOperation"] == 1 and e["accessAddress"] == "0x0" for e in raised), events
            assert events[-1] == {"event": "exit", "code": "0xc0000005"}, events
        else:
            assert process.returncode == 124 and events[-1]["event"] == "timeout", events
            # The diagnostic must not leave its hung child running.
            import ctypes
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
            kernel.OpenProcess.restype = ctypes.c_void_p
            kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            handle = kernel.OpenProcess(0x00100000, False, int((output / "debuggee.pid").read_text()))
            if handle:
                try:
                    assert kernel.WaitForSingleObject(handle, 5000) == 0
                finally:
                    kernel.CloseHandle(handle)
        reports.append({"case": mode, "passed": True, "observerExitCode": process.returncode})
    # Failed startup must produce a diagnostic error, not a successful empty log.
    missing = root / "missing"
    missing.mkdir()
    result = subprocess.run([str(exe), str(missing), str(root / "absent.exe")], timeout=10)
    assert result.returncode == 2
    events = [json.loads(line) for line in (missing / "debug-events.jsonl").read_text().splitlines()]
    assert events[0]["event"] == "create-failed"
    reports.append({"case": "missing-executable", "passed": True})
    print(json.dumps({"passed": True, "cases": reports}, indent=2))
