// Disposable synthetic-fixture diagnostic, never linked into the application.
// Record exception metadata without reading target memory or creating dumps.
#include <windows.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

static std::string Hex(uintptr_t value) {
  std::ostringstream out;
  out << "\"0x" << std::hex << value << "\"";
  return out.str();
}

static std::string ModuleName(HANDLE file) {
  wchar_t path[32768];
  const DWORD size = GetFinalPathNameByHandleW(file, path, 32768, FILE_NAME_NORMALIZED);
  if (size == 0 || size >= 32768) return "unknown";
  const std::wstring name = std::filesystem::path(path).filename().wstring();
  std::string result;
  for (const wchar_t c : name) {
    if (c == L'"' || c == L'\\') result += '\\';
    result += c >= 32 && c < 127 ? static_cast<char>(c) : '?';
  }
  return result;
}

// Kept outside C++ scopes with destructors for MSVC's SEH restriction.
static int FaultFixture(const wchar_t* mode) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  if (wcscmp(mode, L"--fixture-handled") == 0) {
    __try {
      RaiseException(0xe0421001, 0, 0, nullptr);
    } __except (GetExceptionCode() == 0xe0421001 ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
      return 0;
    }
    return 9;
  }
  if (wcscmp(mode, L"--fixture-crash") == 0) {
    const ULONG_PTR info[] = {1, 0};
    RaiseException(EXCEPTION_ACCESS_VIOLATION, EXCEPTION_NONCONTINUABLE, 2, info);
    return 9;
  }
  if (wcscmp(mode, L"--fixture-hang") == 0) {
    Sleep(INFINITE);
    return 9;
  }
  return 2;
}

