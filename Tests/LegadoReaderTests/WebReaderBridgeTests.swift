import Libavfilter
import Libavformat
import UIKit
import WebKit
import XCTest
@testable import Legado

@MainActor
final class WebReaderBridgeTests: XCTestCase {
    func testPlayerKeepsNativeVideoAndAudioFilters() {
        var iterator: UnsafeMutableRawPointer?
        var names = Set<String>()
        while let filter = av_filter_iterate(&iterator) {
            names.insert(String(cString: filter.pointee.name))
        }
        XCTAssertTrue(Set(["buffer", "buffersink", "transpose", "rotate", "hflip", "vflip",
                           "scale_vt", "yadif_videotoolbox", "aresample", "atempo"]).isSubset(of: names))
        XCTAssertFalse(names.contains("libplacebo"))
        XCTAssertFalse(names.contains { $0.hasSuffix("_vulkan") })
    }

    func testVideoInputProtocolsSupportWebStreamsAndExcludeSMB() {
        var iterator: UnsafeMutableRawPointer?
        var names = Set<String>()
        while let name = avio_enum_protocols(&iterator, 0) {
            names.insert(String(cString: name))
        }
        XCTAssertTrue(Set(["http", "https", "httpproxy", "tcp", "tls", "crypto"]).isSubset(of: names))
        XCTAssertFalse(names.contains("smb"))
    }

    private func webPrepared(script: String?, resource: String? = nil) throws -> PreparedRequest {
        let html = "<html><body><p>原始页面</p></body></html>"
        let address = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        var prepared = try LegadoURLBuilder().prepare(address)
        prepared.useWebView = true
        prepared.webJavaScript = script
        prepared.sourceRegex = resource
        return prepared
    }

