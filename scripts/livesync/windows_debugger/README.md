# Windows renderer exception observer

Opt in with `debug_renderer=true` in the Windows application workflow, normally
with `renderer_only=true`. The existing renderer driver retains its viewport,
state acknowledgments and failure conditions. This standalone executable is not
linked into or included in the preserved application artifact.

Windows may terminate a window callback with `0xc000041d` without producing a WER
record on the hosted runner. Start the synthetic renderer under the Windows debug
API to record first/second-chance exceptions before that final termination. Log
only exception codes, thread IDs, instruction/module offsets, access-violation
metadata, module basenames and process exit. No target memory reads, dumps,
transcripts or PCM. The public synthetic fixture is the only intended target.

Only the initial loader breakpoint is consumed. All later exceptions continue as
`DBG_EXCEPTION_NOT_HANDLED`, allowing the application's own handlers or normal
termination to run. The debugger exits nonzero for a nonzero target exit. Bound
observation to ten minutes and 4096 exceptions, and kill the child when the
observer exits. The driver also checks a successful capture's debugger exit.

Before the renderer build, native contracts check a handled first-chance
exception, an unhandled access violation (including second chance and nonzero
exit), timeout cleanup, and missing executable. Compile and execute these on
Windows; local macOS lint does not validate the Win32 implementation.

A debugger changes scheduling and `IsDebuggerPresent`. A passing observed run
cannot establish that the intermittent startup bug is fixed. Preserve the earlier
failed run and require an explained fix plus uninstrumented validation.

API semantics: [debugger exception handling](https://learn.microsoft.com/en-us/windows/win32/debug/debugger-exception-handling),
[ContinueDebugEvent](https://learn.microsoft.com/en-us/windows/win32/api/debugapi/nf-debugapi-continuedebugevent).
