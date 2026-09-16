#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(LIVESYNC_INFERENCE_EXPORTS)
#define LIVESYNC_INFERENCE_API __declspec(dllexport)
#else
#define LIVESYNC_INFERENCE_API __declspec(dllimport)
#endif
#else
#define LIVESYNC_INFERENCE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ABI v1. Text is UTF-8, indexed by byte offset/length, not NUL terminated.
// All storage belongs to the caller; no native result allocation escapes.
typedef struct ls_transcript_token {
  double media_start;
  double media_end;
  float recognition_score;
  uint32_t has_timestamp;
  uint32_t text_offset;
  uint32_t text_length;
} ls_transcript_token;

typedef struct ls_transcript_segment {
  double media_start;
  double media_end;
  uint32_t text_offset;
  uint32_t text_length;
  uint32_t token_offset;
  uint32_t token_count;
} ls_transcript_segment;

typedef struct ls_inference_result {
  uint64_t generation;
  uint64_t continuity;
  double elapsed_seconds;
  // 0 success, 1 model unavailable, 2 inference failed, 3 output limit,
  // 4 invalid segment timestamps. Nonzero results never contain usable text.
  uint32_t status;
  uint32_t segment_count;
  uint32_t token_count;
  uint32_t text_bytes;
  ls_transcript_segment segments[64];
  ls_transcript_token tokens[512];
  char text[8192];
} ls_inference_result;

LIVESYNC_INFERENCE_API uint32_t ls_inference_abi_version(void);
LIVESYNC_INFERENCE_API size_t ls_inference_result_size(void);
// Own one handle on a serialized background queue, holding a verified model
// lease. Destroy joins native work: never invoke it on the UI/audio thread.
LIVESYNC_INFERENCE_API void* ls_inference_create(const char* model_path, int threads);
LIVESYNC_INFERENCE_API void ls_inference_destroy(void* handle);
LIVESYNC_INFERENCE_API int ls_inference_reset(void* handle, uint64_t generation, uint64_t continuity);
// Copies 8–15 s of PCM into the worker. 1 accepted, 0 rejected, -1 error.
LIVESYNC_INFERENCE_API int ls_inference_submit(
    void* handle, uint64_t generation, uint64_t continuity, double media_start, double media_seconds_per_sample,
    const float* samples, size_t count);
// Destructive poll. 1 copied, 0 not ready, -1 invalid destination/error.
// The destination must be exactly ls_inference_result_size() bytes.
LIVESYNC_INFERENCE_API int ls_inference_take_result(void* handle, ls_inference_result* output, size_t size);

#ifdef __cplusplus
}
#endif
