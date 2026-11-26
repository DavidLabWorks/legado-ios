import Foundation
import SwiftSoup

public enum RSSReadingMode: Equatable, Sendable {
    case html(content: String, baseURL: String?)
    case startHTML(content: String, baseURL: String?)
    case web(url: String)
    case image(url: String)
    case video(url: String)
}

public struct RSSReadingPolicy: Sendable {
    public init() {}

    public func mode(article: RssArticle, source: RssSource, resolvedContent: String? = nil) -> RSSReadingMode {
        if article.type == 1 || article.type == 2 {
            let raw = resolvedContent?.trimmed.nilIfEmpty ?? article.link
            let articleURL = absoluteURL(article.link, base: article.origin)
            let url = absoluteURL(raw, base: articleURL)
            return article.type == 1 ? .image(url: url) : .video(url: url)
        }
        if let description = article.description?.trimmed.nilIfEmpty {
            return .html(content: description, baseURL: source.loadWithBaseUrl ? absoluteURL(article.link, base: article.origin) : nil)
        }
        if source.ruleContent?.trimmed.nilIfEmpty != nil, let content = resolvedContent {
            return .html(content: content, baseURL: source.loadWithBaseUrl ? absoluteURL(article.link, base: article.origin) : nil)
        }
        return .web(url: absoluteURL(article.link, base: article.origin))
    }

    private func absoluteURL(_ value: String, base: String) -> String {
        URL(string: value, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? value
    }
}

public struct RSSHTMLProcessor: Sendable {
    public static let defaultStyle = "img{max-width:100% !important; width:auto; height:auto;}video{object-fit:fill; max-width:100% !important; width:auto; height:auto;}body{word-wrap:break-word; height:auto;max-width: 100%; width:auto;}"
    // Keep source CSS later in the cascade so intentional source styling wins.
    public static let appearanceStyle = """
    :root{color-scheme:light dark;}
    body{background-color:#fcfcfc;color:#171717;}
    @media(prefers-color-scheme:dark){body{background-color:#111113;color:#f2f2f2;}a{color:#9ecbff;}}
    """
    public init() {}

    public func contentHTML(_ content: String, style: String?) -> String {
        injectStyle(into: content, style: style?.trimmed.nilIfEmpty ?? Self.defaultStyle)
    }

    /// Extracted articles often contain only a few paragraphs without a mobile viewport.
    public func articleHTML(_ content: String, style: String?) -> String {
        let html = contentHTML(content, style: style)
        do {
            let document = try SwiftSoup.parse(html)
            guard let head = document.head() else { return html }
            if try document.select("meta[name=viewport]").isEmpty() {
                try head.prependElement("meta").attr("name", "viewport").attr("content", "width=device-width, initial-scale=1")
            }
            if style?.trimmed.nilIfEmpty == nil {
                // Put reading defaults first so the article's own CSS can override them.
                try head.prepend("""
                <style>
                :where(html){max-width:44rem;margin-inline:auto;}
                :where(body){box-sizing:border-box;margin:0;padding:1.25rem clamp(1rem,5vw,2rem) 2rem;
                    font:-apple-system-body;line-height:1.75;overflow-wrap:break-word;}
                :where(p){margin:0 0 1em;}
                :where(h1,h2,h3){line-height:1.35;margin:1.3em 0 .55em;}
                :where(blockquote){margin:1em 0;padding-inline-start:1em;border-inline-start:.18em solid #919198;}
                :where(pre){max-width:100%;overflow-x:auto;}
                </style>
                """)
            }
            document.outputSettings().prettyPrint(pretty: false)
            return try document.outerHtml()
        } catch {
            return html
        }
    }

    public func startHTML(_ content: String, source: RssSource) -> String {
        var html: String
        if let script = source.startJs?.trimmed.nilIfEmpty {
            if let range = content.range(of: "</body>") {
                html = String(content[..<range.lowerBound]) + "<script>\(script)</script>" + String(content[range.lowerBound...])
            } else {
                html = "<body>\(content)<script>\(script)</script></body>"
            }
        } else { html = content }
        return contentHTML(html, style: source.startStyle?.trimmed.nilIfEmpty ?? source.style)
    }

    private func injectStyle(into content: String, style: String) -> String {
        let tag = "<style>\(Self.appearanceStyle)</style><style>\(style)</style>"
        if let range = content.range(of: "</style>") {
            return String(content[..<range.upperBound]) + tag + String(content[range.upperBound...])
        }
        if let range = content.range(of: "</head>") {
            return String(content[..<range.lowerBound]) + tag + String(content[range.lowerBound...])
        }
        return tag + content
    }
}

public struct RSSStartPageResolver: Sendable {
    public init() {}
    public func resolve(_ source: RssSource) throws -> RSSReadingMode? {
        guard let raw = source.startHtml?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let html: String
        if raw.hasPrefix("@js:") {
            let result = try JavaScriptRuleEvaluator().evaluate(script: String(raw.dropFirst(4)), result: .string(""), executionContext: .init(baseURL: source.sourceUrl, source: source.bookSourceAdapter))
            html = result.value.stringValue
        } else if raw.hasPrefix("<js>"), let end = raw.range(of: "</js>", options: .backwards) {
            let script = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound])
            let result = try JavaScriptRuleEvaluator().evaluate(script: script, result: .string(""), executionContext: .init(baseURL: source.sourceUrl, source: source.bookSourceAdapter))
            html = result.value.stringValue
        } else { html = raw }
        return .startHTML(content: html, baseURL: source.loadWithBaseUrl ? source.sourceUrl : nil)
    }
}

public struct RSSResourcePolicy: Sendable {
    private let blacklist: [String]
    private let whitelist: [String]
    public init(blacklist: String?, whitelist: String?) {
        self.blacklist = Self.rules(blacklist)
        self.whitelist = Self.rules(whitelist)
    }
    public func allows(_ url: String) -> Bool {
        if !blacklist.isEmpty { return !blacklist.contains { matches(url, rule: $0) } }
        if !whitelist.isEmpty { return whitelist.contains { matches(url, rule: $0) } }
        return true
    }
    public func contentBlockerJSON() -> String? {
        var rules: [[String: Any]] = []
        if !blacklist.isEmpty {
            for value in blacklist {
                rules.append(["trigger": ["url-filter": filter(for: value)], "action": ["type": "block"]])
            }
        } else if !whitelist.isEmpty {
            rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "block"]])
            for value in whitelist {
                rules.append(["trigger": ["url-filter": filter(for: value)], "action": ["type": "ignore-previous-rules"]])
            }
        }
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    private func matches(_ value: String, rule: String) -> Bool {
        if value.hasPrefix(rule) { return true }
        guard let expression = try? NSRegularExpression(pattern: rule) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return false }
        return match.range == range
    }
    private func filter(for rule: String) -> String {
        let literalPrefix = "^" + NSRegularExpression.escapedPattern(for: rule)
        return "(?:\(literalPrefix))|(?:^(?:\(rule))$)"
    }
    private static func rules(_ value: String?) -> [String] {
        value?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
