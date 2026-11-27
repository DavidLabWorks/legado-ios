import AVFoundation

enum ListeningEngine: String, CaseIterable, Sendable {
    case libreTTS, edgeOne, pptBoard, fengwmEdge, fengwmAzure, fengwmVolcengine, wanxiang

    static let preferenceKey = "listeningEngine"

    var title: String {
        switch self {
        case .libreTTS: return "LibreTTS 在线"
        case .edgeOne: return "EdgeOne TTS"
        case .pptBoard: return "PPTBoard TTS"
        case .fengwmEdge: return "fengwm · Edge"
        case .fengwmAzure: return "fengwm · Azure"
        case .fengwmVolcengine: return "fengwm · 火山"
        case .wanxiang: return "万象 TTS"
        }
    }

    var voicePreferenceKey: String { rawValue + "Voice" }

    private var baseURL: URL {
        switch self {
        case .libreTTS: return URL(string: "https://libretts.is-an.org/api/")!
        case .edgeOne: return URL(string: "https://tts.smallyoung.cn/")!
        case .pptBoard: return URL(string: "https://tts.pptboard.com/")!
        case .fengwmEdge, .fengwmAzure, .fengwmVolcengine: return URL(string: "https://tts.102465.xyz/api/")!
        case .wanxiang: return URL(string: "https://api.vsaa.cn/api/toolbox/tts/")!
        }
    }

    private var fengwmProvider: String? {
        switch self {
        case .fengwmEdge: return "edge"
        case .fengwmAzure: return "azure"
        case .fengwmVolcengine: return "volcengine"
        default: return nil
        }
    }

    struct Voice: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let locale: String

        enum CodingKeys: String, CodingKey {
            case id = "ShortName", name = "LocalName", locale = "Locale"
        }

        init(id: String, name: String, locale: String) {
            self.id = id
            self.name = name
            self.locale = locale
        }

        init(id: String, name: String) {
            let locale: String
            if id.hasPrefix("zh_") { locale = "zh-CN" }
            else if id.hasPrefix("en_") { locale = "en" }
            else if id.hasPrefix("jp_") { locale = "ja" }
            else { locale = id.split(separator: "-").prefix(2).joined(separator: "-") }
            self.init(id: id, name: name, locale: locale)
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            locale = try fields.decode(String.self, forKey: .locale)
            let shortName = id.components(separatedBy: "-").last ?? id
            name = try fields.decodeIfPresent(String.self, forKey: .name)
                ?? ["XiaoxiaoNeural": "晓晓", "YunxiNeural": "云希", "XiaoyiNeural": "晓伊", "YunyangNeural": "云扬"][shortName]
                ?? (shortName.hasSuffix("Neural") ? String(shortName.dropLast(6)) : shortName)
        }

