import SwiftUI

struct NetworkSettingsView: View {
    let page: ApplicationSettings.Page
    @State private var settings = ApplicationSettingsStore.shared.settings
    @StateObject private var cache = CacheManagementModel()
    @FocusState private var focusedField: NetworkTextField?
    @State private var drafts: [NetworkTextField: String] = [:]
    @State private var fieldErrors: [NetworkTextField: String] = [:]
    @State private var confirmsReset = false
    @State private var errorMessage: String?

    private var title: String {
        switch page {
        case .chapterCache: "缓存管理"
        case .connection: "网络连接"
        case .advancedNetwork: "高级网络"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch page {
                case .chapterCache:
                    CacheSettingsContent(cache: cache, limit: binding(\.chapterCacheMB),
                                         prefetch: binding(\.prefetchChapters))
                case .connection: connectionSettings
                case .advancedNetwork: advancedSettings
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认") { confirmsReset = true }
                    .disabled(page.applying(.init(), to: settings) == settings && drafts.isEmpty)
            }
        }
        .onAppear { settings = ApplicationSettingsStore.shared.settings }
        .alert("恢复\(title)默认值？", isPresented: $confirmsReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                do {
                    try update { $0 = page.applying(.init(), to: $0) }
                    drafts.removeAll()
                    fieldErrors.removeAll()
                    focusedField = nil
                }
                catch { errorMessage = error.localizedDescription }
            }
        } message: { Text(page == .chapterCache ? "章节缓存的容量上限和预读章数将恢复为默认值。" : "本页设置将立即恢复为默认值。") }
        .alert("设置未生效", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") {}
        } message: { Text(errorMessage ?? "") }
        .onChange(of: focusedField) { field in finishEditing(except: field) }
        .onDisappear { finishEditing(except: nil) }
    }

    private func binding<Value>(_ key: WritableKeyPath<ApplicationSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { newValue in
            do { try update { $0[keyPath: key] = newValue } }
            catch { errorMessage = error.localizedDescription }
        })
    }

    private func update(_ change: (inout ApplicationSettings) -> Void) throws {
        let store = ApplicationSettingsStore.shared
        let current = store.settings
        var next = current
        change(&next)
        try store.save(next)
        settings = store.settings
        if current != settings { DiagnosticLog.shared.record(category: "设置", message: "\(title)设置已更新") }
        if settings.chapterCacheMB < current.chapterCacheMB {
            Task { await cache.trimToLimit() }
        }
    }

    @ViewBuilder private var connectionSettings: some View {
        ReadingSoftCard {
            VStack(spacing: 0) {
                Menu {
                    Picker("请求超时", selection: binding(\.timeoutSeconds)) {
                        Text("跟随书源").tag(0)
                        let values = Set([5, 10, 15, 30, 60, 120, 180, 300, settings.timeoutSeconds]).subtracting([0])
                        ForEach(values.sorted(), id: \.self) { Text("\($0) 秒").tag($0) }
                    }
                } label: {
                    HStack {
                        Label("请求超时", systemImage: "clock").font(.headline)
                        Spacer()
                        Text(settings.timeoutSeconds == 0 ? "跟随书源" : "\(settings.timeoutSeconds) 秒")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("请求超时")
                .accessibilityValue(settings.timeoutSeconds == 0 ? "跟随书源" : "\(settings.timeoutSeconds) 秒")
                .accessibilityIdentifier("network.timeout")
                Divider().padding(.vertical, 12)
                Stepper(value: binding(\.concurrentSources), in: 1...64) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("搜索并发数").font(.headline)
                        Text("同时搜索 \(settings.concurrentSources) 个书源")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
        ReadingSoftCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("兼容无效证书的书源", isOn: binding(\.ignoreCertificateErrors))
                    .font(.headline)
                Text("开启后允许使用自签名或过期证书的书源。关闭后由系统验证 HTTPS 证书。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private var advancedSettings: some View {
        ReadingSoftCard {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(NetworkTextField.allCases, id: \.self) { field in
                    if field != .userAgent { Divider() }
                    Text(field.rawValue).font(.headline)
                    Group {
                        if field == .hosts {
                            TextEditor(text: draft(for: field))
                                .font(.body.monospacedDigit())
                                .readingScrollContentBackgroundHidden()
                                .frame(height: 94)
                        } else {
                            TextField(field == .proxy ? "例如 http://127.0.0.1:7890" : "留空使用默认浏览器标识",
                                      text: draft(for: field))
                                .keyboardType(field == .proxy ? .URL : .default)
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                                .frame(minHeight: 44)
                        }
                    }
                    .padding(.horizontal, field == .hosts ? 5 : 10)
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 8))
                    .focused($focusedField, equals: field)
                    .accessibilityLabel(field.rawValue)
                    if let message = fieldErrors[field] {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                    if field == .proxy {
                        Text("支持 HTTP、HTTPS 和 SOCKS 代理。留空关闭全局代理。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if field == .hosts {
                        Text("每行输入 IP 地址和域名，可用 # 添加注释。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
    }

    private func draft(for field: NetworkTextField) -> Binding<String> {
        Binding(get: { drafts[field] ?? settings[keyPath: field.key] }, set: { text in
            drafts[field] = text == settings[keyPath: field.key] ? nil : text
            var candidate = settings
            candidate[keyPath: field.key] = text
            do {
                _ = try candidate.validated()
                fieldErrors[field] = nil
            } catch {
                fieldErrors[field] = error.localizedDescription
            }
        })
    }

    private func finishEditing(except focused: NetworkTextField?) {
        for (field, text) in drafts where field != focused && fieldErrors[field] == nil {
            do {
                try update { $0[keyPath: field.key] = text }
                drafts[field] = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum NetworkTextField: String, CaseIterable {
    case userAgent = "默认 User-Agent", proxy = "全局代理", hosts = "自定义 Hosts"

    var key: WritableKeyPath<ApplicationSettings, String> {
        switch self {
        case .userAgent: \.userAgent
        case .proxy: \.proxy
        case .hosts: \.hosts
        }
    }
}
