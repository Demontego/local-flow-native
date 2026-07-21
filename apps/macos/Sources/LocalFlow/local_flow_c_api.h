#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocalFlowEngine LocalFlowEngine;

typedef struct LFContext {
  const char *app_name;
  const char *bundle_id;
  const char *channel_hint;
  const char *before_text;
  const char *selected_text;
  const char *chat_lines;
  const char *recent;
  const char *screenshot_path;
} LFContext;

typedef struct LFSessionResult {
  char *raw;
  char *clean;
  int press_enter;
} LFSessionResult;

typedef void (*lf_progress_cb)(uint32_t percent, void *userdata);

LocalFlowEngine *lf_engine_new(void);
void lf_engine_free(LocalFlowEngine *ptr);
void lf_string_free(char *s);
char *lf_engine_load_models(LocalFlowEngine *ptr);
char *lf_engine_personalization_json(LocalFlowEngine *ptr);
char *lf_engine_save_personalization_json(LocalFlowEngine *ptr, const char *json);
char *lf_engine_recent_json(LocalFlowEngine *ptr, const char *bundle_id);
char *lf_engine_download_whisper(LocalFlowEngine *ptr, lf_progress_cb cb, void *userdata);
char *lf_engine_download_qwen(LocalFlowEngine *ptr, lf_progress_cb cb, void *userdata);
int lf_engine_start_hold(LocalFlowEngine *ptr);
void lf_engine_cancel_hold(LocalFlowEngine *ptr);
int lf_engine_push_audio(LocalFlowEngine *ptr, const float *samples, int len);
char *lf_engine_partial(LocalFlowEngine *ptr);
LFSessionResult *lf_engine_end_hold(LocalFlowEngine *ptr, const LFContext *ctx);
char *lf_engine_cleanup_text(LocalFlowEngine *ptr, const char *raw, const LFContext *ctx);
void lf_session_result_free(LFSessionResult *r);
LFContext *lf_context_new(const char *app_name, const char *bundle_id, const char *channel_hint,
                          const char *before_text, const char *selected_text,
                          const char *chat_lines, const char *recent,
                          const char *screenshot_path);
void lf_context_free(LFContext *ctx);
char *lf_library_version(void);

#ifdef __cplusplus
}
#endif
