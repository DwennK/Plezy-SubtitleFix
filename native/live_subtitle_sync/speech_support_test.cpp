#include "speech_support.h"

#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <vector>

using namespace livesync;

void require(bool condition, const char* reason) {
  if (!condition) throw std::runtime_error(reason);
}

int main(int argc, char** argv) {
  try {
    SpeechEvidence unknown;
    require(unknown.support(1, 0.35) == SpeechSupport::unknown, "failure must remain unknown");
    SpeechEvidence speech{true, 8, {{1, 2}, {4, 5}}};
    require(speech.support(1.5, 0) == SpeechSupport::supported, "speech membership");
    require(speech.support(0.7, 0.35) == SpeechSupport::supported, "existing uncertainty support");
    require(speech.support(0.6, 0.35) == SpeechSupport::unsupported, "outside uncertainty");
    require(speech.support(8, 0.35) == SpeechSupport::unknown, "window end excluded");
    require(speech.support(-0.1, 0.35) == SpeechSupport::unknown, "negative point");
    require(speech.support(1, -1) == SpeechSupport::unknown, "negative uncertainty");
    require(
        speech.support(std::numeric_limits<double>::quiet_NaN(), 0.35) == SpeechSupport::unknown, "nonfinite point");
    SpeechDetector unavailable(nullptr, 0);
    std::vector<float> silence(8 * 16000, 0);
    require(!unavailable.analyze(silence.data(), silence.size()).available, "no model fallback");
    if (argc != 2 && argc != 3) throw std::runtime_error("provide verified model path for native inference contracts");
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<unsigned char> model((std::istreambuf_iterator<char>(input)), {});
    require(model.size() == 885098, "pinned model length");
    SpeechDetector detector(model.data(), model.size());
    // Input model storage may be released: init consumes it synchronously.
    model.clear();
    model.shrink_to_fit();
    const auto quiet = detector.analyze(silence.data(), silence.size());
    require(quiet.available && quiet.intervals.empty(), "real silence classified");
    require(quiet.support(4, 0.35) == SpeechSupport::unsupported, "silence is not unknown");
    silence[0] = std::numeric_limits<float>::quiet_NaN();
    require(!detector.analyze(silence.data(), silence.size()).available, "nonfinite PCM rejected");
    silence[0] = 0;
    require(!detector.analyze(silence.data(), 1).available, "short window rejected");
    require(!detector.analyze(nullptr, silence.size()).available, "null PCM rejected");
    require(
        detector.analyze(silence.data(), silence.size()).intervals.empty(), "context reusable after rejected input");
    if (argc == 3) {
      std::ifstream audio(argv[2], std::ios::binary | std::ios::ate);
      const auto bytes = static_cast<std::streamoff>(audio.tellg());
      require(bytes >= 8 * 16000 * 4 && bytes <= 15 * 16000 * 4 && bytes % 4 == 0, "bounded float window");
      audio.seekg(0);
      std::vector<float> samples(static_cast<size_t>(bytes) / 4);
      audio.read(reinterpret_cast<char*>(samples.data()), static_cast<std::streamsize>(bytes));
      require(audio.good(), "complete float window");
      const auto first = detector.analyze(samples.data(), samples.size());
      require(first.available, "real window available");
      require(detector.analyze(silence.data(), silence.size()).intervals.empty(), "speech must not leak into silence");
      const auto repeat = detector.analyze(samples.data(), samples.size());
      require(repeat.available && repeat.intervals.size() == first.intervals.size(), "repeat interval count");
      std::cout << std::setprecision(17) << "{\"intervals\":[";
      for (size_t i = 0; i < first.intervals.size(); ++i) {
        require(
            first.intervals[i].start == repeat.intervals[i].start && first.intervals[i].end == repeat.intervals[i].end,
            "independent window state must reset");
        if (i) std::cout << ',';
        std::cout << '[' << first.intervals[i].start << ',' << first.intervals[i].end << ']';
      }
      std::cout << "],\"resetAndReusePassed\":true}\n";
    }
    std::cout << "Speech support contracts passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
