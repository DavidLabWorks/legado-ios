import SwiftUI
import Translation
import UIKit
import UniformTypeIdentifiers

struct ReaderView: View {
    @AppStorage(EPUBReadingMode.preferenceKey) private var defaultEPUBMode = EPUBReadingMode.original
    @State private var sessionEPUBMode: EPUBReadingMode?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @StateObject private var model: ReaderViewModel
    private var book: Book { model.book }
    @State private var sourceSwitchBook: Book?
    @StateObject private var speech = ReaderSpeechController()
    private enum ReaderSheet: Hashable, Identifiable {
        case bookmarks, bookInfo, listening
        case dictionary(String)
        case replaceRule(ReplaceRule)
        case originalWebPage(URL)
        var id: Self { self }
    }

    @State private var translationText: String?
    @State private var textSelection: ReaderTextSelection?
    @State private var activeSheet: ReaderSheet?
    private enum BottomPanel { case appearance, autoRead, settings }
    @State private var changingPageAnimation = false
    @State private var draftReplaceRules = false
    @State private var draftDefaultMode = EPUBReadingMode.original
    @State private var savingPanel = false
    @State private var bottomPanel: BottomPanel?
    @State private var showsTableOfContents = false
    @State private var readerSessionActive = false
    @State private var chapterCommentsTarget: ReaderChapterCommentsTarget?
    @State private var browserChapter: BookChapter?
    @State private var illustrationChapter: BookChapter?
    @State private var isAutoReading = false
    @State private var showsReaderMenu = false
    @State private var followsSystemBrightness = true
    @State private var readerBrightness = Double(UIScreen.main.brightness)
    @State private var brightnessBeforeReading = Double(UIScreen.main.brightness)
    @State private var tocDescending = false
    @State private var readerSettingSaveError: String?
    @State private var backgroundImage: UIImage?
    @State private var backgroundError: String?
    @State private var showsBackgroundPicker = false
    @State private var showsTypographySettings = false
    @State private var showsPageSettings = false
    @State private var marginArea: MarginArea = .body
    @State private var showsFontImporter = false
    @State private var fontError: String?
    @State private var readerJumpPosition: Int?
    @State private var showsContentSearch = false
    @State private var contentSearchQuery = ""
    @State private var readerPosition = 0
    @State private var readerPageRanges: [NSRange] = []
    @State private var listeningPack: OfflineVoicePack?
    @State private var listeningVoice = OfflineVoice.uncleFu
    @State private var speechChapter: Int?
    @State private var speechPageIndex = 0
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var readerRenderRevision = 0
    @State private var isWaitingForNextChapter = false
    @State private var isWaitingForPreviousChapter = false
    @State private var resumesSpeechAfterChapterLoad = false
    @State private var speechTimerTask: Task<Void, Never>?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var progressSaveGeneration = 0
    @State private var speechStartGeneration = 0
    @State private var speechTimerRemaining = 0
    @State private var isSavingBookmark = false
    @ScaledMetric(relativeTo: .subheadline) private var pageSliderLabelWidth: CGFloat = 92
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 21
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("textFont") private var fontPath = ""
    @AppStorage("readerFontRevision") private var fontRevision = 0
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = ReaderTypography.defaultTitleBottomSpacing
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("headerPaddingBottom") private var headerPaddingBottom = 0.0
    @AppStorage("headerPaddingLeft") private var headerPaddingLeft = 16.0
    @AppStorage("headerPaddingRight") private var headerPaddingRight = 16.0
    @AppStorage("headerPaddingTop") private var headerPaddingTop = 0.0
    @AppStorage("footerPaddingBottom") private var footerPaddingBottom = 6.0
    @AppStorage("footerPaddingLeft") private var footerPaddingLeft = 16.0
    @AppStorage("footerPaddingRight") private var footerPaddingRight = 16.0
    @AppStorage("footerPaddingTop") private var footerPaddingTop = 6.0
    @AppStorage("showHeaderLine") private var showHeaderLine = false
    @AppStorage("showFooterLine") private var showFooterLine = true
    @AppStorage("tipHeaderLeft") private var tipHeaderLeft = 2
    @AppStorage("tipHeaderMiddle") private var tipHeaderMiddle = 0
    @AppStorage("tipHeaderRight") private var tipHeaderRight = 3
    @AppStorage("tipFooterLeft") private var tipFooterLeft = 1
    @AppStorage("tipFooterMiddle") private var tipFooterMiddle = 0
    @AppStorage("tipFooterRight") private var tipFooterRight = 6
    @AppStorage("headerMode") private var headerMode = 0
    @AppStorage("footerMode") private var footerMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    @AppStorage("autoReadSpeed") private var autoReadSpeed = 10
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @ReaderPanelPreference("readerSimplifiedChinese") private var simplifiedChinese = false
    @AppStorage("readerFullJustify") private var fullJustify = true
    @ReaderPanelPreference("readerKeepScreenOn") private var keepScreenOn = false
    @ReaderPanelPreference("readerHideHomeIndicator") private var hideHomeIndicator = false
    @ReaderPanelPreference("readerHideStatusBar") private var hideStatusBar = false
    @AppStorage("readerBrightness") private var storedReaderBrightness = 0.0
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @State private var pageAnimation: Int
    @ReaderPanelPreference("screenOrientation") private var screenOrientation = "0"

