import SwiftUI
import UIKit

struct ReplaceRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: ReplaceRuleLibraryModel
    @State private var rule: ReplaceRule
    @State private var mode: Int
    @State private var testTitle = "第一章 开始"
    @State private var testContent = "在这里粘贴需要净化的正文。"
    @State private var testBook = ""
    @State private var testSource = ""
    @State private var testResult: ReplaceRuleTestResult?
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var isSaving = false
    @ScaledMetric(relativeTo: .body) private var previewIconWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var inputHeight: CGFloat = 64
    @State private var expandedFilter = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsDiscard = false
    private let original: ReplaceRule
    private let readingBook: Book?

    init(rule: ReplaceRule, startsWithTest: Bool = false, readingBook: Book? = nil) {
        self.readingBook = readingBook
        if let readingBook {
            _testBook = State(initialValue: readingBook.name)
            _testSource = State(initialValue: readingBook.origin)
            _testContent = State(initialValue: rule.pattern)
        }
        if readingBook == nil, rule.scopeBookURL != nil {
            _testBook = State(initialValue: rule.scope ?? "")
        }
        original = rule
        _rule = State(initialValue: rule)
        _mode = State(initialValue: startsWithTest ? 1 : 0)
    }

    var body: some View {
        ReadingNavigationStack {
            Group {
                if let readingBook {
                    filterSummary(book: readingBook)
                } else {
                    editor.readingSheetTitle("净化规则")
                }
            }
            .alert("规则提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("放弃未保存的修改？", isPresented: $showsDiscard) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃修改", role: .destructive) { dismiss() }
            }
            .onChange(of: rule) { _ in testResult = nil }
            .onChange(of: testTitle + testContent + testBook + testSource) { _ in testResult = nil }
        }
        .modifier(FilterSheetSize(isFilter: readingBook != nil, expanded: expandedFilter || typeSize.isAccessibilitySize))
        .disabled(isSaving)
        .interactiveDismissDisabled(rule != original || isSaving)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Picker("模式", selection: $mode) {
                Text(readingBook == nil ? "编辑规则" : "规则设置").tag(0)
                Text("测试规则").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ReadingSheetForm {
                if mode == 0 {
                    configuration
                } else {
                    testForm
                }
            }
        }
        .background(ReadingTheme.sheetBackground)
        .toolbar { editorActions(showCancel: readingBook == nil) }
    }

    @ToolbarContentBuilder
    private func editorActions(showCancel: Bool) -> some ToolbarContent {
        ReadingSheetActions {
            if showCancel { Button("取消", action: cancel) }
            ReadingSheetActionButton(isWorking: isSaving, action: save)
                .disabled(isSaving || isTesting)
        }
    }

    private func cancel() {
        if rule != original { showsDiscard = true } else { dismiss() }
    }

    private func save() {
        // Commit any pending input-method composition before saving the draft.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isSaving = true
        Task {
            let saved = await library.save(rule)
            isSaving = false
            if saved { dismiss() }
            else {
                errorMessage = library.notice?.detail ?? "保存失败"
                library.notice = nil
            }
        }
    }

    private func filterSummary(book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    patternField
                    Divider().padding(.horizontal, 16)
                    replacementField
                }
                .padding(.vertical, 4)
                .readingSheetGroup()
                VStack(spacing: 0) {
                    bookScopePicker(name: book.name, url: book.bookUrl)
                    Divider()
                    Toggle("使用正则表达式", isOn: $rule.isRegex)
                        .font(.subheadline)
                        .frame(minHeight: 46)
                    Divider()
                    NavigationLink {
                        editor.readingPageTitle("更多设置")
                    } label: {
                        summaryRow("更多设置", value: "名称、分组、测试")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .readingSheetGroup()
                if book.readConfig?.useReplaceRule == false {
                    Text("本书已关闭正文替换，启用后规则才会生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .readingSheetTitle("过滤文本")
        .toolbar { editorActions(showCancel: true) }
        .onAppear { expandedFilter = false }
        .onDisappear { expandedFilter = true }
    }

    private enum BookScope { case all, current, custom }

    private func bookScopePicker(name: String, url: String) -> some View {
        let scope: BookScope
        if rule.scopeBookURL == nil && (rule.scope ?? "").isEmpty && (rule.excludeScope ?? "").isEmpty {
            scope = .all
        } else if rule.scopeBookURL == url && (rule.excludeScope ?? "").isEmpty {
            scope = .current
        } else {
            scope = .custom
        }
        return HStack {
            Text("作用范围").font(.subheadline)
            Spacer()
            Picker("作用范围", selection: Binding(get: { scope }, set: { selection in
                guard selection != .custom else { return }
                rule.scopeBookURL = selection == .current ? url : nil
                rule.scope = selection == .current ? name : nil
                rule.excludeScope = nil
            })) {
                Text("全局").tag(BookScope.all)
                Text("本书").tag(BookScope.current)
                if scope == .custom { Text("自定义").tag(BookScope.custom) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: scope == .custom ? 210 : 144)
            .accessibilityIdentifier("filter.scope")
        }
        .frame(minHeight: 45)
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.vertical, 7)
        .frame(minHeight: 45)
        .contentShape(Rectangle())
    }

    private var patternField: some View {
        ruleInput("匹配内容", text: $rule.pattern, id: "filter.pattern", prompt: "输入要匹配的文字",
                  language: rule.isRegex ? .regex : .plain)
    }

    private var replacementField: some View {
        let language: SyntaxCodeEditor.Language = rule.replacement.hasPrefix("@js:") ? .javascript : .regex
        return ruleInput("替换为", text: $rule.replacement, id: "filter.replacement", prompt: "留空即删除匹配文字",
                         language: rule.isRegex ? language : .plain)
    }

    private func ruleInput(_ title: String, text: Binding<String>, id: String, prompt: String,
                           language: SyntaxCodeEditor.Language) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 10)
            SyntaxCodeEditor(text: text, language: language, inlineID: id)
                .accessibilityLabel(title)
                .accessibilityHint(prompt)
                .frame(height: inputHeight)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(prompt).font(.body).foregroundStyle(.secondary)
                            .padding(.leading, 10).padding(.top, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var configuration: some View {
        Group {
            if readingBook == nil {
                Section {
                    patternField
                    replacementField
                }
            }
            Section("规则信息") {
                HStack {
                    Text("规则名称")
                    TextField("名称", text: $rule.name).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("分组")
                    TextField("未分组", text: optional(\.group)).multilineTextAlignment(.trailing)
                        .accessibilityLabel("分组")
                }
                Toggle("启用规则", isOn: $rule.isEnabled)
                Toggle("使用正则表达式", isOn: $rule.isRegex)
                if rule.isRegex {
                    DisclosureGroup("正则替换语法") {
                        Text("用 $1、$2 引用捕获组。以 @js: 开头可运行 JavaScript，result 为匹配文本，也可读取 book 和 chapter。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if readingBook?.readConfig?.useReplaceRule == false {
                    Text("本书已关闭正文替换，启用后规则才会生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if let book = readingBook {
                    bookScopePicker(name: book.name, url: book.bookUrl)
                } else if let url = original.scopeBookURL {
                    bookScopePicker(name: original.scope ?? "", url: url)
                }
                DisclosureGroup {
                    Toggle("章节标题", isOn: $rule.scopeTitle)
                    Toggle("正文", isOn: $rule.scopeContent)
                    ReadingTextField("限定书名或书源（留空为全部）", text: optional(\.scope), axis: .vertical)
                    ReadingTextField("排除书名或书源", text: optional(\.excludeScope), axis: .vertical)
                } label: {
                    ReadingLabeledContent(readingBook == nil && original.scopeBookURL == nil ? "作用范围" : "详细条件", value: scopeDescription)
                }
            }
            Section {
                DisclosureGroup("执行设置") {
                    HStack {
                        Text("超时（毫秒）")
                        TextField("3000", value: $rule.timeoutMillisecond, format: .number.grouping(.never))
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("排序编号")
                        TextField("0", value: $rule.sortOrder, format: .number.grouping(.never))
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    Text("超时值小于等于 0 时使用 3000 毫秒，单次正则最多运行 60 秒。规则按编号依次执行，超时或超出资源限制时保留原文并报告错误。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ruleActions
            }
        }
    }

    private var scopeDescription: String {
        let target: String
        switch (rule.scopeTitle, rule.scopeContent) {
        case (true, true): target = "标题与正文"
        case (true, false): target = "章节标题"
        case (false, true): target = "正文"
        case (false, false): return "未选择"
        }
        if let book = readingBook, rule.scopeBookURL == book.bookUrl, (rule.excludeScope ?? "").isEmpty {
            return "本书 · " + target
        }
        if rule.scopeBookURL != nil { return (rule.scope ?? "指定书籍") + " · " + target }
        if (rule.scope ?? "").isEmpty && (rule.excludeScope ?? "").isEmpty {
            return "全部书籍 · " + target
        }
        return "自定义 · " + target
    }

    private var ruleActions: some View {
        Menu("规则操作", systemImage: "ellipsis.circle") {
            Button("复制规则 JSON", systemImage: "doc.on.doc") { UIPasteboard.general.string = json }
            Button("粘贴规则 JSON", systemImage: "doc.on.clipboard") {
                do {
                    guard let text = UIPasteboard.general.string else { return }
                    var pasted = try JSONDecoder().decode(ReplaceRule.self, from: Data(text.utf8))
                    pasted.id = rule.id
                    pasted.sortOrder = rule.sortOrder
                    rule = pasted
                } catch { errorMessage = error.localizedDescription }
            }
            ReadingShareLink(item: json) { Label("分享规则", systemImage: "square.and.arrow.up") }
        }
    }

    private func previewRow(_ title: String, systemImage: String, value: String, placeholder: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: previewIconWidth, height: previewIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text(value.isEmpty ? placeholder : value)
                    .font(.body)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }

    private var testForm: some View {
        Group {
            Section("测试文本") {
                NavigationLink {
                    RuleCodeFieldView(title: "测试正文", path: "测试输入", text: $testContent)
                } label: {
                    previewRow("正文", systemImage: "text.alignleft", value: testContent, placeholder: "输入测试正文")
                }
                DisclosureGroup("测试上下文") {
                    TextField("章节标题", text: $testTitle)
                    TextField("书名（用于作用范围判断）", text: $testBook)
                    TextField("书源地址（用于作用范围判断）", text: $testSource).textInputAutocapitalization(.never)
                }
            }
            Section {
                Button { runTest() } label: {
                    HStack { Label(isTesting ? "测试中…" : "运行当前草稿", systemImage: "play.fill"); Spacer(); if isTesting { RagdollLoading() } }
                }.disabled(isTesting)
                if !rule.isEnabled { Text("规则处于停用状态，结果将保持原文。可在编辑页启用后测试。").font(.footnote).foregroundStyle(.secondary) }
            }
            if let result = testResult {
                Section("测试结果 · \(result.elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms") {
                    Label(result.report.effectiveRuleIDs.isEmpty ? "未改变文本（请检查匹配、启用状态及作用范围）" : "规则已生效",
                          systemImage: result.report.effectiveRuleIDs.isEmpty ? "info.circle" : "checkmark.circle")
                    ReadingLabeledContent("标题", value: result.report.title)
                    Text(result.report.content.isEmpty ? "（正文为空）" : result.report.content)
                        .font(.body.monospaced()).textSelection(.enabled)
                }
                if !result.report.diagnostics.isEmpty {
                    Section("执行错误") {
                        ForEach(result.report.diagnostics) { diagnostic in Text(diagnostic.message).foregroundStyle(.red) }
                    }
                }
            }
        }
    }

    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(rule)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    private func optional(_ path: WritableKeyPath<ReplaceRule, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: path] ?? "" }, set: { value in
            if path == \.scope { rule.scopeBookURL = nil }
            rule[keyPath: path] = value.isEmpty ? nil : value
        })
    }
    private func runTest() {
        let snapshot = rule
        let title = testTitle, content = testContent, book = testBook, source = testSource
        let bookURL = readingBook?.name == book ? readingBook?.bookUrl : (snapshot.scope == book ? snapshot.scopeBookURL : nil)
        isTesting = true
        testResult = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ReplaceRuleTester().test(rule: snapshot, title: title, content: content, bookName: book, sourceURL: source, bookURL: bookURL ?? "test")
                }.value
                if rule == snapshot, title == testTitle, content == testContent, book == testBook, source == testSource { testResult = result }
            } catch { errorMessage = error.localizedDescription }
            isTesting = false
        }
    }
}


private struct FilterSheetSize: ViewModifier {
    let isFilter: Bool
    let expanded: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if !isFilter {
            content
        } else if #available(iOS 16, *) {
            content.modifier(FilterDetents(expanded: expanded))
        } else {
            content.readingPresentationDetents(expanded ? [.large] : [.medium])
                .readingPresentationDragIndicator()
        }
    }
}


@available(iOS 16, *)
private struct FilterDetents: ViewModifier {
    let expanded: Bool
    private static let compact = PresentationDetent.height(448)
    @State private var selection = Self.compact

    func body(content: Content) -> some View {
        content.presentationDetents([Self.compact, .large], selection: $selection)
            .presentationDragIndicator(.visible)
            .onAppear { selection = expanded ? .large : Self.compact }
            .onChange(of: expanded) { selection = $0 ? .large : Self.compact }
    }
}