    func testBackgroundWebViewUsesScriptReturnValueAndRetriesNull() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "网页正文")
        let executor = WKSourceWebViewExecutor()
        let response = try await executor.execute(webPrepared(script: "window.attempt = (window.attempt || 0) + 1; window.attempt < 3 ? null : '脚本正文' + window.attempt"), source: source, timeout: 5)
        XCTAssertEqual(response.decodedText, "脚本正文3")
        let empty = try await executor.execute(webPrepared(script: "''"), source: source, timeout: 5)
        XCTAssertEqual(empty.decodedText, "")
        var userAgent = try webPrepared(script: "navigator.userAgent")
        userAgent.headers["User-Agent"] = "Legado WK Regression/1.0"
        let identity = try await executor.execute(userAgent, source: source, timeout: 5)
        XCTAssertEqual(identity.decodedText, "Legado WK Regression/1.0")
    }

    func testBackgroundWebViewMatchesDispatchedResourceInsteadOfScriptOutput() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "资源网页")
        let prepared = try webPrepared(script: "fetch('data:text/plain,resource-match').catch(() => {}); 'ignored output'", resource: "data:text/plain,resource-match")
        let response = try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 5)
        XCTAssertEqual(response.decodedText, "data:text/plain,resource-match")
    }

    func testSlowDirectoryCanFinishWithinTheWebViewRequestTimeout() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "网页目录")
        let prepared = try webPrepared(script: """
            window.polls = (window.polls || 0) + 1;
            window.polls < 33 ? null : '完整目录'
            """)
        let response = try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 60)
        XCTAssertEqual(response.decodedText, "完整目录")
    }

    func testBackgroundWebViewLoadsPOSTResponseHTMLAndReportsMissingResource() async throws {
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "资源网页")
        var prepared = try webPrepared(script: "document.querySelector('p').textContent")
        prepared.webViewHTML = "<p>POST 返回的正文</p>"
        prepared.url = try XCTUnwrap(URL(string: source.id + "/posted"))
        let response = try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 5)
        XCTAssertEqual(response.decodedText, "POST 返回的正文")
        do {
            let missing = try webPrepared(script: nil, resource: "https://never-matches.test/.*")
            _ = try await WKSourceWebViewExecutor().execute(missing, source: source, timeout: 1)
            XCTFail("Unmatched resource must not become a successful HTML result")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未找到匹配")) }
    }

    func testBackgroundWebViewCancellationStopsNullPolling() async throws {
        let prepared = try webPrepared(script: "null")
        let source = BookSource(bookSourceUrl: "https://web-content.test", bookSourceName: "取消测试")
        let request = Task { try await WKSourceWebViewExecutor().execute(prepared, source: source, timeout: 5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testArticleLoaderHidesWhileAnImageIsStillLoading() async throws {
        let imageRequested = expectation(description: "Article requested its slow images")
        imageRequested.expectedFulfillmentCount = 2
        let images = PendingArticleImage(requested: imageRequested)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(images, forURLScheme: "slow-image")
        let source = RssSource(sourceUrl: "https://article.test", sourceName: "测试")
        let html = "<p>正文</p><img id='portrait' width='240' height='360' src='slow-image://fixture/portrait'><img id='unknown' src='slow-image://fixture/unknown'>"
        let surface = RSSWebReaderView(mode: .html(content: html, baseURL: nil), source: source)
        let coordinator = surface.makeCoordinator()
        configuration.userContentController.addUserScript(.init(source: coordinator.imageScript(baseURL: source.sourceUrl, isArticle: true),
                                                                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let webView = ReadingWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = coordinator
        defer { RSSWebReaderView.dismantleUIView(webView, coordinator: coordinator) }

        coordinator.installRulesAndLoad(mode: surface.mode, in: webView)
        await fulfillment(of: [imageRequested], timeout: 10)
        let readable = try await webView.evaluateJavaScript("document.querySelector('p').getBoundingClientRect().height > 0")
        XCTAssertEqual(readable as? Bool, true)
        XCTAssertTrue(webView.isLoading)
        let indicator = try XCTUnwrap(webView.subviews.compactMap { $0 as? RagdollImageView }.first)
        XCTAssertTrue(indicator.isHidden, "The loading cat should disappear once the article is displayed")

        let ratios = try await webView.evaluateJavaScript("""
            Array.from(document.images, img => {
              const box = img.getBoundingClientRect();
              return img.dataset.legadoPhotoState === 'loading' && box.width > 250 &&
                getComputedStyle(img).backgroundImage.includes('data:image/png') ? box.height / box.width : 0;
            })
            """)
        let sizes = try XCTUnwrap(ratios as? [Double])
        XCTAssertEqual(sizes, [1.5, 0.75])

        _ = try await webView.evaluateJavaScript("""
            window.portraitLoaded = new Promise(resolve => portrait.addEventListener('load', () => resolve(), {once:true}));
            window.unknownFailed = new Promise(resolve => unknown.addEventListener('error', () => resolve(), {once:true}));
            true
            """, in: nil, in: .defaultClient)
        let portrait = try XCTUnwrap(images.tasks["portrait"])
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360)).image { _ in }.pngData())
        portrait.didReceive(URLResponse(url: try XCTUnwrap(portrait.request.url), mimeType: "image/png",
                                        expectedContentLength: data.count, textEncodingName: nil))
        portrait.didReceive(data)
        portrait.didFinish()
        let state = try await webView.callAsyncJavaScript("""
            await window.portraitLoaded;
            return [portrait.dataset.legadoPhotoState || 'loaded', getComputedStyle(portrait).borderRadius,
                    Math.round(100 * portrait.height / portrait.width).toString(), unknown.dataset.legadoPhotoState];
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(state as? [String], ["loaded", "6px", "150", "loading"])

        try XCTUnwrap(images.tasks["unknown"]).didFailWithError(URLError(.cannotDecodeContentData))
        let failed = try await webView.callAsyncJavaScript("""
            await window.unknownFailed;
            return [unknown.dataset.legadoPhotoState || 'none', getComputedStyle(unknown).backgroundImage.includes('data:image/png') ? 'cat' : 'no cat'];
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(failed as? [String], ["failed", "no cat"])
    }

    func testGeneratedRSSContentFollowsAppearanceWithoutReloading() async throws {
        let source = RssSource(sourceUrl: "https://appearance-regression.test", sourceName: "测试")
        let surface = RSSWebReaderView(
            mode: .html(content: "<body><p>订阅正文</p><a href='#'>链接</a><button>操作</button></body>", baseURL: nil),
            source: source
        )
        let coordinator = surface.makeCoordinator()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = coordinator
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        controller.overrideUserInterfaceStyle = .dark
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            RSSWebReaderView.dismantleUIView(webView, coordinator: coordinator)
            window.isHidden = true
        }
        coordinator.installRulesAndLoad(mode: surface.mode, in: webView)
        let loaded = expectation(for: NSPredicate(format: "estimatedProgress == 1 AND loading == NO"), evaluatedWith: webView)
        await fulfillment(of: [loaded], timeout: 20)
        let appearanceScript = """
        [matchMedia('(prefers-color-scheme:dark)').matches,
         getComputedStyle(document.body).backgroundColor,
         getComputedStyle(document.body).color,
         getComputedStyle(document.querySelector('a')).color,
         getComputedStyle(document.documentElement).colorScheme].map(String).join('|')
        """
        let dark = try await webView.evaluateJavaScript(appearanceScript)
        XCTAssertEqual(dark as? String, "true|rgb(17, 17, 19)|rgb(242, 242, 242)|rgb(158, 203, 255)|light dark")
        _ = try await webView.evaluateJavaScript("window.appearanceMarker = 'preserved'")
        controller.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        XCTAssertEqual(webView.traitCollection.userInterfaceStyle, .light)
        var light = try await webView.evaluateJavaScript(appearanceScript)
        for _ in 0..<50 {
            if (light as? String)?.hasPrefix("false|") == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
            light = try await webView.evaluateJavaScript(appearanceScript)
        }
        XCTAssertEqual(light as? String, "false|rgb(252, 252, 252)|rgb(23, 23, 23)|rgb(0, 0, 238)|light dark")
        let marker = try await webView.evaluateJavaScript("window.appearanceMarker")
        XCTAssertEqual(marker as? String, "preserved")
        // A source may intentionally override the generated article palette.
        _ = try await webView.evaluateJavaScript("document.head.insertAdjacentHTML('beforeend', '<style>body{color:rgb(120,30,40)}</style>')")
        let custom = try await webView.evaluateJavaScript("getComputedStyle(document.body).color")
        XCTAssertEqual(custom as? String, "rgb(120, 30, 40)")
    }

    func testPageJavaScriptCanStoreVariablesAndEvaluateContentRules() async throws {
        let source = RssSource(sourceUrl: "https://bridge-regression.test/\(UUID().uuidString)", sourceName: "测试")
        let surface = RSSWebReaderView(mode: .html(content: "<p>页面正文</p>", baseURL: source.sourceUrl), source: source)
        let coordinator = surface.makeCoordinator()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "legado")
        configuration.userContentController.addUserScript(.init(source: coordinator.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        let window = UIWindow(frame: webView.frame)
        let controller = UIViewController()
        controller.view.addSubview(webView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            RSSWebReaderView.dismantleUIView(webView, coordinator: coordinator)
            window.isHidden = true
        }
        coordinator.installRulesAndLoad(mode: surface.mode, in: webView)
        let loaded = expectation(for: NSPredicate(format: "estimatedProgress == 1 AND loading == NO"), evaluatedWith: webView)
        await fulfillment(of: [loaded], timeout: 20)

        let result = try await webView.evaluateJavaScript("""
            java.put('key', '已保存');
            java.setContent('<div><p>规则正文</p></div>');
            [java.get('key'), java.getString('tag.p@text')].join('|');
            """)
        XCTAssertEqual(result as? String, "已保存|规则正文")
    }
}

@MainActor
private final class PendingArticleImage: NSObject, WKURLSchemeHandler {
    let requested: XCTestExpectation
    var tasks: [String: WKURLSchemeTask] = [:]

    init(requested: XCTestExpectation) { self.requested = requested }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        if let url = urlSchemeTask.request.url { tasks[url.lastPathComponent] = urlSchemeTask }
        requested.fulfill()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private actor RSSPaginationTransport: HTTPTransport {
    private var requests: [URL] = []
    private var shouldFailSecondPage = true

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try XCTUnwrap(request.url)
        requests.append(url)
        if url.host == "unavailable.test" { throw URLError(.cannotConnectToHost) }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "page" }?.value ?? "1"
        if page == "2", shouldFailSecondPage {
            shouldFailSecondPage = false
            throw URLError(.networkConnectionLost)
        }
        let body = "{\"items\":[{\"title\":\"Page \(page)\",\"link\":\"https://feed.test/article/\(page)\"}]}"
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }

    func requestedPages() -> [String] {
        requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value }
    }

    func requestCount() -> Int { requests.count }
}

