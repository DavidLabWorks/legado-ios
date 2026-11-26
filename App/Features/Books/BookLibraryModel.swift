import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

final class LocalBookImportFile: @unchecked Sendable {
    let url: URL
    private let hasSecurityScope: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

private struct BookDirectoryRestoreError: LocalizedError {
    let saveError: String
    let restoreError: String
    var errorDescription: String? {
        "书籍与目录保存失败：\(saveError)。原目录恢复也失败：\(restoreError)。请重新加载原书源目录。"
    }
}

enum AppBookChapterRepository {
    static func live() -> any BookChapterRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            return FileBookChapterRepository.live()
        }
        return SQLiteBookChapterRepository(
            database: database,
            legacyDirectory: base.appendingPathComponent("Chapters", isDirectory: true)
        )
    }
}

enum BookshelfSort: Int, CaseIterable, Identifiable {
    case recentRead = 0, recentUpdate, name, custom, recentReadOrUpdate, author

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .recentRead: "最近阅读"
        case .recentUpdate: "最近更新"
        case .name: "书名"
        case .custom: "自定义顺序"
        case .recentReadOrUpdate: "阅读或更新"
        case .author: "作者"
        }
    }
}

extension BookGroup {
    var bookshelfSort: BookshelfSort { BookshelfSort(rawValue: bookSort) ?? .recentRead }
}

