#pragma once

#include <mpv/client.h>

#include "pcm_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// The app supplies functions from its already-loaded, pinned mpv. In particular,
// a static Apple framework must never be duplicated in a second dynamic image.
typedef struct ls_mpv_api {
  uint32_t version;
  int (*get_property)(mpv_handle*, const char*, mpv_format, void*);
  int (*set_property_string)(mpv_handle*, const char*, const char*);
  void (*free_node_contents)(mpv_node*);
  mpv_event* (*wait_event)(mpv_handle*, double);
  void (*destroy)(mpv_handle*);
} ls_mpv_api;

typedef struct ls_capture_info {
  uint64_t generation;
  uint64_t continuity;
  uint64_t samples;
  // 0 capturing, 1 waiting for PCM, 2 invalid packet, 3 unsupported layout,
  // 4 stopped (including player shutdown).
  uint32_t state;
} ls_capture_info;

LIVESYNC_PCM_API uint32_t ls_capture_abi_version(void);
LIVESYNC_PCM_API size_t ls_capture_api_size(void);
LIVESYNC_PCM_API size_t ls_capture_info_size(void);
// weak_client comes from mpv_create_weak_client on the live player's owner
// queue. Ownership transfers ONLY on success. One capture per process. All
// API calls belong to one serialized background isolate, never the UI thread.
LIVESYNC_PCM_API void* ls_capture_create(mpv_handle* weak_client, const ls_mpv_api* api, uint64_t generation);
// Stops and joins the polling thread, disables the tap and destroys the weak
// client. Player shutdown is also detected and releases the weak client, so
// mpv_terminate_destroy cannot wait forever for an abandoned active capture.
LIVESYNC_PCM_API void ls_capture_destroy(void* capture);
LIVESYNC_PCM_API int ls_capture_reset(void* capture, uint64_t generation);
LIVESYNC_PCM_API int ls_capture_get_info(void* capture, ls_capture_info* info, size_t size);
LIVESYNC_PCM_API size_t
ls_capture_snapshot(void* capture, double seconds, float* output, size_t capacity, ls_pcm_window_info* info);

#ifdef __cplusplus
}
#endif
