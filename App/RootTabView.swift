import SwiftUI
import UniformTypeIdentifiers

enum AppTab: String, CaseIterable {
    case bookshelf, explore, websites, settings

    var title: String {
        switch self {
        case .bookshelf: "书架"
        case .explore: "发现"
        case .websites: "网站"
        case .settings: "设置"
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @State private var readerColorScheme: ColorScheme?
    @State private var selection: AppTab
    @State private var showsDemoReader = false
    @State private var didOpenDemoReader = false
    @State private var sourceImportIsPresented = false
    @State private var displayedSourceNotice: SourceLibraryModel.Notice?
    @AppStorage("themeMode") private var themeMode = "0"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let requested = arguments.firstIndex(of: "-uiDemoTab")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let page = requested ?? UserDefaults.standard.string(forKey: "defaultHomePage")
        let initial = page == "rss" ? .websites : page.flatMap(AppTab.init(rawValue:)) ?? .bookshelf
        _selection = State(initialValue: initial)
    }

    var body: some View {
        // Give TabView a transient binding so its tag projections do not accumulate on the root State.
        let tab = $selection
        TabView(selection: Binding(get: { tab.wrappedValue }, set: { value, transaction in
            tab.transaction(transaction).wrappedValue = value
        })) {
            tabNavigationStack {
                Group {
                    if ProcessInfo.processInfo.arguments.contains("-uiDemoSourceSwitch") {
                        SourceSwitchView(
                            book: DemoContent.books[0],
                            sources: DemoContent.sources,
                            demoCandidates: DemoContent.sourceSwitchCandidates
                        ) { _, _ in true }
                    } else if ProcessInfo.processInfo.arguments.contains("-uiDemoBookDetail") {
                        BookDetailView(
                            demoBook: DemoContent.books[0],
                            source: DemoContent.sources[0],
                            chapters: DemoContent.readerChapters
                        )
                    } else if requestedDemoPage == "search" {
                        SearchView(initialKeyword: automationSearchKeyword)
                    } else if requestedDemoPage == "sources" {
                        SourceManagementView()
                    } else if requestedDemoPage == "rss-photo" {
                        let source = RssSource(sourceUrl: "https://appearance.invalid", sourceName: "图片外观检查")
                        RSSPhotoView(photos: [.init(url: "data:image/png;base64,")], index: 0, source: source, referer: source.sourceUrl)
                    } else {
                        BookshelfView()
                    }
                }
                .readingNavigationDestination(isPresented: $showsDemoReader) {
                    ReaderView(
                        demoBook: DemoContent.books[0],
                        chapters: DemoContent.readerChapters,
                        initialIndex: 0,
                        content: DemoContent.readerText
                    )
                }
                .task {
                    guard !didOpenDemoReader else { return }
                    didOpenDemoReader = true
                    showsDemoReader = ProcessInfo.processInfo.arguments.contains("-uiDemoReader")
                }
            }
                .tabItem { Label(AppTab.bookshelf.title, systemImage: selection == .bookshelf ? "book.fill" : "book").environment(\.symbolVariants, .none) }
                .tag(AppTab.bookshelf)

            tabNavigationStack { ExploreView() }
                .tabItem { Label(AppTab.explore.title, image: selection == .explore ? "ExploreBooklistsSelected" : "ExploreBooklists") }
                .tag(AppTab.explore)

            tabNavigationStack { RSSHomeView() }
                .tabItem { Label(AppTab.websites.title, image: selection == .websites ? "WebsiteFeedSelected" : "WebsiteFeed") }
                .tag(AppTab.websites)

            tabNavigationStack {
                if ProcessInfo.processInfo.arguments.contains("-uiDemoRules") {
                    ReplaceRuleManagementView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoHistory") {
                    ReadingHistoryView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoFiles") {
                    LocalBookFilesView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoOtherSettings") {
                    StartupSettingsView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoAbout") {
                    AboutView()
                } else if ProcessInfo.processInfo.arguments.contains("-uiDemoLogs") {
                    DiagnosticLogView()
                } else {
                    SettingsView()
                }
            }
                .tabItem { Label(AppTab.settings.title, image: selection == .settings ? "SettingsPawGearSelected" : "SettingsPawGear") }
                .tag(AppTab.settings)
        }
        .readingTabBarBackground()
        .onPreferenceChange(ReaderColorSchemeKey.self) { readerColorScheme = $0 }
        .preferredColorScheme(readerColorScheme ?? (themeMode == "2" ? .dark : (themeMode == "1" || themeMode == "3" ? .light : nil)))
        .transaction { transaction in
            if themeMode == "3" { transaction.animation = nil }
        }
        .sheet(item: $sourceLibrary.pendingImport, onDismiss: {
            sourceImportIsPresented = false
            displayedSourceNotice = sourceLibrary.notice
        }) { pending in
            Group {
                if let backup = pending.backup { BackupRestoreView(backup: backup) }
                else if let rules = pending.rules { DetectedRuleImportView(rules: rules, skippedWebsites: pending.skippedWebsites) }
                else { SourceImportReviewView(pending: pending) }
            }
            .environmentObject(sourceLibrary)
            .onAppear { sourceImportIsPresented = true }
        }
        .onChange(of: sourceLibrary.notice?.id) { _ in
            if !sourceImportIsPresented { displayedSourceNotice = sourceLibrary.notice }
        }
        .alert(item: $displayedSourceNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.detail),
                dismissButton: .default(Text("好")) { sourceLibrary.notice = nil }
            )
        }
        .tint(ReadingTheme.accent)
        .toggleStyle(SwitchToggleStyle(tint: ReadingTheme.toggleTint))
    }

    private func tabNavigationStack<Content: View>(@ViewBuilder root: () -> Content) -> some View {
        ReadingNavigationStack { root().background(HomeTabBar()) }
    }

    private var requestedDemoPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiDemoTab"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private var automationSearchKeyword: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiAutomationSearch"),
              arguments.indices.contains(index + 1) else { return "" }
        return arguments[index + 1]
    }
}

private struct BookshelfView: View {
    @ObservedObject private var appLock = AppLock.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @State private var showsLocalImporter = false
    @State private var pendingLocalFiles: [LocalBookImportFile] = []
    @AppStorage("bookshelfSelectedGroupID") private var selectedGroupID = Int(BookGroup.idAll)
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @State private var opening: Task<Void, Never>?
    @State private var warmedReader: ReaderViewModel?
    @State private var readerDestination: ShelfReaderDestination?

    private enum ShelfReaderDestination {
        case prepared(ReaderViewModel)
        case book(Book, BookSource?)
    }
    @State private var showsGroupManager = false
    @State private var orderingGroup: BookGroup?
    @State private var verificationBooks: [Book] = []
    @AppStorage("bookshelfLayout") private var bookshelfLayout = "grid"
    @AppStorage("showsContinueReadingCard") private var showsContinueReadingCard = true

    private var selectedGroup: BookGroup {
        let groups = library.visibleGroups
        return groups.first(where: { $0.id == selectedGroupID })
            ?? groups.first(where: { $0.id == BookGroup.idAll })
            ?? groups.first
            ?? BookGroup(groupId: BookGroup.idAll, groupName: "全部")
    }

    // Older preferences store grid layouts as grid followed by the column count.
    private var showsGrid: Bool { bookshelfLayout.hasPrefix("grid") }

    private var displayedBooks: [Book] { library.books(in: selectedGroup) }

    private var recentBook: Book? {
        displayedBooks.filter(BookReadingPresentation.hasStarted)
            .sorted { $0.durChapterTime > $1.durChapterTime }
            .first
    }

