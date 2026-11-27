import SafariServices
import SwiftUI
import UIKit

// RootTabView owns the window appearance, including the system status bar.
struct ReaderColorSchemeKey: PreferenceKey {
    static var defaultValue: ColorScheme? { nil }
    static func reduce(value: inout ColorScheme?, nextValue: () -> ColorScheme?) {
        value = nextValue() ?? value
    }
}

extension View {
    func readerPresentationColorScheme(_ scheme: ColorScheme?) -> some View {
        // A reader can also open inside a sheet, which owns its own presentation.
        preferredColorScheme(scheme).preference(key: ReaderColorSchemeKey.self, value: scheme)
    }
}

struct ReaderChapterCommentsView: View {
    let target: ReaderChapterCommentsTarget

    @Environment(\.dismiss) private var dismiss
    @State private var state: StateOfComments = .loading
    @State private var attempt = 0
    @State private var showsSourcePage = false
    @State private var pages = ReaderChapterCommentPages()
    @State private var more: MoreComments = .idle

    private enum StateOfComments {
        case loading, loaded, page(URL), failed(String)
    }

    private enum MoreComments { case idle, loading(URL), failed(String) }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    if target.source.ruleReview?.supportsChapterComments == true ||
                        target.source.ruleReview?.supportsChapterCommentsPage == true {
                        sourceComments
                    }
                    if let official = target.official {
                        Link(destination: official.url) {
                            Label("在\(official.platformName)查看此章", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityIdentifier("reader.comments.officialChapter")
                    }
                } header: {
                    Text(target.chapter.title)
                } footer: {
                    if let official = target.official {
                        if official.platform == .fanqie {
                            Text("在官方章节页进入番茄小说 App，在章节结尾选择「\(official.discussionName)」。")
                        } else {
                            Text("打开官方章节后，在阅读页选择「\(official.discussionName)」。")
                        }
                    }
                }
                .listRowBackground(ReadingTheme.sheetCard)
            }
            .readingScrollContentBackgroundHidden()
            .readingSheetTitle("本章评论")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { dismiss() }
                        .accessibilityIdentifier("reader.comments.close")
                }
            }
        }
        .sheet(isPresented: $showsSourcePage) {
            if case .page(let url) = state {
                InAppWebBrowser(url: url, close: { showsSourcePage = false })
                    .ignoresSafeArea()
            }
        }
        .task(id: attempt) {
            let service = NetworkBookService()
            if case .loading(let nextURL) = more {
                do {
                    let page = try await service.loadChapterCommentsPage(
                        book: target.book, chapter: target.chapter, source: target.source, nextPageURL: nextURL
                    )
                    guard !Task.isCancelled else { return }
                    pages.append(page, requestedURL: nextURL)
                    more = .idle
                } catch {
                    guard !Task.isCancelled else { return }
                    more = .failed(error.localizedDescription)
                }
                return
            }
            guard case .loading = state else { return }
            do {
                if target.source.ruleReview?.supportsChapterComments == true {
                    let page = try await service.loadChapterCommentsPage(
                        book: target.book, chapter: target.chapter, source: target.source
                    )
                    guard !Task.isCancelled else { return }
                    pages.append(page, requestedURL: nil)
                    state = .loaded
                } else if target.source.ruleReview?.supportsChapterCommentsPage == true {
                    let url = try await service.chapterCommentsPageURL(
                        book: target.book, chapter: target.chapter, source: target.source
                    )
                    guard !Task.isCancelled else { return }
                    state = .page(url)
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var sourceComments: some View {
        switch state {
        case .loading:
            HStack(spacing: 10) {
                RagdollLoading()
                Text("正在加载评论")
            }
        case .page:
            Button {
                showsSourcePage = true
            } label: {
                Label("打开书源评论页", systemImage: "safari")
            }
            .accessibilityIdentifier("reader.comments.sourcePage")
        case .failed(let message):
            Text(message)
                .accessibilityIdentifier("reader.comments.error")
            Button("重试") {
                state = .loading
                attempt += 1
            }
            .accessibilityIdentifier("reader.comments.retry")
        case .loaded:
            if pages.comments.isEmpty, pages.nextPageURL == nil {
                Text("本章暂无评论")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader.comments.empty")
            } else {
                ForEach(pages.comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        if let author = comment.author {
                            Text(author).font(.subheadline.weight(.semibold))
                        }
                        Text(comment.content).textSelection(.enabled)
                        if let postedAt = comment.postedAt {
                            Text(postedAt).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                if let nextURL = pages.nextPageURL {
                    switch more {
                    case .loading:
                        RagdollLoading("正在加载更多评论")
                    case .idle:
                        Button("加载更多") { loadMore(nextURL) }
                            .accessibilityIdentifier("reader.comments.more")
                    case .failed(let message):
                        Text(message).accessibilityIdentifier("reader.comments.moreError")
                        Button("重试加载更多") { loadMore(nextURL) }
                            .accessibilityIdentifier("reader.comments.retryMore")
                    }
                }
            }
        }
    }

    private func loadMore(_ url: URL) {
        guard pages.nextPageURL == url else { return }
        if case .loading = more { return }
        more = .loading(url)
        attempt += 1
    }
}

struct InAppWebBrowser: UIViewControllerRepresentable {
    let url: URL
    var isChapterPage = false
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(chapterURL: isChapterPage ? url : nil, close: close) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let chapterURL: URL?
        let close: () -> Void
        init(chapterURL: URL?, close: @escaping () -> Void) {
            self.chapterURL = chapterURL
            self.close = close
        }
        func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            guard let chapterURL else { return }
            let result = didLoadSuccessfully ? "初始导航完成" : "初始导航失败"
            DiagnosticLog.shared.record(didLoadSuccessfully ? .info : .warning, category: "章节原网页",
                message: "系统 Safari · \(DiagnosticLog.safeURL(chapterURL)) · \(result)（HTTP 状态不可见）")
        }
        func safariViewController(_ controller: SFSafariViewController, initialLoadDidRedirectTo url: URL) {
            guard let chapterURL else { return }
            DiagnosticLog.shared.record(category: "章节原网页",
                message: "系统 Safari · \(DiagnosticLog.safeURL(chapterURL)) · 初始导航重定向到 \(DiagnosticLog.safeURL(url))")
        }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { close() }
    }
}

struct ReaderEdgeBackNavigation: UIViewControllerRepresentable {
    var isAllowed = true

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.isAllowed = isAllowed }

    final class Controller: UIViewController, UIGestureRecognizerDelegate, UINavigationControllerDelegate, UIViewControllerAnimatedTransitioning {
        var isAllowed = true
        private lazy var edgePan: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            gesture.maximumNumberOfTouches = 1
            gesture.delegate = self
            return gesture
        }()
        private var interaction: UIPercentDrivenInteractiveTransition?
        private weak var draggedModal: UIViewController?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.view.addGestureRecognizer(edgePan)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            edgePan.view?.removeGestureRecognizer(edgePan)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let x = touch.location(in: gestureRecognizer.view).x
            return isAllowed && (0...28).contains(x)
        }

        // The player presents a full-screen reader with its own single-page navigation stack.
        private var modalReader: UIViewController? {
            guard let navigationController, navigationController.viewControllers.count == 1 else { return nil }
            var host: UIViewController = navigationController
            while let parent = host.parent { host = parent }
            guard host.modalPresentationStyle == .overFullScreen, host.presentingViewController != nil,
                  host.presentedViewController == nil else { return nil }
            return host
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = edgePan.velocity(in: edgePan.view)
            guard velocity.x > abs(velocity.y), isAllowed, let navigationController,
                  navigationController.viewControllers.count > 1 || modalReader != nil,
                  navigationController.transitionCoordinator == nil, navigationController.presentedViewController == nil
            else { return false }
            var page = parent
            while let controller = page {
                if controller === navigationController.topViewController { return true }
                page = controller.parent
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }

        @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
            let width = max(1, gesture.view?.bounds.width ?? 1)
            let window = gesture.view?.window
            let progress = min(1, max(0, gesture.translation(in: window).x / width))
            let velocity = gesture.velocity(in: window).x
            let shouldFinish = gesture.state == .ended && progress + velocity * 0.15 / width > 0.45
            if gesture.state == .began { draggedModal = modalReader }
            if let modalReader = draggedModal {
                switch gesture.state {
                case .began, .changed:
                    modalReader.view.transform = CGAffineTransform(translationX: width * progress, y: 0)
                case .ended, .cancelled, .failed:
                    draggedModal = nil
                    // Leave UIKit's sheet hierarchy intact until the user commits to leaving.
                    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
                                   delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                        modalReader.view.transform = shouldFinish ? CGAffineTransform(translationX: width, y: 0) : .identity
                    } completion: { _ in
                        if shouldFinish { modalReader.dismiss(animated: false) }
                    }
                default: break
                }
                return
            }
            switch gesture.state {
            case .began:
                guard let navigation = navigationController else { return }
                interaction = UIPercentDrivenInteractiveTransition()
                interaction?.completionCurve = .easeOut
                let previousDelegate = navigation.delegate
                navigation.delegate = self
                navigation.popViewController(animated: true)
                // SwiftUI owns subsequent pushes and pops, including changes to the bound path.
                navigation.delegate = previousDelegate
            case .changed:
                interaction?.update(progress)
            case .ended:
                if shouldFinish { interaction?.finish() }
                else { interaction?.cancel() }
                interaction = nil
            case .failed, .cancelled:
                interaction?.cancel()
                interaction = nil
            default: break
            }
        }

        func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationController.Operation,
                                  from fromVC: UIViewController, to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? { self }

        func navigationController(_ navigationController: UINavigationController,
                                  interactionControllerFor animationController: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
            interaction
        }

        func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0.32 }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            guard let reader = context.view(forKey: .from), let previous = context.view(forKey: .to),
                  let destination = context.viewController(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            let width = context.containerView.bounds.width
            let cornerRadius = reader.layer.cornerRadius
            let clipped = reader.clipsToBounds
            reader.clipsToBounds = true
            previous.frame = context.finalFrame(for: destination)
            context.containerView.insertSubview(previous, belowSubview: reader)
            previous.transform = CGAffineTransform(translationX: -width * 0.25, y: 0)
            UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: .curveLinear) {
                reader.layer.cornerRadius = 24
                reader.transform = CGAffineTransform(translationX: width, y: 0)
                previous.transform = .identity
            } completion: { _ in
                reader.layer.cornerRadius = cornerRadius
                reader.clipsToBounds = clipped
                reader.transform = .identity
                previous.transform = .identity
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}

