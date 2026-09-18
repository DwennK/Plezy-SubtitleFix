#pragma once

#include <whisper.h>

namespace livesync::fault_test {
whisper_context* initialize(const char* path, whisper_context_params options);
int transcribe(whisper_context* context, whisper_full_params parameters, const float* samples, int count);
int64_t segment_end(whisper_context* context, int index);
}  // namespace livesync::fault_test
