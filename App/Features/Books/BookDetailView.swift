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
    @State private var showsTableOfContents = false
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = model.originalWebPageURL {
                        Button("打开原网页", systemImage: "safari") { openWebPage(url) }
                            .accessibilityIdentifier("book.detail.openWebPage")
                    }
                    Button("换源", systemImage: "arrow.triangle.2.circlepath") { showsSourceSwitch = true }
                        .disabled(sourceLibrary.sources.filter(\.enabled).count < 2)
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
                    Divider()
                    Button("缓存接下来 10 章", systemImage: "arrow.down.circle") { model.startCaching(limit: 10, using: batchCache) }
                        .disabled(model.chapters.isEmpty || cacheProgress?.isActive == true)
                    Button("缓存剩余章节", systemImage: "square.and.arrow.down.on.square") { model.startCaching(limit: nil, using: batchCache) }
                        .disabled(model.chapters.isEmpty || cacheProgress?.isActive == true)
                    if cacheProgress?.isActive == true {
                        Divider()
                        Button("停止缓存", systemImage: "stop.circle", role: .destructive) { batchCache.cancel(bookURL: model.book.bookUrl) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
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
        .fullScreenCover(isPresented: $showsTableOfContents) {
            BookTableOfContentsView(book: model.book, chapters: model.chapters, source: model.source)
        }
    }

    @ViewBuilder
    private var detailScrollView: some View {
        if #available(iOS 16.0, *) {
            ScrollView { detailContent }
        } else {
            // On iOS 15 the native pull-to-refresh control is available on List.
            List {
                detailContent
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        }
    }

    private var detailContent: some View {
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
            chapterCard
            if let cacheProgress { cacheProgressCard(cacheProgress) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
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
                    height: 126
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
                NavigationLink {
                    ReaderView(demoBook: model.book, chapters: model.chapters, initialIndex: model.book.durChapterIndex, content: DemoContent.readerText)
                } label: { readingLabel }
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

    private var chapterCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录").font(.headline)
                Spacer()
                Text("\(model.chapters.count) 章").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
            if model.state == .loading || model.state == .idle {
                HStack { Spacer(); ProgressView("正在解析目录…"); Spacer() }.padding(.vertical, 28)
            } else if model.state == .findingSource {
                HStack { Spacer(); ProgressView("当前源不可用，正在自动寻找可用源…"); Spacer() }
                    .padding(.vertical, 28)
            } else if model.state == .failed {
                ReadingUnavailableView(
                    "没有找到可用目录",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text(model.browserDirectoryURL != nil ? "可下拉刷新重试，或在右上角菜单中换源。" : "已自动尝试其他可搜索书源，可稍后刷新重试或手动换源。")
                )
                .padding(.vertical, 12)
                if let issue = model.diagnostics.last(where: { $0.severity == .error && $0.code != "toc.empty" }) ?? model.diagnostics.last(where: { $0.severity == .error }) {
                    Text(issue.message).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(model.chapters.filter { !$0.isVolume }.prefix(8).enumerated()), id: \.element.id) { offset, chapter in
                    if offset > 0 { Divider() }
                    if chapter.isVolume {
                        Text(chapter.title).font(.subheadline.bold()).foregroundStyle(ReadingTheme.accent)
                            .padding(.vertical, 12)
                    } else {
                        BookChapterLink(book: model.book, chapters: model.chapters, source: model.source, index: chapter.index) {
                            HStack(spacing: 12) {
                                Text(String(format: "%02d", chapter.index + 1))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 28)
                                Text(chapter.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                if chapter.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if model.chapters.count > 8 {
                    Divider()
                    Button {
                        showsTableOfContents = true
                    } label: {
                        Label("查看全部目录", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }
}

private struct BookTableOfContentsView: View {
    @Environment(\.resumeBookReading) private var resume
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapters: [BookChapter]
    let source: BookSource
    @State private var searchText = ""
    @State private var descending = false
    @State private var selectedChapter: BookChapter?

    private var displayedChapters: [BookChapter] {
        let filtered = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return descending ? Array(filtered.reversed()) : filtered
    }

    var body: some View {
        ReadingNavigationStack {
            List(displayedChapters) { chapter in
                if chapter.isVolume {
                    Text(chapter.title).font(.headline).foregroundStyle(ReadingTheme.accent)
                } else {
                    Button {
                        if let resume { resume(book, chapters, source, chapter.index) }
                        else { selectedChapter = chapter }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(chapter.index + 1)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            Text(chapter.title).lineLimit(2)
                                .foregroundStyle(chapter.index == book.durChapterIndex ? ReadingTheme.accent : .primary)
                            if chapter.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                            Spacer()
                            ChapterAvailabilityIcon(bookURL: book.bookUrl, chapterURL: chapter.url, sourceID: source.id)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .id(descending)
            .readingNavigationDestination(isPresented: Binding(
                get: { selectedChapter != nil }, set: { if !$0 { selectedChapter = nil } }
            )) {
                if let chapter = selectedChapter {
                    ReaderView(book: book, chapters: chapters, initialIndex: chapter.index, source: source)
                }
            }
            .searchable(text: $searchText, prompt: "搜索目录")
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(descending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") {
                        descending.toggle()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(book.durChapterTitle ?? "尚未阅读").lineLimit(1)
                    Spacer()
                    Text("\(min(book.durChapterIndex + 1, chapters.count))/\(chapters.count)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}
