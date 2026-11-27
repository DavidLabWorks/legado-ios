import Foundation

/// A portable document, independent of SQLite schema and iOS container paths.
public struct LibraryBackup: Codable, Sendable {
    public static let identifier = "com.epiboly.legado.backup"
    public let type: String
    public let version: Int
    public let createdAt: Date
    public var shelf: Shelf
    public var bookSources: [BookSource]
    public var websiteSources: [RssSource]
    public var websiteSourceGroups: [String]?
    public var bookmarks: [Bookmark]
    public var readingHistory: [ReadRecord]
    public var websiteFavorites: [RssStar]
    public var websiteHistory: [RssReadRecord]
    public var searchHistory: [SearchKeyword]
    public var sourceVariables: [LegadoCache]
    public var websiteVariables: [String: [String: String]]
    public var speechEngines: [HttpTTS]
    public var keyboardAssists: [KeyboardAssist]
    public var subscriptions: [RuleSub]
    public var tocRules: [TxtTocRule]?
    public var replaceRules: [ReplaceRule]
    public var settings: ApplicationSettings
    public var preferences: [String: JSONValue]
    public var fonts: [String: Data]
    public var background: Data?

    public var migration: Migration?

    public struct Migration: Codable, Sendable {
        public var pendingProgress: [String: BookProgress]
        public var servers: [Server]
    }

    public struct Shelf: Codable, Sendable {
        public var books: [Book]
        public var groups: [BookGroup]
        public var chapters: [String: [BookChapter]]
        // Keys are just filenames. A local book's URL is rebound during restore.
        public var localFiles: [String: Data]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Unrelated documents continue through the normal rule-import classifier.
    public static func recognize(_ data: Data) throws -> Self? {
        struct Header: Decodable {
            let type: String
            let version: Int?
            enum CodingKeys: CodingKey { case type, version }
            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                type = try fields.decode(String.self, forKey: .type)
                version = try? fields.decode(Int.self, forKey: .version)
            }
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.type == identifier else { return nil }
        guard header.version == 1 || header.version == 2 else {
            throw BackupError.invalid("无法识别备份版本，请用支持此版本的喵阅打开。")
        }
        decoder.dateDecodingStrategy = .iso8601
        let backup: Self
        do { backup = try decoder.decode(Self.self, from: data) }
        catch { throw BackupError.invalid("备份缺少必需的数据或格式损坏。") }
        try backup.validate()
        return backup
    }

    static func isPortableVariable(_ key: String) -> Bool {
        key.hasPrefix("sourceVariable_") || (key.hasPrefix("v_") && !key.hasSuffix("_loginInfo"))
    }

