import SwiftUI
import UniformTypeIdentifiers

struct ReplaceRuleManagementView: View {
    @EnvironmentObject private var library: ReplaceRuleLibraryModel
    @State private var showsImporter = false
    @State private var showsTextImporter = false
    @State private var importResult: ReplaceRuleLibraryModel.Notice?
    @State private var showsQRImporter = false
    @State private var editingRule: ReplaceRule?
    @State private var startsWithTest = false
    @State private var query = ""
    @State private var group: String?

    private var filtered: [ReplaceRule] {
        library.rules.filter { rule in
            (group == nil || rule.group == group) && (query.isEmpty || rule.name.localizedCaseInsensitiveContains(query)
                || rule.pattern.localizedCaseInsensitiveContains(query) || (rule.group?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    var body: some View {
        Group {
            if library.rules.isEmpty {
                ReadingIllustratedEmptyState(artwork: "StatisticsBookArtwork", title: "还没有净化规则",
                                             message: "用规则替换文字，或移除正文中的干扰内容。") {
                    Button { edit(library.newRule()) } label: {
                        Label("新建规则", systemImage: "plus").managementPrimaryAction()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)
                    Menu {
                        importActions
                    } label: {
                        Text("导入已有规则").font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                }
            } else {
                List {
                    Section {
                        Picker("分组", selection: $group) {
                            Text("全部").tag(String?.none)
                            ForEach(Array(Set(library.rules.compactMap(\.group))).sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    .listRowBackground(ReadingTheme.surface)
                    Section {
                        ForEach(filtered) { rule in
                            HStack(spacing: 12) {
                                Button { edit(rule) } label: {
                                    HStack(spacing: 12) {
                                        ManagementRowIcon(systemName: rule.isRegex ? "chevron.left.forwardslash.chevron.right" : "textformat", active: rule.isEnabled)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(rule.name.isEmpty ? rule.pattern : rule.name)
                                                .font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                            Text(rule.group ?? (rule.scopeTitle && rule.scopeContent ? "标题与正文" : rule.scopeTitle ? "标题" : "正文"))
                                                .font(.caption).foregroundStyle(.secondary)
                                            if !rule.name.isEmpty {
                                                Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Toggle("启用", isOn: Binding(get: { rule.isEnabled }, set: { value in Task { await library.setEnabled(value, for: rule.id) } }))
                                    .labelsHidden().accessibilityLabel("启用\(rule.name)")
                            }
                            .padding(.vertical, 4)
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { edit(rule) }
                                Button("测试", systemImage: "play") { edit(rule, test: true) }
                                Button("复制", systemImage: "doc.on.doc") { edit(library.newRule(copying: rule)) }
                                Button("删除", systemImage: "trash", role: .destructive) { Task { await library.remove(id: rule.id) } }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.compactMap { filtered.indices.contains($0) ? filtered[$0].id : nil }
                            Task { for id in ids { await library.remove(id: id) } }
                        }
                        .onMove { offsets, destination in Task { await library.move(from: offsets, to: destination) } }
                        .moveDisabled(group != nil || !query.isEmpty)
                        if filtered.isEmpty {
                            Text("没有符合筛选条件的规则").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("规则 · \(filtered.count)").textCase(nil)
                    } footer: { Text("共 \(library.rules.count) 条，已启用 \(library.rules.filter(\.isEnabled).count) 条。长按规则可复制或测试，拖动排序决定执行顺序。") }
                    .listRowBackground(ReadingTheme.surface)
                }
                .readingManagementList()
                .searchable(text: $query, prompt: "名称、匹配内容或分组")
            }
        }
        .background(ReadingTheme.managementCanvas)
        .navigationTitle("净化规则")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !library.rules.isEmpty { EditButton().disabled(group != nil || !query.isEmpty) }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("更多", systemImage: "ellipsis") {
                    Button("新建规则", systemImage: "plus") { edit(library.newRule()) }
                    importActions
                    ReadingShareLink(item: exportJSON) { Label("导出全部规则", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $editingRule) { ReplaceRuleEditorView(rule: $0, startsWithTest: startsWithTest).environmentObject(library) }
        .qrCodeImportSheet(isPresented: $showsQRImporter) { value in
            Task { await library.importText(value) }
        }
        .sheet(isPresented: $showsTextImporter, onDismiss: {
            if let importResult {
                library.notice = importResult
                self.importResult = nil
            }
        }) {
            ReplaceRuleTextImportView { importResult = $0 }.environmentObject(library)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await library.importFiles(urls) }
            case .failure(let error): library.notice = .init(kind: .error, title: "无法选择文件", detail: error.localizedDescription)
            }
        }
        .alert(item: $library.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.detail), dismissButton: .default(Text("好")))
        }
    }
    @ViewBuilder private var importActions: some View {
        Button("从文件导入", systemImage: "doc.badge.plus") { showsImporter = true }
        Button("URL 或粘贴 JSON", systemImage: "link.badge.plus") { showsTextImporter = true }
        Button("二维码导入", systemImage: "qrcode.viewfinder") { showsQRImporter = true }
    }

    private func edit(_ rule: ReplaceRule, test: Bool = false) { startsWithTest = test; editingRule = rule }
    private var exportJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(library.rules)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

private struct ReplaceRuleTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: ReplaceRuleLibraryModel
    let onImport: (ReplaceRuleLibraryModel.Notice) -> Void
    @State private var value = ""
    @State private var importing = false
    @State private var errorMessage: String?
    var body: some View {
        ReadingNavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("粘贴净化规则 JSON、HTTP(S) 链接或 Legado 净化规则深链。").font(.footnote).foregroundStyle(.secondary)
                SyntaxCodeEditor(text: $value, language: .json)
            }.padding()
            .readingSheetTitle("导入净化规则")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton("导入", busyTitle: "导入中", isWorking: importing) {
                        importing = true
                        Task {
                            defer { importing = false }
                            do {
                                let result = try await library.importTextReportingResult(value)
                                onImport(result)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .disabled(importing)
        .interactiveDismissDisabled(importing)
        .alert("净化规则导入失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}
