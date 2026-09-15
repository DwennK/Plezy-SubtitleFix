#include "inference_worker.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <thread>

using namespace std::chrono_literals;
using livesync::InferenceStatus;
using livesync::InferenceWorker;

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

template <typename Predicate>
void wait_until(Predicate predicate) {
  const auto deadline = std::chrono::steady_clock::now() + 30s;
  while (!predicate()) {
    require(std::chrono::steady_clock::now() < deadline, "native worker deadline exceeded");
    std::this_thread::sleep_for(2ms);
  }
}

livesync::InferenceResult check_result(
    InferenceWorker& worker, uint64_t generation, uint64_t continuity, double origin, double scale) {
  wait_until([&] { return !worker.busy(); });
  auto result = worker.take_result();
  require(result.has_value() && result->status == InferenceStatus::success, "actual CPU inference failed");
  require(result->generation == generation && result->continuity == continuity, "stale result escaped");
  require(!result->segments.empty(), "empty reference transcript");
  std::string transcript;
  int timed_tokens = 0;
  for (const auto& segment : result->segments) {
    require(
        segment.media_start >= origin && segment.media_end <= origin + 11 * scale + 0.03,
        "segment did not retain the media clock");
    transcript += segment.text;
    for (const auto& token : segment.tokens) {
      if (token.has_timestamp) {
        ++timed_tokens;
        require(
            token.media_start >= origin && token.media_end <= origin + 11 * scale + 0.03,
            "token did not retain the media clock");
      }
    }
  }
  auto words = [](std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
      return static_cast<char>(std::isalpha(c) ? std::tolower(c) : ' ');
    });
    std::vector<std::string> result;
    std::istringstream stream(text);
    std::string word;
    while (stream >> word) result.push_back(word);
    return result;
  };
  const auto expected =
      words("and so my fellow americans ask not what your country can do for you ask what you can do for your country");
  const auto actual = words(transcript);
  std::vector<size_t> previous(actual.size() + 1);
  std::iota(previous.begin(), previous.end(), size_t{0});
  for (size_t i = 1; i <= expected.size(); ++i) {
    std::vector<size_t> row(actual.size() + 1);
    row[0] = i;
    for (size_t j = 1; j <= actual.size(); ++j)
      row[j] = std::min({row[j - 1] + 1, previous[j] + 1, previous[j - 1] + (expected[i - 1] != actual[j - 1])});
    previous = std::move(row);
  }
  require(
      static_cast<double>(previous.back()) / expected.size() <= 0.25,
      "native worker smoke word error exceeded 25 percent");
  require(timed_tokens > 0, "missing experimental token timestamps");
  require(!worker.take_result(), "result poll was not destructive");
  return std::move(*result);
}

int main(int argc, char** argv) {
  try {
    require(argc == 3, "expected verified model and pinned fixture float32 paths");
    std::ifstream input(argv[2], std::ios::binary | std::ios::ate);
    require(input.good(), "fixture could not be opened");
    const auto bytes = static_cast<std::streamoff>(input.tellg());
    require(bytes >= 8 * 16000 * 4 && bytes <= 15 * 16000 * 4 && bytes % 4 == 0, "fixture bounds invalid");
    std::vector<float> pcm(static_cast<size_t>(bytes) / 4);
    input.seekg(0);
    input.read(reinterpret_cast<char*>(pcm.data()), static_cast<std::streamsize>(bytes));
    require(input.good(), "fixture read failed");
    InferenceWorker worker(argv[1]);
    worker.reset(5, 77);
    require(!worker.submit({5, 77, 100, 1.25 / 16000, {}}), "short window accepted");
    require(worker.submit({5, 77, 100, 1.0 / 16000, pcm}), "first bounded window rejected");
    require(!worker.submit({5, 77, 100, 1.25 / 16000, pcm}), "second concurrent inference accepted");
    InferenceWorker competing(argv[1]);
    competing.reset(1, 1);
    require(
        !competing.submit({1, 1, 100, 1.0 / 16000, pcm}), "another worker bypassed the process-wide inference limit");
    const auto first = check_result(worker, 5, 77, 100, 1);
    require(!worker.submit({5, 78, 100, 1.25 / 16000, pcm}), "wrong continuity accepted");
    worker.reset(6, 88);
    require(worker.submit({6, 88, 100, 1.25 / 16000, pcm}), "cancellation window rejected");
    wait_until([&] { return worker.inferencing(); });
    worker.reset(7, 99);
    wait_until([&] { return !worker.busy(); });
    require(!worker.take_result(), "cancelled generation published a result");
    require(worker.submit({7, 99, 200, 1.25 / 16000, pcm}), "worker failed to recover after cancellation");
    const auto second = check_result(worker, 7, 99, 200, 1.25);
    require(first.segments.size() == second.segments.size(), "same input changed segment count after cancellation");
    for (size_t i = 0; i < first.segments.size(); ++i) {
      const auto& a = first.segments[i];
      const auto& b = second.segments[i];
      require(
          std::abs(b.media_start - (200 + (a.media_start - 100) * 1.25)) < 1e-9 &&
              std::abs(b.media_end - (200 + (a.media_end - 100) * 1.25)) < 1e-9,
          "media timestamp conversion lost its origin or speed");
    }
    worker.stop();
    worker.stop();
    require(!worker.submit({7, 99, 100, 1.25 / 16000, pcm}), "stopped worker accepted audio");
    InferenceWorker missing("missing-model-file");
    missing.reset(1, 1);
    require(missing.submit({1, 1, 100, 1.0 / 16000, pcm}), "missing model test rejected input");
    wait_until([&] { return !missing.busy(); });
    const auto failure = missing.take_result();
    require(failure && failure->status == InferenceStatus::model_unavailable, "model error was not typed");
    std::cout << "Actual CPU worker recognition, timebase, single-flight, cancellation and recovery passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