    init(prepared model: ReaderViewModel) {
        _pageAnimation = State(initialValue: model.book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _readerPosition = State(initialValue: min(model.requestedPosition, max(0, model.content.utf16.count - 1)))
        _model = StateObject(wrappedValue: model)
    }

    init(book: Book, chapters: [BookChapter], initialIndex: Int, source: BookSource) {
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
            source: source
        ))
    }

    init(book: Book, chapters: [BookChapter], initialIndex: Int) {
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex
        ))
    }

    init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        var readerChapters = chapters
        var readerInitialIndex = initialIndex
        var readerContent = content
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiScrollRegression") {
            readerChapters = (0..<80).map {
                BookChapter(url: "demo://scroll/\($0)", title: "第\($0 + 1)章 · 连续阅读", bookUrl: book.bookUrl, index: $0)
            }
            readerInitialIndex = 20
            if arguments.contains("-uiShortChapters") { readerContent = "短章正文，继续向下可以自然读到下一章。" }
        }
        #endif
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        #if DEBUG
        if arguments.contains("-uiComicRegression") {
            let base = ProcessInfo.processInfo.environment["COMIC_TEST_BASE_URL"] ?? "http://127.0.0.1:18089"
            var source = BookSource(bookSourceUrl: base, bookSourceName: "漫画回归测试")
            source.bookSourceType = 2
            source.header = "{\"X-Comic-Test\":\"fixture\"}"
            var rules = ContentRule()
            rules.content = ".page@html"
            rules.imageStyle = "FULL"
            source.ruleContent = rules
            let session = UUID().uuidString
            let chapters = (0..<3).map {
                BookChapter(url: "\(base)/chapter/\($0)?session=\(session)", title: "第\($0 + 1)话 · 漫画测试", bookUrl: book.bookUrl, index: $0)
            }
            _model = StateObject(wrappedValue: ReaderViewModel(book: book, chapters: chapters,
                initialIndex: 0, source: source, cache: ChapterContentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(session))))
            return
        }
        if arguments.contains("-uiReaderFailure") {
            _model = StateObject(wrappedValue: ReaderViewModel(
                book: book, chapters: readerChapters, initialIndex: readerInitialIndex,
                source: BookSource(bookSourceUrl: "https://reader-failure.invalid", bookSourceName: "正文失败测试源"),
                service: ReaderFailureTestLoader()
            ))
            return
        }
        #endif
        _model = StateObject(wrappedValue: ReaderViewModel(
            demoBook: book,
            chapters: readerChapters,
            initialIndex: readerInitialIndex,
            content: readerContent
        ))
    }


    private var isLocalEPUB: Bool {
        book.origin == "local" && URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub"
    }

    private var defaultEPUBSelection: Binding<EPUBReadingMode> {
        Binding(get: { defaultEPUBMode }, set: { mode in
            if sessionEPUBMode == nil { sessionEPUBMode = defaultEPUBMode }
            defaultEPUBMode = mode
        })
    }

    var body: some View {
        if isLocalEPUB, (sessionEPUBMode ?? defaultEPUBMode) == .original {
            EPUBReaderView(book: book, chapters: model.chapters, initialIndex: model.currentIndex,
                           restoresSavedLocation: sessionEPUBMode == nil, defaultMode: defaultEPUBSelection) { chapterIndex in
                model.select(index: chapterIndex)
                sessionEPUBMode = .text
            }
        } else {
            textReaderBody
        }
    }

    private var menuBackGesture: ReaderMenuBackGesture {
        ReaderMenuBackGesture(menuVisible: showsReaderMenu) { dismiss() }
    }

    private var textReaderBody: some View {
        readerCanvas
        .readerPresentationColorScheme(resolvedStyle.id == "night" ? .dark : .light)
        .readingTabBarHidden()
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(hideStatusBar)
        .readingHomeIndicatorHidden(hideHomeIndicator)
        .alert("阅读设置未保存", isPresented: readerSettingErrorPresented(inSettings: false)) {
            Button("好", role: .cancel) { readerSettingSaveError = nil }
        } message: { Text(readerSettingSaveError ?? "") }
        .alert("朗读中断", isPresented: Binding(
            get: { speech.errorMessage != nil && activeSheet == nil && bottomPanel == nil },
            set: { if !$0 { speech.clearError() } }
        )) {
            Button("重试") { closePlayer(); startListening() }
            Button("取消", role: .cancel) { speech.clearError() }
        } message: { Text(speech.errorMessage ?? "") }
        .onAppear {
            guard !readerSessionActive else { return }
            readerSessionActive = true
            activity.beginReading(book)
            speech.onNextChapter = { moveSpeechToChapter(direction: 1) }
            speech.onPreviousChapter = { moveSpeechToChapter(direction: -1) }
            speech.onRemoteStop = { closePlayer() }
            UIDevice.current.isBatteryMonitoringEnabled = true
            brightnessBeforeReading = Double(UIScreen.main.brightness)
            if storedReaderBrightness >= 0.05 {
                followsSystemBrightness = false
                readerBrightness = storedReaderBrightness
                UIScreen.main.brightness = CGFloat(storedReaderBrightness)
            } else {
                readerBrightness = brightnessBeforeReading
            }
            ReaderScreenOrientation.apply(screenOrientation)
            if ProcessInfo.processInfo.arguments.contains("-uiDemoBookmarks") {
                activeSheet = .bookmarks
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderMenu") {
                showsReaderMenu = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderStyle") {
                DispatchQueue.main.async { openPanel(.appearance) }
            }
        }
        .onDisappear {
            guard !showsTableOfContents, !showsContentSearch, chapterCommentsTarget == nil else { return }
            if bottomPanel != nil { cancelPanel() }
            readerSessionActive = false
            model.stopBackgroundReading()
            isAutoReading = false
            UIApplication.shared.isIdleTimerDisabled = false
            closePlayer()
            saveProgress(immediate: true)
            ReaderScreenOrientation.restoreApplicationDefault()
            if sessionEPUBMode != .original { activity.cancelReading(book) }
            UIDevice.current.isBatteryMonitoringEnabled = false
            if !followsSystemBrightness {
                UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
            }
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            speech.onNextChapter = nil
            speech.onPreviousChapter = nil
            speech.onRemoteStop = nil
        }
        .modifier(menuBackGesture)
        .overlay {
            GeometryReader { viewport in
                VStack(spacing: 0) {
                    if showsReaderMenu {
                        readerTopChrome
                            .modifier(menuBackGesture)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                    if listeningPack != nil {
                        ReaderListeningPlayer(book: book, speech: speech, tint: foregroundColor,
                                              background: readerChromeBackground, viewportHeight: viewport.size.height,
                                              close: closePlayer)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if showsReaderMenu {
                        readerBottomChrome
                            .modifier(menuBackGesture)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(bottomPanel == nil ? readerMenuAnimation : nil, value: showsReaderMenu)
            }
            .coordinateSpace(name: ReaderListeningPlayer.viewportSpace)
        }
        .accessibilityHidden(bottomPanel != nil)
        .allowsHitTesting(bottomPanel == nil)
        .overlay { readerBottomPanel.allowsHitTesting(bottomPanel != nil) }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .bookmarks: bookmarksSheet
            case .listening:
                ReadingNavigationStack {
                    listeningPreferences
                }
            case .dictionary(let term): ReaderDictionary(term: term)
            case .replaceRule(let rule):
                ReplaceRuleEditorView(rule: rule, readingBook: book)
            case .originalWebPage(let url):
                InAppWebBrowser(url: url, close: { activeSheet = nil })
                    .ignoresSafeArea()
            case .bookInfo:
                ReaderBookInfoSheet(book: model.bookAtReadingPosition(readerPosition),
                                    source: model.source ?? sourceLibrary.sources.first { $0.id == book.origin },
                                    chapters: model.chapters)
                    .environment(\.resumeBookReading, resumeFromBookInfo)
            }
        }
        .fullScreenCover(isPresented: $showsTableOfContents) { tableOfContents }
        .fullScreenCover(isPresented: $showsContentSearch) { contentSearchSheet }
        .fullScreenCover(item: $chapterCommentsTarget) { target in
            ReaderChapterCommentsView(target: target)
                .id(target.id)
        }
        .sheet(item: $browserChapter) { chapter in
            if let source = model.source {
                BrowserChapterView(book: book, chapter: chapter, source: source, nextChapterURL: model.nextChapter?.url) { report in
                    try await model.acceptBrowserChapter(report, chapter: chapter, source: source)
                }
            }
        }
        .sheet(item: $illustrationChapter) { chapter in
            EPUBIllustrationsView(book: book, chapter: chapter)
        }
        .sheet(item: $sourceSwitchBook) { currentBook in
            ReadingNavigationStack {
                SourceSwitchView(book: currentBook, sources: sourceLibrary.sources) { report, source in
                    await progressSaveTask?.value
                    if library.contains(book) {
                        guard await library.commitSourceSwitch(oldBookURL: book.bookUrl, report: report) else { return false }
                    }
                    await activity.endReading(book)
                    await model.applySourceSwitch(report, source: source)
                    readerPosition = report.book.durChapterPos
                    readerJumpPosition = nil
                    readerPageRanges = []
                    readerRenderRevision &+= 1
                    activity.beginReading(report.book)
                    return true
                }
            }
        }
        .background { readerLoadingTasks }
        .background { readerObservers }
    }

    private var readerLoadingTasks: some View {
        Color.clear
        .onChange(of: replaceRules.rules) { rules in model.replaceReadingRules(rules, at: readerPosition) }
        .task(id: model.chapterLoadGeneration) {
            isWaitingForNextChapter = false
            isWaitingForPreviousChapter = false
            let needsInitialPosition = !model.hasLoadedCurrentChapter
            let pending = progressSaveTask
            let pendingGeneration = progressSaveGeneration
            guard !Task.isCancelled else { return }
            readerJumpPosition = nil
            readerPageRanges = []
            if needsInitialPosition, model.requestedPosition != .max { readerPosition = model.requestedPosition }
            await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [])
            guard !Task.isCancelled else { return }
            if needsInitialPosition {
                readerPosition = pageAnimation == 3
                    ? continuousPosition(model.requestedPosition, content: model.content)
                    : min(model.requestedPosition, max(model.content.utf16.count - 1, 0))
            }
            // Keep writes ordered without delaying the chapter request or its first render.
            await pending?.value
            guard !Task.isCancelled else { return }
            if progressSaveGeneration == pendingGeneration { progressSaveTask = nil }
            if let chapter = model.currentChapter {
                await library.updateProgress(for: book, chapter: chapter, position: readerPosition)
            }
            if resumesSpeechAfterChapterLoad {
                resumesSpeechAfterChapterLoad = false
                if model.content.isEmpty { closePlayer() } else { startConfiguredSpeech() }
            }
        }
        .task(id: "\(model.chapterLoadGeneration):\(model.currentIndex):\(model.hasLoadedCurrentChapter)") {
            model.checkForNewChapters(using: library) { readerPosition }
        }
        .task(id: "\(model.chapterLoadGeneration):\(pageAnimation == 3):\(model.hasLoadedCurrentChapter):\(model.scrollRevision):\(model.chapters.count)") {
            guard pageAnimation == 3 else { return }
            await model.prepareContinuousReading(rules: model.usesReplaceRules ? replaceRules.rules : [])
        }
        .task {
            let storedImage = await Task.detached(priority: .utility) { ReaderBackgroundStore.load() }.value
            if !Task.isCancelled, backgroundImage == nil, FileManager.default.fileExists(atPath: ReaderBackgroundStore.url.path) {
                backgroundImage = storedImage
            }
        }
    }

    private var readerObservers: some View {
        Color.clear
        .onAppear { updateIdleTimer() }
        .onChange(of: keepScreenOn) { _ in
            updateIdleTimer()
        }
        .onChange(of: adjacentReadiness) { _ in
            if model.isContinuationWindowReady, isWaitingForNextChapter {
                isWaitingForNextChapter = false
                readerRenderRevision &+= 1
            }
            if model.isPreviousWindowReady, isWaitingForPreviousChapter {
                advanceToPreparedPreviousChapter()
            }
        }
        .onChange(of: isAutoReading) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.isSpeaking) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.completionCount) { _ in
            if readAloudByPage {
                continueSpeechToNextPage()
            } else {
                continueSpeechToNextChapter()
            }
        }
        .onChange(of: speech.spokenPosition) { position in
            guard let position, speechChapter == model.currentIndex, pageAnimation != 3,
                  !readerPageRanges.indices.contains(currentPage - 1) || !NSLocationInRange(position, readerPageRanges[currentPage - 1]) else { return }
            readerJumpPosition = position
        }
        .onChange(of: speech.errorMessage) { error in
            if error != nil { closePlayer() }
        }
        .onChange(of: readAloudByPage) { _ in
            restartSpeechAfterReaderLayoutChange()
        }
        .onChange(of: readAloudWakeLock) { _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(readerBrightness)
                }
                activity.beginReading(book)
            } else {
                isAutoReading = false
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                }
                saveProgress(immediate: true)
                activity.cancelReading(book)
            }
        }
        .onChange(of: screenOrientation) { value in
            ReaderScreenOrientation.apply(value)
        }
        .onChange(of: model.chapterLoadGeneration) { _ in endTextSelection() }
        .onChange(of: themeMode) { _ in
            isAutoReading = false
            readerJumpPosition = nil
            currentPage = 1
            totalPages = 1
        }
        .onChange(of: pageAnimation) { value in
            isAutoReading = false
            saveProgress(immediate: true)
            readerJumpPosition = readerPosition
            currentPage = 1
            totalPages = 1

        }
    }


    private var readerCanvas: some View {
        ZStack {
            readerContent
            readerMenuDismissOverlay
        }
        .background {
            ZStack {
                backgroundColor
                if let backgroundImage = activeBackgroundImage {
                    Image(uiImage: backgroundImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    private var waitingForChapter: Bool {
        model.content.isEmpty && !model.hasLoadedCurrentChapter
    }

    @ViewBuilder private var readerContent: some View {
        if pageAnimation != 3, model.content.isEmpty && model.hasLoadedCurrentChapter {
            VStack(spacing: 18) {
                Image(systemName: "text.page.slash").font(.largeTitle)
                Text(model.currentChapterError == nil ? "正文为空" : "本章加载失败").font(.title3.weight(.semibold))
                Text(model.currentChapterError ?? "本章暂无正文。")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                readerRecoveryActions
                Button("打开阅读菜单") { showsReaderMenu = true }
                    .accessibilityIdentifier("reader.failureMenu")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
        } else {
            VStack(spacing: 0) {
                if headerVisible { readerTipBar(isHeader: true) }
                readerSurface
                    .opacity(textSelection == nil ? 1 : 0)
                    .accessibilityHidden(textSelection != nil)
                    .overlay { if let textSelection { selectionControls(textSelection) } }
                    .transaction { $0.animation = nil }
                    .allowsHitTesting(!waitingForChapter)
                    .accessibilityHidden(waitingForChapter)
                readerFooter
            }
            .frame(maxWidth: readingColumnMaxWidth)
            .frame(maxWidth: .infinity)
            .overlay {
                if waitingForChapter, model.isWaitingForSource || model.onlineSourceID == nil {
                    ReaderLoadingOverlay(title: model.title.readerText(simplified: simplifiedChinese))
                        .id(model.chapterLoadGeneration)
                        .onTapGesture { showsReaderMenu.toggle() }
                }
            }
            .overlay(alignment: .bottom) {
                if let error = model.currentChapterError, !showsReaderMenu {
                    VStack(spacing: 10) {
                        Text(model.content.isEmpty ? "本章加载失败" : "本章加载不完整").font(.subheadline.weight(.semibold))
                        Text(error).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        readerRecoveryActions
                        Button("打开阅读菜单") { showsReaderMenu = true }
                            .accessibilityIdentifier("reader.failureMenu")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(foregroundColor)
                    .background(backgroundColor)
                }
            }
        }
    }

    @ViewBuilder private var readerRecoveryActions: some View {
        HStack(spacing: 16) {
            Button(action: refreshCurrentChapter) {
                Label(model.scrollRetries.contains(model.currentIndex) ? "重试中…" : "重试本章", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.scrollRetries.contains(model.currentIndex))
            .accessibilityIdentifier("reader.retryChapter")
            if model.source != nil {
                Button("换源", action: openSourceSwitch)
                    .accessibilityIdentifier("reader.failureChangeSource")
            }
        }
        .readingSecondaryButtonStyle()
        if model.source?.ruleContent?.content?.contains("source.bookSourceComment") == true, let chapter = model.currentChapter {
            Button("在原站打开本章") { browserChapter = chapter }
        }
    }

    private func resumeFromBookInfo(_ selectedBook: Book, _ chapters: [BookChapter], _ source: BookSource?, _ index: Int?) {
        activeSheet = nil
        if book.bookUrl != selectedBook.bookUrl || book.origin != selectedBook.origin || model.chapters != chapters {
            let previous = book
            var updated = selectedBook
            if let index {
                updated.durChapterIndex = index
                updated.durChapterPos = 0
            }
            stopSpeechForContentChange()
            model.replaceReadingDirectory(book: updated, chapters: chapters, source: source)
            readerPosition = model.requestedPosition
            readerJumpPosition = nil
            readerRenderRevision &+= 1
            if previous.bookUrl != updated.bookUrl || previous.origin != updated.origin {
                Task {
                    await activity.endReading(previous)
                    activity.beginReading(updated)
                }
            }
        } else if let index, index != model.currentIndex {
            navigate(to: index)
        }
    }

    private func openSourceSwitch() {
        stopSpeechIfNeeded()
        isAutoReading = false
        saveProgress(immediate: true)
        showsReaderMenu = false
        sourceSwitchBook = model.bookAtReadingPosition(readerPosition)
    }

    private func openChapterComments(at index: Int) {
        guard let target = model.commentsTarget(at: index) else { return }
        showsReaderMenu = false
        chapterCommentsTarget = target
    }

    @ViewBuilder private var readerFooter: some View {
        if pageAnimation != 3, model.commentsTarget(at: model.currentIndex) != nil {
            // A changing footer height would repaginate the text precisely when the last page appears.
            HStack(spacing: 0) {
                if footerVisible { readerTipBar(isHeader: false) }
                Spacer(minLength: 0)
                if !readerPageRanges.isEmpty, currentPage == totalPages {
                    Button {
                        openChapterComments(at: model.currentIndex)
                    } label: {
                        Label("本章评论", systemImage: "text.bubble")
                            .font(.subheadline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(foregroundColor)
                    .accessibilityIdentifier("reader.chapterEndComments")
                }
            }
            .frame(minHeight: 44)
        } else if footerVisible {
            readerTipBar(isHeader: false)
        }
    }

    @ViewBuilder private var readerSurface: some View {
        if model.hasImageContent, let chapter = model.currentChapter {
            VStack(spacing: 0) {
                ReaderComicView(simplifiedChinese: simplifiedChinese, blocks: model.imageBlocks, source: model.imageSource, book: model.book, chapter: chapter,
                    background: activeBackgroundImage == nil ? resolvedStyle.background : .clear,
                    foreground: resolvedStyle.foreground, fontSize: CGFloat(fontSize),
                    requestedPosition: model.requestedPosition, jumpPosition: readerJumpPosition,
                    onPosition: { position, page, count in
                        readerPosition = position
                        currentPage = page
                        totalPages = count
                        readerPageRanges = model.imageBlocks.compactMap { block in
                            if case .image = block.content { return block.range }; return nil
                        }
                    }, onMenuTap: { showsReaderMenu.toggle() }, onChapterBoundary: { direction in
                        if direction < 0, model.canGoPrevious { moveChapter(-1, previousPosition: .max) }
                        if direction > 0, model.canGoNext { moveChapter(1) }
                    }, onSelectText: beginTextSelection)
                HStack(spacing: 6) {
                    Button { moveChapter(-1) } label: {
                        Label("上一章", systemImage: "chevron.left")
                            .frame(minHeight: 44)
                    }
                    .disabled(!model.canGoPrevious)
                    Spacer(minLength: 0)
                    Text("第 \(currentPage) / \(totalPages) 张")
                        .font(.footnote.monospacedDigit())
                        .accessibilityLabel("本章第 \(currentPage) 张，共 \(totalPages) 张")
                    Spacer(minLength: 0)
                    Button { moveChapter(1) } label: {
                        HStack(spacing: 6) { Text("下一章"); Image(systemName: "chevron.right") }
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("下一章")
                    .disabled(!model.canGoNext)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .tint(foregroundColor)
                .foregroundStyle(foregroundColor)
                .background(readerChromeBackground)
            }
        } else if pageAnimation == 3 {
            ReaderScrollView(
                configuration: readerTextConfiguration,
                chapters: model.visibleScrollChapters,
                resetID: model.scrollRevision,
                activeIndex: model.currentIndex,
                loadingAhead: model.isLoadingScrollAhead,
                loadingBehind: model.isLoadingScrollBehind,
                onNeedChapters: { direction in
                    Task { await model.extendContinuousReading(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : []) }
                },
                onPositionChanged: { index, position in
                    if index != model.currentIndex {
                        if speechChapter == model.currentIndex { closePlayer() }
                        saveProgress(immediate: true)
                        model.updateContinuousPosition(chapter: index)
                        readerJumpPosition = nil
                    }
                    let resolved = min(max(position, 0), model.content.utf16.count)
                    if readerPosition != resolved { readerPosition = resolved }
                },
                onRetainChapters: { model.retainContinuousChapters($0) },
                onOpenComments: openChapterComments
            )
        } else {
            readerTextConfiguration
        }
    }

    private var readerTextConfiguration: ReaderTextView {
        ReaderTextView(
            simplifiedChinese: simplifiedChinese,
            adjacentPagePreview: model.adjacentPagePreview(direction:),
            text: readerDisplayText,
            title: model.title,
            previousTitle: pageAnimation == 3 ? model.previousTitle : nil,
            previousText: pageAnimation == 3 ? model.previousContent : "",
            isPreviousReady: pageAnimation == 3 && model.isPreviousWindowReady,
            continuationTitle: pageAnimation == 3 ? model.continuationTitle : nil,
            continuationText: pageAnimation == 3 ? model.continuationContent : "",
            isContinuationReady: pageAnimation == 3 && model.isContinuationWindowReady,
            isVolume: model.currentChapter?.isVolume == true,
            fontSize: fontSize,
            fontPath: fontPath,
            fontRevision: fontRevision,
            letterSpacing: letterSpacing,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            paragraphIndent: paragraphIndent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            paddingTop: paddingTop,
            paddingBottom: paddingBottom,
            headerInset: 0,
            footerInset: 0,
            fontWeight: fontWeight,
            titleMode: titleMode,
            titleSize: titleSize,
            titleTopSpacing: titleTopSpacing,
            titleBottomSpacing: titleBottomSpacing,
            underlineMode: underlineMode,
            onSelectText: beginTextSelection,
            fullJustify: fullJustify,
            pageAnimation: pageAnimation,
            isEInkMode: themeMode == "3",
            backgroundColor: activeBackgroundImage == nil ? resolvedStyle.background : .clear,
            foregroundColor: resolvedStyle.foreground,
            spokenRange: speechChapter == model.currentIndex ? speech.spokenRange : nil,
            spokenPosition: speechChapter == model.currentIndex ? speech.spokenPosition : nil,
            speechColor: resolvedStyle.speechBackground,
            requestedPosition: pageAnimation == 3 ? readerPosition : model.requestedPosition,
            jumpPosition: readerJumpPosition,
            renderRevision: readerRenderRevision,
            readerPosition: $readerPosition,
            pageRanges: $readerPageRanges,
            currentPage: $currentPage,
            totalPages: $totalPages,
            isAutoReading: isAutoReading,
            isAutoReadPaused: pausesAutoReading,
            isLoadingNextChapter: isWaitingForNextChapter,
            secondsPerScreen: Double(autoReadSpeed),
            onReachedEnd: { boundaryPosition in
                if pageAnimation == 3 {
                    requestNextChapter()
                    return
                }
                if model.canGoNext {
                    showsReaderMenu = false
                    readerPosition = boundaryPosition
                    saveProgress(immediate: true)
                    readerJumpPosition = nil
                    // Keep every chapter in its own TextKit document. Appending
                    // text here makes the absolute UTF-16 offset belong to the
                    // previous chapter while progress is saved under the next.
                    model.goNext()
                    readerPosition = model.requestedPosition
                } else {
                    isAutoReading = false
                }
            },
            onReachedStart: { boundaryPosition in
                if pageAnimation == 3 {
                    requestPreviousChapter()
                    return
                }
                guard model.canGoPrevious else { return }
                showsReaderMenu = false
                readerPosition = boundaryPosition
                saveProgress(immediate: true)
                readerJumpPosition = nil
                model.goPrevious(position: Int.max)
                if model.hasLoadedCurrentChapter { readerPosition = max(0, model.content.utf16.count - 1) }
            },
            onEnteredPrevious: { position in
                guard pageAnimation == 3, model.canGoPrevious, model.hasPreviousWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.previousContent)
                readerJumpPosition = nil
                model.promotePrevious(position: readerPosition)
            },
            onEnteredContinuation: { position in
                guard pageAnimation == 3, model.canGoNext, model.hasContinuationWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.continuationContent)
                readerJumpPosition = nil
                model.promoteContinuation(position: readerPosition)
            },
            onDeferredRender: { readerRenderRevision &+= 1 },
            onCancelNextLoading: { isWaitingForNextChapter = false },
            onPageChanged: pageDidChange,
            onMenuTap: { showsReaderMenu.toggle() },
            holdsDisplayedPage: waitingForChapter,
            chapterGeneration: model.displayedChapterGeneration
        )
    }

    @ViewBuilder private var readerMenuDismissOverlay: some View {
        if showsReaderMenu {
            Color.black
                .opacity(resolvedStyle.id == "night" ? 0.08 : 0.03)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showsReaderMenu = false }
                .accessibilityHidden(true)
        }
    }

    private var readingColumnMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 760 : .greatestFiniteMagnitude
    }

    private var adjacentReadiness: Int {
        (model.isPreviousWindowReady ? 1 : 0) | (model.isContinuationWindowReady ? 2 : 0)
    }

    private var readerDisplayText: String {
        if !model.content.isEmpty { return model.content }
        if pageAnimation == 3 {
            return String(repeating: "\n", count: 80)
        }
        if model.isLoading || !model.hasLoadedCurrentChapter {
            return "正文正在后台加载…\n\n你可以继续向下滚动，下一章已经提前生成。"
        }
        let reason = model.diagnostics.first?.message ?? "当前书源没有返回正文。"
        return "本章加载失败\n\n\(reason)\n\n本章位置会保留，请继续向下进入下一章。"
    }

    private func continuousPosition(_ position: Int, content: String) -> Int {
        let length = content.isEmpty ? 80 : content.utf16.count
        return min(max(position, 0), max(length - 1, 0))
    }

    private var activeBackgroundImage: UIImage? {
        themeMode != "3" && useBackgroundImage ? backgroundImage : nil
    }

    private var backgroundColor: Color {
        Color(uiColor: resolvedStyle.background)
    }

    private var foregroundColor: Color {
        Color(uiColor: resolvedStyle.foreground)
    }

    private var resolvedStyle: ReaderStylePreset {
        themeMode == "3" ? .eInk : ReaderStylePreset.resolve(theme)
    }

    private var headerVisible: Bool {
        switch headerMode {
        case 1: true
        case 2: false
        default: hideStatusBar
        }
    }

    private var footerVisible: Bool { footerMode == 0 }

    @ViewBuilder private func selectionControls(_ selection: ReaderTextSelection) -> some View {
        let controls = ReaderSelectionView(selection: selection, onDismiss: endTextSelection, onFilter: { text in
            var rule = replaceRules.newRule()
            rule.name = String(text.prefix(20))
            rule.pattern = text
            rule.isRegex = false
            endTextSelection()
            activeSheet = .replaceRule(rule)
        }, onLookup: { activeSheet = .dictionary($0) }, onTranslate: { translationText = $0 })
        if #available(iOS 17.4, *) {
            controls.translationPresentation(isPresented: Binding(
                get: { translationText != nil }, set: { if !$0 { translationText = nil } }
            ), text: translationText ?? "")
        } else {
            controls
        }
    }

    private func beginTextSelection(_ selection: ReaderTextSelection) {
        textSelection = selection
    }

    private func endTextSelection() {
        translationText = nil
        textSelection = nil
    }

    private var pausesAutoReading: Bool {
        isWaitingForNextChapter
            || isWaitingForPreviousChapter
            || showsReaderMenu
            || showsTableOfContents
            || bottomPanel != nil
            || activeSheet != nil
            || textSelection != nil
            || chapterCommentsTarget != nil
            || illustrationChapter != nil
    }


    private func readerTipBar(isHeader: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            readerTipRow(
                isHeader ? [tipHeaderLeft, tipHeaderMiddle, tipHeaderRight] : [tipFooterLeft, tipFooterMiddle, tipFooterRight],
                date: context.date,
                showDivider: isHeader ? showHeaderLine : showFooterLine,
                isHeader: isHeader
            )
            .padding(.top, isHeader ? headerPaddingTop : footerPaddingTop)
            .padding(.bottom, isHeader ? headerPaddingBottom : footerPaddingBottom)
        }
        .allowsHitTesting(false)
    }

    private func readerTipRow(_ values: [Int], date: Date, showDivider: Bool, isHeader: Bool) -> some View {
        let left = readerTipText(values[0], date: date)
        let middle = readerTipText(values[1], date: date)
        let right = readerTipText(values[2], date: date)
        return HStack(spacing: 0) {
            if !left.isEmpty { Text(left) }
            Spacer(minLength: !left.isEmpty && (!middle.isEmpty || !right.isEmpty) ? 8 : 0)
            if !middle.isEmpty {
                Text(middle)
                Spacer(minLength: right.isEmpty ? 0 : 8)
            }
            if !right.isEmpty { Text(right) }
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: 12))
        .foregroundStyle(foregroundColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.leading, isHeader ? headerPaddingLeft : footerPaddingLeft)
        .padding(.trailing, isHeader ? headerPaddingRight : footerPaddingRight)
        .overlay(alignment: .bottom) {
            if showDivider { Divider().overlay(foregroundColor.opacity(0.35)) }
        }
    }

    private func readerTipText(_ value: Int, date: Date) -> String {
        var time: String { date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        var battery: Int {
            let level = UIDevice.current.batteryLevel
            return level >= 0 ? Int((level * 100).rounded()) : 100
        }
        var progressText: String { String(format: "%.1f%%", chapterProgress * 100) }
        switch value {
        case 1: return model.title.readerText(simplified: simplifiedChinese)
        case 2: return time
        case 3: return "▰"
        case 4: return "\(currentPage)/\(totalPages)"
        case 5: return progressText
        case 6: return "\(currentPage)/\(totalPages)  \(progressText)"
        case 7: return book.name.readerText(simplified: simplifiedChinese)
        case 8: return "\(time) ▰"
        case 9: return "\(time) \(battery)%"
        case 10: return "\(battery)%"
        case 11: return "\(model.currentChapterNumber)/\(model.directory.readableIndices.count)"
        default: return ""
        }
    }

    private var readerChromeTint: Color {
        foregroundColor
    }

    private var readerChromeBackground: Color { Color(uiColor: resolvedStyle.menuBackground) }

    private var chapterProgress: Double {
        let count = model.directory.readableIndices.count
        guard count > 0, model.currentChapterNumber > 0 else { return 0 }
        return (Double(model.currentChapterNumber - 1) + chapterPageFraction) / Double(count)
    }

    private var chapterPageFraction: Double {
        guard model.hasLoadedCurrentChapter, !model.content.isEmpty else { return 0 }
        guard totalPages > 1 else { return 1 }
        return min(max(Double(max(currentPage - 1, 0)) / Double(totalPages - 1), 0), 1)
    }


    private var readerMenuAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.15 : 0.26)
    }

    private var readerTopChrome: some View {
        HStack(spacing: 4) {
            readerChromeIconButton("chevron.backward", label: "返回") { dismiss() }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.name.readerText(simplified: simplifiedChinese))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(model.title.readerText(simplified: simplifiedChinese))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                if model.source != nil {
                    readerChromeIconButton("rectangle.2.swap", label: "换源", action: openSourceSwitch)
                        .accessibilityIdentifier("reader.changeSource")
                        .accessibilityValue(book.originName)
                    Rectangle()
                        .fill(readerChromeTint.opacity(0.2))
                        .frame(width: 1, height: 16)
                        .accessibilityHidden(true)
                }
                readerMoreMenu
            }
            .padding(.horizontal, 4)
            .background {
                Capsule().fill(readerChromeTint.opacity(0.07)).padding(.vertical, 5)
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .top) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private func readerToolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .regular))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var readerMoreMenu: some View {
        Menu {
            if model.commentsTarget(at: model.currentIndex) != nil {
                Button("本章评论", systemImage: "text.bubble") {
                    openChapterComments(at: model.currentIndex)
                }
                .accessibilityIdentifier("reader.chapterComments")
            }
            Button("书籍信息", systemImage: "info.circle") {
                showsReaderMenu = false
                activeSheet = .bookInfo
            }
            if let url = model.currentChapterWebPageURL {
                Button("打开原网页", systemImage: "safari") {
                    showsReaderMenu = false
                    activeSheet = .originalWebPage(url)
                }
            }
            if model.source != nil, book.origin != "local", model.currentChapter?.isVolume == false {
                Button("重新获取本章", systemImage: "arrow.clockwise") {
                    showsReaderMenu = false
                    refreshCurrentChapter()
                }
                .disabled(model.isLoading || model.scrollRetries.contains(model.currentIndex))
            }
            Button("搜索正文", systemImage: "magnifyingglass") {
                showsReaderMenu = false
                showsContentSearch = true
            }
            if isLocalEPUB {
                Button(EPUBReadingMode.original.title, systemImage: "book") {
                    showsReaderMenu = false
                    sessionEPUBMode = .original
                }
                Button("本章插图", systemImage: "photo.on.rectangle") {
                    showsReaderMenu = false
                    illustrationChapter = model.currentChapter
                }
            }
            Button(bookmarkSaved ? "已添加书签" : "添加书签", systemImage: bookmarkSaved ? "bookmark.fill" : "bookmark", action: addBookmark)
                .disabled(isSavingBookmark)
                .accessibilityIdentifier("reader.addBookmark")
            Button("书签列表", systemImage: "list.bullet") {
                showsReaderMenu = false
                activeSheet = .bookmarks
            }
        } label: {
            readerToolbarIcon("ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
    }

    private var readerBottomChrome: some View {
        VStack(spacing: 8) {
            if !model.hasImageContent {
                HStack(spacing: 8) {
                    quickAction(isAutoReading ? "停止翻页" : "自动阅读", icon: isAutoReading ? "stop.fill" : "play") {
                        if isAutoReading {
                            isAutoReading = false
                        } else {
                            showsReaderMenu = false
                            openPanel(.autoRead)
                        }
                    }
                    quickAction("听书", icon: "headphones", action: openListeningSettings)
                        .disabled(!canStartListening)
                        .opacity(canStartListening ? 1 : 0.38)
                }
            }
            readerChapterControls
            HStack(spacing: 0) {
                readerChromeAction("list.bullet", "目录") {
                    showsReaderMenu = false
                    showsTableOfContents = true
                }
                readerChromeAction("textformat.size", "外观") {
                    showsReaderMenu = false
                    openPanel(.appearance)
                }
                readerChromeAction(resolvedStyle.id == "night" ? "sun.max" : "moon", resolvedStyle.id == "night" ? "日间" : "夜间") {
                    toggleNightTheme()
                }.disabled(themeMode == "3")
                readerChromeAction("gearshape", "设置") {
                    showsReaderMenu = false
                    openPanel(.settings)
                }
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .bottom) }
    }

    private func quickAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(foregroundColor.opacity(0.065), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var readerChapterControls: some View {
        HStack(spacing: 16) {
            readerChromeIconButton("chevron.left", label: "上一章") { moveChapter(-1) }
                .disabled(!model.canGoPrevious)
                .opacity(model.canGoPrevious ? 1 : 0.25)
            ReaderChapterSlider(directory: model.directory, simplifiedChinese: simplifiedChinese, currentNumber: model.currentChapterNumber,
                                progress: chapterProgress) { index in
                if index != model.currentIndex { navigate(to: index) }
            }
            readerChromeIconButton("chevron.right", label: "下一章") { moveChapter(1) }
                .disabled(!model.canGoNext)
                .opacity(model.canGoNext ? 1 : 0.25)
        }
    }

    private func readerChromeIconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            readerToolbarIcon(icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func readerChromeAction(_ icon: String, _ title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: min(toolbarIconSize, 28), weight: .regular))
                    .frame(height: 28)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var readerBrightnessBinding: Binding<Double> {
        Binding(
            get: { readerBrightness },
            set: { value in
                followsSystemBrightness = false
                readerBrightness = value
                storedReaderBrightness = value
                UIScreen.main.brightness = CGFloat(value)
            }
        )
    }

    private func followSystemBrightness() {
        followsSystemBrightness = true
        storedReaderBrightness = 0
        UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
        readerBrightness = brightnessBeforeReading
    }

    private func toggleNightTheme() {
        if resolvedStyle.id == "night" {
            theme = previousDayTheme == "night" ? "wechat" : previousDayTheme
        } else {
            previousDayTheme = resolvedStyle.id
            theme = "night"
        }
    }

    private func moveChapter(_ direction: Int, previousPosition: Int? = nil) {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        if direction < 0 {
            model.goPrevious(position: previousPosition ?? (pageAnimation == 3 || model.hasImageContent ? 0 : .max))
        } else {
            model.goNext()
        }
        if model.requestedPosition != .max { readerPosition = model.requestedPosition }
    }

    private func requestNextChapter() {
        if pageAnimation == 3 {
            guard model.canGoNext else { isAutoReading = false; return }
            Task { await model.extendContinuousReading(direction: 1, rules: model.usesReplaceRules ? replaceRules.rules : []) }
            return
        }
        guard model.canGoNext, model.hasContinuationWindow else {
            isAutoReading = false
            return
        }
        if model.isContinuationWindowReady {
            isWaitingForNextChapter = false
            readerRenderRevision &+= 1
        } else {
            isWaitingForNextChapter = true
        }
    }

    private func requestPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow else { return }
        if model.isPreviousWindowReady {
            advanceToPreparedPreviousChapter()
        } else {
            isWaitingForPreviousChapter = true
        }
    }

    private func advanceToPreparedPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow, model.isPreviousWindowReady else { return }
        isWaitingForPreviousChapter = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        let position = max(model.previousContent.utf16.count - 1, 0)
        readerPosition = position
        model.promotePrevious(position: position)
    }

    private func startAutoReading() {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        isAutoReading = true
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn || isAutoReading
            || (readAloudWakeLock && speech.isSpeaking)
    }

    private func pageDidChange() {
        saveProgress()
        guard enableReadRecord else { return }
        Task { await activity.checkpoint(book) }
    }


    private var readerBottomPanel: some View {
        GeometryReader { viewport in
            ZStack(alignment: .bottom) {
                if let bottomPanel {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { dismissTopPanel() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    let height = dynamicTypeSize.isAccessibilitySize ? viewport.size.height : panelHeight(bottomPanel)
                    ReaderBottomPanel(height: min(height, viewport.size.height),
                                      bottomInset: viewport.safeAreaInsets.bottom,
                                      dismiss: { cancelPanel() }) {
                        switch bottomPanel {
                        case .appearance: styleControls
                        case .autoRead: autoReadControls
                        case .settings: readerSettings
                        }
                    }
                    .disabled(savingPanel)
                    .accessibilityHidden(showsPageSettings)
                    .allowsHitTesting(!showsPageSettings)
                    .transition(panelTransition)
                    .zIndex(1)
                    if showsPageSettings {
                        detailPanel(.page, isPresented: $showsPageSettings, viewport: viewport)
                            .accessibilityHidden(showsTypographySettings)
                            .allowsHitTesting(!showsTypographySettings)
                            .zIndex(2)
                    }
                    if showsTypographySettings {
                        detailPanel(.typography, isPresented: $showsTypographySettings, viewport: viewport)
                            .sheet(isPresented: $showsFontImporter) { fontImporter }
                            .zIndex(3)
                    }
                }
            }
            .environment(\.colorScheme, resolvedStyle.id == "night" ? .dark : .light)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
            .animation(readerMenuAnimation, value: bottomPanel)
            .animation(readerMenuAnimation, value: showsPageSettings)
            .animation(readerMenuAnimation, value: showsTypographySettings)
        }
    }

    private var panelTransition: AnyTransition {
        // Earlier systems leave accessibility frames at the slide-in starting position.
        if #available(iOS 18, *), !reduceMotion { return .move(edge: .bottom) }
        return .opacity
    }

    private var readerSettingsFields: [any ReaderPanelField] {
        [_simplifiedChinese, _keepScreenOn, _hideHomeIndicator, _hideStatusBar, _screenOrientation]
    }

    private func openPanel(_ panel: BottomPanel) {
        if panel == .settings {
            readerSettingsFields.forEach { $0.beginPreview() }
            draftReplaceRules = model.usesReplaceRules
            draftDefaultMode = defaultEPUBMode
        }
        bottomPanel = panel
    }

    @ToolbarContentBuilder private var readerSettingsActions: some ToolbarContent {
        ReadingSheetActions {
            Button("取消", action: cancelPanel).disabled(savingPanel)
            ReadingSheetActionButton(isWorking: savingPanel) {
                savingPanel = true
                Task { await savePanel(); savingPanel = false }
            }
        }
    }

    private func cancelPanel() {
        guard !savingPanel, let panel = bottomPanel else { return }
        if panel == .settings { readerSettingsFields.forEach { $0.endPreview(save: false) } }
        backgroundError = nil
        fontError = nil
        bottomPanel = nil
    }

    @MainActor private func savePanel() async {
        let enabled = draftReplaceRules
        if enabled != model.usesReplaceRules {
            if library.contains(book), !(await library.updateReadConfig(for: book, { $0.useReplaceRule = enabled })) {
                readerSettingSaveError = library.errorMessage ?? "正文替换设置未保存"
                return
            }
            stopSpeechForContentChange()
            _ = model.toggleReplaceRules(position: readerPosition)
        }
        if draftDefaultMode != defaultEPUBMode { defaultEPUBSelection.wrappedValue = draftDefaultMode }
        readerSettingsFields.forEach { $0.endPreview(save: true) }
        bottomPanel = nil
    }

    @MainActor private func selectPageAnimation(_ value: Int) async {
        guard pageAnimation != value, !changingPageAnimation else { return }
        changingPageAnimation = true
        defer { changingPageAnimation = false }
        if library.contains(book), !(await library.updateReadConfig(for: book, { $0.pageAnim = -1 })) {
            readerSettingSaveError = library.errorMessage ?? "翻页设置未保存"
            return
        }
        _ = model.useGlobalPageAnimation()
        UserDefaults.standard.set(value, forKey: "pageAnim")
        pageAnimation = value
    }

    private func dismissTopPanel() {
        if showsTypographySettings { showsTypographySettings = false }
        else if showsPageSettings { showsPageSettings = false }
        else { cancelPanel() }
    }

    private func detailPanel(_ detail: StyleDetail, isPresented: Binding<Bool>, viewport: GeometryProxy) -> some View {
        ReaderBottomPanel(height: viewport.size.height, bottomInset: viewport.safeAreaInsets.bottom,
                          dismiss: { isPresented.wrappedValue = false }) {
            styleDetail(detail, isPresented: isPresented)
        }
        .transition(panelTransition)
    }

    private func panelHeight(_ panel: BottomPanel) -> CGFloat {
        switch panel {
        case .appearance: 260 + (backgroundImage == nil ? 0 : 49) + (backgroundError == nil ? 0 : 44)
        case .autoRead: 248
        case .settings: isLocalEPUB ? 426 : 382
        }
    }

    private var autoReadControls: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("自动翻页速度")
                                .font(.headline)
                            Spacer()
                            Text("每屏 \(autoReadSpeed) 秒")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityHidden(true)

                        Slider(
                            value: Binding(get: { Double(autoReadSpeed) }, set: { autoReadSpeed = Int($0.rounded()) }),
                            in: 1...120
                        ) { Text("自动翻页速度") }
                        .accessibilityValue("每屏 \(autoReadSpeed) 秒")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: autoReadSpeed = min(120, autoReadSpeed + 1)
                            case .decrement: autoReadSpeed = max(1, autoReadSpeed - 1)
                            @unknown default: break
                            }
                        }
                        .tint(ReadingTheme.accent)
                    }
                    .padding(16)
                    .readingSheetGroup()

                    Button {
                        cancelPanel()
                        startAutoReading()
                    } label: {
                        Label("开始自动阅读", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(ReadingTheme.onAccent)
                            .background(ReadingTheme.accentFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: 540)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .readingSheetSurface()
            .readingSheetTitle("自动阅读")
            .toolbar {
                ReadingSheetActions { ReadingSheetCloseButton(action: cancelPanel) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var styleControls: some View {
        NavigationView {
            ScrollView {
                compactStyleControls
                    .frame(maxWidth: 540)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity)
            }
            .readingSheetSurface()
            .readingSheetTitle("阅读样式")
            .toolbar {
                ReadingSheetActions {
                    Button("更多") { showsPageSettings = true }
                    Button("取消", action: cancelPanel)
                }
            }
        }
        .navigationViewStyle(.stack)
        .readingPhotoPicker(isPresented: $showsBackgroundPicker) { data in
            backgroundError = nil
            do {
                backgroundImage = try ReaderBackgroundStore.save(data)
                useBackgroundImage = true
            } catch {
                backgroundError = error.localizedDescription
            }
        } onError: { error in
            backgroundError = error.localizedDescription
        }
    }

    private enum StyleDetail: String {
        case typography = "字体与间距"
        case page = "页面设置"
    }

    private func styleDetail(_ detail: StyleDetail, isPresented: Binding<Bool>) -> some View {
        NavigationView {
            Form {
                switch detail {
                case .typography: typographySections
                case .page: pageStyleSections
                }
            }
            .readingScrollContentBackgroundHidden()
            .readingSheetSurface()
            .readingSheetTitle(detail.rawValue)
            .toolbar {
                ReadingSheetActions {
                    Button("返回") { isPresented.wrappedValue = false }
                }
            }
            .modifier(ReaderMenuBackGesture(menuVisible: true) { isPresented.wrappedValue = false })
        }
        .navigationViewStyle(.stack)
    }

    private var fontImporter: some View {
        // Some Files providers report fonts as generic data. The installer validates the font itself.
        ReadingImportPicker(contentTypes: [.font, .data], allowsMultipleSelection: false) { urls in
            showsFontImporter = false
            guard let source = urls.first else { return }
            do {
                fontPath = try ReaderFontStore.install(from: source)
                fontRevision &+= 1
                fontError = nil
            } catch {
                fontError = error.localizedDescription
            }
        } onCancel: { showsFontImporter = false }
    }

    @ViewBuilder private var typographySections: some View {
        pageSection("字体", icon: "textformat") {
            Button(fontPath.isEmpty ? "选择字体文件" : "更换字体文件", systemImage: "textformat") {
                showsFontImporter = true
            }
            HStack {
                Text("当前字体")
                Spacer()
                Text(fontPath.isEmpty ? "系统字体" : URL(fileURLWithPath: fontPath).lastPathComponent)
                    .foregroundStyle(.secondary)
            }
            if !fontPath.isEmpty {
                Button("使用系统字体") { fontPath = "" }
            }
            if let fontError {
                Text(fontError).font(.footnote).foregroundStyle(.red)
            }
            valueSlider("字号", value: $fontSize, range: 5...50, format: { "\(Int($0))" })
            Picker("字重", selection: $fontWeight) {
                Text("正常").tag(0)
                Text("粗体").tag(1)
                Text("细体").tag(2)
            }
            Picker("下划线", selection: $underlineMode) {
                Text("关闭").tag(0)
                Text("实线").tag(1)
                Text("虚线").tag(2)
            }
        }
        pageSection("间距与段落", icon: "text.alignleft") {
            valueSlider("字间距", value: $letterSpacing, range: -0.5...0.5, step: 0.01, format: { String(format: "%.2f", $0) })
            valueSlider("行间距", value: $lineSpacing, range: 0...50, format: { "\(Int($0))" })
            valueSlider("段距", value: $paragraphSpacing, range: 0...50, format: { String(format: "%.1f", $0) })
            Toggle("两端对齐", isOn: $fullJustify)
            VStack(alignment: .leading, spacing: 6) {
                Text("段落缩进")
                TextField("请输入缩进字符", text: $paragraphIndent)
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("段落缩进字符")
                Text("控制每段开头的缩进，默认两个全角空格；清空后不缩进。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var pageStyleSections: some View {
        Section {
            Button {
                showsTypographySettings = true
            } label: {
                HStack {
                    Label(StyleDetail.typography.rawValue, systemImage: "textformat")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .listRowBackground(Color(uiColor: .secondarySystemBackground))
        }

        pageSection("章节标题", icon: "textformat.size") {
            VStack(spacing: 12) {
                chapterLayoutPreview
                Picker("标题模式", selection: $titleMode) {
                    Text("左对齐").tag(0)
                    Text("居中").tag(1)
                    Text("隐藏").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
            pageSlider("标题字号增量", value: $titleSize, range: -10...30, signed: true)
            pageSlider("标题上间距", value: $titleTopSpacing)
            pageSlider("标题下间距", value: $titleBottomSpacing)
        }

        pageSection("翻页动画", icon: "rectangle.on.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                                    count: dynamicTypeSize.isAccessibilitySize ? 2 : 5)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Self.pageAnimationChoices, id: \.0) { choice in
                        let selected = pageAnimation == choice.value
                        Button {
                            Task { await selectPageAnimation(choice.value) }
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: choice.icon).font(.body.weight(.medium))
                                Text(choice.title).font(.caption.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .padding(.vertical, 3)
                            .foregroundStyle(selected ? ReadingTheme.onAccent : ReadingTheme.accent)
                            .background(selected ? ReadingTheme.accentFill : ReadingTheme.accent.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(changingPageAnimation)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Divider()
                Label(pageAnimation == 3 ? "上下滑动连续阅读，轻点中间打开菜单。"
                      : "左右滑动或轻点两侧翻页，轻点中间打开菜单。", systemImage: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        pageSection("边距", icon: "arrow.up.left.and.arrow.down.right") {
            Picker("边距区域", selection: $marginArea) {
                ForEach(MarginArea.allCases, id: \.self) { area in
                    Text(area.rawValue).tag(area)
                }
            }
            .pickerStyle(.segmented)
            let margins = marginBindings
            pageSlider("左边距", value: margins.left)
            pageSlider("右边距", value: margins.right)
            pageSlider("上边距", value: margins.top)
            pageSlider("下边距", value: margins.bottom)
        }

        pageSection("页眉页脚", icon: "rectangle.split.3x1") {
            Picker("页眉显示", selection: $headerMode) {
                Text("状态栏显示时隐藏").tag(0)
                Text("显示").tag(1)
                Text("隐藏").tag(2)
            }
            Picker("页脚显示", selection: $footerMode) {
                Text("显示").tag(0)
                Text("隐藏").tag(1)
            }
            tipPicker("页眉左", selection: $tipHeaderLeft)
            tipPicker("页眉中", selection: $tipHeaderMiddle)
            tipPicker("页眉右", selection: $tipHeaderRight)
            tipPicker("页脚左", selection: $tipFooterLeft)
            tipPicker("页脚中", selection: $tipFooterMiddle)
            tipPicker("页脚右", selection: $tipFooterRight)
            Toggle("页眉分隔线", isOn: $showHeaderLine)
            Toggle("页脚分隔线", isOn: $showFooterLine)
        }
    }

    private func pageSection<Content: View>(_ title: String, icon: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
                .listRowBackground(Color(uiColor: .secondarySystemBackground))
        } header: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ReadingTheme.accent)
                .textCase(nil)
        }
    }

    private var chapterLayoutPreview: some View {
        let excerpt = model.hasImageContent ? "" : String(model.content.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            if titleMode != 2 {
                Text(model.title.isEmpty ? "章节标题" : model.title.readerText(simplified: simplifiedChinese))
                    .font(.system(size: max(10, (fontSize + titleSize) * 0.8), weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: titleMode == 1 ? .center : .leading)
                    .padding(.top, titleTopSpacing * 0.25)
                    .padding(.bottom, titleBottomSpacing * 0.25)
            }
            if excerpt.isEmpty {
                Capsule().fill(readerChromeTint.opacity(0.22)).frame(height: 3)
                Capsule().fill(readerChromeTint.opacity(0.16)).frame(height: 3)
                    .padding(.trailing, 42)
            } else {
                Text(excerpt.readerText(simplified: simplifiedChinese))
                    .font(.system(size: max(10, fontSize * 0.7), design: .serif))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.leading, 14 + paddingLeft * 0.35)
        .padding(.trailing, 14 + paddingRight * 0.35)
        .padding(.top, 12 + paddingTop * 0.35)
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: 96, alignment: .topLeading)
        .clipped()
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(readerChromeTint.opacity(0.12))
        }
        .accessibilityHidden(true)
    }

    private enum MarginArea: String, CaseIterable {
        case body = "正文"
        case header = "页眉"
        case footer = "页脚"
    }

    private var marginBindings: (left: Binding<Double>, right: Binding<Double>, top: Binding<Double>, bottom: Binding<Double>) {
        switch marginArea {
        case .body: ($paddingLeft, $paddingRight, $paddingTop, $paddingBottom)
        case .header: ($headerPaddingLeft, $headerPaddingRight, $headerPaddingTop, $headerPaddingBottom)
        case .footer: ($footerPaddingLeft, $footerPaddingRight, $footerPaddingTop, $footerPaddingBottom)
        }
    }

    private func pageSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...100,
                            signed: Bool = false) -> some View {
        let number = String(format: signed ? "%+.0f" : "%.0f", value.wrappedValue)
        let slider = Slider(value: value, in: range, step: 1)
            .tint(ReadingTheme.accent)
            .accessibilityLabel(title)
            .accessibilityValue(number)
        return VStack(spacing: 4) {
            HStack(spacing: 12) {
                Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : pageSliderLabelWidth, alignment: .leading)
                    .accessibilityHidden(true)
                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                } else {
                    slider
                }
                Text(number)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 30)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .foregroundStyle(ReadingTheme.accent)
                    .background(ReadingTheme.accent.opacity(0.07), in: Capsule())
                    .accessibilityHidden(true)
            }
            if dynamicTypeSize.isAccessibilitySize { slider }
        }
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
    }

    private var compactStyleControls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("亮度")
                    Slider(value: readerBrightnessBinding, in: 0.05...1)
                        .tint(ReadingTheme.accent)
                        .accessibilityLabel("阅读亮度")
                    Button {
                        if followsSystemBrightness {
                            readerBrightnessBinding.wrappedValue = max(0.05, Double(UIScreen.main.brightness))
                        } else {
                            followSystemBrightness()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: followsSystemBrightness ? "checkmark.circle.fill" : "circle")
                            Text("随系统")
                        }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(followsSystemBrightness ? .isSelected : [])
                }

                Divider()
                HStack(spacing: 12) {
                    Text("字号")
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        styleSizeButton("minus", label: "减小字号", disabled: fontSize <= 5) { fontSize = max(5, fontSize - 1) }
                        Text("\(Int(fontSize))")
                            .font(.headline.monospacedDigit())
                            .frame(maxWidth: .infinity)
                        styleSizeButton("plus", label: "增大字号", disabled: fontSize >= 50) { fontSize = min(50, fontSize + 1) }
                    }
                    .frame(maxWidth: 166)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .readingSheetGroup()

            HStack(spacing: 0) {
                ForEach(ReaderStylePreset.legadoDefaults) { preset in
                    let selected = resolvedStyle.id == preset.id && activeBackgroundImage == nil
                    Button {
                        useBackgroundImage = false
                        theme = preset.id
                    } label: {
                        Circle()
                            .fill(Color(uiColor: preset.background))
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(selected ? 0.85 : 0.16),
                                                      lineWidth: selected ? 2 : 0.6)
                                if selected {
                                    Image(systemName: "checkmark").font(.subheadline.bold())
                                        .foregroundStyle(Color(uiColor: preset.foreground))
                                }
                            }
                            .frame(width: 32, height: 32)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Button {
                    backgroundError = nil
                    showsBackgroundPicker = true
                } label: {
                    Image(systemName: "photo")
                        .frame(width: 32, height: 32)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("选择背景图片")
            }

            if backgroundImage != nil {
                HStack {
                    Text("使用背景图片")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { useBackgroundImage.toggle() }
                        .accessibilityHidden(true)
                    Toggle("使用背景图片", isOn: $useBackgroundImage)
                        .labelsHidden()
                        .fixedSize()
                    Button(role: .destructive) {
                        do {
                            try FileManager.default.removeItem(at: ReaderBackgroundStore.url)
                            backgroundImage = nil
                            useBackgroundImage = false
                            backgroundError = nil
                        } catch { backgroundError = error.localizedDescription }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("删除背景图片")
                }
            }

            if let backgroundError {
                Text(backgroundError).font(.footnote).foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.vertical, 2)
    }

    private func styleSizeButton(_ icon: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Color(uiColor: .systemBackground), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private static let pageAnimationChoices: [(value: Int, title: String, icon: String)] = [
        (0, "覆盖", "rectangle.on.rectangle"),
        (1, "滑动", "rectangle.portrait.and.arrow.right"),
        (2, "仿真", "book.pages"),
        (3, "滚动", "arrow.up.and.down"),
        (4, "无动画", "rectangle")
    ]

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private static let readerTipChoices: [(Int, String)] = [
        (0, "无"), (7, "书名"), (1, "标题"), (2, "时间"), (3, "电量"),
        (10, "电量%"), (4, "页数"), (5, "进度(%)"), (11, "进度(xx/yyy)"),
        (6, "页数及进度"), (8, "时间及电量"), (9, "时间及电量%")
    ]

    private func tipPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.readerTipChoices, id: \.0) { value, name in
                Text(name).tag(value)
            }
        }
    }


    private var readerSettings: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    VStack(spacing: 0) {
                        Toggle("繁体转简体", isOn: $simplifiedChinese)
                            .accessibilityIdentifier("reader.simplifiedChinese")
                            .frame(minHeight: 44)
                        Divider()
                        Toggle("正文替换规则", isOn: $draftReplaceRules)
                        .frame(minHeight: 44)
                        if isLocalEPUB {
                            Divider()
                            EPUBDefaultModePicker(selection: $draftDefaultMode)
                                .frame(minHeight: 44)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                    .readingSheetGroup()

                    VStack(spacing: 0) {
                        HStack {
                            Text("屏幕方向")
                            Spacer()
                            Picker("屏幕方向", selection: $screenOrientation) {
                                Text("跟随系统").tag("0")
                                Text("竖向").tag("1")
                                Text("横向").tag("2")
                                Text("跟随传感器").tag("3")
                                Text("反向竖屏").tag("4")
                                Text("反向横屏").tag("5")
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        .frame(minHeight: 44)
                        Divider()
                        Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                            .frame(minHeight: 44)
                        if #available(iOS 16.0, *) {
                            Divider()
                            Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
                                .frame(minHeight: 44)
                        }
                        Divider()
                        Toggle("隐藏状态栏", isOn: $hideStatusBar)
                            .frame(minHeight: 44)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                    .readingSheetGroup()
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: 540)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .readingSheetSurface()
            .readingSheetTitle("阅读设置")
            .alert("阅读设置未保存", isPresented: readerSettingErrorPresented(inSettings: true)) {
                Button("好", role: .cancel) { readerSettingSaveError = nil }
            } message: { Text(readerSettingSaveError ?? "") }
            .toolbar {
                readerSettingsActions
            }
        }
        .navigationViewStyle(.stack)
    }

    private var listeningPreferences: some View {
        ListeningSettingsView(presented: true, isListening: listeningPack != nil, canStart: canStartListening,
                              speechTimerRemaining: speechTimerRemaining, onStart: startListening)
    }

    private func refreshCurrentChapter() {
        stopSpeechIfNeeded()
        Task {
            if pageAnimation == 3, model.scrollChapters.contains(where: { $0.id == model.currentIndex }) {
                await model.retryContinuousChapter(index: model.currentIndex, rules: model.usesReplaceRules ? replaceRules.rules : [])
            } else {
                await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], forceRefresh: true)
            }
            readerPosition = min(readerPosition, model.content.utf16.count)
        }
    }

    private var tableOfContents: some View {
        ReaderTableOfContents(
            directory: model.directory, simplifiedChinese: simplifiedChinese, currentIndex: model.currentIndex, bookTitle: book.name.readerText(simplified: simplifiedChinese),
            bookURL: model.book.bookUrl, sourceID: model.onlineSourceID, cache: model.chapterCache, descending: $tocDescending,
            onCache: model.cacheChapters
        ) { index in
            if index != model.currentIndex { navigate(to: index) }
            showsTableOfContents = false
        }
    }

    private var contentSearchSheet: some View {
        let results = contentSearchResults
        return ReadingNavigationStack {
            Group {
                if contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadingUnavailableView("搜索正文", systemImage: "magnifyingglass", description: Text("输入本章正文关键字"))
                } else if results.isEmpty {
                    ReadingUnavailableView.search(text: contentSearchQuery)
                } else {
                    List {
                        Section("本章 · \(results.count) 个匹配段落") {
                            ForEach(results) { paragraph in
                                Button {
                                    navigate(to: model.currentIndex, position: paragraph.id)
                                    showsContentSearch = false
                                } label: {
                                    Text(paragraph.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .readingSheetTitle("正文搜索")
            .searchable(text: $contentSearchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索本章")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { showsContentSearch = false }
                }
            }
        }
    }

    private struct SearchHit: Identifiable {
        let id: Int
        let text: AttributedString
    }

    private var contentSearchResults: [SearchHit] {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).readerText(simplified: simplifiedChinese)
        guard !query.isEmpty else { return [] }
        return model.paragraphs.compactMap { paragraph in
            let text = paragraph.text.readerText(simplified: simplifiedChinese)
            guard let hit = text.range(of: query, options: .caseInsensitive, locale: .current) else { return nil }
            let start = text.index(hit.lowerBound, offsetBy: -16, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(hit.upperBound, offsetBy: 44, limitedBy: text.endIndex) ?? text.endIndex
            var snippet = AttributedString((start == text.startIndex ? "" : "…") + text[start..<hit.lowerBound])
            var matched = AttributedString(text[hit])
            matched.inlinePresentationIntent = .stronglyEmphasized
            matched.backgroundColor = .yellow.opacity(0.55)
            snippet += matched
            snippet += AttributedString(text[hit.upperBound..<end] + (end == text.endIndex ? "" : "…"))
            return SearchHit(id: paragraph.id, text: snippet)
        }
    }

    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            Group {
                let bookmarks = activity.bookmarks(for: book)
                if bookmarks.isEmpty {
                    ReadingUnavailableView(
                        "本书还没有书签",
                        systemImage: "bookmark",
                        description: Text("阅读时点击顶部书签按钮即可记录当前位置。")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.chapterName).font(.headline).foregroundStyle(.primary)
                                if !bookmark.bookText.isEmpty {
                                    Text(bookmark.bookText).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("位置 \(bookmark.chapterPosition)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } }
                        }
                    }
                }
            }
            .readingSheetTitle("书签")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { activeSheet = nil }
                }
            }
        }
    }

    private var bookmarkSaved: Bool {
        let page = currentPage - 1
        let range = pageAnimation != 3 && readerPageRanges.indices.contains(page) ? readerPageRanges[page] : nil
        return !model.bookmarks(at: readerPosition, in: activity.bookmarks, pageRange: range).isEmpty
    }

    private func addBookmark() {
        guard !isSavingBookmark, !bookmarkSaved, let chapter = model.currentChapter else { return }
        let currentBook = book
        let position = readerPosition
        let content = model.content
        isSavingBookmark = true
        Task {
            defer { isSavingBookmark = false }
            await activity.addBookmark(
                book: currentBook,
                chapter: chapter,
                position: position,
                content: content
            )
        }
    }

    private func jump(to bookmark: Bookmark) {
        guard let index = bookmark.resolvedChapterIndex(in: model.chapters) else { return }
        navigate(to: index, position: bookmark.chapterPosition)
        activeSheet = nil
    }


    private func navigate(to index: Int, position: Int = 0) {
        guard model.chapters.indices.contains(index), !model.chapters[index].isVolume else { return }
        let target = max(0, position)
        let currentPosition = model.hasLoadedCurrentChapter ? readerPosition : model.requestedPosition
        guard index != model.currentIndex || target != currentPosition else { return }
        stopSpeechForContentChange()
        saveProgress(immediate: true)
        readerJumpPosition = nil
        readerPosition = target
        if index != model.currentIndex || !model.hasLoadedCurrentChapter {
            model.select(index: index, position: target)
        } else {
            let generation = model.chapterLoadGeneration
            DispatchQueue.main.async {
                if model.chapterLoadGeneration == generation { readerJumpPosition = target }
            }
        }
    }

    private func saveProgress(immediate: Bool = false) {
        guard model.hasLoadedCurrentChapter, let chapter = model.currentChapter else { return }
        let position = readerPosition
        let currentBook = book
        progressSaveGeneration &+= 1
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor [weak library] in
            if !immediate { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled, let library else { return }
            await library.updateProgress(for: currentBook, chapter: chapter, position: position)
        }
    }


    private func stopSpeechIfNeeded() {
        closePlayer()
    }

    private func closePlayer() {
        speechStartGeneration &+= 1
        resumesSpeechAfterChapterLoad = false
        listeningPack = nil
        speechChapter = nil
        speech.stop()
        speechTimerTask?.cancel()
        speechTimerRemaining = 0
    }

    private func stopSpeechForContentChange() {
        closePlayer()
        isAutoReading = false
    }

    private func restartSpeechAfterReaderLayoutChange() {
        guard speech.isSpeaking || speech.isPaused else { return }
        speechStartGeneration &+= 1
        speech.stop()
        startConfiguredSpeech()
    }

    private var canStartListening: Bool {
        listeningPack == nil && !model.hasImageContent && !model.content.isEmpty
    }

    private func openListeningSettings() {
        guard canStartListening else { return }
        showsReaderMenu = false
        activeSheet = .listening
    }

    private func startListening() {
        guard canStartListening else { return }
        showsReaderMenu = false
        guard let pack = OfflineVoicePack.selected else {
            activeSheet = .listening
            return
        }
        activeSheet = nil
        isAutoReading = false
        listeningPack = pack
        listeningVoice = .preferred
        scheduleSpeechTimer()
        startConfiguredSpeech()
    }

    private func startConfiguredSpeech() {
        guard let listeningPack else { return }
        configureSpeech()
        speechChapter = model.currentIndex
        if readAloudByPage {
            guard !readerPageRanges.isEmpty else {
                guard !model.content.isEmpty else { return }
                let generation = speechStartGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard generation == speechStartGeneration,
                          readAloudByPage,
                          !speech.isSpeaking,
                          !speech.isPaused else { return }
                    startConfiguredSpeech()
                }
                return
            }
            let pageIndex = readerPageRanges.firstIndex { readerPosition < NSMaxRange($0) }
                ?? max(readerPageRanges.count - 1, 0)
            speechPageIndex = pageIndex
            speakPage(at: pageIndex, from: readerPosition)
            return
        }
        let start = model.paragraphs.last(where: { $0.id <= readerPosition })?.id ?? 0
        let range = NSRange(location: start, length: model.content.utf16.count - start)
        speech.speak(model.content, reading: range, continuesAcrossChapters: true, voice: listeningVoice, pack: listeningPack)
    }

    private func speakPage(at index: Int, from position: Int? = nil) {
        guard readerPageRanges.indices.contains(index) else {
            continueSpeechToNextChapter()
            return
        }
        let range = readerPageRanges[index]
        let start = min(max(position ?? range.location, range.location), NSMaxRange(range))
        let pageRange = NSRange(location: start, length: max(NSMaxRange(range) - start, 0))
        guard pageRange.length > 0 else {
            continueSpeechToNextPage()
            return
        }
        speech.speak(model.content, reading: pageRange, continuesAcrossChapters: true, voice: listeningVoice, pack: listeningPack)
    }

    private func continueSpeechToNextPage() {
        guard listeningPack != nil else { return }
        guard readAloudByPage, readerPageRanges.indices.contains(speechPageIndex) else {
            continueSpeechToNextChapter()
            return
        }
        readerPosition = NSMaxRange(readerPageRanges[speechPageIndex])
        guard readerPageRanges.indices.contains(speechPageIndex + 1) else {
            continueSpeechToNextChapter()
            return
        }
        speechPageIndex += 1
        let nextPosition = readerPageRanges[speechPageIndex].location
        readerPosition = nextPosition
        readerJumpPosition = nextPosition
        speakPage(at: speechPageIndex)
    }

    private func continueSpeechToNextChapter() {
        guard listeningPack != nil else { return }
        guard model.canGoNext else {
            closePlayer()
            return
        }
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        model.goNext()
        readerPosition = model.requestedPosition
    }

    private func moveSpeechToChapter(direction: Int) {
        let canMove = direction < 0 ? model.canGoPrevious : model.canGoNext
        guard canMove else { return }
        speech.stop()
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func scheduleSpeechTimer() {
        speechTimerTask?.cancel()
        speechTimerRemaining = ttsTimer
        guard speechTimerRemaining > 0 else { return }
        speechTimerTask = Task { @MainActor in
            do {
                while speechTimerRemaining > 0 {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    if !speech.isSpeaking && !speech.isPaused && !resumesSpeechAfterChapterLoad {
                        speechTimerRemaining = 0
                        break
                    }
                    if !speech.isPaused { speechTimerRemaining -= 1 }
                    if speechTimerRemaining == 0 {
                        closePlayer()
                    }
                }
            } catch { }
        }
    }

    private func configureSpeech() {
        speech.configure(
            speechRate: ttsSpeechRate,
            ignoresAudioFocus: ignoreAudioFocus,
            pausesForPhoneCalls: pauseReadAloudWhilePhoneCalls,
            mediaButtonPerNext: mediaButtonPerNext,
            bookName: model.book.name,
            chapterTitle: model.title,
            author: model.book.author,
            coverAddress: model.book.displayCoverURL
        )
    }

    private static func globalPageAnimation() -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pageAnim") == nil,
           let legacy = defaults.object(forKey: "readerPageAnimation") as? NSNumber {
            defaults.set(legacy.intValue, forKey: "pageAnim")
        }
        return defaults.integer(forKey: "pageAnim")
    }

    private func readerSettingErrorPresented(inSettings: Bool) -> Binding<Bool> {
        Binding(get: { readerSettingSaveError != nil && (bottomPanel == .settings) == inSettings },
                set: { if !$0 { readerSettingSaveError = nil } })
    }



}

#if DEBUG
private struct ReaderFailureTestLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: ProcessInfo.processInfo.arguments.contains("-uiReaderPartialFailure") ? "本章只加载了第一页正文。" : "",
              diagnostics: [.init(severity: .error, code: "content.request", message: "测试书源正文请求失败", rule: chapter.url)])
    }
}
#endif

private struct ReaderListeningPlayer: View {
    let book: Book
    @ObservedObject var speech: ReaderSpeechController
    let tint: Color
    let background: Color
    static let viewportSpace = "reader.listeningPlayer.viewport"
    let viewportHeight: CGFloat
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dockedRight = false
    @State private var verticalFraction: CGFloat = 1
    @GestureState private var dragCenter: CGPoint?

    private enum Control { case playback, close }
    private let buttonSize: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let area = geometry.frame(in: .named(Self.viewportSpace))
            let insetX = min(size.width / 2, buttonSize + 12)
            let insetY = min(viewportHeight / 2, buttonSize / 2 + 10)
            let travelY = viewportHeight - 2 * insetY
            // Keep the preferred height in the full reader. Menus only constrain the visible position.
            let minY = max(insetY, min(area.minY + buttonSize / 2, area.midY))
            let maxY = max(minY, min(viewportHeight - insetY, area.maxY - buttonSize / 2))
            let preferredY = insetY + verticalFraction * travelY
            let anchor = CGPoint(x: dockedRight ? size.width - insetX : insetX,
                                 y: min(max(preferredY, minY), maxY))
            let snap: Animation? = reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
            let center = dragCenter ?? anchor

            let coverOnRight = center.x == size.width / 2 ? dockedRight : center.x > size.width / 2

            controls(coverOnRight: coverOnRight)
                .animation(snap, value: coverOnRight)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                        .updating($dragCenter) { value, center, _ in
                            center = CGPoint(
                                x: min(max(anchor.x + value.translation.width, insetX), size.width - insetX),
                                y: min(max(anchor.y + value.translation.height, minY), maxY)
                            )
                        }
                        .onEnded { value in
                            withAnimation(snap) {
                                dockedRight = anchor.x + value.translation.width > size.width / 2
                                if travelY > 0, value.translation.height != 0 {
                                    let y = min(max(anchor.y + value.translation.height, minY), maxY)
                                    verticalFraction = (y - insetY) / travelY
                                }
                            }
                        }
                )
                .position(x: center.x, y: center.y - area.minY)
                .animation(dragCenter == nil ? snap : nil, value: dragCenter == nil)
        }
    }

    private func controls(coverOnRight: Bool) -> some View {
        let order: [Control] = coverOnRight ? [.close, .playback] : [.playback, .close]
        return HStack(spacing: 0) {
            ForEach(order, id: \.self) { control in
                switch control {
                case .playback:
                    Button { speech.pauseOrResume() } label: {
                        Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(speech.isPreparingAudio ? 0 : 1)
                            .frame(width: 36, height: 36)
                            .background {
                                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverURL,
                                                 width: 36, height: 36)
                                    .overlay(Color.black.opacity(0.48))
                                    .clipShape(Circle())
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            .overlay {
                                if speech.isPreparingAudio {
                                    RagdollLoading(width: 28)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Rectangle())
                    }
                    .disabled(!speech.isSpeaking && !speech.isPaused)
                    .accessibilityLabel(speech.isPaused ? "继续播放" : "暂停播放")
                    .accessibilityValue(speech.isPreparingAudio ? "正在缓冲" : "")
                case .close:
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(tint.opacity(0.09), in: Circle())
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭播放器")
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background {
            Capsule().fill(background)
                .overlay(Capsule().strokeBorder(tint.opacity(0.15), lineWidth: 1))
                .frame(height: 40)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

private struct ReaderBottomPanel<Content: View>: View {
    let height: CGFloat
    let bottomInset: CGFloat
    let dismiss: () -> Void
    @ViewBuilder var content: Content
    @GestureState private var dragOffset: CGFloat = 0
    @State private var releaseOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .frame(height: 16)
                .accessibilityHidden(true)
            content
        }
        .frame(height: height)
        .padding(.bottom, bottomInset)
        .background(Color(uiColor: .systemBackground))
        .clipShape(TopCorners())
        .simultaneousGesture(DragGesture(coordinateSpace: .named("reader.bottomPanel"))
            .updating($dragOffset) { drag, offset, _ in
                if drag.startLocation.y < 65 { offset = max(0, drag.translation.height) }
            }
            .onEnded { drag in
                if drag.startLocation.y < 65, drag.translation.height > 24,
                   drag.predictedEndTranslation.height > 80 {
                    // Continue the exit from the finger's last position when the gesture resets.
                    releaseOffset = drag.translation.height
                    dismiss()
                }
            })
        .offset(y: max(dragOffset, releaseOffset))
        .coordinateSpace(name: "reader.bottomPanel")
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, dismiss)
    }

    private struct TopCorners: Shape {
        func path(in rect: CGRect) -> Path {
            Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                              cornerRadii: CGSize(width: 18, height: 18)).cgPath)
        }
    }
}
