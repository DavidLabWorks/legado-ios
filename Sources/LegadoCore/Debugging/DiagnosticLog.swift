import Foundation

public struct DiagnosticLogEntry: Codable, Identifiable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable { case info, warning, error }
    public var id: UUID
    public var date: Date
    public var level: Level
    public var category: String
    public var message: String
}

public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()
    private let lock = NSLock()
    private let fileURL: URL
    private let maximumEntries: Int
    private let isEnabled: @Sendable () -> Bool
    private var entries: [DiagnosticLogEntry]

    public init(directory: URL? = nil, maximumEntries: Int = 500,
                isEnabled: @escaping @Sendable () -> Bool = { ApplicationSettingsStore.shared.settings.recordLog }) {
        fileURL = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Logs", isDirectory: true)).appendingPathComponent("diagnostics.json")
        self.maximumEntries = max(1, maximumEntries)
        self.isEnabled = isEnabled
        entries = (try? JSONDecoder().decode([DiagnosticLogEntry].self, from: Data(contentsOf: fileURL))) ?? []
        entries = Array(entries.suffix(self.maximumEntries))
    }

    public func record(_ level: DiagnosticLogEntry.Level = .info, category: String, message: String) {
        guard isEnabled() else { return }
        lock.lock()
        defer { lock.unlock() }
        entries.append(.init(id: UUID(), date: Date(), level: level,
                             category: String(category.prefix(80)), message: Self.redact(String(message.prefix(2048)))))
        entries = Array(entries.suffix(maximumEntries))
        try? persist()
    }

    public func snapshot() -> [DiagnosticLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        entries.removeAll()
    }

    public func export() -> String {
        let formatter = ISO8601DateFormatter()
        return snapshot().reversed().map {
            "\(formatter.string(from: $0.date)) [\($0.level.rawValue.uppercased())] [\($0.category)] \($0.message)"
        }.joined(separator: "\n")
    }

    public func network(_ request: URLRequest, status: Int? = nil, error: Error? = nil, startedAt: Date) {
        // URL query strings, credentials and fragments can contain access tokens.
        let url = request.url.map(Self.safeURL) ?? "未知地址"
        let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
        let result: String
        if let error, case HTTPClientError.statusResponse(let response) = error {
            result = "HTTP \(response.statusCode)"
        } else {
            result = error.map { "失败 (\(($0 as NSError).domain):\(($0 as NSError).code))" } ?? "HTTP \(status ?? 0)"
        }
        record(error != nil || (status ?? 0) >= 400 ? .error : .info, category: "网络",
               message: "\(request.httpMethod ?? "GET") \(url) · \(result) · \(duration) ms")
    }

    func forbiddenRequest(_ prepared: PreparedRequest, request: URLRequest, response: HTTPResponse,
                          source: BookSource, stage: DifferentialStage) {
        let category: String
        switch stage {
        case .search: category = "搜索请求"
        case .content: category = "章节请求"
        default: return
        }
        guard isEnabled() else { return }
        let page = Self.safeURL(prepared.url)
        var details = [prepared.useWebView ? "书源 WebView" : "书源 HTTP 请求",
                       "\(prepared.method.rawValue) \(page)", "HTTP \(response.statusCode)"]
        let finalPage = Self.safeURL(response.finalURL)
        if finalPage != page { details.append("响应地址 \(finalPage)") }
        details.append(source.enabledCookieJar == true ? "书源 Cookie 管理已开启" : "书源 Cookie 管理已关闭")
        if !prepared.useWebView {
            let hasCookie = request.value(forHTTPHeaderField: "Cookie")?.isEmpty == false
            details.append(hasCookie ? "初始请求含 Cookie" : "初始请求无 Cookie")
            let settings = ApplicationSettingsStore.shared.settings
            if prepared.proxy != nil || !settings.proxy.isEmpty { details.append("已配置应用或书源代理") }
            else if let host = prepared.url.host?.lowercased(),
                    let hosts = try? ApplicationSettings.parseHosts(settings.hosts), hosts[host] != nil {
                details.append("已配置当前域名的 Hosts")
            }
        }
        if response.headers.contains(where: { $0.key.lowercased() == "cf-mitigated" && $0.value.lowercased() == "challenge" }) {
            details.append("响应标记为网页验证")
        }
        // Record only a numeric error code, never a raw title or response body.
        let prefix = String(decoding: response.data.prefix(8192), as: UTF8.self)
        if let tag = prefix.range(of: #"(?i)<title\b[^>]*>\s*[45][0-9]{2}\b"#, options: .regularExpression) {
            details.append("错误页标题含 \(prefix[tag].suffix(3))")
        }
        record(.error, category: category, message: details.joined(separator: " · "))
    }

    public static func safeURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "[URL]" }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string ?? "[URL]"
    }

    public static func redact(_ text: String) -> String {
        var value = text
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s\"<>]+"#) {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value), let url = URL(string: String(value[range])) else { continue }
                value.replaceSubrange(range, with: safeURL(url))
            }
        }
        for pattern in [
            #"(?im)(authorization|cookie)["']?(\s*[=:]\s*)[^\r\n]+"#,
            #"(?i)["']?(password|passwd|token|secret)["']?(\s*[=:]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "$1$2[已隐藏]")
            }
        }
        return value
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
