import SwiftUI

@MainActor
private final class CacheManagementModel: ObservableObject {
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

struct CacheManagementView: View {
    @StateObject private var model = CacheManagementModel()
    @State private var confirmsClear = false

    var body: some View {
        let limitMB = ApplicationSettingsStore.shared.settings.chapterCacheMB
        let usedSpace = ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .binary)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("章节缓存占用", systemImage: "internaldrive")
                        .font(.subheadline)
                    Text(model.bytes == 0 ? "0 KB" : usedSpace)
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    ProgressView(value: min(Double(model.bytes) / Double(max(limitMB, 1) * 1024 * 1024), 1))
                        .tint(ReadingTheme.onAccent)
                        .accessibilityHidden(true)
                    Text("已缓存 \(model.entries) 章 · 上限 \(limitMB) MB")
                        .font(.subheadline)
                }
                .foregroundStyle(ReadingTheme.onAccent)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReadingTheme.emphasisSurface, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .combine)

                NavigationLink {
                    NetworkSettingsView(initialTab: .cache)
                } label: {
                    HStack {
                        Label("网络与缓存设置", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Text("阅读和预读的网络章节会保存在本机。超过容量上限时，优先清理最久未读取的章节。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("清空章节缓存", systemImage: "trash", role: .destructive) {
                    confirmsClear = true
                }
                .frame(minHeight: 44)
                .disabled(model.entries == 0 || model.isWorking)
            }
            .frame(maxWidth: 640)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.canvas)
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .overlay { if model.isWorking { RagdollLoading() } }
        .alert("清空章节缓存？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空缓存", role: .destructive) { Task { await model.clear() } }
        } message: {
            Text("将移除已缓存的 \(model.entries) 章，释放 \(usedSpace) 空间。")
        }
        .alert("缓存操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }
}
