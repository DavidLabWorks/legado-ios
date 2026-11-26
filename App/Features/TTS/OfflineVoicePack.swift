import CryptoKit
import Foundation
import ZIPFoundation

enum OfflineVoicePack: String, CaseIterable, Identifiable, Sendable {
    case zipvoice, high, medium, compact
    var id: Self { self }
    static let preferenceKey = "offlineVoicePack.v1"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineSpeech/v1", isDirectory: true)
    }
    var directory: URL { Self.root.appendingPathComponent(rawValue, isDirectory: true) }
    var title: String {
        switch self {
        case .zipvoice: "ZipVoice（男声和女声）"
        case .high: "高质量"
        case .medium: "中等"
        case .compact: "精简"
        }
    }
    var downloadSize: Int64 {
        switch self {
        case .zipvoice: ZipVoiceDownload.size
        case .high: 1_262_405_474
        case .medium: 700_779_921
        case .compact: 596_147_583
        }
    }
    private var files: [(name: String, bytes: Int, sha256: String)] {
        switch self {
        case .zipvoice: ZipVoiceDownload.assets.map { ($0.name, Int($0.size), $0.sha256) }
        case .high:
            [("talker.gguf", 967980192, "5227dcbc4df7c5533341d111cc469fa491a48e722b23dd10f553181b52dff2d9"),
             ("codec.gguf", 358453280, "70dc95dbfdd9aa5d9d406236ff771d061bf17b0cda02a72513953355606e719b")]
        case .medium:
            [("talker.gguf", 551302304, "857b33d574e115e6ccfdc5e0d7bd73adbc034bcb48a59d8902aece3fc43db430"),
             ("codec.gguf", 177171200, "673c036d3f857e5d762515741e47c74b69ae0fe7ccb4bab60d644540c3e40d80")]
        case .compact:
            [("talker.gguf", 498179232, "e4af69223cc2d9d7e9d8f658127c1fac470d693ea37848f84c9580d83a7b18b8"),
             ("codec.gguf", 177171200, "15613cabeac27f0f1edcd10bee8e649a56c14c22df7f734da421267fb7391e2b")]
        }
    }
    var voices: [OfflineVoice] { self == .zipvoice ? [.uncleFu, .serena] : OfflineVoice.allCases }

    func resolve(_ voice: OfflineVoice) -> OfflineVoice {
        voices.contains(voice) ? voice : .uncleFu
    }

    var isInstalled: Bool {
        files.allSatisfy { file in
            (try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.bytes
        }
    }
    static var selected: Self? {
        Self.zipvoice.isInstalled ? .zipvoice : nil
    }

    var partialArchive: URL { Self.root.appendingPathComponent(rawValue + ".partial.zip") }

    static let didRemove = Notification.Name("OfflineVoicePack.didRemove")

    private var storedLocations: [URL] {
        self == .zipvoice ? [directory, partialArchive, ZipVoiceDownload.stage] : [directory, partialArchive]
    }

    var hasStoredFiles: Bool { storedLocations.contains { FileManager.default.fileExists(atPath: $0.path) } }

    @MainActor func remove() throws {
        let manager = FileManager.default
        for url in storedLocations.reversed() where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.preferenceKey) == rawValue {
            defaults.removeObject(forKey: Self.preferenceKey)
        }
        NotificationCenter.default.post(name: Self.didRemove, object: rawValue)
    }

    static func prepareRoot() throws {
        var root = Self.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try root.setResourceValues(flags)
    }

    // Validate in a separate directory so an interruption never exposes a partial pack to the reader.
    func install(archive url: URL) throws {
        let manager = FileManager.default
        if isInstalled { return }
        let archive = try Archive(url: url, accessMode: .read)
        try Self.prepareRoot()
        let stage = Self.root.appendingPathComponent(".install-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        for file in files {
            try Task.checkCancellation()
            guard let entry = archive[file.name], entry.type == .file, entry.uncompressedSize == UInt64(file.bytes) else {
                throw PackError.invalid
            }
            let output = stage.appendingPathComponent(file.name)
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            var digest = SHA256()
            var written = 0
            _ = try archive.extract(entry, bufferSize: 1 << 20, skipCRC32: true) { chunk in
                try Task.checkCancellation()
                written += chunk.count
                guard written <= file.bytes else { throw PackError.invalid }
                digest.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
            guard written == file.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw PackError.invalid
            }
        }
        try Task.checkCancellation()
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: stage, to: directory)
    }

    enum PackError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: "语音包校验失败，请选择完整的 ZipVoice 语音包 ZIP 文件。"
            case .unavailable: "下载中断，请稍后重试。已完成的分片会保留。"
            }
        }
    }
}

