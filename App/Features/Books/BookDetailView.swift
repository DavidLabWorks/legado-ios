import SwiftUI

struct BookDetailView: View {
    @Environment(\.resumeBookReading) private var resume
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: BookDetailViewModel
    @ObservedObject private var batchCache = ChapterBatchCache.shared
    private var cacheProgress: ChapterBatchCache.Progress? { batchCache.progress[model.book.bookUrl] }

    private struct WebPage: Identifiable {
        let url: URL
        let directory: URL?
        var id: URL { url }
    }

    @State private var refreshTask: Task<Void, Never>?
    @State private var webPage: WebPage?
    @State private var showsSourceSwitch = false
    @State private var showsDemoReader = false
    @State private var warmedReader: ReaderViewModel?
    @State private var openedReader: ReaderViewModel?
    @State private var opening: Task<Void, Never>?

    init(searchBook: SearchBook, source: BookSource) {
        _model = StateObject(wrappedValue: BookDetailViewModel(searchBook: searchBook, source: source))
    }

    init(book: Book, source: BookSource, chapters: [BookChapter] = []) {
        _model = StateObject(wrappedValue: BookDetailViewModel(book: book, source: source, chapters: chapters))
    }

    init(demoBook: Book, source: BookSource, chapters: [BookChapter]) {
        batchCache = ChapterBatchCache(progress: [demoBook.bookUrl: .init(total: chapters.filter { !$0.isVolume }.count, processed: 2)])
        _model = StateObject(wrappedValue: BookDetailViewModel(demoBook: demoBook, source: source, chapters: chapters))
    }

