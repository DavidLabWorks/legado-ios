import SwiftUI
import WebKit

@MainActor
final class CacheManagementModel: ObservableObject {
    @Published private(set) var entries = 0
    @Published private(set) var bytes = 0
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let cache: ChapterContentCache

    init(cache: ChapterContentCache = .live()) { self.cache = cache }

    func load() async {
        do {
            let statistics = try await cache.statistics()
            entries = statistics.entries
            bytes = statistics.bytes
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trimToLimit() async {
        do {
            try await cache.pruneIfNeeded()
            await load()
        } catch { errorMessage = "容量上限已更新，整理缓存失败：\(error.localizedDescription)" }
    }

    func clear() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await cache.removeAll()
            entries = 0
            bytes = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CacheSettingsContent: View {
    @ObservedObject var cache: CacheManagementModel
    @Binding var limit: Int
    @Binding var prefetch: Int
    @State private var confirmsClear = false
    @State private var confirmsWebClear = false
    @State private var clearingWeb = false
    @State private var webCleared = false

    private func capacity(_ mb: Int) -> String {
        mb.isMultiple(of: 1024) ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    var body: some View {
        let usedSpace = cache.bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: Int64(cache.bytes), countStyle: .binary)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("章节缓存占用").font(.subheadline)
                Text(usedSpace).font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                ProgressView(value: min(Double(cache.bytes) / Double(max(limit, 1) * 1024 * 1024), 1))
                    .tint(ReadingTheme.onAccent)
                    .accessibilityHidden(true)
                Text("已缓存 \(cache.entries) 章").font(.subheadline)
            }
            .accessibilityElement(children: .combine)
            Divider().overlay(ReadingTheme.onAccent.opacity(0.25))
            Menu {
                Picker("容量上限", selection: $limit) {
                    let limits = Set([16, 32, 64, 128, 256, 512, 1024, 2048, 4096, limit])
                    ForEach(limits.sorted(), id: \.self) { mb in Text(capacity(mb)).tag(mb) }
                }
            } label: {
                HStack {
                    Text("容量上限").font(.headline)
                    Spacer()
                    Text(capacity(limit)).monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("容量上限")
            .accessibilityValue(capacity(limit))
            .accessibilityHint("超出上限时会清理最久未读取的章节")
            .accessibilityIdentifier("cache.limit")
            Text("超出上限时，优先清理最久未读取的章节。").font(.footnote)
        }
        .padding(20)
        .foregroundStyle(ReadingTheme.onAccent)
        .background(ReadingTheme.emphasisSurface, in: RoundedRectangle(cornerRadius: 20))
        .task { await cache.load() }

        ReadingSoftCard {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: $prefetch, in: 0...20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动预读").font(.headline)
                        Text(prefetch == 0 ? "已关闭" : "前后各预读 \(prefetch) 章")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("cache.prefetch")
                .accessibilityValue(String(prefetch))
                Divider()
                Button("清空章节缓存", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .frame(minHeight: 44)
                    .disabled(cache.entries == 0 || cache.isWorking)
                if cache.isWorking { RagdollLoading("正在清理章节缓存…") }
            }
            .padding(16)
        }
        .alert("清空章节缓存？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空缓存", role: .destructive) { Task { await cache.clear() } }
        } message: { Text("将移除已缓存的 \(cache.entries) 章，释放 \(usedSpace) 空间。这些章节需重新加载才能离线阅读。") }
        .alert("缓存操作提示", isPresented: Binding(
            get: { cache.errorMessage != nil }, set: { if !$0 { cache.errorMessage = nil } }
        )) {
            Button("好") { cache.errorMessage = nil }
        } message: { Text(cache.errorMessage ?? "") }

        ReadingSoftCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("网页缓存").font(.headline).accessibilityAddTraits(.isHeader)
                Text("清理网页和图片的临时文件，保留登录状态和离线章节。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("清理网页缓存", systemImage: "trash", role: .destructive) { confirmsWebClear = true }
                        .frame(minHeight: 44)
                        .disabled(clearingWeb)
                        .accessibilityValue(clearingWeb ? "处理中" : (webCleared ? "已清理" : ""))
                    Spacer()
                    if clearingWeb { RagdollLoading(width: 24) }
                    if webCleared { Text("已清理").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .padding(16)
        }
        .alert("清理网页缓存？", isPresented: $confirmsWebClear) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { Task { await clearWebCache() } }
        } message: { Text("下次打开网页时会重新加载页面和图片。登录状态和离线章节都会保留。") }
    }

    @MainActor private func clearWebCache() async {
        guard !clearingWeb else { return }
        clearingWeb = true
        webCleared = false
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache],
            modifiedSince: .distantPast
        )
        URLCache.shared.removeAllCachedResponses()
        clearingWeb = false
        webCleared = true
        DiagnosticLog.shared.record(category: "存储", message: "清理网页缓存完成")
        UIAccessibility.post(notification: .announcement, argument: "清理网页缓存完成")
    }

}
