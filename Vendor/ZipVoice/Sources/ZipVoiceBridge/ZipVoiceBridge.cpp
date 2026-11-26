#include "ZipVoiceBridge.h"
#include <string>

const SherpaOnnxOfflineTts *LegadoZipVoiceCreate(const char *models, const char *resources, int32_t threads) {
    const auto encoder = std::string(models) + "/encoder.int8.onnx";
    const auto decoder = std::string(models) + "/decoder.int8.onnx";
    const auto vocoder = std::string(models) + "/vocos_24khz.onnx";
    const auto tokens = std::string(resources) + "/tokens.txt";
    const auto lexicon = std::string(resources) + "/lexicon.txt";
    SherpaOnnxOfflineTtsConfig config{};
    auto &zip = config.model.zipvoice;
    zip.encoder = encoder.c_str();
    zip.decoder = decoder.c_str();
    zip.vocoder = vocoder.c_str();
    zip.tokens = tokens.c_str();
    zip.lexicon = lexicon.c_str();
    zip.feat_scale = 0.1f;
    zip.t_shift = 0.5f;
    zip.target_rms = 0.1f;
    zip.guidance_scale = 1;
    config.model.num_threads = threads;
    config.model.provider = "cpu";
    config.max_num_sentences = 1;
    return SherpaOnnxCreateOfflineTts(&config);
}

const SherpaOnnxGeneratedAudio *LegadoZipVoiceGenerate(const SherpaOnnxOfflineTts *tts,
    const char *text, const float *reference, int32_t count, SherpaOnnxGeneratedAudioProgressCallbackWithArg callback) {
    SherpaOnnxGenerationConfig config{};
    config.speed = 1;
    config.silence_scale = 1;
    config.reference_audio = reference;
    config.reference_audio_len = count;
    config.reference_sample_rate = 24000;
    config.reference_text = "推开窗，街上的人已经多了起来。";
    config.num_steps = 4;
    return SherpaOnnxOfflineTtsGenerateWithConfig(tts, text, &config, callback, nullptr);
}