        var languageName: String {
            Locale(identifier: "zh_CN").localizedString(forIdentifier: locale) ?? locale
        }
    }

    static let xiaoxiao = Voice(id: "zh-CN-XiaoxiaoNeural", name: "晓晓", locale: "zh-CN")
    static let yunxi = Voice(id: "zh-CN-YunxiNeural", name: "云希", locale: "zh-CN")

    // ShortName and Locale both start with the catalog's language subtag.
    private static func isChinese(_ language: Substring?) -> Bool {
        language == "zh" || language == "yue" || language == "wuu"
    }

    private static func supports(_ identifier: String) -> Bool {
        let language = identifier.split(separator: "-").first
        return language == "en" || isChinese(language)
    }

    var defaultVoices: [Voice] {
        if self == .fengwmVolcengine {
            return [Voice(id: "zh_female_story", name: "少儿故事 中英混", locale: "zh-CN"),
                    Voice(id: "zh_female_qingxin", name: "清新女声 中英混", locale: "zh-CN")]
        }
        return [Self.xiaoxiao, Self.yunxi]
    }

    func supportedVoiceID(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return defaultVoices[0].id }
        if fengwmProvider == nil, !Self.supports(id) { return defaultVoices[0].id }
        return id
    }

    func voices() async throws -> [Voice] {
        let url: URL
        switch self {
        case .libreTTS: url = baseURL.appendingPathComponent("voices")
        case .pptBoard: url = baseURL.appendingPathComponent("voices.json")
        case .edgeOne: url = baseURL
        case .wanxiang: url = baseURL.appendingPathComponent("voices.php")
        case .fengwmEdge, .fengwmAzure, .fengwmVolcengine:
            var components = URLComponents(url: baseURL.appendingPathComponent("voices"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "provider", value: fengwmProvider)]
            url = components.url!
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try decodeVoices(data)
    }

    func decodeVoices(_ data: Data) throws -> [Voice] {
        let catalog: [Voice]
        switch self {
        case .fengwmEdge, .fengwmAzure, .fengwmVolcengine:
            struct Catalog: Decodable {
                struct Entry: Decodable {
                    let voice_name: String
                    let label: String
                }
                let provider: String
                let voices: [Entry]
            }
            let result = try JSONDecoder().decode(Catalog.self, from: data)
            guard result.provider == fengwmProvider else { throw URLError(.cannotParseResponse) }
            catalog = result.voices.map { Voice(id: $0.voice_name, name: $0.label) }
        case .wanxiang:
            struct Catalog: Decodable {
                struct Payload: Decodable {
                    struct Entry: Decodable { let voice, name: String }
                    let voices: [Entry]
                }
                let data: Payload
            }
            catalog = try JSONDecoder().decode(Catalog.self, from: data).data.voices.map {
                Voice(id: $0.voice, name: $0.name)
            }
        case .edgeOne:
            // EdgeOne publishes its voice catalog in the page's JavaScript.
            let html = String(decoding: data, as: UTF8.self) as NSString
            let pattern = #"[{]\s*value:\s*'([\w-]+)',\s*name:\s*'([^']+)'(?:,\s*desc:\s*'([^']+)')?"#
            let entries = try NSRegularExpression(pattern: pattern)
            catalog = entries.matches(in: html as String, range: NSRange(location: 0, length: html.length)).compactMap {
                let id = html.substring(with: $0.range(at: 1))
                guard id.hasSuffix("Neural") else { return nil }
                var name = html.substring(with: $0.range(at: 2))
                if $0.range(at: 3).location != NSNotFound {
                    name += "（" + html.substring(with: $0.range(at: 3)) + "）"
                }
                return Voice(id: id, name: name)
            }
        case .libreTTS, .pptBoard:
            catalog = try JSONDecoder().decode([Voice].self, from: data)
        }
        if fengwmProvider != nil {
            guard !catalog.isEmpty else { throw URLError(.cannotParseResponse) }
            return catalog
        }
        let voices = catalog.filter { Self.supports($0.locale) }
        guard !voices.isEmpty else { throw URLError(.cannotParseResponse) }
        let commonVoices = [Self.xiaoxiao.id, Self.yunxi.id, "zh-CN-XiaoyiNeural", "zh-CN-YunyangNeural"]
        func order(_ voice: Voice) -> (Int, String, String) {
            let languageRank = Self.isChinese(voice.locale.split(separator: "-").first) ? commonVoices.count : commonVoices.count + 1
            return (commonVoices.firstIndex(of: voice.id) ?? languageRank, voice.locale, voice.id)
        }
        return voices.sorted { order($0) < order($1) }
    }

    static func isTemporaryFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .resourceUnavailable, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        let httpError = error as NSError
        return httpError.domain == "ListeningEngine" &&
            (httpError.code == 408 || httpError.code == 429 || (500..<600).contains(httpError.code))
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ListeningEngine", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(title) 请求失败（HTTP \(http.statusCode)），请稍后重试。"
            ])
        }
    }

    func download(text: String, voice: String) async throws -> URL {
        let path: String
        let body: [String: String]
        switch self {
        case .libreTTS:
            path = "tts"
            body = ["text": text, "voice": voice, "format": "wav"]
        case .edgeOne, .pptBoard:
            path = "v1/audio/speech"
            body = ["input": text, "voice": voice, "model": "tts-1"]
        case .fengwmEdge, .fengwmAzure, .fengwmVolcengine:
            path = "tts"
            body = ["text": text, "voice": voice, "provider": fengwmProvider!]
        case .wanxiang:
            path = "tts.php"
            body = ["text": text, "voice": voice, "raw": "1"]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 45)
        request.httpMethod = "POST"
        if self == .wanxiang {
            var form = URLComponents()
            form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (file, response) = try await URLSession.shared.download(for: request)
        do {
            try Task.checkCancellation()
            try validate(response)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size != 0 else { throw audioError("服务返回了空音频。") }
            if response.mimeType == "application/json" {
                struct ServiceError: Decodable { let msg: String }
                let detail = size.map { $0 <= 65_536 } == true
                    ? try? JSONDecoder().decode(ServiceError.self, from: Data(contentsOf: file)).msg
                    : nil
                throw audioError(detail.map { String($0.prefix(300)) } ?? "服务返回了 JSON，未生成音频。")
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func audioError(_ reason: String) -> NSError {
        NSError(domain: "ListeningEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(title)：\(reason)"])
    }

    func synthesisChunks(_ text: String) -> [Substring] {
        // 万象按 Unicode 码点限制每次请求的字数。
        let limit = 1_500
        let scalars = text.unicodeScalars
        guard self == .wanxiang, scalars.count > limit else { return [text[...]] }
        var chunks: [Substring] = []
        var start = scalars.startIndex
        let breaks = CharacterSet(charactersIn: "。！？；，、.!?;,").union(.whitespacesAndNewlines)
        while let end = scalars.index(start, offsetBy: limit, limitedBy: scalars.endIndex), end < scalars.endIndex {
            // Prefer a pause and leave room for the final words in a nearly full request.
            let middle = scalars.index(start, offsetBy: limit / 2)
            let searchStart = scalars.index(start, offsetBy: limit / 4)
            let pause = scalars[searchStart..<middle].lastIndex(where: breaks.contains)
            let split = pause.map { scalars.index(after: $0) } ?? middle
            chunks.append(text[start..<split])
            start = split
        }
        chunks.append(text[start...])
        return chunks
    }

    static func audio(text: String, voice: ListeningVoice) async throws -> Data {
        var samples = Data()
        for chunk in voice.engine.synthesisChunks(text) {
            try Task.checkCancellation()
            let file = try await voice.engine.download(text: String(chunk), voice: voice.id)
            defer { try? FileManager.default.removeItem(at: file) }
            try samples.append(voice.engine.decodeAudio(file))
        }
        return samples
    }

    private func decodeAudio(_ file: URL) throws -> Data {
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw audioError("无法识别返回的音频，请在听书设置中更换声音或引擎。")
        }
        let format = audio.processingFormat
        guard format.sampleRate == 24_000, format.channelCount == 1, audio.length > 0, audio.length <= 24_000 * 300,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw URLError(.cannotDecodeContentData)
        }
        try audio.read(into: buffer)
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
            throw URLError(.cannotDecodeContentData)
        }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
    }
}

struct ListeningVoice: Sendable, Equatable {
    let engine: ListeningEngine
    let id: String

    static var preferred: Self {
        let defaults = UserDefaults.standard
        let engine = defaults.string(forKey: ListeningEngine.preferenceKey).flatMap(ListeningEngine.init(rawValue:)) ?? .libreTTS
        return Self(engine: engine, id: engine.supportedVoiceID(defaults.string(forKey: engine.voicePreferenceKey)))
    }
}
