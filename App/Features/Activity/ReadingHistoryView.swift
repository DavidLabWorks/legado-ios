import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @AppStorage("readRecordSort") private var sortMode = 0
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var pendingDelete: ReadRecordSummary?

    private var displayedRecords: [ReadRecordSummary] {
        activity.summaries(searchKey: searchText, sortMode: sortMode)
    }

    var body: some View {
        let summaries = activity.summaries
        let records = displayedRecords
        VStack(spacing: 0) {
            ReadingPillSearchField(placeholder: "搜索书名", text: $searchText)
            if summaries.isEmpty {
                ReadingIllustratedEmptyState(
                    artwork: "HistoryEmptyArtwork",
                    title: "还没有阅读记录",
                    message: enableReadRecord ? "翻页后会按设备累计阅读时长" : "阅读记录当前已关闭"
                ) { EmptyView() }
            } else {
                List {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("累计阅读", systemImage: "clock")
                            .font(.subheadline)
                        Text(duration(summaries.reduce(0) { $0 + $1.readTime }))
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("读过 \(summaries.count) 本书")
                            .font(.subheadline)
                    }
                    .foregroundStyle(ReadingTheme.onAccent)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ReadingTheme.emphasisSurface, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityElement(children: .combine)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(ReadingTheme.canvas)

                    if records.isEmpty {
                        ReadingUnavailableView.search(text: searchText)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(records) { record in
                            let book = books.books.first { $0.name == record.bookName }
                            NavigationLink {
                                destination(for: record, book: book)
                            } label: {
                                HStack(spacing: 14) {
                                    BookCoverArtwork(title: record.bookName, author: book?.author ?? "",
                                                     remoteURL: book?.displayCoverURL, width: 44, height: 62)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.bookName).font(.headline).foregroundStyle(ReadingTheme.ink)
                                        Text("已读 " + duration(record.readTime)).font(.subheadline)
                                        if record.lastRead > 0 {
                                            Text("最后阅读 " + date(record.lastRead))
                                                .font(.caption)
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowBackground(ReadingTheme.canvas)
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = record }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .readingScrollContentBackgroundHidden()
            }
        }
        .readingPageTitle("阅读记录")
        .navigationBarHidden(false)
        .background(ReadingTheme.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("阅读记录选项", systemImage: "ellipsis") {
                    Toggle("记录阅读时长", isOn: $enableReadRecord)
                    Section("排序") {
                        sortButton("书名", value: 0)
                        sortButton("阅读时长", value: 1)
                        sortButton("最后阅读", value: 2)
                    }
                    if !summaries.isEmpty {
                        Button("清空", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    }
                }
            }
        }
        .alert("清空阅读记录", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await activity.clearHistory() } }
        } message: {
            Text("确定删除全部阅读记录吗？")
        }
        .alert("删除阅读记录", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                guard let record = pendingDelete else { return }
                pendingDelete = nil
                Task { await activity.removeHistory(bookName: record.bookName) }
            }
        } message: {
            Text("确定删除“\(pendingDelete?.bookName ?? "")”的阅读记录吗？")
        }
    }

    @ViewBuilder private func destination(for record: ReadRecordSummary, book: Book?) -> some View {
        if let book {
            BookshelfReadView(
                book: book,
                source: sources.sources.first(where: { $0.bookSourceUrl == book.origin })
            )
        } else {
            SearchView(initialKeyword: record.bookName)
        }
    }

    @ViewBuilder private func sortButton(_ title: String, value: Int) -> some View {
        Button {
            sortMode = value
        } label: {
            if sortMode == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func duration(_ milliseconds: Int64) -> String {
        let value = max(milliseconds, 0)
        let days = value / 86_400_000
        let hours = value % 86_400_000 / 3_600_000
        let minutes = value % 3_600_000 / 60_000
        let seconds = value % 60_000 / 1_000
        var result = ""
        if days > 0 { result += "\(days)天" }
        if hours > 0 { result += "\(hours)小时" }
        if minutes > 0 { result += "\(minutes)分钟" }
        if seconds > 0 { result += "\(seconds)秒" }
        return result.isEmpty ? "0秒" : result
    }

    private func date(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        guard milliseconds > 0 else { return "" }
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
