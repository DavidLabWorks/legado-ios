import SwiftUI

struct RSSSourceEditorView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RssSource
    private let originalURL: String?

    init(source: RssSource? = nil) {
        let value = source ?? RssSource()
        _draft = State(initialValue: value)
        originalURL = source?.sourceUrl
    }

    var body: some View {
        Form {
            Section("基本") {
                TextField("名称", text: $draft.sourceName)
                TextField("URL", text: $draft.sourceUrl).textInputAutocapitalization(.never).keyboardType(.URL)
                requiredField("图标", \.sourceIcon)
                optionalField("分组", \.sourceGroup)
                optionalField("注释", \.sourceComment, axis: .vertical)
                Toggle("启用", isOn: $draft.enabled)
            }
            Section("请求与登录") {
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
            Section("分类与列表规则") {
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
            Section("WebView规则") {
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
            Section("其他") {
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
        }
        .navigationTitle(originalURL == nil ? "新建网站源" : "编辑网站源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { if await library.save(draft, replacing: originalURL) { dismiss() } } }
            }
        }
    }

    @ViewBuilder private func optionalField(_ title: String, _ keyPath: WritableKeyPath<RssSource, String?>, axis: Axis = .horizontal) -> some View {
        ReadingTextField(title, text: optionalText(keyPath), axis: axis).textInputAutocapitalization(.never)
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
