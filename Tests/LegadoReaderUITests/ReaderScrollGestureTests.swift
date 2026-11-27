import XCTest
import UIKit
import Vision

@MainActor
final class ReaderScrollGestureTests: XCTestCase {
    func testPagedSelectionKeepsPageEdgesFixed() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "0",
                               "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "28", "-paddingBottom", "80"]
        app.launch()
        let reader = app.textViews["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let pageTwo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        let frame = reader.frame
        let (_, before) = try selectionPixels(in: app)
        let point = try bodyTextPoint(in: reader)
        point.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 5))

        func assertPageEdges(file: StaticString = #filePath, line: UInt = #line) throws {
            let (width, pixels) = try selectionPixels(in: app)
            for y in [Int(frame.minY + 2), Int(frame.maxY - 90)] {
                let band = (y * width * 4)..<((y + 80) * width * 4)
                // Allow minor antialiasing differences between the two text views.
                XCTAssertTrue(band.allSatisfy { abs(Int(pixels[$0]) - Int(before[$0])) <= 4 },
                              "Text at the page edge moved at y=\(y)",
                              file: file, line: line)
            }
        }
        try assertPageEdges()
        let selection = app.textViews["reader.selection"]
        selection.swipeUp()
        try assertPageEdges()
        let handle = try trailingHandle(in: selection)
        let bottomMargin = handle.withOffset(CGVector(dx: 0, dy: frame.maxY - 4 - handle.screenPoint.y))
        handle.press(forDuration: 0.15, thenDragTo: bottomMargin, withVelocity: .slow, thenHoldForDuration: 0.4)
        let end = try trailingHandle(in: selection)
        XCTAssertGreaterThan(end.screenPoint.y, handle.screenPoint.y + 10)
        XCTAssertLessThan(end.screenPoint.y, frame.maxY - 50)
        app.buttons["复制"].tap()
        XCTAssertFalse(selection.exists)
        XCTAssertTrue(pageTwo.exists)
        try assertPageEdges()
    }

    func testSelectedBodyTextBecomesAReplacementRuleInBothReadingModes() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for mode in ["0", "3"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-pageAnim", mode, "-themeMode", "1", "-screenOrientation", "1"]
            app.launchArguments += ["-readerUseBackgroundImage", "NO", "-readerTheme", "wechat"]
            if mode == "3" { app.launchArguments += ["-lineSpacingExtra", "0"] }
            app.launch()
            let reader = mode == "3" ? app.collectionViews["reader.continuous"] : app.textViews["reader.text"]
            XCTAssertTrue(reader.waitForExistence(timeout: 15))
            // A middle paragraph leaves room for the toolbar during the multiline drag on small screens.
            let point: XCUICoordinate
            if reader.frame.height < 700 {
                point = try bodyTextPoint(in: reader)
            } else {
                let line = try recognizedLine(containing: "雨落", in: reader)
                point = reader.coordinate(withNormalizedOffset: CGVector(
                    dx: line.minX + line.width * 0.25, dy: 1 - line.midY
                ))
            }
            point.press(forDuration: 0.8)
            let add = app.buttons["过滤"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            let copy = app.buttons["复制"]
            XCTAssertLessThan(copy.frame.midX, add.frame.midX)
            XCTAssertLessThan(add.frame.midX, app.buttons["查找"].frame.midX)
            XCTAssertLessThan(app.buttons["查找"].frame.midX, app.buttons["翻译"].frame.midX)
            XCTAssertFalse(app.buttons["添加过滤规则"].exists)
            let selection = app.textViews["reader.selection"]
            let handle = try trailingHandle(in: selection)
            handle.press(forDuration: 0.15, thenDragTo: handle.withOffset(CGVector(dx: 52, dy: 100)),
                         withVelocity: .slow, thenHoldForDuration: 0.2)
            try assertLineGap(in: selection, below: handle.screenPoint.y - selection.frame.minY)
            attachScreenshot(app)
            XCTAssertTrue(add.isEnabled)
            add.tap()
            let excerpt = app.textViews["filter.pattern"]
            XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
            let pattern = try XCTUnwrap(excerpt.value as? String)
            XCTAssertGreaterThan(pattern.count, 4)
            let bar = app.navigationBars["过滤文本"]
            let heading = bar.staticTexts["sheet.heading"]
            XCTAssertLessThan(heading.frame.maxX, bar.buttons["取消"].frame.minX)
            XCTAssertLessThanOrEqual(bar.buttons["取消"].frame.maxX, bar.buttons["保存"].frame.minX)
            let replacement = app.textViews["filter.replacement"]
            XCTAssertTrue(replacement.isHittable)
            XCTAssertEqual(excerpt.frame.height, replacement.frame.height, accuracy: 1)
            let scope = app.segmentedControls.containing(.button, identifier: "全局").firstMatch
            XCTAssertTrue(scope.buttons["全局"].isSelected)
            let regex = app.switches["使用正则表达式"]
            XCTAssertTrue(regex.isHittable)
            XCTAssertEqual(regex.value as? String, "0")
            if mode == "3" {
                scope.buttons["本书"].tap()
                XCTAssertTrue(scope.buttons["本书"].isSelected)
                scope.buttons["全局"].tap()
                XCTAssertTrue(scope.buttons["全局"].isSelected)
                scope.buttons["本书"].tap()
                XCTAssertEqual(regex.value as? String, "0")
            } else {
                regex.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                XCTAssertEqual(regex.value as? String, "1")
            }
            let preview = XCTAttachment(screenshot: app.screenshot())
            preview.name = "过滤文本编辑页-模式" + mode
            preview.lifetime = .keepAlways
            self.add(preview)
            if mode == "0" {
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "更多设置")).firstMatch.tap()
                let name = try XCTUnwrap(app.textFields["名称"].value as? String)
                XCTAssertEqual(name.split(whereSeparator: \.isWhitespace),
                               pattern.prefix(20).split(whereSeparator: \.isWhitespace))
                let settingsBar = app.navigationBars["更多设置"]
                let pageTitle = settingsBar.staticTexts["page.heading"]
                let back = settingsBar.buttons.firstMatch
                XCTAssertEqual(pageTitle.frame.midY, back.frame.midY, accuracy: 4)
                XCTAssertEqual(pageTitle.frame.minX - back.frame.maxX, 12, accuracy: 8)
                XCTAssertTrue(settingsBar.buttons["保存"].isHittable)
                XCTAssertTrue(app.textFields["分组"].isHittable)
                let settingsPreview = XCTAttachment(screenshot: app.screenshot())
                settingsPreview.name = "过滤规则更多设置"
                settingsPreview.lifetime = .keepAlways
                self.add(settingsPreview)
                let advancedRegex = app.switches["使用正则表达式"]
                if !advancedRegex.isHittable { app.swipeUp() }
                XCTAssertEqual(advancedRegex.value as? String, "1")
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            if mode == "0" {
                excerpt.tap()
                excerpt.typeText("X")
                XCTAssertTrue((excerpt.value as? String)?.contains("X") == true)
                excerpt.typeText(XCUIKeyboardKey.delete.rawValue)
                XCTAssertEqual(excerpt.value as? String, pattern)
            }
            replacement.tap()
            let newValue = mode == "3" ? "REPLACED\nNEXT" : "REPLACED"
            replacement.typeText(newValue)
            XCTAssertEqual(replacement.value as? String, newValue)
            app.navigationBars["过滤文本"].buttons["保存"].tap()
            if mode == "3" {
                XCTAssertTrue(reader.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "REPLACED")).firstMatch.waitForExistence(timeout: 8))
            } else {
                let replaced = NSPredicate(format: "value CONTAINS %@", "REPLACED")
                wait(for: [expectation(for: replaced, evaluatedWith: reader)], timeout: 8)
            }
            app.terminate()
        }
    }

    func testFilteringWholeParagraphClosesItsSpaceInBothReadingModes() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for mode in ["0", "3"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-pageAnim", mode, "-themeMode", "1", "-screenOrientation", "1"]
            app.launch()
            let reader = mode == "3" ? app.collectionViews["reader.continuous"] : app.textViews["reader.text"]
            XCTAssertTrue(reader.waitForExistence(timeout: 15))
            let paragraph = try recognizedLine(containing: "第一束光", in: reader)
            let y = 1 - paragraph.midY
            reader.coordinate(withNormalizedOffset: CGVector(dx: paragraph.minX, dy: y))
                .withOffset(CGVector(dx: 4, dy: 0)).press(forDuration: 0.8)
            let filter = app.buttons["过滤"]
            XCTAssertTrue(filter.waitForExistence(timeout: 5))
            let selection = app.textViews["reader.selection"]
            let end = selection.coordinate(withNormalizedOffset: CGVector(dx: paragraph.maxX, dy: y))
                .withOffset(CGVector(dx: 8, dy: 0))
            try trailingHandle(in: selection).press(forDuration: 0.15, thenDragTo: end,
                                                   withVelocity: .slow, thenHoldForDuration: 0.2)
            filter.tap()
            let excerpt = app.textViews["filter.pattern"]
            XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
            XCTAssertEqual(excerpt.value as? String, "窗外，第一束光穿过雨幕。")
            app.navigationBars["过滤文本"].buttons["保存"].tap()
            XCTAssertTrue(reader.waitForExistence(timeout: 5))
            let following = try recognizedLine(containing: "立刻动身", in: reader)
            XCTAssertEqual(following.midY * reader.frame.height, paragraph.midY * reader.frame.height, accuracy: 4)
            app.terminate()
        }
    }

    func testFirstLineSelectionMenuFitsBelowHandlesInBothReadingModes() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for mode in ["0", "3"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-pageAnim", mode, "-titleMode", "2",
                                   "-paddingTop", "6", "-themeMode", "1", "-screenOrientation", "1"]
            app.launch()
            let reader = mode == "3" ? app.collectionViews["reader.continuous"] : app.textViews["reader.text"]
            XCTAssertTrue(reader.waitForExistence(timeout: 15))
            let line = try recognizedLine(containing: "雨落", in: reader)
            let point = reader.coordinate(withNormalizedOffset: CGVector(
                dx: mode == "0" ? line.minX : line.maxX, dy: 1 - line.midY
            )).withOffset(CGVector(dx: mode == "0" ? 6 : -16, dy: 0))
            XCTAssertLessThan(point.screenPoint.y - reader.frame.minY, 48)
            point.press(forDuration: 0.8)

            let selection = app.textViews["reader.selection"]
            let filter = app.buttons["过滤"]
            XCTAssertTrue(filter.waitForExistence(timeout: 5))
            func verifyMenu() throws -> XCUICoordinate {
                let handle = try trailingHandle(in: selection)
                try assertMatchingHandleDots(in: app, between: reader.frame.minY..<filter.frame.minY)
                for label in ["复制", "过滤", "查找", "翻译"] {
                    let button = app.buttons[label]
                    XCTAssertTrue(button.isHittable)
                    XCTAssertTrue(reader.frame.contains(button.frame))
                    XCTAssertGreaterThan(button.frame.minY, handle.screenPoint.y + 2)
                }
                attachScreenshot(app)
                return handle
            }

            let handle = try verifyMenu()
            let nextLine = handle.withOffset(CGVector(dx: mode == "0" ? 44 : -80, dy: 68))
            handle.press(forDuration: 0.15, thenDragTo: nextLine, withVelocity: .slow, thenHoldForDuration: 0.2)
            let extended = try verifyMenu()
            XCTAssertGreaterThan(extended.screenPoint.y, handle.screenPoint.y + 15)
            filter.tap()
            let bar = app.navigationBars["过滤文本"]
            XCTAssertTrue(bar.buttons["保存"].waitForExistence(timeout: 5))
            if mode == "0" {
                app.segmentedControls.buttons["本书"].tap()
                bar.buttons["取消"].tap()
                app.alerts["放弃未保存的修改？"].buttons["放弃修改"].tap()
            } else {
                bar.buttons["取消"].tap()
            }
            wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)], timeout: 5)
            app.terminate()
        }
    }

    private func recognizedLine(containing phrase: String, in reader: XCUIElement) throws -> CGRect {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans"]
        let image = try XCTUnwrap(reader.screenshot().image.cgImage)
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try XCTUnwrap(request.results?.first { $0.topCandidates(1).first?.string.contains(phrase) == true }).boundingBox
    }

    private func bodyTextPoint(in reader: XCUIElement) throws -> XCUICoordinate {
        let image = try XCTUnwrap(reader.screenshot().image.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = ["zh-Hans"]
        try VNImageRequestHandler(cgImage: image).perform([recognition])
        let line = try XCTUnwrap(recognition.results?.first {
            (0.35...0.7).contains($0.boundingBox.midY) && ($0.topCandidates(1).first?.string.count ?? 0) >= 8
        })
        return reader.coordinate(withNormalizedOffset: CGVector(dx: line.boundingBox.midX, dy: 1 - line.boundingBox.midY))
    }

    private func selectionPixels(in selection: XCUIElement) throws -> (Int, [UInt8]) {
        let image = try XCTUnwrap(selection.screenshot().image.cgImage)
        let width = Int(selection.frame.width)
        let height = Int(selection.frame.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, pixels)
    }

    private func assertMatchingHandleDots(in app: XCUIApplication, between limits: Range<CGFloat>) throws {
        let (width, pixels) = try selectionPixels(in: app)
        var diameters: [Int] = []
        var previousRow = -2
        for y in Int(ceil(limits.lowerBound))..<Int(limits.upperBound) {
            var run = 0
            var widest = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                let green = Int(pixels[i + 1])
                let isHandle = pixels[i] < 85 && green > 110 && green - Int(pixels[i + 2]) > 30
                run = isHandle ? run + 1 : 0
                widest = max(widest, run)
            }
            guard widest >= 5 else { continue } // Ignore the thin vertical stems.
            if y == previousRow + 1 {
                diameters[diameters.count - 1] = max(diameters.last!, widest)
            } else {
                diameters.append(widest)
            }
            previousRow = y
        }
        XCTAssertEqual(diameters.count, 2, "Both green drag knobs should be visible")
        for diameter in diameters { XCTAssertEqual(Double(diameter), 9, accuracy: 1) }
    }

    private func assertLineGap(in selection: XCUIElement, below firstLine: CGFloat) throws {
        let (width, pixels) = try selectionPixels(in: selection)
        // Between the two dragged endpoints at least one entire row should show the page background.
        let start = max(0, Int(firstLine) + 8)
        let end = min(pixels.count / (4 * width), start + 75)
        let hasGap = (start..<end).contains { y in
            let row = y * width * 4
            return (8..<(width - 8)).allSatisfy { x in
                (0..<3).allSatisfy { c in abs(Int(pixels[row + x * 4 + c]) - Int(pixels[row + c])) <= 3 }
            }
        }
        XCTAssertTrue(hasGap, "Adjacent selected lines should be separated by the page background")
    }

    private func trailingHandle(in selection: XCUIElement) throws -> XCUICoordinate {
        let (width, pixels) = try selectionPixels(in: selection)
        let offsets = stride(from: pixels.count - 4, through: 0, by: -4)
        let lastGreen = offsets.first { index -> Bool in
            let green = Int(pixels[index + 1])
            return pixels[index] < 85 && green > 110 && green - Int(pixels[index + 2]) > 30
        }
        let pixel = try XCTUnwrap(lastGreen, "The selected passage should have a visible green drag handle")
        return selection.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: pixel / 4 % width, dy: pixel / 4 / width - 2))
    }

    func testSelectionCopyDismissLookupAndTranslation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-pageAnim", "0", "-themeMode", "1", "-screenOrientation", "1"]
        app.launch()
        let reader = app.textViews["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        let point = try bodyTextPoint(in: reader)
        let copy = app.buttons["复制"]
        point.press(forDuration: 0.8)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertFalse(app.textViews["reader.selection"].exists)
        point.press(forDuration: 0.8)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertFalse(app.textViews["reader.selection"].exists)
        point.press(forDuration: 0.8)
        app.buttons["查找"].tap()
        let done = app.buttons["DDUIDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        app.buttons["翻译"].tap()
        attachScreenshot(app)
        if #unavailable(iOS 17.4) {
            let translate = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Translate", "翻译"])).firstMatch
            XCTAssertTrue(translate.waitForExistence(timeout: 5))
            translate.tap()
        }
        let sheet = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier CONTAINS %@ OR label == %@", "TranslationUI", "Sheet Grabber"
        )).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
    }

    func testCompactPanelsOpenFromReaderMenuAndSlideDownToDismiss() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0",
                               "-readerTheme", "wechat", "-themeMode", "1"]
        app.launch()
        for (entry, title) in [("外观", "阅读样式"), ("自动阅读", "自动阅读"), ("设置", "阅读设置")] {
            let button = app.buttons[entry]
            XCTAssertTrue(button.waitForExistence(timeout: 15))
            button.tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(bar.frame.minY, app.frame.height * 0.4)
            let bottomEdge = try app.backgroundRGB(x: 0.02, y: 0.985)
            XCTAssertTrue(bottomEdge.allSatisfy { $0 >= 250 }, "\(title) should meet the bottom edge, got \(bottomEdge)")
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)
            wait(for: [dismissed], timeout: 5)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func testBottomMenuControlsAutoReadingAndDayNightMode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0", "-themeMode", "1"]
        app.launch()
        let autoRead = app.buttons["自动阅读"]
        XCTAssertTrue(autoRead.waitForExistence(timeout: 20))
        XCTAssertEqual(autoRead.frame.midY, app.buttons["听书"].frame.midY, accuracy: 1)
        attachScreenshot(app)

        let isNight = app.buttons["日间"].exists
        app.buttons[isNight ? "日间" : "夜间"].tap()
        app.buttons[isNight ? "夜间" : "日间"].tap()
        autoRead.tap()
        let interval = app.sliders["自动翻页速度"]
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        interval.adjust(toNormalizedSliderPosition: 0.25)
        let selectedValue = interval.value as? String
        XCTAssertNotNil(selectedValue)
        attachScreenshot(app)
        app.navigationBars["自动阅读"].buttons["关闭"].tap()

        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        XCTAssertTrue(autoRead.waitForExistence(timeout: 5))
        autoRead.tap()
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        XCTAssertEqual(interval.value as? String, selectedValue)
        app.buttons["开始自动阅读"].tap()

        center.tap()
        let stop = app.buttons["停止翻页"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(autoRead.waitForExistence(timeout: 5))

        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["书籍详情"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["切换为日间"].exists)
        XCTAssertFalse(app.buttons["切换为夜间"].exists)
    }

    func testListeningSetupCanBeCancelledWithoutStarting() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0",
                               "-listeningEngine", "retired"]
        app.launch()
        let listen = app.buttons["听书"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        app.buttons["声音引擎"].tap()
        XCTAssertTrue(app.navigationBars["声音引擎"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["listening.engine"].exists)
        let search = app.textFields["搜索声音或语言"]
        search.tap()
        search.typeText("Yunxi")
        let yunxi = app.buttons["listening.voice.zh-CN-YunxiNeural"]
        XCTAssertTrue(yunxi.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["listening.voice.zh-CN-XiaoxiaoNeural"].exists)
        yunxi.tap()
        XCTAssertTrue(yunxi.isSelected)
        XCTAssertTrue(app.buttons["试听"].exists)
        XCTAssertFalse(app.switches["listening.byPage"].exists)
        app.navigationBars["声音引擎"].buttons["确定"].tap()
        XCTAssertTrue(app.buttons["开始听书"].isEnabled)
        app.buttons["收起播放器"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        XCTAssertTrue(listen.isEnabled)
        XCTAssertFalse(app.buttons["关闭播放器"].exists)
    }

    func testListeningEngineMenuRemembersSelectedVoice() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0"]
        app.launch()
        let listen = app.buttons["听书"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        app.buttons["声音引擎"].tap()
        let engine = app.buttons["listening.engine"]
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        func tapWhenReady(_ button: XCUIElement) {
            if button.isHittable { button.tap(); return }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            button.tap()
        }
        func choose(_ title: String) {
            tapWhenReady(engine)
            tapWhenReady(app.buttons[title])
        }
        func findVoice(_ id: String) -> XCUIElement {
            let voice = app.buttons["listening.voice." + id]
            if !voice.isHittable {
                let search = app.textFields["搜索声音或语言"]
                search.tap()
                search.typeText(id)
            }
            return voice
        }
        func select(_ id: String) { tapWhenReady(findVoice(id)) }
        func assertSelected(_ id: String) {
            let voice = findVoice(id)
            XCTAssertTrue(voice.waitForExistence(timeout: 5))
            XCTAssertTrue(voice.isSelected)
            if app.keyboards.count > 0 { voice.tap() }
        }
        let xiaoxiao = "zh-CN-XiaoxiaoNeural"
        let yunxi = "zh-CN-YunxiNeural"
        choose("LibreTTS 在线")
        select(xiaoxiao)
        choose("EdgeOne TTS")
        select(yunxi)
        choose("PPTBoard TTS")
        select(xiaoxiao)
        choose("EdgeOne TTS")
        assertSelected(yunxi)
        choose("PPTBoard TTS")
        assertSelected(xiaoxiao)
        choose("fengwm · Edge")
        select(yunxi)
        choose("fengwm · Azure")
        select(xiaoxiao)
        choose("fengwm · 火山")
        let fireVoice = "zh_female_qingxin"
        select(fireVoice)
        choose("万象 TTS")
        select(xiaoxiao)
        choose("fengwm · 火山")
        assertSelected(fireVoice)
        choose("fengwm · Edge")
        assertSelected(yunxi)
        choose("EdgeOne TTS")
        attachScreenshot(app)
        app.navigationBars["声音引擎"].buttons["确定"].tap()
        app.launch()
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        app.buttons["声音引擎"].tap()
        assertSelected(yunxi)
    }

    func testVoiceChangesApplyOnlyAfterConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0"]
        app.launch()
        app.buttons["听书"].tap()
        let open = app.buttons["声音引擎"]
        let bar = app.navigationBars["声音引擎"]
        let engine = app.buttons["listening.engine"]
        let original = app.buttons["listening.voice.zh-CN-XiaoxiaoNeural"]
        let alternate = app.buttons["listening.voice.zh-CN-YunxiNeural"]
        open.tap()
        engine.tap()
        app.buttons["EdgeOne TTS"].tap()
        original.tap()
        bar.buttons["确定"].tap()
        for cancelButton in [true, false] {
            open.tap()
            XCTAssertEqual(engine.value as? String, "EdgeOne TTS")
            XCTAssertTrue(original.isSelected)
            alternate.tap()
            XCTAssertTrue(alternate.isSelected)
            engine.tap()
            app.buttons["PPTBoard TTS"].tap()
            if cancelButton {
                bar.buttons["取消"].tap()
            } else {
                let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                start.press(forDuration: 0.1, thenDragTo: bottom)
            }
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)
            waitForExpectations(timeout: 5)
        }
        open.tap()
        XCTAssertEqual(engine.value as? String, "EdgeOne TTS")
        XCTAssertTrue(original.isSelected)
        alternate.tap()
        bar.buttons["确定"].tap()
        open.tap()
        XCTAssertTrue(alternate.isSelected)
    }

    func testLiveLibreTTSVoiceSearchAndPreview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEGADO_LIVE_LIBRETTS"] == "1", "需要启用在线语音服务测试")
        checkLiveVoiceSearchAndPreview(engine: "libreTTS")
    }

    func testLiveCommunityVoiceSearchAndPreview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEGADO_LIVE_COMMUNITY_TTS"] == "1", "需要启用在线语音服务测试")
        for engine in ["edgeOne", "pptBoard"] {
            checkLiveVoiceSearchAndPreview(engine: engine)
        }
    }

    func testLiveFengwmAndWanxiangVoiceSearchAndPreview() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEGADO_LIVE_FENGWM_WANXIANG"] == "1")
        for (engine, voice) in [("fengwmEdge", "zh-CN-YunxiNeural"), ("fengwmAzure", "zh-CN-YunjianNeural"),
                                ("fengwmVolcengine", "zh_male_xiaoming"), ("wanxiang", "zh-TW-YunJheNeural")] {
            checkLiveVoiceSearchAndPreview(engine: engine, voiceID: voice)
        }
    }

    private func checkLiveVoiceSearchAndPreview(engine: String, voiceID: String = "en-US-JennyNeural") {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-listeningEngine", engine]
        app.launch()
        app.buttons["profile.headphones"].tap()
        let more = app.buttons["声音引擎"]
        XCTAssertTrue(more.waitForExistence(timeout: 25))
        more.tap()
        let search = app.textFields["搜索声音或语言"]
        search.tap()
        search.typeText(voiceID)
        let voice = app.buttons["listening.voice." + voiceID]
        XCTAssertTrue(voice.waitForExistence(timeout: 25))
        voice.tap()
        let preview = app.buttons["试听"]
        if !preview.isHittable { app.swipeUp() }
        preview.tap()
        XCTAssertTrue(app.buttons["停止试听"].waitForExistence(timeout: 3))
        XCTAssertTrue(preview.waitForExistence(timeout: 25))
        let previewErrors = ["无法试听", "无法播放试听音频", "试听播放失败", "试听音频解码失败", "试听播放中断"]
        for message in previewErrors {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", message)).firstMatch.exists)
        }
    }

    func testPlayerReplacesTheCurrentParagraphDuringPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0",
                               "-listeningEngine", "edgeOne"]
        app.launch()
        let entry = app.buttons["听书"]
        expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: entry)
        waitForExpectations(timeout: 12)
        entry.tap()
        let paragraph = app.staticTexts["listening.paragraph"]
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        XCTAssertTrue(paragraph.label.hasPrefix("雨落在旧城"))
        app.buttons["开始听书"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "林深推开阁楼的窗"), evaluatedWith: paragraph)
        waitForExpectations(timeout: 45)
        XCTAssertTrue(paragraph.label.hasSuffix("一枚褪色的蓝色邮票。"))
        XCTAssertEqual(app.staticTexts.matching(identifier: "listening.paragraph").count, 1)
        app.buttons["结束朗读"].tap()
    }

    func testPlayerLayoutShowsOneParagraphInPortraitAndLandscape() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0",
                                   "-screenOrientation", orientation.isLandscape ? "2" : "1"]
            app.launch()
            let entry = app.buttons["听书"]
            expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: entry)
            waitForExpectations(timeout: 12)
            entry.tap()
            let paragraph = app.staticTexts["listening.paragraph"]
            let play = app.buttons["开始听书"]
            XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
            if orientation.isLandscape {
                let heading = app.staticTexts["listening.chapter"]
                XCTAssertGreaterThan(paragraph.frame.minX, heading.frame.maxX)
            }
            XCTAssertEqual(paragraph.label, "雨落在旧城的瓦檐上，细密得像一封迟到了许多年的信。")
            XCTAssertTrue(play.isHittable)
            XCTAssertTrue(app.buttons["listening.timer"].isHittable)
            XCTAssertFalse(app.buttons["原文"].exists)
            XCTAssertLessThanOrEqual(paragraph.frame.maxY, app.buttons["播放设置"].frame.minY + 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = orientation == .portrait ? "播放器竖屏" : "播放器横屏"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    func testListeningSettingsCanResetAndCancelTimerDuringPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0",
                               "-listeningEngine", "edgeOne"]
        app.launch()
        let listen = app.buttons["听书"]
        let timer = app.buttons["listening.timer"]
        let start = app.buttons["开始听书"]
        expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: listen)
        waitForExpectations(timeout: 12)
        listen.tap()
        XCTAssertTrue(app.staticTexts["listening.chapter"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["listening.engine"].exists)
        timer.tap()
        app.buttons["15 分钟"].tap()
        start.tap()
        let pause = app.buttons["暂停播放"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertEqual(timer.value as? String, "剩余 15 分钟")
        timer.tap()
        app.buttons["30 分钟"].tap()
        XCTAssertEqual(timer.value as? String, "剩余 30 分钟")
        timer.tap()
        let minutes = app.textFields["自定义分钟数"]
        minutes.tap()
        minutes.typeText("181")
        XCTAssertFalse(app.buttons["确定"].isEnabled)
        app.navigationBars["定时关闭"].buttons["关闭"].tap()
        XCTAssertEqual(timer.value as? String, "剩余 30 分钟")
        pause.tap()
        let play = app.buttons["继续播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let speed = app.buttons["语速"]
        speed.tap()
        XCTAssertFalse(app.navigationBars["朗读语速"].exists)
        app.buttons["1.5×"].tap()
        expectation(for: NSPredicate(format: "value == %@", "1.5×"), evaluatedWith: speed)
        waitForExpectations(timeout: 5)
        speed.tap()
        XCTAssertFalse(app.navigationBars["朗读语速"].exists)
        app.buttons["1.0×"].tap()
        expectation(for: NSPredicate(format: "value == %@", "1.0×"), evaluatedWith: speed)
        waitForExpectations(timeout: 5)
        let paragraph = app.staticTexts["listening.paragraph"]
        XCTAssertTrue(paragraph.isHittable)
        XCTAssertFalse(paragraph.label.isEmpty)
        XCTAssertFalse(app.buttons["原文"].exists)
        attachScreenshot(app)
        app.buttons["播放设置"].tap()
        XCTAssertFalse(app.buttons["listening.engine"].exists)
        XCTAssertTrue(app.switches["朗读时保持亮屏"].exists)
        XCTAssertTrue(app.switches["忽略音频焦点"].exists)
        XCTAssertFalse(app.cells.buttons["listening.timer"].exists)
        XCTAssertFalse(app.sliders["朗读语速"].exists)
        app.navigationBars["听书设置"].buttons["关闭"].tap()
        app.buttons["声音引擎"].tap()
        let yunxi = app.buttons["listening.voice.zh-CN-YunxiNeural"]
        let target = yunxi.isSelected ? app.buttons["listening.voice.zh-CN-XiaoxiaoNeural"] : yunxi
        target.tap()
        XCTAssertTrue(target.isSelected)
        let settingsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settingsShot.name = "播放中的声音引擎"
        settingsShot.lifetime = .keepAlways
        add(settingsShot)
        app.navigationBars["声音引擎"].buttons["确定"].tap()
        timer.tap()
        app.buttons["listening.timer.preset.0"].tap()
        XCTAssertEqual(timer.value as? String, "关闭")
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        app.buttons["listening.openPlayer"].tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["listening.openPlayer"].exists)
        XCTAssertEqual(timer.value as? String, "关闭")
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        let chapter = app.staticTexts["listening.chapter"]
        let initialTitle = chapter.label
        app.buttons["下一章"].tap()
        expectation(for: NSPredicate(format: "label != %@", initialTitle), evaluatedWith: chapter)
        waitForExpectations(timeout: 5)
        app.buttons["上一章"].tap()
        expectation(for: NSPredicate(format: "label == %@", initialTitle), evaluatedWith: chapter)
        waitForExpectations(timeout: 5)
        app.buttons["结束朗读"].tap()
        XCTAssertFalse(app.buttons["关闭播放器"].exists)
    }

    func testListeningAdvancesOnBookshelfAndReconnectsWhenReaderReopens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-uiScrollRegression",
                               "-uiShortChapters", "-pageAnim", "0"]
        app.launch()
        let listen = app.buttons["听书"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        app.buttons["收起播放器"].tap()
        let pause = app.buttons["暂停播放"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        let middle = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        middle.tap()
        app.buttons["返回"].tap()

        let resume = app.buttons["bookshelf.continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["reader.text"].exists)
        XCTAssertTrue(pause.isHittable)
        let bar = app.tabBars.firstMatch
        XCTAssertLessThan(pause.frame.maxY, bar.frame.minY)
        let grip = pause.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(.init(dx: 0, dy: 110)))
        XCTAssertLessThan(pause.frame.maxY, bar.frame.minY)
        let chapterOnExit = resume.label
        let advanced = NSPredicate(format: "label != %@ AND label CONTAINS %@", chapterOnExit, "连续阅读")
        expectation(for: advanced, evaluatedWith: resume)
        waitForExpectations(timeout: 45)
        let cover = app.buttons["listening.openPlayer"]
        cover.tap()
        XCTAssertTrue(app.staticTexts["listening.chapter"].waitForExistence(timeout: 5))
        XCTAssertTrue(pause.isHittable)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(pause.isHittable)
        pause.tap()
        let play = app.buttons["继续播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        app.buttons["目录"].tap()
        let contents = app.staticTexts["reader.toc.title"]
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        cover.tap()
        XCTAssertTrue(app.staticTexts["listening.chapter"].waitForExistence(timeout: 5))
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        app.buttons["关闭播放器"].tap()
        XCTAssertFalse(play.exists)
        XCTAssertTrue(contents.exists)
    }

    func testPlayerCoverReturnsToBookmarksAndTheUnderlyingReader() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0", "-themeMode", "2"]
        app.launch()
        app.buttons["听书"].tap()
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        app.buttons["收起播放器"].tap()
        app.buttons["暂停播放"].tap()
        let middle = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        middle.tap()
        app.buttons["更多"].tap()
        app.buttons["书签列表"].tap()
        let bookmarks = app.navigationBars["书签"]
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 5))
        XCTAssertTrue(bookmarks.buttons["关闭"].isHittable)
        let cover = app.buttons["listening.openPlayer"]
        cover.tap()
        XCTAssertTrue(app.buttons["继续播放"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["收起播放器"].isHittable)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 5))
        let closeBookmarks = bookmarks.buttons["关闭"]
        wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: closeBookmarks)], timeout: 5)
        closeBookmarks.tap()
        XCTAssertFalse(bookmarks.exists)

        cover.tap()
        XCTAssertTrue(app.staticTexts["listening.chapter"].waitForExistence(timeout: 5))
        app.buttons["收起播放器"].tap()
        middle.tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["bookshelf.continue"].waitForExistence(timeout: 5))
        app.buttons["关闭播放器"].tap()
    }

    func testPlayerCoverReopensFromBookshelfWithoutOpeningReader() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0", "-themeMode", "2"]
        app.launch()
        app.buttons["听书"].tap()
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        app.buttons["收起播放器"].tap()
        app.buttons["暂停播放"].tap()
        let back = app.buttons["返回"]
        let middle = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        if !back.exists { middle.tap() }
        back.tap()

        let shelf = app.buttons["bookshelf.continue"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        let play = app.buttons["继续播放"]
        let (width, pixels) = try selectionPixels(in: play)
        let sample = (4 * width + width / 2) * 4
        XCTAssertLessThan(pixels[sample], 80, "书架使用深色时，播放器也应使用深色背景")
        for _ in 0..<2 {
            app.buttons["listening.openPlayer"].tap()
            XCTAssertTrue(app.staticTexts["listening.chapter"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.textViews["reader.text"].exists)
            app.buttons["收起播放器"].tap()
            XCTAssertTrue(shelf.waitForExistence(timeout: 5))
            XCTAssertTrue(play.isHittable)
        }
        app.buttons["关闭播放器"].tap()
    }

    func testPlayerCoverOpensListenedBookAndReturnsToOtherBooksPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0",
                               "-textSize", "28", "-tipFooterRight", "6"]
        app.launch()
        let listen = app.buttons["听书"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        app.buttons["收起播放器"].tap()
        let pause = app.buttons["暂停播放"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        let play = app.buttons["继续播放"]
        let cover = app.buttons["listening.openPlayer"]
        let back = app.buttons["返回"]
        let middle = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        middle.tap()
        back.tap()

        let otherBook = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "群星沉默时")).firstMatch
        XCTAssertTrue(otherBook.waitForExistence(timeout: 8))
        otherBook.tap()
        XCTAssertTrue(listen.waitForExistence(timeout: 8))
        XCTAssertTrue(listen.isEnabled)
        middle.tap()
        app.coordinate(withNormalizedOffset: .init(dx: 0.8, dy: 0.5)).tap()
        let pageTwo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        cover.tap()
        XCTAssertTrue(app.staticTexts["长夜里的灯"].waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        if !back.exists { middle.tap() }
        back.tap()
        XCTAssertTrue(app.buttons["bookshelf.continue"].waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        app.buttons["关闭播放器"].tap()
    }

    func testSpeedMenuAppliesSelectionOnPlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0"]
        app.launch()
        app.buttons["听书"].tap()
        let speed = app.buttons["语速"]
        for value in ["1.3×", "1.0×"] {
            speed.tap()
            XCTAssertFalse(app.navigationBars["朗读语速"].exists)
            app.buttons[value].tap()
            XCTAssertEqual(speed.value as? String, value)
        }
    }

    func testPlayerAndSheetsFollowSelectedAppearance() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for (mode, light) in [("1", true), ("2", false)] {
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0", "-themeMode", mode]
            app.launch()
            app.buttons["听书"].tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
            func checkBackground(at y: CGFloat) throws {
                let rgb = try app.backgroundRGB(x: 0.55, y: y)
                let average = rgb.reduce(0, +) / 3
                XCTAssertTrue(light ? average > 155 : average < 120, "外观 \(mode)，背景 \(rgb)")
            }
            try checkBackground(at: 0.15)
            for (button, title) in [("listening.timer", "定时关闭"), ("声音引擎", "声音引擎"), ("播放设置", "听书设置")] {
                app.buttons[button].tap()
                let bar = app.navigationBars[title]
                XCTAssertTrue(bar.waitForExistence(timeout: 5))
                try checkBackground(at: bar.frame.midY / app.frame.height)
                if title == "声音引擎" { attachScreenshot(app) }
                bar.buttons[title == "声音引擎" ? "确定" : "关闭"].tap()
                XCTAssertTrue(app.buttons["收起播放器"].isHittable)
            }
        }
    }

    func testProfileListeningSettingsOnlyShowsPreferencesAndVoiceEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings"]
        app.launch()
        app.buttons["profile.headphones"].tap()
        XCTAssertTrue(app.switches["朗读时保持亮屏"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["listening.timer"].exists)
        XCTAssertFalse(app.sliders["朗读语速"].exists)
        app.buttons["声音引擎"].tap()
        XCTAssertTrue(app.buttons["listening.engine"].waitForExistence(timeout: 5))
        app.navigationBars["声音引擎"].buttons["确定"].tap()
        XCTAssertTrue(app.switches["朗读时保持亮屏"].isHittable)
    }

    func testListeningTimerExpiresAndClearsForNextPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-uiScrollRegression",
                               "-pageAnim", "0", "-ttsTimer", "45", "-readAloudByPage", "YES"]
        app.launch()
        let listen = app.buttons["听书"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        let timer = app.buttons["listening.timer"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertEqual(timer.value as? String, "关闭")
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.buttons["暂停播放"].waitForExistence(timeout: 10))
        timer.tap()
        let minutes = app.textFields["自定义分钟数"]
        minutes.tap()
        minutes.typeText("1")
        let startedAt = ProcessInfo.processInfo.systemUptime
        app.buttons["确定"].tap()
        XCTAssertEqual(timer.value as? String, "剩余 1 分钟")
        app.buttons["收起播放器"].tap()
        let close = app.buttons["关闭播放器"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 75), .completed)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - startedAt, 60)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        listen.tap()
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertEqual(timer.value as? String, "关闭")
    }

    func testListeningPlayerDragsAndDocksWithCloseButtonOnRight() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "0"]
        app.launch()
        let listen = app.buttons["听书"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        listen.tap()
        let start = app.buttons["开始听书"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()
        app.buttons["收起播放器"].tap()
        let pause = app.buttons["暂停播放"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        pause.tap()
        let play = app.buttons["继续播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let close = app.buttons["关闭播放器"]
        let leftClose = close.frame
        let leftPlay = play.frame
        XCTAssertGreaterThan(leftClose.midX, leftPlay.midX)

        let middle = CGVector(dx: 0.5, dy: 0.5)
        let readerCenter = app.coordinate(withNormalizedOffset: middle)
        readerCenter.tap()
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        XCTAssertLessThan(close.frame.maxY, listen.frame.minY)
        XCTAssertLessThan(close.frame.midY, leftClose.midY)
        readerCenter.tap()
        let restored = NSPredicate { _, _ in abs(close.frame.midY - leftClose.midY) <= 1 }
        wait(for: [expectation(for: restored, evaluatedWith: nil)], timeout: 3)

        let fromClose = close.coordinate(withNormalizedOffset: middle)
        fromClose.press(forDuration: 0.1, thenDragTo: fromClose.withOffset(
            CGVector(dx: app.frame.width * 0.48, dy: -100)))
        XCTAssertEqual(close.frame.midX - play.frame.midX, leftClose.midX - leftPlay.midX, accuracy: 2)
        XCTAssertEqual(play.frame.midX, app.frame.maxX - leftPlay.midX, accuracy: 2)
        XCTAssertEqual(close.frame.midY, leftClose.midY - 100, accuracy: 4)

        let rightCloseX = close.frame.midX
        let fromPlay = play.coordinate(withNormalizedOffset: middle)
        let lift = app.frame.height * 0.25
        fromPlay.press(forDuration: 0.1, thenDragTo: fromPlay.withOffset(
            CGVector(dx: -app.frame.width * 0.48, dy: -lift)))
        XCTAssertTrue(play.exists)
        XCTAssertEqual(close.frame.midX, leftClose.midX, accuracy: 2)
        XCTAssertEqual(close.frame.midY, leftClose.midY - 100 - lift, accuracy: 4)
        let restingFrame = close.frame
        readerCenter.tap()
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        XCTAssertEqual(close.frame.midY, restingFrame.midY, accuracy: 1)
        XCTAssertEqual(close.frame.midX, restingFrame.midX, accuracy: 1)
        attachScreenshot(app)
        let coverEdge = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 24, dy: close.frame.midY))
        coverEdge.press(forDuration: 0.1, thenDragTo: coverEdge.withOffset(
            CGVector(dx: app.frame.width * 0.48, dy: 0)))
        XCTAssertEqual(close.frame.midX, rightCloseX, accuracy: 2)
        XCTAssertTrue(listen.isHittable)
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertFalse(close.exists)
    }

    func testMoreMenuOpensChapterInEmbeddedBrowser() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-uiComicRegression"]
        app.launch()
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["打开原网页"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }

    func testComicImagesLoadInOrderAndFailedImageCanRetry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiComicRegression", "-pageAnim", "3", "-themeMode", "1"]
        app.launchEnvironment["COMIC_TEST_BASE_URL"] = "http://127.0.0.1:18089"
        app.launch()
        let reader = app.tables["reader.comic"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        XCTAssertTrue(app.images["reader.comic.image.1"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textViews["reader.text"].exists)
        attachScreenshot(app)
        reader.swipeUp()
        let retry = app.buttons["reader.comic.retry.2"]
        for _ in 0..<4 where !retry.isHittable { reader.swipeUp() }
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(app.images["reader.comic.image.2"].waitForExistence(timeout: 15))
        attachScreenshot(app)
        XCTAssertFalse(retry.exists)
        reader.swipeUp()
        XCTAssertTrue(app.images["reader.comic.image.3"].waitForExistence(timeout: 15))
        let third = app.images["reader.comic.image.3"]
        XCTAssertGreaterThan(third.frame.height, third.frame.width * 2)
        attachScreenshot(app)
        app.buttons["下一章"].tap()
        XCTAssertTrue(app.images["reader.comic.image.1"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["上一章"].isEnabled)
        app.buttons["上一章"].tap()
        XCTAssertTrue(app.images["reader.comic.image.1"].waitForExistence(timeout: 15))
        app.terminate()
    }

    func testFixedReaderTapZonesInContinuousMode() throws {
        continueAfterFailure = false
        let (app, reader) = launchReader(shortChapters: false)
        let original = try value("position", in: reader)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.16)).tap()
        let advanced = expectation(for: NSPredicate { _, _ in
            ((try? self.value("position", in: reader)) ?? 0) > original
        }, evaluatedWith: nil)
        wait(for: [advanced], timeout: 5)
        let next = try value("position", in: reader)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.82)).tap()
        let returned = expectation(for: NSPredicate { _, _ in
            ((try? self.value("position", in: reader)) ?? next) < next
        }, evaluatedWith: nil)
        wait(for: [returned], timeout: 5)
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
        app.buttons["更多"].tap()
        XCTAssertTrue(app.buttons["书籍详情"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["重新获取本章"].exists)
    }

    func testBackgroundSwitchRestoresPresetWithoutDeletingPhoto() throws {
        try exerciseBackgroundSwitch(readingMode: "0")
    }

    func testScrollBackgroundSwitchRestoresPresetWithoutDeletingPhoto() throws {
        try exerciseBackgroundSwitch(readingMode: "3")
    }

    private func exerciseBackgroundSwitch(readingMode: String) throws {
        continueAfterFailure = false
        let app = launchAppearance(readingMode: readingMode)
        let choose = app.buttons["选择背景图片"]
        scrollToAppearanceElement(choose, in: app)
        app.buttons["微信读书"].tap()
        choose.tap()
        let photo = app.images.matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", "PXGGridLayout-Info", "照片,", "Photo,"
        )).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = expectation(for: NSPredicate { _, _ in !photo.exists }, evaluatedWith: nil)
        wait(for: [dismissed], timeout: 15)
        let useBackground = app.switches["使用背景图片"]
        scrollToAppearanceElement(useBackground, in: app)
        XCTAssertEqual(useBackground.value as? String, "1")
        app.navigationBars["阅读样式"].buttons["取消"].tap()
        let imageColor = try app.backgroundRGB()

        func assertBackground(_ expected: [Int]) {
            // Wait for dismissal to finish before sampling the reader beneath the sheet.
            let settled = expectation(for: NSPredicate { _, _ in
                guard let rgb = try? app.backgroundRGB() else { return false }
                return zip(rgb, expected).allSatisfy { abs($0 - $1) <= 4 }
            }, evaluatedWith: nil)
            wait(for: [settled], timeout: 5)
        }

        func openAppearance() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.buttons["外观"].tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
            scrollToAppearanceElement(useBackground, in: app)
        }
        openAppearance()
        attachScreenshot(app)
        app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.25, dy: useBackground.frame.midY / app.frame.height
        )).tap()
        XCTAssertEqual(useBackground.value as? String, "0")
        XCTAssertTrue(app.buttons["删除背景图片"].exists)
        app.navigationBars["阅读样式"].buttons["取消"].tap()
        assertBackground([218, 233, 219])

        openAppearance()
        useBackground.tap()
        XCTAssertEqual(useBackground.value as? String, "1")
        app.navigationBars["阅读样式"].buttons["取消"].tap()
        assertBackground(imageColor)

        openAppearance()
        app.buttons["预设2"].tap()
        XCTAssertEqual(useBackground.value as? String, "0")
        app.navigationBars["阅读样式"].buttons["取消"].tap()
        assertBackground([221, 192, 144])
    }

    func testBackgroundPickerCanBeOpenedRepeatedly() throws {
        continueAfterFailure = false
        let app = launchAppearance()
        for _ in 0..<3 {
            let choose = app.buttons["选择背景图片"]
            scrollToAppearanceElement(choose, in: app)
            choose.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        }
    }

    func testBackgroundPhotoCanBeSelectedAndReplaced() throws {
        try exerciseBackgroundPhotoSelection(usesLegacyUI: false)
    }

    func testLegacyBackgroundPhotoCanBeSelectedAndReplaced() throws {
        try exerciseBackgroundPhotoSelection(usesLegacyUI: true)
    }

    private func exerciseBackgroundPhotoSelection(usesLegacyUI: Bool) throws {
        continueAfterFailure = false
        let app = launchAppearance(usesLegacyUI: usesLegacyUI)
        for _ in 0..<2 {
            let choose = app.buttons["选择背景图片"]
            scrollToAppearanceElement(choose, in: app)
            choose.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            let photo = app.images.matching(NSPredicate(
                format: "identifier == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", "PXGGridLayout-Info", "照片,", "Photo,"
            )).firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 5), "Seed a demo image with simctl addmedia before running this test")
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let dismissed = expectation(for: NSPredicate { _, _ in !photo.exists }, evaluatedWith: nil)
            wait(for: [dismissed], timeout: 15)
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 15))
            let useBackground = app.switches["使用背景图片"]
            scrollToAppearanceElement(useBackground, in: app)
            XCTAssertEqual(useBackground.value as? String, "1")
        }
    }

    func testClosingAutomaticReadingKeepsSelectedSpeed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu"]
        app.launch()
        app.buttons["自动阅读"].tap()
        let speed = app.sliders["自动翻页速度"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        let initial = speed.value as? String
        speed.adjust(toNormalizedSliderPosition: initial == "每屏 1 秒" ? 1 : 0)
        XCTAssertNotEqual(speed.value as? String, initial)
        let selected = speed.value as? String
        app.navigationBars["自动阅读"].buttons["关闭"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["自动阅读"].tap()
        XCTAssertEqual(speed.value as? String, selected)
    }

    func testAppearanceActionsAndImmediateThemePersistence() {
        continueAfterFailure = false
        let app = launchAppearance()
        let bar = app.navigationBars["阅读样式"]
        let more = bar.buttons["更多"]
        let cancel = bar.buttons["取消"]
        XCTAssertTrue(more.isHittable && cancel.isHittable)
        XCTAssertLessThan(more.frame.midX, cancel.frame.midX)
        XCTAssertEqual(app.buttons.matching(identifier: "更多").count, 1)
        XCTAssertFalse(bar.buttons["保存"].exists)
        let preset = app.buttons["预设2"]
        let wasSelected = preset.isSelected
        let nextPreset = wasSelected ? app.buttons["微信读书"] : preset
        nextPreset.tap()
        more.tap()
        XCTAssertTrue(app.navigationBars["页面设置"].waitForExistence(timeout: 5))
        app.navigationBars["页面设置"].buttons["返回"].tap()
        attachScreenshot(app)
        cancel.tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertTrue(nextPreset.isSelected)
    }

    func testStyleDetailsRestoreCompactSheetWhenNavigatingBack() {
        exerciseStyleSheetNavigation(usesLegacyUI: false)
    }

    func testStyleDetailBackgroundsFollowTheReaderTheme() throws {
        continueAfterFailure = false
        for night in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderStyle",
                                   "-readerTheme", night ? "night" : "wechat", "-themeMode", night ? "1" : "2"]
            app.launch()
            let style = app.navigationBars["阅读样式"]
            XCTAssertTrue(style.waitForExistence(timeout: 15))
            for title in ["阅读样式", "页面设置", "字体与间距"] {
                if title == "页面设置" { app.buttons["更多"].tap() }
                if title == "字体与间距" { app.buttons[title].tap() }
                let bar = app.navigationBars[title]
                XCTAssertTrue(bar.waitForExistence(timeout: 5))
                let pageColor = try app.backgroundRGB(x: 0.04, y: (bar.frame.maxY + 16) / app.frame.height)
                // Sample the open space between the title and the toolbar buttons.
                let barColor = try app.backgroundRGB(x: 0.5, y: bar.frame.midY / app.frame.height)
                for rgb in [pageColor, barColor] {
                    // The native dark sheet is elevated above black, even when the panel is drawn in the reader window.
                    XCTAssertTrue(rgb.allSatisfy { night ? (24...36).contains($0) : $0 >= 250 }, "\(title) RGB \(rgb)")
                }
                attachScreenshot(app)
            }
            app.terminate()
        }
    }

    func testLegacyStyleDetailsRestoreCompactSheetWhenNavigatingBack() {
        exerciseStyleSheetNavigation(usesLegacyUI: true)
    }

    private func exerciseStyleSheetNavigation(usesLegacyUI: Bool) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launchAppearance(usesLegacyUI: usesLegacyUI)
        let style = app.navigationBars["阅读样式"]
        let compactTop = style.frame.minY
        let page = app.navigationBars["页面设置"]
        let typography = app.navigationBars["字体与间距"]
        XCTAssertFalse(app.buttons["字体与间距"].exists)
        XCTAssertTrue(app.buttons["增大字号"].isHittable)
        enum ReturnAction { case swipeDown, button, edgeSwipe }
        for action in [ReturnAction.swipeDown, .button, .edgeSwipe] {
            app.buttons["更多"].tap()
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            let expandedTop = page.frame.minY
            XCTAssertLessThan(expandedTop, compactTop - 100)
            app.buttons["字体与间距"].tap()
            XCTAssertTrue(typography.waitForExistence(timeout: 5))
            for (detail, parent) in [(typography, page), (page, style)] {
                XCTAssertEqual(detail.frame.minY, expandedTop, accuracy: 3)
                switch action {
                case .swipeDown:
                    let start = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: 0, dy: app.frame.height * 0.65)))
                case .edgeSwipe:
                    let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
                    let end = edge.withOffset(.init(dx: app.frame.width * 0.8, dy: 0))
                    edge.press(forDuration: 0.05, thenDragTo: end)
                case .button:
                    detail.buttons.firstMatch.tap()
                }
                XCTAssertTrue(parent.waitForExistence(timeout: 5))
            }
            XCTAssertEqual(style.frame.minY, compactTop, accuracy: 3)
        }

        style.buttons["取消"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let appearance = app.buttons["外观"]
        let menuVisible = expectation(for: NSPredicate { _, _ in
            appearance.exists && appearance.frame.maxY < app.frame.maxY - 8
        }, evaluatedWith: nil)
        wait(for: [menuVisible], timeout: 5)
        appearance.tap()
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        XCTAssertEqual(style.frame.minY, compactTop, accuracy: 3)
    }

    func testMarginPickerShowsEachAreasOwnSettings() {
        continueAfterFailure = false
        let app = launchAppearance()
        app.buttons["更多"].tap()
        let area = app.segmentedControls.containing(.button, identifier: "正文").firstMatch
        let left = app.sliders["左边距"]
        scrollToAppearanceElement(app.sliders["下边距"], in: app)
        XCTAssertTrue(area.buttons["正文"].isSelected)
        let body = left.value as? String
        area.buttons["页脚"].tap()
        let footer = left.value as? String
        area.buttons["页眉"].tap()
        let header = left.value as? String
        let target: CGFloat = header == "100" ? 0 : 1
        left.adjust(toNormalizedSliderPosition: target)
        let edited = left.value as? String
        XCTAssertNotEqual(edited, header)
        area.buttons["正文"].tap()
        XCTAssertEqual(left.value as? String, body)
        area.buttons["页脚"].tap()
        XCTAssertEqual(left.value as? String, footer)
        area.buttons["页眉"].tap()
        XCTAssertEqual(left.value as? String, edited)
        attachScreenshot(app)
        if let header, let original = Double(header) {
            left.adjust(toNormalizedSliderPosition: CGFloat(original / 100))
        }
    }

    func testFontPickerCanBePresentedAboveAppearanceAndReopened() throws {
        continueAfterFailure = false
        let app = launchAppearance()
        app.buttons["更多"].tap()
        app.buttons["字体与间距"].tap()
        for _ in 0..<2 {
            let choose = app.buttons.matching(NSPredicate(format: "label IN %@", ["选择字体文件", "更换字体文件"])).firstMatch
            scrollToAppearanceElement(choose, in: app)
            XCTAssertTrue(app.staticTexts["段落缩进"].exists)
            choose.tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            let pickerAppeared = cancel.waitForExistence(timeout: 10)
            if !pickerAppeared { print(app.debugDescription); attachScreenshot(app) }
            XCTAssertTrue(pickerAppeared)
            cancel.tap()
            XCTAssertTrue(app.navigationBars["字体与间距"].waitForExistence(timeout: 5))
        }
    }

    func testFontPickerInstallsSelectedTrueTypeFile() {
        continueAfterFailure = false
        let app = launchAppearance()
        app.buttons["更多"].tap()
        app.buttons["字体与间距"].tap()
        let choose = app.buttons.matching(NSPredicate(format: "label IN %@", ["选择字体文件", "更换字体文件"])).firstMatch
        scrollToAppearanceElement(choose, in: app)
        if choose.label == "更换字体文件" {
            let reset = app.buttons["使用系统字体"]
            scrollToAppearanceElement(reset, in: app)
            reset.tap()
        }
        XCTAssertEqual(choose.label, "选择字体文件")
        choose.tap()
        openImportFixtureFolder(in: app)
        let font = app.collectionViews["File View"].cells.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Reader-Test")
        ).firstMatch
        XCTAssertTrue(font.waitForExistence(timeout: 5))
        XCTAssertTrue(font.isEnabled)
        font.tap()
        XCTAssertTrue(app.buttons["更换字体文件"].waitForExistence(timeout: 10))
        let installed = app.staticTexts["Reader-Test.ttf"]
        scrollToAppearanceElement(installed, in: app)
        XCTAssertTrue(installed.isHittable)
        let reset = app.buttons["使用系统字体"]
        scrollToAppearanceElement(reset, in: app)
        reset.tap()
        XCTAssertEqual(choose.label, "选择字体文件")
    }

    func testBookmarkSelectionSurvivesLeavingAndReenteringReader() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-pageAnim", "0", "-themeMode", "1", "-textSize", "28"]
        app.launch()
        func openReaderMenu() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let more = app.buttons["更多"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
        }
        let book = app.staticTexts["山海入梦来"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        book.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 20))
        openReaderMenu()
        let bookmark = app.buttons["reader.addBookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertEqual(bookmark.label, "添加书签")
        bookmark.tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 10))
        openReaderMenu()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertEqual(bookmark.label, "移除书签")
        app.buttons["书签列表"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "位置 ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 5))
        openReaderMenu()
        bookmark.tap()
        app.buttons["更多"].tap()
        XCTAssertEqual(bookmark.label, "添加书签")
        app.buttons["书签列表"].tap()
        XCTAssertTrue(app.staticTexts["本书还没有书签"].waitForExistence(timeout: 5))
    }

    func testProfileBookmarkOpensAtSavedPageAndAllowsReadingOn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "bookshelf", "-pageAnim", "0",
                               "-tipHeaderLeft", "1", "-tipFooterRight", "4", "-textSize", "28"]
        app.launch()
        app.buttons["更多"].tap()
        app.buttons["本地书籍文件"].tap()
        openPagingFixture(in: app)
        let reader = app.textViews["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        func showMenu() {
            reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 5))
        }
        showMenu()
        app.buttons["下一章"].tap()
        let title = "第二章 灯塔"
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let pageTwo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        showMenu()
        app.buttons["更多"].tap()
        app.buttons["reader.addBookmark"].tap()
        app.buttons["下一章"].tap()
        showMenu()
        app.buttons["返回"].tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["profile.bookmark"].tap()
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars[title].exists)
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].firstMatch.exists)
        showMenu()
        app.buttons["下一章"].tap()
        XCTAssertTrue(app.staticTexts["第三章 天明"].firstMatch.waitForExistence(timeout: 5))
    }

    private func openPagingFixture(in app: XCUIApplication) {
        app.buttons["导入 TXT / EPUB"].firstMatch.tap()
        let browse = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
        if browse.exists && !browse.isSelected { browse.tap() }
        openImportFixtureFolder(in: app)
        let file = app.collectionViews["File View"].cells.matching(NSPredicate(format: "label BEGINSWITH %@", "TXT-Paging")).firstMatch
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Import", "导入"])).firstMatch
        if open.exists { open.tap() }
        let book = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", "TXT-Paging", "书架："
        )).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
    }

    private func launchAppearance(readingMode: String = "0", usesLegacyUI: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderStyle", "-pageAnim", readingMode, "-themeMode", "1"]
        if usesLegacyUI { app.launchArguments.append("-uiLegacyCompatibility") }
        app.launch()
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 20))
        return app
    }

    private func scrollToAppearanceElement(_ element: XCUIElement, in app: XCUIApplication) {
        // Partly visible rows can be hittable while their center is inside
        // the home-indicator area, where a tap does not activate the button.
        let safeBottom = app.frame.maxY - 24
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.midY <= safeBottom { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable && element.frame.midY <= safeBottom)
    }

    func testOnlineChapterCanRefreshFromReaderMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiReaderFailure", "-uiDemoReaderMenu", "-pageAnim", "0"]
        app.launch()
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let refresh = app.buttons["重新获取本章"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertFalse(more.exists)
        XCTAssertTrue(app.buttons["reader.retryChapter"].waitForExistence(timeout: 10))
    }

    func testFailedChaptersAllowRetryMenuAndSourceSwitchInBothReadingModes() throws {
        try exerciseFailedChapters(partial: false)
    }

    func testPartialChaptersAllowRetryMenuAndSourceSwitchInBothReadingModes() throws {
        try exerciseFailedChapters(partial: true)
    }

    private func exerciseFailedChapters(partial: Bool) throws {
        continueAfterFailure = false
        for mode in ["3", "0"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiReaderFailure", "-pageAnim", mode, "-themeMode", "0"]
            if partial { app.launchArguments += ["-uiReaderPartialFailure"] }
            app.launch()
            let retry = app.buttons["reader.retryChapter"]
            XCTAssertTrue(retry.waitForExistence(timeout: 20))
            retry.tap()
            XCTAssertTrue(app.buttons["reader.failureChangeSource"].waitForExistence(timeout: 10))
            app.buttons["reader.failureChangeSource"].tap()
            XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].waitForExistence(timeout: 10))
            app.buttons["取消"].tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 10))
            if mode == "3" {
                app.collectionViews["reader.continuous"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            } else {
                app.buttons["reader.failureMenu"].tap()
            }
            let changeSource = app.buttons["reader.changeSource"]
            XCTAssertTrue(changeSource.waitForExistence(timeout: 5))
            let more = app.buttons["更多"]
            XCTAssertEqual(changeSource.label, "换源")
            XCTAssertEqual(changeSource.frame.midY, more.frame.midY, accuracy: 2)
            XCTAssertLessThanOrEqual(changeSource.frame.maxX, more.frame.minX)
            changeSource.tap()
            XCTAssertTrue(app.navigationBars["为《长夜里的灯》换源"].waitForExistence(timeout: 10))
            attachScreenshot(app)
            app.terminate()
        }
    }

    func testPagedReadingReportsPageCountAndTurnsWithinTheSameChapter() throws {
        try exercisePagedReading(mode: "4", fontSize: "28")
    }

    func testLargeFontPagedReadingKeepsWholeLinesWhenTurningPages() throws {
        try exercisePagedReading(mode: "0", fontSize: "40")
    }

    func testCoverTapAcrossChapterBoundaryShowsHeadingOnFirstPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "settings", "-uiDemoFiles",
                               "-pageAnim", "0", "-themeMode", "1", "-titleMode", "0", "-tipFooterRight", "4", "-textSize", "20"]
        app.launch()
        openPagingFixture(in: app)
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        let footer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+")).firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        let total = try XCTUnwrap(footer.label.split(separator: "/").last.flatMap { Int($0) })
        XCTAssertGreaterThan(total, 1)
        let next = body.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        func waitForPage(_ number: Int) {
            expectation(for: NSPredicate(format: "label BEGINSWITH %@", "\(number)/"), evaluatedWith: footer)
            waitForExpectations(timeout: 5)
        }
        func checkChapterHeading() throws {
            waitForPage(1)
            let screenshot = try XCTUnwrap(body.screenshot().image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["zh-Hans"]
            request.regionOfInterest = CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
            try VNImageRequestHandler(cgImage: screenshot).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            XCTAssertTrue(lines.joined().filter { !$0.isWhitespace }.contains("第二章灯塔"), lines.description)
        }
        for number in 2...total {
            next.tap()
            waitForPage(number)
        }
        next.tap()
        try checkChapterHeading()
        body.swipeRight()
        waitForPage(total)
        next.tap()
        try checkChapterHeading()
        next.tap()
        waitForPage(2)
        body.swipeRight()
        try checkChapterHeading()
    }

    func testReaderEdgeDragCanCancelOnCurrentPageAndReturnToBookshelf() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "1", "-tipFooterRight", "6"]
        app.launch()
        let reader = app.textViews["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        reader.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let pageTwo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        func drag(to fraction: CGFloat) {
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(.init(dx: app.frame.width * fraction, dy: 0)),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        let position = pageTwo.label
        drag(to: 0.22)
        XCTAssertTrue(reader.isHittable)
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        XCTAssertEqual(pageTwo.label, position)
        let explore = app.tabBars.buttons["发现"]
        XCTAssertFalse(explore.exists && explore.isHittable)
        drag(to: 0.80)
        XCTAssertTrue(app.buttons["bookshelf.continue"].waitForExistence(timeout: 5))
        XCTAssertFalse(reader.exists)
        XCTAssertTrue(explore.isHittable)
        explore.tap()
        XCTAssertTrue(explore.isSelected)
    }

    func testContinuousReaderEdgeDragReturnsToBookDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoBookDetail", "-uiLegacyCompatibility", "-pageAnim", "3"]
        app.launch()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["开始阅读", "继续阅读"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15))
        read.tap()
        let reader = app.collectionViews["reader.continuous"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let edge = app.coordinate(withNormalizedOffset: .init(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(.init(dx: app.frame.width * 0.75, dy: 0)))
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        XCTAssertFalse(reader.exists)
    }

    func testLeftEdgeSwipeReturnsFromOpenReaderMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiDemoReaderMenu", "-pageAnim", "1"]
        app.launch()
        let reader = app.textViews["reader.text"]
        XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 15))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.46))
        edge.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: reader)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.tabBars.buttons["书架"].exists)
    }

    func testReturningFromBookshelfReaderKeepsHomeTabsUsable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "bookshelf", "-pageAnim", "0"]
        app.launch()
        let resume = app.buttons["bookshelf.continue"]
        let explore = app.tabBars.buttons["发现"]
        for swipeBack in [false, true] {
            XCTAssertTrue(resume.waitForExistence(timeout: 15))
            resume.tap()
            let reader = app.textViews["reader.text"]
            XCTAssertTrue(reader.waitForExistence(timeout: 10))
            XCTAssertFalse(explore.exists && explore.isHittable)
            reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if swipeBack {
                let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.45))
                edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(.init(dx: app.frame.width * 0.65, dy: 0)))
            } else {
                app.buttons["返回"].tap()
            }
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            XCTAssertTrue(explore.isHittable)
        }
        explore.tap()
        XCTAssertTrue(explore.isSelected)
    }

    func testSwipingOutOfReaderKeepsHomeTabBarOnScreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoTab", "bookshelf", "-pageAnim", "1"]
        app.launch()
        let explore = app.tabBars.buttons["发现"]
        XCTAssertTrue(explore.waitForExistence(timeout: 10))
        let explorePosition = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: explore.frame.midX, dy: explore.frame.midY))
        for _ in 0..<2 {
            let resume = app.buttons["bookshelf.continue"]
            resume.tap()
            XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 10))
            let edge = app.coordinate(withNormalizedOffset: .init(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(.init(dx: app.frame.width * 0.7, dy: 0)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            explorePosition.tap()
            XCTAssertTrue(explore.isSelected)
            app.tabBars.buttons["书架"].tap()
        }
    }

    func testShortSlowDragsReturnAndFastFlicksTurnInEitherDirection() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "1", "-tipFooterRight", "6"]
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        let footer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+.*")).firstMatch
        func drag(_ start: CGFloat, _ end: CGFloat, velocity: XCUIGestureVelocity = .slow) {
            let from = body.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
            let to = body.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: velocity, thenHoldForDuration: 0)
        }
        func expectPage(_ page: Int) {
            expectation(for: NSPredicate(format: "label BEGINSWITH %@", "\(page)/"), evaluatedWith: footer)
            waitForExpectations(timeout: 5)
        }
        expectPage(1)
        drag(0.75, 0.64)
        expectPage(1)
        drag(0.8, 0.25)
        expectPage(2)
        drag(0.25, 0.37)
        expectPage(2)
        drag(0.2, 0.75)
        expectPage(1)
        drag(0.72, 0.52, velocity: .fast)
        expectPage(2)
        drag(0.28, 0.48, velocity: .fast)
        expectPage(1)
        let start = body.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 125)))
        expectPage(2)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 10, dy: 145)))
        expectPage(2)
    }

    private func exercisePagedReading(mode: String, fontSize: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-uiPagingDiagnostics", "-pageAnim", mode, "-themeMode", "1", "-tipFooterRight", "6", "-textSize", fontSize]
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        let page = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+.*")).firstMatch
        let ready = expectation(for: NSPredicate { _, _ in
            print("[PagedReader] \(body.label) footer=\(page.label)")
            let total = page.label.split(separator: "/").last?.split(separator: " ").first.flatMap { Int($0) } ?? 0
            return page.exists && page.label.hasPrefix("1/") && total > 1
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        let chapter = body.value as? String
        let viewport = body.frame
        attachScreenshot(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.15)).tap()
        let next = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("2/") }, evaluatedWith: nil)
        wait(for: [next], timeout: 5)
        print("[PagedReader second] \(body.label) frame=\(body.frame)")
        XCTAssertEqual(body.frame.minY, viewport.minY, accuracy: 0.5)
        XCTAssertEqual(body.frame.height, viewport.height, accuracy: 0.5)
        XCTAssertEqual(body.value as? String, chapter)
        attachScreenshot(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.85)).tap()
        let previous = expectation(for: NSPredicate { _, _ in page.label.hasPrefix("1/") }, evaluatedWith: nil)
        wait(for: [previous], timeout: 5)
        XCTAssertEqual(body.value as? String, chapter)
        attachScreenshot(app)
    }

    func testBookInfoRoundTripsReuseReaderAndPreservePage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "0",
                               "-tipFooterRight", "6", "-textSize", "24"]
        app.launch()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let pageTwo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func openDetails() {
            center.tap()
            app.buttons["更多"].tap()
            app.buttons["书籍详情"].tap()
            let bar = app.navigationBars["书籍详情"]
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertTrue(bar.staticTexts["page.heading"].exists)
            XCTAssertTrue(bar.buttons["换源"].exists)
            XCTAssertTrue(bar.buttons["更多"].exists)
            XCTAssertFalse(bar.buttons["关闭"].exists)
        }
        for visit in 0..<3 {
            openDetails()
            switch visit {
            case 0:
                let bar = app.navigationBars["书籍详情"]
                attachScreenshot(app)
                bar.buttons["换源"].tap()
                let picker = app.navigationBars["为《长夜里的灯》换源"]
                XCTAssertTrue(picker.waitForExistence(timeout: 5))
                picker.buttons["取消"].tap()
                bar.buttons.firstMatch.tap()
            case 1:
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            default: app.buttons["继续阅读"].tap()
            }
            XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        }
        openDetails()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "第2章 · 连续阅读")).firstMatch
        for _ in 0..<4 where !chapter.isHittable { app.swipeUp(velocity: .slow) }
        chapter.tap()
        XCTAssertTrue(app.textViews["reader.text"].waitForExistence(timeout: 5))
        center.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第2章 · 连续阅读"))
            .firstMatch.waitForExistence(timeout: 5))
        app.buttons["返回"].tap()
        XCTAssertTrue(app.tabBars.buttons["书架"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["reader.text"].exists)
        XCTAssertFalse(app.navigationBars["书籍详情"].exists)
    }

    func testOnlineDirectoryUsesSourceChapterHeadingAndShowsCacheAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiReaderFailure", "-pageAnim", "0", "-themeMode", "1"]
        app.launchEnvironment["READER_TEST_AVAILABLE_CHAPTER_URL"] = "demo://chapter/3"
        app.launch()
        let menu = app.buttons["reader.failureMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["目录"].tap()

        let heading = app.staticTexts["reader.toc.title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertEqual(heading.label, "长夜里的灯")
        let cache = app.buttons["reader.toc.cache"]
        XCTAssertTrue(cache.waitForExistence(timeout: 5))
        XCTAssertTrue(cache.isHittable)
        let search = app.buttons["搜索章节"]
        XCTAssertGreaterThan(search.frame.minY, app.frame.height * 0.8)
        XCTAssertEqual(search.frame.midY, cache.frame.midY, accuracy: 2)
        app.buttons["定位当前章节"].tap()
        let first = app.buttons["reader.toc.0"]
        XCTAssertTrue(first.label.contains("第一章 · 雨夜"))
        XCTAssertFalse(first.label.contains("01"))
        let failedDownload = app.buttons["reader.toc.download.0"]
        XCTAssertTrue(failedDownload.waitForExistence(timeout: 5))
        failedDownload.tap()
        let failure = app.alerts["章节缓存失败"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        failure.buttons["好"].tap()
        XCTAssertTrue(failedDownload.isEnabled)

        let download = app.buttons["reader.toc.download.3"]
        download.tap()
        let downloadedRow = app.buttons["reader.toc.3"]
        let stored = expectation(for: NSPredicate(format: "value == %@", "已缓存"), evaluatedWith: downloadedRow)
        wait(for: [stored], timeout: 5)
        XCTAssertFalse(download.exists)
        XCTAssertEqual(first.value as? String, "未缓存")
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(heading.exists)
        attachScreenshot(app)

        search.tap()
        let field = app.textFields["搜索章节"]
        field.typeText("2")
        let result = app.buttons["reader.toc.1"]
        XCTAssertTrue(result.label.contains("灯塔"))
        XCTAssertLessThan(result.frame.maxY, field.frame.minY)
        XCTAssertFalse(cache.exists)
        XCTAssertFalse(first.exists)
        attachScreenshot(app)
    }

    func testDirectoryKeepsCurrentPageAndSliderJumpsToLastChapter() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "0",
                               "-themeMode", "1", "-tipFooterRight", "6", "-textSize", "24"]
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        let pageTwo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2/")).firstMatch
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(pageTwo.waitForExistence(timeout: 5))
        func showMenu() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        showMenu()
        app.buttons["目录"].tap()
        let currentRow = app.buttons["reader.toc.20"]
        XCTAssertTrue(currentRow.waitForExistence(timeout: 5))
        XCTAssertTrue(currentRow.isHittable)
        XCTAssertFalse(currentRow.label.contains("本章"))
        XCTAssertLessThan(app.staticTexts["reader.toc.title"].frame.minY, app.frame.height * 0.12)
        attachScreenshot(app)
        app.buttons["倒序"].tap()
        let lastRow = app.buttons["reader.toc.79"]
        XCTAssertTrue(lastRow.waitForExistence(timeout: 5))
        XCTAssertTrue(lastRow.isHittable)
        XCTAssertFalse(currentRow.isHittable)
        app.buttons["定位当前章节"].tap()
        XCTAssertTrue(currentRow.isHittable)
        currentRow.tap()
        XCTAssertTrue(pageTwo.exists)

        showMenu()
        let slider = app.sliders["reader.chapterSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 1)
        let moved = expectation(for: NSPredicate { _, _ in
            (body.value as? String ?? "").contains("第80章")
        }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        XCTAssertTrue(slider.isHittable)
        XCTAssertFalse(app.buttons["reader.returnToPosition"].exists)
        attachScreenshot(app)
    }

    func testPagedReadingChapterNavigationDirectorySearchAndSettings() throws {
        try exerciseChapterNavigationAndSettings(usesLegacyUI: false)
    }

    func testLegacyReadingChapterNavigationDirectorySearchAndPhotoPicker() throws {
        try exerciseChapterNavigationAndSettings(usesLegacyUI: true)
    }

    private func exerciseChapterNavigationAndSettings(usesLegacyUI: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-pageAnim", "0", "-themeMode", "1"]
        if usesLegacyUI { app.launchArguments.append("-uiLegacyCompatibility") }
        app.launch()
        let body = app.textViews["reader.text"]
        XCTAssertTrue(body.waitForExistence(timeout: 20))
        func waitForChapter(_ title: String) {
            let ready = expectation(for: NSPredicate { _, _ in
                (body.value as? String ?? "").contains(title)
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 15)
        }
        func showMenu() {
            if !app.buttons["目录"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 5))
        }
        waitForChapter("第一章 · 雨夜")
        showMenu()
        XCTAssertFalse(app.buttons["上一章"].isEnabled)
        app.buttons["下一章"].tap()
        waitForChapter("第二章 · 灯塔")
        showMenu()
        app.buttons["上一章"].tap()
        waitForChapter("第一章 · 雨夜")

        showMenu()
        app.buttons["目录"].tap()
        XCTAssertTrue(app.staticTexts["reader.toc.title"].waitForExistence(timeout: 5))
        let chapterSearch = app.textFields["搜索章节"]
        XCTAssertFalse(chapterSearch.exists)
        app.buttons["搜索章节"].tap()
        chapterSearch.typeText("天明")
        app.buttons["reader.toc.4"].tap()
        waitForChapter("第五章 · 天明")
        showMenu()
        XCTAssertFalse(app.buttons["下一章"].isEnabled)

        app.buttons["更多"].tap()
        app.buttons["搜索正文"].tap()
        XCTAssertTrue(app.navigationBars["正文搜索"].waitForExistence(timeout: 5))
        let contentSearch = app.searchFields["搜索本章"]
        contentSearch.tap()
        contentSearch.typeText("灯塔")
        let match = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "林深推开阁楼的窗")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        match.tap()
        XCTAssertFalse(app.navigationBars["正文搜索"].exists)

        showMenu()
        app.buttons["更多"].tap()
        app.buttons["reader.addBookmark"].tap()
        app.buttons["更多"].tap()
        app.buttons["书签列表"].tap()
        XCTAssertTrue(app.navigationBars["书签"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第五章 · 天明"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()

        showMenu()
        app.buttons["外观"].tap()
        XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        if usesLegacyUI {
            app.buttons["选择背景图片"].tap()
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            cancel.tap()
            XCTAssertTrue(app.navigationBars["阅读样式"].waitForExistence(timeout: 5))
        }
        app.navigationBars["阅读样式"].buttons["取消"].tap()
        showMenu()
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 5))
        app.buttons["保存"].tap()
        waitForChapter("第五章 · 天明")
        attachScreenshot(app)
    }

    func testContinuousDirectoryJumpsToSelectedChapter() throws {
        let (app, reader) = launchReader(shortChapters: false)
        let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.72))
        let end = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.40))
        start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        func showMenu() { reader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        showMenu()
        let origin = try value("position", in: reader)
        XCTAssertGreaterThan(origin, 0)
        app.buttons["目录"].tap()
        let search = app.textFields["搜索章节"]
        XCTAssertFalse(search.exists)
        app.buttons["搜索章节"].tap()
        search.typeText("9999")
        app.buttons["取消"].tap()
        XCTAssertFalse(search.exists)
        XCTAssertTrue(app.buttons["reader.toc.20"].isHittable)
        app.buttons["搜索章节"].tap()
        search.typeText("70")
        let target = app.buttons["reader.toc.69"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        let moved = expectation(for: NSPredicate { _, _ in
            (reader.value as? String ?? "").contains("chapter=69 ")
        }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        showMenu()
        XCTAssertTrue(app.buttons["目录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reader.returnToPosition"].exists)
    }

    func testForwardAndReverseFlicksKeepMomentumAcrossChapterInsertion() throws {
        let (app, reader) = launchReader(shortChapters: false)
        let initial = try value("chapter", in: reader)
        for _ in 0..<6 { flick(reader, forward: true) }
        let forward = try value("chapter", in: reader)
        XCTAssertGreaterThan(forward, initial + 2)
        for _ in 0..<6 { flick(reader, forward: false) }
        XCTAssertLessThan(try value("chapter", in: reader), forward)
        XCTAssertGreaterThan(try value("decelInsertions", in: reader), 0)
        XCTAssertGreaterThan(try value("continued", in: reader), 0)
        XCTAssertEqual(try value("interrupted", in: reader), 0)
        attachScreenshot(app)
    }

    func testManyShortChaptersFlowPastTheInitialWindow() throws {
        let (app, reader) = launchReader(shortChapters: true)
        let initial = try value("chapter", in: reader)
        for _ in 0..<4 { flick(reader, forward: true) }
        let forward = try value("chapter", in: reader)
        XCTAssertGreaterThan(forward, initial + 5)
        for _ in 0..<4 { flick(reader, forward: false) }
        XCTAssertLessThan(try value("chapter", in: reader), forward)
        XCTAssertEqual(try value("interrupted", in: reader), 0)
        attachScreenshot(app)
    }

    private func launchReader(shortChapters: Bool) -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoReader", "-uiScrollRegression", "-pageAnim", "3", "-themeMode", "0"]
        if shortChapters { app.launchArguments.append("-uiShortChapters") }
        app.launch()
        let reader = app.collectionViews["reader.continuous"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        var lastInitialState = "<not reported>"
        let ready = expectation(for: NSPredicate { _, _ in
            let text = reader.value as? String ?? "<missing>"
            if text != lastInitialState {
                print("[ContinuousReaderInitial] \(text)")
                lastInitialState = text
            }
            return text.contains("chapter=20 ") && !text.contains("chapters=1 ")
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 20)
        return (app, reader)
    }

    private func flick(_ reader: XCUIElement, forward: Bool) {
        let start = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: forward ? 0.8 : 0.2))
        let end = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: forward ? 0.2 : 0.8))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func value(_ name: String, in reader: XCUIElement) throws -> Int {
        let fields = (reader.value as? String ?? "").split(separator: " ")
        let field = try XCTUnwrap(fields.first { $0.hasPrefix(name + "=") })
        let value = try XCTUnwrap(Int(field.dropFirst(name.count + 1)))
        print("[ContinuousReader] \(reader.value ?? "")")
        return value
    }

    private func attachScreenshot(_ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
extension XCUIApplication {
    func backgroundRGB(x: CGFloat = 0.02, y: CGFloat = 0.28) throws -> [Int] {
        let image = try XCTUnwrap(screenshot().image.cgImage)
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(
            x: floor(CGFloat(image.width) * x), y: floor(CGFloat(image.height) * y), width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
}
