import SwiftUI

struct SourceManagementView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var showsImporter = false
    @State private var showsNewSource = false
    @State private var showsQRImporter = false
    @State private var showsTextImporter = false
    @State private var preparedImport: SourceLibraryModel.PendingImport?
    @State private var showsGroupManager = false
    @State private var showsBatchGroups = false
    @State private var selectedGroup: String?
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedSourceIDs = Set<String>()
    @State private var confirmsBatchDelete = false
    @AppStorage("bookSourceSort") private var sortMode = "manual"
    @AppStorage("bookSourceSortDescending") private var sortDescending = false

    private var filteredSources: [BookSource] {
        let filtered = library.sources.filter { source in
            let matchesGroup: Bool
            if let selectedGroup {
                matchesGroup = selectedGroup.isEmpty ? source.groups.isEmpty : source.hasGroup(selectedGroup)
            } else {
                matchesGroup = true
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesGroup && (query.isEmpty
                || source.bookSourceName.localizedCaseInsensitiveContains(query)
                || source.bookSourceUrl.localizedCaseInsensitiveContains(query)
                || source.groups.contains(where: { $0.localizedCaseInsensitiveContains(query) }))
        }
        guard sortMode != "manual" else { return filtered }
        return filtered.sorted { lhs, rhs in
            sortDescending ? isOrdered(rhs, before: lhs) : isOrdered(lhs, before: rhs)
        }
    }

    private func isOrdered(_ lhs: BookSource, before rhs: BookSource) -> Bool {
        switch sortMode {
        case "weight":
            return lhs.weight == rhs.weight ? lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending : lhs.weight < rhs.weight
        case "name": return lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending
        case "url": return lhs.bookSourceUrl.localizedStandardCompare(rhs.bookSourceUrl) == .orderedAscending
        case "update": return lhs.lastUpdateTime == rhs.lastUpdateTime ? lhs.bookSourceName < rhs.bookSourceName : lhs.lastUpdateTime > rhs.lastUpdateTime
        case "respond": return lhs.respondTime == rhs.respondTime ? lhs.bookSourceName < rhs.bookSourceName : lhs.respondTime < rhs.respondTime
        case "enabled": return lhs.enabled == rhs.enabled ? lhs.bookSourceName < rhs.bookSourceName : lhs.enabled && !rhs.enabled
        default: return lhs.customOrder < rhs.customOrder
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SourceManagementSearchHeader(total: library.sources.count, enabled: library.sources.filter(\.enabled).count,
                                         searchText: $searchText)
            if library.sources.isEmpty, !library.isWorking {
                ReadingIllustratedEmptyState(
                    artwork: "SourceEmptyArtwork",
                    title: "还没有书源",
                    message: "新建书源，或从文件、链接、JSON、二维码导入",
                    bottomBalance: 116
                ) {
                    Menu {
                        Button("新建书源", systemImage: "plus") { showsNewSource = true }
                        Button("从文件导入", systemImage: "doc.badge.plus") { showsImporter = true }
                        Button("URL 或粘贴 JSON", systemImage: "link.badge.plus") { showsTextImporter = true }
                        Button("二维码导入", systemImage: "qrcode.viewfinder") { showsQRImporter = true }
                    } label: {
                        Label("导入书源", systemImage: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 28)
                            .frame(minHeight: 38)
                            .foregroundStyle(ReadingTheme.onAccent)
                            .background(ReadingTheme.accentFill, in: Capsule())
                    }
                    .padding(.top, 26)
                    .accessibilityIdentifier("sources.import")
                }
            } else {
                List {
                    Section {
                        ForEach(filteredSources) { source in
                            if isSelecting {
                                Button {
                                    if !selectedSourceIDs.insert(source.id).inserted { selectedSourceIDs.remove(source.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedSourceIDs.contains(source.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selectedSourceIDs.contains(source.id) ? ReadingTheme.accent : .secondary)
                                        SourceRow(source: source, showsToggle: false) { _ in }
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    SourceDetailView(source: source)
                                } label: {
                                    SourceRow(source: source) { enabled in
                                        Task { await library.setEnabled(enabled, for: source.id) }
                                    }
                                }
                                .contextMenu {
                                    NavigationLink {
                                        SearchView(fixedSource: source)
                                    } label: {
                                        Label("搜索", systemImage: "magnifyingglass")
                                    }
                                    Button(source.enabledExplore ? "停用发现" : "启用发现", systemImage: "safari") {
                                        Task { await library.setExploreEnabled(!source.enabledExplore, for: source.id) }
                                    }
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        Task { await library.remove(sourceIDs: [source.id]) }
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { filteredSources.indices.contains($0) ? filteredSources[$0].id : nil })
                            Task { await library.remove(sourceIDs: ids) }
                        }
                        if filteredSources.isEmpty, !library.isWorking {
                            Text("未找到书源").foregroundStyle(.secondary)
                        }
                    } header: {
                        SourceGroupPicker(title: searchText.isEmpty && selectedGroup == nil ? "书源" : "书源 · \(filteredSources.count)",
                                          groups: library.groups, selection: $selectedGroup)
                    }
                    .listRowBackground(ReadingTheme.surface)
                }
                .readingManagementList()
                .overlay {
                    if library.isWorking { RagdollLoading() }
                }
            }
        }
        .readingPageTitle("书源管理")
        .background(ReadingTheme.settingsCanvas)
        .navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "完成" : "选择") {
                    isSelecting.toggle()
                    if !isSelecting { selectedSourceIDs.removeAll() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("更多", systemImage: "ellipsis") {
                    Button("新建书源", systemImage: "plus") { showsNewSource = true }
                    Button("二维码导入", systemImage: "qrcode.viewfinder") { showsQRImporter = true }
                    Button("从文件导入", systemImage: "doc.badge.plus") { showsImporter = true }
                    Button("URL 或粘贴 JSON", systemImage: "link.badge.plus") { showsTextImporter = true }
                    Divider()
                    NavigationLink {
                        SourceBatchTestView()
                    } label: {
                        Label("书源测试", systemImage: "checkmark.circle.badge.questionmark")
                    }
                    Button("管理分组", systemImage: "folder.badge.gearshape") { showsGroupManager = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("排序", systemImage: "arrow.up.arrow.down") {
                    Toggle("倒序", isOn: $sortDescending)
                    Picker("排序方式", selection: $sortMode) {
                        Text("手动排序").tag("manual")
                        Text("自动排序").tag("weight")
                        Text("按名称").tag("name")
                        Text("按网址").tag("url")
                        Text("按更新时间").tag("update")
                        Text("按响应时间").tag("respond")
                        Text("按启用状态").tag("enabled")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack(spacing: 12) {
                    Button(selectedSourceIDs.count == filteredSources.count ? "取消全选" : "全选") {
                        if selectedSourceIDs.count == filteredSources.count { selectedSourceIDs.removeAll() }
                        else { selectedSourceIDs = Set(filteredSources.map(\.id)) }
                    }
                    Spacer()
                    Button("分组", systemImage: "folder") { showsBatchGroups = true }
                        .disabled(selectedSourceIDs.isEmpty)
                    Button("启用", systemImage: "checkmark.circle") {
                        Task { await library.setEnabled(true, for: selectedSourceIDs) }
                    }
                    .disabled(selectedSourceIDs.isEmpty)
                    Button("停用", systemImage: "pause.circle") {
                        Task { await library.setEnabled(false, for: selectedSourceIDs) }
                    }
                    .disabled(selectedSourceIDs.isEmpty)
                    Button("删除", systemImage: "trash", role: .destructive) { confirmsBatchDelete = true }
                        .disabled(selectedSourceIDs.isEmpty)
                }
                .labelStyle(.titleOnly)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .alert("删除所选书源？", isPresented: $confirmsBatchDelete) {
            Button("删除 \(selectedSourceIDs.count) 个", role: .destructive) {
                let ids = selectedSourceIDs
                selectedSourceIDs.removeAll()
                Task { await library.remove(sourceIDs: ids) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除已选的 \(selectedSourceIDs.count) 个书源，无法撤销。")
        }
        .sheet(isPresented: $showsNewSource) { SourceEditorView().environmentObject(library) }
        .qrCodeImportSheet(isPresented: $showsQRImporter) { value in
            Task { await library.previewInput(value) }
        }
        .sheet(isPresented: $showsTextImporter, onDismiss: {
            if let preparedImport {
                library.pendingImport = preparedImport
                self.preparedImport = nil
            }
        }) {
            SourceTextImportView { preparedImport = $0 }
                .environmentObject(library)
        }
        .sheet(isPresented: $showsGroupManager) {
            SourceGroupManagerView().environmentObject(library)
        }
        .sheet(isPresented: $showsBatchGroups) {
            SourceBatchGroupView(sourceIDs: selectedSourceIDs).environmentObject(library)
        }
        .modifier(JSONImportPicker(isPresented: $showsImporter))
    }
}

private struct SourceTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let onPreview: (SourceLibraryModel.PendingImport) -> Void
    @State private var preparing = false
    @State private var errorMessage: String?
    @State private var mode = 0
    @State private var value = ""

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetForm {
                Picker("导入方式", selection: $mode) {
                    Text("URL").tag(0)
                    Text("粘贴 JSON").tag(1)
                }
                .pickerStyle(.segmented)

                Section(mode == 0 ? "书源 URL" : "书源 JSON") {
                    if mode == 0 {
                        TextField("https://example.com/sources.json", text: $value)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    } else {
                        SyntaxCodeEditor(text: $value, language: .json)
                            .frame(minHeight: 220)
                    }
                }
                Section {
                    Text("导入前可预览并选择书源。地址相同的书源将被替换。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .readingSheetTitle("导入书源")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton("预检", busyTitle: "预检中", isWorking: preparing) {
                        preparing = true
                        Task {
                            defer { preparing = false }
                            do {
                                let review = try await library.preparePreview(value)
                                onPreview(review)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .disabled(preparing)
        .interactiveDismissDisabled(preparing)
        .alert("预检失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

private struct SourceRow: View {
    let source: BookSource
    var showsToggle = true
    let onEnabledChanged: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        SourceManagementRow(name: source.bookSourceName, url: source.bookSourceUrl, groups: source.groups,
                            enabled: source.enabled, showsToggle: showsToggle, onEnabledChanged: onEnabledChanged) {
            ManagementRowIcon(systemName: source.bookSourceType == 1 ? "headphones" : "book.closed", active: source.enabled)
        }
    }
}

private struct SourceGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var newGroup = ""
    @State private var renaming: String?
    @State private var renamedValue = ""

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Section("新建分组") {
                    HStack {
                        TextField("例如：文学", text: $newGroup)
                        Button("添加") {
                            let value = newGroup
                            let ungrouped = Set(library.sources.filter { $0.groups.isEmpty }.map(\.id))
                            Task {
                                if await library.addGroup(value, to: ungrouped), newGroup == value { newGroup = "" }
                            }
                        }
                        .disabled(BookSource.parseGroups(newGroup).isEmpty || !library.sources.contains { $0.groups.isEmpty })
                    }
                    Text("添加后，所有未分组的书源都会加入该分组。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(library.groups, id: \.self) { group in
                        HStack {
                            NavigationLink {
                                SourceGroupContentsView(group: group)
                            } label: {
                                HStack {
                                    Label(group, systemImage: "folder.fill")
                                    Spacer()
                                    Text("\(library.sources.filter { $0.hasGroup(group) }.count) 个书源")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Menu {
                                Button("重命名", systemImage: "pencil") {
                                    renaming = group
                                    renamedValue = group
                                }
                                Button("删除分组", systemImage: "trash", role: .destructive) {
                                    Task { await library.deleteGroup(group) }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(group)分组操作")
                        }
                    }
                } header: {
                    Text("已有分组")
                } footer: {
                    Text("点击分组可查看其中的书源。")
                }
            }
            .readingSheetTitle("书源分组")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { dismiss() }
                }
            }
            .alert("重命名分组", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("分组名称", text: $renamedValue)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    let name = renamedValue
                    if let old = renaming { Task { await library.renameGroup(old, to: name) } }
                    renaming = nil
                }
                .disabled(BookSource.parseGroups(renamedValue).isEmpty)
            }
        }
    }
}

private struct SourceGroupContentsView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let group: String

    private var sources: [BookSource] {
        library.sources.filter { $0.hasGroup(group) }
    }

    var body: some View {
        ReadingSheetList {
            Section {
                ForEach(sources) { source in
                    NavigationLink {
                        SourceDetailView(source: source)
                    } label: {
                        SourceRow(source: source) { enabled in
                            Task { await library.setEnabled(enabled, for: source.id) }
                        }
                    }
                }
                if sources.isEmpty {
                    Text("该分组暂无书源")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(sources.count) 个书源")
            }
        }
        .listStyle(.insetGrouped)
        .readingSheetSurface()
        .readingPageTitle(group)
    }
}

private struct SourceBatchGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let sourceIDs: Set<String>
    @State private var customGroup = ""

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Section("已选择 \(sourceIDs.count) 个书源") {
                    HStack {
                        TextField("输入新分组", text: $customGroup)
                        Button("加入") {
                            let value = customGroup
                            Task {
                                if await library.addGroup(value, to: sourceIDs), customGroup == value { customGroup = "" }
                            }
                        }
                        .disabled(BookSource.parseGroups(customGroup).isEmpty)
                    }
                }
                Section("加入现有分组") {
                    ForEach(library.groups, id: \.self) { group in
                        Button { Task { await library.addGroup(group, to: sourceIDs) } } label: {
                            Label(group, systemImage: "folder.badge.plus")
                        }
                    }
                }
                Section("从分组移除") {
                    ForEach(library.groups, id: \.self) { group in
                        Button(role: .destructive) {
                            Task { await library.removeGroup(group, from: sourceIDs) }
                        } label: { Label(group, systemImage: "folder.badge.minus") }
                    }
                }
            }
            .readingSheetTitle("批量归组")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { dismiss() }
                }
            }
        }
    }
}

private struct SourceDetailView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let source: BookSource
    @State private var showsEditor = false
    @State private var editedSourceID: String?
    private var current: BookSource { library.sources.first { $0.id == (editedSourceID ?? source.id) } ?? source }

    var body: some View {
        ReadingPageList {
            Section("基本信息") {
                ReadingLabeledContent("名称", value: current.bookSourceName)
                ReadingLabeledContent("地址", value: current.bookSourceUrl)
                ReadingLabeledContent("分组", value: current.bookSourceGroup ?? "未分组")
                ReadingLabeledContent("类型", value: String(current.bookSourceType))
            }
            Section("能力") {
                CapabilityRow(title: "搜索", available: current.searchUrl?.isEmpty == false)
                CapabilityRow(title: "发现", available: current.exploreUrl?.isEmpty == false)
                CapabilityRow(title: "详情", available: current.ruleBookInfo != nil)
                CapabilityRow(title: "目录", available: current.ruleToc != nil)
                CapabilityRow(title: "正文", available: current.ruleContent != nil)
            }
            Section("状态") {
                Toggle("启用书源", isOn: Binding(
                    get: { library.sources.first(where: { $0.id == current.id })?.enabled ?? current.enabled },
                    set: { value in Task { await library.setEnabled(value, for: current.id) } }
                ))
                Toggle("启用发现", isOn: Binding(
                    get: { library.sources.first(where: { $0.id == current.id })?.enabledExplore ?? current.enabledExplore },
                    set: { value in Task { await library.setExploreEnabled(value, for: current.id) } }
                ))
            }
            Section("兼容检查") {
                NavigationLink {
                    SearchView(fixedSource: current)
                } label: {
                    Label("搜索此书源", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    SourceDebugView(source: current)
                } label: {
                    Label("书源调试", systemImage: "stethoscope")
                }
                Text("使用你输入的关键词，逐步验证搜索、详情、目录和正文规则。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if current.loginUrl?.isEmpty == false {
                Section("账户") {
                    NavigationLink {
                        SourceLoginView(source: current)
                    } label: {
                        Label("登录此书源", systemImage: "person.badge.key.fill")
                    }
                    Text("登录 Cookie 与阅读请求共享；若书源提供检测脚本，会在页面载入后自动验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let comment = current.bookSourceComment, !comment.isEmpty {
                Section("说明") { Text(comment) }
            }
        }
        .readingPageTitle(current.bookSourceName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showsEditor = true }
            }
        }
        .sheet(isPresented: $showsEditor) {
            SourceEditorView(source: current) { editedSourceID = $0.id }.environmentObject(library)
        }
    }
}

struct DetectedRuleImportView: View {
    let rules: SourceLibraryModel.DetectedRules
    @EnvironmentObject private var library: SourceLibraryModel
    @EnvironmentObject private var websites: RSSLibraryModel
    @EnvironmentObject private var replacements: ReplaceRuleLibraryModel
    @State private var saving = false
    @State private var failure: String?

    @State private var selected: IndexSet
    private let names: [String]

    private let skippedWebsites: [String]

    init(rules: SourceLibraryModel.DetectedRules, skippedWebsites: [String]) {
        self.skippedWebsites = skippedWebsites
        self.rules = rules
        names = rules.names
        _selected = State(initialValue: IndexSet(integersIn: names.indices))
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                if !skippedWebsites.isEmpty {
                    DisclosureGroup("可导入 \(names.count) 条，已跳过 \(skippedWebsites.count) 条") {
                        ForEach(skippedWebsites.indices, id: \.self) { index in
                            Text(skippedWebsites[index])
                        }
                    }
                }
                Section {
                    ForEach(names.indices, id: \.self) { index in
                        Button {
                            if selected.contains(index) { selected.remove(index) }
                            else { selected.insert(index) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected.contains(index) ? ReadingTheme.accent : Color.secondary)
                                    .accessibilityHidden(true)
                                if case .websites(let sources) = rules {
                                    WebsiteSourceIcon(source: sources[index])
                                        .padding(5)
                                        .frame(width: 36, height: 36)
                                        .background(ReadingTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(names[index]).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    if case .websites(let sources) = rules,
                                       let host = URL(string: sources[index].sourceUrl)?.host {
                                        Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
                        .accessibilityIdentifier("import.item.\(index)")
                    }
                } header: {
                    HStack {
                        Text("已选 \(selected.count) / \(names.count) 项")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ReadingTheme.ink)
                        Spacer()
                        Button(selected.count == names.count ? "取消全选" : "全选") {
                            selected = selected.count == names.count ? [] : IndexSet(integersIn: names.indices)
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(names.isEmpty)
                    }
                    .textCase(nil)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            .readingListTopMargin(4)
            .readingSheetTitle("导入" + rules.title)
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { library.cancelPendingImport() }
                    ReadingSheetActionButton("导入", busyTitle: "导入中", isWorking: saving) {
                        let indices = selected
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                switch rules {
                                case .websites(let items): try await websites.importSources(indices.map { items[$0] })
                                case .replacements(let items): try await replacements.importRules(indices.map { items[$0] })
                                case .contents(let items): try await TxtTocRuleManagementModel().importRules(indices.map { items[$0] })
                                }
                                library.notice = .init(kind: .success, title: rules.title + "已导入", detail: "已处理 \(indices.count) 项。")
                                library.cancelPendingImport()
                            } catch { failure = error.localizedDescription }
                        }
                    }.disabled(selected.isEmpty)
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }
}

struct SourceImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let pending: SourceLibraryModel.PendingImport
    @State private var selectedIDs: Set<String>
    @State private var importError: String?
    @State private var isImporting = false
    @State private var keepOriginalName = false
    @State private var keepOriginalGroup = false
    @State private var keepOriginalEnabled = false
    @State private var showComments = false
    @State private var customGroup = ""
    @State private var addCustomGroup = true

    init(pending: SourceLibraryModel.PendingImport) {
        self.pending = pending
        _selectedIDs = State(initialValue: Set(pending.items.filter { $0.existing == nil || $0.state == "更新" }.map(\.id)))
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Section {
                    HStack(spacing: 10) {
                        importCountCard(
                            title: "有效",
                            count: pending.validCount,
                            color: .green,
                            systemImage: "checkmark.circle.fill"
                        )
                        importCountCard(
                            title: "失效",
                            count: pending.invalidCount,
                            color: .red,
                            systemImage: "xmark.circle.fill"
                        )
                        importCountCard(
                            title: "总计",
                            count: pending.totalCount,
                            color: .secondary,
                            systemImage: "doc.text.fill"
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                    Menu("选择") {
                        Button("全选") { selectedIDs = Set(pending.items.map(\.id)) }
                        Button("取消全选") { selectedIDs.removeAll() }
                        Button("仅选择新增") {
                            selectedIDs = Set(pending.items.filter { $0.existing == nil }.map(\.id))
                        }
                        Button("仅选择更新") {
                            selectedIDs = Set(pending.items.filter { $0.existing != nil }.map(\.id))
                        }
                    }
                    .disabled(pending.items.isEmpty)

                    Label("仅有效书源可被选择和导入", systemImage: "checkmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !pending.items.isEmpty {
                    Section("导入设置") {
                        HStack {
                            TextField("自定义分组", text: $customGroup)
                            Toggle("追加", isOn: $addCustomGroup).labelsHidden()
                        }
                        Toggle("保留原名称", isOn: $keepOriginalName)
                        Toggle("保留原分组", isOn: $keepOriginalGroup)
                        Toggle("保留原启用状态", isOn: $keepOriginalEnabled)
                        Toggle("显示书源备注", isOn: $showComments)
                    }
                }

                Section("有效书源（\(pending.validCount)）") {
                    ForEach(pending.items) { item in
                        Button {
                            if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedIDs.contains(item.id) ? ReadingTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.bookSourceName).foregroundStyle(.primary)
                                    HStack {
                                        Text(item.state)
                                            .font(.caption.bold())
                                            .foregroundStyle(item.state == "新增" ? .green : item.state == "更新" ? .orange : .secondary)
                                        Text(item.source.bookSourceUrl)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if showComments, let comment = item.source.bookSourceComment, !comment.isEmpty {
                                        Text(comment).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !pending.invalidItems.isEmpty {
                    Section("失效书源（\(pending.invalidCount)）") {
                        ForEach(pending.invalidItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.bookSourceName.isEmpty ? "未命名书源" : item.source.bookSourceName)
                                        .foregroundStyle(.primary)
                                    if !item.source.bookSourceUrl.isEmpty {
                                        Text(item.source.bookSourceUrl)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(item.issues.map(\.message).joined(separator: "；"))
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .readingSheetTitle("书源导入预检")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") {
                        library.cancelPendingImport()
                        dismiss()
                    }
                    ReadingSheetActionButton("导入", busyTitle: "导入中", isWorking: isImporting) {
                        let ids = selectedIDs
                        isImporting = true
                        Task {
                            await library.commitPendingImport(
                                selectedIDs: ids,
                                keepOriginalName: keepOriginalName,
                                keepOriginalGroup: keepOriginalGroup,
                                keepOriginalEnabled: keepOriginalEnabled,
                                customGroup: customGroup.isEmpty ? nil : customGroup,
                                addCustomGroup: addCustomGroup
                            )
                            isImporting = false
                            if library.pendingImport == nil { dismiss() }
                            else {
                                let message = library.notice?.detail ?? "保存失败，请重试"
                                library.notice = nil
                                importError = message
                            }
                        }
                    }
                    .disabled(selectedIDs.isEmpty || isImporting)
                }
            }
        }
        .disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
        .alert("导入保存失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func importCountCard(
        title: String,
        count: Int,
        color: Color,
        systemImage: String
    ) -> some View {
        VStack(spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.title2.bold())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CapabilityRow: View {
    let title: String
    let available: Bool

    var body: some View {
        ReadingLabeledContent(title) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
                .accessibilityLabel(available ? "已配置" : "未配置")
        }
    }
}
