import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TxtTocRuleManagementModel: ObservableObject {
    @Published private(set) var rules: [TxtTocRule] = []
    @Published var message: String?
    private let repository: SQLiteConfigurationRepository?
    private var persistedRules: [TxtTocRule] = []
    private var pendingSave: Task<Void, Error>?
    private var saveGeneration = 0

    init() {
        repository = (try? LegadoDatabase(url: LegadoDatabase.defaultURL())).map {
            SQLiteConfigurationRepository(database: $0)
        }
    }

    func load() async {
        guard let repository else { message = "无法打开目录规则数据库"; return }
        let generation = saveGeneration
        do {
            let stored = try await repository.loadTxtTocRules(initialDefaults: TxtTocRuleDefaults.load())
            if generation == saveGeneration, pendingSave == nil {
                rules = stored
                persistedRules = stored
            }
        }
        catch { message = error.localizedDescription }
    }

    func importDefaults(report: Bool = true) async {
        let defaults = TxtTocRuleDefaults.load()
        guard !defaults.isEmpty else { message = "应用内置目录规则缺失"; return }
        var updated = rules.filter { $0.id >= 0 }
        updated.append(contentsOf: defaults)
        if await persist(updated), report { message = "已恢复内置目录规则" }
    }

    func save(_ rule: TxtTocRule) async -> Bool {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rule.rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.id == -100 else {
            message = "名称和正则不能为空"
            return false
        }
        guard rule.rule.isEmpty || (try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines)) != nil else {
            message = "目录正则语法错误"
            return false
        }
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) { updated[index] = rule }
        else { var value = rule; value.serialNumber = (updated.map(\.serialNumber).max() ?? 0) + 1; updated.append(value) }
        return await persist(updated)
    }

    func setEnabled(_ enabled: Bool, for rule: TxtTocRule) async {
        guard var value = rules.first(where: { $0.id == rule.id }), value.enable != enabled else { return }
        value.enable = enabled
        _ = await save(value)
    }

    func remove(at offsets: IndexSet) async {
        _ = await persist(rules.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        var updated = rules
        updated.move(fromOffsets: offsets, toOffset: destination)
        for index in updated.indices { updated[index].serialNumber = index + 1 }
        _ = await persist(updated)
    }

    func importData(_ data: Data) async {
        do {
            let decoded: [TxtTocRule]
            if let values = try? JSONDecoder().decode([TxtTocRule].self, from: data) { decoded = values }
            else { decoded = [try JSONDecoder().decode(TxtTocRule.self, from: data)] }
            try await importRules(decoded)
            message = "已导入 \(decoded.count) 条目录规则"
        } catch { message = error.localizedDescription }
    }

    func importRules(_ incoming: [TxtTocRule]) async throws {
        guard let repository else { throw LegadoDatabaseError.open("无法打开目录规则数据库") }
        let generation = saveGeneration
        let stored = try await repository.loadTxtTocRules(initialDefaults: TxtTocRuleDefaults.load())
        var merged = rules
        if generation == saveGeneration, pendingSave == nil {
            persistedRules = stored
            merged = stored
        }
        for value in incoming {
            if let index = merged.firstIndex(where: { $0.id == value.id }) { merged[index] = value }
            else { merged.append(value) }
        }
        for index in merged.indices { merged[index].serialNumber = index + 1 }
        try await write(merged, to: repository)
    }

    private func persist(_ values: [TxtTocRule]) async -> Bool {
        guard let repository else { message = "无法打开目录规则数据库"; return false }
        do {
            try await write(values, to: repository)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    private func write(_ values: [TxtTocRule], to repository: SQLiteConfigurationRepository) async throws {
        // Switches can change in quick succession. Each snapshot includes the previous tap.
        let updated = values.sorted { ($0.serialNumber, $0.id) < ($1.serialNumber, $1.id) }
        rules = updated
        saveGeneration += 1
        let generation = saveGeneration
        let previous = pendingSave
        let write = Task {
            _ = await previous?.result
            try await repository.saveTxtTocRules(updated)
            persistedRules = updated
        }
        pendingSave = write
        defer { if generation == saveGeneration { pendingSave = nil } }
        do {
            try await write.value
        } catch {
            if generation == saveGeneration { rules = persistedRules }
            throw error
        }
    }
}

struct TxtTocRuleManagementView: View {
    @StateObject private var model = TxtTocRuleManagementModel()
    @State private var editing: TxtTocRule?
    @State private var importing = false
    @State private var exporting = false
    @State private var editMode = EditMode.inactive

    var body: some View {
        Group {
            if model.rules.isEmpty {
                ReadingIllustratedEmptyState(artwork: "SourceEmptyArtwork", title: "没有TXT目录规则",
                                             message: "添加分章规则，或从更多菜单恢复内置规则。") {
                    Button("新建规则") { editing = TxtTocRule() }
                        .readingProminentButtonStyle()
                        .padding(.top, 20)
                }
            } else {
                List {
                    Section {
                        ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                            HStack(spacing: 12) {
                                Button { editing = rule } label: {
                                    HStack(spacing: 12) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.subheadline.weight(.medium).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(rule.name).font(.body.weight(.semibold))
                                            if let example = rule.example, !example.isEmpty {
                                                Text(example).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                            } else if !rule.rule.isEmpty {
                                                Text(rule.rule).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("编辑目录规则")
                                Toggle("启用\(rule.name)", isOn: Binding(
                                    get: { rule.enable },
                                    set: { enabled in Task { await model.setEnabled(enabled, for: rule) } }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("启用\(rule.name)")
                            }
                            .padding(.vertical, 3)
                            .swipeActions(edge: .leading) {
                                Button(rule.enable ? "停用" : "启用") {
                                    Task { await model.setEnabled(!rule.enable, for: rule) }
                                }
                                .tint(rule.enable ? .orange : .green)
                            }
                        }
                        .onDelete { offsets in Task { await model.remove(at: offsets) } }
                        .onMove { offsets, destination in Task { await model.move(from: offsets, to: destination) } }
                    } header: {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("共 \(model.rules.count) 条规则 · 已启用 \(model.rules.filter(\.enable).count) 条")
                                .font(.subheadline).foregroundStyle(ReadingTheme.managementSecondary)
                            Text("识别顺序").font(.headline).foregroundStyle(ReadingTheme.ink)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .textCase(nil)
                        .padding(.bottom, 4)
                    }
                    .listRowBackground(ReadingTheme.surface)
                }
                .readingManagementList()
                .environment(\.editMode, $editMode)
            }
        }
        .background(ReadingTheme.managementCanvas)
        .navigationTitle("TXT 目录规则")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode.isEditing {
                    Button("完成") { withAnimation { editMode = .inactive } }
                } else {
                    Button("新建", systemImage: "plus") { editing = TxtTocRule() }
                }
                Menu {
                    Button("导入JSON", systemImage: "square.and.arrow.down") { importing = true }
                    Button("导出JSON", systemImage: "square.and.arrow.up") { exporting = true }
                        .disabled(model.rules.isEmpty)
                    Button("恢复内置规则", systemImage: "arrow.counterclockwise") {
                        Task { await model.importDefaults() }
                    }
                    Button(editMode.isEditing ? "完成排序" : "调整顺序", systemImage: "arrow.up.arrow.down") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .disabled(model.rules.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("更多")
            }
        }
        .task { await model.load() }
        .sheet(item: $editing) { value in
            TxtTocRuleEditView(value: value, saveError: $model.message) { await model.save($0) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { Task { await model.importData(data) } }
        }
        .fileExporter(
            isPresented: $exporting,
            document: TxtTocRuleDocument(rules: model.rules),
            contentType: .json,
            defaultFilename: "txtTocRules.json"
        ) { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
        .alert("TXT目录规则", isPresented: Binding(
            get: { editing == nil && model.message != nil },
            set: { if !$0, editing == nil { model.message = nil } }
        )) { Button("好") { model.message = nil } } message: { Text(model.message ?? "") }
    }
}

private struct TxtTocRuleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: TxtTocRule
    @State private var sample = ""
    @State private var testing = false
    @State private var editingSample = false
    @FocusState private var sampleFocused: Bool
    @State private var saving = false
    @Binding var saveError: String?
    let save: (TxtTocRule) async -> Bool

    init(value: TxtTocRule, saveError: Binding<String?>, save: @escaping (TxtTocRule) async -> Bool) {
        _value = State(initialValue: value)
        _sample = State(initialValue: value.example ?? "")
        _saveError = saveError
        self.save = save
    }

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                Picker("编辑模式", selection: $testing) {
                    Text("规则设置").tag(false)
                    Text("匹配测试").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20).padding(.vertical, 8)
                List {
                    if testing {
                        matchTest
                    } else {
                        Section("识别规则") {
                            TextField("名称", text: $value.name)
                            codeField("目录正则", text: $value.rule)
                            codeField("标题处理 JavaScript（可选）", text: $value.replacement)
                            Toggle("启用", isOn: $value.enable).tint(ReadingTheme.toggleTint)
                        }
                        .listRowBackground(ReadingTheme.surface)
                    }
                }
                .listStyle(.insetGrouped)
                .readingListTopMargin(8)
                .readingScrollContentBackgroundHidden()
            }
            .background(ReadingTheme.canvas)
            .readingSheetTitle("编辑目录规则")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton(isWorking: saving) {
                        value.example = sample.isEmpty ? nil : sample
                        saving = true
                        Task { if await save(value) { dismiss() }; saving = false }
                    }
                    .disabled(saving)
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(saveError ?? "") }
    }

    private func codeField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body.monospaced()).frame(height: 68)
                .textInputAutocapitalization(.never).disableAutocorrection(true)
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder private var matchTest: some View {
        let preview = TocMatchPreview(pattern: value.rule, sample: sample)
        Section("当前规则") {
            VStack(alignment: .leading, spacing: 10) {
                Label(value.name.isEmpty ? "未命名规则" : value.name, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption)
                Text(value.rule.isEmpty ? (value.id == -100 ? "默认分章" : "尚未填写目录正则") : value.rule)
                    .font(.subheadline.monospaced()).textSelection(.enabled)
            }
            .foregroundStyle(ReadingTheme.onAccent)
            .padding(.vertical, 4)
            .listRowBackground(ReadingTheme.emphasisSurface)
        }
        Section {
            if editingSample {
                TextEditor(text: $sample)
                    .font(.body.monospaced()).frame(minHeight: 130)
                    .accessibilityLabel("测试文本")
                    .focused($sampleFocused)
                    .onAppear { sampleFocused = true }
            } else {
                Button { editingSample = true } label: {
                    if sample.isEmpty {
                        Label("输入或粘贴测试文本", systemImage: "pencil")
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(preview.lines.indices, id: \.self) { index in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(verbatim: preview.lines[index]).font(.subheadline)
                                        .background(preview.highlighted.contains(index) ? ReadingTheme.coral.opacity(0.25) : .clear)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("编辑测试文本")
            }
        } header: {
            HStack {
                Text("测试文本")
                Spacer()
                Button(editingSample ? "完成编辑" : "编辑") { editingSample.toggle() }
                    .font(.subheadline)
            }
        }
        .listRowBackground(ReadingTheme.surface)
        Section {
            if let message = preview.message {
                Text(value.id == -100 && value.rule.isEmpty ? "默认分章规则没有可测试的正则。" : message)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(preview.matches.indices, id: \.self) { index in
                let match = preview.matches[index]
                ReadingLabeledContent(match.text.isEmpty ? "空匹配" : match.text, value: "第 \(match.line) 行")
                    .font(.subheadline).textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(match.text.isEmpty ? "空匹配" : match.text)
                    .accessibilityValue("第 \(match.line) 行")
            }
        } header: {
            HStack {
                Text("匹配结果")
                Spacer()
                if !preview.matches.isEmpty {
                    Text(preview.truncated ? "展示前 20 条" : "命中 \(preview.matches.count) 条")
                }
            }
        }
        .listRowBackground(ReadingTheme.surface)
    }
}

private struct TocMatchPreview {
    var lines: [String] = []
    var highlighted: Set<Int> = []
    var matches: [(line: Int, text: String)] = []
    var truncated = false
    var message: String?

    init(pattern: String, sample: String) {
        let text = sample as NSString
        var starts = [0]
        var offset = 0
        while offset < text.length {
            var next = 0
            var end = 0
            text.getLineStart(nil, end: &next, contentsEnd: &end, for: NSRange(location: offset, length: 0))
            lines.append(text.substring(with: NSRange(location: offset, length: end - offset)))
            if end < next { starts.append(next) }
            offset = next
        }
        if starts.count > lines.count { lines.append("") }
        guard !pattern.isEmpty else { message = "请先填写目录正则"; return }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            message = "正则语法错误"
            return
        }
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: sample, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            if let match { ranges.append(match.range) }
            if ranges.count > 20 { stop.pointee = true }
        }
        truncated = ranges.count > 20
        var line = 0
        for range in ranges.prefix(20) {
            while line + 1 < starts.count && starts[line + 1] <= range.location { line += 1 }
            matches.append((line + 1, text.substring(with: range)))
            highlighted.insert(line)
            while line + 1 < starts.count && starts[line + 1] < NSMaxRange(range) {
                line += 1
                highlighted.insert(line)
            }
        }
        if matches.isEmpty { message = sample.isEmpty ? "输入样文后可查看匹配结果" : "没有匹配" }
    }
}

private struct TxtTocRuleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let rules: [TxtTocRule]
    init(rules: [TxtTocRule]) { self.rules = rules }
    init(configuration: ReadConfiguration) throws { rules = [] }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(rules))
    }
}
