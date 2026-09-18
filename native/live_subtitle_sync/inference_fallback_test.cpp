// Fault contracts use the real worker and pinned CPU decoder. Backend calls and
// one output timestamp are intercepted in this executable, never in a DLL.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "inference_fault_test_hooks.h"
#include "inference_worker.h"

using namespace std::chrono_literals;
namespace {
std::string scenario;
std::atomic<int> gpu_loads{0}, cpu_loads{0}, decode_calls{0};
std::atomic<bool> entered{false};
bool current_gpu = false;
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
template <class Predicate>
void wait_until(Predicate ready) {
  const auto deadline = std::chrono::steady_clock::now() + 60s;
  while (!ready()) {
    require(std::chrono::steady_clock::now() < deadline, "fault contract deadline exceeded");
    std::this_thread::sleep_for(2ms);
  }
}
}  // namespace

namespace livesync::fault_test {
whisper_context* initialize(const char* path, whisper_context_params options) {
  require(
      options.dtw_token_timestamps && !options.flash_attn && options.dtw_aheads_preset == WHISPER_AHEADS_BASE_EN &&
          options.dtw_mem_size == 128 * 1024 * 1024,
      "fallback changed alignment parameters");
  current_gpu = options.use_gpu;
  if (current_gpu) {
    ++gpu_loads;
    if (scenario == "load-null" || scenario == "cpu-load-fails") return nullptr;
    if (scenario == "load-throws") throw std::runtime_error("injected GPU initialization failure");
  } else {
    ++cpu_loads;
    if (scenario == "cpu-load-fails") return nullptr;
  }
  // The fault contracts simulate GPU failures on either CI architecture. The
  // real Metal profile is exercised separately with actual native PCM.
  options.use_gpu = false;
  return whisper_init_from_file_with_params(path, options);
}

int transcribe(whisper_context* context, whisper_full_params parameters, const float* samples, int count) {
  const int call = ++decode_calls;
  if ((current_gpu && scenario == "cancel" && call == 1) ||
      (!current_gpu && scenario == "fallback-cancel" && call == 2)) {
    entered.store(true);
    wait_until([&] { return parameters.abort_callback(parameters.abort_callback_user_data); });
    return -1;
  }
  if (current_gpu && (scenario == "decode-fails" || scenario == "decode-throws" || scenario == "cpu-decode-fails" ||
                      scenario == "fallback-cancel")) {
    std::this_thread::sleep_for(25ms);
    if (scenario == "decode-throws") throw std::runtime_error("injected GPU inference failure");
    return -1;
  }
  if (!current_gpu && scenario == "cpu-decode-fails") return -1;
  return whisper_full(context, parameters, samples, count);
}
int64_t segment_end(whisper_context* context, int index) {
  return scenario == "invalid-timestamps" ? -1 : whisper_full_get_segment_t1(context, index);
}
}  // namespace livesync::fault_test

int main(int argc, char** argv) {
  try {
#ifdef _WIN32
    require(_setmode(_fileno(stdin), _O_BINARY) != -1, "binary stdin unavailable");
#endif
    require(argc == 3, "expected model path and fault scenario; float32 fixture arrives on stdin");
    scenario = argv[2];
    require(
        scenario == "load-null" || scenario == "load-throws" || scenario == "decode-fails" ||
            scenario == "decode-throws" || scenario == "cpu-load-fails" || scenario == "cpu-decode-fails" ||
            scenario == "cancel" || scenario == "fallback-cancel" || scenario == "invalid-timestamps",
        "unknown fault scenario");
    std::vector<float> pcm(11 * 16000);
    std::cin.read(reinterpret_cast<char*>(pcm.data()), static_cast<std::streamsize>(pcm.size() * sizeof(float)));
    require(
        std::cin.gcount() == static_cast<std::streamsize>(pcm.size() * sizeof(float)),
        "expected exactly 11 seconds PCM");
    livesync::InferenceWorker worker(argv[1], 2);
    require(worker.backend() == livesync::InferenceBackend::metal_preferred, "test profile did not request GPU");
    worker.reset(1, 1);
    require(worker.submit({1, 1, 100, 1.0 / 16000, pcm}), "first window was not accepted");
    const bool cancelled = scenario == "cancel" || scenario == "fallback-cancel";
    if (cancelled) {
      wait_until([] { return entered.load(); });
      worker.reset(2, 2);
      wait_until([&] { return !worker.busy(); });
      require(!worker.take_result(), "cancelled GPU window published a result");
      require(cpu_loads == (scenario == "cancel" ? 0 : 1), "cancellation changed backend load count");
      require(worker.submit({2, 2, 200, 1.0 / 16000, pcm}), "post-seek window rejected");
    }
    wait_until([&] { return !worker.busy(); });
    auto result = worker.take_result();
    require(result.has_value(), "missing result");
    if (scenario == "cpu-load-fails") {
      require(
          result->status == livesync::InferenceStatus::model_unavailable && decode_calls == 0,
          "both load failures were not bounded and typed");
    } else if (scenario == "cpu-decode-fails") {
      require(
          result->status == livesync::InferenceStatus::inference_failed && decode_calls == 2,
          "CPU failure retried or was reported as success");
    } else if (scenario == "invalid-timestamps") {
      require(
          result->status == livesync::InferenceStatus::invalid_timestamps && decode_calls == 1,
          "malformed timestamps triggered a CPU retry");
    } else {
      require(
          result->status == livesync::InferenceStatus::success && !result->segments.empty(),
          "real CPU recovery failed");
      const uint64_t expected_generation = cancelled ? 2 : 1;
      require(
          result->generation == expected_generation && result->continuity == expected_generation,
          "recovery changed generation or continuity");
      const double origin = cancelled ? 200 : 100;
      require(
          result->segments.front().media_start >= origin && result->segments.back().media_end <= origin + 11.02,
          "recovery lost the PCM media timebase");
      if (scenario == "decode-fails" || scenario == "decode-throws") {
        require(result->elapsed_seconds >= 0.025, "elapsed time omitted failed GPU attempt");
      }
      if (!cancelled) {
        require(worker.submit({1, 1, 300, 1.0 / 16000, pcm}), "second CPU window rejected");
        wait_until([&] { return !worker.busy(); });
        result = worker.take_result();
        require(result && result->status == livesync::InferenceStatus::success, "sticky CPU recovery failed");
      }
    }
    const bool kept_gpu = scenario == "cancel" || scenario == "invalid-timestamps";
    require(gpu_loads == 1 && cpu_loads == (kept_gpu ? 0 : 1), "backend was retried more than once");
    require(
        worker.backend() ==
            (kept_gpu ? livesync::InferenceBackend::metal_preferred : livesync::InferenceBackend::cpu_fallback),
        "reported backend preference is incorrect");
    worker.stop();
    std::cout << "{\"scenario\":\"" << scenario << "\",\"passed\":true,\"gpuLoadAttempts\":" << gpu_loads
              << ",\"cpuLoadAttempts\":" << cpu_loads << ",\"decodeCalls\":" << decode_calls << "}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
