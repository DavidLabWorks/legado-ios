import SwiftUI

struct RSSSourceEditorView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @State private var isSaving = false
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
    private let originalURL: String?

    init(source: RssSource? = nil) {
        let value = source ?? RssSource()
        _draft = State(initialValue: value)
        originalURL = source?.sourceUrl
    }

    var body: some View {
        List {
            sourceSummary
                .listRowBackground(ReadingTheme.groupedCanvas)
            Section("基本信息") {
                basicField("名称", placeholder: "网站名称", text: $draft.sourceName)
                basicField("源地址", placeholder: "https://", text: $draft.sourceUrl)
                    .keyboardType(.URL)
                basicField("分组", placeholder: "未分组", text: optionalText(\.sourceGroup))
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
        }
        .listStyle(.insetGrouped)
        .readingListTopMargin(8)
        .readingScrollContentBackgroundHidden()
        .background(ReadingTheme.canvas)
        .navigationTitle(originalURL == nil ? "新建网站源" : "编辑网站源")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $detail, onDismiss: {
            if let originalDetail { draft = originalDetail; self.originalDetail = nil }
        }) { item in
            ReadingNavigationStack {
                Form {
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if detail == nil {
                    ReadingSheetActionButton(isWorking: isSaving) {
                        isSaving = true
                        Task {
                            if await library.save(draft, replacing: originalURL) { dismiss() }
                            isSaving = false
                        }
                    }
                }
            }
        }
        .disabled(isSaving)
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