private actor RSSDelayedTransport: HTTPTransport {
    let pausedHost: String
    let pausedPage: String
    private var requestTotal = 0
    private var pending: CheckedContinuation<Void, Never>?

    init(host: String, page: String) { pausedHost = host; pausedPage = page }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try XCTUnwrap(request.url)
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "page" }?.value ?? "1"
        requestTotal += 1
        if url.host == pausedHost, page == pausedPage {
            await withCheckedContinuation { continuation in
                pending = continuation
            }
        }
        let body = "{\"items\":[{\"title\":\"Page \(page)\",\"link\":\"https://feed.test/article/\(page)\"}]}"
        return .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: url)
    }

    func waitUntilPaused() async throws {
        for _ in 0..<500 {
            if pending != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.timedOut)
    }

    func resume() { pending?.resume(); pending = nil }
    func requestCount() -> Int { requestTotal }
}

@MainActor
final class RSSLibraryRegressionTests: XCTestCase {
    func testUnavailableDatabaseDoesNotCrashOrPublishUnsavedImports() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("existing file".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let model = RSSLibraryModel.live(databaseURL: blocked.appendingPathComponent("rss.sqlite3"))
        XCTAssertNotNil(model.errorMessage)
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        let saved = await model.save(source(), replacing: nil)
        XCTAssertFalse(saved)
        await model.importText(#"{"sourceUrl":"https://feed.test","sourceName":"未保存的订阅"}"#)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("existing file".utf8))
    }

    private func source(host: String = "feed.test") -> RssSource {
        var source = RssSource(sourceUrl: "https://\(host)", sourceName: host)
        source.sortUrl = "https://\(host)/list?page={{page}}"
        source.ruleArticles = "$.items"
        source.ruleTitle = "$.title"
        source.ruleLink = "$.link"
        source.ruleNextPage = "PAGE"
        return source
    }

    func testFailedNextPageRetriesTheSamePageWithoutSkippingArticles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSPaginationTransport()
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        let feed = source()
        await model.refresh(feed)
        XCTAssertEqual(model.articles.map(\.title), ["Page 1"])
        await model.loadMore(feed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.articles.map(\.title), ["Page 1"])
        await model.loadMore(feed)
        let pages = await transport.requestedPages()
        XCTAssertEqual(pages, ["1", "2", "2"])
        XCTAssertEqual(model.articles.map(\.title), ["Page 1", "Page 2"])
    }

