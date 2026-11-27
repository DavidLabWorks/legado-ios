import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogView: View {
    @State private var recording = ApplicationSettingsStore.shared.settings.recordLog
    @State private var entries: [DiagnosticLogEntry] = []
    @State private var query = ""
    @State private var level = "all"
    @State private var confirmsClear = false
    @State private var exportsLog = false
    @State private var exportText = ""
    @State private var errorMessage: String?

    private var filtered: [DiagnosticLogEntry] {
        entries.filter {
            (level == "all" || $0.level.rawValue == level)
                && (query.isEmpty || "\($0.category) \($0.message)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let matches = filtered
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("记录运行日志", isOn: Binding(get: { recording }, set: { updateRecording($0) }))
                        .font(.headline)
                    Text("日志仅存本机，最多 500 条。网络日志省略请求正文和 Header，隐藏 URL 查询参数和常见凭据。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                if !entries.isEmpty {
                    VStack(spacing: 0) {
                        ReadingPillSearchField(placeholder: "搜索内容或分类", text: $query)
                        Picker("级别", selection: $level) {
                            Text("全部").tag("all")
                            ForEach(DiagnosticLogEntry.Level.allCases, id: \.self) { level in
                                Text(levelTitle(level)).tag(level.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                    .listRowInsets(EdgeInsets())
                }
            }
            .listRowBackground(ReadingTheme.surface)
            if matches.isEmpty {
                ReadingUnavailableView {
                    Label(entries.isEmpty ? "暂无日志" : "没有匹配的日志",
                          systemImage: entries.isEmpty ? "doc.text" : "magnifyingglass")
                } description: {
                    if entries.isEmpty {
                        Text(recording
                             ? "网络请求、JS 输出和运行错误将显示在这里。"
                             : "开启上方的“记录运行日志”后，可在这里查看请求和运行错误。")
                    } else {
                        Text("试试其他关键词或日志级别。")
                    }
                } actions: {
                    if !entries.isEmpty {
                        Button("清除筛选") {
                            query = ""
                            level = "all"
                        }
                    }
                }
                .padding(.vertical, 32)
                .listRowBackground(ReadingTheme.settingsCanvas)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(matches) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                levelLabel(entry.level)
                                    .font(.caption.weight(.semibold))
                                Text(entry.category).font(.subheadline.weight(.semibold))
                            }
                            Text(entry.message)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                    .listRowBackground(ReadingTheme.surface)
                } header: {
                    Text(matches.count == entries.count ? "共 \(entries.count) 条日志" : "显示 \(matches.count) 条 · 共 \(entries.count) 条")
                        .textCase(nil)
                } footer: {
                    Text("崩溃诊断由 iOS 延迟提供，可搜索“系统诊断”查看。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .readingScrollContentBackgroundHidden()
        .readingScrollDismissesKeyboard()
        .refreshable { reload() }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle("日志与诊断")
        .onAppear {
            recording = ApplicationSettingsStore.shared.settings.recordLog
            reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("日志操作", systemImage: "ellipsis") {
                    Button("刷新", systemImage: "arrow.clockwise") { reload() }
                    Button("导出全部日志", systemImage: "square.and.arrow.up") {
                        exportText = DiagnosticLog.shared.export()
                        exportsLog = true
                    }.disabled(entries.isEmpty)
                    Button("清空日志", systemImage: "trash", role: .destructive) { confirmsClear = true }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .alert("清空全部日志？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空日志", role: .destructive) {
                do { try DiagnosticLog.shared.clear(); reload() }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exportsLog, document: DiagnosticLogDocument(text: exportText), contentType: .plainText, defaultFilename: "阅读诊断日志") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("日志操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func updateRecording(_ enabled: Bool) {
        let store = ApplicationSettingsStore.shared
        var settings = store.settings
        settings.recordLog = enabled
        do {
            try store.save(settings)
            recording = enabled
            if enabled { DiagnosticLog.shared.record(category: "诊断", message: "已开启运行日志") }
            reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func reload() { entries = DiagnosticLog.shared.snapshot() }
    @ViewBuilder private func levelLabel(_ level: DiagnosticLogEntry.Level) -> some View {
        switch level {
        case .info: Label(levelTitle(level), systemImage: "info.circle").foregroundStyle(.secondary)
        case .warning: Label(levelTitle(level), systemImage: "exclamationmark.triangle").foregroundStyle(ReadingTheme.ink)
        case .error: Label(levelTitle(level), systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func levelTitle(_ level: DiagnosticLogEntry.Level) -> String {
        switch level { case .info: "信息"; case .warning: "警告"; case .error: "错误" }
    }
}

private struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: Data(text.utf8)) }
}
