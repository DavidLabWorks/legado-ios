@preconcurrency import WebKit
import SwiftUI
import UIKit

struct SourceLoginView: View {
    let source: BookSource
    var sheetClose: (() -> Void)? = nil
    @State private var reloadID = UUID()
    @State private var status = "打开登录页后，Cookie 会自动同步给搜索与阅读请求。"
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(ReadingTheme.accent)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if isChecking { RagdollLoading(width: 28) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            if let request = loginRequest {
                SourceLoginWebView(
                    request: request,
                    sourceURL: source.bookSourceUrl,
                    sourceID: source.id,
                    loginCheckJavaScript: source.loginCheckJs,
                    reloadID: reloadID,
                    status: $status,
                    isChecking: $isChecking
                )
            } else {
                ReadingUnavailableView("登录地址无效", systemImage: "link.badge.plus", description: Text(source.loginUrl ?? "书源没有配置登录地址"))
            }
        }
        .readingRouteHeader("登录 · \(source.bookSourceName)", close: sheetClose) {
            Button("重新载入", systemImage: "arrow.clockwise") { reloadID = UUID() }
        }
    }

    private var loginRequest: URLRequest? {
        guard let value = source.loginUrl,
              let prepared = try? LegadoURLBuilder().prepare(
                value,
                baseURL: URL(string: source.bookSourceUrl),
                defaultHeaders: sourceHeaders
              ) else { return nil }
        return prepared.urlRequest(handleCookies: source.enabledCookieJar ?? true)
    }

    private var sourceHeaders: [String: String] {
        guard let value = source.header,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let request: URLRequest
    let sourceURL: String
    let sourceID: String
    let loginCheckJavaScript: String?
    let reloadID: UUID
    @Binding var status: String
    @Binding var isChecking: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = ReadingWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.navigationDelegate = context.coordinator
        context.coordinator.installExistingCookies(in: webView) { webView.load(request) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadID != reloadID else { return }
        context.coordinator.lastReloadID = reloadID
        webView.reload()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SourceLoginWebView
        var lastReloadID: UUID

        init(parent: SourceLoginWebView) {
            self.parent = parent
            lastReloadID = parent.reloadID
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.status = "正在打开登录页…"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            syncCookies(from: webView)
            guard let script = parent.loginCheckJavaScript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !script.isEmpty else {
                parent.status = "页面已载入；登录后 Cookie 会自动同步。"
                return
            }
            parent.isChecking = true
            webView.evaluateJavaScript(script) { [weak self] value, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.parent.isChecking = false
                    if let error {
                        self.parent.status = "登录检测脚本失败：\(error.localizedDescription)"
                    } else {
                        self.parent.status = Self.truthy(value) ? "书源登录检测已通过" : "页面已载入，尚未检测到登录状态"
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func installExistingCookies(in webView: WKWebView, completion: @escaping () -> Void) {
            guard let url = URL(string: parent.sourceURL) else {
                completion()
                return
            }
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            guard !cookies.isEmpty else {
                completion()
                return
            }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }

        private func syncCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cookies.forEach(HTTPCookieStorage.shared.setCookie)
                guard let url = URL(string: self.parent.sourceURL) else { return }
                let matching = HTTPCookieStorage.shared.cookies(for: url) ?? []
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
                Task {
                    await SourceNetworkPolicy.shared.setCookieHeader(
                        header,
                        sourceID: self.parent.sourceID,
                        url: url
                    )
                }
            }
        }

        private static func truthy(_ value: Any?) -> Bool {
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.boolValue }
            guard let text = value.map(String.init(describing:))?.lowercased() else { return false }
            return !text.isEmpty && !["false", "0", "null", "undefined"].contains(text)
        }
    }
}

final class WKSourceWebViewExecutor: NSObject, SourceWebViewRequestExecuting, @unchecked Sendable {
    @MainActor
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        let override = ApplicationSettingsStore.shared.settings.timeoutSeconds
        return try await BackgroundWebViewRequest(prepared: prepared, source: source, timeout: override > 0 ? Double(override) : timeout).run()
    }
}

