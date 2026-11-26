import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class RSSLibraryModel: ObservableObject {
    @Published private(set) var hasLoadedSources = false
    @Published private(set) var sources: [RssSource] = []
    @Published private(set) var articles: [RssArticle] = []
    @Published private(set) var stars: [RssStar] = []
    @Published private(set) var records: [RssReadRecord] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private var sourceRepository: SQLiteRssSourceRepository { get throws { .init(database: try database) } }
    private var articleRepository: SQLiteRssArticleRepository { get throws { .init(database: try database) } }
    private var starRepository: SQLiteRssStarRepository { get throws { .init(database: try database) } }
    private var recordRepository: SQLiteRssReadRecordRepository { get throws { .init(database: try database) } }
    private let service: RSSService
    private let importer = RSSSourceImporter()
    private let databaseResult: Result<LegadoDatabase, Error>
    private var database: LegadoDatabase { get throws { try databaseResult.get() } }
    @Published private var nextURL: String?
    var canLoadMore: Bool { nextURL?.nilIfBlank != nil }
    private var visitedPageURLs: Set<String> = []
    private var page = 1
    private var order: Int64 = 0
    private struct Feed: Equatable {
        let origin: String
        let sort: String
        let key: String?
    }
    private var activeFeed: Feed?
    private var hasLoadedFeed = false
    private var articleRequestID = UUID()
    @Published private var loadingMoreRequestID: UUID?
    @Published private(set) var refreshingFeed = false
    @Published private(set) var paginationError: String?
    var isLoadingMore: Bool { loadingMoreRequestID != nil }
    private var activeOperations = 0

    init(database: LegadoDatabase, service: RSSService = .init()) {
        databaseResult = .success(database)
        self.service = service
    }

    private init(databaseError: Error) {
        let error = LegadoDatabaseError.open("RSS 数据库无法打开：\(databaseError.localizedDescription)。请检查存储空间后重新启动应用。")
        databaseResult = .failure(error)
        service = .init()
        errorMessage = error.localizedDescription
    }

    static func live(databaseURL: URL = LegadoDatabase.defaultURL()) -> RSSLibraryModel {
        do { return .init(database: try LegadoDatabase(url: databaseURL)) }
        catch { return .init(databaseError: error) }
    }

    func reloadAfterBackup() async {
        resetActiveFeed()
        await load()
    }

    private func resetActiveFeed() {
        invalidatePageRequests()
        activeFeed = nil
        paginationError = nil
        visitedPageURLs.removeAll()
        articles = []
        nextURL = nil
        hasLoadedFeed = false
    }

    private func invalidatePageRequests() {
        articleRequestID = UUID()
        loadingMoreRequestID = nil
        refreshingFeed = false
    }

    func load() async {
        defer { hasLoadedSources = true }
        do {
            async let loadedSources = sourceRepository.all()
            async let loadedStars = starRepository.all()
            async let loadedRecords = recordRepository.all()
            (sources, stars, records) = try await (loadedSources, loadedStars, loadedRecords)
        } catch { errorMessage = error.localizedDescription }
    }

    func importSources(_ incoming: [RssSource]) async throws {
        sources = try await database.mergeImportedRssSources(incoming)
    }

    func importFiles(_ urls: [URL]) async {
        await perform {
            var merged = self.sources
            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let payload = try self.importer.decode(Data(contentsOf: url))
                merged = try self.importer.merge(payload.sources, into: merged)
                for remote in payload.subscriptionURLs { merged = try await self.importRemote(remote, existing: merged) }
            }
            try await self.sourceRepository.save(merged)
            self.sources = try await self.sourceRepository.all()
        }
    }

    @discardableResult
    func importText(_ text: String) async -> Bool {
        var succeeded = false
        await perform {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var merged: [RssSource]
            if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                merged = try await self.importRemote(trimmed, existing: self.sources)
            } else {
                let payload = try self.importer.decode(Data(trimmed.utf8))
                merged = try self.importer.merge(payload.sources, into: self.sources)
                for remote in payload.subscriptionURLs { merged = try await self.importRemote(remote, existing: merged) }
            }
            try await self.sourceRepository.save(merged)
            self.sources = try await self.sourceRepository.all()
            succeeded = true
        }
        return succeeded
    }

    func applySilentSubscription(_ data: Data) async throws {
        let incoming = try importer.decode(data).sources
        var updated = sources
        for var source in incoming {
            if let index = updated.firstIndex(where: { $0.sourceUrl == source.sourceUrl }) {
                guard updated[index].lastUpdateTime < source.lastUpdateTime else { continue }
                source.sourceGroup = updated[index].sourceGroup
                updated[index] = source
            } else { updated.append(source) }
        }
        try await sourceRepository.save(updated)
        sources = try await sourceRepository.all()
    }

    func setEnabled(_ enabled: Bool, source: RssSource) async {
        do { try await sourceRepository.setEnabled(enabled, sourceURL: source.sourceUrl); sources = try await sourceRepository.all() }
        catch { errorMessage = error.localizedDescription }
    }
    func remove(_ source: RssSource) async {
        do {
            try await sourceRepository.remove(sourceURL: source.sourceUrl)
            if activeFeed?.origin == source.sourceUrl {
                resetActiveFeed()
            }
            sources = try await sourceRepository.all()
        } catch { errorMessage = error.localizedDescription }
    }

    func clearArticleCache(for source: RssSource) async {
        if activeFeed?.origin == source.sourceUrl {
            // Invalidate pending page requests before they can write the cache back.
            invalidatePageRequests()
        }
        let requestID = articleRequestID
        do {
            try await database.removeRssArticles(origin: source.sourceUrl)
            if activeFeed?.origin == source.sourceUrl, articleRequestID == requestID {
                resetActiveFeed()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveSources(from offsets: IndexSet, to destination: Int) async {
        var values = sources
        values.move(fromOffsets: offsets, toOffset: destination)
        for index in values.indices { values[index].customOrder = index }
        do { try await sourceRepository.save(values); sources = try await sourceRepository.all() }
        catch { errorMessage = error.localizedDescription }
    }

    func save(_ value: RssSource, replacing originalURL: String?) async -> Bool {
        let name = value.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = value.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { errorMessage = "源名称和URL不能为空"; return false }
        do {
            var source = value; source.sourceName = name; source.sourceUrl = url
            let original = originalURL.flatMap { key in sources.first { $0.sourceUrl == key } }
            if original != source { source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000) }
            if let originalURL, originalURL != source.sourceUrl {
                try await starRepository.updateOrigin(from: originalURL, to: source.sourceUrl)
                try await articleRepository.updateOrigin(from: originalURL, to: source.sourceUrl)
                try await database.deleteSourceVariables(originalURL)
            }
            var values = sources.filter { $0.sourceUrl != originalURL && $0.sourceUrl != source.sourceUrl }
            values.append(source)
            try await sourceRepository.save(values)
            sources = try await sourceRepository.all()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func refresh(_ source: RssSource, sortName: String? = nil, sortURL: String? = nil, key: String? = nil, preferCache: Bool = false) async {
        let name = sortName ?? source.sourceName
        let url = sortURL ?? source.sortUrl?.nilIfBlank ?? source.sourceUrl
        let feed = Feed(origin: source.sourceUrl, sort: name, key: key)
        if preferCache, activeFeed == feed, hasLoadedFeed { return }
        let requestID = UUID()
        articleRequestID = requestID
        loadingMoreRequestID = nil
        paginationError = nil
        refreshingFeed = true
        defer { if articleRequestID == requestID { refreshingFeed = false } }
        if activeFeed != feed {
            hasLoadedFeed = false
            articles = []
            nextURL = nil
            page = 1
        }
        activeFeed = feed
        await perform(isCurrent: { self.articleRequestID == requestID }) {
            if preferCache, key == nil {
                let cached = try await self.database.cachedRssFeed(origin: source.sourceUrl, sort: name)
                guard self.articleRequestID == requestID else { return }
                if let cached {
                    self.visitedPageURLs = []
                    self.page = cached.page ?? 1
                    self.nextURL = cached.nextURL
                    self.order = (cached.articles.last?.order ?? 1) - 1
                    self.articles = cached.articles
                    // Legacy caches have articles but no record of whether another page exists.
                    if cached.page != nil || source.ruleNextPage?.nilIfBlank == nil {
                        self.hasLoadedFeed = true
                        return
                    }
                }
            }
            let report = try await self.service.articles(sortName: name, sortURL: url, source: source, page: 1, key: key)
            guard self.articleRequestID == requestID else { return }
            var nextOrder = Int64(Date().timeIntervalSince1970 * 1_000)
            var values = report.result.articles
            for index in values.indices { values[index].order = nextOrder; nextOrder -= 1 }
            let articles: [RssArticle]
            if key != nil {
                // Search results belong to this query, not the persistent feed.
                let records = try await self.recordRepository.all()
                let readLinks = Set(records.map(\.record))
                for index in values.indices { values[index].read = readLinks.contains(values[index].link) }
                articles = values
            } else {
                articles = try await self.database.saveRssFeedPage(values, origin: source.sourceUrl, sort: name,
                    page: 1, nextURL: report.result.nextURL, replaceFeed: source.ruleNextPage?.nilIfBlank != nil)
            }
            guard self.articleRequestID == requestID else { return }
            self.visitedPageURLs = [url]
            self.page = 1
            self.order = nextOrder
            self.nextURL = report.result.nextURL
            self.articles = articles
            self.hasLoadedFeed = true
        }
    }

    func loadMore(_ source: RssSource, sortName: String? = nil, key: String? = nil) async {
        let name = sortName ?? source.sourceName
        guard activeFeed == Feed(origin: source.sourceUrl, sort: name, key: key),
              !refreshingFeed, loadingMoreRequestID == nil, let nextURL, !nextURL.isEmpty else { return }
        let requestID = articleRequestID
        loadingMoreRequestID = requestID
        paginationError = nil
        defer { if loadingMoreRequestID == requestID { loadingMoreRequestID = nil } }
        let nextPage = page + 1
        do {
            let report = try await self.service.articles(sortName: name, sortURL: nextURL, source: source, page: nextPage, key: key)
            guard self.articleRequestID == requestID else { return }
            var nextOrder = self.order
            var values = report.result.articles
            for index in values.indices { values[index].order = nextOrder; nextOrder -= 1 }
            var followingURL = report.result.nextURL
            let usesPageTemplate = source.ruleNextPage?.uppercased() == "PAGE"
            if usesPageTemplate {
                // PAGE reuses the request template even when the site has run out of results.
                let ids = Set(self.articles.map(\.id))
                if values.allSatisfy({ ids.contains($0.id) }) { followingURL = nil }
            } else if let url = followingURL, url == nextURL || visitedPageURLs.contains(url) {
                followingURL = nil
            }
            let articles: [RssArticle]
            if key != nil {
                let records = try await self.recordRepository.all()
                guard self.articleRequestID == requestID else { return }
                let readLinks = Set(records.map(\.record))
                for index in values.indices { values[index].read = readLinks.contains(values[index].link) }
                var seen = Set(self.articles.map(\.id))
                articles = self.articles + values.filter { seen.insert($0.id).inserted }
            } else {
                articles = try await self.database.saveRssFeedPage(values, origin: source.sourceUrl, sort: name,
                    page: nextPage, nextURL: followingURL, replaceFeed: false)
            }
            guard self.articleRequestID == requestID else { return }
            if !usesPageTemplate { self.visitedPageURLs.insert(nextURL) }
            self.page = nextPage
            self.order = nextOrder
            self.nextURL = followingURL
            self.articles = articles
        } catch {
            if articleRequestID == requestID, !isRequestCancellation(error) { paginationError = error.localizedDescription }
        }
    }

    static let websiteHistoryKey = "recordWebsiteBrowsingHistory"

    func read(_ article: RssArticle) async {
        guard UserDefaults.standard.object(forKey: Self.websiteHistoryKey) as? Bool ?? true else { return }
        do {
            try await recordRepository.insertIgnoringExisting(article.record())
            records = try await recordRepository.all()
            if let index = articles.firstIndex(of: article) { articles[index].read = true }
        }
        catch { errorMessage = error.localizedDescription }
    }
    func readingMode(for article: RssArticle, source: RssSource, forceRefresh: Bool = false) async -> RSSReadingMode {
        let policy = RSSReadingPolicy()
        if !forceRefresh, article.type == 0, article.description?.nilIfBlank != nil {
            return policy.mode(article: article, source: source)
        }
        guard let rule = source.ruleContent?.nilIfBlank else {
            return policy.mode(article: article, source: source)
        }
        do {
            let fetched = try await service.contentDetailed(article: article, rule: rule, source: source)
            let content = fetched.content
            var updated = fetched.article
            if article.type == 0 {
                updated.description = content
                // Scripts can adjust their working URL and source context, but
                // a content refresh updates the entry the user opened. It must
                // not move primary keys or overwrite another cached article.
                var persisted = updated
                persisted.origin = article.origin
                persisted.sort = article.sort
                persisted.link = article.link
                try await articleRepository.put([persisted])
                if var star = try await starRepository.star(origin: article.origin, link: article.link) {
                    star.description = content
                    star.variable = updated.variable
                    try await starRepository.save(star)
                    stars = try await starRepository.all()
                }
                if let index = articles.firstIndex(where: { $0.id == article.id }) { articles[index] = persisted }
                return .html(content: content, baseURL: source.loadWithBaseUrl ? fetched.finalURL : nil)
            }
            return policy.mode(article: updated, source: source, resolvedContent: content)
        } catch {
            if isRequestCancellation(error) { return policy.mode(article: article, source: source) }
            errorMessage = error.localizedDescription
            if article.type == 0 { return .html(content: "加载正文失败\n\(error.localizedDescription)", baseURL: nil) }
            return policy.mode(article: article, source: source)
        }
    }
    func toggleStar(_ article: RssArticle) async {
        do {
            if try await starRepository.star(origin: article.origin, link: article.link) != nil {
                try await starRepository.remove(origin: article.origin, link: article.link)
            } else { try await starRepository.save(article.star()) }
            stars = try await starRepository.all()
        } catch { errorMessage = error.localizedDescription }
    }
    func isStarred(_ article: RssArticle) -> Bool { stars.contains { $0.origin == article.origin && $0.link == article.link } }

    func removeStar(_ value: RssStar) async {
        do { try await starRepository.remove(origin: value.origin, link: value.link); stars = try await starRepository.all() }
        catch { errorMessage = error.localizedDescription }
    }

    func saveStar(_ value: RssStar) async throws {
        try await starRepository.save(value)
        stars = try await starRepository.all()
    }

    func clearStars() async {
        do { try await starRepository.clear(); stars = [] }
        catch { errorMessage = error.localizedDescription }
    }

    func clearRecords() async {
        do { try await recordRepository.clear(); records = [] }
        catch { errorMessage = error.localizedDescription }
    }

    private func importRemote(_ value: String, existing: [RssSource]) async throws -> [RssSource] {
        let withoutUA = value.hasSuffix("#requestWithoutUA")
        let raw = withoutUA ? String(value.dropLast("#requestWithoutUA".count)) : value
        guard let url = URL(string: raw) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if withoutUA { request.setValue("", forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await URLSessionHTTPTransport.shared.download(for: request)
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) != false else { throw URLError(.badServerResponse) }
        let payload = try importer.decode(data)
        return try importer.merge(payload.sources, into: existing)
    }
    private func isRequestCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func perform(isCurrent: () -> Bool = { true }, _ operation: () async throws -> Void) async {
        activeOperations += 1
        isWorking = true
        defer { activeOperations -= 1; isWorking = activeOperations > 0 }
        do { try await operation() } catch { if isCurrent(), !isRequestCancellation(error) { errorMessage = error.localizedDescription } }
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