enum ZipVoiceDownload {
    struct Asset {
        let name: String
        let size: Int64
        let sha256: String
        let sources: [URL]
    }

    private static func modelSources(_ name: String) -> [URL] {
        let path = "/k2-fsa/ZipVoice/resolve/889dd609a42f0de9cf9aac335eae42677becb1b9/zipvoice_distill/" + name
        return ["https://huggingface.co", "https://hf-mirror.com"].map { URL(string: $0 + path)! }
    }

    static let assets = [
        Asset(name: "encoder.int8.onnx", size: 5_570_211, sha256: "f2de9a761a85e5ddd125dee6e05bad1c7ee92c11b83b4d775dab216a6aa41379",
              sources: modelSources("text_encoder_int8.onnx")),
        Asset(name: "decoder.int8.onnx", size: 124_657_100, sha256: "3cc2e08a96610d7ea1b227398e97cdbbe0414499741d3aec0b8113db2a2ab251",
              sources: modelSources("fm_decoder_int8.onnx")),
        Asset(name: "vocos_24khz.onnx", size: 54_157_409, sha256: "bcb3b970e384161c4d634f0bb9e999ff1c471b34c9bc0b1049a5014065ed3cc0",
              sources: [URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx")!])
    ]
    private static let chunkSize: Int64 = 8_000_000
    static var size: Int64 { assets.reduce(0) { $0 + $1.size } }
    static var stage: URL { OfflineVoicePack.root.appendingPathComponent(".zipvoice-download", isDirectory: true) }

    private static func committedBytes(_ asset: Asset) -> Int64 {
        let url = stage.appendingPathComponent(asset.name)
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if bytes == asset.size { return bytes }
        return bytes > asset.size ? 0 : bytes / chunkSize * chunkSize
    }
    static var savedBytes: Int64 { assets.reduce(0) { $0 + committedBytes($1) } }

    static func install(report: @Sendable (Int64, String) async -> Void) async throws {
        let manager = FileManager.default
        try OfflineVoicePack.prepareRoot()
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        let count = assets.reduce(0) { $0 + ($1.size + chunkSize - 1) / chunkSize }
        var previous: Int64 = 0
        var parts: Int64 = 0
        for asset in assets {
            let url = stage.appendingPathComponent(asset.name)
            if !manager.fileExists(atPath: url.path) { try Data().write(to: url) }
            let offset = committedBytes(asset)
            let writer = try FileHandle(forWritingTo: url)
            defer { try? writer.close() }
            try writer.truncate(atOffset: UInt64(offset))
            try writer.seekToEnd()
            for start in stride(from: offset, to: asset.size, by: Int(chunkSize)) {
                try Task.checkCancellation()
                let end = min(start + chunkSize, asset.size)
                let part = parts + start / chunkSize + 1
                let status = "第 \(part) 个分片，共 \(count) 个"
                let base = previous + start
                await report(base, "正在连接 · " + status)
                let tmp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? manager.removeItem(at: tmp) }
                for (index, source) in asset.sources.enumerated() {
                    do {
                        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)!
                        components.queryItems = [URLQueryItem(name: "part", value: String(start))]
                        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
                        request.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
                        try await VoicePackTransfer.download(request, to: tmp, size: end - start,
                                contentRange: "bytes \(start)-\(end - 1)/\(asset.size)") { bytes in
                            await report(base + bytes, "正在下载 · " + status)
                        }
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard index + 1 < asset.sources.count else { throw OfflineVoicePack.PackError.unavailable }
                    }
                }
                try Task.checkCancellation()
                try writer.write(contentsOf: Data(contentsOf: tmp, options: .mappedIfSafe))
                try writer.synchronize()
            }
            await report(previous + asset.size, "正在校验 " + asset.name)
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            var hash = SHA256()
            while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                try manager.removeItem(at: url)
                throw OfflineVoicePack.PackError.invalid
            }
            previous += asset.size
            parts += (asset.size + chunkSize - 1) / chunkSize
        }
        try Task.checkCancellation()
        let pack = OfflineVoicePack.zipvoice
        if pack.isInstalled { return }
        if manager.fileExists(atPath: pack.directory.path) { try manager.removeItem(at: pack.directory) }
        try manager.moveItem(at: stage, to: pack.directory)
    }
}