@MainActor
private final class BackgroundWebViewRequest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let prepared: PreparedRequest
    private let source: BookSource
    private let timeout: TimeInterval
    private let webView: WKWebView
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var responseStatus: Int?
    private var responseHeaders: [String: String] = [:]
    private var completed = false
    private var timeoutTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var sourcePattern: NSRegularExpression?
    private var collectingResponse = false
    private let documentReadyCondition: String?
    private var emptyScriptResults = 0

    init(prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) {
        self.prepared = prepared
        self.source = source
        self.timeout = timeout
        let readsDirectoryAtDocumentEnd = source.id.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://101kks.com"
            && prepared.url.scheme == "https" && prepared.url.host == "101kks.com"
            && prepared.url.user == nil && prepared.url.password == nil && (prepared.url.port ?? 443) == 443
            && prepared.url.path.range(of: #"^/book/[0-9]+/index\.html$"#, options: .regularExpression) != nil
            && prepared.webJavaScript?.isEmpty == false && prepared.sourceRegex == nil
        if readsDirectoryAtDocumentEnd {
            documentReadyCondition = #"/展[開开]\s*全\s*部\s*[\d,]+\s*[章節节]/.test(document.body?.innerText || '')"#
        } else if URL(string: source.id)?.host == "www.qidian.com",
                  prepared.url.host == "www.qidian.com", prepared.url.scheme == "https",
                  prepared.url.path.range(of: #"^/book/[0-9]+(?:/catalog)?/?$"#, options: .regularExpression) != nil,
                  let script = prepared.webJavaScript, prepared.sourceRegex == nil {
            if prepared.url.lastPathComponent == "catalog", script.contains("#j-catalogWrap") {
                documentReadyCondition = "document.querySelector('#j-catalogWrap .volume li a')"
            } else if script.contains("og:novel:book_name") {
                documentReadyCondition = "document.querySelector('meta[property=\"og:novel:book_name\"]')"
            } else {
                documentReadyCondition = nil
            }
        } else {
            documentReadyCondition = nil
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: readsDirectoryAtDocumentEnd ? UIScreen.main.bounds : .zero, configuration: configuration)
        webView.customUserAgent = prepared.headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        super.init()
        webView.navigationDelegate = self
        if prepared.sourceRegex != nil {
            configuration.userContentController.addUserScript(.init(source: Self.resourceObserver,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    func run() async throws -> HTTPResponse {
        try Task.checkCancellation()
        if let pattern = prepared.sourceRegex { sourcePattern = try NSRegularExpression(pattern: pattern) }
        if let documentReadyCondition {
            let controller = webView.configuration.userContentController
            controller.add(self, contentWorld: .defaultClient, name: "legadoDirectoryReady")
            let ready = "if (\(documentReadyCondition)) window.webkit.messageHandlers.legadoDirectoryReady.postMessage(null);"
            controller.addUserScript(.init(source: ready,
                                           injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        if sourcePattern != nil { webView.configuration.userContentController.add(self, name: "legadoResource") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                installRequestCookies { [weak self] in self?.startLoading() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func startLoading() {
        guard !completed else { return }
        timeoutTask = Task { [weak self] in
            let seconds = min(max(self?.timeout ?? 30, 1), 300)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let error: Error
            if let pattern = prepared.sourceRegex {
                error = RuleEngineError.invalidInput(rule: pattern, expected: "WebView 在超时前未找到匹配的可观察资源地址")
            } else { error = URLError(.timedOut) }
            finish(.failure(error))
        }
        if let html = prepared.webViewHTML {
            webView.loadHTMLString(html, baseURL: prepared.url)
        } else {
            webView.load(prepared.urlRequest(timeout: timeout, handleCookies: true))
        }
    }

    private func installRequestCookies(completion: @escaping () -> Void) {
        guard let header = prepared.headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value,
              let host = prepared.url.host, !header.isEmpty else {
            completion()
            return
        }
        let cookies = header.split(separator: ";").flatMap { part -> [HTTPCookie] in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return [] }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            let scoped = prepared.webViewCookies.filter { $0.name == name && $0.value == pair[1] }
            if !scoped.isEmpty { return scoped }
            let cookie = HTTPCookie(properties: [
                .name: name,
                .value: pair[1],
                .domain: host,
                .path: "/",
                .secure: prepared.url.scheme == "https" ? "TRUE" : "FALSE"
            ])
            return cookie.map { [$0] } ?? []
        }
        guard !cookies.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            responseStatus = response.statusCode
            responseHeaders = response.allHeaderFields.reduce(into: [:]) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        evaluatePage()
    }

    private func evaluatePage() {
        guard !completed, evaluationTask == nil else { return }
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let responseStatus, !(200..<300).contains(responseStatus) {
                    if documentReadyCondition != nil && responseStatus == 403 {
                        var details = ["后台目录页 HTTP 403"]
                        let headers = HTTPURLResponse(url: prepared.url, statusCode: responseStatus, httpVersion: nil, headerFields: responseHeaders)
                        if headers?.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" {
                            details.append("服务器要求网页验证")
                        }
                        if let delay = headers?.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(delay), seconds >= 0 {
                            details.append("服务器建议等待 \(seconds) 秒")
                        }
                        let titleCode = webView.title?.prefix(3) ?? ""
                        if ["500", "502", "503", "504", "520", "521", "522", "523", "524"].contains(String(titleCode)) {
                            details.append("错误页标题含 \(titleCode)")
                        }
                        DiagnosticLog.shared.record(.error, category: "网页目录", message: details.joined(separator: " · "))
                    }
                    let response = HTTPResponse(data: Data(), statusCode: responseStatus, headers: responseHeaders,
                                                finalURL: webView.url ?? prepared.url)
                    finish(.failure(HTTPClientError.statusResponse(response)))
                    return
                }
                let defaultDelay = prepared.webJavaScript == nil ? 900 : 0
                let delay = 100 + min(max(prepared.webViewDelayMilliseconds, defaultDelay), 300_000)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                guard !completed else { return }
                if sourcePattern != nil {
                    // Resource sniffing has priority over script output; the
                    // script may start a media/fetch request after load.
                    if let script = prepared.webJavaScript, !script.isEmpty {
                        _ = try await webView.evaluateJavaScript(script)
                    }
                    return
                }
                let script = prepared.webJavaScript.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "document.documentElement.outerHTML"
                var pollDelay: UInt64 = 200_000_000
                // The request timer also covers scripts waiting for a directory to expand.
                while !completed {
                    try Task.checkCancellation()
                    let value = try await webView.evaluateJavaScript(script)
                    try Task.checkCancellation()
                    if let value, !(value is NSNull) {
                        let body: String
                        if let string = value as? String { body = string }
                        else {
                            body = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
                        }
                        await deliver(body)
                        return
                    }
                    emptyScriptResults += 1
                    try await Task.sleep(nanoseconds: pollDelay)
                    pollDelay = min(pollDelay + 200_000_000, 1_000_000_000)
                }
            } catch {
                guard !Task.isCancelled else { return }
                finish(.failure(error))
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "legadoDirectoryReady" {
            guard documentReadyCondition != nil, message.frameInfo.isMainFrame,
                  let url = webView.url, url.host == prepared.url.host, url.path == prepared.url.path,
                  url.scheme == prepared.url.scheme, url.port == prepared.url.port else { return }
            evaluatePage()
            return
        }
        guard let address = message.body as? String else { return }
        observeResource(address)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        evaluationTask?.cancel()
        evaluationTask = nil
        emptyScriptResults = 0
        if prepared.webViewHTML == nil, let address = webView.url?.absoluteString { observeResource(address) }
    }

    private func observeResource(_ address: String) {
        guard !completed, !collectingResponse, let pattern = sourcePattern else { return }
        let range = NSRange(address.startIndex..., in: address)
        guard pattern.firstMatch(in: address, range: range)?.range == range else { return }
        collectingResponse = true
        Task { [weak self] in await self?.deliver(address) }
    }

    private func deliver(_ body: String) async {
        guard !completed else { return }
        var response = HTTPResponse(data: Data(body.utf8), statusCode: responseStatus ?? 200, headers: responseHeaders,
                                    finalURL: webView.url ?? prepared.url, requestedCharset: "utf-8")
        if source.enabledCookieJar == true {
            response.webViewCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        }
        guard !completed, !Task.isCancelled else { return }
        finish(.success(response))
    }

    // Public WK APIs do not expose every network request. Observe browser
    // resource timing, dispatched fetch/XHR, and media load events, including
    // frames. Native HLS segments, service-worker internals and DRM traffic
    // cannot be promised; a missing match fails explicitly at the deadline.
    private static let resourceObserver = #"""
    (() => {
        const send = value => {
            try { if (value) window.webkit.messageHandlers.legadoResource.postMessage(new URL(String(value), document.baseURI).href); } catch (_) {}
        };
        try {
            new PerformanceObserver(list => list.getEntries().forEach(entry => send(entry.name))).observe({type:'resource', buffered:true});
        } catch (_) {}
        const originalFetch = window.fetch;
        if (originalFetch) window.fetch = function(input, init) {
            const result = originalFetch.apply(this, arguments);
            send(typeof input === 'string' || input instanceof URL ? input : input.url);
            return result;
        };
        const open = XMLHttpRequest.prototype.open, transmit = XMLHttpRequest.prototype.send;
        const addresses = new WeakMap();
        XMLHttpRequest.prototype.open = function(method, url) { const result = open.apply(this, arguments); addresses.set(this, url); return result; };
        XMLHttpRequest.prototype.send = function() { const result = transmit.apply(this, arguments); send(addresses.get(this)); return result; };
        document.addEventListener('loadstart', event => {
            if (event.target instanceof HTMLMediaElement) send(event.target.currentSrc || event.target.src);
        }, true);
        window.addEventListener('load', () => performance.getEntriesByType('resource').forEach(entry => send(entry.name)));
    })();
    """#

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !completed else { return }
        completed = true
        if documentReadyCondition != nil {
            if case .failure(let error) = result, (error as? URLError)?.code == .timedOut {
                let stage = evaluationTask == nil ? "尚未开始解析目录" : "目录脚本已启动，返回空结果 \(emptyScriptResults) 次"
                let status = responseStatus.map { "HTTP \($0)" } ?? "尚未收到主页面 HTTP 状态"
                DiagnosticLog.shared.record(.error, category: "网页目录",
                    message: "\(DiagnosticLog.safeURL(prepared.url)) · \(status) · \(stage)")
            }
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "legadoDirectoryReady", contentWorld: .defaultClient)
        }
        timeoutTask?.cancel()
        evaluationTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "legadoResource")
        webView.navigationDelegate = nil
        webView.stopLoading()
        continuation?.resume(with: result)
        continuation = nil
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}

enum BrowserBookPageAction {
    case search(BrowserSearchPage, (String) async throws -> Void)
    case directory(URL, ([[String: String]]) async throws -> Void)
}

struct BrowserBookPageView: View {
    let url: URL
    let action: BrowserBookPageAction
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: BrowserBookDocument

    init(url: URL, action: BrowserBookPageAction) {
        self.url = url
        self.action = action
        let manual: Bool
        if case .search(let page, _) = action { manual = page.manualVerification != nil } else { manual = false }
        _browser = StateObject(wrappedValue: BrowserBookDocument(manualVerification: manual))
    }

    private var searchPage: BrowserSearchPage? {
        if case .search(let page, _) = action { return page }
        return nil
    }
    @State private var message: String?
    private var directoryURL: URL? {
        if case .directory(let directory, _) = action { return directory }
        return nil
    }
    private var isDirectory: Bool { directoryURL != nil }
    private var instructions: String {
        isDirectory ? "如需验证，请按网页提示完成。目录加载后会自动导入。"
                    : "如果网站要求验证，请在下方完成。看到书籍后，点“使用此页结果”。"
    }
    @State private var importing = false

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                Text(browser.problem ?? message ?? instructions)
                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                BrowserBookWebView(browser: browser, url: url, isDirectory: isDirectory,
                                   useSourceCookies: searchPage?.manualVerification != nil && searchPage?.source.enabledCookieJar == true)
                if let directoryURL {
                    if !browser.isShowing(directoryURL), browser.ready {
                        Button("打开本书目录") { browser.webView.load(URLRequest(url: directoryURL)) }
                            .buttonStyle(.bordered).padding(10)
                    }
                } else {
                    Button("使用此页结果") {
                        guard case .search(let page, let useResults) = action else { return }
                        importing = true
                        Task { @MainActor in
                            defer { importing = false }
                            do {
                                let html = try await page.manualVerification == nil
                                    ? browser.bookLinks(at: url) : browser.verifiedResults(at: url)
                                try await useResults(html)
                                dismiss()
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!browser.ready || importing)
                    .padding(10)
                }
            }
            .readingSheetTitle(searchPage.map { "\($0.source.bookSourceName) · 网页搜索" } ?? "101 看书")
            .toolbar {
                ReadingSheetActions {
                    Button("重新打开") { browser.webView.load(URLRequest(url: url)) }.disabled(importing)
                    ReadingSheetCloseButton { dismiss() }.disabled(importing)
                }
            }
        }
        .task(id: browser.documentID) {
            guard case .directory(let directory, let useChapters) = action, browser.ready,
                  browser.isShowing(directory) else { return }
            do {
                message = "正在解析网页目录…"
                let rows = try await browser.expandedChapterLinks(at: directory) { message = $0 }
                try Task.checkCancellation()
                importing = true
                defer { importing = false }
                try await useChapters(rows)
                dismiss()
            } catch is CancellationError {
                return
            } catch { message = error.localizedDescription }
        }
        .interactiveDismissDisabled(importing)
    }
}

@MainActor
private final class BrowserBookDocument: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var ready = false
    @Published var problem: String?
    @Published private(set) var documentID = UUID()
    private var status: Int?

    // The two user-visible pages share their own in-memory browser session.
    private static let websiteDataStore = WKWebsiteDataStore.nonPersistent()

    init(manualVerification: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = manualVerification ? .nonPersistent() : Self.websiteDataStore
        if manualVerification { configuration.defaultWebpagePreferences.preferredContentMode = .mobile }
        webView = ReadingWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        status = nil
        ready = false
        problem = nil
        documentID = UUID()
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame { status = (response.response as? HTTPURLResponse)?.statusCode }
        decisionHandler(.allow)
    }

    func isShowing(_ url: URL) -> Bool {
        guard let current = webView.url else { return false }
        return current.scheme == url.scheme && current.host == url.host && current.port == url.port && current.path == url.path
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        ready = status.map { (200..<300).contains($0) } ?? false
        documentID = UUID()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        ready = status.map { (200..<300).contains($0) } ?? false
        if !ready, let status { problem = "网站返回 HTTP \(status)。如有验证提示，请按网页提示操作。" }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { ready = false; problem = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func rememberDirectorySize() {
        // Some pages hide the expand button before the new chapter links arrive.
        let script = #"""
        if (/^\/book\/\d+\/index\.html$/.test(location.pathname)) {
            const record = () => {
                const m = document.body?.innerText.match(/展[開开]\s*全\s*部\s*([\d,]+)\s*[章節节]/);
                if (m) window.legadoVisibleDirectoryCount = Number(m[1].replace(/,/g, ""));
            };
            document.addEventListener("DOMContentLoaded", record, {once: true});
            document.addEventListener("click", record, true);
        }
        """#
        webView.configuration.userContentController.addUserScript(WKUserScript(source: script,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    }

    func expandedChapterLinks(at url: URL, progress: (String) -> Void) async throws -> [[String: String]] {
        let document = documentID
        for attempt in 0...40 {
            try Task.checkCancellation()
            guard document == documentID, ready, isShowing(url) else { throw CancellationError() }
            do {
                let rows = try await chapterLinks(at: url, expand: true)
                try Task.checkCancellation()
                guard document == documentID else { throw CancellationError() }
                return rows
            } catch let error as NSError where error.domain == "BrowserDirectory" {
                if attempt == 40 {
                    let detail = error.localizedDescription.replacingOccurrences(of: "，正在等待完整目录", with: "")
                    throw NSError(domain: "BrowserDirectory", code: 4, userInfo: [NSLocalizedDescriptionKey:
                        "目录未能自动导入。\(detail)可点“重新打开”再试。"])
                }
                progress(error.localizedDescription)
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw URLError(.timedOut)
    }

    func chapterLinks(at url: URL, expand: Bool = false) async throws -> [[String: String]] {
        let script = #"""
        const target = new URL(expected);
        const id = target.pathname.match(/^\/book\/(\d+)\/index\.html$/)?.[1];
        if (!id || location.origin !== target.origin || location.pathname !== target.pathname) return null;
        if (document.readyState === "loading") return { rows: [], expectedCount: 0 };
        const links = new Map();
        let visibleEntries = 0;
        for (const link of document.links) {
            const u = new URL(link.href);
            const match = u.pathname.match(/^\/txt\/(\d+)\/(\d+)\.html$/);
            if (u.origin !== target.origin || u.username || u.password || !match || match[1] !== id) continue;
            if (!link.getClientRects().length || getComputedStyle(link).visibility !== "visible") continue;
            const title = link.innerText.trim();
            if (title) {
                visibleEntries++;
                links.set(u.origin + u.pathname, title);
            }
        }
        const more = document.body.innerText.match(/展[開开]\s*全\s*部\s*([\d,]+)\s*[章節节]/);
        const expectedCount = Math.max(window.legadoVisibleDirectoryCount || 0, more ? Number(more[1].replace(/,/g, "")) : 0);
        if (expand && more && links.size && links.size < expectedCount && !window.legadoDidExpandDirectory) {
            // Use the site's visible expand control only on this book's directory.
            const label = /^(?:[點点][擊击]\s*)?展[開开]\s*全\s*部\s*[\d,]+\s*[章節节]/;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            for (let node; (node = walker.nextNode());) {
                if (!/[點点展]/.test(node.textContent)) continue;
                let el = node.parentElement;
                if (!el?.getClientRects().length || getComputedStyle(el).visibility !== "visible") continue;
                while (el && el !== document.body && el.textContent.length < 100 && !label.test(el.innerText.trim())) {
                    el = el.parentElement;
                }
                if (!el || el === document.body || el.textContent.length >= 100 || !label.test(el.innerText.trim())) continue;
                const button = el.closest("a,button,[role=button],[onclick]") || el;
                window.legadoVisibleDirectoryCount = expectedCount;
                window.legadoDidExpandDirectory = true;
                window.legadoPreviewCount = links.size;
                button.click();
                break;
            }
        }
        const result = Array.from(links, ([url, title]) => ({url, title}));
        const numbered = result.map(row => row.title.match(/^第\s*(\d+)\s*章/)).filter(Boolean);
        if (numbered.length > 1 && Number(numbered[0][1]) > Number(numbered[numbered.length-1][1])) result.reverse();
        // Some lists include a repeated chapter. Count rendered entries for completeness
        // only after expansion, then import each chapter URL once.
        const expanded = window.legadoDidExpandDirectory && links.size > window.legadoPreviewCount;
        const accountedFor = expanded && visibleEntries === expectedCount ? visibleEntries : links.size;
        return { rows: result, expectedCount, accountedFor };
        """#
        guard ready, let page = try await webView.callAsyncJavaScript(script, arguments: ["expected": url.absoluteString, "expand": expand],
                                                                       in: nil, contentWorld: .defaultClient) as? [String: Any],
              let links = page["rows"] as? [[String: String]], let expectedCount = page["expectedCount"] as? Int else {
            throw NSError(domain: "BrowserDirectory", code: 1, userInfo: [NSLocalizedDescriptionKey: "请打开这本书的目录页。"])
        }
        if (page["accountedFor"] as? Int ?? links.count) < expectedCount {
            throw NSError(domain: "BrowserDirectory", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "已识别 \(links.count) 条章节链接，网页标注共 \(expectedCount) 条，正在等待完整目录。"])
        }
        guard !links.isEmpty else {
            throw NSError(domain: "BrowserDirectory", code: 3, userInfo: [NSLocalizedDescriptionKey: "当前页面尚未显示可导入的章节链接。"])
        }
        return links
    }

    func verifiedResults(at url: URL, waitingMessage: String = "请在本次搜索页提交验证码，等书籍结果出现后再导入。") async throws -> String {
        let document = documentID
        // Return visible content for the source's own selectors. Never include
        // submitted fields, scripts or other executable page content.
        let script = #"""
        const expectedURL = new URL(expected);
        if (location.origin !== expectedURL.origin || location.pathname !== expectedURL.pathname ||
            location.search !== expectedURL.search || document.readyState === "loading") return "";
        const visible = el => el.getClientRects().length && getComputedStyle(el).visibility !== "hidden";
        if (Array.from(document.querySelectorAll("input[name=yzm]")).some(visible)) return "";
        const excluded = "script,style,form,input,button,select,textarea,iframe,object,embed,template,noscript";
        const output = document.implementation.createHTMLDocument("");
        function copy(from, to) {
            for (const node of from.childNodes) {
                if (node.nodeType === Node.TEXT_NODE) { to.append(node.textContent); continue; }
                if (node.nodeType !== Node.ELEMENT_NODE || node.matches(excluded) ||
                    node.namespaceURI !== "http://www.w3.org/1999/xhtml" ||
                    node.hidden || getComputedStyle(node).display === "none") continue;
                const el = output.createElement(node.localName);
                for (const key of ["class","id","title","alt"]) {
                    if (node.hasAttribute(key)) el.setAttribute(key, node.getAttribute(key));
                }
                for (const key of ["href","src"]) {
                    if (!node.hasAttribute(key)) continue;
                    try {
                        const resolved = new URL(node.getAttribute(key), document.baseURI);
                        if (["http:","https:"].includes(resolved.protocol)) el.setAttribute(key, resolved.href);
                    } catch (_) {}
                }
                to.append(el);
                copy(node, el);
            }
        }
        copy(document.body, output.body);
        return output.body.innerHTML;
        """#
        guard ready, let html = try await webView.callAsyncJavaScript(script, arguments: ["expected": url.absoluteString],
                                                                      in: nil, contentWorld: .defaultClient) as? String,
              documentID == document, !html.isEmpty else {
            throw NSError(domain: "BrowserSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: waitingMessage])
        }
        return html
    }

    func bookLinks(at url: URL) async throws -> String {
        // Only copy visible book titles and links from the requested results page.
        let script = #"""
        const target = new URL(expected);
        if (location.origin !== target.origin || decodeURI(location.pathname) !== decodeURI(target.pathname)
            || location.search !== target.search) return "";
        const list = document.createElement("div");
        for (const link of document.links) {
            const u = new URL(link.href);
            if (u.origin !== target.origin || u.username || u.password || !/^\/book\/\d+\.html$/.test(u.pathname)) continue;
            if (!link.getClientRects().length || getComputedStyle(link).visibility !== "visible") continue;
            const title = link.innerText.trim();
            if (!title) continue;
            const a = document.createElement("a");
            a.href = u.origin + u.pathname;
            a.textContent = title;
            list.append(a);
        }
        return list.childElementCount ? list.outerHTML : "";
        """#
        guard ready, let html = try await webView.callAsyncJavaScript(script, arguments: ["expected": url.absoluteString],
                                                                      in: nil, contentWorld: .defaultClient) as? String,
              !html.isEmpty else {
            throw NSError(domain: "BrowserSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: "请回到本次搜索结果页，确认网页已显示书籍。"])
        }
        return html
    }
}

private struct BrowserBookWebView: UIViewRepresentable {
    let browser: BrowserBookDocument
    let url: URL
    let isDirectory: Bool
    let useSourceCookies: Bool

    func makeUIView(context: Context) -> WKWebView {
        if isDirectory { browser.rememberDirectorySize() }
        let webView = browser.webView
        let cookies = useSourceCookies ? HTTPCookieStorage.shared.cookies(for: url) ?? [] : []
        if cookies.isEmpty {
            webView.load(URLRequest(url: url))
        } else {
            Task { @MainActor in
                for cookie in cookies { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

struct BrowserChapterView: View {
    let book: Book
    let chapter: BookChapter
    let source: BookSource
    let nextChapterURL: String?
    let accept: (ChapterContentReport) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserBookDocument(manualVerification: true)
    @State private var pageURL: URL?
    @State private var submission: AsyncStream<String>.Continuation?
    @State private var message: String?
    @State private var retry = 0
    @State private var failed = false
    private let instructions = "如需验证，请按原站提示操作。看到正文后，点“使用本页正文”。"

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                Text(message ?? browser.problem ?? instructions)
                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                if let pageURL {
                    BrowserBookWebView(browser: browser, url: pageURL, isDirectory: false,
                                       useSourceCookies: source.enabledCookieJar == true)
                }
                if failed {
                    Button("重新读取本章") { retry += 1 }.padding()
                } else {
                    Button("使用本页正文") {
                        guard let pageURL, let submission else { return }
                        Task { @MainActor in
                            do {
                                let html = try await browser.verifiedResults(at: pageURL, waitingMessage: instructions)
                                submission.yield(html)
                                submission.finish()
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent).padding().disabled(!browser.ready || submission == nil)
                }
            }
            .readingSheetTitle(chapter.title)
            .toolbar {
                ReadingSheetActions {
                    if let pageURL { Button("重新载入") { browser.webView.load(URLRequest(url: pageURL)) } }
                    ReadingSheetCloseButton { dismiss() }
                }
            }
        }
        .task(id: retry) {
            failed = false
            message = nil
            let report = await NetworkBookService().loadContent(book: book, chapter: chapter, source: source,
                                                                nextChapterURL: nextChapterURL, readBrowserPage: { url in
                try await readPage(url)
            })
            guard !Task.isCancelled else { return }
            do {
                try await accept(report)
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                message = error.localizedDescription
                failed = true
            }
        }
    }

    @MainActor private func readPage(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        if let previous = pageURL, previous != url { browser.webView.load(URLRequest(url: url)) }
        pageURL = url
        message = nil
        let pages = AsyncStream<String> { submission = $0 }
        defer { submission = nil }
        for await html in pages { return html }
        throw CancellationError()
    }
}