    func testFailedSourceChangeDoesNotReusePreviousSourcesArticlesOrNextPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSPaginationTransport()
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        await model.refresh(source())
        let unavailable = source(host: "unavailable.test")
        await model.refresh(unavailable)
        XCTAssertTrue(model.articles.isEmpty)
        let count = await transport.requestCount()
        await model.loadMore(unavailable)
        let afterLoadMore = await transport.requestCount()
        XCTAssertEqual(afterLoadMore, count)
    }

    func testSlowPreviousSourceCannotReplaceTheCurrentFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSDelayedTransport(host: "slow.test", page: "1")
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        let slow = Task { await model.refresh(source(host: "slow.test")) }
        try await transport.waitUntilPaused()
        await model.refresh(source())
        XCTAssertTrue(model.isWorking)
        await transport.resume()
        await slow.value
        XCTAssertEqual(model.articles.map(\.origin), ["https://feed.test"])
        XCTAssertFalse(model.isWorking)
    }

    func testRepeatedLoadMoreWhileWaitingRequestsOnlyOnePage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LegadoDatabase(url: directory.appendingPathComponent("rss.sqlite3"))
        let transport = RSSDelayedTransport(host: "feed.test", page: "2")
        let model = RSSLibraryModel(database: database, service: RSSService(transport: transport))
        let feed = source()
        await model.refresh(feed)
        let pending = Task { await model.loadMore(feed) }
        try await transport.waitUntilPaused()
        await model.loadMore(feed)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
        await transport.resume()
        await pending.value
        XCTAssertEqual(model.articles.map(\.title), ["Page 1", "Page 2"])
    }
}
