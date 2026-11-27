import SwiftUI

struct CachedTextExportView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @StateObject private var model = BookFileOperations()
    @State private var counts: [String: (cached: Int, total: Int)]?
    @State private var loadError: String?
    @State private var query = ""

    private var networkBooks: [Book] { library.books.filter { $0.origin != "local" } }

    var body: some View {
        List {
            if let loadError {
                Section {
                    Text(loadError)
                    Button("重新读取") { Task { await reload() } }
                }
            } else if let counts {
                let books = networkBooks.filter {
                    query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                        || $0.author.localizedCaseInsensitiveContains(query)
                }
                if networkBooks.isEmpty {
                    ReadingUnavailableView("还没有网络书籍", systemImage: "books.vertical",
                                           description: Text("将网络书加入书架后，可以在这里查看缓存并导出正文。"))
                } else if books.isEmpty {
                    ReadingUnavailableView.search(text: query)
                } else {
                    let cached = books.filter { counts[$0.bookUrl] != nil }
                    if !cached.isEmpty {
                        Section {
                            ForEach(cached) { book in
                                if let count = counts[book.bookUrl] {
                                    Button { export(book) } label: {
                                        bookRow(book, status: "已缓存 \(count.cached)/\(count.total) 章", action: "导出")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: { Text("可导出 · \(cached.count)") }
                        footer: { Text("正文按目录顺序导出为 TXT，缺少的章节会在文件中标记。") }
                        .listRowBackground(ReadingTheme.surface)
                    }
                    let uncached = books.filter { counts[$0.bookUrl] == nil }
                    if !uncached.isEmpty {
                        Section("尚未缓存 · \(uncached.count)") {
                            ForEach(uncached) { book in
                                if let source = sources.sources.first(where: { $0.bookSourceUrl == book.origin }) {
                                    NavigationLink { BookDetailView(book: book, source: source) } label: {
                                        bookRow(book, status: book.author, action: "去缓存")
                                    }
                                } else {
                                    bookRow(book, status: "原书源不可用", action: "")
                                }
                            }
                        }
                        .listRowBackground(ReadingTheme.surface)
                    }
                }
            } else {
                RagdollLoading("正在读取缓存…")
            }
        }
        .readingManagementList()
        .safeAreaInset(edge: .top, spacing: 0) {
            if !networkBooks.isEmpty {
                ReadingPillSearchField(placeholder: "搜索书名或作者", text: $query, fill: ReadingTheme.surface)
                    .background(ReadingTheme.settingsCanvas)
            }
        }
        .readingPageTitle("缓存正文导出")
        .task(id: networkBooks.map(\.bookUrl)) { await reload() }
        .refreshable { await reload() }
        .modifier(BookFileOperationFeedback(model: model))
    }

    private func bookRow(_ book: Book, status: String, action: String) -> some View {
        HStack(spacing: 12) {
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverURL, width: 34, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name).font(.headline).foregroundStyle(ReadingTheme.ink)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if !action.isEmpty { Text(action).font(.subheadline.weight(.medium)).foregroundStyle(ReadingTheme.accent) }
        }
        .contentShape(Rectangle())
    }

    private func reload() async {
        do {
            let snapshot = try await ChapterContentCache.live().exportCounts(
                for: networkBooks.map(\.bookUrl), directories: AppBookChapterRepository.live()
            )
            try Task.checkCancellation()
            counts = snapshot
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func export(_ book: Book) {
        Task {
            await model.run {
                let chapters = try await AppBookChapterRepository.live().load(bookURL: book.bookUrl)
                let file = try await model.exporter.cachedBook(book, chapters: chapters)
                model.present(file)
            }
            await reload()
        }
    }
}
