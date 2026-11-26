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

    static let preferenceKey = "appTtsEngine"
    static var preferred: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .uncleFu
    }

    var speaker: String { String(rawValue.dropFirst("qwen.".count)) }
}

enum OfflineSpeechError: LocalizedError {
    case model, synthesis
    var errorDescription: String? {
        switch self {
        case .model: "无法载入离线语音包，请在「我的 → 离线朗读」中检查已选档位。"
        case .synthesis: "离线语音合成失败，请重新播放。"
        }
    }
}

actor OfflineSpeech {
    static let shared = OfflineSpeech()
    final class Passage: Sendable {
        let key: String
        let pack: OfflineVoicePack
        let codes: [Int32]

        init(key: String, pack: OfflineVoicePack, codes: [Int32]) {
            self.key = key
            self.pack = pack
            self.codes = codes
        }
    }

    let decoder = WaveformDecoder()
    private let recentCodes: NSCache<NSString, Passage> = {
        let cache = NSCache<NSString, Passage>()
        cache.totalCostLimit = 512 * 1024
        return cache
    }()
    private var context: OpaquePointer?
    private var loadedVoice: OfflineVoice?
    private var loadedPack: OfflineVoicePack?
    private var expiry: Task<Void, Never>?

    func unload() async {
        expiry?.cancel()
        expiry = nil
        if let context { qwen3_tts_free(context) }
        context = nil
        await decoder.unload()
    }

    func prepare(_ text: String, voice: OfflineVoice, pack: OfflineVoicePack) throws -> Passage {
        try Task.checkCancellation()
        let key = pack.rawValue + "/" + voice.rawValue + "/" + text
        expiry?.cancel()
        defer {
            expiry = Task {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await unload()
            }
        }
        if let cached = recentCodes.object(forKey: key as NSString) {
            return cached
        }
        if loadedPack != pack, let context {
            qwen3_tts_free(context)
            self.context = nil
        }
        if context == nil {
            let talker = pack.directory.appendingPathComponent("talker.gguf")
            let params = Self.parameters
            guard let loaded = qwen3_tts_init_from_file(talker.path, params) else { throw OfflineSpeechError.model }
            guard qwen3_tts_set_language_by_name(loaded, "chinese") == 0 else {
                qwen3_tts_free(loaded)
                throw OfflineSpeechError.model
            }
            legado_qwen_set_cancel_check(loaded) { Task.isCancelled }
            loadedVoice = nil
            loadedPack = pack
            context = loaded
        }
        try Task.checkCancellation()
        guard let context else { throw OfflineSpeechError.model }
        if loadedVoice != voice {
            guard let url = Bundle.main.url(forResource: voice.speaker, withExtension: "prompt", subdirectory: "VoicePreviews"),
                  let prompt = try? Data(contentsOf: url) else { throw OfflineSpeechError.model }
            loadedVoice = nil
            let status = prompt.withUnsafeBytes { bytes in
                legado_qwen_set_narrator(context, voice.speaker, "这一天，故事才刚刚开始。",
                                         bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            guard status == 0 else { throw OfflineSpeechError.model }
            loadedVoice = voice
        }
        var count: Int32 = 0
        guard let buffer = qwen3_tts_synthesize_codes(context, text, &count) else {
            try Task.checkCancellation()
            throw OfflineSpeechError.synthesis
        }
        defer { qwen3_tts_codes_free(buffer) }
        try Task.checkCancellation()
        guard count > 0 else { throw OfflineSpeechError.synthesis }
        let codes = Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
        let passage = Passage(key: key, pack: pack, codes: codes)
        recentCodes.setObject(passage, forKey: key as NSString, cost: codes.count * MemoryLayout<Int32>.stride)
        return passage
    }

    fileprivate static var parameters: qwen3_tts_context_params {
        var params = qwen3_tts_context_default_params()
        params.use_gpu = false
        params.n_threads = Int32(min(6, ProcessInfo.processInfo.activeProcessorCount))
        params.max_codec_steps = 420
        params.temperature = 0.9
        params.seed = 42
        params.verbosity = 0
        return params
    }
}

// One waveform decoder serves every passage in order while the talker prepares the next one.
actor WaveformDecoder {
    private let recentAudio: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
    private var context: OpaquePointer?
    private var pack: OfflineVoicePack?

    func unload() {
        if let context { qwen3_tts_free(context) }
        context = nil
        pack = nil
    }

    func decode(_ passage: OfflineSpeech.Passage) throws -> Data {
        try Task.checkCancellation()
        let key = passage.key as NSString
        if let cached = recentAudio.object(forKey: key) { return cached as Data }
        if pack != passage.pack {
            unload()
            let codec = passage.pack.directory.appendingPathComponent("codec.gguf")
            var params = OfflineSpeech.parameters
            params.n_threads = min(4, params.n_threads)
            guard let loaded = qwen3_tts_init_codec_only(codec.path, params) else { throw OfflineSpeechError.model }
            context = loaded
            pack = passage.pack
        }
        var count: Int32 = 0
        guard let samples = qwen3_tts_decode_codes(context, passage.codes, Int32(passage.codes.count), &count) else {
            throw OfflineSpeechError.synthesis
        }
        defer { qwen3_tts_pcm_free(samples) }
        try Task.checkCancellation()
        guard count > 0 else { throw OfflineSpeechError.synthesis }
        for i in 0..<Int(count) {
            let sample = samples[i]
            samples[i] = sample.isFinite ? min(1, max(-1, sample)) : 0
        }
        let data = Data(bytes: samples, count: Int(count) * MemoryLayout<Float>.size)
        recentAudio.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
}
