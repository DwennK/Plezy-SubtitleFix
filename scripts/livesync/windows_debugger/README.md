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

## Observe without a debugger

`observe_renderer_faults=true` enables a separate, test-only native runner
option for the synthetic harness. Its vectored exception observer records at
most 32 first-chance notifications with a fault PC and up to 24 handler-stack
PCs, resolved to module basenames and offsets. It returns
`EXCEPTION_CONTINUE_SEARCH`; handled application exceptions remain handled and
fatal exceptions remain fatal. Native contracts verify both behaviors without
an attached debugger, including the stack's presence and failed log startup.

This observer is best effort. It skips debugger/thread-name, guard-page and
stack-overflow notifications, plus recursive or concurrent observations. Stack
lookup faults are locally contained so they do not replace the original
exception. Instrumentation can still affect scheduling; a passing run is not a
crash fix. No stack memory, registers, dump, media or transcript is written.

The CMake option defaults off. The workflow preserves the normal application
before enabling it, sets the log path only for the owned renderer process, and
turns the option off in `finally` before a later controller rebuild. It records
hashes of the observed executable, Flutter DLL and mpv DLL. The observer and the
external debugger modes are mutually exclusive.
