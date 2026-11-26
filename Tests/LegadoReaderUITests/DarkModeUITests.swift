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
        app.buttons["导出备份 JSON"].tap()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "存储", "保存"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 12))
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

    func testStorageMaintenanceShowsResultsInTheTappedRow() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["-uiDemoTab", "settings", "-uiDemoOtherSettings"])
        let database = app.buttons["整理数据库"]
        scrollTo(database, in: app)
        database.tap()
        let compacted = expectation(for: NSPredicate(format: "value == %@", "已整理"), evaluatedWith: database)
        wait(for: [compacted], timeout: 10)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach(app, name: "其他设置 · 整理完成")

        let cache = app.buttons["清理网页缓存"]
        cache.tap()
        let confirmation = app.alerts["清理网页缓存？"]
        confirmation.buttons["取消"].tap()
        XCTAssertNotEqual(cache.value as? String, "已清理")
        cache.tap()
        confirmation.buttons["清理"].tap()
        let cleared = expectation(for: NSPredicate(format: "value == %@", "已清理"), evaluatedWith: cache)
        wait(for: [cleared], timeout: 15)
        XCTAssertEqual(database.value as? String, "已整理")
    }

    func testLegacyProfileScrollsBetweenHeaderAndSettings() {
        continueAfterFailure = false
        let app = launch(["-uiDemoTab", "settings", "-themeMode", "2", "-uiLegacyCompatibility"])
        let scroll = app.scrollViews["profile.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        var metrics: [XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        measure(metrics: metrics) {
            scroll.swipeUp(velocity: .fast)
            XCTAssertTrue(app.buttons["profile.gearshape"].isHittable)
            XCTAssertFalse(app.buttons["profile.info.circle"].exists)
            XCTAssertFalse(app.staticTexts["项目与支持"].exists)
            scroll.swipeDown(velocity: .fast)
            XCTAssertTrue(app.buttons["profile.about"].isHittable)
        }
        scroll.swipeUp(velocity: .fast)
        app.buttons["profile.gearshape"].tap()
        XCTAssertTrue(app.navigationBars["其他设置"].waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
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
            "-lineSpacingExtra", "12", "-pageAnim", "0"
        ])
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 20))
        // Expand the sheet so the controls can be inspected without clipping.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        let standard = app.buttons["标准"]
        XCTAssertTrue(standard.waitForExistence(timeout: 5))
        try assertReadableDarkFill(standard, in: app)
        attach(app, name: "Night reader spacing selection")
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
                               ("网站", "在喜欢的网站，读点新鲜事"), ("我的", "按照你的方式阅读")] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5))
            attach(app, name: "Dark tab \(tab)")
        }
        scrollTo(app.buttons["profile.globe"], in: app)
        app.buttons["profile.globe"].tap()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
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
        app.tabBars.buttons["我的"].tap()
        let settings = app.buttons["profile.gearshape"]
        scrollTo(settings, in: app)
        settings.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "启动页面")).firstMatch
        XCTAssertTrue(picker.label.contains("书架") || picker.value as? String == "书架")
        picker.tap()
        XCTAssertFalse(app.buttons["阅读统计"].exists)
        app.navigationBars["其他设置"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.navigationBars["其他设置"].buttons.element(boundBy: 0).tap()
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
            ("waveform", "离线语音包", nil),
            ("bookmark", "书签", nil),
            ("link", "规则订阅", "新建"),
            ("text.badge.checkmark", "净化规则", "新建规则"),
            ("list.bullet.rectangle", "TXT目录规则", "新建"),
            ("folder", "文件管理", nil),
            ("gearshape", "其他设置", nil)
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
                if title == "净化规则" {
                    app.segmentedControls.buttons["测试规则"].tap()
                    try captureDarkPage(app, name: "Rule test form")
                }
                app.buttons["取消"].tap()
            }
            if title == "其他设置" {
                for (entry, destination) in [("网络与缓存设置", "网络与缓存"), ("章节缓存管理", "缓存管理"), ("日志与诊断", "日志与诊断")] {
                    let link = app.buttons[entry]
                    scrollTo(link, in: app)
                    link.tap()
                    XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
                    try captureDarkPage(app, name: "Settings \(destination)")
                    app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
                }
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
        XCTAssertTrue(app.navigationBars["分组或书源"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Search group filter")
        app.segmentedControls.buttons["书源"].tap()
        try captureDarkPage(app, name: "Search source filter")
        app.buttons["取消"].tap()
        app.terminate()

        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources", "-themeMode", "2"]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 5))
        app.tabBars.buttons["网站"].tap()
        let count = app.buttons["websites.sourceCount"]
        XCTAssertTrue(count.isHittable)
        count.tap()
        let managementBar = app.navigationBars["网站源管理"]
        XCTAssertTrue(managementBar.waitForExistence(timeout: 5))
        managementBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["网站源管理"].isHittable)
        try captureDarkPage(app, name: "网站首页")
        app.buttons["websites.history"].tap()
        XCTAssertTrue(app.navigationBars["网站阅读记录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["我的"].tap()
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
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night table of contents")
        app.buttons["关闭"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night reader settings")
        let click = app.buttons["点击区域设置"]
        scrollTo(click, in: app)
        click.tap()
        XCTAssertTrue(app.navigationBars["点击区域设置"].waitForExistence(timeout: 5))
        try captureDarkPage(app, name: "Night click action grid")
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
