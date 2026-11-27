import SwiftUI
import UniformTypeIdentifiers

struct RSSSourceEditorView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @State private var isSaving = false
    @State private var choosingGroups = false
    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    @State private var showsExport = false
    @State private var exportError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RssSource
    private enum Detail: String, CaseIterable, Identifiable {
        case appearance = "图标与注释", request = "请求与登录", list = "分类与列表规则"
        case web = "WebView 规则", other = "其他设置"
        var id: Self { self }
        var icon: String {
            switch self {
            case .appearance: "slider.horizontal.3"
            case .request: "lock"
            case .list: "list.bullet"
            case .web: "chevron.left.forwardslash.chevron.right"
            case .other: "gearshape"
            }
        }
    }
    @State private var originalDetail: RssSource?
    @State private var detail: Detail?
    private let originalSource: RssSource?

    init(source: RssSource? = nil, initialGroup: String? = nil) {
        var value = source ?? RssSource()
        if source == nil { value.sourceGroup = BookSource.joinGroups([initialGroup ?? ""]) }
        _draft = State(initialValue: value)
        originalSource = source
    }

    var body: some View {
        List {
            sourceSummary
                .listRowBackground(ReadingTheme.surface)
            Section("基本信息") {
                basicField("名称", placeholder: "网站名称", text: $draft.sourceName)
                basicField("源地址", placeholder: "https://", text: $draft.sourceUrl)
                    .keyboardType(.URL)
                groupButton
                Toggle("启用此源", isOn: $draft.enabled).tint(ReadingTheme.toggleTint)
            }
            .listRowBackground(ReadingTheme.surface)
            Section("详细配置") {
                ForEach(Detail.allCases) { item in
                    Button { originalDetail = draft; detail = item } label: {
                        HStack {
                            Label(item.rawValue, systemImage: item.icon)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(ReadingTheme.surface)
            if let originalSource {
                Section {
                    Button(role: .destructive) { confirmsDeletion = true } label: {
                        Label("删除网站源", systemImage: "trash")
                    }
                    .alert("删除「\(originalSource.sourceName)」？", isPresented: $confirmsDeletion) {
                        Button("取消", role: .cancel) {}
                        Button("删除", role: .destructive) {
                            isDeleting = true
                            Task {
                                if await library.remove(originalSource) { dismiss() }
                                isDeleting = false
                            }
                        }
                    } message: {
                        Text("此网站源的文章缓存也会一并删除。")
                    }
                }
                .listRowBackground(ReadingTheme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .readingListTopMargin(8)
        .readingScrollContentBackgroundHidden()
        .background(ReadingTheme.canvas)
        .readingPageTitle(originalSource == nil ? "新建网站源" : "编辑网站源")
        .sheet(isPresented: $choosingGroups) {
            WebsiteGroupSelectionSheet(groups: library.groups, selected: draft.groups) { groups in
                draft.sourceGroup = BookSource.joinGroups(groups)
            }
        }
        .sheet(item: $detail, onDismiss: {
            if let originalDetail { draft = originalDetail; self.originalDetail = nil }
        }) { item in
            ReadingNavigationStack {
                ReadingSheetForm {
                    switch item {
                    case .appearance:
                        requiredField("图标", \.sourceIcon)
                        optionalField("注释", \.sourceComment, axis: .vertical)
                    case .request: requestFields
                    case .list: listFields
                    case .web: webFields
                    case .other: otherFields
                    }
                }
                .readingSheetTitle(item.rawValue)
                .toolbar {
                    ReadingSheetActions {
                        Button("取消") { detail = nil }
                        ReadingSheetActionButton { originalDetail = nil; detail = nil }
                    }
                }
            }
        }
        .fileExporter(isPresented: $showsExport, document: SourceExportDocument(sources: [draft]), contentType: .json,
                      defaultFilename: sourceExportFilename(draft.sourceName, fallback: "网站源")) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .toolbar {
            ReadingSheetActions {
                if detail == nil {
                    Button("导出") { showsExport = true }
                    ReadingSheetActionButton(isWorking: isSaving) {
                        isSaving = true
                        Task {
                            if await library.save(draft, replacing: originalSource?.sourceUrl) { dismiss() }
                            isSaving = false
                        }
                    }
                }
            }
        }
        .disabled(isSaving || isDeleting)
    }

    private var groupButton: some View {
        Button { choosingGroups = true } label: {
            HStack {
                Text("分组").foregroundStyle(ReadingTheme.ink)
                Spacer()
                Text(draft.groups.isEmpty ? "未分组" : draft.groups.joined(separator: "、"))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("websiteEditor.groups")
        .accessibilityLabel("分组")
        .accessibilityValue(draft.groups.isEmpty ? "未分组" : draft.groups.joined(separator: "、"))
    }

    private var sourceSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.title2).foregroundStyle(ReadingTheme.onAccent)
                .frame(width: 46, height: 46)
                .background(ReadingTheme.emphasisSurface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.sourceName.isEmpty ? "未命名网站源" : draft.sourceName).font(.headline)
                Text([draft.type == 1 ? "图片" : draft.type == 2 ? "视频" : "网页", draft.sourceGroup]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: draft.enabled ? "已启用" : "已停用",
                       color: draft.enabled ? .green : .secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func basicField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        ReadingLabeledContent(title) {
            TextField(placeholder, text: text)
                .accessibilityLabel(title).multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).disableAutocorrection(true)
        }
    }

    @ViewBuilder private var requestFields: some View {
        optionalField("自定义变量说明", \.variableComment, axis: .vertical)
        optionalField("JS库", \.jsLib, axis: .vertical)
        Toggle("自动保存Cookie", isOn: optionalBool(\.enabledCookieJar, default: true))
        optionalField("并发率", \.concurrentRate)
        optionalField("请求头", \.header, axis: .vertical)
        optionalField("登录地址", \.loginUrl)
        optionalField("登录UI", \.loginUi, axis: .vertical)
        optionalField("登录检测JS", \.loginCheckJs, axis: .vertical)
        optionalField("封面解密JS", \.coverDecodeJs, axis: .vertical)
    }

    @ViewBuilder private var listFields: some View {
        optionalField("分类URL（名称::URL）", \.sortUrl, axis: .vertical)
        Toggle("单URL源", isOn: $draft.singleUrl)
        Picker("列表样式", selection: $draft.articleStyle) { ForEach(0..<5, id: \.self) { Text("样式 \($0)").tag($0) } }
        optionalField("列表规则", \.ruleArticles, axis: .vertical)
        optionalField("下一页规则", \.ruleNextPage, axis: .vertical)
        optionalField("标题规则", \.ruleTitle, axis: .vertical)
        optionalField("发布日期规则", \.rulePubDate, axis: .vertical)
        optionalField("描述规则", \.ruleDescription, axis: .vertical)
        optionalField("图片规则", \.ruleImage, axis: .vertical)
        optionalField("链接规则", \.ruleLink, axis: .vertical)
        optionalField("正文规则", \.ruleContent, axis: .vertical)
    }

    @ViewBuilder private var webFields: some View {
        optionalField("正文URL白名单", \.contentWhitelist, axis: .vertical)
        optionalField("正文URL黑名单", \.contentBlacklist, axis: .vertical)
        optionalField("跳转URL拦截JS", \.shouldOverrideUrlLoading, axis: .vertical)
        optionalField("样式", \.style, axis: .vertical)
        Toggle("启用JavaScript", isOn: $draft.enableJs)
        Toggle("使用Base URL加载", isOn: $draft.loadWithBaseUrl)
        optionalField("注入JS", \.injectJs, axis: .vertical)
        optionalField("预注入JS", \.preloadJs, axis: .vertical)
        optionalField("起始HTML", \.startHtml, axis: .vertical)
        optionalField("起始样式", \.startStyle, axis: .vertical)
        optionalField("起始JS", \.startJs, axis: .vertical)
        Toggle("输出网页日志", isOn: $draft.showWebLog)
    }

    @ViewBuilder private var otherFields: some View {
        Stepper("自定义排序：\(draft.customOrder)", value: $draft.customOrder)
        Picker("类型", selection: $draft.type) { Text("网页").tag(0); Text("图片").tag(1); Text("视频").tag(2) }
        Toggle(isOn: $draft.preload) {
            VStack(alignment: .leading, spacing: 3) {
                Text("启用预加载")
                Text("提前加载下一页，关闭时滑到列表底部再加载。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle("优先加载缓存", isOn: $draft.cacheFirst)
        optionalField("搜索URL", \.searchUrl, axis: .vertical)
    }

    @ViewBuilder private func optionalField(_ title: String, _ keyPath: WritableKeyPath<RssSource, String?>, axis: Axis = .horizontal) -> some View {
        if axis == .vertical {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: optionalText(keyPath))
                    .font(.body.monospaced()).frame(height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ReadingTheme.separator))
                    .accessibilityLabel(title)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
            }
        } else {
            TextField(title, text: optionalText(keyPath)).textInputAutocapitalization(.never)
        }
    }
    @ViewBuilder private func requiredField(_ title: String, _ keyPath: WritableKeyPath<RssSource, String>, axis: Axis = .horizontal) -> some View {
        ReadingTextField(title, text: Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 }), axis: axis).textInputAutocapitalization(.never)
    }
    private func optionalText(_ keyPath: WritableKeyPath<RssSource, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    private func optionalBool(_ keyPath: WritableKeyPath<RssSource, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(get: { draft[keyPath: keyPath] ?? defaultValue }, set: { draft[keyPath: keyPath] = $0 })
    }
}

private struct WebsiteGroupSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String]
    @State private var selected: [String]
    @State private var creatingGroup = false
    let apply: ([String]) -> Void

    init(groups: [String], selected: [String], apply: @escaping ([String]) -> Void) {
        _choices = State(initialValue: groups + selected.filter { !groups.contains($0) })
        _selected = State(initialValue: selected)
        self.apply = apply
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Section {
                    WebsiteGroupChoice(group: "", isSelected: selected.isEmpty) { selected.removeAll() }
                    ForEach(choices, id: \.self) { group in
                        WebsiteGroupChoice(group: group, isSelected: selected.contains(group)) {
                            if selected.contains(group) { selected.removeAll { $0 == group } }
                            else { selected.append(group) }
                        }
                    }
                }
                Section {
                    Button("新建分组", systemImage: "folder.badge.plus") { creatingGroup = true }
                }
            }
            .readingSheetTitle("选择分组")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton("完成") { apply(selected); dismiss() }
                }
            }
            .sheet(isPresented: $creatingGroup) {
                WebsiteGroupNameSheet(original: nil, groups: choices) { name in
                    choices.append(name)
                    selected.append(name)
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }
}

struct WebsiteGroupNameSheet: View {
    let original: String?
    let groups: [String]
    let save: (String) async throws -> Void

    var body: some View {
        WebsiteNameSheet(title: original == nil ? "新建分组" : "重命名分组", field: "分组名称",
                         original: original ?? "", validate: { name in
            if BookSource.parseGroups(name) != [name] { return "组名中不能包含逗号或分号" }
            if ["全部", "全部分组", "未分组"].contains(name) { return "此名称已用于分组筛选" }
            if name != original && groups.contains(name) { return "已有同名分组" }
            return nil
        }, save: save)
    }
}

struct WebsiteNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let field: String
    let original: String
    let validate: (String) -> String?
    let save: (String) async throws -> Void
    @State private var name: String
    @State private var saving = false
    @State private var error: String?

    init(title: String, field: String, original: String, validate: @escaping (String) -> String? = { _ in nil },
         save: @escaping (String) async throws -> Void) {
        self.title = title
        self.field = field
        self.original = original
        self.validate = validate
        self.save = save
        _name = State(initialValue: original)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetForm {
                Section {
                    TextField(field, text: $name)
                } footer: {
                    if !trimmed.isEmpty, let message = validate(trimmed) { Text(message) }
                }
            }
            .readingSheetTitle(title)
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }.disabled(saving)
                    ReadingSheetActionButton(isWorking: saving) {
                        let value = trimmed
                        saving = true
                        Task {
                            do { try await save(value); dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(trimmed.isEmpty || validate(trimmed) != nil || trimmed == original || saving)
                }
            }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .readingPresentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
    }
}