    static func validWebsiteVariablePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasSuffix(".json") else { return false }
        return [parts[0], parts[1].dropLast(5)].allSatisfy {
            $0.utf8.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    func validate() throws {
        guard type == Self.identifier, (version == 1 && migration == nil) || (version == 2 && migration != nil) else { throw BackupError.invalid("无法识别此备份。") }
        guard websiteVariables.keys.allSatisfy(Self.validWebsiteVariablePath),
              sourceVariables.allSatisfy({ Self.isPortableVariable($0.key) }) else {
            throw BackupError.invalid("备份中有无效的源变量。")
        }
        func checkIDs(_ ids: [String]) throws {
            guard !ids.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(ids).count == ids.count else { throw BackupError.invalid("备份中含有空白或重复的标识。") }
        }
        try checkIDs(shelf.books.map(\.bookUrl))
        try checkIDs(bookSources.map(\.bookSourceUrl))
        try checkIDs(websiteSources.map(\.sourceUrl))
        if let websiteSourceGroups {
            try checkIDs(websiteSourceGroups)
            guard websiteSourceGroups.allSatisfy({ BookSource.parseGroups($0) == [$0] }) else {
                throw BackupError.invalid("备份中的网站源分组名称无效。")
            }
        }
        guard Set(replaceRules.map(\.id)).count == replaceRules.count,
              Set(shelf.chapters.keys).isSubset(of: Set(shelf.books.map(\.bookUrl))) else {
            throw BackupError.invalid("备份中的规则或章节关联无效。")
        }
        let localNames = try shelf.books.filter { $0.origin == "local" }.map { book in
            guard let url = URL(string: book.bookUrl), LocalBookService.supports(url) else {
                throw BackupError.invalid("本地书籍路径无效。")
            }
            return url.lastPathComponent
        }
        try checkIDs(localNames)
        for (url, chapters) in shelf.chapters {
            guard chapters.allSatisfy({ $0.bookUrl == url }), Set(chapters.map(\.url)).count == chapters.count else {
                throw BackupError.invalid("章节目录与书籍不匹配或有重复章节。")
            }
        }
        for book in shelf.books where URL(string: book.bookUrl)?.isFileURL == true && book.origin != "local" {
            throw BackupError.invalid("本地书籍缺少原文件标记。")
        }
        guard Set(localNames).isSubset(of: Set(shelf.localFiles.keys)),
              shelf.localFiles.keys.allSatisfy({ ["txt", "epub"].contains(($0 as NSString).pathExtension.lowercased()) }) else { throw BackupError.invalid("本地书籍与原文件不匹配。") }
        for names in [Array(shelf.localFiles.keys), Array(fonts.keys)] {
            try checkIDs(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
            for name in names {
                guard !name.hasPrefix("."), name.utf8.count <= 255,
                      name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
                else { throw BackupError.invalid("备份内的文件名无效。") }
            }
        }
        for name in fonts.keys where !["ttf", "otf", "ttc", "otc"].contains((name as NSString).pathExtension.lowercased()) {
            throw BackupError.invalid("备份中的字体文件类型无效。")
        }
        _ = try settings.validated()
        try BackupPreferences.validate(preferences)
    }
}

enum BackupError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

enum BackupPreferences {
    // Only user preferences travel between devices. System defaults, session
    // state and cookies must never be set by a shared JSON document.
    static let strings: Set<String> = [
        "themeMode", "bookSourceSort", "bookshelfLayout", "defaultHomePage", "epubTheme",
        "paragraphIndent", "readerPreviousDayTheme", "readerTheme", "screenOrientation",
        "sourceTestKeyword", "systemTtsVoice", "textFont", "defaultEPUBReadingMode", "listeningEngine", "libreTTSVoice",
        "edgeOneVoice", "pptBoardVoice"
    ]
    static let flags: Set<String> = [
        "auto_refresh", "bookSourceSortDescending", "enableReadRecord", "epubPublisherStyles", "epubScroll",
        "ignoreAudioFocus", "mediaButtonPerNext", "onlyUpdateRead", "pauseReadAloudWhilePhoneCalls",
        "precisionSearch", "readAloudWakeLock", "readerFullJustify", "readerHideHomeIndicator",
        "readerHideStatusBar", "readerKeepScreenOn", "readerSimplifiedChinese",
        "readerUseBackgroundImage", "showFooterLine", "showHeaderLine", "recordWebsiteBrowsingHistory"
    ]
    static let numbers: Set<String> = [
        "autoReadSpeed", "bookshelfSort",
        "epubFontScale", "footerMode", "footerPaddingBottom", "footerPaddingLeft", "footerPaddingRight", "footerPaddingTop",
        "headerMode", "headerPaddingBottom", "headerPaddingLeft", "headerPaddingRight", "headerPaddingTop",
        "letterSpacing", "lineSpacingExtra", "paddingBottom", "paddingLeft", "paddingRight", "paddingTop",
        "paragraphSpacing", "readRecordSort", "readerBrightness", "textBold", "textSize",
        "tipFooterLeft", "tipFooterMiddle", "tipFooterRight", "tipHeaderLeft", "tipHeaderMiddle", "tipHeaderRight",
        "titleBottomSpacing", "titleMode", "titleSize", "titleTopSpacing", "ttsSpeechRate", "underlineMode", "pageAnim"
    ]
    static func read(_ defaults: UserDefaults) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for key in strings { values[key] = defaults.string(forKey: key).map(JSONValue.string) }
        for key in flags where defaults.object(forKey: key) != nil { values[key] = .bool(defaults.bool(forKey: key)) }
        for key in numbers where defaults.object(forKey: key) != nil { values[key] = .number(defaults.double(forKey: key)) }
        return values
    }
    // Older backups may contain retired numeric preferences. Accept them on
    // import without applying them or writing them into new backups.
    private static let legacyNumericKeys: Set<String> = [
        "ttsTimer",
        "clickActionTopLeft", "clickActionTopCenter", "clickActionTopRight", "clickActionMiddleLeft",
        "clickActionMiddleRight", "clickActionBottomLeft", "clickActionBottomCenter", "clickActionBottomRight"
    ]

    static func validate(_ values: [String: JSONValue]) throws {
        for (key, value) in values {
            switch value {
            case .string where strings.contains(key) || key == "appTtsEngine" || key == "offlineVoicePack.v1": continue
            case .bool where flags.contains(key) || key == "readerShowBrightness" || key == "readAloudByPage": continue
            case .number(let n) where (numbers.contains(key) || legacyNumericKeys.contains(key)) && n.isFinite && abs(n) <= 100000: continue
            default: throw BackupError.invalid("备份中的设置无效：" + key)
            }
        }
    }
    static func apply(_ values: [String: JSONValue], to defaults: UserDefaults) {
        for key in strings.union(flags).union(numbers) {
            switch values[key] {
            case .string(let v): defaults.set(v, forKey: key)
            case .bool(let v): defaults.set(v, forKey: key)
            case .number(let v): defaults.set(v, forKey: key)
            default: defaults.removeObject(forKey: key)
            }
        }
    }
}

// Each replacement is atomic. Retain the old contents until the SQLite
// transaction commits so a failed restore can undo its companion file writes.
struct BackupFileChanges {
    let root: URL
    private var originals: [(URL, Data?)] = []