struct ReaderMenuBackGesture: ViewModifier {
    let menuVisible: Bool
    let goBack: () -> Void

    static func shouldGoBack(startX: CGFloat, displacement: CGSize) -> Bool {
        startX >= 0 && startX <= 28 && displacement.width >= 56
            && displacement.width > abs(displacement.height) * 1.5
    }

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onEnded { value in
                    if menuVisible, Self.shouldGoBack(startX: value.startLocation.x, displacement: value.translation) {
                        goBack()
                    }
                },
            including: menuVisible ? .all : .subviews
        )
    }
}

@MainActor enum ReaderScreenOrientation {
    static private(set) var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask = switch value {
        case "1": .portrait
        case "2": .landscape
        case "3": .all
        case "4": .portraitUpsideDown
        case "5": .landscapeLeft
        default: .allButUpsideDown
        }
        supportedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    static func restoreApplicationDefault() { apply("0") }
}

struct ReaderChapterSlider: View {
    let directory: ReaderChapterDirectory
    let simplifiedChinese: Bool
    let currentNumber: Int
    let progress: Double
    let onSelect: (Int) -> Void
    @State private var previewNumber: Int?

    var body: some View {
        let count = directory.readableIndices.count
        let number = previewNumber ?? currentNumber
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let previewNumber, directory.readableIndices.indices.contains(previewNumber - 1) {
                    Text(directory.rows[directory.readableIndices[previewNumber - 1]].title.readerText(simplified: simplifiedChinese))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text("\(previewNumber)/\(count)")
                } else {
                    Text("第 \(currentNumber) 章 / 共 \(count) 章")
                    Spacer(minLength: 0)
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if count > 1 {
                Slider(value: Binding(
                    get: { Double(max(number, 1)) },
                    set: { previewNumber = Int($0.rounded()) }
                ), in: 1...Double(count), step: 1) { editing in
                    if !editing, let previewNumber {
                        self.previewNumber = nil
                        select(previewNumber)
                    }
                }
                .tint(ReadingTheme.accent)
                .accessibilityLabel("章节跳转")
                .accessibilityValue("第 \(number) 章，共 \(count) 章")
                .accessibilityIdentifier("reader.chapterSlider")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(currentNumber + 1)
                    case .decrement: select(currentNumber - 1)
                    @unknown default: break
                    }
                }
            } else {
                ProgressView(value: progress).tint(ReadingTheme.accent)
            }
        }
    }

    private func select(_ number: Int) {
        guard directory.readableIndices.indices.contains(number - 1) else { return }
        onSelect(directory.readableIndices[number - 1])
    }
}

