#pragma once
#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>
#ifdef __cplusplus
extern "C" {
#endif
const SherpaOnnxOfflineTts *LegadoZipVoiceCreate(const char *models, const char *resources, int32_t threads);
const SherpaOnnxGeneratedAudio *LegadoZipVoiceGenerate(const SherpaOnnxOfflineTts *tts,
    const char *text, const float *reference, int32_t count, SherpaOnnxGeneratedAudioProgressCallbackWithArg callback);
#ifdef __cplusplus
}
#endif
