#pragma once

// Test-only instrumentation. The normal runner does not include this header.
// Record bounded exception/stack metadata, never memory contents or media.
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace livesync_diagnostic {
inline HANDLE log_file = INVALID_HANDLE_VALUE;
inline volatile LONG recording = 0;
inline volatile LONG exception_count = 0;

inline void Write(const char* data, DWORD size) {
  DWORD written = 0;
  WriteFile(log_file, data, size, &written, nullptr);
}

// VirtualQuery obtains allocation metadata, not target memory contents. The
// module basename and relative PC make ASLR addresses usable after the process
// exits. Stack walking is best effort; the fault instruction is separate.
inline int Address(char* output, size_t capacity, const void* pc) {
  MEMORY_BASIC_INFORMATION region{};
  const auto address = reinterpret_cast<uintptr_t>(pc);
  const auto base = VirtualQuery(pc, &region, sizeof(region)) ? reinterpret_cast<uintptr_t>(region.AllocationBase) : 0;
  wchar_t path[512]{};
  const DWORD length = base ? GetModuleFileNameW(reinterpret_cast<HMODULE>(base), path, 512) : 0;
  char name[128] = "unknown";
  if (length > 0 && length < 512) {
    size_t start = 0;
    for (DWORD i = 0; i < length; ++i) {
      if (path[i] == L'\\' || path[i] == L'/') start = i + 1;
    }
    size_t n = 0;
    for (size_t i = start; i < length && n + 1 < sizeof(name); ++i) {
      // Keep valid JSON without allocating in an exception callback.
      const wchar_t c = path[i];
      name[n++] = c >= 32 && c < 127 && c != L'"' && c != L'\\' ? static_cast<char>(c) : '?';
    }
    name[n] = 0;
  }
  return _snprintf_s(
      output, capacity, _TRUNCATE, "{\"pc\":\"0x%llx\",\"module\":\"%s\",\"offset\":\"0x%llx\"}",
      static_cast<unsigned long long>(address), name, static_cast<unsigned long long>(base ? address - base : 0));
}

// Keep the large buffer out of Observe's entry frame so stack-overflow
// notifications can be skipped before allocating it.
__declspec(noinline) inline void Record(EXCEPTION_POINTERS* pointers) {
  const DWORD code = pointers->ExceptionRecord->ExceptionCode;
  const LONG sequence = InterlockedIncrement(&exception_count);
  if (sequence <= 32) {
    char buffer[8192];
    int size = _snprintf_s(
        buffer, sizeof(buffer), _TRUNCATE,
        "{\"event\":\"first-chance\",\"sequence\":%ld,\"code\":\"0x%lx\",\"thread\":%lu,\"fault\":", sequence, code,
        GetCurrentThreadId());
    int added =
        size > 0 ? Address(buffer + size, sizeof(buffer) - size, pointers->ExceptionRecord->ExceptionAddress) : -1;
    if (added > 0) size += added;
    bool valid = size > 0 && added > 0;
    if (valid) {
      added = _snprintf_s(buffer + size, sizeof(buffer) - size, _TRUNCATE, ",\"handlerStack\":[");
      valid = added > 0;
      if (valid) size += added;
    }
    void* stack[24]{};
    const USHORT frames = valid ? CaptureStackBackTrace(0, 24, stack, nullptr) : 0;
    for (USHORT i = 0; valid && i < frames; ++i) {
      if (static_cast<size_t>(size) + 2 >= sizeof(buffer)) {
        valid = false;
        break;
      }
      if (i > 0) buffer[size++] = ',';
      added = Address(buffer + size, sizeof(buffer) - size, stack[i]);
      valid = added > 0;
      if (valid) size += added;
    }
    if (valid && static_cast<size_t>(size) + 4 < sizeof(buffer)) {
      buffer[size++] = ']';
      buffer[size++] = '}';
      buffer[size++] = '\n';
      Write(buffer, static_cast<DWORD>(size));
    }
  }
}

inline LONG CALLBACK Observe(EXCEPTION_POINTERS* pointers) {
  const DWORD code = pointers->ExceptionRecord->ExceptionCode;
  // Debugger/thread-name and guard-page notifications are not crash evidence.
  // A stack overflow cannot safely use the bounded stack buffer below.
  if (code == EXCEPTION_BREAKPOINT || code == EXCEPTION_SINGLE_STEP || code == EXCEPTION_GUARD_PAGE ||
      code == EXCEPTION_STACK_OVERFLOW || code == 0x406d1388 || log_file == INVALID_HANDLE_VALUE ||
      InterlockedCompareExchange(&recording, 1, 0) != 0) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  __try {
    Record(pointers);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    // A fault in best-effort stack/module lookup must not replace the original
    // application exception. Recursive observation is blocked by recording.
    constexpr char failed[] = "{\"event\":\"observer-failed\"}\n";
    Write(failed, sizeof(failed) - 1);
  }
  InterlockedExchange(&recording, 0);
  // Observation must never swallow the original exception or change registers.
  return EXCEPTION_CONTINUE_SEARCH;
}

inline bool Install() {
  wchar_t path[4096]{};
  const DWORD length = GetEnvironmentVariableW(L"LIVESYNC_RENDERER_EXCEPTION_LOG", path, 4096);
  if (length == 0) return true;
  if (length >= 4096) return false;
  log_file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log_file == INVALID_HANDLE_VALUE) return false;
  if (!AddVectoredExceptionHandler(1, Observe)) {
    CloseHandle(log_file);
    log_file = INVALID_HANDLE_VALUE;
    return false;
  }
  const char* installed = IsDebuggerPresent() ? "{\"event\":\"installed\",\"debuggerPresent\":true}\n"
                                              : "{\"event\":\"installed\",\"debuggerPresent\":false}\n";
  Write(installed, static_cast<DWORD>(std::strlen(installed)));
  // Owned for process lifetime; normal builds have no observer or file handle.
  return true;
}
}  // namespace livesync_diagnostic