// A detail page opened by a reader sends chapter selections back to that session.
typealias ResumeBookReading = @MainActor (Book, [BookChapter], BookSource?, Int?) -> Void

private struct ResumeBookReadingKey: EnvironmentKey {
    static let defaultValue: ResumeBookReading? = nil
}

extension EnvironmentValues {
    var resumeBookReading: ResumeBookReading? {
        get { self[ResumeBookReadingKey.self] }
        set { self[ResumeBookReadingKey.self] = newValue }
    }
}

struct BookChapterLink<Label: View>: View {
    let book: Book
    let chapters: [BookChapter]
    var source: BookSource?
    let index: Int
    @ViewBuilder let label: () -> Label
    @Environment(\.resumeBookReading) private var resume

    var body: some View {
        if let resume {
            Button { resume(book, chapters, source, index) } label: { label().contentShape(Rectangle()) }
        } else {
            NavigationLink {
                if let source {
                    ReaderView(book: book, chapters: chapters, initialIndex: index, source: source)
                } else {
                    ReaderView(book: book, chapters: chapters, initialIndex: index)
                }
            } label: { label() }
        }
    }
}

extension View {
    @ViewBuilder
    func readerBookInfoDestination(_ page: Binding<ReaderBookInfoPage?>) -> some View {
        let presented = Binding(get: { page.wrappedValue != nil }, set: { if !$0 { page.wrappedValue = nil } })
        if #available(iOS 18.0, *) {
            readingNavigationDestination(isPresented: presented) { page.wrappedValue }
        } else {
            // A nested navigationDestination(isPresented:) repeatedly lays out the chapter list on iOS 17.
            background(NavigationLink(isActive: presented, destination: { page.wrappedValue }) { EmptyView() }.hidden())
        }
    }
}

