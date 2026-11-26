#include <stdbool.h>
#include "qwen3_tts.h"

// Polled on the synthesis thread between codec frames.
#ifdef __cplusplus
extern "C"
#endif
void legado_qwen_set_cancel_check(struct qwen3_tts_context *ctx, bool (*check)(void));

// The bundled prompt is row-major little-endian UInt16, 16 codebooks per frame.
#ifdef __cplusplus
extern "C"
#endif
int legado_qwen_set_narrator(struct qwen3_tts_context *ctx, const char *speaker, const char *transcript,
                             const uint8_t *codes, size_t bytes);