    var body: some View {
        detailScrollView
        .refreshable { await refreshDetails() }
        .background(ReadingTheme.canvas)
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("换源") { showsSourceSwitch = true }
                    .disabled(sourceLibrary.sources.filter(\.enabled).count < 2)
                Menu {
                    if let url = model.originalWebPageURL {
                        Button("打开原网页", systemImage: "safari") { openWebPage(url) }
                            .accessibilityIdentifier("book.detail.openWebPage")
                    }
                    Button("允许更新", systemImage: model.book.canUpdate ? "checkmark" : "circle") {
                        model.toggleCanUpdate()
                        Task { await saveCurrentBook() }
                    }
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await refreshDetails() }
                    }
                    if model.source.loginUrl?.isEmpty == false {
                        NavigationLink {
                            SourceLoginView(source: model.source)
                        } label: {
                            Label("登录", systemImage: "person.badge.key")
                        }
                    }
                    ReadingShareLink(item: model.book.bookUrl) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .task {
            model.restoreSourceAfterReading(from: library.books, sources: sourceLibrary.sources)
            let oldURL = model.book.bookUrl
            let shouldPersistUpdate = library.contains(model.book)
            if let stored = library.books.first(where: { $0.bookUrl == oldURL }) {
                model.restoreLibraryBook(from: stored, sources: sourceLibrary.sources)
            }
            let requestedBook = model.book
            let applied = await model.load(sources: sourceLibrary.sources, persistDirectory: false, runPreUpdateScript: shouldPersistUpdate, commitSourceSwitch: { report in
                guard shouldPersistUpdate else { return true }
                return await library.commitSourceSwitch(oldBookURL: oldURL, report: report)
            }, commitPreparedUpdate: { report in
                guard shouldPersistUpdate else { return true }
                return await library.commitPreparedUpdate(requestedBook: requestedBook, report: report)
            })
            if library.contains(model.book) {
                if let stored = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
                    model.restoreUserSettings(from: stored)
                    model.restoreReadingProgress(from: stored)
                }
                if applied, !model.usedStoredDirectory, oldURL == model.book.bookUrl, model.state == .ready {
                    await saveLoadedDirectory()
                }
            }
        }
        .task(id: model.chapters.isEmpty ? nil : model.book) {
            warmedReader = nil
            guard resume == nil, !model.chapters.isEmpty, !ProcessInfo.processInfo.arguments.contains("-uiDemo") else { return }
            let reader = await ReaderViewModel.cachedOpening(book: model.book, chapters: model.chapters, source: model.source,
                                                             rules: replaceRules.rules, speculative: true)
            if !Task.isCancelled, reader.hasLoadedCurrentChapter { warmedReader = reader }
        }
        .onDisappear { opening?.cancel(); warmedReader = nil }
        .readingNavigationDestination(isPresented: $showsDemoReader) {
            ReaderView(demoBook: model.book, chapters: model.chapters, initialIndex: model.book.durChapterIndex, content: DemoContent.readerText)
        }
        .readingNavigationDestination(isPresented: Binding(
            get: { openedReader != nil }, set: { if !$0 { openedReader = nil } }
        )) {
            if let openedReader { ReaderView(prepared: openedReader) }
        }
        .onChange(of: model.state) { state in
            if state == .failed, model.chapters.isEmpty, webPage == nil, !showsSourceSwitch,
               let directory = model.browserDirectoryURL {
                openWebPage(directory)
            }
        }
        .onChange(of: model.source.id) { _ in
            resume?(model.book, model.chapters, model.source, nil)
        }
        .sheet(item: $webPage) { page in
            if let directory = page.directory {
                BrowserBookPageView(url: page.url, action: .directory(directory) { rows in
                    try model.useBrowserDirectory(rows, at: directory)
                    if library.contains(model.book) { await saveLoadedDirectory() }
                })
            } else {
                InAppWebBrowser(url: page.url, close: { webPage = nil })
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showsSourceSwitch) {
            ReadingNavigationStack {
                SourceSwitchView(book: model.book, sources: sourceLibrary.sources) { report, source in
                    let oldURL = model.book.bookUrl
                    if library.contains(model.book) {
                        guard await library.commitSourceSwitch(oldBookURL: oldURL, report: report) else { return false }
                    }
                    await model.applySourceSwitch(report, source: source)
                    return true
                }
            }
        }
    }

    private var detailScrollView: some View {
        List {
            VStack(alignment: .leading, spacing: 24) {
                hero
                Divider()
                if let intro = MetadataTextSanitizer().clean(model.book.intro), !intro.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("简介").font(.headline)
                        Text(intro).font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                    }
                    Divider()
                }
                if let cacheProgress { cacheProgressCard(cacheProgress) }
            }
            .listRowSeparator(.hidden)
            chapterList
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .readingScrollContentBackgroundHidden()
    }

    @MainActor
    private func refreshDetails() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task {
            defer { refreshTask = nil }
            let requestedBook = model.book
            let oldURL = model.book.bookUrl
            let wasInLibrary = library.contains(model.book)
            let applied = await model.refresh(sources: sourceLibrary.sources, persistDirectory: false, commitSourceSwitch: { report in
                guard wasInLibrary else { return true }
                return await library.commitSourceSwitch(oldBookURL: oldURL, report: report)
            }, commitPreparedUpdate: { report in
                guard wasInLibrary else { return true }
                return await library.commitPreparedUpdate(requestedBook: requestedBook, report: report)
            })
            if applied, wasInLibrary, oldURL == model.book.bookUrl, model.state == .ready {
                await saveLoadedDirectory()
            }
        }
        refreshTask = task
        await task.value
    }

    private func cacheProgressCard(_ progress: ChapterBatchCache.Progress) -> some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(progress.title, systemImage: progress.isActive ? "arrow.down.circle.fill" : (progress.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle"))
                        .font(.headline)
                    Spacer()
                    Text("\(progress.processed)/\(progress.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                    .tint(ReadingTheme.accent)
                if progress.isActive {
                    Button("停止缓存", role: .destructive) { batchCache.cancel(bookURL: model.book.bookUrl) }
                        .font(.subheadline)
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                BookCoverArtwork(
                    title: model.book.name,
                    author: model.book.author,
                    remoteURL: model.book.displayCoverURL,
                    width: 88,
                    height: 126,
                    allowsPreview: true
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.book.name).font(.title2.weight(.semibold)).lineLimit(3)
                    Text(model.book.author.isEmpty ? "未知作者" : model.book.author)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let kind = model.book.kind, !kind.isEmpty {
                        Text(kind).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.source.bookSourceName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let latest = model.book.latestChapterTitle, !latest.isEmpty {
                Text("更新至 \(latest)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { readingActions }
                } else {
                    HStack(spacing: 12) { readingActions }
                }
            }
            .controlSize(.large)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var readingActions: some View {
        Group {
            if let resume {
                Button { resume(model.book, model.chapters, model.source, nil) } label: { readingLabel }
            } else if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                Button { showsDemoReader = true } label: { readingLabel }
            } else {
                Button(action: openReader) { readingLabel }
            }
        }
        .readingProminentButtonStyle()
        .disabled(model.chapters.isEmpty)
        Button {
            if library.contains(model.book) {
                Task { await library.remove(bookURL: model.book.bookUrl) }
            } else {
                Task { await saveCurrentBook() }
            }
        } label: {
            Label(
                library.contains(model.book) ? "已在书架" : "加入书架",
                systemImage: library.contains(model.book) ? "checkmark" : "plus"
            )
            .font(.subheadline)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 28)
        }
        .readingSecondaryButtonStyle()
    }

    private var readingLabel: some View {
        Text(model.book.durChapterIndex > 0 || model.book.durChapterPos > 0 ? "继续阅读" : "开始阅读")
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 28)
    }

    private func openWebPage(_ url: URL) {
        let directory = model.chapters.isEmpty ? model.browserDirectoryURL : nil
        if directory != nil { model.stopWaitingForDirectory() }
        webPage = WebPage(url: url, directory: directory)
    }

    private func openReader() {
        opening?.cancel()
        opening = Task {
            let reader = await ReaderViewModel.cachedOpening(book: model.book, chapters: model.chapters, source: model.source,
                                                             rules: replaceRules.rules, reusing: warmedReader)
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = reader.hasLoadedCurrentChapter
            withTransaction(transaction) { openedReader = reader }
        }
    }

    private func saveCurrentBook() async {
        await library.addOrUpdate(model.book, chapters: model.chapters)
        if let stored = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
            model.restoreReadingProgress(from: stored)
        }
    }

    private func saveLoadedDirectory() async {
        let report = BookSourceSwitchReport(book: model.book, chapters: model.chapters, exactChapterMatch: true)
        if !(await library.commitSourceSwitch(oldBookURL: model.book.bookUrl, report: report)) {
            model.reportDirectorySaveFailure(library.errorMessage)
        }
    }

    private var directoryFailureHint: String {
        if model.qidianCatalogURL != nil { return "起点暂未返回目录，可下拉重试或打开官方目录。" }
        if model.browserDirectoryURL != nil { return "可下拉刷新重试，或轻点右上角的「换源」。" }
        return "已自动尝试其他可搜索书源，可稍后刷新重试或手动换源。"
    }

    @ViewBuilder
    private var chapterList: some View {
        if model.state == .loadingDetails {
            HStack { Spacer(); ProgressView("正在加载作品详情…"); Spacer() }.padding(.vertical, 28)
        } else if model.state == .loading || model.state == .idle {
            HStack { Spacer(); ProgressView("正在解析目录…"); Spacer() }.padding(.vertical, 28)
        } else if model.state == .findingSource {
            HStack { Spacer(); ProgressView("当前源不可用，正在自动寻找可用源…"); Spacer() }
                .padding(.vertical, 28)
        } else if model.state == .failed {
            ReadingUnavailableView(
                "没有找到可用目录",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                description: Text(directoryFailureHint)
            )
            .padding(.vertical, 12)
            if let url = model.qidianCatalogURL {
                Button("打开起点官方目录") { openWebPage(url) }
            }
            if let issue = model.diagnostics.last(where: { $0.severity == .error && $0.code != "toc.empty" }) ?? model.diagnostics.last(where: { $0.severity == .error }) {
                Text(issue.message).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            BookDetailChapterRows(book: model.book, chapters: model.chapters, source: model.source)
        }
    }
}

struct BookDetailChapterRows: View {
    let book: Book
    let chapters: [BookChapter]
    var source: BookSource?
    @State private var descending = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("目录").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text("\(chapters.count) 章").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if chapters.count > 1 {
                    Button { descending.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down").imageScale(.small)
                            Text(descending ? "正序" : "倒序")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            Divider()
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        .listRowSeparator(.hidden)

        if #available(iOS 17.0, *) {
            chapterRows.navigationLinkIndicatorVisibility(.hidden)
        } else {
            chapterRows
        }
    }

    private var chapterRows: some View {
        ForEach(descending ? Array(chapters.reversed()) : chapters, id: \.index) { chapter in
            if chapter.isVolume {
                ChapterVolumeLabel(title: chapter.title)
            } else {
                BookChapterLink(book: book, chapters: chapters, source: source, index: chapter.index) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        ChapterDirectoryLabel(number: chapter.index + 1, count: chapters.count,
                                              title: chapter.title)
                        if chapter.isVip {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("VIP 章节")
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

struct ChapterDirectoryLabel: View {
    let number: Int
    let count: Int
    let title: String
    var isCurrent = false
    @ScaledMetric(relativeTo: .caption) private var digitWidth: CGFloat = 8
    private static let chapterPrefix = try! NSRegularExpression(
        pattern: #"^\s*(第\s*[0-9０-９零〇一二两兩三四五六七八九十百千万萬]+\s*[章节節回话話集卷])\s*"#
    )

    private var heading: (marker: String?, name: String) {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return (nil, "第\(number)章") }
        guard let match = Self.chapterPrefix.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)),
              let prefix = Range(match.range(at: 1), in: original),
              let matched = Range(match.range, in: original) else {
            return (String(format: "%02d", number), original)
        }
        let remainder = original[matched.upperBound...].drop(while: { $0.isWhitespace || "·:：、".contains($0) })
        return remainder.isEmpty ? (nil, original) : (String(original[prefix]), String(remainder))
    }

    var body: some View {
        let heading = self.heading
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let marker = heading.marker {
                Text(verbatim: marker)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: digitWidth * CGFloat(3 + max(2, String(count).count)), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(heading.name)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent {
                Image(systemName: "bookmark.fill")
                    .font(.footnote)
                    .foregroundStyle(ReadingTheme.accent)
                    .accessibilityLabel("正在阅读")
            }
        }
    }
}

struct ChapterVolumeLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(ReadingTheme.separator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .padding(.top, 8)
    }
}