struct ReaderBookInfoPage: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let source: BookSource?
    let chapters: [BookChapter]
    let resume: ResumeBookReading

    var body: some View {
        Group {
            if let source {
                BookDetailView(book: book, source: source, chapters: chapters)
            } else {
                LocalBookDetailView(book: book, pageTitle: "书籍详情")
            }
        }
        .environment(\.resumeBookReading, { book, chapters, source, index in
            dismiss()
            resume(book, chapters, source, index)
        })
        .readingTabBarHidden()
    }
}

struct ReaderTableOfContents: View {
    let directory: ReaderChapterDirectory
    let simplifiedChinese: Bool
    let currentIndex: Int
    let bookTitle: String
    let bookURL: String
    let sourceID: String?
    let cache: ChapterContentCache
    @Binding var descending: Bool
    let onCache: () -> Void
    let onCacheChapter: (Int) async -> Bool
    @ObservedObject private var batchCache = ChapterBatchCache.shared
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showsDownloadFailure = false
    @State private var search = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                directoryHeader

                let rows = directory.rows(matching: search, descending: descending, simplified: simplifiedChinese)
                List {
                    ForEach(rows) { row in
                        chapterRow(row).id(row.id)
                    }
                }
                .listStyle(.plain)
                .readingScrollContentBackgroundHidden()
                .id(descending)
                .overlay {
                    if rows.isEmpty && !search.isEmpty { ReadingUnavailableView.search(text: search) }
                }

