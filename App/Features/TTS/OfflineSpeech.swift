import CQwenSpeech
import Foundation

enum OfflineVoice: String, CaseIterable {
    case uncleFu = "qwen.uncle_fu"
    case serena = "qwen.serena"
    case vivian = "qwen.vivian"

    var title: String {
        switch self {
        case .uncleFu: "Uncle_Fu（离线男声）"
        case .serena: "Serena（离线女声）"
        case .vivian: "Vivian（离线女声）"
        }
    }

    var speaker: String { String(rawValue.dropFirst("qwen.".count)) }
}

private enum OfflineSpeechError: LocalizedError {
    case model, synthesis
    var errorDescription: String? {
        switch self {
        case .model: "无法载入离线语音包，请在阅读设置中检查已选档位。"
        case .synthesis: "离线语音合成失败，请重新播放。"
        }
    }
}

actor OfflineSpeech {
    static let shared = OfflineSpeech()
    private var context: OpaquePointer?
    private var loadedPack: OfflineVoicePack?
    private var expiry: Task<Void, Never>?

    func audio(text: String, voice: OfflineVoice) throws -> Data {
        try Task.checkCancellation()
        expiry?.cancel()
        defer {
            expiry = Task {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                if let context { qwen3_tts_free(context) }
                context = nil
            }
        }
        guard let pack = OfflineVoicePack.selected else { throw OfflineSpeechError.model }
        if loadedPack != pack, let context {
            qwen3_tts_free(context)
            self.context = nil
        }
        if context == nil {
            let talker = pack.directory.appendingPathComponent("talker.gguf")
            let codec = pack.directory.appendingPathComponent("codec.gguf")
            var params = qwen3_tts_context_default_params()
            // CPU synthesis can continue while iOS has suspended foreground GPU access.
            params.use_gpu = false
            params.n_threads = 4
            params.max_codec_steps = 420
            params.seed = 42
            params.verbosity = 0
            guard let loaded = qwen3_tts_init_from_file(talker.path, params) else { throw OfflineSpeechError.model }
            guard qwen3_tts_set_codec_path(loaded, codec.path) == 0,
                  qwen3_tts_set_language_by_name(loaded, "chinese") == 0 else {
                qwen3_tts_free(loaded)
                throw OfflineSpeechError.model
            }
            loadedPack = pack
            context = loaded
        }
        try Task.checkCancellation()
        guard let context, qwen3_tts_set_speaker_by_name(context, voice.speaker) == 0 else {
            throw OfflineSpeechError.model
        }
        var count: Int32 = 0
        guard let samples = qwen3_tts_synthesize(context, text, &count) else { throw OfflineSpeechError.synthesis }
        defer { qwen3_tts_pcm_free(samples) }
        try Task.checkCancellation()
        guard count > 0 else { throw OfflineSpeechError.synthesis }
        let pcm = UnsafeBufferPointer(start: samples, count: Int(count)).map { sample in
            Int16(max(-1, min(1, sample.isFinite ? sample : 0)) * 32767)
        }
        var wave = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) }
        }
        let size = UInt32(pcm.count * 2)
        append(size + 36)
        wave.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(24_000))
        append(UInt32(48_000))
        append(UInt16(2))
        append(UInt16(16))
        wave.append(Data("data".utf8))
        append(size)
        pcm.withUnsafeBytes { wave.append(contentsOf: $0) }
        return wave
    }

    static func phrases(in paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in paragraph {
            current.append(character)
            if current.count >= 60 || (current.count >= 10 && "。？！；!?;\n".contains(character)) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { $0.rangeOfCharacter(from: .alphanumerics) != nil || !$0.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).isEmpty }
    }
}
