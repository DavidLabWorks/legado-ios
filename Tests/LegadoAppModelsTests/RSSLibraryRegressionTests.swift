import Foundation
import SQLite3
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct RSSLibraryRegressionTests {
    @Test func clearingArticleCacheResetsAllCategoriesOfOnlyTheSelectedSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database)
        let source = source()
        for origin in [source.sourceUrl, "https://other.test"] {
            for sort in ["全部", "最新"] {
                let article = RssArticle(origin: origin, sort: sort, title: sort, link: origin + "/one")
                _ = try await database.saveRssFeedPage([article], origin: origin, sort: sort, page: 1, nextURL: "/two", replaceFeed: true)
            }
        }
        await model.refresh(source, preferCache: true)
        let article = try #require(model.articles.first)
        await model.toggleStar(article)
        #expect(model.canLoadMore)

        await model.clearArticleCache(for: source)

        #expect(model.errorMessage == nil)
        #expect(model.articles.isEmpty && !model.canLoadMore)
        #expect(model.isStarred(article))
        for sort in ["全部", "最新"] {
            #expect(try await database.cachedRssFeed(origin: source.sourceUrl, sort: sort) == nil)
            let other = try await database.cachedRssFeed(origin: "https://other.test", sort: sort)
            #expect(other?.articles.count == 1 && other?.nextURL == "/two")
        }
    }

    @Test func databaseSaveFailureReportsErrorButDoesNotRollbackEarlierRuleFileWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("rss.sqlite3")
        let database = try LegadoDatabase(url: databaseURL)
        let store = RSSVariableStore(directory: directory.appendingPathComponent("ruleData"))
        var source = source()
        source.ruleContent = "@js:rssArticle.title = 'unsaved'; rssArticle.putBigVariable('key', 'rule-committed'); 'new content'"
        let article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        try await database.putRssArticles([article])
        var handle: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &handle) == SQLITE_OK)
        defer { if let handle { sqlite3_close(handle) } }
        #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_article_save BEFORE INSERT ON rssArticles BEGIN SELECT RAISE(FAIL, 'article save failed'); END", nil, nil, nil) == SQLITE_OK)
        let model = RSSLibraryModel(database: database, service: .init(
            transport: RSSSequenceTransport(bodies: ["body"]), urlBuilder: .init(rssVariableStore: store),
            engine: .init(javaScript: .init(rssVariableStore: store)), networkPolicy: .init()
        ))

        _ = await model.readingMode(for: article, source: source)

        #expect(model.errorMessage?.contains("article save failed") == true)
        let saved = try await database.findRssArticle(origin: article.origin, link: article.link)
        #expect(saved?.title == "original")
        #expect(try store.get(origin: article.origin, link: article.link, key: "key") == "rule-committed")
    }

    @Test func failedContentScriptDoesNotPersistPartialArticleMutations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database, service: .init(transport: RSSSequenceTransport(bodies: ["body"]), networkPolicy: .init()))
        var source = source()
        source.ruleContent = "@js:rssArticle.title = 'partial'; rssArticle.putVariable('token', 'partial'); throw new Error('failed content')"
        var article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        article.variable = #"{"token":"original"}"#
        try await database.putRssArticles([article])

        _ = await model.readingMode(for: article, source: source)

        #expect(model.errorMessage?.contains("failed content") == true)
        let saved = try await database.findRssArticle(origin: article.origin, link: article.link)
        #expect(saved?.title == "original")
        #expect(saved?.variableMap["token"] == "original")
    }

    @Test func scriptIdentityChangesDoNotMoveCachedArticlesOrOverwriteOtherEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database, service: .init(transport: RSSSequenceTransport(bodies: ["body"]), networkPolicy: .init()))
        var source = source()
        source.ruleContent = "@js:rssArticle.origin = 'https://other.test'; rssArticle.link = '/target'; rssArticle.sort = 'other'; rssArticle.putVariable('token', 'kept'); 'fresh'"
        let article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        let other = RssArticle(origin: "https://other.test", sort: "other", title: "protected", link: "/target")
        try await database.putRssArticles([article, other])
        await model.toggleStar(article)

        #expect(await model.readingMode(for: article, source: source) == .html(content: "fresh", baseURL: article.link))
        let original = try await database.findRssArticle(origin: article.origin, link: article.link, sort: article.sort)
        let target = try await database.findRssArticle(origin: other.origin, link: other.link, sort: other.sort)
        #expect(original?.description == "fresh")
        #expect(original?.variableMap["token"] == "kept")
        #expect(target?.title == "protected")
        #expect(target?.description == nil)
        #expect(model.stars.count == 1)
        #expect(model.stars.first?.link == article.link)
    }

    @Test func contentRuleArticleMutationsPersistWithArticleAndFavoriteVariables() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let model = RSSLibraryModel(database: database, service: .init(transport: RSSSequenceTransport(bodies: ["body"]), networkPolicy: .init()))
        var source = source()
        source.ruleContent = "@js:rssArticle.setTitle('updated'); rssArticle.putVariable('token', 'saved'); java.get('token')"
        let article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "original", link: source.sourceUrl + "/article")
        await model.toggleStar(article)

        let mode = await model.readingMode(for: article, source: source)

        #expect(mode == .html(content: "saved", baseURL: article.link))
        let saved = try await database.findRssArticle(origin: article.origin, link: article.link)
        #expect(saved?.title == "updated")
        #expect(saved?.variableMap["token"] == "saved")
        #expect(model.stars.first?.article.variableMap["token"] == "saved")
    }

    @Test func explicitContentRefreshReplacesTheExistingDescription() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [#"{"content":"更新后的正文"}"#])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleContent = "$.content"
        var article = RssArticle(origin: source.sourceUrl, sort: "全部", title: "文章", link: source.sourceUrl + "/one")
        article.description = "旧正文"
        #expect(await model.readingMode(for: article, source: source) == .html(content: "旧正文", baseURL: article.link))
        let refreshed = await model.readingMode(for: article, source: source, forceRefresh: true)
        #expect(refreshed == .html(content: "更新后的正文", baseURL: article.link))
        #expect(try await database.findRssArticle(origin: source.sourceUrl, link: article.link)?.description == "更新后的正文")
    }

    @Test func searchesDoNotMixPreviousQueriesOrTheCachedFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"旧搜索","link":"/old"}]}"#,
            #"{"items":[{"title":"新搜索","link":"/new"}]}"#,
            #"{"items":[]}"#
        ])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        let source = source()
        let cached = RssArticle(origin: source.sourceUrl, sort: "全部", title: "缓存文章", link: "/cached")
        try await database.putRssArticles([cached])
        await model.refresh(source, sortName: "搜索", key: "old")
        #expect(model.articles.map(\.title) == ["旧搜索"])
        await model.refresh(source, sortName: "搜索", key: "new")
        #expect(model.articles.map(\.title) == ["新搜索"])
        await model.refresh(source, sortName: "搜索", key: "missing")
        #expect(model.articles.isEmpty)
        #expect(try await database.loadRssArticles(origin: source.sourceUrl, sort: "全部") == [cached])
    }

    @Test func failedRefreshKeepsTheExistingPageAndNextPageCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"第一页","link":"/one"}],"next":"/page2"}"#,
            nil,
            #"{"items":[{"title":"第二页","link":"/two"}]}"#
        ])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "$.next"
        await model.refresh(source)
        await model.refresh(source)
        #expect(model.errorMessage != nil)
        #expect(model.articles.map(\.title) == ["第一页"])
        await model.loadMore(source)
        #expect(model.articles.map(\.title) == ["第一页", "第二页"])
        #expect(await transport.requestCount() == 3)
    }

    @Test func searchPaginationDeduplicatesResultsAndPreservesReadState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"第一篇","link":"/one"}],"next":"/page2"}"#,
            #"{"items":[{"title":"第一篇","link":"/one"},{"title":"第二篇","link":"/two"}]}"#
        ])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "$.next"
        await model.refresh(source, sortName: "搜索", key: "test")
        let article = try #require(model.articles.first)
        await model.read(article)
        await model.toggleStar(article)
        await model.loadMore(source, sortName: "搜索", key: "test")
        #expect(model.articles.map(\.title) == ["第一篇", "第二篇"])
        #expect(model.articles.first?.read == true)
        #expect(model.isStarred(article))
    }

    @Test func failedRuleEvaluationPreservesPersistedArticles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [#"{"items":[{"title":"已有文章","link":"/one"}]}"#, "{}"])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "PAGE"
        await model.refresh(source)
        source.ruleArticles = "@js:throw new Error('broken rule')"
        await model.refresh(source)
        #expect(model.errorMessage != nil)
        #expect(model.articles.map(\.title) == ["已有文章"])
        #expect(try await database.loadRssArticles(origin: source.sourceUrl, sort: source.sourceName).map(\.title) == ["已有文章"])
    }

    @Test func reopeningFeedsUsesDiskAndRestoresTheNextPageEvenAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSSequenceTransport(bodies: [
            #"{"items":[{"title":"第一篇","link":"/one"}],"next":"/two"}"#,
            #"{"items":[]}"#,
            #"{"items":[{"title":"第二篇","link":"/two"}]}"#,
            #"{"items":[{"title":"更新","link":"/new"}]}"#
        ])
        let service = RSSService(transport: transport, networkPolicy: .init())
        let first = RSSLibraryModel(database: database, service: service)
        var source = source()
        source.ruleNextPage = "$.next"
        await first.refresh(source, preferCache: true)
        await first.refresh(source, preferCache: true)
        await first.refresh(source, sortName: "空分类", preferCache: true)
        let reopened = RSSLibraryModel(database: database, service: service)
        await reopened.refresh(source, sortName: "空分类", preferCache: true)
        await reopened.refresh(source, preferCache: true)
        #expect(await transport.requestCount() == 2)
        #expect(reopened.articles.map(\.title) == ["第一篇"])
        await reopened.loadMore(source)
        #expect(reopened.articles.map(\.title) == ["第一篇", "第二篇"])
        await reopened.refresh(source)
        #expect(reopened.articles.map(\.title) == ["更新"])
        #expect(await transport.requestCount() == 4)
    }

    @Test func failedNextPageCanRetryAndRepeatedPageStopsPagination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let first = #"{"items":[{"title":"一","link":"/1"}]}"#
        let second = #"{"items":[{"title":"二","link":"/2"}]}"#
        let transport = RSSSequenceTransport(bodies: [first, nil, second, second])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "PAGE"
        await model.refresh(source)
        await model.loadMore(source)
        #expect(model.paginationError != nil && !model.isLoadingMore && model.canLoadMore)
        await model.loadMore(source)
        #expect(model.paginationError == nil && model.articles.count == 2)
        await model.loadMore(source)
        #expect(!model.canLoadMore && !model.isLoadingMore)
        await model.loadMore(source)
        #expect(await transport.requestCount() == 4)
        let cached = try await database.cachedRssFeed(origin: source.sourceUrl, sort: source.sourceName)
        #expect(cached?.page == 3 && cached?.nextURL == nil)
    }

    @Test func cachedArticlesWithoutPagingMetadataRecoverNextPage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try LegadoDatabase(url: dir.appendingPathComponent("feed.sqlite"))
        let transport = RSSSequenceTransport(bodies: [#"{"items":[{"title":"刷新","link":"/1"}],"next":"/page/2/"}"#])
        let model = RSSLibraryModel(database: database, service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "$.next"
        try await database.putRssArticles([RssArticle(origin: source.sourceUrl, sort: source.sourceName, title: "旧缓存", link: "/1")])
        await model.refresh(source, preferCache: true)
        #expect(model.articles.map(\.title) == ["刷新"])
        #expect(model.canLoadMore)
    }

    @Test func cancelledFirstVisitCanReopenAndPaginate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RSSSequenceTransport(bodies: [nil,
            #"{"items":[{"title":"首页","link":"/1"}],"next":"/page/2/"}"#,
            #"{"items":[{"title":"第二页","link":"/2"}]}"#], failure: .cancelled)
        let model = RSSLibraryModel(database: try LegadoDatabase(url: dir.appendingPathComponent("feed.sqlite")),
                                    service: .init(transport: transport, networkPolicy: .init()))
        var source = source()
        source.ruleNextPage = "$.next"
        await model.refresh(source, preferCache: true)
        #expect(model.errorMessage == nil)
        await model.refresh(source, preferCache: true)
        #expect(model.canLoadMore)
        await model.loadMore(source)
        #expect(model.articles.map(\.title) == ["首页", "第二页"])
    }

    private func source() -> RssSource {
        var source = RssSource(sourceUrl: "https://rss-model.test", sourceName: "全部")
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleLink = "$.link"
        return source
    }
}

private actor RSSSequenceTransport: HTTPTransport {
    private var bodies: [String?]
    private var count = 0
    private let failure: URLError.Code
    init(bodies: [String?], failure: URLError.Code = .networkConnectionLost) { self.bodies = bodies; self.failure = failure }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        count += 1
        guard !bodies.isEmpty, let body = bodies.removeFirst() else { throw URLError(failure) }
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: request.url!)
    }
    func requestCount() -> Int { count }
}