int wmain(int argc, wchar_t** argv) {
  if (argc == 2) return FaultFixture(argv[1]);
  // output-directory executable [self-test-mode]; the renderer has no arguments.
  if (argc < 3 || argc > 4) return 2;
  const std::filesystem::path output(argv[1]);
  std::ofstream log(output / L"debug-events.jsonl", std::ios::out | std::ios::trunc);
  if (!log) return 2;
  const auto record = [&log](const std::string& fields) {
    log << '{' << fields << "}\n";
    log.flush();
  };
  std::wstring command = L"\"" + std::wstring(argv[2]) + L"\"";
  if (argc == 4) {
    if (wcscmp(argv[3], L"--fixture-handled") != 0 && wcscmp(argv[3], L"--fixture-crash") != 0 &&
        wcscmp(argv[3], L"--fixture-hang") != 0)
      return 2;
    command += L" " + std::wstring(argv[3]);
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  PROCESS_INFORMATION process{};
  const auto directory = std::filesystem::path(argv[2]).parent_path().wstring();
  if (!CreateProcessW(
          argv[2], command.data(), nullptr, nullptr, TRUE, DEBUG_ONLY_THIS_PROCESS, nullptr, directory.c_str(),
          &startup, &process)) {
    record("\"event\":\"create-failed\",\"win32Error\":" + std::to_string(GetLastError()));
    return 2;
  }
  // Default Windows behavior already kills a debuggee when its debugger exits.
  // Keep this explicit so the driver's cleanup cannot leave a fixture running.
  if (!DebugSetProcessKillOnExit(TRUE)) {
    record("\"event\":\"configuration-failed\",\"win32Error\":" + std::to_string(GetLastError()));
    return 2;
  }
  {
    std::ofstream pid(output / L"debuggee.pid.tmp", std::ios::out | std::ios::trunc);
    pid << process.dwProcessId << '\n';
    if (!pid) return 2;
  }
  if (!MoveFileExW(
          (output / L"debuggee.pid.tmp").c_str(), (output / L"debuggee.pid").c_str(),
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    record("\"event\":\"pid-publish-failed\",\"win32Error\":" + std::to_string(GetLastError()));
    return 2;
  }
  CloseHandle(process.hThread);
  record("\"event\":\"started\",\"pid\":" + std::to_string(process.dwProcessId));
  const ULONGLONG deadline =
      GetTickCount64() + ((argc == 4 && wcscmp(argv[3], L"--fixture-hang") == 0) ? 3000 : 600000);
  std::map<uintptr_t, std::string> modules;
  bool loaderBreakpointSeen = false;
  size_t exceptionCount = 0;
  for (;;) {
    if (GetTickCount64() >= deadline) {
      record("\"event\":\"timeout\"");
      TerminateProcess(process.hProcess, 124);
      CloseHandle(process.hProcess);
      return 124;
    }
    DEBUG_EVENT event{};
    if (!WaitForDebugEventEx(&event, 200)) {
      const DWORD error = GetLastError();
      if (error == ERROR_SEM_TIMEOUT) continue;
      record("\"event\":\"wait-failed\",\"win32Error\":" + std::to_string(error));
      return 2;
    }
    DWORD status = DBG_CONTINUE;
    switch (event.dwDebugEventCode) {
      case CREATE_PROCESS_DEBUG_EVENT:
      case LOAD_DLL_DEBUG_EVENT: {
        const bool main = event.dwDebugEventCode == CREATE_PROCESS_DEBUG_EVENT;
        const HANDLE file = main ? event.u.CreateProcessInfo.hFile : event.u.LoadDll.hFile;
        const auto base =
            reinterpret_cast<uintptr_t>(main ? event.u.CreateProcessInfo.lpBaseOfImage : event.u.LoadDll.lpBaseOfDll);
        const std::string name = file ? ModuleName(file) : "unknown";
        modules[base] = name;
        record("\"event\":\"module\",\"base\":" + Hex(base) + ",\"module\":\"" + name + "\"");
        if (file) CloseHandle(file);
        // Windows closes debug-event process/thread handles on their exit events.
        break;
      }
      case UNLOAD_DLL_DEBUG_EVENT:
        modules.erase(reinterpret_cast<uintptr_t>(event.u.UnloadDll.lpBaseOfDll));
        break;
      case EXCEPTION_DEBUG_EVENT: {
        const auto& exception = event.u.Exception.ExceptionRecord;
        const bool first = event.u.Exception.dwFirstChance != 0;
        const bool loader = !loaderBreakpointSeen && first && exception.ExceptionCode == EXCEPTION_BREAKPOINT;
        if (loader) loaderBreakpointSeen = true;
        // Only the initial debugger breakpoint is consumed. All application
        // exceptions retain Windows' first/second-chance dispatch and failure.
        status = loader ? DBG_CONTINUE : DBG_EXCEPTION_NOT_HANDLED;
        MEMORY_BASIC_INFORMATION region{};
        const auto address = reinterpret_cast<uintptr_t>(exception.ExceptionAddress);
        const SIZE_T queried = VirtualQueryEx(process.hProcess, exception.ExceptionAddress, &region, sizeof(region));
        const auto base = queried ? reinterpret_cast<uintptr_t>(region.AllocationBase) : 0;
        const auto module = modules.find(base);
        std::string fields = "\"event\":\"exception\",\"code\":" + Hex(exception.ExceptionCode) +
                             ",\"firstChance\":" + (first ? "true" : "false") +
                             ",\"loaderBreakpoint\":" + (loader ? "true" : "false") +
                             ",\"thread\":" + std::to_string(event.dwThreadId) + ",\"address\":" + Hex(address) +
                             ",\"module\":\"" + (module == modules.end() ? "unknown" : module->second) +
                             "\",\"moduleOffset\":" + (module == modules.end() ? "null" : Hex(address - base));
        if (exception.ExceptionCode == EXCEPTION_ACCESS_VIOLATION && exception.NumberParameters >= 2) {
          fields += ",\"accessOperation\":" + std::to_string(exception.ExceptionInformation[0]) +
                    ",\"accessAddress\":" + Hex(exception.ExceptionInformation[1]);
        }
        record(fields);
        if (++exceptionCount > 4096) {
          record("\"event\":\"exception-limit\"");
          TerminateProcess(process.hProcess, 125);
          return 125;
        }
        break;
      }
      default:
        break;
    }
    const bool exited = event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT;
    if (exited) record("\"event\":\"exit\",\"code\":" + Hex(event.u.ExitProcess.dwExitCode));
    if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId, status)) {
      record("\"event\":\"continue-failed\",\"win32Error\":" + std::to_string(GetLastError()));
      return 2;
    }
    if (exited) {
      CloseHandle(process.hProcess);
      return event.u.ExitProcess.dwExitCode == 0 ? 0 : 1;
    }
  }
}