    var body: some View {
        GeometryReader { geometry in
            shelfScrollView {
                VStack(spacing: 0) {
                    ReadingPageHeader(title: "书架", subtitle: "阅读，让时间有了形状", artwork: .bookshelf) {
                        if appLock.credential != nil {
                            Button { appLock.lockNow() } label: { ReadingToolbarIcon(systemName: "lock") }
                                .accessibilityLabel("立即锁定喵阅")
                        }
                        NavigationLink { SearchView() } label: {
                            ReadingToolbarIcon(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜索")
                        bookshelfMenu
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if showsContinueReadingCard, let book = recentBook {
                            Button { open(book) } label: {
                                ContinueReadingCard(book: book)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("bookshelf.continue")
                            .padding(.bottom, 20)
                        }
                        if library.hasLoadedShelf { bookshelfSummary }
                        if !library.hasLoadedShelf {
                            ProgressView("正在读取书架…")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        } else if displayedBooks.isEmpty {
                            EmptyBookshelfHero { showsLocalImporter = true }
                                .padding(.top, min(80, max(24, geometry.size.height * 0.075)))
                        } else {
                            if showsGrid {
                                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                                    ForEach(displayedBooks) { book in
                                        BookshelfBookLink(book: book, grid: true) { open(book) }
                                    }
                                }
                            } else {
                                ForEach(displayedBooks) { book in
                                    BookshelfBookLink(book: book, grid: false) { open(book) }
                                    if book.id != displayedBooks.last?.id {
                                        Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                                            .padding(.leading, 66)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                library.startGroupUpdate(sources: sources.sources, group: selectedGroup)
            }
        }
        .background(ReadingTheme.canvas)
        .navigationBarHidden(true)
        .task(id: library.visibleGroups.map(\.id)) {
            let groups = library.visibleGroups
            if !groups.isEmpty, !groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = Int(selectedGroup.id)
            }
        }
        .readingNavigationDestination(isPresented: Binding(
            get: { readerDestination != nil }, set: { if !$0 { readerDestination = nil } }
        )) {
            switch readerDestination {
            case let .prepared(reader): ReaderView(prepared: reader)
            case let .book(book, source): BookshelfBookDestination(book: book, source: source)
            case nil: EmptyView()
            }
        }
        .onDisappear { opening?.cancel(); warmedReader = nil }
        .task(id: recentBook) {
            warmedReader = nil
            guard let book = recentBook, book.origin != "local",
                  let source = sources.sources.first(where: { $0.id == book.origin }),
                  !ProcessInfo.processInfo.arguments.contains("-uiDemo") else { return }
            let chapters = await library.updateCoordinator.storedChapters(bookURL: book.bookUrl)
            guard !Task.isCancelled, let restored = BookshelfReadViewModel.restoredBook(book, chapters: chapters) else { return }
            let reader = await ReaderViewModel.cachedOpening(book: restored, chapters: chapters, source: source,
                                                             rules: replaceRules.rules, speculative: true)
            if !Task.isCancelled, reader.hasLoadedCurrentChapter { warmedReader = reader }
        }
        .readingLocalBookFileImporter(isPresented: $showsLocalImporter) { files in
            pendingLocalFiles = files
        } onError: { error in
            library.reportError(error)
        }
        .sheet(isPresented: Binding(
            get: { !pendingLocalFiles.isEmpty },
            set: { if !$0 { pendingLocalFiles = [] } }
        )) {
            LocalBookImportReviewView(files: pendingLocalFiles) {
                pendingLocalFiles = []
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showsGroupManager) {
            BookGroupManagerView(groups: library.groups)
                .environmentObject(library)
        }
        .sheet(item: $orderingGroup) { group in
            BookOrderView(group: group)
                .environmentObject(library)
        }
        .sheet(isPresented: Binding(
            get: { !verificationBooks.isEmpty },
            set: { if !$0 { verificationBooks = [] } }
        )) {
            BookshelfVerificationView(books: verificationBooks)
                .environmentObject(library)
        }
        .alert("书架操作失败", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.clearError() } }
        )) {
            Button("好") { library.clearError() }
        } message: {
            Text(library.errorMessage ?? "未知错误")
        }
        .alert("书架更新", isPresented: Binding(
            get: { library.updateMessage != nil },
            set: { if !$0 { library.clearUpdateMessage() } }
        )) {
            let books = library.booksRequiringVerification
            if books.isEmpty {
                Button("好") { library.clearUpdateMessage() }
            } else {
                Button(books.count == 1 ? "去验证" : "去验证（\(books.count) 本）") { verificationBooks = books }
                Button("取消", role: .cancel) { library.clearUpdateMessage() }
            }
        } message: {
            Text(library.updateMessage ?? "")
        }
    }

    @ViewBuilder
    private func shelfScrollView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 16, *), !ReadingCompatibility.usesLegacyUI {
            ScrollView { content() }
        } else {
            // On iOS 15 the native pull-to-refresh gesture is available on List.
            List {
                content()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(ReadingTheme.canvas)
            }
            .listStyle(.plain)
        }
    }

    private func open(_ book: Book) {
        opening?.cancel()
        let source = sources.sources.first { $0.id == book.origin }
        if book.origin == "local", book.localTXTRevision != nil {
            opening = Task {
                let chapters = await library.cachedTXTChapters(for: book)
                guard !Task.isCancelled else { return }
                if chapters.isEmpty {
                    readerDestination = .book(book, nil)
                } else {
                    readerDestination = .prepared(ReaderViewModel(book: book, chapters: chapters, initialIndex: book.durChapterIndex))
                }
                opening = nil
            }
            return
        }
        guard book.origin != "local", let source, !ProcessInfo.processInfo.arguments.contains("-uiDemo") else {
            readerDestination = .book(book, source)
            return
        }
        opening = Task {
            let chapters = await library.updateCoordinator.storedChapters(bookURL: book.bookUrl)
            guard !Task.isCancelled else { return }
            if let restored = BookshelfReadViewModel.restoredBook(book, chapters: chapters) {
                let reader = await ReaderViewModel.cachedOpening(book: restored, chapters: chapters, source: source,
                                                                 rules: replaceRules.rules, reusing: warmedReader)
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = reader.hasLoadedCurrentChapter
                withTransaction(transaction) { readerDestination = .prepared(reader) }
            } else {
                readerDestination = .book(book, source)
            }
            opening = nil
        }
    }

    private var bookshelfSummary: some View {
        let controls = HStack(spacing: 4) {
            bookshelfGroupMenu
            ReadingLayoutPicker(showsGrid: Binding(
                get: { showsGrid },
                set: { bookshelfLayout = $0 ? "grid" : "list" }
            )) {
                bookshelfSortMenu
            }
        }
        .buttonStyle(.plain)
        let count = displayedBooks.count
        let heading = HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("书籍").font(.title3.bold())
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.8)
            Text("（\(count)）").font(.subheadline).foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("书籍，\(count)本")
        .accessibilityAddTraits([.isHeader, .isStaticText])
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    controls
                }
            } else {
                HStack(spacing: 0) {
                    heading
                    Spacer(minLength: 4)
                    controls
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var bookshelfGroupMenu: some View {
        Menu {
            Picker("书架分组", selection: $selectedGroupID) {
                ForEach(library.visibleGroups) { group in
                    Text(group.groupName).tag(Int(group.id))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedGroup.groupName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : 96)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ReadingTheme.groupedCanvas, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        .accessibilityLabel("选择分组")
        .accessibilityValue(selectedGroup.groupName)
    }

    private var bookshelfSortMenu: some View {
        let group = selectedGroup
        return Menu {
            Section("「\(group.groupName)」的排序方式") {
                ForEach(BookshelfSort.allCases) { sort in
                    sortOption(sort, group: group)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("排序方式")
        .accessibilityValue(group.bookshelfSort.title)
    }

    private func sortOption(_ sort: BookshelfSort, group: BookGroup) -> some View {
        Button {
            Task {
                if group.bookshelfSort != sort { await library.setGroupSort(group, sort: sort) }
                if sort == .custom,
                   let saved = library.groups.first(where: { $0.id == group.id && $0.bookshelfSort == sort }),
                   library.books(in: saved).count > 1 {
                    orderingGroup = saved
                }
            }
        } label: {
            if group.bookshelfSort == sort {
                Label(sort.title, systemImage: "checkmark")
            } else {
                Text(sort.title)
            }
        }
        .accessibilityAddTraits(group.bookshelfSort == sort ? .isSelected : [])
    }

    private var bookshelfMenu: some View {
        Menu {
            Button("导入本地书", systemImage: "plus") { showsLocalImporter = true }
            Button("书架分组", systemImage: "rectangle.3.group") { showsGroupManager = true }
            NavigationLink {
                LocalBookFilesView()
            } label: {
                Label("本地书籍文件", systemImage: "folder")
            }
            Divider()
            Toggle("显示「继续阅读」卡片", isOn: $showsContinueReadingCard)
                .toggleStyle(.automatic)
        } label: {
            ReadingToolbarIcon(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
              count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }
}

private struct BookOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    let group: BookGroup

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Section {
                    ForEach(library.books(in: group)) { book in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.name)
                            Text(book.author).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onMove { offsets, destination in
                        Task { await library.moveBooks(in: group, from: offsets, to: destination) }
                    }
                } footer: {
                    Text("拖动调整书籍顺序。同一本书在各分组间共用自定义顺序。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .readingSheetTitle("\(group.groupName) · 自定义顺序")
            .toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { dismiss() }
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.clearError() } }
            )) {
                Button("好") { library.clearError() }
            } message: { Text(library.errorMessage ?? "") }
        }
    }
}

private struct BookshelfVerificationView: View {
    let books: [Book]
    @EnvironmentObject private var library: BookLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var remaining: [Book]
    @State private var selected: Book?

    init(books: [Book]) {
        self.books = books
        _remaining = State(initialValue: books)
    }

    var body: some View {
        if books.count == 1, let book = books.first {
            directory(for: book)
        } else {
            ReadingNavigationStack {
                List(remaining) { book in
                    Button(book.name) { selected = book }
                        .listRowBackground(ReadingTheme.sheetCard)
                }
                .readingScrollContentBackgroundHidden()
                .readingSheetTitle("待验证（\(remaining.count) 本）")
                .toolbar {
                    ReadingSheetActions {
                        ReadingSheetCloseButton { dismiss() }
                    }
                }
            }
            .sheet(item: $selected, onDismiss: {
                if remaining.isEmpty { dismiss() }
            }) { book in
                directory(for: book)
            }
        }
    }

    @ViewBuilder private func directory(for book: Book) -> some View {
        if let url = book.browserDirectoryURL {
            BrowserBookPageView(url: url, action: .directory(url) { rows in
                try await library.refreshFromBrowser(rows, book: book, directory: url)
                remaining.removeAll { $0.id == book.id }
            })
        }
    }
}

private struct BookshelfBookLink: View {
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    let book: Book
    let grid: Bool
    let open: () -> Void
    @State private var showsGroupSelector = false
    @State private var showsWebDirectory = false
    @State private var showsCoverSearch = false

    private var source: BookSource? { sources.sources.first { $0.bookSourceUrl == book.origin } }

    var body: some View {
        let isChecking = library.checkingBookURLs.contains(book.bookUrl)
        Button(action: open) {
            if grid { BookshelfGridItem(book: book, isChecking: isChecking) }
            else { BookshelfRow(book: book, isChecking: isChecking) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            NavigationLink {
                if let source { BookDetailView(book: book, source: source) }
                else { LocalBookDetailView(book: book) }
            } label: {
                Label("书籍详情", systemImage: "info.circle")
            }
            Button("设置封面", systemImage: "photo") { showsCoverSearch = true }
            Button("刷新目录", systemImage: "arrow.clockwise") {
                Task { await library.checkForUpdates(sources: sources.sources, bookURL: book.bookUrl) }
            }
            .disabled(library.isCheckingUpdates)
            if source?.enabled == true, book.browserDirectoryURL != nil {
                Button("用网页刷新目录", systemImage: "globe") { showsWebDirectory = true }
                    .disabled(library.isCheckingUpdates)
            }
            Button("移至分组", systemImage: "rectangle.3.group") { showsGroupSelector = true }
            Button("移出书架", systemImage: "trash", role: .destructive) {
                Task { await library.remove(bookURL: book.bookUrl) }
            }
        }
        .sheet(isPresented: $showsGroupSelector) {
            BookGroupSelectView(book: book).environmentObject(library)
        }
        .sheet(isPresented: $showsCoverSearch) {
            BookCoverSearchView(book: book)
        }
        .sheet(isPresented: $showsWebDirectory) {
            if let url = book.browserDirectoryURL {
                BrowserBookPageView(url: url, action: .directory(url) { rows in
                    try await library.refreshFromBrowser(rows, book: book, directory: url)
                })
            }
        }
    }
}

private struct BookshelfChapters: View {
    let book: Book
    var lineLimit: Int? = 1

    var body: some View {
        let latest = book.latestChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let current = BookReadingPresentation.position(book)
        VStack(alignment: .leading, spacing: 2) {
            Text("读到：\(current)")
            Text("最新：\(latest.isEmpty ? "暂无章节信息" : latest)")
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .lineLimit(lineLimit)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BookUpdateIndicator: View {
    var body: some View {
        RagdollLoading(width: 24)
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.7), in: Circle())
            .accessibilityLabel("正在检测更新")
            .allowsHitTesting(false)
    }
}

private struct ChapterUpdateBadge: View {
    let count: Int
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 20

    var body: some View {
        if count > 0 {
            Text(verbatim: String(count))
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: diameter, minHeight: diameter)
                .background(Color(red: 0.82, green: 0.12, blue: 0.19), in: Capsule())
                .fixedSize()
                .accessibilityLabel("更新 \(count) 章")
        }
    }
}

private struct BookshelfGridItem: View {
    let book: Book
    let isChecking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                BookCoverArtwork(
                    title: book.name,
                    author: book.author,
                    remoteURL: book.displayCoverURL,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .overlay { if isChecking { BookUpdateIndicator() } }
            }
            .aspectRatio(0.70, contentMode: .fit)
            .frame(maxWidth: 180)
            .overlay(alignment: .topTrailing) {
                ChapterUpdateBadge(count: book.lastCheckCount)
                    .padding(3)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(.caption.weight(.semibold))
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(BookReadingPresentation.position(book))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.top, 8)
        }
    }
}

private struct BookshelfBookDestination: View {
    let book: Book
    let source: BookSource?

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-uiDemo"), book.origin != "local" {
            ReaderView(demoBook: book, chapters: DemoContent.readerChapters, initialIndex: 0, content: DemoContent.readerText)
        } else {
            BookshelfReadView(book: book, source: source)
        }
    }
}

private struct ContinueReadingCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let book: Book

    private var actionLabel: some View {
        HStack(spacing: 3) {
            Text("继续阅读")
            Image(systemName: "chevron.forward").accessibilityHidden(true)
        }
        .font(.caption.weight(.semibold))
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize { actionLabel }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(book.name)
                    .font(.headline)
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize { actionLabel }
            }
            BookshelfChapters(book: book, lineLimit: dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background { ReadingCardBackground(cornerRadius: 14) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct BookGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var library: BookLibraryModel
    @State private var newName = ""
    @State private var showsCreate = false
    @State private var editingGroup: BookGroup?
    @State private var editingName = ""
    @State private var editMode: EditMode = .inactive

    @State private var original: [BookGroup]
    @State private var draft: [BookGroup]
    @State private var saving = false
    @State private var saveError: String?

    init(groups: [BookGroup]) {
        _original = State(initialValue: groups)
        _draft = State(initialValue: groups)
    }

    private var customGroups: [BookGroup] {
        draft.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
    }

    var body: some View {
        ReadingNavigationStack {
            groupList
                .readingSheetTitle("书架分组")
                .toolbar {
                    ReadingSheetActions {
                        Button("取消") { dismiss() }
                        ReadingSheetActionButton(isWorking: saving) {
                            saving = true
                            Task {
                                if await library.saveGroupDraft(draft, original: original) { dismiss() }
                                else { saveError = library.errorMessage; library.clearError() }
                                saving = false
                            }
                        }
                    }
                }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("分组未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
        .tint(ReadingTheme.accent)
        .readingPresentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .readingPresentationDragIndicator()
        .alert("新建分组", isPresented: $showsCreate) {
            TextField("分组名称", text: $newName)
            Button("取消", role: .cancel) {}
            // On iOS 17 an initially disabled alert action can dismiss without running.
            Button("创建") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !draft.contains(where: { $0.groupName == name }) else { return }
                guard let id = library.nextGroupID(reserving: draft) else {
                    saveError = "自定义分组已达到上限（63 个）。"
                    return
                }
                draft.append(BookGroup(groupId: id, groupName: name, order: (customGroups.last?.order ?? 0) + 1))
            }
        }
        .alert("重命名分组", isPresented: Binding(
            get: { editingGroup != nil },
            set: { if !$0 { editingGroup = nil } }
        )) {
            TextField("分组名称", text: $editingName)
            Button("取消", role: .cancel) { editingGroup = nil }
            Button("保存") {
                guard let group = editingGroup, let i = draft.firstIndex(where: { $0.id == group.id }) else { return }
                draft[i].groupName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                editingGroup = nil
            }
            .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: customGroups.count) { count in
            if count < 2 { editMode = .inactive }
        }
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            List {
                Group {
                    shelfSummary
                        .listRowSeparator(.hidden)
                    groupsHeading
                        .listRowSeparator(.hidden)
                    if customGroups.isEmpty {
                        Text("暂无自定义分组")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(customGroups) { group in
                        groupRow(group)
                            .swipeActions {
                                Button("删除", role: .destructive) { draft.removeAll { $0.id == group.id } }
                            }
                    }
                    .onMove { offsets, destination in
                        var ordered = customGroups
                        ordered.move(fromOffsets: offsets, toOffset: destination)
                        for i in ordered.indices { ordered[i].order = i + 1 }
                        draft = draft.filter { $0.groupId <= 0 } + ordered
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .readingScrollContentBackgroundHidden()
            .environment(\.editMode, $editMode)

            Button {
                newName = ""
                showsCreate = true
            } label: {
                Label("新建分组", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(ReadingTheme.onAccent)
                    .background(ReadingTheme.accentFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var shelfSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("全部书籍").font(.headline)
            Text("共 \(library.books.count) 本")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottomTrailing) {
            if !dynamicTypeSize.isAccessibilitySize {
                ReadingHeaderArtwork.bookshelf
                    .aspectRatio(220.0 / 72, contentMode: .fit)
                    .frame(width: 136)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
        }
        .readingSheetGroup()
        .accessibilityElement(children: .combine)
    }

    private var groupsHeading: some View {
        HStack {
            Text("自定义分组").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            if customGroups.count > 1 {
                Button(editMode.isEditing ? "完成排序" : "排序") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.subheadline).frame(minHeight: 44)
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 10)
        .frame(minHeight: 44, alignment: .bottom)
    }

    private func groupRow(_ group: BookGroup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: group.show ? "folder" : "eye.slash")
                .foregroundStyle(group.show ? ReadingTheme.accent : Color.secondary)
                .frame(width: 40, height: 40)
                .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.groupName).font(.body.weight(.medium))
                Text(group.show ? "书架可见" : "已隐藏")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !editMode.isEditing {
                Menu {
                    Button(group.show ? "在书架隐藏" : "在书架显示", systemImage: group.show ? "eye.slash" : "eye") {
                        if let i = draft.firstIndex(where: { $0.id == group.id }) { draft[i].show.toggle() }
                    }
                    Button("重命名", systemImage: "pencil") {
                        editingName = group.groupName
                        editingGroup = group
                    }
                    Button("删除", systemImage: "trash", role: .destructive) {
                        draft.removeAll { $0.id == group.id }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(group.groupName)的操作")
            }
        }
        .padding(.vertical, 8)
    }
}

private struct BookGroupSelectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @State private var saving = false
    @State private var saveError: String?
    let book: Book
    @State private var selected: Set<Int64>

    init(book: Book) {
        self.book = book
        _selected = State(initialValue: [])
    }

    private var customGroups: [BookGroup] {
        library.groups.filter { $0.groupId > 0 }.sorted { $0.order < $1.order }
    }

    var body: some View {
        ReadingNavigationStack {
            List(customGroups) { group in
                Button {
                    if !selected.insert(group.id).inserted { selected.remove(group.id) }
                } label: {
                    HStack {
                        Text(group.groupName).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(group.id) { Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent) }
                    }
                }
                .listRowBackground(ReadingTheme.sheetCard)
            }
            .readingScrollContentBackgroundHidden()
            .overlay {
                if customGroups.isEmpty {
                    ReadingUnavailableView("没有自定义分组", systemImage: "rectangle.3.group")
                }
            }
            .readingSheetTitle("移至分组")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton(isWorking: saving) {
                        saving = true
                        Task {
                            if await library.setBook(book, groupIDs: selected) { dismiss() }
                            else { saveError = library.errorMessage ?? "书架记录已变化"; library.clearError() }
                            saving = false
                        }
                    }
                }
            }
            .onAppear {
                selected = Set(customGroups.filter { (book.group & $0.groupId) != 0 }.map(\.groupId))
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("分组未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}

private struct LocalBookImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @State private var files: [LocalBookImportFile]
    let onFinish: () -> Void
    @State private var selectedPaths: Set<String>
    @State private var isImporting = false
    @State private var importError: String?

    private var urls: [URL] { files.map(\.url) }

    init(files: [LocalBookImportFile], onFinish: @escaping () -> Void) {
        _files = State(initialValue: files)
        self.onFinish = onFinish
        _selectedPaths = State(initialValue: Set(files.map { $0.url.path }))
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Button(selectedPaths.count == urls.count ? "取消全选" : "全选") {
                    if selectedPaths.count == urls.count { selectedPaths.removeAll() }
                    else { selectedPaths = Set(urls.map(\.path)) }
                }
                .disabled(isImporting)

                ForEach(urls, id: \.path) { url in
                    Button {
                        if !selectedPaths.insert(url.path).inserted { selectedPaths.remove(url.path) }
                    } label: {
                        HStack {
                            Image(systemName: selectedPaths.contains(url.path) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedPaths.contains(url.path) ? ReadingTheme.accent : .secondary)
                            VStack(alignment: .leading) {
                                Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(.primary)
                                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay { if isImporting { RagdollLoading("正在导入…") } }
            .readingSheetTitle("导入本地书")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { finish() }.disabled(isImporting)
                    ReadingSheetActionButton("导入", busyTitle: "导入中", isWorking: isImporting) {
                        isImporting = true
                        let selected = files.filter { selectedPaths.contains($0.url.path) }
                        Task {
                            let failed = await library.importPickedLocalFiles(selected)
                            isImporting = false
                            if failed.isEmpty {
                                finish()
                            } else {
                                let succeeded = selectedPaths.subtracting(failed)
                                files.removeAll { succeeded.contains($0.url.path) }
                                selectedPaths = failed
                                importError = library.errorMessage
                                library.clearError()
                            }
                        }
                    }
                    .disabled(selectedPaths.isEmpty || isImporting)
                }
            }
        }
        .disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
        .alert("本地书导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}

private struct EmptyBookshelfHero: View {
    @Environment(\.colorScheme) private var colorScheme
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image("BookshelfEmptyArtwork")
                .resizable()
                .scaledToFit()
                .frame(width: 168, height: 112)
                .opacity(colorScheme == .dark ? 0.78 : 1)
                .accessibilityHidden(true)
            Text("书架还是空的")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ReadingTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 22)
            Text("导入本地书，或添加书源后搜索书籍")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Button(action: onImport) {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .accessibilityHidden(true)
                    Text("本地文件")
                        .font(.headline)
                }
                .foregroundStyle(ReadingTheme.onAccent)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .frame(minWidth: 170, minHeight: 44)
                .background(ReadingTheme.accentFill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bookshelf.importLocal")
            .padding(.top, 28)
            NavigationLink { SourceManagementView() } label: {
                Text("添加书源")
                    .font(.body)
                    .foregroundStyle(ReadingTheme.ink)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bookshelf.addSource")
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 32)
    }
}

struct BookshelfReadView: View {
    let book: Book
    let source: BookSource?
    var bookmark: Bookmark? = nil
    @EnvironmentObject private var library: BookLibraryModel
    @StateObject private var model = BookshelfReadViewModel()

    var body: some View {
        Group {
            if !model.chapters.isEmpty, let resolvedBook = model.resolvedBook {
                if let source {
                    ReaderView(
                        book: resolvedBook,
                        chapters: model.chapters,
                        initialIndex: resolvedBook.durChapterIndex,
                        source: source
                    )
                } else {
                    ReaderView(book: resolvedBook, chapters: model.chapters, initialIndex: resolvedBook.durChapterIndex)
                }
            } else {
                ReaderOpeningPage {
                    if let error = model.errorMessage {
                        ReadingUnavailableView(bookmark == nil ? "无法打开书籍" : "无法打开书签", systemImage: "book.closed", description: Text(error))
                    } else {
                        ReaderLoadingOverlay(title: book.name, heading: bookmark == nil ? "正在打开书籍" : "正在恢复书签位置")
                    }
                }
            }
        }
        .task { await model.load(book: book, source: source, library: library, bookmark: bookmark) }
    }
}

private struct ReaderOpeningPage<Content: View>: View {
    @ViewBuilder var content: Content
    @AppStorage("readerTheme") private var readerTheme = "wechat"
    @AppStorage("themeMode") private var themeMode = "0"

    var body: some View {
        let style = themeMode == "3" ? ReaderStylePreset.eInk : ReaderStylePreset.resolve(readerTheme)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: style.background).ignoresSafeArea())
            .readerPresentationColorScheme(style.id == "night" ? .dark : .light)
            .readingTabBarHidden()
    }
}

private struct BookshelfRow: View {
    let book: Book
    let isChecking: Bool
    @ScaledMetric(relativeTo: .body) private var coverWidth = 52

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BookCoverArtwork(
                title: book.name,
                author: book.author,
                remoteURL: book.displayCoverURL,
                width: coverWidth,
                height: coverWidth * 1.42
            )
            .overlay { if isChecking { BookUpdateIndicator() } }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    ChapterUpdateBadge(count: book.lastCheckCount)
                }
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                BookshelfChapters(book: book)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let fixedSource: BookSource?
    private let initialKeyword: String
    private let sheetClose: (() -> Void)?
    @State private var keyword: String
    @StateObject private var model = SearchViewModel()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editsHistory = false
    @State private var showsScope = false
    @State private var selectedGroups = Set<String>()
    @State private var selectedSourceID: String?
    @State private var presentedBrowserPage: BrowserSearchPage?
    @State private var didStartInitialSearch = false
    @State private var searchIsPresented: Bool
    @State private var visibleResultIDs = Set<String>()
    @AppStorage("precisionSearch") private var precisionSearch = false

    init(fixedSource: BookSource? = nil, initialKeyword: String = "", sheetClose: (() -> Void)? = nil) {
        self.sheetClose = sheetClose
        self.fixedSource = fixedSource
        self.initialKeyword = initialKeyword
        _keyword = State(initialValue: initialKeyword)
        _searchIsPresented = State(initialValue: initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                switch model.state {
                case .idle:
                    idleContent
                case .searching where model.books.isEmpty:
                    initialLoadingView
                case .unavailable:
                    unavailableView
                case .empty:
                    emptyResultsView
                case .searching, .finished:
                    resultsContent
                }
                ForEach(model.browserPages) { page in
                    Button { presentedBrowserPage = page } label: {
                        Label(page.manualVerification == nil ? "在浏览器中打开 101 看书搜索" : "手动验证 · \(page.source.bookSourceName)", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }
                if model.state != .searching, !model.diagnostics.isEmpty { diagnosticsCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(sheetClose == nil ? ReadingTheme.canvas : ReadingTheme.sheetBackground)
        .readingSearchField(text: $keyword, isPresented: $searchIsPresented, prompt: "书名或作者")
        .readingScrollDismissesKeyboard()
        .onSubmit(of: [.text, .search]) { startSearch() }
        .onDisappear {
            if model.state == .searching || model.isLoadingMore { model.cancel() }
        }
        .onChange(of: keyword) { value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.cancel(reset: true)
            }
        }
        .onChange(of: model.state) { state in
            if state == .finished { loadMoreForVisibleLastResult() }
        }
        .onChange(of: model.isLoadingMore) { loading in
            if !loading { loadMoreForVisibleLastResult() }
        }
        .onChange(of: library.sources.count) { _ in
            guard !didStartInitialSearch,
                  !initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !library.sources.isEmpty else { return }
            didStartInitialSearch = true
            startSearch()
        }
        .task {
            await model.loadSearchKeywords()
            if !initialKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !library.sources.isEmpty, !didStartInitialSearch {
                didStartInitialSearch = true
                startSearch()
            }
        }
        .readingRouteHeader("搜索", close: sheetClose) {
            Menu {
                Toggle("精准搜索", isOn: $precisionSearch)
                    .toggleStyle(.automatic)
                Button("分组或书源", systemImage: "scope") { showsScope = true }
                NavigationLink {
                    SourceManagementView()
                } label: {
                    Label("书源管理", systemImage: "network")
                }
                if model.state == .searching {
                    Button("停止搜索", systemImage: "stop.fill", role: .destructive) {
                        model.cancel()
                    }
                } else if model.isPaused {
                    Button("继续搜索", systemImage: "play.fill") { model.resume() }
                }
            } label: {
                Label("搜索选项", systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("搜索选项")
            .accessibilityIdentifier("search.options")
        }
        .onChange(of: model.browserPage?.id) { _ in
            if let page = model.browserPage, page.page == 1, !showsScope {
                searchIsPresented = false
                presentedBrowserPage = page
            }
        }
        .sheet(item: $presentedBrowserPage) { page in
            BrowserBookPageView(url: page.url, action: .search(page) { html in
                try await model.useBrowserResults(html, for: page)
            })
        }
        .sheet(isPresented: $showsScope) {
            SearchScopeSheet(
                sources: library.sources.filter(\.enabled),
                groups: library.groups,
                selectedGroups: $selectedGroups,
                selectedSourceID: $selectedSourceID
            )
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if fixedSource == nil {
                Button { showsScope = true } label: { scopeCard }
                    .buttonStyle(.plain)
                    .accessibilityHint("选择要搜索的分组或书源")
            } else {
                scopeCard
            }
            if !model.searchKeywords.isEmpty {
                searchHistoryView
                    .onDisappear { editsHistory = false }
            }
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }

    private var scopeCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("搜索范围")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(scopeDisplay)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    if fixedSource == nil {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(searchableSourceCount) 个可搜索书源")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize {
                Image("ExploreBookStack")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 94)
                    .accessibilityHidden(true)
            }
        }
        .padding(20)
        .background { ReadingCardBackground() }
        .accessibilityElement(children: .combine)
    }

    private var initialLoadingView: some View {
        VStack(spacing: 12) {
            ReadingCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        RagdollLoading()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在搜索“\(model.submittedKeyword)”").font(.headline)
                            Text(searchProgressText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("停止", role: .destructive) { model.cancel() }
                            .font(.subheadline.weight(.medium))
                    }
                    ProgressView(value: searchProgress)
                        .tint(ReadingTheme.accent)
                    Text("结果会在书源返回后立即显示，无需等待全部完成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(0..<2, id: \.self) { _ in SearchLoadingRow() }
        }
    }

    private var resultsContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.submittedKeyword)
                            .font(.title2.bold())
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        Text(model.isShowingCachedResults
                             ? (model.state == .searching ? "已显示缓存结果，正在更新书源" : "已显示缓存结果")
                             : "找到 \(model.books.count) 条结果")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.isPaused {
                        Button("继续", systemImage: "play.fill") { model.resume() }
                            .readingSecondaryButtonStyle()
                            .controlSize(.small)
                    } else if model.state == .searching {
                        HStack(spacing: 4) {
                            RagdollLoading(width: 28)
                            Text("\(model.completedSourceCount)/\(model.totalSourceCount)").font(.caption.monospacedDigit())
                        }
                    } else {
                        StatusPill(text: scopeDisplay, systemImage: "scope")
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(ReadingTheme.groupedCanvas, in: Capsule())
                    }
                }
                if model.state == .searching {
                    ProgressView(value: searchProgress).tint(ReadingTheme.accent)
                }
            }
            .padding(.vertical, 4)

            ForEach(model.books) { book in
                if let source = library.sources.first(where: { $0.bookSourceUrl == book.origin }) {
                    NavigationLink {
                        BookDetailView(searchBook: book, source: source)
                    } label: {
                        SearchBookRow(book: book, showsDisclosure: true)
                    }
                    .buttonStyle(.plain)
                    .onAppear { resultAppeared(book) }
                    .onDisappear { visibleResultIDs.remove(book.id) }
                } else {
                    SearchBookRow(book: book, showsDisclosure: false)
                        .onAppear { resultAppeared(book) }
                        .onDisappear { visibleResultIDs.remove(book.id) }
                }
            }
            if model.isLoadingMore {
                HStack(spacing: 10) {
                    RagdollLoading(width: 28)
                    Text("正在查找更多结果…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if !model.hasMore, model.state == .finished {
                Text("已经到底了")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image("ExploreEmptyBook")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 88)
                    .accessibilityHidden(true)
            }
            Text(model.isPaused ? "搜索已停止" : "未找到“\(model.submittedKeyword)”")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 12)
            Text(emptyResultsDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            if model.isPaused {
                Button("继续搜索") { model.resume() }
                    .readingProminentButtonStyle()
                    .controlSize(.large)
                    .padding(.top, 20)
            }
            Button {
                if keyword.isEmpty { keyword = model.submittedKeyword }
                searchIsPresented = true
            } label: {
                Text("修改关键词")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .foregroundStyle(model.isPaused ? ReadingTheme.accent : ReadingTheme.onAccent)
                    .background(model.isPaused ? Color.clear : ReadingTheme.accentFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, model.isPaused ? 4 : 20)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var unavailableView: some View {
        SearchStateCard(
            title: "当前范围没有可搜索书源",
            detail: "请启用带搜索规则的书源，或调整当前搜索范围。",
            systemImage: "network.slash"
        ) {
            Button("调整范围", systemImage: "scope") { showsScope = true }
                .readingProminentButtonStyle()
            NavigationLink {
                SourceManagementView()
            } label: {
                Label("管理书源", systemImage: "network")
            }
            .readingSecondaryButtonStyle()
        }
    }

    private var searchProgress: Double {
        guard model.totalSourceCount > 0 else { return 0 }
        return Double(model.completedSourceCount) / Double(model.totalSourceCount)
    }

    private var emptyResultsDetail: String {
        if model.isPaused { return "还有书源未搜索完。" }
        if precisionSearch { return "可以缩短关键词，或在搜索选项中关闭精准搜索。" }
        return "试试书名中的几个字，或用作者名搜索。"
    }

    private var searchProgressText: String {
        model.completedSourceCount == 0
            ? "正在连接 \(model.totalSourceCount) 个书源"
            : "已完成 \(model.completedSourceCount) / \(model.totalSourceCount) 个书源"
    }

    private var searchableSourceCount: Int {
        scopedSources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }.count
    }

    private func resultAppeared(_ book: SearchBook) {
        visibleResultIDs.insert(book.id)
        loadMoreForVisibleLastResult()
    }

    private func loadMoreForVisibleLastResult() {
        // A streamed result can appear before its search finishes. Recheck
        // after each batch as well as appearance; the row may stay on screen.
        guard let lastID = model.books.last?.id, visibleResultIDs.contains(lastID) else { return }
        model.loadMore()
    }

    private var diagnosticsCard: some View {
        DisclosureGroup("部分书源未返回结果（\(model.diagnostics.count)）") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.diagnostics.prefix(20)) { diagnostic in
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message).font(.subheadline)
                            Text(diagnostic.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background { ReadingCardBackground(cornerRadius: 18) }
    }

    private var searchHistoryView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("最近搜索")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if editsHistory {
                    Button(role: .destructive) {
                        Task { await model.clearSearchKeywords() }
                    } label: {
                        Text("清空").frame(minWidth: 44, minHeight: 44)
                    }
                }
                Button { editsHistory.toggle() } label: {
                    Text(editsHistory ? "完成" : "管理")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .foregroundStyle(editsHistory ? .primary : .secondary)
            }
            .font(.subheadline)
            LazyVGrid(columns: [GridItem(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 145), spacing: 10)],
                      alignment: .leading, spacing: 10) {
                ForEach(model.searchKeywords) { item in
                    Button {
                        if editsHistory {
                            Task { await model.deleteSearchKeyword(item.word) }
                        } else {
                            keyword = item.word
                            startSearch()
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: editsHistory ? "minus.circle.fill" : "clock")
                                .font(.footnote)
                                .foregroundStyle(editsHistory ? Color.red : .secondary)
                            Text(item.word)
                                .font(.subheadline)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background { ReadingCardBackground(cornerRadius: 14) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editsHistory ? "删除 \(item.word)" : item.word)
                }
            }
        }
    }

    private var scopedSources: [BookSource] {
        if var fixedSource { fixedSource.enabled = true; return [fixedSource] }
        let enabled = library.sources.filter(\.enabled)
        if let selectedSourceID { return enabled.filter { $0.id == selectedSourceID } }
        guard !selectedGroups.isEmpty else { return enabled }
        return enabled.filter { source in selectedGroups.contains(where: source.hasGroup) }
    }

    private var scopeDisplay: String {
        if let fixedSource { return fixedSource.bookSourceName }
        if let selectedSourceID, let source = library.sources.first(where: { $0.id == selectedSourceID }) { return source.bookSourceName }
        return selectedGroups.isEmpty ? "全部书源" : selectedGroups.sorted().joined(separator: ",")
    }

    private func startSearch() {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchIsPresented = false
        model.search(keyword: value, sources: scopedSources, precision: precisionSearch)
    }
}

private struct SearchLoadingRow: View {
    var body: some View {
        ReadingCard {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.12)).frame(width: 58, height: 82)
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.14)).frame(width: 150, height: 14)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.1)).frame(width: 90, height: 11)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 11)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SearchStateCard<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ReadingCard {
            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(ReadingTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(ReadingTheme.accentSoft.opacity(0.5), in: Circle())
                VStack(spacing: 5) {
                    Text(title).font(.headline).multilineTextAlignment(.center)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) { actions }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}

private struct SearchBookRow: View {
    let book: SearchBook
    let showsDisclosure: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsDisclosure {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let latest = book.latestChapterTitle, !latest.isEmpty {
                    Label(latest, systemImage: "text.book.closed")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .accessibilityLabel("最新章节，\(latest)")
                }
                HStack(spacing: 8) {
                    if !book.originName.isEmpty {
                        Text(book.originName)
                            .font(.caption.weight(.medium))
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(ReadingTheme.coral.opacity(0.14), in: Capsule())
                            .accessibilityLabel("书源，\(book.originName)")
                    }
                    if let wordCount = book.wordCount, !wordCount.isEmpty {
                        Text(wordCount).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background { ReadingCardBackground(cornerRadius: 16) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsView: View {
    @AppStorage("themeMode") private var themeMode = "0"
    @ScaledMetric(relativeTo: .body) private var rowHeight = 52

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ReadingPageHeader(title: AppTab.settings.title, subtitle: "按照你的方式阅读", artwork: .profile) {}
                LazyVStack(alignment: .leading, spacing: 24) {
                    appCard
                    settingSection("通用") {
                        settingLink("启动管理", icon: "power") { StartupSettingsView() }
                        settingLink("应用锁", icon: "lock", showsSeparator: false) { AppLockSettingsView() }
                    }
                    readingSection
                    sourcesSection
                    rulesSection
                    settingSection("文件与备份") {
                        settingLink("本地书籍文件", icon: "folder") { LocalBookFilesView() }
                        settingLink("缓存正文导出", icon: "doc.text") { CachedTextExportView() }
                        settingLink("数据备份与恢复", icon: "externaldrive", showsSeparator: false) { LibraryBackupView() }
                    }
                    settingSection("网络与缓存") {
                        settingLink("缓存管理", icon: "internaldrive") { NetworkSettingsView(page: .chapterCache) }
                        settingLink("网络连接", icon: "wifi") { NetworkSettingsView(page: .connection) }
                        settingLink("高级网络", icon: "slider.horizontal.3") {
                            NetworkSettingsView(page: .advancedNetwork)
                        }
                        settingLink("整理数据库", icon: "cylinder", showsSeparator: false) { DatabaseMaintenanceView() }
                    }
                    settingSection("日志") {
                        settingLink("日志与诊断", icon: "doc.text.magnifyingglass", showsSeparator: false) { DiagnosticLogView() }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .clipped()
        .background(ReadingTheme.canvas)
        .accessibilityIdentifier("profile.scroll")
        .navigationBarHidden(true)
    }

    private var appCard: some View {
        NavigationLink {
            AboutView()
        } label: {
            HStack(spacing: 16) {
                Image("BrandIcon")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppIdentity.name)
                        .font(.headline)
                        .foregroundStyle(ProfileTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("读小说、听书、整理网页")
                        .font(.footnote)
                        .foregroundStyle(ProfileTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProfileTheme.ink.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(ProfileTheme.detail.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [ReadingTheme.surface, ProfileTheme.appCardTint],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ReadingTheme.surface.opacity(0.9), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看关于与版本信息")
        .accessibilityIdentifier("profile.about")
    }

    private var readingSection: some View {
        settingSection("阅读") {
            Menu {
                Picker("外观", selection: $themeMode) {
                    Text("跟随系统").tag("0")
                    Text("浅色").tag("1")
                    Text("深色").tag("2")
                    Text("E-Ink 模式").tag("3")
                }
            } label: {
                settingRow("外观", icon: "circle.lefthalf.filled", value: appearanceTitle, showsValuePill: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("外观")
            .accessibilityValue(appearanceTitle)
            .accessibilityIdentifier("profile.appearance")
            settingLink("听书设置", icon: "headphones") {
                ListeningSettingsView(palette: .settings).readingPageTitle("听书设置")
            }
            settingLink("书签", icon: "bookmark") { AllBookmarksView() }
            settingLink("阅读统计", icon: "chart.bar", showsSeparator: false) { ReadingStatisticsView() }
        }
    }

    private var sourcesSection: some View {
        settingSection("内容来源") {
            settingLink("书源管理", icon: "globe") { SourceManagementView() }
            settingLink("网站源管理", icon: "network", showsSeparator: false) { WebsiteSourceManagementView() }
        }
    }

    private var rulesSection: some View {
        settingSection("规则") {
            settingLink("规则订阅", icon: "link") { RuleSubscriptionView() }
            settingLink(ReplaceRuleManagementView.title, icon: "text.badge.checkmark") { ReplaceRuleManagementView() }
            settingLink("TXT 目录规则", icon: "list.bullet.rectangle", showsSeparator: false) {
                TxtTocRuleManagementView()
            }
        }
    }

    private var appearanceTitle: String {
        switch themeMode {
        case "1": "浅色"
        case "2": "深色"
        case "3": "E-Ink 模式"
        default: "跟随系统"
        }
    }

    private func settingSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(ProfileTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background { ReadingCardBackground(cornerRadius: 18) }
        }
    }

    private func settingLink<Destination: View>(
        _ title: String,
        icon: String,
        showsSeparator: Bool = true,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            ProfileDestination(content: destination)
        } label: {
            settingRow(title, icon: icon, showsSeparator: showsSeparator)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.\(icon)")
    }

    private func settingRow(
        _ title: String,
        icon: String,
        value: String? = nil,
        showsValuePill: Bool = false,
        showsSeparator: Bool = true
    ) -> some View {
        HStack(spacing: 18) {
            ProfileSettingIcon(systemName: icon)
                .frame(width: 26, height: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(ProfileTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(ProfileTheme.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, showsValuePill ? 10 : 0)
                    .padding(.vertical, showsValuePill ? 4 : 0)
                    .overlay {
                        if showsValuePill {
                            Capsule().strokeBorder(ProfileTheme.separator, lineWidth: 0.5)
                        }
                    }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(ProfileTheme.secondary.opacity(0.65))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(ProfileTheme.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 62)
                    .padding(.trailing, 18)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// NavigationView on iOS 15 constructs link destinations while laying out the rows.
// Defer their models and settings reads until the destination is displayed.
private struct ProfileDestination<Content: View>: View {
    let content: () -> Content
    var body: some View { content() }
}

private enum ProfileTheme {
    static let appCardTint = adaptive(0xFBF3EC, dark: 0x302923)
    static let ink = adaptive(0x171817, dark: 0xF3F0EC)
    static let secondary = adaptive(0x898A8C, dark: 0xA5A2A0)
    static let detail = adaptive(0xBA916B, dark: 0xD1AB84)
    static let separator = adaptive(0xEAEAEA, dark: 0x373638)

    private static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

private struct ProfileSettingIcon: View {
    let systemName: String

    var body: some View {
        Group {
            if systemName == "textformat.size" {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("A").font(.system(size: 24, weight: .light)).foregroundStyle(ProfileTheme.ink)
                    Text("A").font(.system(size: 13, weight: .medium)).foregroundStyle(ProfileTheme.detail)
                }
            } else if ["circle.lefthalf.filled", "waveform", "bookmark", "clock", "globe"].contains(systemName) {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 24, y: size.height / 24)
                    draw(in: &context)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(ProfileTheme.ink, ProfileTheme.detail)
            }
        }
    }

    private func draw(in context: inout GraphicsContext) {
        let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
        let circle = Path(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
        switch systemName {
        case "circle.lefthalf.filled":
            var half = Path()
            half.addArc(center: CGPoint(x: 12, y: 12), radius: 9.5, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            half.closeSubpath()
            context.fill(half, with: .color(ProfileTheme.ink))
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
            var edge = Path()
            edge.addArc(center: CGPoint(x: 12, y: 12), radius: 10.2, startAngle: .degrees(105), endAngle: .degrees(255), clockwise: false)
            context.stroke(edge, with: .color(ProfileTheme.detail), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        case "waveform":
            for (index, height) in [4.0, 12.0, 21.0, 14.0, 5.0].enumerated() {
                let bar = CGRect(x: 2 + Double(index) * 4.4, y: (24 - height) / 2, width: 2.4, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.2), with: .color(index > 2 ? ProfileTheme.detail : ProfileTheme.ink))
            }
        case "bookmark":
            var bookmark = Path()
            bookmark.move(to: CGPoint(x: 5, y: 21))
            bookmark.addLine(to: CGPoint(x: 5, y: 4))
            bookmark.addQuadCurve(to: CGPoint(x: 7, y: 2), control: CGPoint(x: 5, y: 2))
            bookmark.addLine(to: CGPoint(x: 17, y: 2))
            bookmark.addQuadCurve(to: CGPoint(x: 19, y: 4), control: CGPoint(x: 19, y: 2))
            bookmark.addLine(to: CGPoint(x: 19, y: 21))
            bookmark.addLine(to: CGPoint(x: 12, y: 16))
            bookmark.closeSubpath()
            context.stroke(bookmark, with: .color(ProfileTheme.detail), style: stroke)
        case "clock":
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
            var hands = Path()
            hands.move(to: CGPoint(x: 12, y: 6))
            hands.addLine(to: CGPoint(x: 12, y: 12))
            hands.addLine(to: CGPoint(x: 16, y: 15))
            context.stroke(hands, with: .color(ProfileTheme.detail), style: stroke)
        case "globe":
            let meridian = Path(ellipseIn: CGRect(x: 7.5, y: 2.5, width: 9, height: 19))
            context.stroke(meridian, with: .color(ProfileTheme.detail), style: stroke)
            var parallels = Path()
            for y in [7.0, 17.0] {
                parallels.move(to: CGPoint(x: 4, y: y))
                parallels.addQuadCurve(to: CGPoint(x: 20, y: y), control: CGPoint(x: 12, y: 12))
            }
            context.stroke(parallels, with: .color(ProfileTheme.detail), style: stroke)
            context.stroke(circle, with: .color(ProfileTheme.ink), style: stroke)
        default: break
        }
    }
}

private struct AllBookmarksView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @State private var editingBookmark: Bookmark?
    @State private var exportsJSON = false
    @State private var exportsMarkdown = false

    private var sections: [BookmarkSection] {
        var output: [BookmarkSection] = []
        for bookmark in activity.bookmarks {
            let id = bookmark.bookName + "\u{0}" + bookmark.bookAuthor
            if output.last?.id == id {
                output[output.count - 1].bookmarks.append(bookmark)
            } else {
                output.append(.init(id: id, bookName: bookmark.bookName, author: bookmark.bookAuthor, bookmarks: [bookmark]))
            }
        }
        return output
    }

    var body: some View {
        Group {
            if activity.bookmarks.isEmpty {
                ReadingIllustratedEmptyState(artwork: "HistoryEmptyArtwork", title: "暂无书签",
                                             message: "阅读时可从右上角菜单添加书签。") { EmptyView() }
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.bookmarks) { bookmark in
                                bookmarkLink(bookmark)
                                    .contextMenu {
                                        Button("编辑书签", systemImage: "square.and.pencil") { editingBookmark = bookmark }
                                    }
                            }
                            .listRowBackground(ReadingTheme.surface)
                        } header: {
                            HStack(spacing: 12) {
                                BookCoverArtwork(title: section.bookName, author: section.author,
                                                 remoteURL: section.bookmarks.first.flatMap(matchingBook)?.displayCoverURL,
                                                 width: 34, height: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section.bookName).font(.headline).foregroundStyle(ReadingTheme.ink)
                                    if !section.author.isEmpty { Text(section.author).font(.caption) }
                                }
                            }
                            .textCase(nil)
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .readingListTopMargin(4)
                .readingScrollContentBackgroundHidden()
            }
        }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle("书签")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !activity.bookmarks.isEmpty {
                    Menu("导出", systemImage: "square.and.arrow.up") {
                        Button("导出 JSON") { exportsJSON = true }
                        Button("导出 Markdown") { exportsMarkdown = true }
                    }
                }
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            BookmarkEditorView(bookmark: bookmark)
        }
        .fileExporter(
            isPresented: $exportsJSON,
            document: BookmarkExportDocument(data: jsonExportData),
            contentType: .json,
            defaultFilename: exportFilename(extension: "json")
        ) { _ in }
        .fileExporter(
            isPresented: $exportsMarkdown,
            document: BookmarkExportDocument(data: Data(markdownExport.utf8)),
            contentType: .plainText,
            defaultFilename: exportFilename(extension: "md")
        ) { _ in }
    }

    private func matchingBook(_ bookmark: Bookmark) -> Book? {
        library.books.first { $0.name == bookmark.bookName && $0.author == bookmark.bookAuthor }
    }

    @ViewBuilder private func bookmarkLink(_ bookmark: Bookmark) -> some View {
        if let book = matchingBook(bookmark) {
            NavigationLink {
                BookshelfReadView(book: book, source: sources.sources.first { $0.id == book.origin }, bookmark: bookmark)
            } label: { bookmarkRow(bookmark) }
        } else {
            Button { editingBookmark = bookmark } label: { bookmarkRow(bookmark) }
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bookmark.chapterName.isEmpty ? "第 \(bookmark.chapterIndex + 1) 章" : bookmark.chapterName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if !bookmark.bookText.isEmpty {
                Text(bookmark.bookText)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(ReadingTheme.ink)
                    .lineSpacing(3)
                    .lineLimit(3)
            }
            if !bookmark.content.isEmpty {
                Label(bookmark.content, systemImage: "note.text")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
    }

    private var jsonExportData: Data {
        (try? JSONEncoder().encode(activity.bookmarks)) ?? Data("[]".utf8)
    }

    private var markdownExport: String {
        var output = ""
        var name = ""
        var author = ""
        for bookmark in activity.bookmarks {
            if bookmark.bookName != name && bookmark.bookAuthor != author {
                name = bookmark.bookName
                author = bookmark.bookAuthor
                output += "## \(bookmark.bookName) \(bookmark.bookAuthor)\n\n"
            }
            output += "#### \(bookmark.chapterName)\n\n"
            output += "###### 原文\n \(bookmark.bookText)\n\n"
            output += "###### 摘要\n \(bookmark.content)\n\n"
        }
        return output
    }

    private func exportFilename(extension value: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        return "bookmark-\(formatter.string(from: Date())).\(value)"
    }
}

private struct BookmarkSection: Identifiable {
    let id: String
    let bookName: String
    let author: String
    var bookmarks: [Bookmark]
}

private struct BookmarkExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

private struct BookmarkEditorView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    @State private var saving = false
    @State private var saveError: String?
    @State private var bookText: String
    @State private var content: String

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _bookText = State(initialValue: bookmark.bookText)
        _content = State(initialValue: bookmark.content)
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetForm {
                Section("原文") { TextEditor(text: $bookText).frame(minHeight: 150) }
                Section("摘要") { TextEditor(text: $content).frame(minHeight: 120) }
                Section {
                    Button("删除书签", role: .destructive) {
                        Task { await activity.removeBookmark(bookmark); dismiss() }
                    }
                }
            }
            .readingSheetTitle(bookmark.chapterName.isEmpty ? "编辑书签" : bookmark.chapterName)
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton(isWorking: saving) {
                        saving = true
                        var updated = bookmark
                        updated.bookText = bookText
                        updated.content = content
                        Task {
                            if await activity.updateBookmark(updated) { dismiss() }
                            else { saveError = activity.errorMessage; activity.clearError() }
                            saving = false
                        }
                    }
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("书签未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}

private struct SearchScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sources: [BookSource]
    let groups: [String]
    @Binding var selectedGroups: Set<String>
    @Binding var selectedSourceID: String?
    private enum Scope { case all, groups, source }
    @State private var mode: Scope
    @State private var sourceFilter = ""
    @State private var workingGroups: Set<String>
    @State private var workingSourceID: String?

    init(
        sources: [BookSource],
        groups: [String],
        selectedGroups: Binding<Set<String>>,
        selectedSourceID: Binding<String?>
    ) {
        self.sources = sources
        self.groups = groups
        _selectedGroups = selectedGroups
        _selectedSourceID = selectedSourceID
        _workingGroups = State(initialValue: selectedGroups.wrappedValue)
        _workingSourceID = State(initialValue: selectedSourceID.wrappedValue)
        _mode = State(initialValue: selectedSourceID.wrappedValue != nil ? .source : selectedGroups.wrappedValue.isEmpty ? .all : .groups)
    }

    var body: some View {
        ReadingNavigationStack {
            ReadingSheetList {
                Picker("范围类型", selection: $mode) {
                    Text("全部书源").tag(Scope.all)
                    Text("分组").tag(Scope.groups)
                    Text("书源").tag(Scope.source)
                }
                .pickerStyle(.segmented)

                if mode == .all {
                    Label("全部书源", systemImage: "checkmark")
                } else if mode == .groups {
                    Text("已选 \(workingGroups.count) 个分组").font(.footnote).foregroundStyle(.secondary)
                    ForEach(groups, id: \.self) { group in
                        Button {
                            if !workingGroups.insert(group).inserted { workingGroups.remove(group) }
                        } label: {
                            HStack {
                                Text(group).foregroundStyle(.primary)
                                Spacer()
                                if workingGroups.contains(group) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } else {
                    ReadingPillSearchField(placeholder: "筛选书源", text: $sourceFilter)
                    ForEach(filteredSources) { source in
                        Button {
                            workingSourceID = source.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(source.bookSourceName).foregroundStyle(.primary)
                                    Text(source.bookSourceUrl).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if workingSourceID == source.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .readingSheetTitle("搜索范围")
            .toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton {
                        selectedGroups = mode == .groups ? workingGroups : []
                        selectedSourceID = mode == .source ? workingSourceID : nil
                        dismiss()
                    }
                    .disabled((mode == .groups && workingGroups.isEmpty) || (mode == .source && workingSourceID == nil))
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }

    private var filteredSources: [BookSource] {
        guard !sourceFilter.isEmpty else { return sources }
        return sources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(sourceFilter)
                || $0.bookSourceUrl.localizedCaseInsensitiveContains(sourceFilter)
        }
    }
}
