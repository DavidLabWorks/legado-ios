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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                exportCard
                if let message { Text(message).font(.callout).textSelection(.enabled) }

                Text("备份范围").font(.headline).accessibilityAddTraits(.isHeader)
                ReadingSoftCard {
                    VStack(spacing: 0) {
                        backupRow("书架与本地书", "书架分组、TXT 和 EPUB 原文件", icon: "book")
                        Divider()
                        backupRow("阅读记录", "阅读进度、书签与网站收藏", icon: "bookmark")
                        Divider()
                        backupRow("源、规则与偏好", "书源、网站源、规则及阅读、听书与网络设置", icon: "slider.horizontal.3")
                    }
                }

                Text("恢复备份").font(.headline).accessibilityAddTraits(.isHeader)
                ReadingSoftCard {
                    Button { picking = true } label: {
                        HStack {
                            backupRow("选择备份文件", "恢复前可预览备份内容", icon: "square.and.arrow.down")
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                .padding(.trailing, 16)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("导入 JSON 文件")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("备份可能包含请求头与服务器配置中的账号或密钥，分享前请检查。", systemImage: "lock.shield")
                    Text("章节缓存和离线语音包需重新下载，网站需重新登录。也可从“文件”或分享菜单打开备份 JSON。")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity)
        .background(ReadingTheme.canvas)
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.large)
        .disabled(working)
        .modifier(JSONImportPicker(isPresented: $picking))
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "喵阅备份-" + Date().formatted(.iso8601.year().month().day())) { result in
            document = nil
            switch result {
            case .success(let url): message = "已导出 " + url.lastPathComponent
            case .failure(let error): if !Self.cancelled(error) { message = error.localizedDescription }
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本机资料").font(.caption)
                    Text("导出阅读备份").font(.system(.title2, design: .serif).bold())
                    Text("书架、原文件与阅读设置").font(.subheadline)
                }
                Spacer(minLength: 0)
                Image("StatisticsBookArtwork").resizable().scaledToFit()
                    .frame(maxWidth: 96, maxHeight: 74).accessibilityHidden(true)
            }
            if working {
                RagdollLoading("正在生成备份…")
            } else {
                Button(action: export) {
                    Label("导出 JSON 文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .readingProminentButtonStyle()
                .accessibilityIdentifier("导出备份 JSON")
            }
        }
        .padding(16)
        .foregroundStyle(.primary)
        .background(colorScheme == .dark ? ReadingTheme.surface : ReadingTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }

    private func backupRow(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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
                if saving { RagdollLoading("正在恢复…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .disabled(saving)
            .readingSheetTitle("恢复喵阅备份")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { library.sources.cancelPendingImport() }.disabled(saving)
                }
            }
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