    init(root: URL) { self.root = root.standardizedFileURL }

    func checked(_ relative: String) throws -> URL {
        let file = root.appendingPathComponent(relative)
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL.path
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == expected,
              file.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw BackupError.invalid("备份内含无效的文件路径。")
        }
        return file
    }

    func regularFiles(in relative: String, extensions: Set<String>) throws -> [URL] {
        let folder = try checked(relative)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            .filter { url in
                let attributes = try url.resourceValues(forKeys: keys)
                return attributes.isRegularFile == true && attributes.isSymbolicLink != true && extensions.contains(url.pathExtension.lowercased())
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func websiteVariables() throws -> [String: [String: String]] {
        let base = try checked("ruleData/rss")
        guard FileManager.default.fileExists(atPath: base.path) else { return [:] }
        var values: [String: [String: String]] = [:]
        for origin in try FileManager.default.contentsOfDirectory(atPath: base.path) {
            // Only the hash-named partitions belong to the RSS variable store.
            guard LibraryBackup.validWebsiteVariablePath(origin + "/" + origin + ".json") else { continue }
            let folder = try checked("ruleData/rss/" + origin)
            for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                let key = origin + "/" + file
                guard LibraryBackup.validWebsiteVariablePath(key),
                      let data = try read("ruleData/rss/" + key) else { continue }
                values[key] = try JSONDecoder().decode([String: String].self, from: data)
            }
        }
        return values
    }

    func read(_ relative: String) throws -> Data? {
        let file = try checked(relative)
        do { return try Data(contentsOf: file, options: .mappedIfSafe) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    mutating func write(_ data: Data?, to relative: String) throws {
        let file = try checked(relative)
        let old = try read(relative)
        guard old != data else { return }
        if let data {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: file)
        }
        originals.append((file, old))
    }

    func rollback() throws {
        for (file, old) in originals.reversed() {
            if let old { try old.write(to: file, options: .atomic) }
            else { try FileManager.default.removeItem(at: file) }
        }
    }
}
