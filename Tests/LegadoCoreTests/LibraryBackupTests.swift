import Foundation
import Testing
@testable import LegadoCore

struct LibraryBackupTests {
    @Test func restoresPortableShelfSourcesSettingsAndWebsiteData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        let source = try LegadoDatabase(url: a.appendingPathComponent("db"))
        let target = try LegadoDatabase(url: b.appendingPathComponent("db"))
        let from = UUID().uuidString, to = UUID().uuidString
        let sourceDefaults = try #require(UserDefaults(suiteName: from))
        let targetDefaults = try #require(UserDefaults(suiteName: to))
        defer { sourceDefaults.removePersistentDomain(forName: from); targetDefaults.removePersistentDomain(forName: to) }
        let text = "第一章\n在新设备上继续读"
        let original = a.appendingPathComponent("原书.txt")
        try Data(text.utf8).write(to: original)
        let local = try LocalBookService().importFile(at: original, into: a.appendingPathComponent("LocalBooks"))
        var book = local.book
        book.durChapterPos = 5
        let site = RssSource(sourceUrl: "https://site.test", sourceName: "网站")
        let rule = BookSource(bookSourceUrl: "https://books.test", bookSourceName: "书源")
        let novel = Book(bookUrl: "https://books.test/1", name: "网络书", origin: rule.bookSourceUrl)
        let mark = Bookmark(time: 100, bookName: book.name)
        let star = RssStar(article: .init(origin: site.sourceUrl, sort: "", title: "收藏", link: "/1"))
        let variable = RSSVariableStore(directory: a.appendingPathComponent("ruleData/rss"))
        try variable.put(origin: site.sourceUrl, link: "/1", key: "page", value: "3")
        try await source.replaceBooksAndChapters([book, novel], chapters: local.chapters, bookURL: book.bookUrl)
        let epubURL = try EPUBBookTests().fixture()
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }
        let epub = try LocalBookService().importFile(at: epubURL, into: a.appendingPathComponent("LocalBooks"))
        try await source.replaceBooksAndChapters([book, novel, epub.book], chapters: epub.chapters, bookURL: epub.book.bookUrl)
        let extra = Data("尚未上架".utf8)
        try extra.write(to: a.appendingPathComponent("LocalBooks/另一本.txt"))
        let pending = BookProgress(book: book)
        sourceDefaults.set(try JSONEncoder().encode([book.bookUrl: pending]), forKey: "pendingBookReadingProgress")
        let downloads = ChapterContentCache(directory: a.appendingPathComponent("ChapterContent"))
        try await downloads.save(.init(bookURL: novel.bookUrl, chapterURL: "/cached", content: "TEMP_CHAPTER_SENTINEL"))
        try await source.replaceBookGroups([.init(groupId: 1, groupName: "收藏")])
        try await source.replaceReadRecords([.init(deviceId: "fixture", bookName: book.name, readTime: 6000, lastRead: 150)])
        try await source.appendRssReadRecords([.init(record: "/1", title: "阅读记录", readTime: 30, origin: site.sourceUrl)])
        try await source.replaceRuleSubs([.init(id: 1, name: "订阅", url: "https://example.invalid/rules")])
        try await source.replaceHttpTTS([.init(id: 1, name: "朗读设置", url: "https://example.invalid/tts")])
        try await source.replaceKeyboardAssists([.init(key: "辅助", value: "字")])
        try await source.replaceServers([.init(id: 1, name: "测试服务器")])
        try await source.recordSearchKeyword("迁移", at: 333)
        try FileManager.default.createDirectory(at: a.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: a.appendingPathComponent("fonts/fixture.ttf"))
        try await source.replaceBookmarks([mark])
        try await source.replaceBookSources([rule])
        try await source.replaceRssSources([site])
        try await source.replaceRssStars([star])
        try await source.replaceTxtTocRules([.init(id: 1, name: "章节", rule: "^第")])
        try await source.putCache(.init(key: "v_book_choice", value: "繁体"))
        try await source.putCache(.init(key: "v_book_loginInfo", value: "secret"))
        let replace = ReplaceRule(id: 10, name: "清理", pattern: "示例")
        try JSONEncoder().encode([replace]).write(to: a.appendingPathComponent("replace-rules.json"))
        try Data([1, 2, 3]).write(to: a.appendingPathComponent("reader-background.jpg"))
        var network = ApplicationSettings()
        network.userAgent = "MiaoYue/1"
        network.proxy = "socks5://127.0.0.1:1080"
        network.hosts = "192.0.2.1 books.test"
        network.timeoutSeconds = 60
        network.concurrentSources = 8
        network.ignoreCertificateErrors = false
        network.chapterCacheMB = 512
        network.prefetchChapters = 3
        network.recordLog = true
        try ApplicationSettingsStore(defaults: sourceDefaults).save(network)
        sourceDefaults.set("2", forKey: "themeMode")
        sourceDefaults.set("wechat", forKey: "readerTheme")
        sourceDefaults.set("qwen.serena", forKey: "appTtsEngine")
        sourceDefaults.set("fixture.ttf", forKey: "textFont")
        sourceDefaults.set(true, forKey: "readAloudByPage")
        sourceDefaults.set(false, forKey: "recordWebsiteBrowsingHistory")
        sourceDefaults.set(7, forKey: "ttsSpeechRate")
        sourceDefaults.set(24, forKey: "textSize")
        targetDefaults.set(true, forKey: "readerFullJustify")
        try await target.replaceBooks([Book(bookUrl: "old", name: "旧书", origin: "old")])
        let bytes = try await source.makeBackup(defaultsSuite: from).encoded()
        #expect(!String(decoding: bytes, as: UTF8.self).contains("secret"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("TEMP_CHAPTER_SENTINEL"))
        let backup = try #require(try LibraryBackup.recognize(bytes))
        for _ in 0..<2 {
            try await target.restoreBackup(backup, defaultsSuite: to)
            let result = try await target.makeBackup(defaultsSuite: to)
            #expect(result.shelf.books.count == 3)
            #expect(result.shelf.books.contains(novel))
            let restored = try #require(result.shelf.books.first { $0.name == book.name })
            #expect(restored.bookUrl != book.bookUrl)
            #expect(restored.durChapterPos == 5)
            let restoredEPUB = try #require(result.shelf.books.first { $0.name == epub.book.name })
            let epubChapter = try #require(result.shelf.chapters[restoredEPUB.bookUrl]?.first { $0.title == "第二章" })
            #expect(try LocalBookService().loadContent(book: restoredEPUB, chapter: epubChapter).content.contains("第二章正文"))
            #expect(result.migration?.pendingProgress[restored.bookUrl] == pending)
            #expect(result.migration?.servers == backup.migration?.servers)
            #expect(result.shelf.localFiles == backup.shelf.localFiles)
            #expect(result.shelf.localFiles["另一本.txt"] == extra)
            #expect(result.shelf.groups == backup.shelf.groups)
            #expect(result.readingHistory == backup.readingHistory)
            #expect(result.websiteHistory == backup.websiteHistory)
            #expect(result.searchHistory == backup.searchHistory)
            #expect(result.speechEngines == backup.speechEngines)
            #expect(result.keyboardAssists == backup.keyboardAssists)
            #expect(result.subscriptions == backup.subscriptions)
            #expect(result.fonts == backup.fonts)
            #expect(result.preferences == backup.preferences)
            let chapter = try #require(result.shelf.chapters[restored.bookUrl]?.first)
            #expect(chapter.baseUrl == restored.bookUrl)
            #expect(try LocalBookService().loadContent(book: restored, chapter: chapter).content.contains("在新设备上继续读"))
            #expect(result.bookSources == [rule])
            #expect(result.websiteSources == [site])
            #expect(result.bookmarks == [mark])
            #expect(result.websiteFavorites == [star])
            #expect(result.tocRules == backup.tocRules)
            #expect(result.replaceRules == [replace])
            #expect(result.sourceVariables.map(\.key) == ["v_book_choice"])
            #expect(result.background == Data([1, 2, 3]))
            #expect(result.settings == network)
            #expect(ApplicationSettingsStore(defaults: targetDefaults).settings == network)
            #expect(targetDefaults.integer(forKey: "textSize") == 24)
            #expect(targetDefaults.object(forKey: "readerFullJustify") == nil)
            let restoredVariables = RSSVariableStore(directory: b.appendingPathComponent("ruleData/rss"))
            #expect(try restoredVariables.get(origin: site.sourceUrl, link: "/1", key: "page") == "3")
        }
    }

    @Test func emptyBackupReplacesCollectionsAndDoesNotReviveLegacyFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LegadoDatabase(url: dir.appendingPathComponent("db"))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = try await db.makeBackup(defaultsSuite: suite)
        let source = BookSource(bookSourceUrl: "https://legacy.test", bookSourceName: "旧源")
        let legacy = dir.appendingPathComponent("book-sources.json")
        try JSONEncoder().encode([source]).write(to: legacy)
        defaults.set(["旧记录"], forKey: "bookSearchHistory")
        let old = try await db.makeBackup(defaultsSuite: suite)
        #expect(old.bookSources == [source])
        #expect(old.searchHistory.map(\.word) == ["旧记录"])
        try await db.restoreBackup(old, defaultsSuite: suite)
        try await db.restoreBackup(empty, defaultsSuite: suite)
        try await db.importLegacyJSON(bookSourcesURL: legacy, booksURL: nil)
        try await db.importLegacySearchKeywords(["旧记录"])
        #expect(try await db.loadBookSources().isEmpty)
        #expect(try await db.loadSearchKeywords(order: .lastUseTime).isEmpty)
    }

    @Test func failedFileWriteRollsBackFilesShelfAndSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LegadoDatabase(url: root.appendingPathComponent("db"))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = Book(bookUrl: "https://book.test", name: "旧书", origin: "source")
        try await db.replaceBooks([old])
        defaults.set(21, forKey: "textSize")
        var incoming = try await db.makeBackup(defaultsSuite: suite)
        let path = root.appendingPathComponent("LocalBooks/local.txt")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("原版".utf8).write(to: path)
        incoming.shelf.books = [Book(bookUrl: path.absoluteString, name: "新书")]
        incoming.shelf.localFiles = ["local.txt": Data("新版".utf8)]
        incoming.preferences["textSize"] = .number(30)
        incoming.background = Data([1])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("reader-background.jpg"), withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await db.restoreBackup(incoming, defaultsSuite: suite) }
        #expect(try await db.loadBooks() == [old])
        #expect(try Data(contentsOf: path) == Data("原版".utf8))
        #expect(defaults.integer(forKey: "textSize") == 21)
    }
}
