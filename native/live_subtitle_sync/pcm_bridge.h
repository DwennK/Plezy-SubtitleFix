#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(LIVESYNC_PCM_EXPORTS)
#define LIVESYNC_PCM_API __declspec(dllexport)
#else
#define LIVESYNC_PCM_API __declspec(dllimport)
#endif
#else
#define LIVESYNC_PCM_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ls_pcm_window_info {
  uint64_t generation;
  uint64_t continuity;
  double media_start;
  double media_seconds_per_sample;
} ls_pcm_window_info;

// A handle belongs to one worker thread. Calls are synchronous and bounded;
// the app must never invoke them from its UI or audio callback thread.
LIVESYNC_PCM_API void* ls_pcm_create(void);
LIVESYNC_PCM_API void ls_pcm_destroy(void* handle);
LIVESYNC_PCM_API void ls_pcm_reset(void* handle, uint64_t generation);
// Returns 0 accepted, 1 stale, 2 invalid, 3 unsupported layout, 4 internal error.
LIVESYNC_PCM_API int ls_pcm_append(
    void* handle, uint64_t generation, int64_t epoch, double pts, double speed, int rate, int channels, int samples,
    int planes, const char* format, const uint8_t* bytes, size_t size);
// Copies at most 15 seconds; zero means empty, invalid request, or capacity too
// small. The caller owns the returned PCM and must release it after inference.
LIVESYNC_PCM_API size_t
ls_pcm_snapshot(void* handle, double seconds, float* output, size_t capacity, ls_pcm_window_info* info);

#ifdef __cplusplus
}
#endif
