import SwiftUI
import UniformTypeIdentifiers

struct LibraryBackupView: View {
    private var library = BackupLibraries()
    @State private var picking = false
    @State private var exporting = false
    @State private var working = false
    @State private var document: BackupJSONDocument?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button { export() } label: { Label("导出备份 JSON", systemImage: "square.and.arrow.up") }
                Button { picking = true } label: { Label("导入 JSON 文件", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("一个备份包含书架、文件管理中的 TXT 和 EPUB 原文件、阅读进度、书签、书源、网站源、收藏、规则，以及阅读、听书、网络与缓存设置。也可从“文件”或分享菜单用喵阅打开 JSON。")
            }
            Section {
                Text("备份包含阅读记录、请求头和服务器配置，分享前请留意其中的账号或密钥。下载的章节正文不随备份导出。网站登录会话须重新登录，离线语音包须重新下载。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if working { ProgressView("正在生成备份…") }
            if let message { Text(message) }
        }
        .navigationTitle("数据备份与恢复")
        .disabled(working)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                let files = urls.map(SourceImportFile.init)
                Task { await library.sources.previewPickedFiles(files) }
            case .failure(let error): if !Self.cancelled(error) { message = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "喵阅备份-" + Date().formatted(.iso8601.year().month().day())) { result in
            document = nil
            switch result {
            case .success(let url): message = "已导出 " + url.lastPathComponent
            case .failure(let error): if !Self.cancelled(error) { message = error.localizedDescription }
            }
        }
    }

    private static func cancelled(_ error: Error) -> Bool { (error as? CocoaError)?.code == .userCancelled }

    private func export() {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await library.waitForSavedChanges()
                let data = try await Task.detached(priority: .userInitiated) {
                    let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
                    return try await database.makeBackup().encoded()
                }.value
                document = .init(data: data)
                exporting = true
            } catch { message = "备份失败：" + error.localizedDescription }
        }
    }
}

private struct BackupJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupRestoreView: View {
    let backup: LibraryBackup
    private var library = BackupLibraries()
    @State private var saving = false
    @State private var errorMessage: String?

    init(backup: LibraryBackup) { self.backup = backup }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section("备份内容") {
                    ReadingLabeledContent("备份时间", value: backup.createdAt.formatted())
                    ReadingLabeledContent("书架书籍", value: String(backup.shelf.books.count))
                    ReadingLabeledContent("本地原文件", value: String(backup.shelf.localFiles.count))
                    ReadingLabeledContent("书源", value: String(backup.bookSources.count))
                    ReadingLabeledContent("网站源", value: String(backup.websiteSources.count))
                    ReadingLabeledContent("书签", value: String(backup.bookmarks.count))
                    ReadingLabeledContent("网站收藏", value: String(backup.websiteFavorites.count))
                }
                Section {
                    DisclosureGroup("网络与缓存设置") {
                        let settings = backup.settings
                        ReadingLabeledContent("User-Agent", value: settings.userAgent.isEmpty ? "默认" : settings.userAgent)
                        ReadingLabeledContent("全局代理", value: settings.proxy.isEmpty ? "未设置" : settings.proxy)
                        ReadingLabeledContent("自定义 Hosts", value: settings.hosts.isEmpty ? "未设置" : settings.hosts)
                        ReadingLabeledContent("请求超时", value: settings.timeoutSeconds == 0 ? "跟随书源" : "\(settings.timeoutSeconds) 秒")
                        ReadingLabeledContent("搜索并发数", value: String(settings.concurrentSources))
                        ReadingLabeledContent("兼容无效证书的书源", value: settings.ignoreCertificateErrors ? "开启" : "关闭")
                        ReadingLabeledContent("章节缓存上限", value: "\(settings.chapterCacheMB) MB")
                        ReadingLabeledContent("自动预读", value: settings.prefetchChapters == 0 ? "关闭" : "前后各 \(settings.prefetchChapters) 章")
                    }
                }
                Section {
                    Button("恢复此备份", role: .destructive) { restore() }
                } footer: {
                    Text("恢复会用备份覆盖当前书架、源、收藏、规则、记录及设置。同名本地书籍文件将使用备份版本。")
                }
                if saving { ProgressView("正在恢复…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .disabled(saving)
            .navigationTitle("恢复喵阅备份")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { library.sources.cancelPendingImport() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
        }
    }

    private func restore() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await library.waitForSavedChanges()
                let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
                try await database.restoreBackup(backup)
                await library.reload()
                var detail = "已恢复书架、书源、网站源和设置。"
                do { try await ChapterContentCache.live().pruneIfNeeded() }
                catch { detail += "章节缓存清理失败：" + error.localizedDescription }
                library.sources.notice = .init(kind: .success, title: "备份已恢复", detail: detail)
                library.sources.cancelPendingImport()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

@MainActor
private struct BackupLibraries: DynamicProperty {
    @EnvironmentObject var sources: SourceLibraryModel
    @EnvironmentObject var books: BookLibraryModel
    @EnvironmentObject var activity: ReadingActivityModel
    @EnvironmentObject var websites: RSSLibraryModel
    @EnvironmentObject var rules: ReplaceRuleLibraryModel
    @EnvironmentObject var subscriptions: RuleSubscriptionModel

    func waitForSavedChanges() async throws {
        try await books.waitForBackupSnapshot()
        try await sources.waitForPendingSave()
        try await rules.waitForPendingSave()
        await activity.waitForPendingSaves()
        try await subscriptions.waitForBackupSnapshot()
        guard !websites.isWorking else { throw BackupError.invalid("网站数据正在更新，请稍后再试。") }
    }

    func reload() async {
        await sources.load(force: true)
        await books.reloadAfterBackup()
        await activity.load()
        await websites.reloadAfterBackup()
        await rules.load()
        await subscriptions.reloadAfterBackup()
    }
}
