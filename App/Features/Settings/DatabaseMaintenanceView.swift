import SwiftUI

struct DatabaseMaintenanceView: View {
    @State private var compacting = false
    @State private var compacted = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            ReadingSoftCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("回收空闲空间", systemImage: "externaldrive").font(.headline)
                    Text("删除书籍或规则后，可整理数据库以回收空闲空间。现有书籍、规则和阅读记录都会保留。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Button { Task { await compactDatabase() } } label: {
                            Text("开始整理").managementPrimaryAction()
                        }
                        .buttonStyle(.plain)
                        .disabled(compacting)
                        .accessibilityValue(compacting ? "处理中" : (compacted ? "已整理" : ""))
                        Spacer()
                        if compacting { RagdollLoading(width: 28) }
                        if compacted { Label("已整理", systemImage: "checkmark").font(.subheadline) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle("整理数据库")
        .alert("整理失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @MainActor private func compactDatabase() async {
        guard !compacting else { return }
        compacting = true
        compacted = false
        defer { compacting = false }
        do {
            let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
            try await database.compact()
            compacted = true
            DiagnosticLog.shared.record(category: "存储", message: "整理数据库完成")
            UIAccessibility.post(notification: .announcement, argument: "整理数据库完成")
        } catch {
            DiagnosticLog.shared.record(.error, category: "存储", message: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }
}
