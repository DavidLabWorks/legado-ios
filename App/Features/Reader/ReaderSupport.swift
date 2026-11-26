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
                .listRowBackground(Color(uiColor: .secondarySystemBackground))
            }
            .readingScrollContentBackgroundHidden()
            .readingSheetSurface()
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
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { close() }
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

// A details sheet opened by a reader sends chapter selections back to that session.
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

struct ReaderBookInfoSheet: View {
    let book: Book
    let source: BookSource?
    let chapters: [BookChapter]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReadingNavigationStack {
            Group {
                if let source {
                    BookDetailView(book: book, source: source, chapters: chapters)
                } else {
                    LocalBookDetailView(book: book)
                }
            }
            .readingSheetTitle(source == nil ? book.name : "书籍详情")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { dismiss() }
                }
            }
        }
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
    @ObservedObject private var batchCache = ChapterBatchCache.shared
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ReadingNavigationStack {
            ScrollViewReader { proxy in
                let rows = directory.rows(matching: search, descending: descending, simplified: simplifiedChinese)
                List {
                    ForEach(rows) { row in
                        chapterRow(row).id(row.id)
                    }
                }
                .listStyle(.plain)
                .id(descending)
                .overlay {
                    if rows.isEmpty && !search.isEmpty { ReadingUnavailableView.search(text: search) }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if showsSearch { searchBar } else { directoryHeader }
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
                            .background(.bar)
                        }
                    }
                }
                .onChange(of: search) { query in
                    if query.isEmpty { proxy.scrollTo(currentIndex, anchor: .center) }
                }
                .toolbar {
                    ReadingSheetActions {
                        if !showsSearch {
                            Button { showsSearch = true } label: { Label("搜索章节", systemImage: "magnifyingglass") }
                        }
                        Button {
                            if search.isEmpty { proxy.scrollTo(currentIndex, anchor: .center) }
                            closeSearch()
                        } label: { Image(systemName: "scope") }
                        .accessibilityLabel("定位当前章节")
                        ReadingSheetCloseButton { dismiss() }
                    }
                }
                .onAppear {
                    if !descending { DispatchQueue.main.async { proxy.scrollTo(currentIndex, anchor: .center) } }
                }
            }
            .readingSheetTitle("目录")
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
        .background(ReadingTheme.surface)
        .onAppear { searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        search = ""
        showsSearch = false
    }

    private var directoryHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(bookTitle)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 16) {
                Text("共 \(directory.readableIndices.count) 章")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if sourceID != nil {
                    Button(action: onCache) {
                        Label("缓存", systemImage: "arrow.down.circle")
                            .frame(minHeight: 44)
                    }
                    .disabled(directory.readableIndices.isEmpty || batchCache.progress[bookURL]?.isActive == true)
                    .accessibilityLabel("缓存全书章节")
                    .accessibilityIdentifier("reader.toc.cache")
                }
                Button { descending.toggle() } label: {
                    Label(descending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down")
                        .frame(minHeight: 44)
                }
            }
            .font(.footnote.weight(.medium))
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .padding(.horizontal, 20)
        .background(ReadingTheme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func chapterRow(_ row: ReaderChapterDirectory.Row) -> some View {
        if let number = row.number {
            let current = row.id == currentIndex
            Button { onSelect(row.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ChapterDirectoryLabel(number: number, count: directory.readableIndices.count,
                                          title: row.title.readerText(simplified: simplifiedChinese), isCurrent: current)
                    if let sourceID {
                        ChapterAvailabilityIcon(bookURL: bookURL, chapterURL: row.chapterURL, sourceID: sourceID, cache: cache)
                    }
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("reader.toc.\(row.id)")
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparatorTint(ReadingTheme.separator.opacity(0.65))
        } else {
            ChapterVolumeLabel(title: row.title.readerText(simplified: simplifiedChinese))
                .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
                .listRowSeparator(.hidden)
        }
    }
}

struct ChapterAvailabilityIcon: View {
    let bookURL: String
    let chapterURL: String
    let sourceID: String
    var cache: ChapterContentCache = .live()
    @State private var isCached: Bool?

    var body: some View {
        ZStack {
            if isCached == false {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .padding(.leading, 12)
                    .accessibilityLabel("未下载")
            }
        }
        .task(id: [bookURL, chapterURL, sourceID]) {
            isCached = nil
            let changes = await cache.availability(bookURL: bookURL, chapterURL: chapterURL, sourceID: sourceID)
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
