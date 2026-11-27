import UIKit
import XCTest

@MainActor
final class DarkModeUITests: XCTestCase {
    func testSharedBackupShowsRestorePreviewAndAllowsCancellation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        var backup: [String: Any] = [
            "type": "com.epiboly.legado.backup", "version": 1, "createdAt": "2026-01-01T00:00:00Z",
            "shelf": ["books": [], "groups": [], "chapters": [:], "localFiles": [:]] as [String: Any],
            "websiteVariables": [:], "preferences": [:], "fonts": [:],
            "settings": ["userAgent": "", "proxy": "", "hosts": "", "timeoutSeconds": 0, "concurrentSources": 8,
                         "chapterCacheMB": 128, "prefetchChapters": 2, "recordLog": false,
                         "ignoreCertificateErrors": false] as [String: Any]
        ]
        for key in ["bookSources", "websiteSources", "bookmarks", "readingHistory", "websiteFavorites",
                    "websiteHistory", "searchHistory", "sourceVariables", "speechEngines", "keyboardAssists",
                    "subscriptions", "replaceRules"] { backup[key] = [Any]() }
        try JSONSerialization.data(withJSONObject: backup).write(to: file)
        let app = launch(["-uiDemoTab", "settings", "-uiAutomationImportURL", file.absoluteString])
        let preview = app.navigationBars["恢复喵阅备份"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["恢复此备份"].exists)
        preview.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["profile.about"].waitForExistence(timeout: 5))
    }

    func testBackupSettingsOpensSystemExporter() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings"])
        let row = app.buttons["profile.externaldrive"]
        let scroll = app.scrollViews["profile.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        for _ in 0..<5 where !row.isHittable { scroll.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["导入 JSON 文件"].waitForExistence(timeout: 5))
        attach(app, name: "备份与恢复首屏")
        app.buttons["导出备份 JSON"].tap()
        // iOS 17 Files labels the export confirmation “Move”.
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "存储", "保存", "Move", "移动"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 12))
    }

    func testWebsiteSourceDraftKeepsAdvancedSettingsAcrossNavigation() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "rss", "-themeMode", "1"])
        app.buttons["网站源管理"].tap()
        app.buttons["网站源操作"].tap()
        app.buttons["新建网站源"].tap()
        let request = app.buttons["请求与登录"]
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        attach(app, name: "网站源编辑首屏")
        request.tap()
        let cookies = app.switches["自动保存Cookie"]
        let previous = cookies.value as? String
        cookies.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.navigationBars["请求与登录"].buttons["保存"].tap()
        request.tap()
        XCTAssertNotEqual(previous, cookies.value as? String)
        app.navigationBars["请求与登录"].buttons["取消"].tap()

        for title in ["图标与注释", "请求与登录", "分类与列表规则", "WebView 规则", "其他设置"] {
            let entry = app.buttons[title]
            scrollTo(entry, in: app)
            entry.tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.staticTexts["sheet.heading"].waitForExistence(timeout: 5))
            XCTAssertTrue(bar.buttons["保存"].isHittable)
            attach(app, name: title)
            bar.buttons["取消"].tap()
        }
    }

    func testWebsiteManagementSelectsAndDeletesOnlyFilteredSources() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("websites.json")
        let sources = [["sourceName": "Alpha", "sourceUrl": "https://alpha.invalid"],
                       ["sourceName": "Beta", "sourceUrl": "https://beta.invalid"],
                       ["sourceName": "Gamma", "sourceUrl": "https://gamma.invalid", "sourceGroup": "新闻"]]
        try JSONSerialization.data(withJSONObject: sources).write(to: file)
        app.launchEnvironment["LEGADO_UI_RSS_DATABASE"] = directory.appendingPathComponent("rss.sqlite3").path
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        let notice = app.alerts["网站源已导入"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        notice.buttons["好"].tap()
        app.buttons["网站源管理"].tap()

        let bar = app.navigationBars["网站源管理"]
        let group = app.buttons["分组"]
        group.tap()
        app.buttons["未分组"].tap()
        bar.buttons["编辑"].tap()
        XCTAssertFalse(app.buttons["删除"].isEnabled)
        let move = app.buttons["移动到分组"]
        XCTAssertFalse(move.isEnabled)
        app.staticTexts["Alpha"].tap()
        XCTAssertTrue(app.buttons["删除（1）"].isEnabled)
        app.staticTexts["Alpha"].tap()
        XCTAssertFalse(app.buttons["删除"].isEnabled)
        app.buttons["全选"].tap()
        let delete = app.buttons["删除（2）"]
        XCTAssertEqual(app.buttons["取消全选"].value as? String, "已选 2 项")
        delete.tap()
        let confirm = app.alerts["删除所选网站源？"]
        confirm.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["取消全选"].isHittable)
        attach(app, name: "网站源批量操作")
        group.tap()
        app.buttons["新闻"].tap()
        XCTAssertFalse(app.buttons["删除"].isEnabled)
        group.tap()
        app.buttons["未分组"].tap()
        app.buttons["全选"].tap()
        move.tap()
        let moveBar = app.navigationBars["移动到分组"]
        XCTAssertFalse(moveBar.buttons["移动"].isEnabled)
        app.buttons["新闻"].tap()
        XCTAssertTrue(app.buttons["新闻"].isSelected)
        attach(app, name: "网站源移动到分组")
        moveBar.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["取消全选"].isHittable)
        move.tap()
        app.buttons["新建分组"].tap()
        let name = app.textFields["分组名称"]
        name.tap()
        name.typeText("Moved")
        app.navigationBars["新建分组"].buttons["保存"].tap()
        XCTAssertTrue(app.buttons["Moved"].isSelected)
        moveBar.buttons["移动"].tap()
        XCTAssertTrue(app.staticTexts["此分组暂无网站源"].waitForExistence(timeout: 5))
        group.tap()
        app.buttons["Moved"].tap()
        XCTAssertTrue(app.staticTexts["Alpha"].exists && app.staticTexts["Beta"].exists)
        XCTAssertFalse(app.staticTexts["Gamma"].exists)
        bar.buttons["编辑"].tap()
        app.buttons["全选"].tap()
        delete.tap()
        confirm.buttons["删除 2 个"].tap()
        XCTAssertTrue(bar.buttons["编辑"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss"]
        app.launch()
        app.buttons["网站源管理"].tap()
        XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha"].exists)
        XCTAssertFalse(app.staticTexts["Beta"].exists)
    }

    func testWebsiteSourceEditorDeletesOriginalSourceAfterConfirmation() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let name = "Editor Delete Test"
        app.launchEnvironment["LEGADO_UI_RSS_DATABASE"] = directory.appendingPathComponent("rss.sqlite3").path
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss"]
        app.launch()
        app.buttons["网站源管理"].tap()
        app.buttons["网站源操作"].tap()
        app.buttons["新建网站源"].tap()
        let delete = app.buttons["删除网站源"]
        XCTAssertFalse(delete.exists)
        let nameField = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "网站名称")).firstMatch
        nameField.tap()
        nameField.typeText(name)
        let url = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "https://")).firstMatch
        url.tap()
        url.typeText("https://editor.invalid\n")
        app.navigationBars["新建网站源"].buttons["保存"].tap()
        app.staticTexts[name].tap()

        url.tap()
        url.typeText("/draft\n")
        scrollTo(delete, in: app)
        delete.tap()
        let confirmation = app.alerts["删除「\(name)」？"]
        confirmation.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["编辑网站源"].exists)
        delete.tap()
        confirmation.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["还没有网站源"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        app.buttons["网站源管理"].tap()
        XCTAssertTrue(app.staticTexts["还没有网站源"].waitForExistence(timeout: 5))
    }

    func testTocRuleSwitchPersistsIndependentlyOfOpeningTheEditor() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.list.bullet.rectangle"]
        scrollTo(entry, in: app)
        entry.tap()

        let name = "目录(去空白)"
        let toggle = app.switches["启用" + name]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = toggle.value as? String
        attach(app, name: "TXT 目录规则列表")
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, original)
        let title = app.navigationBars["TXT 目录规则"]
        XCTAssertTrue(title.exists)
        title.buttons.element(boundBy: 0).tap()
        entry.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertNotEqual(toggle.value as? String, original)

        let row = app.buttons.containing(.staticText, identifier: name).firstMatch
        row.tap()
        XCTAssertTrue(app.navigationBars["编辑目录规则"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        row.swipeRight()
        app.buttons[original == "1" ? "启用" : "停用"].tap()
        XCTAssertEqual(toggle.value as? String, original)
        title.buttons["更多"].tap()
        app.buttons["调整顺序"].tap()
        XCTAssertTrue(title.buttons["完成"].waitForExistence(timeout: 5), app.debugDescription)
        title.buttons["完成"].tap()
        XCTAssertTrue(title.buttons["新建"].waitForExistence(timeout: 5))
    }

    func testBookSourceFilterAndSwitchCanBeUsedFromTheList() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "sources", "-themeMode", "1"])
        let filter = app.buttons["分组"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        attach(app, name: "书源管理列表")
        filter.tap()
        app.buttons["文学"].tap()

        let toggle = app.switches["启用经典文学馆"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["听见故事"].exists)
        let original = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["书源管理"].exists)
        XCTAssertNotEqual(toggle.value as? String, original)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        filter.tap()
        app.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["听见故事"].waitForExistence(timeout: 5))
    }

    func testSubscriptionEditorKeepsSaveValidationAndUpdateOptions() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.link"]
        scrollTo(entry, in: app)
        entry.tap()
        let title = app.navigationBars["规则订阅"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        attach(app, name: "规则订阅列表")
        title.buttons["新建"].tap()
        XCTAssertTrue(app.navigationBars["新建订阅"].waitForExistence(timeout: 5))
        let save = app.buttons["保存"]
        XCTAssertFalse(save.isEnabled)
        attach(app, name: "新建订阅表单")
        app.segmentedControls.buttons["净化规则"].tap()
        let automatic = app.switches["自动更新"]
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.switches["静默更新"].waitForExistence(timeout: 5))
        let url = app.descendants(matching: .any).matching(identifier: "subscription.url").firstMatch
        url.tap()
        url.typeText("https://rules.invalid/books.json")
        XCTAssertTrue(save.isEnabled)
        app.buttons["取消"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }

    func testTocMatchTabRetainsSampleAndReportsSourceLines() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "2"])
        let entry = app.buttons["profile.list.bullet.rectangle"]
        scrollTo(entry, in: app)
        entry.tap()
        app.buttons["新建"].tap()
        let bar = app.navigationBars["编辑目录规则"]
        bar.buttons["保存"].tap()
        let error = app.alerts["保存失败"]
        XCTAssertTrue(error.staticTexts["名称和正则不能为空"].waitForExistence(timeout: 5))
        error.buttons["好"].tap()
        XCTAssertTrue(bar.exists)
        let pattern = app.textViews["目录正则"]
        pattern.tap()
        pattern.typeText("^#.*")
        let tabs = app.segmentedControls
        tabs.buttons["匹配测试"].tap()
        app.buttons["输入或粘贴测试文本"].tap()
        app.textViews["测试文本"].typeText("#1\nbody\n#2")
        app.buttons["完成编辑"].tap()
        XCTAssertTrue(app.staticTexts["命中 2 条"].waitForExistence(timeout: 5))
        attach(app, name: "目录规则匹配测试")
        let thirdLine = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value == %@", "#2", "第 3 行")).firstMatch
        XCTAssertTrue(thirdLine.exists, app.debugDescription)
        tabs.buttons["规则设置"].tap()
        XCTAssertEqual(pattern.value as? String, "^#.*")
        tabs.buttons["匹配测试"].tap()
        XCTAssertTrue(thirdLine.exists)
    }

    func testProfileAndAboutShowCurrentAppName() {
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let card = app.buttons["profile.about"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("喵阅"))
        attach(app, name: "MiaoYue profile")
        card.tap()
        XCTAssertTrue(app.staticTexts["喵阅"].waitForExistence(timeout: 5))
        attach(app, name: "MiaoYue about")
    }

    func testExploreCategoryStaysVisibleAndRowPaddingOpensBook() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "explore"])
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "经典文学馆")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        // A short viewport lets the six demo books scroll on iPhone.
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }
        XCUIDevice.shared.orientation = .landscapeLeft

        let category = app.buttons["热门连载"]
        let firstBook = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "潮汐来信")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertTrue(firstBook.isHittable)
        let categoryY = category.frame.midY
        let firstBookY = firstBook.frame.midY
        let list = app.scrollViews["explore.books"]
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.1, thenDragTo: end)
        let scrolled = NSPredicate { _, _ in
            !firstBook.exists || firstBook.frame.midY < firstBookY - 40
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: scrolled, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(category.isHittable)
        XCTAssertEqual(category.frame.midY, categoryY, accuracy: 1)

        category.tap()
        XCTAssertTrue(category.isSelected)
        XCTAssertEqual(firstBook.frame.midY, firstBookY, accuracy: 1)
        firstBook.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.08)).tap()
        XCTAssertTrue(app.navigationBars["书籍详情"].waitForExistence(timeout: 5))
    }

    func testStartupScopeAndDirectDiagnostics() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.power"]
        scrollTo(entry, in: app)
        entry.tap()
        XCTAssertFalse(app.buttons["应用锁"].exists)
        let pages = app.buttons["settings.startupPage"]
        let original = try XCTUnwrap(pages.value as? String)
        let another = original == "发现" ? "书架" : "发现"
        XCTAssertFalse(app.segmentedControls.firstMatch.exists)
        pages.tap()
        attach(app, name: "启动时打开 · 选择菜单")
        try XCTUnwrap(app.buttons.matching(identifier: another).allElementsBoundByIndex.last(where: \.isHittable)).tap()
        XCTAssertEqual(pages.value as? String, another)
        XCTAssertTrue(app.tabBars.buttons["设置"].isSelected)
        app.launchArguments = ["-uiDemo", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons[another].isSelected)
        app.tabBars.buttons["设置"].tap()
        scrollTo(entry, in: app)
        entry.tap()
        XCTAssertEqual(pages.value as? String, another)
        pages.tap()
        try XCTUnwrap(app.buttons.matching(identifier: original).allElementsBoundByIndex.last(where: \.isHittable)).tap()

        let toggle = app.switches["启动时更新书架"]
        let control = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let wasEnabled = toggle.value as? String == "1"
        if !wasEnabled { control.tap() }
        let scope = app.buttons["settings.refreshScope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        attach(app, name: "启动管理")
        let wasLatest = (scope.value as? String ?? scope.label).contains("最新章")
        let choices = ["全部书籍", "已读到最新章的书"]
        scope.tap()
        app.buttons[choices[wasLatest ? 0 : 1]].firstMatch.tap()
        control.tap()
        XCTAssertFalse(scope.exists)
        control.tap()
        XCTAssertTrue((scope.value as? String ?? scope.label).contains(choices[wasLatest ? 0 : 1]))
        scope.tap()
        app.buttons[choices[wasLatest ? 1 : 0]].firstMatch.tap()
        if !wasEnabled { control.tap() }
        app.navigationBars["启动管理"].buttons.element(boundBy: 0).tap()
        let logs = app.buttons["profile.doc.text.magnifyingglass"]
        scrollTo(logs, in: app)
        app.scrollViews["profile.scroll"].swipeUp()
        XCTAssertLessThan(app.staticTexts["日志"].frame.minY, logs.frame.minY)
        attach(app, name: "设置 · 网络与日志")
        logs.tap()
        XCTAssertTrue(app.navigationBars["日志与诊断"].waitForExistence(timeout: 5))
        let recording = app.switches["记录运行日志"]
        let recordSwitch = recording.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let initial = try XCTUnwrap(recording.value as? String)
        attach(app, name: "日志与诊断")
        recordSwitch.tap()
        app.navigationBars["日志与诊断"].buttons.element(boundBy: 0).tap()
        logs.tap()
        XCTAssertNotEqual(recording.value as? String, initial)
        recordSwitch.tap()
        XCTAssertEqual(recording.value as? String, initial)
    }

    func testDatabaseMaintenanceRunsFromItsOwnPage() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.cylinder"]
        scrollTo(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["整理数据库"].waitForExistence(timeout: 5))
        let database = app.buttons["开始整理"]
        XCTAssertNotEqual(database.value as? String, "已整理")
        attach(app, name: "整理数据库")
        database.tap()
        let compacted = expectation(for: NSPredicate(format: "value == %@", "已整理"), evaluatedWith: database)
        wait(for: [compacted], timeout: 10)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach(app, name: "数据库 · 整理完成")

        XCTAssertFalse(app.buttons["清理网页缓存"].exists)
    }

    func testWebCacheClearsSeparatelyInCacheManagement() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.internaldrive"]
        scrollTo(entry, in: app)
        entry.tap()
        let limit = app.buttons["cache.limit"]
        let previousLimit = limit.value as? String
        let chapters = app.buttons["清空章节缓存"]
        let hadChapters = chapters.isEnabled
        let cache = app.buttons["清理网页缓存"]
        scrollTo(cache, in: app)
        cache.tap()
        let confirmation = app.alerts["清理网页缓存？"]
        confirmation.buttons["取消"].tap()
        XCTAssertNotEqual(cache.value as? String, "已清理")
        cache.tap()
        confirmation.buttons["清理"].tap()
        let cleared = expectation(for: NSPredicate(format: "value == %@", "已清理"), evaluatedWith: cache)
        wait(for: [cleared], timeout: 15)
        XCTAssertEqual(chapters.isEnabled, hadChapters)
        XCTAssertEqual(limit.value as? String, previousLimit)
    }

    func testLegacyProfileScrollsBetweenHeaderAndSettings() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "2", "-uiLegacyCompatibility"])
        let scroll = app.scrollViews["profile.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        var metrics: [XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics) {
            let logs = app.buttons["profile.doc.text.magnifyingglass"]
            for _ in 0..<4 where !logs.isHittable { scroll.swipeUp(velocity: .fast) }
            XCTAssertTrue(logs.isHittable)
            XCTAssertFalse(app.buttons["profile.info.circle"].exists)
            XCTAssertFalse(app.staticTexts["项目与支持"].exists)
            let about = app.buttons["profile.about"]
            for _ in 0..<4 where !about.isHittable { scroll.swipeDown(velocity: .fast) }
            XCTAssertTrue(about.isHittable)
        }
        app.buttons["profile.power"].tap()
        XCTAssertTrue(app.navigationBars["启动管理"].waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    }

    func testSearchScopeSaveUsesThePrimaryFillInBothAppearances() throws {
        for theme in ["1", "2"] {
            let app = launch(["-uiDemoTab", "search", "-themeMode", theme])
            let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "搜索范围")).firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 12))
            entry.tap()
            let bar = app.navigationBars["搜索范围"]
            let save = bar.buttons["保存"]
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            let title = bar.staticTexts["sheet.heading"]
            XCTAssertEqual(title.label, "搜索范围")
            XCTAssertGreaterThan(title.frame.width, 60)
            let cancel = bar.buttons["取消"]
            XCTAssertLessThan(title.frame.minX, app.frame.width * 0.2)
            XCTAssertGreaterThan(cancel.frame.midX, app.frame.midX)
            XCTAssertLessThan(cancel.frame.midX, save.frame.midX)
            try assertReadableDarkFill(save, in: app)
            let row = try XCTUnwrap(app.cells.containing(.staticText, identifier: "全部书源").allElementsBoundByIndex.last)
            let y = row.frame.midY / app.frame.height
            let panel = try app.backgroundRGB(x: (bar.frame.minX + 5) / app.frame.width, y: y)
            let card = try app.backgroundRGB(x: (row.frame.midX + row.frame.width / 4) / app.frame.width, y: y)
            for (base, fill) in zip(panel, card) {
                if theme == "1" {
                    XCTAssertGreaterThanOrEqual(base, 250)
                    XCTAssertGreaterThan(base, fill)
                    XCTAssertGreaterThan(fill, 225)
                } else {
                    XCTAssertLessThan(base, 45)
                    XCTAssertGreaterThan(fill, base)
                    XCTAssertLessThan(fill, 65)
                }
            }
            attach(app, name: "搜索范围 · 保存按钮 · \(theme)")
            app.terminate()
        }
    }

    func testReplacementRulesKeepTitleBesideBackAndSearchInContent() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings"])
        let entry = app.buttons["profile.text.badge.checkmark"]
        scrollTo(entry, in: app)
        entry.tap()
        app.buttons["新建规则"].tap()
        let pattern = app.textViews["filter.pattern"]
        pattern.tap()
        pattern.typeText("sample")
        app.buttons["syntaxCodeEditor.done"].tap()
        app.buttons["保存"].tap()
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        back.tap()
        entry.tap()

        let bar = app.navigationBars["替换净化"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let heading = bar.staticTexts["page.heading"]
        XCTAssertEqual(heading.label, "替换净化")
        XCTAssertEqual(heading.frame.midY, back.frame.midY, accuracy: 4)
        XCTAssertEqual(heading.frame.minX - back.frame.maxX, 12, accuracy: 8)
        let search = app.textFields["名称、匹配内容或分组"]
        XCTAssertTrue(search.isHittable)
        XCTAssertGreaterThanOrEqual(search.frame.midY, bar.frame.maxY)
        attach(app, name: "替换净化")
        bar.buttons["编辑"].tap()
        bar.buttons["完成"].tap()
        search.tap()
        search.typeText("unmatched")
        XCTAssertTrue(app.staticTexts["没有符合筛选条件的规则"].exists)
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.staticTexts["sample"].exists)
    }

    func testProfileDetailBackgroundInLightMode() throws {
        try checkProfileDetailBackground(theme: "1")
    }

    func testProfileDetailBackgroundInDarkMode() throws {
        try checkProfileDetailBackground(theme: "2")
    }

    private func checkProfileDetailBackground(theme: String) throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", theme])
        let profile = app.scrollViews["profile.scroll"]
        XCTAssertTrue(profile.waitForExistence(timeout: 8))

        let canvas = try gutterRGB(in: app)
        let routes = [
            ("about", "关于"), ("power", "启动管理"), ("lock", "应用锁"),
            ("headphones", "听书设置"), ("bookmark", "书签"), ("chart.bar", "阅读统计"),
            ("globe", "书源管理"), ("network", "网站源管理"), ("link", "规则订阅"),
            ("text.badge.checkmark", "替换净化"), ("list.bullet.rectangle", "TXT 目录规则"),
            ("folder", "本地书籍文件"), ("doc.text", "缓存正文导出"), ("externaldrive", "数据备份与恢复"),
            ("internaldrive", "缓存管理"), ("wifi", "网络连接"), ("slider.horizontal.3", "高级网络"),
            ("cylinder", "整理数据库"), ("doc.text.magnifyingglass", "日志与诊断")
        ]
        for (icon, title) in routes {
            let entry = app.buttons["profile." + icon]
            scrollTo(entry, in: app)
            entry.tap()
            let nav = app.navigationBars[title]
            let back = icon == "lock" && app.buttons["取消"].exists ? app.buttons["取消"] : nav.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), title)
            if nav.exists {
                let heading = nav.staticTexts["page.heading"]
                XCTAssertEqual(heading.label, title)
                XCTAssertEqual(heading.frame.midY, back.frame.midY, accuracy: 4, title)
                XCTAssertEqual(heading.frame.minX - back.frame.maxX, 12, accuracy: 8, title)
            }
            let page = try gutterRGB(in: app)
            for (actual, expected) in zip(page, canvas) {
                XCTAssertEqual(actual, expected, accuracy: 2, "\(title) · \(page) / \(canvas)")
            }
            attach(app, name: title)
            back.tap()
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
        }
    }

    func testWebsiteActivityBackgroundMatchesHomeInBothAppearances() throws {
        continueAfterFailure = false
        for theme in ["1", "2"] {
            let app = launch(["-uiDemoTab", "rss", "-themeMode", theme])
            let favorites = app.buttons["websites.favorites"]
            XCTAssertTrue(favorites.waitForExistence(timeout: 8))
            let home = try gutterRGB(in: app)
            for (entry, title) in [(favorites, "网页收藏"), (app.buttons["websites.history"], "网站阅读记录")] {
                entry.tap()
                let nav = app.navigationBars[title]
                XCTAssertTrue(nav.waitForExistence(timeout: 5))
                let page = try gutterRGB(in: app)
                for (actual, expected) in zip(page, home) {
                    XCTAssertEqual(actual, expected, accuracy: 2, "\(title) · \(page) / \(home)")
                }
                nav.buttons.firstMatch.tap()
                XCTAssertTrue(favorites.waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    // Average a narrow strip away from the bars so a nearby card shadow cannot dominate.
    private func gutterRGB(in app: XCUIApplication) throws -> [Int] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let strip = CGRect(x: 1, y: image.height / 4, width: 2, height: image.height / 2)
        let crop = try XCTUnwrap(image.cropping(to: strip))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.prefix(3).map(Int.init)
    }

    func testProfileOpensFileAndNetworkPagesDirectly() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let routes = [("folder", "本地书籍文件"), ("doc.text", "缓存正文导出"), ("internaldrive", "缓存管理"),
                      ("wifi", "网络连接"), ("slider.horizontal.3", "高级网络")]
        for (icon, title) in routes {
            let entry = app.buttons["profile." + icon]
            scrollTo(entry, in: app)
            if icon == "slider.horizontal.3" { attach(app, name: "设置 · 文件与网络入口") }
            entry.tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertFalse(bar.buttons["保存"].exists)
            switch icon {
            case "folder":
                XCTAssertTrue(app.buttons["导入 TXT / EPUB"].waitForExistence(timeout: 5))
            case "doc.text":
                let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "长夜里的灯")).firstMatch
                XCTAssertTrue(book.waitForExistence(timeout: 5))
            case "internaldrive":
                XCTAssertTrue(app.buttons["cache.limit"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["清空章节缓存"].exists)
                XCTAssertTrue(app.buttons["清理网页缓存"].exists)
            case "wifi":
                XCTAssertTrue(app.switches["兼容无效证书的书源"].exists)
            default:
                XCTAssertTrue(app.textFields["全局代理"].exists)
                XCTAssertTrue(app.textFields["默认 User-Agent"].exists)
                XCTAssertTrue(app.textViews["自定义 Hosts"].exists)
            }
            attach(app, name: title)
            bar.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.scrollViews["profile.scroll"].waitForExistence(timeout: 5))
        }
    }

    func testNetworkSwitchPersistsWhenLeavingImmediately() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.wifi"]
        scrollTo(entry, in: app)
        entry.tap()
        let toggle = app.switches["兼容无效证书的书源"]
        let original = try XCTUnwrap(toggle.value as? String)
        let switchControl = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        switchControl.tap()
        let bar = app.navigationBars["网络连接"]
        XCTAssertFalse(bar.buttons["保存"].exists)
        bar.buttons.element(boundBy: 0).tap()
        entry.tap()
        XCTAssertNotEqual(try XCTUnwrap(toggle.value as? String), original)
        switchControl.tap()
        XCTAssertEqual(toggle.value as? String, original)
    }

    func testInvalidInlineProxyPreservesPreviousValue() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "2"])
        let entry = app.buttons["profile.slider.horizontal.3"]
        scrollTo(entry, in: app)
        entry.tap()
        let proxy = app.textFields["全局代理"]
        let original = proxy.value as? String
        proxy.tap()
        proxy.typeText("?invalid")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "代理格式应为")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["应用"].exists)
        app.navigationBars["高级网络"].buttons.element(boundBy: 0).tap()
        entry.tap()
        XCTAssertEqual(proxy.value as? String, original)
    }

    func testCachePrefetchTakesEffectWithoutSaving() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.internaldrive"]
        scrollTo(entry, in: app)
        entry.tap()
        let stepper = app.steppers["cache.prefetch"]
        let initial = try XCTUnwrap((stepper.value as? String).flatMap(Int.init))
        let trailing = stepper.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
        let plus = trailing.withOffset(CGVector(dx: -18, dy: 0))
        let minus = trailing.withOffset(CGVector(dx: -68, dy: 0))
        (initial < 20 ? plus : minus).tap()
        app.navigationBars["缓存管理"].buttons.element(boundBy: 0).tap()
        entry.tap()
        XCTAssertEqual(stepper.value as? String, String(initial < 20 ? initial + 1 : initial - 1))
        (initial < 20 ? minus : plus).tap()
        XCTAssertEqual(stepper.value as? String, String(initial))
    }

    func testInlineProxyPersistsOnBackAndKeyboardDone() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "1"])
        let entry = app.buttons["profile.slider.horizontal.3"]
        scrollTo(entry, in: app)
        entry.tap()
        let field = app.textFields["全局代理"]
        let original = try XCTUnwrap(field.value as? String)
        let previous = original == field.placeholderValue ? "" : original
        let address = previous == "http://127.0.0.1:17891" ? "http://127.0.0.1:17892" : "http://127.0.0.1:17891"
        func replaceAddress(_ current: String, with value: String) {
            field.tap()
            if !current.isEmpty {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + value)
        }
        let back = app.navigationBars["高级网络"].buttons.element(boundBy: 0)
        replaceAddress(previous, with: address)
        back.tap()
        entry.tap()
        XCTAssertEqual(field.value as? String, address)
        replaceAddress(address, with: previous)
        app.buttons["完成"].firstMatch.tap()
        back.tap()
        entry.tap()
        XCTAssertEqual(field.value as? String, original)
    }

    func testPrimaryActionsKeepDarkFillInBothAppearances() throws {
        continueAfterFailure = false
        for theme in ["2", "1"] {
            let app = launch(["-uiDemoBookDetail", "-themeMode", theme])
            let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["开始阅读", "继续阅读"])).firstMatch
            XCTAssertTrue(read.waitForExistence(timeout: 20))
            XCTAssertTrue(read.isEnabled)
            try assertReadableDarkFill(read, in: app)
            attach(app, name: "Book detail theme \(theme)")
            app.terminate()
        }
    }

    func testNightReaderSelectionsKeepDarkFillAndReadableLabels() throws {
        continueAfterFailure = false
        let app = launch([
            "-uiDemoReader", "-uiDemoReaderStyle", "-themeMode", "2",
            "-readerTheme", "night", "-readerUseBackgroundImage", "NO",
            "-pageAnim", "0"
        ])
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["标准"].exists)
        try assertReadableDarkFill(app.buttons["随系统"], in: app)
        attach(app, name: "Night reader style panel")
        app.buttons["更多"].tap()
        app.buttons["字体与间距"].tap()
        XCTAssertTrue(app.staticTexts["行间距"].waitForExistence(timeout: 5))
        app.navigationBars["字体与间距"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["页面设置"].waitForExistence(timeout: 5))
        let cover = app.buttons["覆盖"]
        for _ in 0..<16 {
            if cover.exists && cover.isHittable && cover.frame.maxY < app.frame.height - 50 { break }
            app.swipeUp()
        }
        XCTAssertTrue(cover.exists && cover.isHittable)
        try assertReadableDarkFill(cover, in: app)
        attach(app, name: "Night reader animation selection")
    }

    func testDarkAppearanceAcrossTabsAndPresentedEditors() throws {
        continueAfterFailure = false
        let app = launch(["-themeMode", "2"])
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 20))
        for (tab, heading) in [("书架", "阅读，让时间有了形状"), ("发现", "下一本好书，在这里遇见"),
                               ("网站", "在喜欢的网站，读点新鲜事"), ("设置", "按照你的方式阅读")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5))
            attach(app, name: "Dark tab \(tab)")
        }
        scrollTo(app.buttons["profile.globe"], in: app)
        app.buttons["profile.globe"].tap()
        XCTAssertTrue(app.navigationBars["书源管理"].waitForExistence(timeout: 10))
        attach(app, name: "Dark source library")
        app.buttons["更多"].firstMatch.tap()
        app.buttons["新建书源"].tap()
        XCTAssertTrue(app.navigationBars["新建书源"].waitForExistence(timeout: 10))
        let basic = app.buttons["基础"]
        try assertReadableDarkFill(basic, in: app)
        let login = app.buttons["登录"]
        login.tap()
        try assertReadableDarkFill(login, in: app)
        attach(app, name: "Dark source category selection")
        attach(app, name: "Dark presented source editor")
        app.segmentedControls.buttons["JSON"].tap()
        XCTAssertTrue(app.textViews["syntaxCodeEditor"].waitForExistence(timeout: 5))
        attach(app, name: "Dark JSON editor")
        app.textViews["syntaxCodeEditor"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Dark editor keyboard and accessory toolbar")
        let visibleKeyboard = app.keyboards.firstMatch.frame.intersection(app.frame)
        if !visibleKeyboard.isNull && visibleKeyboard.width > 20 && visibleKeyboard.height > 20 {
            let keyboard = try luminances(app.keyboards.firstMatch, in: app)
                // System keycaps vary by iOS version and input language. The
                // lower quartile samples the background, while the median can
                // land on the lighter keycaps of a correctly dark keyboard.
                XCTAssertLessThan(keyboard[keyboard.count / 4], 0.15,
                                  "System keyboard background should follow dark appearance")
        }
        let accessory = app.buttons["syntaxCodeEditor.done"]
        XCTAssertTrue(accessory.exists && accessory.isHittable)
        try assertReadableDarkFill(accessory, in: app)
        app.buttons["@"].tap()
        XCTAssertTrue((app.textViews["syntaxCodeEditor"].value as? String)?.contains("@") == true)
        accessory.tap()
        let dismissed = expectation(for: NSPredicate { _, _ in !accessory.exists || !accessory.isHittable }, evaluatedWith: nil)
        wait(for: [dismissed], timeout: 5)
    }

    func testRetiredStatisticsStartupPreferenceOpensBookshelfAndStatisticsIsReachableFromProfile() throws {
        continueAfterFailure = false
        let app = launch(["-defaultHomePage", "statistics", "-themeMode", "2"])
        let shelf = app.tabBars.buttons["书架"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        XCTAssertTrue(shelf.isSelected)
        app.tabBars.buttons["设置"].tap()
        let settings = app.buttons["profile.power"]
        scrollTo(settings, in: app)
        settings.tap()
        let pages = app.buttons["settings.startupPage"]
        XCTAssertEqual(pages.value as? String, "书架")
        pages.tap()
        XCTAssertFalse(app.buttons["阅读统计"].exists)
        try XCTUnwrap(app.buttons.matching(identifier: "书架").allElementsBoundByIndex.last(where: \.isHittable)).tap()
        app.navigationBars["启动管理"].buttons.element(boundBy: 0).tap()
        let statistics = app.buttons["profile.chart.bar"]
        scrollTo(statistics, in: app)
        statistics.tap()
        let today = app.otherElements["statistics.todayCard"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        try assertReadableDarkFill(today, in: app)
        attach(app, name: "Dark reading statistics")
    }

    func testDarkSettingsRulesAndManagementPages() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "2"])
        XCTAssertFalse(app.buttons["profile.textformat.size"].exists)
        XCTAssertFalse(app.buttons["profile.clock"].exists)
        let routes: [(String, String, String?)] = [
            ("about", "关于", nil),
            ("headphones", "听书设置", nil),
            ("bookmark", "书签", nil),
            ("link", "规则订阅", "新建"),
            ("text.badge.checkmark", "替换净化", "新建规则"),
            ("list.bullet.rectangle", "TXT 目录规则", "新建"),
            ("folder", "本地书籍文件", nil),
            ("power", "启动管理", nil),
            ("doc.text.magnifyingglass", "日志与诊断", nil)
        ]
        for (icon, title, create) in routes {
            let entry = app.buttons["profile.\(icon)"]
            scrollTo(entry, in: app)
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            try captureDarkPage(app, name: "Management \(title)")
            if let create {
                app.buttons[create].firstMatch.tap()
                XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
                try captureDarkPage(app, name: "Editor \(title)")
                if title == "替换净化" {
                    app.segmentedControls.buttons["测试规则"].tap()
                    try captureDarkPage(app, name: "Rule test form")
                }
                app.buttons["取消"].tap()
            }
            if title == "关于" {
                let license = app.buttons["开源许可"]
                scrollTo(license, in: app)
                license.tap()
                XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
                try captureDarkPage(app, name: "Licenses")
                app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            }
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.scrollViews["profile.scroll"].waitForExistence(timeout: 5))
        }
    }

    func testDarkSearchFiltersAndSourceImportSheets() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "search", "-themeMode", "2", "-uiAutomationSearch", "深色外观检查"])
        let cancelSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        if cancelSearch.waitForExistence(timeout: 3) { cancelSearch.tap() }
        XCTAssertTrue(app.buttons["search.options"].waitForExistence(timeout: 10))
        app.buttons["search.options"].tap()
        app.buttons["分组或书源"].tap()
        XCTAssertTrue(app.navigationBars["搜索范围"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Search group filter")
        app.segmentedControls.buttons["书源"].tap()
        try captureDarkPage(app, name: "Search source filter")
        app.buttons["取消"].tap()
        app.terminate()

        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources", "-themeMode", "2"]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源管理"].waitForExistence(timeout: 10))
        app.buttons["排序"].tap()
        XCTAssertTrue(app.buttons["倒序"].waitForExistence(timeout: 5))
        try assertReadableDarkFill(app.buttons["倒序"], in: app)
        attach(app, name: "Source sorting menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        app.buttons["更多"].firstMatch.tap()
        app.buttons["URL 或粘贴 JSON"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Source text import")
    }

    func testDarkRSSAndBlackPhotoViewerInLightAppearance() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "rss", "-themeMode", "2"])
        XCTAssertTrue(app.buttons["websites.favorites"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["websites.search"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["站点"].exists)
        XCTAssertFalse(app.buttons["websites.testMirror"].exists)
        XCTAssertFalse(app.buttons["websites.openMirror"].exists)
        app.tabBars.buttons["发现"].tap()
        let bookManager = app.buttons["explore.manageSources"]
        XCTAssertTrue(app.buttons["explore.search"].isHittable && bookManager.isHittable)
        attach(app, name: "Explore header")
        bookManager.tap()
        XCTAssertTrue(app.navigationBars["书源管理"].waitForExistence(timeout: 5))
        app.tabBars.buttons["网站"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["websites.sourceCount"].exists)
        XCTAssertFalse(app.buttons["websites.sourceCount"].exists)
        app.buttons["网站源管理"].tap()
        let managementBar = app.navigationBars["网站源管理"]
        XCTAssertTrue(managementBar.waitForExistence(timeout: 5))
        managementBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["网站源管理"].isHittable)
        try captureDarkPage(app, name: "网站首页")
        app.buttons["websites.history"].tap()
        XCTAssertTrue(app.navigationBars["网站阅读记录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["设置"].tap()
        let management = app.buttons["profile.network"]
        scrollTo(management, in: app)
        XCTAssertTrue(app.buttons["profile.globe"].exists)
        management.tap()
        XCTAssertTrue(app.navigationBars["网站源管理"].waitForExistence(timeout: 5))
        app.buttons["网站源操作"].tap()
        app.buttons["新建网站源"].tap()
        XCTAssertTrue(app.navigationBars["新建网站源"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "RSS source editor")
        app.terminate()

        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss-photo", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.alerts["图片"].waitForExistence(timeout: 10))
        app.alerts["图片"].buttons["好"].tap()
        let error = app.staticTexts["图片加载失败"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        try assertReadableDarkFill(error, in: app)
        let done = app.buttons["关闭图片预览"]
        XCTAssertTrue(done.exists && done.isEnabled)
        attach(app, name: "Photo viewer floating controls")
        let toolbar = try luminances(done, in: app)
        XCTAssertGreaterThanOrEqual((toolbar[toolbar.count * 98 / 100] + 0.05) / (toolbar[toolbar.count * 2 / 100] + 0.05), 4.5)
        attach(app, name: "Readable photo error on black canvas")
    }

    func testNightReaderMenusAndSettings() throws {
        continueAfterFailure = false
        let app = launch(["-uiDemoReader", "-uiDemoReaderMenu", "-readerTheme", "night", "-themeMode", "2", "-readerUseBackgroundImage", "NO"])
        XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 15))
        try captureDarkPage(app, name: "Night reader menu")
        app.buttons["目录"].tap()
        XCTAssertTrue(app.staticTexts["reader.toc.title"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night table of contents")
        app.buttons["关闭"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night reader settings")
        XCTAssertFalse(app.switches["两端对齐"].exists)
        XCTAssertTrue(app.switches["reader.simplifiedChinese"].exists)
        XCTAssertTrue(app.staticTexts["屏幕方向"].exists)
        XCTAssertTrue(app.switches["阅读时隐藏小横条"].isHittable)
        XCTAssertTrue(app.switches["隐藏状态栏"].isHittable)
    }

    func testAppearanceMenuRestoresSystemAndUpdatesVisiblePage() throws {
        continueAfterFailure = false
        // Launch arguments override writes to UserDefaults; leave themeMode mutable here.
        let app = launch(["-uiDemoTab", "settings"])
        let appearance = app.buttons["profile.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let system = app.buttons["跟随系统"]
        XCTAssertTrue(system.waitForExistence(timeout: 3))
        system.tap()
        let followsSystem = expectation(for: NSPredicate(format: "value == %@", "跟随系统"), evaluatedWith: appearance)
        wait(for: [followsSystem], timeout: 5)
        let initial = try luminances(app, in: app)
        let systemIsDark = initial[initial.count / 2] < 0.15
        for (choice, expectsDark) in [("深色", true), ("浅色", false), ("跟随系统", systemIsDark)] {
            appearance.tap()
            let option = app.buttons[choice]
            if !option.waitForExistence(timeout: 2), app.buttons["外观"].exists { app.buttons["外观"].tap() }
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            let changed = expectation(for: NSPredicate(format: "value == %@", choice), evaluatedWith: appearance)
            wait(for: [changed], timeout: 5)
            let values = try luminances(app, in: app)
            let median = values[values.count / 2]
            if expectsDark { XCTAssertLessThan(median, 0.15) }
            else { XCTAssertGreaterThan(median, 0.6) }
            attach(app, name: "Live appearance \(choice)")
        }
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.maxY < app.frame.height / 2 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func captureDarkPage(_ app: XCUIApplication, name: String) throws {
        let values = try luminances(app, in: app)
        XCTAssertLessThan(values[values.count / 2], 0.15, "Unexpected light page or sheet: \(name)")
        attach(app, name: name)
    }

    // Check both the rendered label contrast and the fill's actual brightness.
    // A readable white surface must still fail the dark appearance regression.
    private func assertReadableDarkFill(_ element: XCUIElement, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let luminances = try luminances(element, in: app, file: file, line: line)
        let low = luminances[luminances.count * 2 / 100]
        let high = luminances[luminances.count * 98 / 100]
        XCTAssertGreaterThanOrEqual((high + 0.05) / (low + 0.05), 4.5,
                                    "Rendered label has insufficient contrast", file: file, line: line)
        XCTAssertLessThan(luminances[luminances.count / 2], 0.15,
                          "Filled control or card is too bright for the dark palette", file: file, line: line)
    }

    private func luminances(_ element: XCUIElement, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [Double] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage, file: file, line: line)
        let scaleX = CGFloat(image.width) / app.frame.width
        let scaleY = CGFloat(image.height) / app.frame.height
        let bounds = element.frame.intersection(app.frame).insetBy(dx: 8, dy: 8)
        let rect = CGRect(x: bounds.minX * scaleX, y: bounds.minY * scaleY,
                          width: bounds.width * scaleX, height: bounds.height * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: rect), file: file, line: line)
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ), file: file, line: line)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let sampleStride = crop.width * crop.height > 250_000 ? 64 : 4
        return stride(from: 0, to: bytes.count, by: sampleStride).map {
            0.2126 * linear(bytes[$0]) + 0.7152 * linear(bytes[$0 + 1]) + 0.0722 * linear(bytes[$0 + 2])
        }.sorted()
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo"] + arguments
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
