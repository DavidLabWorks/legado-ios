import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookDetailViewModel: ObservableObject {
    enum State: Equatable { case idle, loadingDetails, loading, findingSource, ready, failed }
    typealias SourceSwitchCommit = @MainActor (BookSourceSwitchReport) async -> Bool
    typealias PreparedUpdateCommit = @MainActor (BookUpdateReport) async -> Bool

    @Published private(set) var state: State = .idle
    @Published private(set) var book: Book
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var source: BookSource
    private var searchBook: SearchBook?
    private let service: NetworkBookService
    private let updateCoordinator: BookUpdateCoordinator
    private let sourceSwitchService: BookSourceSwitchService
    private var loadGeneration = 0
    private var directoryTask: Task<Void, Never>?
    private var restoredShelfBook = false
    private(set) var usedStoredDirectory = false

    init(
        searchBook: SearchBook,
        source: BookSource,
        service: NetworkBookService = .init(),
        chapterRepository: any BookChapterRepository = AppBookChapterRepository.live(),
        sourceSwitchService: BookSourceSwitchService? = nil
    ) {
        self.searchBook = searchBook
        self.source = source
        self.service = service
        let chapters = chapterRepository
        updateCoordinator = BookUpdateCoordinator(repository: chapters, loader: service)
        self.sourceSwitchService = sourceSwitchService ?? BookSourceSwitchService(
            detailLoader: service,
            chapterLoader: service,
            contentLoader: service
        )
        var book = Book(
            bookUrl: searchBook.bookURL,
            name: searchBook.name,
            author: searchBook.author,
            origin: source.bookSourceUrl
        )
        book.originName = source.bookSourceName
        book.coverUrl = searchBook.coverURL
        book.intro = searchBook.intro
        book.kind = searchBook.kind
        self.book = book
    }

    init(book: Book, source: BookSource, chapters: [BookChapter] = [], service: NetworkBookService = .init()) {
        searchBook = nil
        self.book = book
        self.source = source
        self.service = service
        self.chapters = chapters
        if !chapters.isEmpty { state = .ready }
        updateCoordinator = BookUpdateCoordinator(repository: AppBookChapterRepository.live(), loader: service)
        sourceSwitchService = BookSourceSwitchService(
            detailLoader: service,
            chapterLoader: service,
            contentLoader: service
        )
    }

    init(demoBook: Book, source: BookSource, chapters: [BookChapter]) {
        searchBook = nil
        book = demoBook
        self.source = source
        service = .init()
        updateCoordinator = .init()
        sourceSwitchService = .init()
        self.chapters = chapters
        state = .ready
    }

    @discardableResult
    func load(sources: [BookSource] = [], persistDirectory: Bool = true, runPreUpdateScript: Bool? = nil, forceRefresh: Bool = false,
              commitSourceSwitch: SourceSwitchCommit? = nil, commitPreparedUpdate: PreparedUpdateCommit? = nil) async -> Bool {
        guard state == .idle, !Task.isCancelled else { return false }
        directoryTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        state = searchBook == nil ? .loading : .loadingDetails
        usedStoredDirectory = false
        let work = Task {
            await loadDirectory(generation: generation, sources: sources, persistDirectory: persistDirectory,
                                runPreUpdateScript: runPreUpdateScript, forceRefresh: forceRefresh,
                                commitSourceSwitch: commitSourceSwitch, commitPreparedUpdate: commitPreparedUpdate)
        }
        directoryTask = work
        let timeout: Task<Void, Never>? = browserDirectoryURL == nil ? nil : Task {
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard generation == loadGeneration, chapters.isEmpty, state == .loading || state == .loadingDetails else { return }
            diagnostics.append(.init(severity: .error, code: "toc.timeout",
                                     message: "等待目录超过 15 秒。", rule: book.bookUrl))
            stopWaitingForDirectory()
        }
        defer {
            timeout?.cancel()
            if generation == loadGeneration { directoryTask = nil }
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
        return generation == loadGeneration && !Task.isCancelled
    }

    private func loadDirectory(generation: Int, sources: [BookSource], persistDirectory: Bool, runPreUpdateScript: Bool?,
                               forceRefresh: Bool, commitSourceSwitch: SourceSwitchCommit?,
                               commitPreparedUpdate: PreparedUpdateCommit?) async {
        guard acceptsLoad(generation) else { return }
        if searchBook == nil || restoredShelfBook {
            let stored = await updateCoordinator.storedChapters(bookURL: book.bookUrl)
            guard acceptsLoad(generation) else { return }
            if !stored.isEmpty {
                chapters = stored
                state = .ready
                if !forceRefresh, BookshelfReadViewModel.matchesReadingProgress(book, chapters: stored) {
                    usedStoredDirectory = true
                    return
                }
            }
        }
        var loadedDetail: BookDetailReport?
        if let searchBook {
            let detail = await service.loadDetail(searchBook: searchBook, source: source)
            guard acceptsLoad(generation) else { return }
            loadedDetail = detail
            let details = detail.book
            book.name = details.name
            book.author = details.author
            book.originName = details.originName
            if !details.tocUrl.isEmpty { book.tocUrl = details.tocUrl }
            book.type = details.type
            book.kind = details.kind ?? book.kind
            book.coverUrl = details.coverUrl ?? book.coverUrl
            book.intro = details.intro ?? book.intro
            book.charset = details.charset ?? book.charset
            book.wordCount = details.wordCount ?? book.wordCount
            book.latestChapterTitle = details.latestChapterTitle ?? book.latestChapterTitle
            book.originOrder = details.originOrder
            book.variable = details.variable ?? book.variable
            diagnostics += detail.diagnostics
        }
        if chapters.isEmpty { state = .loading }
        let oldBookURL = book.bookUrl
        let toc = await updateCoordinator.refresh(book: book, source: source, persistDirectory: persistDirectory,
                                                  runPreUpdateScript: runPreUpdateScript ?? (searchBook == nil), isFromBookInfo: searchBook != nil, detail: loadedDetail)
        guard acceptsLoad(generation) else { return }
        if toc.refreshed, toc.book.bookUrl != oldBookURL, let commitPreparedUpdate,
           !(await commitPreparedUpdate(toc)) {
            diagnostics += toc.diagnostics
            diagnostics.append(.init(severity: .error, code: "toc.persistence",
                message: "更新后的书籍地址保存失败，已保留原书籍和阅读位置。", rule: oldBookURL))
            state = chapters.isEmpty ? .failed : .ready
            return
        }
        guard acceptsLoad(generation) else { return }
        if !toc.chapters.isEmpty { chapters = toc.chapters }
        diagnostics += toc.diagnostics
        book = toc.book
        if book.bookUrl != oldBookURL { searchBook = nil }
        if !chapters.isEmpty {
            state = .ready
            return
        }

        if browserDirectoryURL != nil || qidianCatalogURL != nil {
            state = .failed
            return
        }
        state = .findingSource
        if let available = await sourceSwitchService.firstAvailableSource(for: book, sources: sources) {
            guard acceptsLoad(generation) else { return }
            if let commitSourceSwitch, !(await commitSourceSwitch(available.report)) {
                diagnostics.append(.init(severity: .error, code: "source_switch.persistence",
                    message: "自动换源保存失败，已保留当前书源和阅读位置。", rule: book.bookUrl))
                state = .failed
                return
            }
            await applySourceSwitch(available.report, source: available.source)
        } else {
            guard acceptsLoad(generation) else { return }
            state = .failed
        }
    }

    var qidianCatalogURL: URL? {
        guard URL(string: source.id)?.host == "www.qidian.com",
              let page = originalWebPageURL, page.scheme == "https", page.host == "www.qidian.com",
              page.path.range(of: #"^/book/[0-9]+/?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.qidian.com/book/\(page.lastPathComponent)/catalog/")
    }

    var originalWebPageURL: URL? { book.originalWebPageURL(sourceURL: source.id) }

    var browserDirectoryURL: URL? { book.origin == source.id ? book.browserDirectoryURL : nil }

    func stopWaitingForDirectory() {
        guard browserDirectoryURL != nil, chapters.isEmpty, state != .ready else { return }
        loadGeneration &+= 1
        directoryTask?.cancel()
        directoryTask = nil
        state = .failed
    }

    func useBrowserDirectory(_ rows: [[String: String]], at directory: URL) throws {
        guard chapters.isEmpty, directory == browserDirectoryURL else { throw CancellationError() }
        let parsed = try book.chapters(fromBrowserRows: rows, at: directory)
        stopWaitingForDirectory()
        let update = BookUpdateMerger().merge(book: book, oldChapters: chapters, newChapters: parsed,
                                              now: Int64(Date().timeIntervalSince1970 * 1000))
        book = update.book
        chapters = update.chapters
        state = .ready
    }

    private func acceptsLoad(_ generation: Int) -> Bool {
        guard generation == loadGeneration else { return false }
        guard !Task.isCancelled else { state = .idle; return false }
        return true
    }

    func applySourceSwitch(_ report: BookSourceSwitchReport, source: BookSource) async {
        loadGeneration &+= 1
        let cleanup = await ChapterBatchCache.shared.clearForSourceSwitch(from: book.bookUrl, to: report.book.bookUrl, cache: .live())
        searchBook = nil
        book = report.book
        chapters = report.chapters
        diagnostics = report.diagnostics + cleanup
        self.source = source
        state = .ready
    }

    func toggleCanUpdate() { book.canUpdate.toggle() }

    func reportDirectorySaveFailure(_ message: String?) {
        diagnostics.append(.init(severity: .error, code: "toc.persistence",
            message: message ?? "目录保存失败，已保留原有缓存。", rule: book.bookUrl))
    }

    func restoreLibraryBook(from stored: Book, sources: [BookSource] = []) {
        guard state == .idle, stored.bookUrl == book.bookUrl else { return }
        if stored.origin != source.id,
           let resolved = sources.first(where: { $0.id == stored.origin }) {
            source = resolved
            searchBook = nil
        }
        restoredShelfBook = stored.origin == source.id
        book = stored
        book.origin = source.id
        book.originName = source.bookSourceName
    }

    func restoreSourceAfterReading(from books: [Book], sources: [BookSource]) {
        guard state == .ready,
              let stored = books.first(where: { $0.bookUrl == book.bookUrl })
                ?? books.first(where: { $0.name == book.name && $0.author == book.author }),
              stored.bookUrl != book.bookUrl || stored.origin != book.origin,
              let source = sources.first(where: { $0.id == stored.origin }) else { return }
        book = stored
        self.source = source
        searchBook = nil
        chapters = []
        diagnostics = []
        state = .idle
    }

    func restoreUserSettings(from stored: Book) {
        guard stored.bookUrl == book.bookUrl else { return }
        book.group = stored.group
        book.order = stored.order
        book.customTag = stored.customTag
        book.customCoverUrl = stored.customCoverUrl
        book.customIntro = stored.customIntro
        book.canUpdate = stored.canUpdate
        book.readConfig = stored.readConfig
        book.syncTime = stored.syncTime
    }

    func restoreReadingProgress(from stored: Book) {
        guard stored.bookUrl == book.bookUrl, stored.durChapterTime > book.durChapterTime else { return }
        let chapterIndex = stored.durChapterTitle.flatMap { title in
            let position = min(max(stored.durChapterIndex, 0), max(chapters.count - 1, 0))
            return chapters.indices.filter { !chapters[$0].isVolume && chapters[$0].title == title }
                .min { abs($0 - position) < abs($1 - position) }
        } ?? stored.durChapterIndex
        guard chapters.indices.contains(chapterIndex), !chapters[chapterIndex].isVolume else { return }
        book.durChapterIndex = chapterIndex
        book.durChapterTitle = chapters[chapterIndex].title
        book.durChapterPos = stored.durChapterPos
        book.durChapterTime = stored.durChapterTime
    }

    @discardableResult
    func refresh(sources: [BookSource] = [], persistDirectory: Bool = true,
                 commitSourceSwitch: SourceSwitchCommit? = nil, commitPreparedUpdate: PreparedUpdateCommit? = nil) async -> Bool {
        chapters = []
        diagnostics = []
        state = .idle
        return await load(sources: sources, persistDirectory: persistDirectory, runPreUpdateScript: true, forceRefresh: true,
                   commitSourceSwitch: commitSourceSwitch, commitPreparedUpdate: commitPreparedUpdate)
    }
}

extension URL {
    static func originalWebPage(from rule: String, relativeTo base: String) -> URL? {
        // An imported address can include Legado request options after the URL.
        let end = rule.range(of: #",\s*(?=\{)"#, options: .regularExpression)?.lowerBound ?? rule.endIndex
        let address = rule[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.hasPrefix("<"), !address.lowercased().hasPrefix("@js:"), !address.contains("{{"),
              let url = URL(string: address, relativeTo: URL(string: base))?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

extension Book {
    func originalWebPageURL(sourceURL: String) -> URL? {
        URL.originalWebPage(from: bookUrl, relativeTo: sourceURL)
    }

    var browserDirectoryURL: URL? {
        guard origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://101kks.com",
              let page = originalWebPageURL(sourceURL: origin), page.scheme == "https",
              page.host == "101kks.com", page.user == nil, page.password == nil, page.port == nil || page.port == 443,
              page.path.range(of: #"^/book/[0-9]+(?:\.html|/index\.html)$"#, options: .regularExpression) != nil
        else { return nil }
        let bookID = page.pathComponents[2].components(separatedBy: ".")[0]
        return URL(string: "https://101kks.com/book/\(bookID)/index.html")
    }

    static func isBrowserChapterAddress(_ address: String, in directory: URL) -> Bool {
        let bookID = directory.deletingLastPathComponent().lastPathComponent
        return address.range(of: #"^https://101kks\.com/txt/\#(bookID)/[0-9]+\.html$"#, options: .regularExpression) != nil
    }

    func chapters(fromBrowserRows rows: [[String: String]], at directory: URL) throws -> [BookChapter] {
        guard directory == browserDirectoryURL else { throw CancellationError() }
        var seen = Set<String>()
        var parsed = [BookChapter]()
        for row in rows {
            guard let address = row["url"], let title = row["title"], !title.isEmpty,
                  Self.isBrowserChapterAddress(address, in: directory),
                  seen.insert(address).inserted else { continue }
            var chapter = BookChapter(url: address, title: title, bookUrl: bookUrl, index: parsed.count)
            chapter.baseUrl = directory.absoluteString
            parsed.append(chapter)
        }
        guard !parsed.isEmpty else {
            throw NSError(domain: "BrowserDirectory", code: 2, userInfo: [NSLocalizedDescriptionKey: "网页中没有找到这本书的章节。"])
        }
        return parsed
    }
}
