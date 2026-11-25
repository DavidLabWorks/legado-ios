import CryptoKit
import Foundation
import ZIPFoundation

enum OfflineVoicePack: String, CaseIterable, Identifiable, Sendable {
    case high, medium, compact
    var id: Self { self }
    static let preferenceKey = "offlineVoicePack.v1"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineSpeech/v1", isDirectory: true)
    }
    var directory: URL { Self.root.appendingPathComponent(rawValue, isDirectory: true) }
    var title: String {
        switch self {
        case .high: "高质量"
        case .medium: "中等"
        case .compact: "精简"
        }
    }
    var downloadSize: Int64 {
        switch self {
        case .high: 1_262_405_474
        case .medium: 700_779_921
        case .compact: 596_147_583
        }
    }
    private var files: [(name: String, bytes: Int, sha256: String)] {
        switch self {
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
    var isInstalled: Bool {
        files.allSatisfy { file in
            (try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == file.bytes
        }
    }
    static var selected: Self? {
        guard let value = UserDefaults.standard.string(forKey: preferenceKey),
              let pack = Self(rawValue: value), pack.isInstalled else { return nil }
        return pack
    }
    static let partSize: Int64 = 48_000_000
    var partsDirectory: URL {
        URL(string: "https://raw.githubusercontent.com/DavidLabWorks/legado-ios/main/OfflineVoicePacks/v1/")!
            .appendingPathComponent(rawValue)
    }

    // Validate in a separate directory so an interruption never exposes a partial pack to the reader.
    func install(archive url: URL) throws {
        let manager = FileManager.default
        if isInstalled { return }
        let archive = try Archive(url: url, accessMode: .read)
        var root = Self.root
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try root.setResourceValues(flags)
        let stage = root.appendingPathComponent(".install-" + UUID().uuidString)
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
            case .invalid: "语音包校验失败，请选择对应档位的完整 ZIP 文件。"
            case .unavailable: "仓库中的语音包暂时无法下载。可以重试，或从文件导入该档位的 ZIP。"
            }
        }
    }
}
