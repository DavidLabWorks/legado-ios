import SwiftUI

struct RuleSubscriptionView: View {
    @EnvironmentObject private var bookSources: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var model: RuleSubscriptionModel
    @State private var editing: RuleSub?

    private var visibleValues: [RuleSub] { model.values.filter { $0.type != 1 } }

    var body: some View {
        Group {
            if visibleValues.isEmpty {
                ReadingIllustratedEmptyState(artwork: "SourceEmptyArtwork", title: "还没有规则订阅",
                                             message: "添加订阅地址，更新书源或净化规则。") {
                    Button { editing = RuleSub() } label: {
                        Label("新建订阅", systemImage: "plus").managementPrimaryAction()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)
                }
            } else {
                List {
                    Section("订阅 · \(visibleValues.count)") {
                        ForEach(visibleValues) { value in
                            Button { open(value) } label: { subscriptionRow(value) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading) {
                                    Button("编辑", systemImage: "pencil") { editing = value }.tint(.blue)
                                }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { visibleValues.indices.contains($0) ? visibleValues[$0].id : nil })
                            let sourceOffsets = IndexSet(model.values.indices.filter { ids.contains(model.values[$0].id) })
                            Task { await model.remove(at: sourceOffsets) }
                        }
                    }
                    .listRowBackground(ReadingTheme.surface)
                }
                .readingManagementList()
            }
        }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle("规则订阅")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { editing = RuleSub() } }
            ToolbarItem(placement: .primaryAction) { if !visibleValues.isEmpty { EditButton().environment(\.locale, Locale(identifier: "zh-Hans")) } }
        }
        .task { await model.load() }
        .sheet(item: $editing) { value in
            RuleSubscriptionEditView(value: value, isNew: !model.values.contains { $0.id == value.id }, saveError: $model.errorMessage) { item in
                await model.save(item)
            }
        }
        .alert("规则订阅", isPresented: Binding(get: { editing == nil && model.errorMessage != nil }, set: { if !$0, editing == nil { model.errorMessage = nil } })) { Button("好") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }

    private func subscriptionRow(_ value: RuleSub) -> some View {
        let updateMode = value.autoUpdate ? (value.silentUpdate ? "静默更新" : "自动更新") : "手动更新"
        return HStack(spacing: 12) {
            ManagementRowIcon(systemName: value.type == 2 ? "wand.and.stars" : "book.closed")
            VStack(alignment: .leading, spacing: 4) {
                Text(value.name.isEmpty ? value.url : value.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if !value.name.isEmpty {
                    Text(value.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(typeName(value.type)) · \(updateMode)")
                    .font(.caption).foregroundStyle(.secondary)
                if model.pendingIDs.contains(value.id) {
                    Label("有更新", systemImage: "arrow.down.circle.fill").font(.caption.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func open(_ value: RuleSub) {
        model.clearPending(value.id)
        Task {
            switch value.type {
            case 2: await replaceRules.importRemoteURL(value.url)
            default: await bookSources.importRemoteURL(value.url)
            }
        }
    }
    private func typeName(_ type: Int) -> String { type == 2 ? "净化" : "书源" }
}

private struct RuleSubscriptionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: RuleSub
    @State private var saving = false
    @Binding var saveError: String?
    let isNew: Bool
    let save: (RuleSub) async -> Bool

    init(value: RuleSub, isNew: Bool, saveError: Binding<String?>, save: @escaping (RuleSub) async -> Bool) {
        _value = State(initialValue: value)
        self.isNew = isNew
        _saveError = saveError
        self.save = save
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetForm {
                Section("订阅类型") {
                    Picker("类型", selection: $value.type) {
                        Text("书源").tag(0)
                        Text("净化规则").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section("订阅来源") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("名称").font(.caption).foregroundStyle(.secondary)
                        TextField("订阅名称（选填）", text: $value.name).accessibilityLabel("名称")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("订阅地址").font(.caption).foregroundStyle(.secondary)
                        ReadingTextField("https://", text: $value.url, axis: .vertical)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .accessibilityLabel("订阅地址")
                            .accessibilityIdentifier("subscription.url")
                    }
                }
                Section("更新方式") {
                    Toggle("自动更新", isOn: $value.autoUpdate)
                    if value.autoUpdate {
                        Stepper("更新间隔：\(value.updateInterval) 小时", value: $value.updateInterval, in: 1...720)
                        Toggle("静默更新", isOn: $value.silentUpdate)
                    }
                }
            }
            .readingSheetTitle(isNew ? "新建订阅" : "编辑订阅")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton(isWorking: saving) { saving = true; Task { if await save(value) { dismiss() }; saving = false } }.disabled(saving || value.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(saveError ?? "") }
    }
}
