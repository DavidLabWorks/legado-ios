import Combine
import SwiftSoup
import SwiftUI
@preconcurrency import WebKit
import UIKit

enum RSSWebAction {
    case searchBook(key: String, scope: String?)
    case addBook(String)
    case open(name: String, url: String?, title: String?, origin: String?)
    case download(url: String, fileName: String)
}

struct RSSNextArticle {
    let title: String
    let open: () -> Void
}

struct RSSWebReaderView: UIViewRepresentable {
    let mode: RSSReadingMode
    let source: RssSource
    @Binding var pageTitle: String?
    var imageBaseURL: String?
    var onShowPhoto: ((RSSGallerySelection) -> Void)?
    var onPlayVideo: ((URL) -> Void)?
    var nextArticle: RSSNextArticle?
    let onTextChange: (String) -> Void
    let onAction: (RSSWebAction) -> Void

    init(mode: RSSReadingMode, source: RssSource, pageTitle: Binding<String?> = .constant(nil), onTextChange: @escaping (String) -> Void = { _ in }, imageBaseURL: String? = nil, onShowPhoto: ((RSSGallerySelection) -> Void)? = nil, onPlayVideo: ((URL) -> Void)? = nil, nextArticle: RSSNextArticle? = nil, onAction: @escaping (RSSWebAction) -> Void = { _ in }) {
        self.mode = mode
        self.source = source
        self._pageTitle = pageTitle
        self.imageBaseURL = imageBaseURL
        self.onShowPhoto = onShowPhoto
        self.onPlayVideo = onPlayVideo
        self.nextArticle = nextArticle
        self.onTextChange = onTextChange
        self.onAction = onAction
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(source: source, onTextChange: onTextChange, onAction: onAction)
        coordinator.onShowPhoto = onShowPhoto
        coordinator.onPlayVideo = onPlayVideo
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = source.enableJs
        let controller = configuration.userContentController
        if onShowPhoto != nil {
            controller.add(context.coordinator, contentWorld: .defaultClient, name: "articleImages")
            let base = imageBaseURL.flatMap { URL(string: $0, relativeTo: URL(string: source.sourceUrl))?.absoluteURL.absoluteString }
            controller.addUserScript(.init(source: context.coordinator.imageScript(baseURL: base ?? source.sourceUrl, isArticle: imageBaseURL != nil),
                                           injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        controller.add(context.coordinator, name: "legado")
        controller.addUserScript(.init(source: context.coordinator.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let preload = source.preloadJs?.trimmedNonEmpty {
            controller.addUserScript(.init(source: preload, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let inject = source.injectJs?.trimmedNonEmpty {
            controller.addUserScript(.init(source: inject, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        context.coordinator.titleObservation = webView.publisher(for: \.title, options: [.new])
            .sink { [title = $pageTitle] in title.wrappedValue = $0?.trimmedNonEmpty }
        context.coordinator.installRulesAndLoad(mode: mode, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(source: source)
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onShowPhoto = onShowPhoto
        context.coordinator.onPlayVideo = onPlayVideo
        context.coordinator.onAction = onAction
        context.coordinator.updateNextArticle(nextArticle, in: webView)
        context.coordinator.loadIfChanged(mode: mode, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.onShowPhoto = nil
        coordinator.onPlayVideo = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "articleImages", contentWorld: .defaultClient)
        coordinator.titleObservation = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "legado")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        private let pullThreshold: CGFloat = 120
        private var nextArticle: RSSNextArticle?
        private var pullHint: UIButton?
        private var armed = false
        private var originalBounce = false

        func updateNextArticle(_ next: RSSNextArticle?, in webView: WKWebView) {
            let titleChanged = nextArticle?.title != next?.title
            nextArticle = next
            let scroll = webView.scrollView
            guard next != nil else {
                if let pullHint {
                    pullHint.removeFromSuperview()
                    self.pullHint = nil
                    scroll.delegate = nil
                    scroll.alwaysBounceVertical = originalBounce
                    armed = false
                }
                return
            }
            if pullHint == nil {
                let hint = UIButton(configuration: .tinted())
                hint.isUserInteractionEnabled = false
                hint.isAccessibilityElement = false
                hint.alpha = 0
                scroll.addSubview(hint)
                pullHint = hint
                originalBounce = scroll.alwaysBounceVertical
                scroll.alwaysBounceVertical = true
                scroll.delegate = self
            }
            if titleChanged { configurePullHint() }
        }

        private func configurePullHint() {
            guard let pullHint else { return }
            var config = UIButton.Configuration.tinted()
            config.cornerStyle = .capsule
            config.buttonSize = .small
            config.image = UIImage(systemName: armed ? "arrow.up.circle.fill" : "arrow.up")
            config.imagePadding = 8
            config.title = armed ? "松开打开下一篇" : "继续上拉打开下一篇"
            config.subtitle = nextArticle?.title
            config.subtitleLineBreakMode = .byTruncatingTail
            pullHint.configuration = config
        }

        private func bottomOffset(_ scroll: UIScrollView) -> CGFloat {
            max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        }

        func scrollViewDidScroll(_ scroll: UIScrollView) {
            guard let hint = pullHint else { return }
            let distance = max(0, scroll.contentOffset.y - bottomOffset(scroll))
            let dragging = scroll.isDragging && !scroll.isZooming
            if dragging || distance == 0 {
                let ready = dragging && distance >= pullThreshold
                if ready != armed {
                    armed = ready
                    configurePullHint()
                    if ready { UISelectionFeedbackGenerator().selectionChanged() }
                }
            }
            guard distance > 0, dragging || hint.alpha > 0 else { hint.alpha = 0; return }
            let size = hint.intrinsicContentSize
            hint.bounds.size = CGSize(width: min(size.width, max(0, scroll.bounds.width - 24)), height: size.height)
            hint.center = CGPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - scroll.adjustedContentInset.bottom - distance / 2)
            hint.alpha = min(1, distance / pullThreshold)
        }

        func scrollViewWillEndDragging(_ scroll: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            let state = scroll.panGestureRecognizer.state
            guard armed, state != .cancelled, state != .failed, !scroll.isZooming,
                  scroll.contentOffset.y - bottomOffset(scroll) >= pullThreshold else { return }
            armed = false
            nextArticle?.open()
        }

        var onShowPhoto: ((RSSGallerySelection) -> Void)?
        var onPlayVideo: ((URL) -> Void)?
        private var videoURLs: [URL] = []
        var titleObservation: AnyCancellable?
        private var source: RssSource
        var onTextChange: (String) -> Void
        var onAction: (RSSWebAction) -> Void
        private var loadedMode: RSSReadingMode?
        private var rulesInstalled = false
        private let htmlProcessor = RSSHTMLProcessor()
        private var analyzeContent: JSONValue = .string("")
        private var analyzeBaseURL = ""
        private var analyzeRedirectURL: String?
        private var analyzeVariables: [String: String] = [:]

        init(source: RssSource, onTextChange: @escaping (String) -> Void, onAction: @escaping (RSSWebAction) -> Void) { self.source = source; self.onTextChange = onTextChange; self.onAction = onAction }
        func update(source: RssSource) { self.source = source }

        func imageScript(baseURL: String, isArticle: Bool) -> String {
            """
            (() => {
              let article = \(isArticle);
              let scheduled = false;
              const excluded = 'nav,aside,footer,header,button,[role="button"],[hidden],[aria-hidden="true"]';
              function articleRoot() {
                return document.querySelector('.article-content, .entry-content, [itemprop="articleBody"]')
                    || document.querySelector('article') || document.querySelector('main') || document.body;
              }
              function prepareColumn(root) {
                if (root.classList.contains('legado-photo-column')) return;
                root.classList.add('legado-photo-column');
                if (!document.querySelector('meta[name="viewport" i]')) {
                  const viewport = document.createElement('meta');
                  viewport.name = 'viewport';
                  viewport.content = 'width=device-width, initial-scale=1';
                  document.head.append(viewport);
                }
                const style = document.createElement('style');
                style.textContent = `
                  .legado-photo-column { box-sizing:border-box; max-width:46rem; margin-inline:auto; padding-inline:12px; }
                  .legado-article-photo { display:block; box-sizing:border-box; float:none; width:100% !important;
                    max-width:100% !important; height:auto !important; margin:12px auto; }
                  .legado-photo-link { display:block; }
                  figure.legado-photo-figure { margin-inline:0; }
                  .legado-article-photo + br, .legado-photo-link + br { display:none; }
                `;
                document.head.append(style);
              }
              function collect() {
                scheduled = false;
                const root = articleRoot();
                if (!article || !root) return;
                for (const img of root.querySelectorAll('img')) {
                  if (!img.closest(excluded) && Math.min(img.naturalWidth, img.naturalHeight) >= 64 &&
                      Math.max(img.naturalWidth, img.naturalHeight) >= 160) {
                    prepareColumn(root);
                    img.classList.add('legado-article-photo');
                    const link = img.closest('a');
                    if (link && link.childElementCount === 1 && !link.textContent.trim()) link.classList.add('legado-photo-link');
                    img.closest('figure')?.classList.add('legado-photo-figure');
                  }
                }
              }
              function photoURL(raw) {
                if (!raw) return null;
                try {
                  const base = /^https?:/i.test(document.baseURI) ? document.baseURI : \(Self.jsString(baseURL));
                  const url = new URL(raw, base);
                  if (['http:', 'https:'].includes(url.protocol) || /^data:image[/]/i.test(url.href)) return url.href;
                } catch (_) {}
                return null;
              }
              function openPhoto(target) {
                const urls = [], nodes = [];
                const requestedURL = typeof target === 'string' ? photoURL(target) : null;
                let index = -1;
                for (const img of articleRoot()?.querySelectorAll('img') || []) {
                  if (img.closest(excluded) || !img.getClientRects().length) continue;
                  const link = img.closest('a[href]');
                  const original = link?.hasAttribute('data-fancybox') ? link.getAttribute('href') : null;
                  const url = photoURL(img.dataset.original || (original && !original.startsWith('#') && original)
                      || img.dataset.src || img.currentSrc || img.getAttribute('src'));
                  if (!url) continue;
                  if (img === target || (requestedURL && index < 0 && (requestedURL === url || requestedURL === img.src))) index = urls.length;
                  urls.push(url);
                  nodes.push(img);
                }
                const canLocate = index >= 0;
                if (!canLocate) {
                  if (!requestedURL) return false;
                  index = 0;
                  urls.splice(0, urls.length, requestedURL);
                }
                window.legadoLocatePhoto = page => {
                  if (canLocate && nodes[page]?.isConnected) nodes[page].scrollIntoView({block:'center', inline:'nearest', behavior:'instant'});
                };
                window.webkit.messageHandlers.articleImages.postMessage({urls, index, canLocate});
                return true;
              }
              window.legadoOpenPhoto = openPhoto;
              function handlePhoto(event) {
                const img = event.target.closest?.('img');
                if (!img || img.closest(excluded)) return;
                const link = img.closest('a[href]');
                if (event.type === 'click' && !article && link && !link.hasAttribute('data-fancybox') &&
                    link.href !== img.src && !/[.](png|jpe?g|gif|webp|avif|heic)([?#]|$)/i.test(link.href)) return;
                if (!openPhoto(img)) return;
                event.preventDefault();
                event.stopImmediatePropagation();
              }
              window.addEventListener('click', handlePhoto, true);
              window.addEventListener('contextmenu', handlePhoto, true);
              function schedule() {
                if (!scheduled) { scheduled = true; requestAnimationFrame(collect); }
              }
              if (!article) return;
              collect();
              new MutationObserver(schedule).observe(document.documentElement, {subtree:true, childList:true,
                attributes:true, attributeFilter:['src','srcset','data-original','data-src','hidden','aria-hidden']});
              document.addEventListener('load', event => { if (event.target.tagName === 'IMG') schedule(); }, true);
            })();
            """
        }

        var bridgeScript: String {
            let sourceJSON = (try? JSONEncoder().encode(source)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return """
            (() => {
              const native = (action, payload) => window.webkit.messageHandlers.legado.postMessage(Object.assign({action}, payload || {}));
              const get = key => window.prompt('__legado_get__', String(key)) || '';
              const put = (key, value) => { value = String(value ?? ''); native('put', {key:String(key), value}); return value; };
              const ruleCall = payload => {
                const result = window.prompt('__legado_rule__', JSON.stringify(payload));
                if (result == null || result === '') return null;
                try { return JSON.parse(result); } catch (_) { return result; }
              };
              const analyzer = {
                setContent(content, baseUrl) { if (content == null) throw new Error('内容不可空（Content cannot be null）'); ruleCall({op:'setContent', content, baseUrl:baseUrl == null ? null : String(baseUrl)}); return analyzer; },
                setBaseUrl(baseUrl) { ruleCall({op:'setBaseUrl', baseUrl:baseUrl == null ? null : String(baseUrl)}); return analyzer; },
                setRedirectUrl(url) { return ruleCall({op:'setRedirectUrl', url:String(url)}); },
                getStringList(rule, content, isUrl) { return ruleCall({op:'getStringList', rule:rule == null ? null : String(rule), content:content === undefined ? null : content, hasContent:content !== undefined, isUrl:!!isUrl}); },
                getString(rule, content, isUrl) { return ruleCall({op:'getString', rule:rule == null ? null : String(rule), content:content === undefined ? null : content, hasContent:content !== undefined && typeof content !== 'boolean', unescape:typeof content === 'boolean' ? content : false, isUrl:!!isUrl}); },
                getElement(rule) { return ruleCall({op:'getElement', rule:String(rule)}); },
                getElements(rule) { return ruleCall({op:'getElements', rule:String(rule)}); }
              };
              window.java = window.java || {};
              java.get = get; java.put = put;
              java.getSource = () => window.source; java.getTag = () => \(Self.jsString(source.sourceName));
              java.showPhoto = src => native('showPhoto', {url:String(src)});
              java.addBook = url => native('addBook', {url:String(url)});
              java.searchBook = (key, scope) => native('searchBook', {key:String(key), scope:scope == null ? null : String(scope)});
              java.open = (name, url, title, origin) => native('open', {name:String(name), url:url == null ? null : String(url), title:title == null ? null : String(title), origin:origin == null ? null : String(origin)});
              java.setContent = analyzer.setContent; java.setBaseUrl = analyzer.setBaseUrl; java.setRedirectUrl = analyzer.setRedirectUrl;
              java.getString = analyzer.getString; java.getStringList = analyzer.getStringList; java.getElement = analyzer.getElement; java.getElements = analyzer.getElements;
              window.source = Object.assign(\(sourceJSON), {
                getKey: () => \(Self.jsString(source.sourceUrl)),
                getTag: () => \(Self.jsString(source.sourceName)),
                get, put
              });
              document.addEventListener('contextmenu', event => {
                const image = event.target && event.target.closest ? event.target.closest('img') : null;
                if (!image || !image.src) return;
                event.preventDefault();
                native('showPhoto', {url:String(image.currentSrc || image.src)});
              }, true);
            })();
            """
        }

        func installRulesAndLoad(mode: RSSReadingMode, in webView: WKWebView) {
            let policy = RSSResourcePolicy(blacklist: source.contentBlacklist, whitelist: source.contentWhitelist)
            guard let json = policy.contentBlockerJSON() else {
                rulesInstalled = true; loadIfChanged(mode: mode, in: webView); return
            }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "rss-\(source.sourceUrl.hashValue)", encodedContentRuleList: json) { [weak self, weak webView] list, _ in
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    if let list { webView.configuration.userContentController.add(list) }
                    self.rulesInstalled = true
                    self.loadIfChanged(mode: mode, in: webView)
                }
            }
        }

        func loadIfChanged(mode: RSSReadingMode, in webView: WKWebView) {
            guard rulesInstalled else { return }
            guard loadedMode != mode else { return }
            loadedMode = mode
            videoURLs.removeAll()
            switch mode {
            case .html(let content, let baseURL):
                let html = articleVideoLinks(in: content, baseURL: baseURL ?? source.sourceUrl)
                webView.loadHTMLString(htmlProcessor.contentHTML(html, style: source.style), baseURL: baseURL.flatMap(URL.init(string:)))
            case .startHTML(let content, let baseURL):
                webView.loadHTMLString(htmlProcessor.startHTML(content, source: source), baseURL: baseURL.flatMap(URL.init(string:)))
            case .web(let value): load(value, in: webView)
            case .image(let value):
                let escaped = Self.htmlEscape(value)
                webView.loadHTMLString(htmlProcessor.contentHTML("<body><img src=\"\(escaped)\"></body>", style: source.style), baseURL: URL(string: value))
            case .video(let value):
                let escaped = Self.htmlEscape(value)
                let html = articleVideoLinks(in: "<video src=\"\(escaped)\"></video>", baseURL: source.sourceUrl)
                webView.loadHTMLString(htmlProcessor.contentHTML(html, style: source.style), baseURL: nil)
                if let url = videoURLs.first { DispatchQueue.main.async { self.onPlayVideo?(url) } }
            }
        }

        private func articleVideoLinks(in html: String, baseURL: String) -> String {
            guard html.range(of: "<video", options: .caseInsensitive) != nil else { return html }
            do {
                let document = try SwiftSoup.parse(html, baseURL)
                let policy = RSSResourcePolicy(blacklist: source.contentBlacklist, whitelist: source.contentWhitelist)
                for video in try document.select("video") {
                    let candidates = [video] + (try video.select("source[src]").array())
                    let urls = try candidates.compactMap { element -> URL? in
                        let address = try element.attr("abs:src")
                        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
                              ["http", "https"].contains(scheme), url.host != nil, policy.allows(address) else { return nil }
                        return url
                    }
                    if let url = urls.first {
                        let index = videoURLs.count
                        videoURLs.append(url)
                        try video.before("<a href=\"legado-video://clip/\(index)\" style=\"display:inline-block;padding:0.8em 1.2em\">▶ 播放视频 \(index + 1)</a>")
                    } else {
                        try video.before("<span>视频地址不可用</span>")
                    }
                    try video.remove()
                }
                return try document.outerHtml()
            } catch { return html }
        }

        private func load(_ value: String, in webView: WKWebView) {
            guard let url = URL(string: value) else { return }
            var request = URLRequest(url: url, cachePolicy: source.cacheFirst ? .returnCacheDataElseLoad : .useProtocolCachePolicy, timeoutInterval: 180)
            if let headers = try? BookSourceHeaderResolver().resolve(source.bookSourceAdapter) {
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                webView.customUserAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
            }
            if webView.customUserAgent == nil { webView.customUserAgent = ApplicationSettingsStore.shared.settings.effectiveUserAgent }
            request = ApplicationSettingsStore.shared.settings.configure(request)
            let cookie = LegadoCookieStore.shared.cookieHeader(for: value)
            if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            webView.load(request)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "articleImages" {
                guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                      let urls = body["urls"] as? [String], let index = body["index"] as? Int,
                      urls.indices.contains(index), let webView = message.webView else { return }
                let policy = RSSResourcePolicy(blacklist: source.contentBlacklist, whitelist: source.contentWhitelist)
                let allowed = urls.indices.filter { policy.allows(urls[$0]) }
                guard let selected = allowed.firstIndex(of: index) else { return }
                let locate: (Int) -> Void = { [weak webView] page in
                    guard allowed.indices.contains(page) else { return }
                    webView?.evaluateJavaScript("window.legadoLocatePhoto?.(\(allowed[page]))",
                                                in: nil, in: .defaultClient, completionHandler: nil)
                }
                onShowPhoto?(.init(urls: allowed.map { urls[$0] }, index: selected,
                                   onLocate: body["canLocate"] as? Bool == true ? locate : nil))
                return
            }
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "put":
                if let key = body["key"] as? String { BookSourceRuntimeStore.shared.put(sourceID: source.sourceUrl, key: key, value: String(describing: body["value"] ?? "")) }
            case "showPhoto":
                if let raw = body["url"] as? String {
                    message.webView?.callAsyncJavaScript("window.legadoOpenPhoto?.(url)", arguments: ["url": raw],
                                                         in: nil, in: .defaultClient, completionHandler: nil)
                }
            case "searchBook":
                if let key = body["key"] as? String { DispatchQueue.main.async { self.onAction(.searchBook(key: key, scope: body["scope"] as? String)) } }
            case "addBook":
                if let raw = body["url"] as? String { DispatchQueue.main.async { self.onAction(.addBook(raw)) } }
            case "open":
                let name = body["name"] as? String ?? ""
                DispatchQueue.main.async { self.onAction(.open(name: name, url: body["url"] as? String, title: body["title"] as? String, origin: body["origin"] as? String)) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            if prompt == "__legado_get__" {
                completionHandler(BookSourceRuntimeStore.shared.get(sourceID: source.sourceUrl, key: defaultText ?? ""))
            } else if prompt == "__legado_rule__" {
                handleRulePrompt(defaultText, completionHandler: completionHandler)
            } else { completionHandler(defaultText) }
        }

        private func handleRulePrompt(_ payload: String?, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            guard let payload, let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let operation = object["op"] as? String else { completionHandler("null"); return }
            switch operation {
            case "setContent":
                analyzeContent = JSONValue.bridge(object["content"])
                if let base = object["baseUrl"] as? String, !base.isEmpty { analyzeBaseURL = base }
                completionHandler("true")
            case "setBaseUrl":
                if let base = object["baseUrl"] as? String, !base.isEmpty { analyzeBaseURL = base }
                completionHandler("true")
            case "setRedirectUrl":
                let value = object["url"] as? String ?? ""
                if !value.lowercased().hasPrefix("data:"), URL(string: value) != nil { analyzeRedirectURL = value }
                completionHandler(Self.jsonString(analyzeRedirectURL))
            default:
                let rule = object["rule"] as? String ?? ""
                guard !rule.isEmpty else { completionHandler(operation == "getStringList" || operation == "getElements" ? "null" : "\"\""); return }
                let input = (object["hasContent"] as? Bool) == true ? JSONValue.bridge(object["content"]) : analyzeContent
                let baseURL = analyzeRedirectURL ?? analyzeBaseURL
                let context = RuleExecutionContext(variables: analyzeVariables, baseURL: baseURL, source: source.bookSourceAdapter)
                Task {
                    let evaluation: RuleEvaluation
                    switch input {
                    case .string(let text):
                        evaluation = await RuleEngine().evaluate(rule, inText: text, baseURL: baseURL, listMode: operation == "getStringList" || operation == "getElements", context: context)
                    default:
                        evaluation = await RuleEngine().evaluate(rule, in: input, context: context)
                    }
                    self.analyzeVariables = evaluation.variables
                    let isURL = object["isUrl"] as? Bool == true
                    let values = evaluation.values.map { value -> JSONValue in
                        guard isURL else { return value }
                        let raw = value.stringValue
                        return .string(URL(string: raw, relativeTo: URL(string: baseURL))?.absoluteURL.absoluteString ?? raw)
                    }
                    let response: Any
                    switch operation {
                    case "getStringList": response = values.map(\.stringValue)
                    case "getElement": response = values.first?.foundationObject ?? NSNull()
                    case "getElements": response = values.map(\.foundationObject)
                    default:
                        var value = values.map(\.stringValue).joined(separator: "\n")
                        if object["unescape"] as? Bool == true { value = Self.unescapeHTML(value) }
                        response = value
                    }
                    completionHandler(Self.json(response))
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "legado-video" {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.isMainFrame,
                   url.host == "clip", let index = Int(url.lastPathComponent), videoURLs.indices.contains(index) {
                    onPlayVideo?(videoURLs[index])
                }
                return
            }
            if !["http", "https", "file", "data", "about"].contains(scheme) {
                UIApplication.shared.open(url); decisionHandler(.cancel); return
            }
            if navigationAction.navigationType == .linkActivated, shouldOverride(url.absoluteString) {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
            guard let response = navigationResponse.response as? HTTPURLResponse, let url = response.url else { decisionHandler(.allow); return }
            let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
                let name = response.suggestedFilename ?? url.lastPathComponent.nilIfBlank ?? "download"
                DispatchQueue.main.async { self.onAction(.download(url: url.absoluteString, fileName: name)) }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
                guard let text = value as? String else { return }
                DispatchQueue.main.async { self?.onTextChange(text) }
            }
        }

        private func shouldOverride(_ url: String) -> Bool {
            guard let script = source.shouldOverrideUrlLoading?.trimmedNonEmpty else { return false }
            let quoted = Self.jsString(url)
            let expression = "(function(url){return (\(script));})(\(quoted))"
            let body = "(function(url){\(script)})(\(quoted))"
            let evaluator = JavaScriptRuleEvaluator()
            let context = RuleExecutionContext(variables: ["url": url], baseURL: url, source: source.bookSourceAdapter)
            let result = (try? evaluator.evaluate(script: expression, result: .string(url), executionContext: context))
                ?? (try? evaluator.evaluate(script: body, result: .string(url), executionContext: context))
            let value = result?.value.stringValue.lowercased() ?? ""
            return ["true", "1", "yes"].contains(value)
        }

        private static func jsString(_ value: String) -> String {
            let data = try? JSONEncoder().encode(value)
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        private static func htmlEscape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        }
        private static func json(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }
        private static func jsonString(_ value: String?) -> String { value.map { json($0) } ?? "null" }
        private static func unescapeHTML(_ value: String) -> String {
            guard let data = "<span>\(value)</span>".data(using: .utf8), let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return value }
            return attributed.string
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    var nilIfBlank: String? { trimmedNonEmpty }
}
