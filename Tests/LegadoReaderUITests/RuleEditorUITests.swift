import ImageIO
import XCTest

@MainActor
final class RuleEditorUITests: XCTestCase {
    func testDiscardConfirmationCanReturnToTheEditedRule() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoRules"]
        app.launch()
        app.buttons["新建规则"].tap()
        let name = app.textFields["名称"]
        name.tap()
        name.typeText("Draft")
        app.buttons["取消"].tap()
        let confirmation = app.alerts["放弃未保存的修改？"]
        confirmation.buttons["继续编辑"].tap()
        XCTAssertEqual(name.value as? String, "Draft")
        app.buttons["取消"].tap()
        confirmation.buttons["放弃修改"].tap()
        XCTAssertTrue(app.navigationBars["净化规则"].waitForExistence(timeout: 5))
        XCTAssertFalse(name.exists)
    }

    func testWebsiteHistoryClearConfirmationIsAnchoredToTrashButton() throws {
        guard #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Checks the iPhone toolbar popover on iOS 26")
        }
        continueAfterFailure = false
        let name = "清空确认位置测试"
        let feed = "<rss><channel><item><title>位置测试文章</title><link>https://history.invalid/post</link><description>位置测试正文</description></item></channel></rss>"
        let source = ["sourceName": name, "sourceUrl": "https://history.invalid",
                      "sortUrl": "测试::data:text/xml;base64," + Data(feed.utf8).base64EncodedString()]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: source).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        app.alerts["网站源已导入"].buttons["好"].tap()
        app.buttons["websites.history"].tap()
        let history = app.switches["记录网页浏览历史"]
        let toggle = history.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        let wasEnabled = history.value as? String == "1"
        if !wasEnabled { toggle.tap() }
        app.navigationBars["网站阅读记录"].buttons.element(boundBy: 0).tap()
        app.staticTexts[name].tap()
        app.staticTexts["位置测试文章"].tap()
        XCTAssertTrue(app.webViews.staticTexts["位置测试正文"].waitForExistence(timeout: 5))
        app.navigationBars["位置测试文章"].buttons.element(boundBy: 0).tap()
        app.navigationBars[name].buttons.element(boundBy: 0).tap()
        app.buttons["websites.history"].tap()
        let trash = app.buttons["清空记录"]
        let anchor = trash.frame
        trash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let clear = app.buttons["清空"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(clear.frame.maxX, anchor.midX)
        XCTAssertGreaterThan(clear.frame.minY, anchor.midY)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        XCTAssertFalse(clear.exists)
        XCTAssertEqual(history.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(history.value as? String, "0")
        XCTAssertFalse(clear.exists)
        if wasEnabled { toggle.tap() }
    }

    func testOpeningWebsiteSourceJSONFromBookshelf() throws {
        continueAfterFailure = false
        let name = "导入验证-" + UUID().uuidString.prefix(8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: [["sourceUrl": "https://import-ui.invalid", "sourceName": name, "sourceGroup": "阅读", "ruleArticles": "item"]]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "bookshelf", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        let review = app.navigationBars["导入网站源"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[name].exists)
        review.buttons["导入"].tap()
        let notice = app.alerts["网站源已导入"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        notice.buttons["好"].tap()
        app.tabBars.buttons["网站"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
        app.buttons["网站源管理"].tap()
        XCTAssertTrue(app.textFields["名称、地址或分组"].exists)
        let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分组")).firstMatch
        group.tap()
        app.buttons["阅读"].tap()
        let toggle = app.switches["启用" + name]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        attach(app, name: "网站源管理")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.navigationBars["网站源管理"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["在喜欢的网站，读点新鲜事"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[name].exists)
    }

    func testWebsiteHomeScrollsThroughLargeLibrary() throws {
        continueAfterFailure = false
        let count = 500
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let feed = "<rss><channel><item><title>滚动验证文章</title><link>https://scroll.invalid/article</link></item></channel></rss>"
        let sortURL = "文章::data:text/xml;base64," + Data(feed.utf8).base64EncodedString()
        func name(_ index: Int) -> String { String(format: "滚动站点 %03d", index) }
        let sources: [[String: Any]] = (1...count).map { index in
            ["sourceName": name(index), "sourceUrl": "https://scroll.invalid/\(index)",
             "customOrder": index, "sortUrl": sortURL]
        }
        let file = directory.appendingPathComponent("sites.json")
        try JSONSerialization.data(withJSONObject: sources).write(to: file)
        app.launchEnvironment["LEGADO_UI_RSS_DATABASE"] = directory.appendingPathComponent("rss.sqlite3").path
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        let notice = app.alerts["网站源已导入"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        notice.buttons["好"].tap()
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: notice)
        wait(for: [dismissed], timeout: 5)
        let total = app.buttons["websites.sourceCount"]
        XCTAssertTrue(total.waitForExistence(timeout: 10))
        XCTAssertTrue(total.label.contains("已启用 500 个网站"), total.label)
        let scroll = app.scrollViews["websites.scroll"]
        let first = app.buttons["websites.source.https://scroll.invalid/1"]
        let last = app.buttons["websites.source.https://scroll.invalid/\(count)"]
        XCTAssertTrue(first.isHittable, first.debugDescription)

        var metrics: [XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)]
        if #available(iOS 26, *) { metrics.append(XCTHitchMetric(application: app)) }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: metrics, options: options) {
            scroll.swipeUp(velocity: .fast)
            scroll.swipeUp(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
        }

        let flick = XCUIGestureVelocity(rawValue: 6_000)
        for _ in 0..<100 {
            if last.exists && last.isHittable { break }
            scroll.swipeUp(velocity: flick)
        }
        XCTAssertTrue(last.isHittable)
        last.tap()
        XCTAssertTrue(app.staticTexts["滚动验证文章"].waitForExistence(timeout: 10))
        app.navigationBars[name(count)].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(last.isHittable)

        for _ in 0..<100 {
            if first.exists && first.isHittable && total.isHittable { break }
            scroll.swipeDown(velocity: flick)
        }
        XCTAssertTrue(first.isHittable && total.isHittable)
    }

    func testOnlineSourceImportAndSearchPaginationReachReader() throws {
        let app = try openSearchFixtureBook(pageAnimation: "0")
        let reader = app.textViews["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        XCTAssertTrue((reader.value as? String ?? "").contains("这是搜索分页回归的合成正文"))
        attach(app, name: "Online import, second search page, and chapter reading")
        checkChapterComments(in: app, reader: reader)
    }

    func testContinuousReaderOpensCommentsForTappedChapter() throws {
        let app = try openSearchFixtureBook(pageAnimation: "3")
        XCTAssertTrue(app.collectionViews["reader.continuous"].waitForExistence(timeout: 15))
        let comments = app.buttons.matching(identifier: "reader.chapterEndComments")
        let first = comments.matching(NSPredicate(format: "value == %@", "分页回归第一章")).firstMatch
        let second = comments.matching(NSPredicate(format: "value == %@", "渡口")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        XCTAssertTrue(first.isHittable && second.isHittable)
        second.tap()
        let retry = app.buttons["reader.comments.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        XCTAssertTrue(app.staticTexts["船家的动作正好呼应了第一章。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["开头埋下的伏笔是那枚铜钱。"].exists)
        app.buttons["reader.comments.close"].tap()
        first.tap()
        XCTAssertTrue(app.staticTexts["开头埋下的伏笔是那枚铜钱。"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["船家的动作正好呼应了第一章。"].exists)
    }

    private func openSearchFixtureBook(pageAnimation: String) throws -> XCUIApplication {
        guard let fixture = ProcessInfo.processInfo.environment["LEGADO_SEARCH_FLOW_FIXTURE_URL"] else {
            throw XCTSkip("Use LegadoSearchFlowUITests with scripts/fixtures/search-flow-server.py")
        }
        continueAfterFailure = false
        var deepLink = URLComponents(string: "legado://import/importonline")!
        deepLink.queryItems = [URLQueryItem(name: "src", value: fixture)]
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemoTab", "search", "-uiLegacyCompatibility",
                               "-themeMode", "1", "-precisionSearch", "0", "-pageAnim", pageAnimation,
                               "-uiAutomationImportURL", deepLink.string!]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源导入预检"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["搜索分页回归源"].exists)
        // Re-running uses the same isolated simulator; unchanged existing
        // sources are deliberately unselected by the real import review.
        app.navigationBars["书源导入预检"].buttons["选择"].tap()
        app.buttons["全选"].tap()
        let importButton = app.navigationBars["书源导入预检"].buttons["导入"]
        XCTAssertTrue(importButton.isEnabled)
        importButton.tap()
        let imported = expectation(for: NSPredicate { _, _ in
            !app.navigationBars["书源导入预检"].exists
        }, evaluatedWith: nil)
        wait(for: [imported], timeout: 10)
        if app.alerts.firstMatch.waitForExistence(timeout: 3) { app.alerts.buttons.firstMatch.tap() }
        // Exercise both fixture sources without depending on the device's other subscriptions.
        app.buttons["search.options"].tap()
        app.buttons["分组或书源"].tap()
        let scopeBar = app.navigationBars["分组或书源"]
        XCTAssertTrue(scopeBar.waitForExistence(timeout: 10))
        let group = app.buttons["00 阅读回归"]
        for _ in 0..<30 {
            if group.exists && group.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(group.exists && group.isHittable)
        group.tap()
        scopeBar.buttons["确定"].tap()
        let search = app.textFields["书名或作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        // A fresh query prevents persisted search results masking pagination.
        search.typeText("迁移回归\(UUID().uuidString.prefix(6))\n")
        XCTAssertTrue(app.staticTexts["迁移回归第一页"].waitForExistence(timeout: 15))
        // The last row is already visible while the other source is pending.
        // Completion must recheck pagination without requiring it to reappear.
        let second = app.staticTexts["迁移回归第二页"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        second.tap()
        XCTAssertTrue(app.buttons["开始阅读"].waitForExistence(timeout: 15))
        app.buttons["开始阅读"].tap()
        return app
    }

    private func checkChapterComments(in app: XCUIApplication, reader: XCUIElement) {
        let more = app.buttons["更多"]
        let next = app.buttons["下一章"]
        let close = app.buttons["reader.comments.close"]
        let endComments = app.buttons["reader.chapterEndComments"]
        let firstRows = app.staticTexts.matching(identifier: "开头埋下的伏笔是那枚铜钱。")
        let first = firstRows.firstMatch
        let firstNextPage = app.staticTexts["雨夜的细节让我记住了这个开头。"]
        let second = app.staticTexts["船家的动作正好呼应了第一章。"]
        let retry = app.buttons["reader.comments.retry"]
        let empty = app.descendants(matching: .any)["reader.comments.empty"]

        func showMenu() {
            if !next.isHittable {
                reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(next.waitForExistence(timeout: 5))
        }
        func advance(to body: String) {
            showMenu()
            next.tap()
            let loaded = expectation(for: NSPredicate { _, _ in
                reader.exists && (reader.value as? String)?.contains(body) == true
            }, evaluatedWith: nil)
            wait(for: [loaded], timeout: 12)
        }

        showMenu()
        more.tap()
        app.buttons["reader.chapterComments"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertFalse(second.exists)
        let moreComments = app.buttons["reader.comments.more"]
        moreComments.tap()
        let retryPage = app.buttons["reader.comments.retryMore"]
        XCTAssertTrue(retryPage.waitForExistence(timeout: 10))
        XCTAssertTrue(first.exists)
        XCTAssertFalse(firstNextPage.exists)
        retryPage.tap()
        XCTAssertTrue(firstNextPage.waitForExistence(timeout: 10))
        XCTAssertEqual(firstRows.count, 1)
        XCTAssertFalse(moreComments.exists)
        attach(app, name: "Read both pages of the first chapter's comments")
        close.tap()

        advance(to: "船家在渡口拾到了那枚铜钱。")
        XCTAssertTrue(endComments.waitForExistence(timeout: 5))
        endComments.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(empty.exists)
        XCTAssertFalse(first.exists)
        XCTAssertFalse(firstNextPage.exists)
        retry.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertFalse(first.exists)
        attach(app, name: "Retry and read the second chapter's own comment")
        close.tap()

        advance(to: "旧渡口的太阳沉入了水中。")
        endComments.tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertFalse(first.exists)
        XCTAssertFalse(second.exists)
        XCTAssertFalse(retry.exists)
        close.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
    }

    func testPullingBookshelfStartsDirectoryUpdate() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-defaultHomePage", "bookshelf", "-auto_refresh", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["更多"].firstMatch.waitForExistence(timeout: 10))
        let update = app.alerts["书架更新"]
        XCTAssertFalse(update.exists)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)
        // The demo books have unavailable sources, so checking them presents a result.
        XCTAssertTrue(update.waitForExistence(timeout: 20))
    }

    func testBookshelfGroupSortingSettingsAndOrderEditorAreReachable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-defaultHomePage", "bookshelf", "-themeMode", "1"]
        app.launch()
        let more = app.buttons["更多"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons["本分组设置"].tap()
        XCTAssertTrue(app.buttons["书名"].waitForExistence(timeout: 5))
        app.buttons["书名"].tap()
        more.tap()
        app.buttons["本分组设置"].tap()
        XCTAssertTrue(app.buttons["允许下拉更新"].exists)
        XCTAssertTrue(app.buttons["仅更新已读至最新章的书"].exists)
        app.buttons["调整书籍顺序"].tap()
        XCTAssertTrue(app.navigationBars["调整书籍顺序"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["拖动调整自定义顺序。书籍的自定义顺序在各分组间共用。"].exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
    }

    func testTextListKeepsCachedArticleBodyOutOfRow() throws {
        continueAfterFailure = false
        let name = "城市漫步 · 周末手记"
        let title = "从老街走到河边，一条适合慢慢散步的周末路线"
        let body = "河岸的步道已经开放。"
        let page = "<article><p>\(body)</p></article>"
        let url = "data:text/html;base64," + Data(page.utf8).base64EncodedString()
        let feed = try JSONSerialization.data(withJSONObject: [
            ["title": title, "link": url],
            ["title": "巷口的新书店 [12P]", "link": "https://walk.invalid/bookshop"],
            ["title": "雨后的街景【6P+2V】", "link": "https://walk.invalid/rain"],
            ["title": "沿着旧铁路线走进山里，记录那些慢慢被树影覆盖的站台和桥梁", "link": "https://walk.invalid/rails"],
            ["title": "码头日落", "link": "https://walk.invalid/sunset"]
        ])
        let source = ["sourceName": name, "sourceUrl": "https://walk.invalid",
                      "sortUrl": "手记::data:application/json;base64," + feed.base64EncodedString(),
                      "ruleArticles": "$[*]", "ruleTitle": "$.title", "ruleLink": "$.link",
                      "ruleContent": "@CSS:article@html"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.json")
        try JSONSerialization.data(withJSONObject: source).write(to: file)
        let app = XCUIApplication()
        app.launchEnvironment["LEGADO_UI_RSS_DATABASE"] = directory.appendingPathComponent("rss.sqlite3").path
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        app.alerts["网站源已导入"].buttons["好"].tap()
        app.staticTexts[name].tap()
        let row = app.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.searchFields["源内搜索"].isHittable)
        let taggedRow = app.cells.containing(.staticText, identifier: "巷口的新书店").firstMatch
        XCTAssertTrue(taggedRow.staticTexts["12P"].exists)
        XCTAssertTrue(app.staticTexts["6P+2V"].exists)
        attach(app, name: "无图文章列表")
        let height = row.frame.height
        XCTAssertGreaterThanOrEqual(height, 44)
        app.staticTexts[title].tap()
        XCTAssertTrue(app.webViews.staticTexts[body].waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(row.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", body)).firstMatch.exists)
        XCTAssertEqual(row.frame.height, height, accuracy: 1)
    }

    func testPullPastArticleEndToReadNext() throws {
        continueAfterFailure = false
        let name = "连续阅读-" + UUID().uuidString.prefix(6)
        let origin = "https://next.invalid/" + UUID().uuidString
        let feed = try JSONSerialization.data(withJSONObject: [
            ["title": "第一篇", "link": origin + "/1", "body": "<p>第一篇开头</p><div style='height:140vh'></div><p>第一篇末尾</p>"],
            ["title": "第二篇", "link": origin + "/2", "body": "<p>短文正文</p>"],
            ["title": "第三篇", "link": origin + "/3", "body": "<p>最后一篇正文</p>"]
        ])
        let source = ["sourceName": name, "sourceUrl": origin,
                      "sortUrl": "全部::data:application/json;base64," + feed.base64EncodedString(),
                      "ruleArticles": "$[*]", "ruleTitle": "$.title", "ruleLink": "$.link", "ruleDescription": "$.body"]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: source).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        app.alerts["网站源已导入"].buttons["好"].tap()
        app.staticTexts[name].tap()
        app.staticTexts["第一篇"].firstMatch.tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["第一篇开头"].waitForExistence(timeout: 5))
        let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        func pull(_ points: CGFloat) {
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -points)))
        }
        web.swipeUp()
        XCTAssertTrue(web.staticTexts["第一篇末尾"].isHittable)
        pull(55)
        XCTAssertTrue(web.staticTexts["第一篇末尾"].isHittable)
        pull(200)
        XCTAssertTrue(web.staticTexts["第一篇末尾"].isHittable)
        pull(360)
        XCTAssertTrue(web.staticTexts["短文正文"].waitForExistence(timeout: 6))
        pull(360)
        XCTAssertTrue(web.staticTexts["最后一篇正文"].waitForExistence(timeout: 6))
        pull(360)
        XCTAssertTrue(web.staticTexts["最后一篇正文"].isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["第一篇"].firstMatch.waitForExistence(timeout: 5))
    }

    func testBookCoverOpensSharedPhotoViewer() throws {
        continueAfterFailure = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoBookDetail", "-themeMode", "1"]
        app.launchEnvironment["LEGADO_UI_DEMO_COVER"] = "data:image/png;base64," + (try XCTUnwrap(image.pngData())).base64EncodedString()
        app.launch()

        let cover = app.buttons["查看封面"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        cover.tap()
        let photo = app.images["长夜里的灯"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["保存到照片"].isEnabled)
        XCTAssertFalse(app.buttons["定位到原文"].exists)
        XCTAssertFalse(app.buttons["图片列表"].exists)
        photo.pinch(withScale: 2, velocity: 2)
        XCTAssertNotEqual(photo.value as? String, "100%")
        app.buttons["关闭图片预览"].tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        cover.tap()
        photo.swipeDown()
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
    }

    func testWebsiteArticleImageMode() throws {
        continueAfterFailure = false
        let previousOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = previousOrientation }
        let name = "图集-" + UUID().uuidString.prefix(6)
        let origin = "https://gallery.invalid/" + UUID().uuidString
        func image(_ color: UIColor, size: CGSize) -> UIImage {
            UIGraphicsImageRenderer(size: size).image { renderer in
                color.setFill()
                renderer.fill(CGRect(origin: .zero, size: size))
            }
        }
        let first = "data:image/png;base64," + (try XCTUnwrap(image(.blue, size: CGSize(width: 200, height: 90)).pngData())).base64EncodedString()
        let gif = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(gif, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [UIColor.red, .green] {
            let frame = try XCTUnwrap(image(color, size: CGSize(width: 140, height: 168)).cgImage)
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.32]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let second = "data:image/gif;base64," + gif.base64EncodedString()
        let html = """
        <p>正文插图</p><img alt="横幅配图" width="200" src='\(first)'><br>
        <img alt="竖幅配图" style="width:140px" data-original='\(second)' src='\(second)'>
        <p style="margin:100vh 0">后记</p>
        <a href='#'><img alt="末尾配图" src='\(second)'></a><p style="height:85vh">完</p>
        <img src='\(first)'><img src='\(second)'>
        """
        let feed = try JSONSerialization.data(withJSONObject: [
            ["title": "文字文章", "link": origin + "/text", "body": "<p>只有文字</p>"],
            ["title": "插图文章", "link": origin + "/images", "body": html]
        ])
        let source: [String: Any] = ["sourceUrl": origin, "sourceName": name, "enableJs": false,
            "sortUrl": "测试::data:application/json;base64," + feed.base64EncodedString(),
            "ruleArticles": "$[*]", "ruleTitle": "$.title", "ruleLink": "$.link", "ruleDescription": "$.body"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("gallery.json")
        try JSONSerialization.data(withJSONObject: source).write(to: file)
        app.launchEnvironment["LEGADO_UI_RSS_DATABASE"] = directory.appendingPathComponent("rss.sqlite3").path
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        app.alerts["网站源已导入"].buttons["好"].tap()
        app.staticTexts[name].tap()
        XCTAssertTrue(app.staticTexts["只有文字"].waitForExistence(timeout: 5))
        app.staticTexts["文字文章"].tap()
        XCTAssertTrue(app.webViews.staticTexts["只有文字"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["图片模式"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["插图文章"].tap()
        XCTAssertFalse(app.buttons["图片模式"].exists)
        let landscape = app.webViews.images["横幅配图"]
        let portrait = app.webViews.images["竖幅配图"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 10), app.debugDescription)
        let firstFrame = landscape.frame, secondFrame = portrait.frame
        XCTAssertEqual(firstFrame.width, app.webViews.firstMatch.frame.width - 24, accuracy: 2)
        XCTAssertEqual(firstFrame.minX, secondFrame.minX, accuracy: 1)
        XCTAssertEqual(firstFrame.width, secondFrame.width, accuracy: 1)
        XCTAssertEqual(secondFrame.minY - firstFrame.maxY, 12, accuracy: 2)
        XCTAssertEqual(firstFrame.height, firstFrame.width * 90 / 200, accuracy: 2)
        XCTAssertEqual(secondFrame.height, secondFrame.width * 168 / 140, accuracy: 2)
        portrait.tap()
        XCTAssertTrue(app.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        let photo = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "website.gallery.photo")
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        XCTAssertEqual(photo.frame.height, app.frame.height, accuracy: 2)
        let context = CIContext()
        var sawRed = false, sawGreen = false
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && !(sawRed && sawGreen) {
            let frame = CIImage(cgImage: try XCTUnwrap(app.screenshot().image.cgImage))
            let center = CGRect(x: frame.extent.midX.rounded(.down), y: frame.extent.midY.rounded(.down), width: 1, height: 1)
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(frame, toBitmap: &pixel, rowBytes: 4, bounds: center, format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            sawRed = sawRed || (pixel[0] > 200 && pixel[1] < 50)
            sawGreen = sawGreen || (pixel[1] > 200 && pixel[0] < 50)
        }
        XCTAssertTrue(sawRed && sawGreen, "全屏 GIF 应显示红、绿两帧")
        let locate = app.buttons["定位到原文"]
        let close = app.buttons["关闭图片预览"]
        XCTAssertTrue(locate.isHittable)
        XCTAssertGreaterThan(locate.frame.minX, close.frame.maxX)
        XCTAssertEqual(locate.frame.midY, close.frame.midY, accuracy: 2)
        let save = app.buttons["保存到照片"]
        XCTAssertGreaterThan(save.frame.midY, app.frame.midY)
        XCTAssertGreaterThan(app.staticTexts["2 / 5"].frame.midY, app.frame.midY)
        attach(app, name: "全屏图片预览")
        photo.tap()
        XCTAssertFalse(save.exists)
        XCTAssertFalse(locate.exists)
        photo.pinch(withScale: 2.5, velocity: 2)
        XCTAssertNotEqual(photo.value as? String, "100%")
        photo.swipeUp()
        XCTAssertTrue(photo.isHittable)
        XCTAssertNotEqual(photo.value as? String, "100%")
        photo.pinch(withScale: 0.2, velocity: -2)
        XCTAssertEqual(photo.value as? String, "100%")
        photo.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if systemAlert.waitForExistence(timeout: 2) {
            systemAlert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "OK", "好"])).firstMatch.tap()
        }
        XCTAssertTrue(app.alerts["图片"].staticTexts["已保存到照片"].waitForExistence(timeout: 8))
        app.alerts["图片"].buttons["好"].tap()
        let overview = app.buttons["图片列表"]
        XCTAssertGreaterThan(overview.frame.midX, save.frame.midX)
        overview.tap()
        let tiles = (1...5).map { app.buttons["第 \($0) 张图片"] }
        XCTAssertTrue(tiles[4].waitForExistence(timeout: 5))
        for tile in tiles.prefix(4) {
            XCTAssertEqual(tile.frame.minY, tiles[0].frame.minY, accuracy: 1)
            XCTAssertEqual(tile.frame.width, tile.frame.height, accuracy: 1)
        }
        XCTAssertGreaterThan(tiles[4].frame.minY, tiles[0].frame.maxY)
        XCTAssertEqual(tiles[4].frame.minX, tiles[0].frame.minX, accuracy: 1)
        XCTAssertTrue(tiles[1].isSelected)
        attach(app, name: "四列图片列表")
        tiles[4].tap()
        XCTAssertTrue(app.staticTexts["5 / 5"].waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["4 / 5"].waitForExistence(timeout: 5))
        app.buttons["返回图片列表"].tap()
        XCTAssertTrue(tiles[3].waitForExistence(timeout: 5))
        XCTAssertTrue(tiles[3].isSelected)
        tiles[1].tap()
        XCTAssertTrue(app.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        app.swipeDown()
        app.buttons["返回大图"].tap()
        XCTAssertTrue(app.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["3 / 5"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(portrait.waitForExistence(timeout: 5))
        XCTAssertEqual(portrait.frame.minY, secondFrame.minY, accuracy: 3)
        portrait.tap()
        XCTAssertTrue(app.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["3 / 5"].waitForExistence(timeout: 5))
        locate.tap()
        let last = app.webViews.images["末尾配图"]
        let viewport = app.webViews.firstMatch
        let centered = NSPredicate { _, _ in last.isHittable && abs(last.frame.midY - viewport.frame.midY) < 30 }
        wait(for: [expectation(for: centered, evaluatedWith: nil)], timeout: 6)
        let originalY = last.frame.minY
        last.tap()
        XCTAssertTrue(app.staticTexts["3 / 5"].waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertEqual(last.frame.minY, originalY, accuracy: 3)
        last.tap()
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["2 / 5"].waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertEqual(last.frame.minY, originalY, accuracy: 3)
    }

    func testArticleVideosOpenInGesturePlayer() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LEGADO_RSS_UI_FIXTURE_URL"],
              let base = URL(string: fixture)?.deletingLastPathComponent() else {
            throw XCTSkip("Use the local RSS fixture server")
        }
        continueAfterFailure = false
        let run = UUID().uuidString.prefix(8)
        let article = base.appendingPathComponent("media/article-\(run)").absoluteString
        let paragraphs = (1...18).map { "<p style='margin:30px;font-size:24px'>样片说明 · 第\($0)段</p>" }.joined()
        let html = "<meta name='viewport' content='width=device-width'><p>视频样片</p><video src='gesture.mov'></video><video><source src='gesture.mp4'></video><video src='gesture.m3u8'></video>" + paragraphs + "<p>正文末尾</p>"
        let feed = try JSONSerialization.data(withJSONObject: [["title": "手势测试", "link": article, "body": html]])
        let name = "视频验证-\(run)"
        let source = ["sourceUrl": article, "sourceName": name, "sortUrl": "样片::data:application/json;base64," + feed.base64EncodedString(),
                      "ruleArticles": "$[*]", "ruleTitle": "$.title", "ruleLink": "$.link", "ruleDescription": "$.body"]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: source).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        app.alerts["网站源已导入"].buttons["好"].tap()
        // Open the saved source in a normal session so a fullscreen round trip cannot replay the import.
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss"]
        app.launch()
        app.staticTexts[name].tap()
        app.staticTexts["手势测试"].tap()
        let player = app.descendants(matching: .any)["website.video.player"].firstMatch
        let videoSurface = player.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.39))
        let speed = app.buttons["播放速度"]
        func showControls() {
            for _ in 0..<2 {
                if speed.waitForExistence(timeout: 0.6), speed.isHittable { return }
                videoSurface.tap()
            }
            XCTAssertTrue(speed.waitForExistence(timeout: 2) && speed.isHittable)
        }
        let clock = app.staticTexts["website.video.time"]
        func elapsed() throws -> Int {
            showControls()
            let time = try XCTUnwrap(clock.label.components(separatedBy: " / ").first)
            return time.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        func visitDesktop() {
            XCUIDevice.shared.press(.home)
            let desktop = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            XCTAssertTrue(desktop.wait(for: .runningForeground, timeout: 5))
            let pip = desktop.descendants(matching: .any).matching(NSPredicate(
                format: "identifier CONTAINS[c] 'PictureInPicture' OR label IN %@",
                ["Picture in Picture", "画中画"]
            )).firstMatch
            XCTAssertFalse(pip.waitForExistence(timeout: 2))
            app.activate()
        }
        for index in 1...3 {
            let video = app.webViews.links["▶ 播放视频 \(index)"]
            XCTAssertTrue(video.waitForExistence(timeout: 12))
            video.tap()
            XCTAssertTrue(player.waitForExistence(timeout: 5))
            if UIDevice.current.userInterfaceIdiom == .phone && app.frame.height > app.frame.width {
                XCTAssertLessThan(player.frame.minY, app.frame.height * 0.25)
                XCTAssertEqual(player.frame.width, app.frame.width, accuracy: 2)
            }
            showControls()
            XCTAssertTrue(clock.waitForExistence(timeout: 10))
            let ready = expectation(for: NSPredicate { _, _ in clock.label.hasSuffix("01:00") || clock.label.hasSuffix("00:59") }, evaluatedWith: nil)
            wait(for: [ready], timeout: 10)
            if index == 1 {
                showControls()
                speed.tap()
                app.buttons["1.5 x"].tap()
                showControls()
                let slider = app.sliders["播放进度"]
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
                XCTAssertEqual(try elapsed(), 45, accuracy: 4)
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
                XCTAssertEqual(try elapsed(), 15, accuracy: 4)
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.1, thenDragTo:
                    slider.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
                let afterDrag = try elapsed()
                XCTAssertGreaterThan(afterDrag, 30)
                player.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.45)).press(forDuration: 0.1, thenDragTo:
                    player.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45)))
                XCTAssertLessThan(try elapsed(), 8)

                let half = player.frame
                let dragStart = player.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.5))
                dragStart.press(forDuration: 0.1, thenDragTo: dragStart.withOffset(CGVector(dx: 4, dy: 35)))
                let returnedToTop = NSPredicate { _, _ in abs(player.frame.minY - half.minY) < 2 }
                wait(for: [expectation(for: returnedToTop, evaluatedWith: nil)], timeout: 3)
                dragStart.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.85)))
                let restore = app.buttons["还原为顶部半屏"]
                XCTAssertTrue(restore.waitForExistence(timeout: 3))
                XCTAssertEqual(player.frame.width, min(app.frame.width * 0.48, 220), accuracy: 2)
                XCTAssertGreaterThan(player.frame.midX, app.frame.midX)
                XCTAssertGreaterThan(player.frame.midY, app.frame.midY)
                XCTAssertTrue(app.webViews.links["▶ 播放视频 2"].isHittable)
                let initial = player.frame
                let start = player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let target = start.withOffset(CGVector(dx: -initial.width * 0.65, dy: -initial.height * 2))
                start.press(forDuration: 0.15, thenDragTo: target)
                let moved = player.frame
                XCTAssertEqual(moved.minX, initial.minX - initial.width * 0.65, accuracy: 14)
                XCTAssertEqual(moved.minY, initial.minY - initial.height * 2, accuracy: 14)
                XCTAssertTrue(player.buttons["暂停"].isHittable)
                visitDesktop()
                XCTAssertTrue(player.buttons["播放"].waitForExistence(timeout: 5))
                XCTAssertEqual(player.frame.minX, moved.minX, accuracy: 2)
                XCTAssertEqual(player.frame.minY, moved.minY, accuracy: 2)
                let web = app.webViews.firstMatch
                let lower = web.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.8))
                let upper = web.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.25))
                let articleEnd = web.staticTexts["正文末尾"]
                for _ in 0..<4 {
                    lower.press(forDuration: 0.1, thenDragTo: upper)
                    if articleEnd.exists && articleEnd.isHittable { break }
                }
                XCTAssertTrue(articleEnd.isHittable)
                XCTAssertEqual(player.frame.minY, moved.minY, accuracy: 2)
                for _ in 0..<4 {
                    upper.press(forDuration: 0.1, thenDragTo: lower)
                    if web.links["▶ 播放视频 2"].isHittable { break }
                }
                XCTAssertFalse(app.buttons["全屏"].exists)
                restore.tap()
                func waitForHalf() {
                    let docked = expectation(for: NSPredicate { _, _ in
                        let frame = player.frame
                        return abs(frame.minY - half.minY) < 2 && abs(frame.height - half.height) < 2
                    }, evaluatedWith: nil)
                    wait(for: [docked], timeout: 6)
                }
                waitForHalf()
                let pausedAt = try elapsed()
                app.buttons["全屏"].tap()
                showControls()
                let exit = app.buttons["退出全屏"]
                XCTAssertTrue(exit.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(app.frame.width, app.frame.height)
                XCTAssertGreaterThan(player.frame.width, player.frame.height)
                XCTAssertGreaterThan(player.frame.height, app.frame.height * 0.8)
                XCTAssertEqual(try elapsed(), pausedAt, accuracy: 1)
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
                XCTAssertEqual(try elapsed(), 15, accuracy: 2)
                player.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).press(forDuration: 0.1, thenDragTo:
                    player.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45)))
                let scrubbedWhilePaused = try elapsed()
                XCTAssertEqual(scrubbedWhilePaused, 39, accuracy: 3)
                exit.tap()
                waitForHalf()
                XCTAssertEqual(try elapsed(), scrubbedWhilePaused, accuracy: 1)
                XCTAssertEqual(player.frame.width, app.frame.width, accuracy: 2)
            } else if index == 3 {
                let slider = app.sliders["播放进度"]
                func revealSlider() {
                    for _ in 0..<2 {
                        if slider.exists && slider.isHittable { return }
                        videoSurface.tap()
                    }
                    XCTAssertTrue(slider.exists && slider.isHittable)
                }
                func verifyPlayback(from target: Int) throws {
                    XCTAssertEqual(try elapsed(), target, accuracy: 4)
                    let moving = NSPredicate { _, _ in
                        guard let current = try? elapsed() else { return false }
                        return (target + 2...target + 8).contains(current)
                    }
                    wait(for: [expectation(for: moving, evaluatedWith: nil)], timeout: 8)
                }
                revealSlider()
                XCTAssertTrue(slider.isEnabled)
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
                try verifyPlayback(from: 45)
                revealSlider()
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 0.1, thenDragTo:
                    slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
                try verifyPlayback(from: 15)
            } else {
                showControls()
                app.buttons["全屏"].tap()
                let exit = app.buttons["退出全屏"]
                XCTAssertTrue(exit.waitForExistence(timeout: 5))
                visitDesktop()
                showControls()
                XCTAssertTrue(exit.isHittable)
                exit.tap()
                XCTAssertTrue(player.buttons["关闭视频"].waitForExistence(timeout: 5))
            }
            showControls()
            player.buttons["关闭视频"].tap()
            let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: player)
            wait(for: [closed], timeout: 5)
            XCTAssertTrue(app.webViews.staticTexts["视频样片"].waitForExistence(timeout: 5))
        }
    }

    func testWebsiteGridPullToRefreshAndAutomaticNextPage() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LEGADO_RSS_UI_FIXTURE_URL"] else {
            throw XCTSkip("Set LEGADO_RSS_UI_FIXTURE_URL to the local website fixture")
        }
        let token = UUID().uuidString
        let base = URL(string: fixture)!.deletingLastPathComponent().appendingPathComponent("grid/" + token, isDirectory: true)
        let name = "分页验证-" + token.prefix(8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(token + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let config: [String: Any] = ["sourceUrl": base.absoluteString, "sourceName": name,
            "articleStyle": 3, "preload": true, "ruleArticles": "@css:#posts > .post.grid",
            "ruleTitle": "@css:h3 a@text", "ruleLink": "@css:h3 a@href",
            "ruleNextPage": "@css:.pagination .next-page a[href]@href"]
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-uiAutomationImportURL", file.absoluteString]
        app.launch()
        app.navigationBars["导入网站源"].buttons["导入"].tap()
        app.alerts["网站源已导入"].buttons["好"].tap()
        app.staticTexts[name].tap()
        XCTAssertTrue(app.staticTexts["第1次首页"].waitForExistence(timeout: 10))
        let title = app.navigationBars[name].staticTexts[name]
        let search = app.searchFields["源内搜索"]
        XCTAssertTrue(title.isHittable)
        XCTAssertTrue(search.isHittable)
        XCTAssertLessThanOrEqual(title.frame.maxY, search.frame.minY)
        let longTitle = String(repeating: "一段需要换行的文章标题", count: 6)
        let first = app.buttons.containing(.staticText, identifier: longTitle).firstMatch.frame
        let secondCard = app.buttons.containing(.staticText, identifier: "第1次首页").firstMatch.frame
        let third = app.buttons.containing(.staticText, identifier: "文章 1").firstMatch.frame
        XCTAssertGreaterThan(first.height, secondCard.height)
        XCTAssertEqual(third.minX, secondCard.minX, accuracy: 1)
        XCTAssertEqual(third.minY - secondCard.maxY, secondCard.minX - first.maxX, accuracy: 1)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.33))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
        top.press(forDuration: 0.1, thenDragTo: bottom)
        XCTAssertTrue(app.staticTexts["第2次首页"].waitForExistence(timeout: 10))
        let second = app.staticTexts["第二页文章"]
        for _ in 0..<10 {
            if second.exists && second.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["网站操作失败"].exists)
    }

    func testRSSSearchSubmissionPaginationAndFavorites() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LEGADO_RSS_UI_FIXTURE_URL"] else {
            throw XCTSkip("Set LEGADO_RSS_UI_FIXTURE_URL to the local RSS fixture source URL")
        }
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launchEnvironment["LEGADO_UI_RSS_DATABASE"] = directory.appendingPathComponent("rss.sqlite3").path
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "rss", "-themeMode", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["网站源管理"].waitForExistence(timeout: 20))
        app.buttons["网站源管理"].tap()
        XCTAssertTrue(app.navigationBars["网站源管理"].waitForExistence(timeout: 5))
        // Replace an existing source in this launch, so a cached navigation
        // destination cannot silently keep using the previous content rules.
        for url in [fixture + "?legacy=1", fixture] {
            app.buttons["网站源操作"].tap()
            app.buttons["URL或粘贴JSON"].tap()
            let editor = app.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            editor.typeText(url)
            app.navigationBars["导入网站源"].buttons["导入"].tap()
            let dismissed = expectation(for: NSPredicate { _, _ in !app.navigationBars["导入网站源"].exists }, evaluatedWith: nil)
            wait(for: [dismissed], timeout: 10)
        }
        let source = app.staticTexts["RSS 全流程测试"]
        source.tap()
        let enabled = app.switches["启用"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "0")
        app.buttons["保存"].tap()
        app.navigationBars["网站源管理"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["网站源管理"].waitForExistence(timeout: 5))
        XCTAssertFalse(source.exists)
        app.buttons["网站源管理"].tap()
        source.tap()
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "1")
        app.buttons["保存"].tap()
        app.navigationBars["网站源管理"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        XCTAssertTrue(app.staticTexts["首页文章"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["调试"].exists)
        let left = app.buttons.containing(.staticText, identifier: "首页文章").firstMatch
        let right = app.buttons.containing(.staticText, identifier: "短标题").firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(left.frame.minX, app.frame.minX)
        XCTAssertLessThan(left.frame.maxX, right.frame.minX)
        XCTAssertLessThanOrEqual(right.frame.maxX, app.frame.maxX)

        app.buttons["编辑"].tap()
        let name = app.textFields["名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("-A")
        let renamed = "RSS 全流程测试-A"
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 5))
        app.navigationBars[renamed].buttons["网站"].tap()
        let renamedSource = app.staticTexts[renamed]
        XCTAssertTrue(renamedSource.waitForExistence(timeout: 5))
        XCTAssertFalse(source.exists)
        renamedSource.tap()
        XCTAssertTrue(app.staticTexts["首页文章"].waitForExistence(timeout: 5))
        let fresh = app.staticTexts["下拉刷新后的文章"]
        XCTAssertFalse(fresh.exists)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        top.press(forDuration: 0.08, thenDragTo: bottom)
        XCTAssertTrue(fresh.waitForExistence(timeout: 10))
        let search = app.searchFields["源内搜索"]
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("needle\n")
        let result = app.staticTexts["搜索结果 needle 第1页"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let secondPage = app.staticTexts["搜索结果 needle 第2页"]
        XCTAssertFalse(secondPage.exists)
        let loading = app.descendants(matching: .any)["website.pagination.loading"].firstMatch
        for _ in 0..<8 {
            if loading.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(loading.exists)
        let finishedLoading = expectation(for: NSPredicate { _, _ in !loading.exists }, evaluatedWith: nil)
        wait(for: [finishedLoading], timeout: 10)
        for _ in 0..<5 {
            if secondPage.exists && secondPage.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(secondPage.isHittable)
        for _ in 0..<12 {
            if result.exists && result.isHittable { break }
            app.swipeDown()
        }
        result.tap()
        XCTAssertTrue(app.webViews.staticTexts["第1次加载的订阅正文"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["搜索结果 needle 第1页"].exists)
        app.buttons["阅读操作"].tap()
        app.buttons["刷新"].tap()
        XCTAssertTrue(app.webViews.staticTexts["第2次加载的订阅正文"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["刷新后的网页标题"].waitForExistence(timeout: 5))
        if app.buttons["取消收藏"].exists { app.buttons["取消收藏"].tap() }
        XCTAssertTrue(app.buttons["收藏"].waitForExistence(timeout: 5))
        app.buttons["收藏"].tap()
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5))
        app.navigationBars["刷新后的网页标题"].buttons.element(boundBy: 0).tap()
        let cancelSearch = app.navigationBars[renamed].buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "取消", "Close", "关闭"]
        )).firstMatch
        if cancelSearch.exists { cancelSearch.tap() }
        app.navigationBars[renamed].buttons["网站"].tap()
        XCTAssertTrue(app.buttons["websites.favorites"].waitForExistence(timeout: 5))
        app.buttons["websites.favorites"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        attach(app, name: "RSS search article saved to favorites")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 10))
        app.buttons["websites.favorites"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let favorites = app.navigationBars["网页收藏"]
        XCTAssertTrue(favorites.exists)
        let favoritesSearch = app.textFields["搜索文章"]
        XCTAssertTrue(favoritesSearch.isHittable)
        favoritesSearch.tap()
        favoritesSearch.typeText("unmatched")
        XCTAssertFalse(result.exists)
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(result.exists)
        favorites.buttons.element(boundBy: 0).tap()
        app.buttons["websites.history"].tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let historyToggle = app.switches["记录网页浏览历史"]
        XCTAssertEqual(historyToggle.value as? String, "1")
        historyToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        app.navigationBars["网站阅读记录"].buttons.element(boundBy: 0).tap()
        renamedSource.tap()
        app.staticTexts["首页文章"].tap()
        XCTAssertTrue(app.navigationBars["首页文章"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["websites.history"].tap()
        XCTAssertTrue(historyToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(historyToggle.value as? String, "0")
        XCTAssertFalse(app.staticTexts["首页文章"].exists)
        XCTAssertTrue(result.exists)
        historyToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    func testBookshelfFilePickerImportsTXTAndEPUBAndDisablesJSON() throws {
        try exerciseLocalBookImport(fromFileManagement: false)
    }

    func testFileManagementFilePickerImportsTXTAndEPUBAndDisablesJSON() throws {
        try exerciseLocalBookImport(fromFileManagement: true)
    }

    func testImportedTXTEntersReaderAndReturnsToShelf() throws {
        let app = try importLocalBooks(fromFileManagement: false)
        let txtBook = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Book")).firstMatch
        txtBook.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["发现"].exists && app.tabBars.buttons["发现"].isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(app.tabBars.buttons["发现"].waitForExistence(timeout: 5))
    }

    private func importLocalBooks(fromFileManagement: Bool) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-themeMode", "1", "-bookshelfLayout", "grid3", "-pageAnim", "0"]
        if fromFileManagement {
            app.launchArguments += ["-uiDemoTab", "settings", "-uiDemoFiles"]
        }
        app.launchArguments += ["-defaultEPUBReadingMode", "original"]
        app.launch()
        let importTitle = fromFileManagement ? "导入 TXT / EPUB" : "本地书"
        let more = fromFileManagement
            ? app.navigationBars["文件管理"].buttons["更多"].firstMatch
            : app.buttons["更多"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons[importTitle].firstMatch.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        let closed = expectation(for: NSPredicate { _, _ in !cancel.exists }, evaluatedWith: nil)
        wait(for: [closed], timeout: 10)
        more.tap()
        app.buttons[importTitle].firstMatch.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))

        let pickerFiles = app.collectionViews["File View"].cells
        let txt = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Book")).firstMatch
        openImportFixtureFolder(in: app)
        XCTAssertTrue(txt.waitForExistence(timeout: 10))
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Import", "导入"])).firstMatch
        for name in ["JSON-Source", "JSON-Uppercase"] {
            let json = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(json.waitForExistence(timeout: 5))
            XCTAssertFalse(json.isEnabled)
            json.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(open.exists && open.isEnabled, "JSON must not be selectable as a local book")
        }
        txt.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let uppercase = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Uppercase")).firstMatch
        XCTAssertTrue(uppercase.waitForExistence(timeout: 5))
        uppercase.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let epub = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "EPUB-Book")).firstMatch
        XCTAssertTrue(epub.waitForExistence(timeout: 5))
        XCTAssertTrue(epub.isEnabled)
        epub.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        attach(app, name: "TXT selectable and JSON excluded")
        open.tap()

        if fromFileManagement {
            XCTAssertTrue(app.navigationBars["文件管理"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.alerts["文件操作失败"].waitForExistence(timeout: 3), app.debugDescription)
            app.tabBars.buttons["书架"].tap()
        } else {
            XCTAssertTrue(app.navigationBars["导入本地书"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.staticTexts["JSON-Source.json"].exists)
            XCTAssertFalse(app.staticTexts["JSON-Uppercase.JSON"].exists)
            XCTAssertTrue(app.staticTexts["TXT-Book.txt"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["TXT-Uppercase.TXT"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["导入"].tap()
        }
        // Repeated runs preserve managed files and correctly add a numeric suffix.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Book")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Uppercase")).firstMatch.waitForExistence(timeout: 15))
        let epubBook = app.staticTexts["EPUB 导入测试"].firstMatch
        XCTAssertTrue(epubBook.waitForExistence(timeout: 15))
        attach(app, name: "Local TXT and EPUB books imported onto shelf")
        return app
    }

    private func exerciseLocalBookImport(fromFileManagement: Bool) throws {
        let app = try importLocalBooks(fromFileManagement: fromFileManagement)
        let epubBook = app.staticTexts["EPUB 导入测试"].firstMatch
        if !fromFileManagement {
            let txtBook = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Book")).firstMatch
            txtBook.press(forDuration: 1)
            app.buttons["书籍信息"].tap()
            let operations = app.buttons["本地书操作"]
            XCTAssertTrue(operations.waitForExistence(timeout: 10))
            operations.tap()
            app.buttons["重新分章"].tap()
            XCTAssertTrue(app.navigationBars["重新分章"].waitForExistence(timeout: 5))
            app.buttons["localTocRule.none"].tap()
            app.buttons["重建目录"].tap()
            let completed = expectation(for: NSPredicate { _, _ in !app.navigationBars["重新分章"].exists }, evaluatedWith: nil)
            wait(for: [completed], timeout: 15)
            XCTAssertTrue(app.staticTexts["1 章"].waitForExistence(timeout: 10))
            attach(app, name: "TXT rebuilt on the same shelf entry")
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(epubBook.waitForExistence(timeout: 10))
        }
        epubBook.tap()
        let reader = app.webViews.firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        XCTAssertTrue(reader.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "这是 EPUB 导入后的第一章正文")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(reader.images["测试插图"].waitForExistence(timeout: 10))
        attach(app, name: "EPUB original layout with inline illustration")
        app.buttons["目录"].tap()
        app.buttons["折叠正文篇"].tap()
        XCTAssertFalse(app.buttons["第二章 EPUB"].exists)
        app.buttons["折叠上卷"].tap()
        app.buttons["完成"].tap()
        app.buttons["目录"].tap()
        XCTAssertFalse(app.buttons["展开正文篇"].exists)
        app.buttons["展开上卷"].tap()
        XCTAssertFalse(app.buttons["第二章 EPUB"].exists)
        app.buttons["展开正文篇"].tap()
        app.buttons["第二章 EPUB"].firstMatch.tap()
        let secondChapter = reader.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "目录锚点跳转成功")).firstMatch
        XCTAssertTrue(secondChapter.waitForExistence(timeout: 10))
        attach(app, name: "EPUB original layout after TOC navigation")
        if !fromFileManagement {
            app.buttons["排版"].tap()
            setEPUBMode("文字阅读与朗读", in: app)
            app.terminate()
            app.launchArguments.removeLast(2)
            app.launch()
            epubBook.tap()
            let text = app.textViews["reader.text"]
            XCTAssertTrue(text.waitForExistence(timeout: 15))
            XCTAssertTrue((text.value as? String)?.contains("目录锚点跳转成功") == true)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.buttons["更多"].tap()
            app.buttons["EPUB 原书排版"].tap()
            XCTAssertTrue(reader.waitForExistence(timeout: 15))
            app.buttons["EPUB 更多"].tap()
            app.buttons["文字阅读与朗读"].tap()
            XCTAssertTrue(text.waitForExistence(timeout: 15))
            XCTAssertTrue((text.value as? String)?.contains("目录锚点跳转成功") == true)
            app.terminate()
            app.launch()
            // A manual switch affects only the open book. Verify the saved preference after relaunch.
            epubBook.tap()
            XCTAssertTrue(text.waitForExistence(timeout: 15))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.buttons["设置"].tap()
            setEPUBMode("EPUB 原书排版", in: app, expectedCurrent: "文字阅读与朗读")
        }
    }

    private func setEPUBMode(_ title: String, in app: XCUIApplication, expectedCurrent: String? = nil) {
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "默认 EPUB 阅读模式")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if let expectedCurrent {
            XCTAssertTrue(picker.label.contains(expectedCurrent) || picker.value as? String == expectedCurrent)
        }
        picker.tap()
        app.buttons[title].firstMatch.tap()
        app.buttons["完成"].tap()
    }

    func testJSONFilePickerOffersOpenAndImportsSelectedFiles() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources"]
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["从文件导入"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        let pickerClosed = expectation(for: NSPredicate { _, _ in
            !cancel.exists && app.navigationBars["书源"].buttons["更多"].isHittable
        }, evaluatedWith: nil)
        wait(for: [pickerClosed], timeout: 10)
        app.buttons["更多"].firstMatch.tap()
        app.buttons["从文件导入"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))

        let json = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "JSON-Source")).firstMatch
        let fixtures = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "书源导入测试")).firstMatch
        if !json.waitForExistence(timeout: 3) {
            if !fixtures.exists {
                let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览", "Locations", "位置"])).firstMatch
                if browse.exists { browse.tap() }
                if !fixtures.waitForExistence(timeout: 2) {
                    let local = app.descendants(matching: .any).matching(NSPredicate(
                        format: "label CONTAINS %@ OR label CONTAINS %@ OR label == %@", "我的 iPhone", "我的iPhone", "On My iPhone"
                    )).firstMatch
                    if !local.waitForExistence(timeout: 5) { print("[SourceFilePicker] \(app.debugDescription)") }
                    XCTAssertTrue(local.exists)
                    local.tap()
                }
            }
            XCTAssertTrue(fixtures.waitForExistence(timeout: 10), "Run sh scripts/prepare-source-import-fixture.sh <simulator-UUID> before this test")
            fixtures.tap()
        }
        XCTAssertTrue(json.waitForExistence(timeout: 10))
        json.tap()
        let uppercase = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "JSON-Uppercase")).firstMatch
        XCTAssertTrue(uppercase.waitForExistence(timeout: 5))
        uppercase.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Import", "导入"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(open.isEnabled)
        attach(app, name: "JSON files selected with Open available")
        open.tap()

        let reviewAppeared = app.navigationBars["书源导入预检"].waitForExistence(timeout: 15)
        if !reviewAppeared {
            print("[SourceFilePickerAfterOpen] \(app.debugDescription)")
            attach(app, name: "File picker after Open")
        }
        XCTAssertTrue(reviewAppeared)
        XCTAssertTrue(app.buttons["导入"].isEnabled)
        attach(app, name: "JSON import review after file picker dismissal")
        app.buttons["导入"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { app.alerts.buttons["好"].tap() }
        XCTAssertTrue(app.staticTexts["文件导入 JSON 测试"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["文件导入大写扩展名测试"].exists)
    }

    func testSourceFormJSONSwitchKeepsHighlightedTextAndSaves() throws {
        try exerciseSourceEditor(usesLegacyUI: false)
    }

    func testLegacySourceFormJSONSwitchKeepsHighlightedTextAndSaves() throws {
        try exerciseSourceEditor(usesLegacyUI: true)
    }

    private func exerciseSourceEditor(usesLegacyUI: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "sources"]
        if usesLegacyUI { app.launchArguments.append("-uiLegacyCompatibility") }
        app.launch()
        XCTAssertTrue(app.navigationBars["书源"].waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap()
        app.buttons["新建书源"].tap()
        XCTAssertTrue(app.navigationBars["新建书源"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书源名称")).firstMatch.tap()
        let editor = app.textViews["syntaxCodeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("UI Source")
        attach(app, name: "Typed source name")
        XCTAssertEqual(editor.value as? String, "UI Source")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "书源地址")).firstMatch.tap()
        editor.tap(); editor.typeText("https://ui-editor.test")
        XCTAssertEqual(editor.value as? String, "https://ui-editor.test")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["JSON"].tap()
        attach(app, name: "Source JSON editor")
        let json = editor.value as? String ?? ""
        XCTAssertTrue(json.contains("UI Source"), "Actual JSON: \(json)")
        XCTAssertTrue(json.contains("https://ui-editor.test"), "Actual JSON: \(json)")
        app.segmentedControls.buttons["字段编辑"].tap()
        app.buttons["保存"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { app.alerts.buttons["好"].tap() }
        XCTAssertTrue(app.staticTexts["UI Source"].waitForExistence(timeout: 10))
    }

    func testPurificationDraftRunsThroughReaderPipeline() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoRules"]
        app.launch()
        XCTAssertTrue(app.buttons["新建规则"].waitForExistence(timeout: 20))
        app.buttons["新建规则"].tap()
        app.textFields["名称"].tap(); app.textFields["名称"].typeText("UI Rule")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "匹配内容")).firstMatch.tap()
        let editor = app.textViews["syntaxCodeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(".")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["测试规则"].tap()
        app.buttons["运行当前草稿"].tap()
        XCTAssertTrue(app.staticTexts["规则已生效"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["（正文为空）"].exists)
        attach(app, name: "Purification test result")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["净化规则"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UI Rule"].exists)
    }

    func testCancellingBookSearchKeepsScopeCardInPlace() throws {
        guard #available(iOS 17.1, *) else { throw XCTSkip("Requires search presentation toolbar behavior") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "bookshelf"]
        app.launch()
        app.buttons["搜索"].tap()

        let field = app.searchFields["书名或作者"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("abc")
        let scope = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "搜索范围")).firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        let editingY = scope.frame.minY
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
        cancel.tap()

        XCTAssertFalse(cancel.exists)
        XCTAssertEqual(scope.frame.minY, editingY, accuracy: 1)
        scope.tap()
        XCTAssertTrue(app.navigationBars["分组或书源"].waitForExistence(timeout: 5))
    }

    func testEditingEmptySearchResultRestoresKeyword() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "search"]
        app.launch()
        let search = app.searchFields["书名或作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("美利坚国父\n")
        let edit = app.buttons["修改关键词"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["未找到“美利坚国父”"].exists)
        attach(app, name: "搜索无结果")
        edit.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "美利坚国父")
    }

    func testLegacySearchSubmitsAndFiltersSources() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "search", "-uiLegacyCompatibility"]
        app.launch()
        let search = app.textFields["书名或作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        app.buttons["搜索选项"].tap()
        app.buttons["分组或书源"].tap()
        XCTAssertTrue(app.navigationBars["分组或书源"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["书源"].tap()
        let filter = app.textFields["筛选书源"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        filter.typeText("no-match")
        XCTAssertFalse(app.staticTexts["经典文学馆"].exists)
        app.navigationBars["分组或书源"].buttons["取消"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("legacy-probe\n")
        XCTAssertTrue(app.buttons["修改关键词"].waitForExistence(timeout: 30))
        app.buttons["修改关键词"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "Legacy search after keyboard submission")
    }

    func testLegacyAboutCanPresentSystemShareSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoAbout", "-uiLegacyCompatibility"]
        app.launch()
        let share = app.buttons["分享版本信息"]
        XCTAssertTrue(share.waitForExistence(timeout: 20))
        share.tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        let appeared = copy.waitForExistence(timeout: 10)
        if !appeared { print("[Share sheet hierarchy] \(app.debugDescription)") }
        XCTAssertTrue(appeared)
        attach(app, name: "Legacy system share sheet")
    }

    func testLegacyRuleMenuCanExportThroughSystemShareSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoRules", "-uiLegacyCompatibility"]
        app.launch()
        XCTAssertTrue(app.navigationBars["净化规则"].waitForExistence(timeout: 20))
        app.buttons["更多"].tap()
        app.buttons["导出全部规则"].tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "复制"])).firstMatch
        let appeared = copy.waitForExistence(timeout: 10)
        if !appeared { print("[Share sheet hierarchy] \(app.debugDescription)") }
        XCTAssertTrue(appeared)
        attach(app, name: "Legacy rule menu export")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
func openImportFixtureFolder(in app: XCUIApplication) {
    let pickerFiles = app.collectionViews["File View"].cells
    let fixtureJSON = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "JSON-Source")).firstMatch
    let fixtures = pickerFiles.matching(NSPredicate(format: "label BEGINSWITH %@", "书源导入测试")).firstMatch
    if !fixtureJSON.waitForExistence(timeout: 3) {
        if !fixtures.exists {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览", "Locations", "位置"])).firstMatch
            if browse.exists { browse.tap() }
            if !fixtures.waitForExistence(timeout: 2) {
                let local = app.descendants(matching: .any).matching(NSPredicate(
                    format: "label CONTAINS %@ OR label CONTAINS %@ OR label == %@", "我的 iPhone", "我的iPhone", "On My iPhone"
                )).firstMatch
                XCTAssertTrue(local.waitForExistence(timeout: 5))
                local.tap()
            }
        }
        XCTAssertTrue(fixtures.waitForExistence(timeout: 10), "Run sh scripts/prepare-source-import-fixture.sh <simulator-UUID>")
        fixtures.tap()
    }
}
