import SwiftUI
import UniformTypeIdentifiers

private final class PackDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}

@MainActor
private final class VoicePackDownloads: ObservableObject {
    static let shared = VoicePackDownloads()
    @Published var busy: OfflineVoicePack?
    @Published var progress: Double?
    @Published var installing = false
    @Published var message: String?
    private var task: Task<Void, Never>?

    init() {
        let root = OfflineVoicePack.root
        for item in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.hasPrefix(".install-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func start(_ pack: OfflineVoicePack, imported: URL? = nil) {
        guard busy == nil else { return }
        busy = pack
        progress = nil
        message = nil
        installing = false
        task = Task {
            defer { busy = nil; task = nil }
            do {
                if let imported {
                    let scoped = imported.startAccessingSecurityScopedResource()
                    defer { if scoped { imported.stopAccessingSecurityScopedResource() } }
                    try await install(pack, from: imported)
                } else {
                    let url = try await download(pack)
                    defer { try? FileManager.default.removeItem(at: url) }
                    try await install(pack, from: url)
                }
                activate(pack)
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func download(_ pack: OfflineVoicePack) async throws -> URL {
        try await Self.fetchParts(pack) { fraction in
            Task { @MainActor [weak self] in
                guard let self, self.busy == pack, !self.installing else { return }
                if fraction - (self.progress ?? -1) >= 0.005 { self.progress = fraction }
            }
        }
    }

    private nonisolated static func fetchParts(_ pack: OfflineVoicePack, report: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let manager = FileManager.default
        let output = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try Data().write(to: output)
        do {
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            for offset in stride(from: Int64(0), to: pack.downloadSize, by: Int(OfflineVoicePack.partSize)) {
                try Task.checkCancellation()
                let count = min(OfflineVoicePack.partSize, pack.downloadSize - offset)
                let name = String(format: "part-%02d", Int(offset / OfflineVoicePack.partSize))
                let url = pack.partsDirectory.appendingPathComponent(name)
                let observer = PackDownloadProgress { fraction in
                    report((Double(offset) + fraction * Double(count)) / Double(pack.downloadSize))
                }
                let (part, response) = try await URLSession.shared.download(from: url, delegate: observer)
                defer { try? manager.removeItem(at: part) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      (try part.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(count) else {
                    throw OfflineVoicePack.PackError.unavailable
                }
                let reader = try FileHandle(forReadingFrom: part)
                defer { try? reader.close() }
                while let buffer = try reader.read(upToCount: 1 << 20), !buffer.isEmpty {
                    try Task.checkCancellation()
                    try writer.write(contentsOf: buffer)
                }
            }
            try writer.synchronize()
            return output
        } catch {
            try? manager.removeItem(at: output)
            throw error
        }
    }

    private func install(_ pack: OfflineVoicePack, from file: URL) async throws {
        installing = true
        let work = Task.detached(priority: .utility) { try pack.install(archive: file) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func cancel() { task?.cancel() }

    func activate(_ pack: OfflineVoicePack) {
        let defaults = UserDefaults.standard
        defaults.set(pack.rawValue, forKey: OfflineVoicePack.preferenceKey)
        if defaults.string(forKey: "appTtsEngine") == nil {
            defaults.set(OfflineVoice.uncleFu.rawValue, forKey: "appTtsEngine")
        }
        // Persist the selection even when an installer terminates the app immediately afterward.
        defaults.synchronize()
    }
}

struct OfflineVoicePackView: View {
    @ObservedObject private var downloads = VoicePackDownloads.shared
    @AppStorage(OfflineVoicePack.preferenceKey) private var selected = ""
    @State private var importPack: OfflineVoicePack?
    @State private var showsImporter = false

    var body: some View {
        List {
            Section {
                ForEach(OfflineVoicePack.allCases) { pack in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(pack.title)
                            Spacer()
                            if pack.isInstalled {
                                if selected == pack.rawValue {
                                    Label("使用中", systemImage: "checkmark").foregroundStyle(.secondary)
                                } else {
                                    Button("使用") { downloads.activate(pack) }.disabled(downloads.busy != nil)
                                }
                            } else {
                                Text(ByteCountFormatter.string(fromByteCount: pack.downloadSize, countStyle: .decimal))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if downloads.busy == pack {
                            if downloads.installing { ProgressView("正在校验并安装…") }
                            else if let value = downloads.progress { ProgressView(value: value) }
                            else { ProgressView("正在连接…") }
                            Button("取消") { downloads.cancel() }
                        } else if !pack.isInstalled {
                            HStack(spacing: 24) {
                                Button("下载") { downloads.start(pack) }
                                Button("从文件导入") { importPack = pack; showsImporter = true }
                            }.disabled(downloads.busy != nil)
                        }
                    }.buttonStyle(.borderless).padding(.vertical, 4)
                }
            } footer: {
                Text("任选一档即可使用 Uncle_Fu 男声、Serena 和 Vivian 女声。安装后可离线朗读，覆盖更新 App 会保留语音包。")
            }
            if let message = downloads.message { Text(message).foregroundStyle(.red) }
        }
        .navigationTitle("离线语音包")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.zip]) { result in
            guard let pack = importPack else { return }
            do { downloads.start(pack, imported: try result.get()) }
            catch { downloads.message = error.localizedDescription }
        }
    }
}
