import Accelerate
import Foundation
import ZipVoiceBridge

enum OfflineVoice: String, CaseIterable {
    case uncleFu = "qwen.uncle_fu"
    case serena = "qwen.serena"

    var title: String {
        switch self {
        case .uncleFu: "Uncle_Fu（离线男声）"
        case .serena: "Serena（离线女声）"
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

actor ZipVoiceSpeech {
    static let shared = ZipVoiceSpeech()
    private var engine: OpaquePointer?
    private var releaseTask: Task<Void, Never>?
    private var references: [OfflineVoice: [Float]] = [:]

    private func unload() {
        releaseTask?.cancel()
        releaseTask = nil
        if let engine { SherpaOnnxDestroyOfflineTts(engine) }
        engine = nil
        references.removeAll()
    }

    func synthesize(_ text: String, voice: OfflineVoice) throws -> Data {
        try Task.checkCancellation()
        releaseTask?.cancel()
        defer {
            releaseTask = Task {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                unload()
            }
        }
        guard let resources = Bundle.main.url(forResource: "ZipVoice", withExtension: nil) else {
            throw OfflineSpeechError.model
        }
        if engine == nil {
            engine = LegadoZipVoiceCreate(OfflineVoicePack.zipvoice.directory.path, resources.path,
                                         Int32(min(4, ProcessInfo.processInfo.activeProcessorCount)))
        }
        guard let engine else { throw OfflineSpeechError.model }
        if references[voice] == nil {
            let url = resources.appendingPathComponent(voice.speaker + ".f32")
            let data = try Data(contentsOf: url)
            guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.stride) else { throw OfflineSpeechError.model }
            var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
            _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            references[voice] = samples
        }
        guard let reference = references[voice] else { throw OfflineSpeechError.model }
        let result = reference.withUnsafeBufferPointer { buffer in
            LegadoZipVoiceGenerate(engine, SpokenPassage.zipVoiceText(for: text), buffer.baseAddress, Int32(buffer.count)) { _, _, _, _ in
                Task.isCancelled ? 0 : 1
            }
        }
        guard let result else { throw OfflineSpeechError.synthesis }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(result) }
        try Task.checkCancellation()
        let audio = result.pointee
        guard audio.sample_rate == 24_000, audio.n > 0, let samples = audio.samples else { throw OfflineSpeechError.synthesis }
        if voice == .uncleFu { return Self.clearMalePCM(samples, count: Int(audio.n)) }
        return Data(bytes: samples, count: Int(audio.n) * MemoryLayout<Float>.size)
    }

    // Broad bell filters keep the bass and the highest sibilants close to their original level.
    private static let maleEQ = bell(hz: 360, gainDB: -2.5) + bell(hz: 2_800, gainDB: 2.5)

    private static func bell(hz: Double, gainDB: Double) -> [Double] {
        let angle = 2 * Double.pi * hz / 24_000
        let gain = pow(10, gainDB / 40)
        let alpha = sin(angle) / (2 * 0.85)
        let denominator = 1 + alpha / gain
        let middle = -2 * cos(angle) / denominator
        return [(1 + alpha * gain) / denominator, middle, (1 - alpha * gain) / denominator,
                middle, (1 - alpha / gain) / denominator]
    }

    private static func clearMalePCM(_ input: UnsafePointer<Float>, count: Int) -> Data {
        let size = count * MemoryLayout<Float>.stride
        guard let eq = vDSP_biquad_CreateSetup(maleEQ, 2) else { return Data(bytes: input, count: size) }
        defer { vDSP_biquad_DestroySetup(eq) }
        var delays = [Float](repeating: 0, count: 6)
        var pcm = Data(count: size)
        pcm.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let output = bytes.bindMemory(to: Float.self).baseAddress else { return }
            let length = vDSP_Length(count)
            vDSP_biquad(eq, &delays, input, 1, output, 1, length)
            var peak: Float = 0
            vDSP_maxmgv(output, 1, &peak, length)
            if peak > 1 { vDSP_vsdiv(output, 1, &peak, output, 1, length) }
        }
        return pcm
    }
}