                if sourceID != nil, let progress = batchCache.progress[bookURL] {
                    HStack {
                        Text(progress.title)
                        Text("\(progress.processed)/\(progress.total)").monospacedDigit()
                        Spacer()
                        if progress.isActive {
                            Button("停止缓存") { batchCache.cancel(bookURL: bookURL) }
                        }
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(ReadingTheme.surface)
                }
                Divider().overlay(ReadingTheme.separator)
                if showsSearch {
                    searchBar
                } else {
                    directoryTools { proxy.scrollTo(currentIndex, anchor: .center) }
                }
            }
            .background(ReadingTheme.sheetBackground.ignoresSafeArea())
            .tint(ReadingTheme.accent)
            .alert("章节缓存失败", isPresented: $showsDownloadFailure) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请稍后再点下载重试。")
            }
            .onChange(of: search) { query in
                if query.isEmpty { proxy.scrollTo(currentIndex, anchor: .center) }
            }
            .onAppear {
                if !descending { DispatchQueue.main.async { proxy.scrollTo(currentIndex, anchor: .center) } }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索章节", text: $search)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 9))
            Button("取消", action: closeSearch)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .onAppear { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        search = ""
        showsSearch = false
    }

    private var directoryHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: bookTitle)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("reader.toc.title")
                Text("目录 · \(directory.readableIndices.count) 章")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ReadingTheme.separator)
                .frame(height: 1)
                .padding(.horizontal, 22)
                .accessibilityHidden(true)
        }
    }

    private func directoryTools(locate: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if sourceID != nil {
                Button(action: onCache) {
                    Label("缓存全书", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(ReadingTheme.accentSoft, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("缓存全书章节")
                .accessibilityIdentifier("reader.toc.cache")
                .disabled(directory.readableIndices.isEmpty || batchCache.progress[bookURL]?.isActive == true)
                Spacer(minLength: 4)
            }
            directoryTool("搜索章节", icon: "magnifyingglass") { showsSearch = true }
            directoryTool("定位当前章节", icon: "scope", action: locate)
            directoryTool(descending ? "正序" : "倒序", icon: "arrow.up.arrow.down") { descending.toggle() }
                .accessibilityValue(descending ? "当前倒序" : "当前正序")
        }
        .buttonStyle(.plain)
        .foregroundStyle(ReadingTheme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    private func directoryTool(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .frame(minWidth: 44, maxWidth: sourceID == nil ? .infinity : 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    @ViewBuilder private func chapterRow(_ row: ReaderChapterDirectory.Row) -> some View {
        if let number = row.number {
            ReaderChapterRow(row: row, number: number, title: row.title.readerText(simplified: simplifiedChinese),
                             isCurrent: row.id == currentIndex, bookURL: bookURL, sourceID: sourceID, cache: cache,
                             batchIsActive: batchCache.progress[bookURL]?.isActive == true,
                             onSelect: { onSelect(row.id) }) {
                if !(await onCacheChapter(row.id)) { showsDownloadFailure = true }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            .listRowSeparator(.hidden)
        } else {
            ChapterVolumeLabel(title: row.title.readerText(simplified: simplifiedChinese))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 22, bottom: 2, trailing: 22))
                .listRowSeparator(.hidden)
        }
    }
}

private struct ReaderChapterRow: View {
    let row: ReaderChapterDirectory.Row
    let number: Int
    let title: String
    let isCurrent: Bool
    let bookURL: String
    let sourceID: String?
    let cache: ChapterContentCache
    let batchIsActive: Bool
    let onSelect: () -> Void
    let onDownload: () async -> Void

    @State private var isCached: Bool?
    @State private var isDownloading = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                ChapterDirectoryLabel(number: number, title: title, wordCount: row.wordCount,
                                      updateInfo: row.updateInfo, isCurrent: isCurrent,
                                      titleColor: sourceID == nil || isCached == true ? .primary : .secondary)
                    .padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityValue(isCached.map { $0 ? "已缓存" : "未缓存" } ?? "")
            .accessibilityIdentifier("reader.toc.\(row.id)")

            if sourceID != nil, isCached == false {
                Button {
                    guard !isDownloading else { return }
                    isDownloading = true
                    Task {
                        await onDownload()
                        isDownloading = false
                    }
                } label: {
                    Group {
                        if isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(isDownloading || batchIsActive)
                .accessibilityLabel("下载 \(title)")
                .accessibilityIdentifier("reader.toc.download.\(row.id)")
            }
        }
        .buttonStyle(.plain)
        .task(id: [bookURL, row.chapterURL, sourceID]) {
            isCached = nil
            guard let sourceID else { return }
            let changes = await cache.availability(bookURL: bookURL, chapterURL: row.chapterURL, sourceID: sourceID)
            for await cached in changes {
                guard !Task.isCancelled else { return }
                isCached = cached
            }
        }
    }
}

struct ReaderLoadingOverlay: View {
    let title: String
    var heading = "正在打开本章"
    @State private var showsIndicator = false

    var body: some View {
        ZStack {
            if showsIndicator {
                HStack(spacing: 14) {
                    RagdollLoading(width: 66)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(heading).font(.headline)
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(white: 0.14))
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                }
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reader.chapterLoading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task {
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            showsIndicator = true
        }
    }
}