@MainActor
final class BookLibraryModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var groups: [BookGroup] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var updateMessage: String?
    private(set) var booksRequiringVerification: [Book] = []
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var checkingBookURLs: Set<String> = []

    private let repository: any BookRepository
    private let localDirectory: URL
    let localFiles: LocalFileService
    private let localService = LocalBookService.live()
    private let txtTocRuleRepository: SQLiteConfigurationRepository?
    let updateCoordinator: BookUpdateCoordinator
    private let chapterRepository: any BookChapterRepository
    private let chapterCache: ChapterContentCache
    private let groupRepository: any BookGroupRepository
    private let pendingProgressKey = "pendingBookReadingProgress"
    private let progressDefaults: UserDefaults
    private var pendingProgress: [String: BookProgress]
    private var bookSaveTask: Task<Bool, Never>?
    private var bookSaveGeneration = 0
    private var persistedBooks: [Book] = []
    private var groupSaveTask: Task<Bool, Never>?
    private var groupSaveGeneration = 0
    private var persistedGroups: [BookGroup] = []
    private var deletingGroupIDs: Set<Int64> = []
    private var sourceSwitchSaveTask: Task<Bool, Never>?
    private var loadGeneration = 0

    init(
        repository: any BookRepository,
        localDirectory: URL? = nil,
        updateCoordinator: BookUpdateCoordinator = .init(),
        chapterRepository: any BookChapterRepository = FileBookChapterRepository.live(),
        groupRepository: any BookGroupRepository = InMemoryBookGroupRepository(),
        chapterCache: ChapterContentCache = .live(),
        progressDefaults: UserDefaults = .standard,
        txtTocRuleRepository: SQLiteConfigurationRepository? = nil
    ) {
        self.repository = repository
        self.localDirectory = localDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("LegadoLocalBooks")
        localFiles = LocalFileService(directory: self.localDirectory)
        self.updateCoordinator = updateCoordinator
        self.chapterRepository = chapterRepository
        self.chapterCache = chapterCache
        self.groupRepository = groupRepository
        self.progressDefaults = progressDefaults
        self.txtTocRuleRepository = txtTocRuleRepository
        pendingProgress = (progressDefaults.data(forKey: pendingProgressKey)
            .flatMap { try? JSONDecoder().decode([String: BookProgress].self, from: $0) }) ?? [:]
    }

    static func live() -> BookLibraryModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado", isDirectory: true)
        let legacyBooks = base.appendingPathComponent("books.json")
        guard let database = try? LegadoDatabase(url: base.appendingPathComponent("legado.sqlite3")) else {
            return BookLibraryModel(
                repository: FileBookRepository(fileURL: legacyBooks),
                localDirectory: base.appendingPathComponent("LocalBooks", isDirectory: true),
                groupRepository: FileBookGroupRepository(fileURL: base.appendingPathComponent("book-groups.json"))
            )
        }
        let chapters = SQLiteBookChapterRepository(
            database: database,
            legacyDirectory: base.appendingPathComponent("Chapters", isDirectory: true)
        )
        return BookLibraryModel(
            repository: SQLiteBookRepository(database: database, legacyFileURL: legacyBooks),
            localDirectory: base.appendingPathComponent("LocalBooks", isDirectory: true),
            updateCoordinator: BookUpdateCoordinator(repository: chapters),
            chapterRepository: chapters,
            groupRepository: SQLiteBookGroupRepository(
                database: database,
                legacyFileURL: base.appendingPathComponent("book-groups.json")
            ),
            txtTocRuleRepository: SQLiteConfigurationRepository(database: database)
        )
    }

    static func demo(books: [Book]) -> BookLibraryModel {
        BookLibraryModel(repository: InMemoryBookRepository(books: books))
    }

    func waitForBackupSnapshot() async throws {
        guard !isCheckingUpdates else { throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "书架正在检查更新，请稍后再试。"]) }
        await waitForSourceSwitch()
        _ = await bookSaveTask?.value
        _ = await groupSaveTask?.value
    }

    func reloadAfterBackup() async {
        pendingProgress = progressDefaults.data(forKey: pendingProgressKey).flatMap { try? JSONDecoder().decode([String: BookProgress].self, from: $0) } ?? [:]
        await load()
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let booksGeneration = bookSaveGeneration
        let groupsGeneration = groupSaveGeneration
        await waitForSourceSwitch()
        _ = await bookSaveTask?.value
        _ = await groupSaveTask?.value
        guard generation == loadGeneration, !Task.isCancelled else { return }
        do {
            async let storedBooks = repository.load()
            async let storedGroups = groupRepository.load()
            let loadedBooks = try await storedBooks
            let loadedGroups = try await storedGroups
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if booksGeneration == bookSaveGeneration, sourceSwitchSaveTask == nil {
                books = loadedBooks
                persistedBooks = loadedBooks
            }
            if groupsGeneration == groupSaveGeneration {
                groups = loadedGroups
                persistedGroups = loadedGroups
                if groups.isEmpty {
                    await persistGroups([.init(groupId: BookGroup.idAll, groupName: "全部", order: 0)])
                }
            }
            for book in books where book.origin == "local" && book.coverUrl?.isEmpty != false {
                guard !Task.isCancelled, let url = URL(string: book.bookUrl),
                      url.isFileURL, url.pathExtension.lowercased() == "epub" else { continue }
                if let cover = try? await Task.detached(priority: .utility, operation: { [localService] in
                    try localService.loadCover(at: url)
                }).value {
                    await restoreLocalCover(for: book, dataURL: "data:image/png;base64,\(cover.base64EncodedString())")
                }
            }
        } catch {
            if generation == loadGeneration, booksGeneration == bookSaveGeneration, groupsGeneration == groupSaveGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    func contains(_ book: Book) -> Bool {
        books.contains { $0.bookUrl == book.bookUrl }
    }

    func setCover(for book: Book, imageData: Data) async throws {
        let thumbnail = await Task.detached(priority: .userInitiated) { BookCoverThumbnail.png(imageData) }.value
        guard let thumbnail else { throw CocoaError(.fileReadCorruptFile) }
        await waitForSourceSwitch()
        try Task.checkCancellation()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl && $0.origin == book.origin }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var updated = books
        updated[index].customCoverUrl = "data:image/png;base64," + thumbnail.base64EncodedString()
        guard await persist(updated) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A reader holds a snapshot. Save only the setting it changed, retaining
    /// current shelf metadata/progress and leaving unshelved previews unshelved.
    @discardableResult
    func updateReadConfig(for book: Book, _ change: (inout BookReadConfig) -> Void) async -> Bool {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl && $0.origin == book.origin }) else { return false }
        var updated = books
        var config = updated[index].readConfig ?? BookReadConfig()
        change(&config)
        updated[index].readConfig = config
        return await persist(updated)
    }

    @discardableResult
    func addOrUpdate(_ book: Book, chapters: [BookChapter] = [], replacing expected: Book? = nil) async -> Bool {
        await waitForSourceSwitch()
        if chapters.isEmpty, expected == nil { return await saveBook(book, chapters: []) }
        let save = Task { @MainActor in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            if let expected, !books.contains(expected) { return false }
            return await saveBook(book, chapters: chapters)
        }
        sourceSwitchSaveTask = save
        return await save.value
    }

    private func saveBook(_ book: Book, chapters: [BookChapter]) async -> Bool {
        var book = book
        if let existing = books.first(where: { $0.bookUrl == book.bookUrl }),
           existing.durChapterTime > book.durChapterTime {
            applyProgress(BookProgress(book: existing), to: &book)
        }
        let pending = pendingProgress[book.bookUrl]
        if let pending {
            if pending.durChapterTime > book.durChapterTime {
                applyProgress(pending, to: &book)
            }
        }
        var updated = books
        if let index = updated.firstIndex(where: { $0.bookUrl == book.bookUrl }) {
            book.customCoverUrl = updated[index].customCoverUrl ?? book.customCoverUrl
            updated[index] = book
        } else {
            updated.append(book)
        }
        let succeeded: Bool
        if chapters.isEmpty {
            succeeded = await persist(updated)
        } else {
            let snapshot = updated
            let bookURL = book.bookUrl
            succeeded = await persist(snapshot) { [repository, chapterRepository] in
                try await Self.writeBooksAndChapters(snapshot, chapters: chapters, bookURL: bookURL,
                                                     repository: repository, chapterRepository: chapterRepository)
            }
        }
        if succeeded, let pending, pendingProgress[book.bookUrl] == pending {
            pendingProgress[book.bookUrl] = nil
            persistPendingProgress()
        }
        return succeeded
    }

    @discardableResult
    func replace(oldBookURL: String, with book: Book) async -> Bool {
        await waitForSourceSwitch()
        guard books.contains(where: { $0.bookUrl == oldBookURL }) else {
            return await addOrUpdate(book)
        }
        var updated = books.filter { $0.bookUrl == oldBookURL || $0.bookUrl != book.bookUrl }
        guard let index = updated.firstIndex(where: { $0.bookUrl == oldBookURL }) else { return false }
        updated[index] = book
        let succeeded = await persist(updated)
        if succeeded, oldBookURL != book.bookUrl {
            await cleanupRemovedBooks([oldBookURL])
        }
        return succeeded
    }

    /// Commit only after validation. Keep other shelf mutations outside the
    /// commit so a failed optimistic snapshot cannot leak into a later save.
    func commitSourceSwitch(oldBookURL: String, report: BookSourceSwitchReport) async -> Bool {
        await waitForSourceSwitch()
        guard !Task.isCancelled else { return false }
        let save = Task { @MainActor [self, repository, chapterRepository] in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            guard books.contains(where: { $0.bookUrl == oldBookURL }), !report.chapters.isEmpty else { return false }
            var updated = books.filter { $0.bookUrl == oldBookURL || $0.bookUrl != report.book.bookUrl }
            guard let index = updated.firstIndex(where: { $0.bookUrl == oldBookURL }) else { return false }
            var replacement = report.book
            replacement.customCoverUrl = updated[index].customCoverUrl ?? replacement.customCoverUrl
            updated[index] = replacement
            let snapshot = updated
            let succeeded = await persist(snapshot) {
                try await Self.writeBooksAndChapters(snapshot, chapters: report.chapters, bookURL: report.book.bookUrl,
                                                     repository: repository, chapterRepository: chapterRepository)
            }
            if succeeded, oldBookURL != report.book.bookUrl { await cleanupRemovedBooks([oldBookURL]) }
            return succeeded
        }
        sourceSwitchSaveTask = save
        return await save.value
    }

    private nonisolated static func writeBooksAndChapters(
        _ books: [Book], chapters: [BookChapter], bookURL: String,
        repository: any BookRepository, chapterRepository: any BookChapterRepository
    ) async throws {
        if let atomic = repository as? any SourceSwitchBookRepository {
            try await atomic.saveSourceSwitch(books, chapters: chapters, bookURL: bookURL)
            return
        }
        let previous = try await chapterRepository.load(bookURL: bookURL)
        do {
            try await chapterRepository.save(chapters, bookURL: bookURL)
            try await repository.save(books)
        } catch {
            let saveError = error
            do {
                try await chapterRepository.save(previous, bookURL: bookURL)
            } catch {
                let failure = BookDirectoryRestoreError(saveError: saveError.localizedDescription, restoreError: error.localizedDescription)
                DiagnosticLog.shared.record(.error, category: "存储", message: failure.localizedDescription)
                throw failure
            }
            throw saveError
        }
    }

    private func waitForSourceSwitch() async {
        while let save = sourceSwitchSaveTask { _ = await save.value }
    }

    func updateProgress(for book: Book, chapter: BookChapter, position: Int = 0, epubLocation: String? = nil) async {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }) else {
            var reading = book
            if epubLocation != nil, reading.readConfig == nil { reading.readConfig = BookReadConfig() }
            reading.readConfig?.epubLocation = epubLocation
            reading.durChapterIndex = chapter.index
            reading.durChapterTitle = chapter.title
            reading.durChapterPos = max(position, 0)
            reading.durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
            pendingProgress[book.bookUrl] = BookProgress(book: reading)
            persistPendingProgress()
            return
        }
        var updated = books
        if epubLocation != nil, updated[index].readConfig == nil { updated[index].readConfig = BookReadConfig() }
        updated[index].readConfig?.epubLocation = epubLocation
        updated[index].durChapterIndex = chapter.index
        updated[index].durChapterTitle = chapter.title
        updated[index].durChapterPos = max(position, 0)
        updated[index].durChapterTime = Int64(Date().timeIntervalSince1970 * 1_000)
        updated[index].lastCheckCount = 0
        updated[index].totalChapterNum = max(updated[index].totalChapterNum, chapter.index + 1)
        await persist(updated, progressBook: updated[index])
    }

    private func applyProgress(_ progress: BookProgress, to book: inout Book) {
        if progress.epubLocation != nil, book.readConfig == nil { book.readConfig = BookReadConfig() }
        book.readConfig?.epubLocation = progress.epubLocation
        book.durChapterIndex = progress.durChapterIndex
        book.durChapterTitle = progress.durChapterTitle
        book.durChapterPos = progress.durChapterPos
        book.durChapterTime = progress.durChapterTime
    }

    func restoreLocalCover(for book: Book, dataURL: String) async {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.bookUrl == book.bookUrl }),
              books[index].origin == "local", books[index].coverUrl?.isEmpty != false else { return }
        var updated = books
        updated[index].coverUrl = dataURL
        await persist(updated)
    }

    private func persistPendingProgress() {
        if pendingProgress.isEmpty {
            progressDefaults.removeObject(forKey: pendingProgressKey)
        } else if let data = try? JSONEncoder().encode(pendingProgress) {
            progressDefaults.set(data, forKey: pendingProgressKey)
        }
    }

    // A user-requested update should finish even if SwiftUI cancels the pull gesture's task.
    @discardableResult
    func startGroupUpdate(sources: [BookSource], group: BookGroup) -> Task<Void, Never> {
        Task { await checkForUpdates(sources: sources, group: group) }
    }

    func checkForUpdates(sources: [BookSource], onlyRead: Bool = false, group: BookGroup? = nil,
                         bookURL: String? = nil) async {
        await waitForSourceSwitch()
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        clearUpdateMessage()
        defer {
            checkingBookURLs.removeAll()
            isCheckingUpdates = false
        }

        let sourceByURL = Dictionary(sources.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, latest in latest })
        let candidates = group.map { books(in: $0) } ?? books
        let requestedBooks: [Book]
        if let bookURL {
            guard let selected = books.first(where: { $0.bookUrl == bookURL }) else { return }
            if selected.origin == "local" {
                checkingBookURLs.insert(bookURL)
                do {
                    let service: LocalBookService
                    if let txtTocRuleRepository {
                        service = try await localService.usingStoredTocRules(from: txtTocRuleRepository)
                    } else { service = localService }
                    var scanned = selected
                    scanned.localTXTRevision = URL(string: bookURL).flatMap(LocalTXTRevision.init(url:))
                    let chapters = try await Task.detached { try service.loadChapters(book: selected).chapters }.value
                    let previous = try await chapterRepository.load(bookURL: bookURL)
                    let report = BookUpdateMerger().merge(book: scanned, oldChapters: previous, newChapters: chapters,
                                                         now: Int64(Date().timeIntervalSince1970 * 1_000))
                    guard report.refreshed else { updateMessage = "《\(selected.name)》没有可用目录。"; return }
                    _ = await commitPreparedUpdate(requestedBook: selected, report: report)
                } catch { errorMessage = error.localizedDescription }
                return
            }
            requestedBooks = [selected]
        } else {
            requestedBooks = candidates.filter {
                $0.canUpdate && $0.origin != "local"
                    && (!onlyRead || $0.durChapterIndex >= max($0.totalChapterNum, 1) - 1)
            }
        }
        var checked = 0
        var added = 0
        var updatesByBookURL: [String: String] = [:]
        var failures: [String] = []
        var challengedURLs: Set<String> = []
        var pending = requestedBooks.makeIterator()
        let concurrentBookLimit = 4
        await withTaskGroup(of: (Book, BookUpdateReport).self) { tasks in
            while !Task.isCancelled {
                while !Task.isCancelled, checkingBookURLs.count < concurrentBookLimit, let book = pending.next() {
                    guard let source = sourceByURL[book.origin], source.enabled else {
                        failures.append("《\(book.name)》书源已停用或不存在")
                        continue
                    }
                    guard checkingBookURLs.insert(book.bookUrl).inserted else { continue }
                    tasks.addTask { [updateCoordinator] in
                        let report = await updateCoordinator.refresh(book: book, source: source, persistDirectory: false)
                        return (book, report)
                    }
                }
                guard let (requestedBook, report) = await tasks.next() else { break }
                defer { checkingBookURLs.remove(requestedBook.bookUrl) }
                await waitForSourceSwitch()
                guard !Task.isCancelled else { break }
                checked += 1
                guard report.refreshed else {
                    let error = report.diagnostics.first { $0.severity == .error }
                    if requestedBook.browserDirectoryURL != nil,
                       report.diagnostics.contains(where: { $0.code == "toc.verification" }) {
                        challengedURLs.insert(requestedBook.bookUrl)
                    }
                    var reason = error?.message ?? "没有解析到可用章节"
                    if let error, error.code == "toc.request", !error.rule.contains(","),
                       let url = URL(string: error.rule), ["http", "https"].contains(url.scheme),
                       !url.lastPathComponent.isEmpty {
                        reason += "（\(url.lastPathComponent)）"
                    }
                    failures.append("《\(requestedBook.name)》\(reason)")
                    continue
                }
                // Fetch concurrently, but merge one result at a time against the current shelf.
                guard books.contains(where: {
                    $0.bookUrl == requestedBook.bookUrl && $0.origin == requestedBook.origin
                }) else { continue }
                let succeeded = await commitPreparedUpdate(requestedBook: requestedBook, report: report)
                guard succeeded else {
                    failures.append("《\(requestedBook.name)》\(errorMessage ?? "目录未能保存")")
                    continue
                }
                if report.addedChapterCount > 0 {
                    added += report.addedChapterCount
                    updatesByBookURL[requestedBook.bookUrl] = "《\(report.book.name)》新增 \(report.addedChapterCount) 章"
                }
            }
        }

        guard !failures.isEmpty else { return }
        let summary = Task.isCancelled
            ? "更新已取消，已检查 \(checked) 本，\(failures.count) 本未更新。"
            : "已检查 \(checked) 本，发现 \(added) 个新章节，\(failures.count) 本未更新。"
        let updates = requestedBooks.compactMap { updatesByBookURL[$0.bookUrl] }
        if !Task.isCancelled {
            booksRequiringVerification = requestedBooks.filter { challengedURLs.contains($0.bookUrl) }
        }
        updateMessage = ([summary] + updates + failures.prefix(3)).joined(separator: "\n")
    }

    func refreshFromBrowser(_ rows: [[String: String]], book: Book, directory: URL) async throws {
        guard !isCheckingUpdates else {
            throw NSError(domain: "BrowserDirectory", code: 5, userInfo: [NSLocalizedDescriptionKey: "书架正在更新，请稍后再试。"])
        }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let chapters = try book.chapters(fromBrowserRows: rows, at: directory)
        let stored = try await chapterRepository.load(bookURL: book.bookUrl)
        guard chapters.count >= Set(stored.map(\.url)).count else {
            throw NSError(domain: "BrowserDirectory", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "网页只读到 \(chapters.count) 章，少于已保存目录。请展开全部章节再试。"])
        }
        let report = BookUpdateMerger().merge(book: book, oldChapters: stored, newChapters: chapters,
                                              now: Int64(Date().timeIntervalSince1970 * 1_000))
        guard await commitPreparedUpdate(requestedBook: book, report: report) else {
            throw NSError(domain: "BrowserDirectory", code: 7, userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "书架记录已变更，目录未保存。"])
        }
    }

    func commitPreparedUpdate(requestedBook: Book, report: BookUpdateReport) async -> Bool {
        await waitForSourceSwitch()
        guard !Task.isCancelled else { return false }
        let save = Task { @MainActor [self, repository, chapterRepository, chapterCache] in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            guard let index = books.firstIndex(where: {
                $0.bookUrl == requestedBook.bookUrl && $0.origin == requestedBook.origin
            }) else { return false }
            if report.book.bookUrl != requestedBook.bookUrl,
               books.contains(where: { $0.bookUrl == report.book.bookUrl }) {
                errorMessage = "更新前脚本返回的书籍地址已属于另一条书架记录，已保留原书籍。"
                return false
            }
            let merger = BookUpdateMerger()
            let prepared = merger.applyingPreparation(original: requestedBook, current: books[index], prepared: report.book)
            let oldChapters: [BookChapter]
            do { oldChapters = try await chapterRepository.load(bookURL: requestedBook.bookUrl) }
            catch { errorMessage = error.localizedDescription; return false }
            guard !Task.isCancelled else { return false }
            var updated = books
            updated[index] = merger.merge(book: prepared, oldChapters: [], newChapters: report.chapters,
                                           now: report.book.lastCheckTime).book
            let replacement = updated[index]
            let snapshot = updated
            let succeeded = await persist(snapshot) {
                if requestedBook.bookUrl != replacement.bookUrl {
                    try await chapterCache.copyContents(from: requestedBook, chapters: oldChapters,
                                                        to: replacement, chapters: report.chapters)
                }
                try await Self.writeBooksAndChapters(snapshot, chapters: report.chapters, bookURL: replacement.bookUrl,
                                                     repository: repository, chapterRepository: chapterRepository)
            }
            if succeeded, requestedBook.bookUrl != replacement.bookUrl {
                await cleanupRemovedBooks([requestedBook.bookUrl])
            }
            return succeeded
        }
        sourceSwitchSaveTask = save
        return await withTaskCancellationHandler { await save.value } onCancel: { save.cancel() }
    }

    func remove(at offsets: IndexSet) async {
        await waitForSourceSwitch()
        var updated = books
        updated.remove(atOffsets: offsets)
        let removed = Set(books.map(\.bookUrl)).subtracting(updated.map(\.bookUrl))
        if await persist(updated) { await cleanupRemovedBooks(removed) }
    }

    var visibleGroups: [BookGroup] {
        groups.filter(\.show).sorted {
            $0.order == $1.order ? $0.groupId < $1.groupId : $0.order < $1.order
        }
    }

    func books(in group: BookGroup) -> [Book] {
        let filtered: [Book]
        let customMask = groups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
        switch group.groupId {
        case BookGroup.idAll: filtered = books
        case BookGroup.idLocal: filtered = books.filter { $0.origin == "local" }
        case BookGroup.idNetNone: filtered = books.filter { $0.origin != "local" && $0.group & customMask == 0 }
        case BookGroup.idLocalNone: filtered = books.filter { $0.origin == "local" && $0.group & customMask == 0 }
        default:
            filtered = group.groupId > 0
                ? books.filter { ($0.group & group.groupId) != 0 }
                : books
        }
        let sort = group.bookshelfSort
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recentRead:
                return max(lhs.durChapterTime, lhs.localImportTime ?? 0) > max(rhs.durChapterTime, rhs.localImportTime ?? 0)
            case .recentUpdate: return lhs.latestChapterTime > rhs.latestChapterTime
            case .name:
                return lhs.name.compare(rhs.name, locale: Locale(identifier: "zh_CN")) == .orderedAscending
            case .custom: return lhs.order < rhs.order
            case .recentReadOrUpdate:
                return max(lhs.latestChapterTime, lhs.durChapterTime) > max(rhs.latestChapterTime, rhs.durChapterTime)
            case .author:
                return lhs.author.compare(rhs.author, locale: Locale(identifier: "zh_CN")) == .orderedAscending
            }
        }
    }

    func setGroupSort(_ group: BookGroup, sort: BookshelfSort) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].bookSort = sort.rawValue
        await persistGroups(updated)
    }

    func moveBooks(in group: BookGroup, from offsets: IndexSet, to destination: Int) async {
        await waitForSourceSwitch()
        let memberIDs = Set(books(in: group).map(\.id))
        var ordered = books.sorted { $0.order < $1.order }
        let slots = ordered.indices.filter { memberIDs.contains(ordered[$0].id) }
        guard offsets.allSatisfy({ slots.indices.contains($0) }), (0...slots.count).contains(destination) else { return }
        var members = slots.map { ordered[$0] }
        members.move(fromOffsets: offsets, toOffset: destination)
        for (index, slot) in slots.enumerated() { ordered[slot] = members[index] }
        for index in ordered.indices { ordered[index].order = index }
        await persist(ordered)
    }

    func nextGroupID(reserving draft: [BookGroup] = []) -> Int64? {
        let used = (groups + draft).filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId }
            | books.reduce(Int64(0)) { $0 | $1.group }
            | deletingGroupIDs.reduce(Int64(0), |)
        return (0..<63).map { Int64(1) << $0 }.first { used & $0 == 0 }
    }

    func createGroup(name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.contains(where: { $0.groupName == name }) else { return }
        guard let nextID = nextGroupID() else {
            errorMessage = "自定义分组已达到上限（63 个），请先删除不再使用的分组。"
            return
        }
        await persistGroups(groups + [.init(groupId: nextID, groupName: name, order: groups.count)])
    }

    func saveGroupDraft(_ draft: [BookGroup], original: [BookGroup]) async -> Bool {
        guard draft != original else { return true }
        guard groups == original else {
            errorMessage = "书架分组已变化，请重新打开后再编辑。"
            return false
        }
        let removed = Set(original.map(\.id)).subtracting(draft.map(\.id)).filter { $0 > 0 }
        guard !removed.isEmpty else { return await persistGroups(draft) }
        deletingGroupIDs.formUnion(removed)
        defer { deletingGroupIDs.subtract(removed) }
        let mask = removed.reduce(Int64(0), |)
        return await persistGroups(draft) {
            await self.waitForSourceSwitch()
            var shelf = self.books
            for i in shelf.indices { shelf[i].group &= ~mask }
            let updated = shelf
            let saved = await self.persist(updated) { [repository = self.repository, groups = self.groupRepository] in
                if let sqlite = groups as? SQLiteBookGroupRepository,
                   let books = repository as? SQLiteBookRepository, sqlite.sharesDatabase(with: books) {
                    try await sqlite.save(draft, withBooks: updated)
                } else {
                    try await groups.save(draft)
                    do { try await repository.save(updated) }
                    catch { try await groups.save(original); throw error }
                }
            }
            if !saved { throw NSError(domain: "BookGroups", code: 1, userInfo: [
                NSLocalizedDescriptionKey: self.errorMessage ?? "书架分组未保存"
            ]) }
        }
    }

    func renameGroup(_ group: BookGroup, name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].groupName = name
        await persistGroups(updated)
    }

    func setGroupVisible(_ group: BookGroup, visible: Bool) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index].show = visible
        await persistGroups(updated)
    }

    func moveGroups(from offsets: IndexSet, to destination: Int) async {
        var editable = groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
        editable.move(fromOffsets: offsets, toOffset: destination)
        var updated = groups
        for (order, group) in editable.enumerated() {
            if let index = updated.firstIndex(where: { $0.id == group.id }) {
                updated[index].order = order + 1
            }
        }
        await persistGroups(updated)
    }

    func deleteGroup(_ group: BookGroup) async {
        guard group.groupId > 0, !deletingGroupIDs.contains(group.id),
              let stored = groups.first(where: { $0.id == group.id }) else { return }
        deletingGroupIDs.insert(group.id)
        defer { deletingGroupIDs.remove(group.id) }
        guard await persistGroups(groups.filter { $0.id != group.id }) else { return }
        await waitForSourceSwitch()
        var updated = books
        for index in updated.indices { updated[index].group &= ~group.groupId }
        if !(await persist(updated)) {
            let saveError = errorMessage
            await persistGroups(groups + [stored])
            errorMessage = saveError
        }
    }

    func setBook(_ book: Book, in group: BookGroup, included: Bool) async {
        await waitForSourceSwitch()
        guard group.groupId > 0, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        var updated = books
        if included { updated[index].group |= group.groupId }
        else { updated[index].group &= ~group.groupId }
        await persist(updated)
    }

    @discardableResult
    func setBook(_ book: Book, groupIDs: Set<Int64>) async -> Bool {
        await waitForSourceSwitch()
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return false }
        let customMask = groups.reduce(Int64(0)) { value, group in
            group.groupId > 0 ? value | group.groupId : value
        }
        let selectedMask = groupIDs.reduce(Int64(0), |)
        var updated = books
        updated[index].group = (updated[index].group & ~customMask) | selectedMask
        return await persist(updated)
    }

    func remove(bookURL: String) async {
        await waitForSourceSwitch()
        if await persist(books.filter { $0.bookUrl != bookURL }) {
            await cleanupRemovedBooks([bookURL])
        }
    }

    private func cleanupRemovedBooks(_ urls: Set<String>) async {
        for url in urls where !books.contains(where: { $0.bookUrl == url }) {
            pendingProgress[url] = nil
            try? await chapterRepository.remove(bookURL: url)
        }
        persistPendingProgress()
    }

    func importLocalFiles(_ urls: [URL]) async {
        await importPickedLocalFiles(urls.map { LocalBookImportFile(url: $0) })
    }

    @discardableResult
    func importPickedLocalFiles(_ files: [LocalBookImportFile]) async -> Set<String> {
        // Keep the picker grants alive through the review and asynchronous copy.
        defer { withExtendedLifetime(files) {} }
        var failures: [String] = []
        var failedPaths = Set<String>()
        for file in files {
            let url = file.url
            do {
                let stored = try await localFiles.importFile(from: url)
                do {
                    try await addLocalFile(at: stored)
                } catch {
                    if let staged = try? await localFiles.stageRemoval(stored) {
                        try? await localFiles.finishRemoval(staged)
                    }
                    throw error
                }
            } catch {
                failedPaths.insert(url.path)
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return failedPaths
    }

    func addLocalFile(at url: URL) async throws {
        guard !books.contains(where: { $0.bookUrl == url.absoluteString }) else { return }
        let service: LocalBookService
        if let txtTocRuleRepository {
            service = try await localService.usingStoredTocRules(from: txtTocRuleRepository)
        } else { service = localService }
        let report = try await Task.detached { try service.openFile(at: url) }.value
        await waitForSourceSwitch()
        guard !books.contains(where: { $0.bookUrl == url.absoluteString }) else { return }
        let chapters = url.pathExtension.lowercased() == "txt" ? report.chapters : []
        var book = report.book
        book.localImportTime = Int64(Date().timeIntervalSince1970 * 1_000)
        guard await addOrUpdate(book, chapters: chapters) else {
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
    }

    func cachedTXTChapters(for book: Book) async -> [BookChapter] {
        guard let indexed = book.localTXTRevision, let url = URL(string: book.bookUrl),
              LocalTXTRevision(url: url) == indexed else { return [] }
        return (try? await chapterRepository.load(bookURL: book.bookUrl)) ?? []
    }

    func localReadingChapters(for book: Book) async throws -> [BookChapter] {
        let saved = await cachedTXTChapters(for: book)
        if !saved.isEmpty { return saved }
        try Task.checkCancellation()
        let revision = URL(string: book.bookUrl).flatMap(LocalTXTRevision.init(url:))
        let parsing = Task.detached { [localService] in try localService.loadChapters(book: book).chapters }
        let chapters = try await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
        try Task.checkCancellation()
        // Backfill older shelf entries only while they still describe the file we parsed.
        if let revision, let url = URL(string: book.bookUrl), revision == LocalTXTRevision(url: url) {
            var updated = book
            updated.localTXTRevision = revision
            _ = await addOrUpdate(updated, chapters: chapters, replacing: book)
        }
        return chapters
    }

    func localTocRules() async throws -> [TxtTocRule] {
        if let txtTocRuleRepository {
            return try await txtTocRuleRepository.loadTxtTocRules(initialDefaults: localService.tocRules)
                .filter(\.enable).sorted { $0.serialNumber < $1.serialNumber }
        }
        return localService.tocRules
    }

    /// Rebuild and commit on the same local identity. The barrier also protects
    /// reading progress and file renames while byte offsets are being mapped.
    func rebuildLocalBook(bookURL: String, rule: TxtTocRule?, splitLongChapter: Bool) async -> Bool {
        await waitForSourceSwitch()
        guard !Task.isCancelled else { return false }
        let save = Task { @MainActor [self, repository, chapterRepository, chapterCache] in
            defer { sourceSwitchSaveTask = nil }
            _ = await bookSaveTask?.value
            guard let index = books.firstIndex(where: { $0.bookUrl == bookURL && $0.origin == "local" }) else {
                errorMessage = "本地书已不在书架中，请重新打开。"
                return false
            }
            let current = books[index]
            do {
                try Task.checkCancellation()
                let service: LocalBookService
                if let txtTocRuleRepository {
                    service = try await localService.usingStoredTocRules(from: txtTocRuleRepository)
                } else { service = localService }
                let stored = try await chapterRepository.load(bookURL: bookURL)
                let parsing = Task.detached {
                    let previous = stored.isEmpty ? try service.loadChapters(book: current).chapters : stored
                    return try service.rebuildTextFile(book: current, rule: rule, splitLongChapter: splitLongChapter,
                                                       previousChapters: previous)
                }
                let report = try await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
                try Task.checkCancellation()
                var updated = books
                updated[index] = report.book
                let snapshot = updated
                let succeeded = await persist(snapshot) {
                    try await Self.writeBooksAndChapters(snapshot, chapters: report.chapters, bookURL: bookURL,
                                                         repository: repository, chapterRepository: chapterRepository)
                }
                if succeeded {
                    // Only derived chapter content for this identity is stale;
                    // the original file and bookmarks are never removed.
                    do { try await chapterCache.remove(bookURL: bookURL) }
                    catch { DiagnosticLog.shared.record(.warning, category: "本地书", message: "目录已重建，旧正文缓存清理失败：\(error.localizedDescription)") }
                }
                return succeeded
            } catch is CancellationError {
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        sourceSwitchSaveTask = save
        return await withTaskCancellationHandler { await save.value } onCancel: { save.cancel() }
    }

    func renameLocalFile(at url: URL, to name: String) async throws {
        await waitForSourceSwitch()
        let target = try await localFiles.rename(url, to: name)
        guard target != url else { return }
        await waitForSourceSwitch()
        var updated = books
        for index in updated.indices where updated[index].origin == "local" && updated[index].bookUrl == url.absoluteString {
            updated[index].bookUrl = target.absoluteString
            updated[index].originName = target.lastPathComponent
        }
        guard await persist(updated) else {
            _ = try await localFiles.rename(target, to: url.lastPathComponent)
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
        if let progress = pendingProgress.removeValue(forKey: url.absoluteString) {
            pendingProgress[target.absoluteString] = progress
            persistPendingProgress()
        }
        try? await chapterRepository.remove(bookURL: url.absoluteString)
    }

    func deleteLocalFile(at url: URL) async throws {
        await waitForSourceSwitch()
        let staged: StagedLocalFile?
        if url.isFileURL,
           books.contains(where: { $0.origin == "local" && $0.bookUrl == url.absoluteString }),
           !FileManager.default.fileExists(atPath: url.path) {
            // Stale shelf paths can belong to a previous app container. Only
            // remove their metadata; existing files still require containment.
            staged = nil
        } else {
            staged = try await localFiles.stageRemoval(url)
        }
        await waitForSourceSwitch()
        guard await persist(books.filter { $0.bookUrl != url.absoluteString }) else {
            if let staged { try await localFiles.restore(staged) }
            throw LocalFileError.saveFailed(errorMessage ?? "无法写入数据库")
        }
        pendingProgress[url.absoluteString] = nil
        persistPendingProgress()
        try? await chapterRepository.remove(bookURL: url.absoluteString)
        if let staged { try await localFiles.finishRemoval(staged) }
    }

    func clearError() { errorMessage = nil }

    func clearUpdateMessage() {
        booksRequiringVerification = []
        updateMessage = nil
    }

    func reportError(_ error: Error) { errorMessage = error.localizedDescription }

    @discardableResult
    private func persist(_ updated: [Book], progressBook: Book? = nil, write: (@Sendable () async throws -> Void)? = nil) async -> Bool {
        // Publish before suspending so the next mutation sees the latest
        // shelf. Serialize disk writes to keep their order identical to it.
        books = updated
        bookSaveGeneration &+= 1
        let generation = bookSaveGeneration
        let previousSave = bookSaveTask
        let save = Task { @MainActor [weak self, repository] in
            let previousSucceeded = await previousSave?.value ?? true
            do {
                if let write { try await write() }
                else if let progressBook, previousSucceeded { try await repository.saveProgress(progressBook, in: updated) }
                else { try await repository.save(updated) }
                self?.persistedBooks = updated
                if self?.bookSaveGeneration == generation { self?.errorMessage = nil }
                return true
            } catch {
                if let self, bookSaveGeneration == generation {
                    books = persistedBooks
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        bookSaveTask = save
        let succeeded = await save.value
        if bookSaveGeneration == generation { bookSaveTask = nil }
        return succeeded
    }

    @discardableResult
    private func persistGroups(_ updated: [BookGroup], write: (@MainActor () async throws -> Void)? = nil) async -> Bool {
        groups = updated
        groupSaveGeneration &+= 1
        let generation = groupSaveGeneration
        let previousSave = groupSaveTask
        let save = Task { @MainActor [weak self, groupRepository] in
            _ = await previousSave?.value
            do {
                if let write { try await write() }
                else { try await groupRepository.save(updated) }
                self?.persistedGroups = updated
                if self?.groupSaveGeneration == generation { self?.errorMessage = nil }
                return true
            } catch {
                if let self, groupSaveGeneration == generation {
                    groups = persistedGroups
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        groupSaveTask = save
        let succeeded = await save.value
        if groupSaveGeneration == generation { groupSaveTask = nil }
        return succeeded
    }
}
