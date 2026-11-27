import XCTest

@MainActor
final class AppLockUITests: XCTestCase {
    private func openLockSettings(_ app: XCUIApplication) {
        let profile = app.scrollViews["profile.scroll"]
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        let entry = app.buttons["profile.lock"]
        for _ in 0..<10 {
            if entry.exists && entry.isHittable { break }
            profile.swipeUp()
        }
        entry.tap()
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin { app.buttons["appLock.digit.\(digit)"].tap() }
    }

    private func capture(_ title: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLockHidesFloatingPlayerWhileListeningContinues() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoReaderMenu", "-uiScrollRegression",
                               "-uiShortChapters", "-pageAnim", "0"]
        app.launch()
        openLockSettings(app)
        let pin = "025739"
        enterPIN(pin, in: app)
        enterPIN(pin, in: app)
        let locked = app.staticTexts["输入喵阅锁定码"]
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        enterPIN(pin, in: app)
        XCTAssertTrue(app.buttons["appLock.delay"].waitForExistence(timeout: 8))
        app.navigationBars["应用锁"].buttons.firstMatch.tap()
        app.tabBars.buttons["书架"].tap()
        let resume = app.buttons["bookshelf.continue"]
        resume.tap()
        app.buttons["听书"].tap()
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        app.buttons["收起播放器"].tap()
        let pause = app.buttons["暂停播放"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let beforeLock = resume.label
        app.buttons["立即锁定喵阅"].tap()
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        XCTAssertFalse(pause.exists)
        XCTAssertFalse(app.buttons["关闭播放器"].exists)
        // The short demo chapter finishes while the PIN screen is on top.
        Thread.sleep(forTimeInterval: 15)
        enterPIN(pin, in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertNotEqual(resume.label, beforeLock)
        pause.tap()
        let play = app.buttons["继续播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let cover = app.buttons["listening.openPlayer"]
        cover.tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        XCTAssertFalse(cover.exists)
        XCTAssertFalse(play.exists)
        enterPIN(pin, in: app)
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        app.buttons["收起播放器"].tap()
        app.buttons["关闭播放器"].tap()
        app.tabBars.buttons["设置"].tap()
        openLockSettings(app)
        app.buttons["关闭应用锁"].tap()
        enterPIN(pin, in: app)
    }

    func testAutoLockTimingAndManualLock() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings"]
        app.launch()
        openLockSettings(app)
        let pin = "023691"
        let locked = app.staticTexts["输入喵阅锁定码"]
        enterPIN(pin, in: app)
        enterPIN(pin, in: app)
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        enterPIN(pin, in: app)

        let delay = app.buttons["appLock.delay"]
        XCTAssertTrue(delay.waitForExistence(timeout: 8))
        let faceID = app.switches["使用 Face ID 解锁"]
        if faceID.exists {
            faceID.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertTrue(app.staticTexts["输入当前锁定码"].waitForExistence(timeout: 5))
            app.buttons["取消"].tap()
            XCTAssertEqual(faceID.value as? String, "0")
        }
        delay.tap()
        app.buttons["离开 5 分钟后"].tap()
        capture("应用锁管理", in: app)
        delay.tap()
        capture("自动锁定时长", in: app)
        app.buttons["离开 1 分钟后"].tap()

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(delay.isHittable)
        XCTAssertFalse(locked.exists)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        Thread.sleep(forTimeInterval: 61)
        app.activate()
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        enterPIN(pin, in: app)
        delay.tap()
        app.buttons["停用"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        enterPIN(pin, in: app)
        openLockSettings(app)
        XCTAssertTrue(delay.label.contains("停用") || (delay.value as? String) == "停用")
        app.navigationBars["应用锁"].buttons.firstMatch.tap()
        app.tabBars.buttons["书架"].tap()
        app.buttons["立即锁定喵阅"].tap()
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        enterPIN(pin, in: app)
        app.tabBars.buttons["设置"].tap()
        openLockSettings(app)
        app.buttons["关闭应用锁"].tap()
        enterPIN(pin, in: app)
    }

    func testPasswordProtectsColdLaunchAndBackgroundReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings"]
        app.launch()
        openLockSettings(app)
        XCTAssertTrue(app.staticTexts["设置 6 位数字锁定码"].waitForExistence(timeout: 8))
        capture("初次设置", in: app)
        let pin = "027519"
        enterPIN("12", in: app)
        app.buttons["删除一位"].tap()
        app.buttons["删除一位"].tap()
        enterPIN(pin, in: app)
        XCTAssertTrue(app.staticTexts["再次输入锁定码"].exists)
        app.buttons["取消"].tap()
        openLockSettings(app)
        XCTAssertTrue(app.staticTexts["设置 6 位数字锁定码"].exists)
        enterPIN(pin, in: app)
        enterPIN("027518", in: app)
        XCTAssertTrue(app.staticTexts["两次输入不一致，请重新设置。"].exists)
        enterPIN(pin, in: app)
        enterPIN(pin, in: app)
        let locked = app.staticTexts["输入喵阅锁定码"]
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["取消"].exists)
        capture("应用解锁", in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["profile.lock"].isHittable)
        let preview = app.navigationBars["书源导入预检"]
        if #available(iOS 16.4, *) {
            var link = URLComponents()
            link.scheme = "legado"
            link.host = "import"
            link.path = "/bookSource"
            link.queryItems = [URLQueryItem(name: "src", value: #"{"bookSourceName":"应用锁测试","bookSourceUrl":"https://example.invalid"}"#)]
            app.open(try XCTUnwrap(link.url))
            XCTAssertFalse(preview.exists)
        }
        enterPIN("111111", in: app)
        XCTAssertTrue(app.staticTexts["密码错误，请重新输入。"].waitForExistence(timeout: 5))
        enterPIN(pin, in: app)
        if #available(iOS 16.4, *) { XCTAssertTrue(preview.waitForExistence(timeout: 8)) }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        XCTAssertFalse(preview.buttons["取消"].isHittable)
        enterPIN(pin, in: app)
        if #available(iOS 16.4, *) {
            XCTAssertTrue(preview.waitForExistence(timeout: 8))
            preview.buttons["取消"].tap()
        }
        openLockSettings(app)
        app.buttons["更改锁定码"].tap()
        enterPIN(pin, in: app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["更改锁定码"].waitForExistence(timeout: 5))
        app.buttons["更改锁定码"].tap()
        enterPIN(pin, in: app)
        let replacement = "009481"
        enterPIN(replacement, in: app)
        enterPIN(replacement, in: app)
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        enterPIN(pin, in: app)
        XCTAssertTrue(app.staticTexts["密码错误，请重新输入。"].exists)
        enterPIN(replacement, in: app)
        app.buttons["关闭应用锁"].tap()
        enterPIN(replacement, in: app)
        app.terminate()
        app.launch()
        openLockSettings(app)
        XCTAssertTrue(app.staticTexts["设置 6 位数字锁定码"].waitForExistence(timeout: 8))
    }
}
