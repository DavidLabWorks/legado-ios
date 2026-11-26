import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct RSSHomeView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    private var enabledSources: [RssSource] { library.sources.filter(\.enabled) }

    var body: some View {
        SourceBrowsePage() {
            ReadingPageHeader(title: "网站", subtitle: "在喜欢的网站，读点新鲜事", artwork: .websites) {
                HStack(spacing: 4) {
                    NavigationLink { WebsiteActivityList(showsStars: true) } label: { ReadingToolbarIcon(systemName: "star") }
                        .accessibilityLabel("网页收藏")
                        .accessibilityIdentifier("websites.favorites")
                    NavigationLink { WebsiteActivityList(showsStars: false) } label: { ReadingToolbarIcon(systemName: "clock") }
                        .accessibilityLabel("网站阅读记录")
                        .accessibilityIdentifier("websites.history")
                    NavigationLink { WebsiteSourceManagementView() } label: { ReadingToolbarIcon(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("网站源管理")
                }
            }
            VStack(spacing: 0) {
                SourceBrowseSectionHeading(title: "我的网站", countText: "已启用 \(enabledSources.count) 个网站",
                                           hasSources: !enabledSources.isEmpty, countIdentifier: "websites.sourceCount") {
                    WebsiteSourceManagementView()
                }
                sourceList
            }
            .padding(.horizontal, enabledSources.isEmpty ? 24 : 20)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0)
                .background(ReadingTheme.canvas, ignoresSafeAreaEdges: .top)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("websites.scroll")
        .refreshable { await library.load() }
        .navigationTitle("网站")
        .modifier(WebsiteOperationStatus())
    }

    @ViewBuilder private var sourceList: some View {
        let sources = enabledSources
        if sources.isEmpty, !library.hasLoadedSources {
            RagdollLoading("正在加载网站", width: 72, axis: .vertical)
                .frame(maxWidth: .infinity).padding(.top, 54)
        } else if sources.isEmpty {
            VStack(spacing: 16) {
                ReadingUnavailableView("暂无已启用的网站", systemImage: "globe",
                                       description: Text("在网站源管理中添加或启用站点。"))
                NavigationLink { WebsiteSourceManagementView() } label: {
                    Label("添加网站源", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 166, height: 40)
                        .foregroundStyle(ReadingTheme.onAccent)
                        .background(ReadingTheme.accentFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 54)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(sources) { source in
                    NavigationLink { RSSSourceDestinationView(sourceURL: source.sourceUrl) } label: {
                        SourceBrowseRow(title: source.sourceName, detail: source.groups.isEmpty ? (URL(string: source.sourceUrl)?.host ?? source.sourceUrl) : source.groups.joined(separator: " · ")) {
                            Image(systemName: "globe").font(.system(size: 25, weight: .light))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("websites.source.\(source.sourceUrl)")
                }
            }
        }
    }
}

private struct WebsiteActivityList: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @AppStorage(RSSLibraryModel.websiteHistoryKey) private var recordsHistory = true
    let showsStars: Bool
    @State private var searchText = ""
    @State private var confirmsClear = false
    @State private var editingStar: RssStar?

    var body: some View {
        Group {
            if showsStars {
                VStack(spacing: 0) {
                    ReadingPillSearchField(placeholder: "搜索文章", text: $searchText)
                    if !library.stars.isEmpty {
                        Text("共 \(library.stars.count) 条收藏").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    }
                    starList
                }
                .navigationBarTitleDisplayMode(.large)
            } else {
                recordList.searchable(text: $searchText, prompt: "搜索文章")
            }
        }
        .navigationTitle(showsStars ? "网页收藏" : "网站阅读记录")
        .toolbar {
            if showsStars ? !library.stars.isEmpty : !library.records.isEmpty {
                Button { confirmsClear = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel(showsStars ? "清空收藏" : "清空记录")
                    .confirmationDialog(showsStars ? "确定清空全部收藏？" : "确定清空全部阅读记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
                        Button("清空", role: .destructive) { Task { if showsStars { await library.clearStars() } else { await library.clearRecords() } } }
                        Button("取消", role: .cancel) {}
                    }
            }
        }
        .sheet(item: $editingStar) { value in
            RSSStarEditSheet(star: value, save: library.saveStar)
        }
        .modifier(WebsiteOperationStatus())
    }

    private var starList: some View {
        let stars = searchText.isEmpty ? library.stars : library.stars.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return List {
            ForEach(stars) { star in
                Group {
                    if let source = library.sources.first(where: { $0.sourceUrl == star.origin }) {
                        NavigationLink { RSSArticleDetailView(article: star.article, source: source) } label: { RSSArticleRow(article: star.article, source: source) }
                    } else { RSSArticleRow(article: star.article) }
                }.swipeActions(edge: .leading) { Button("编辑", systemImage: "pencil") { editingStar = star }.tint(.blue) }
            }.onDelete { offsets in
                let values = offsets.map { stars[$0] }
                Task { for value in values { await library.removeStar(value) } }
            }
        }.overlay { if library.stars.isEmpty {
            ReadingUnavailableView("没有收藏", systemImage: "star")
        } else if stars.isEmpty {
            VStack(spacing: 12) {
                Text("未找到匹配的收藏").font(.headline)
                Text("没有与「\(searchText)」匹配的收藏。").foregroundStyle(.secondary)
                Button("清除搜索，查看全部 \(library.stars.count) 条") { searchText = "" }
                    .readingSecondaryButtonStyle()
            }.padding()
        } }.listStyle(.plain)
    }
    private var recordList: some View {
        List {
            Section {
                Toggle("记录网页浏览历史", isOn: $recordsHistory)
            } footer: {
                Text(recordsHistory ? "打开网站文章时会保存一条阅读记录。" : "记录已暂停，已有记录会保留。")
            }
            Section {
                if filteredRecords.isEmpty {
                    Text(searchText.isEmpty ? "没有阅读记录" : "没有匹配的记录").foregroundStyle(.secondary)
                }
                ForEach(filteredRecords) { record in
                    if let source = library.sources.first(where: { $0.sourceUrl == record.origin }) {
                        NavigationLink { RSSArticleDetailView(article: record.article, source: source) } label: { RSSArticleRow(article: record.article) }
                    } else { RSSArticleRow(article: record.article) }
                }
            }
        }
    }
    private var filteredRecords: [RssReadRecord] { library.records.filter { searchText.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(searchText) } }
}

struct WebsiteSourceManagementView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @State private var searchText = ""
    @State private var showsFiles = false
    @State private var showsTextImport = false
    @State private var showsExport = false

    @State private var selectedGroup: String?
    @State private var editMode = EditMode.inactive

    private var groups: [String] {
        Set(library.sources.flatMap(\.groups)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var sources: [RssSource] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.sources.filter { source in
            guard source.matchesWebsiteSearch(query) else { return false }
            guard let selectedGroup else { return true }
            return selectedGroup.isEmpty ? source.groups.isEmpty : source.groups.contains(selectedGroup)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SourceManagementSearchHeader(total: library.sources.count, enabled: library.sources.filter(\.enabled).count,
                                         searchText: $searchText)
            if library.sources.isEmpty, !library.hasLoadedSources {
                RagdollLoading("正在加载网站源", width: 72, axis: .vertical)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.sources.isEmpty {
                ReadingIllustratedEmptyState(artwork: "SourceEmptyArtwork", title: "还没有网站源",
                                             message: "新建网站源，或从文件、链接、JSON 导入", bottomBalance: 116) {
                    Menu {
                        importActions
                    } label: {
                        Label("添加网站源", systemImage: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 28)
                            .frame(minHeight: 38)
                            .foregroundStyle(ReadingTheme.onAccent)
                            .background(ReadingTheme.accentFill, in: Capsule())
                    }
                    .padding(.top, 26)
                }
            } else {
                List {
                    Section {
                        ForEach(sources) { source in
                            NavigationLink { RSSSourceEditorView(source: source) } label: {
                                SourceManagementRow(name: source.sourceName, url: source.sourceUrl, groups: source.groups,
                                                    systemImage: "globe", enabled: source.enabled, showsToggle: !editMode.isEditing) { enabled in
                                    Task { await library.setEnabled(enabled, source: source) }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button(source.enabled ? "停用" : "启用") { Task { await library.setEnabled(!source.enabled, source: source) } }.tint(.orange)
                            }
                            .swipeActions {
                                Button("删除", role: .destructive) { Task { await library.remove(source) } }
                            }
                            .moveDisabled(!searchText.isEmpty || selectedGroup != nil)
                        }
                        .onMove { offsets, destination in Task { await library.moveSources(from: offsets, to: destination) } }
                        if sources.isEmpty {
                            Text("未找到网站源").foregroundStyle(.secondary)
                        }
                    } header: {
                        SourceGroupPicker(title: searchText.isEmpty && selectedGroup == nil ? "网站源" : "网站源 · \(sources.count)",
                                          groups: groups, selection: $selectedGroup)
                    }
                    .listRowBackground(ReadingTheme.surface)
                }
                .readingManagementList()
                .environment(\.editMode, $editMode)
            }
        }
        .onChange(of: groups) { available in
            if let selectedGroup, !selectedGroup.isEmpty, !available.contains(selectedGroup) { self.selectedGroup = nil }
        }
        .background(ReadingTheme.managementCanvas)
        .navigationTitle("网站源管理")
        .navigationBarTitleDisplayMode(.large)
        .navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .disabled(library.sources.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("网站源操作", systemImage: "ellipsis") {
                    importActions
                    Button("导出全部网站源", systemImage: "square.and.arrow.up") { showsExport = true }
                }
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.json, .text], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): Task { await library.importFiles(urls) }
            case let .failure(error): library.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsTextImport) { RSSImportSheet() }
        .fileExporter(isPresented: $showsExport, document: RSSExportDocument(sources: library.sources), contentType: .json, defaultFilename: "rssSources") { result in
            if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
        }
        .modifier(WebsiteOperationStatus())
    }

    @ViewBuilder private var importActions: some View {
        NavigationLink { RSSSourceEditorView() } label: { Label("新建网站源", systemImage: "plus") }
        Button("导入文件", systemImage: "doc.badge.plus") { showsFiles = true }
        Button("URL或粘贴JSON", systemImage: "link.badge.plus") { showsTextImport = true }
    }
}

private extension RssSource {
    func matchesWebsiteSearch(_ query: String) -> Bool {
        query.isEmpty || sourceName.localizedCaseInsensitiveContains(query)
            || sourceUrl.localizedCaseInsensitiveContains(query) || (sourceGroup ?? "").localizedCaseInsensitiveContains(query)
    }
}

private struct WebsiteOperationStatus: ViewModifier {
    @EnvironmentObject private var library: RSSLibraryModel
    func body(content: Content) -> some View {
        content.overlay { if library.isWorking { RagdollLoading(width: 72) } }
            .alert("网站操作失败", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好") { library.errorMessage = nil }
            } message: { Text(library.errorMessage ?? "") }
    }
}

private struct WebsitePaginationVisible: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let visible = nextValue()
        value = value || visible
    }
}

private struct RSSArticleListView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: RssSource
    var sheetClose: (() -> Void)? = nil
    @State private var showsSearch = false
    @State private var searchText = ""
    @State private var searchKey: String?
    @FocusState private var searchFocused: Bool
    @State private var sorts: [RSSSort] = []
    @State private var resolvingSorts = true
    @State private var selectedSort = 0
    @State private var lastPullSignal = -Double.infinity
    @State private var pullInProgress = false
    @State private var confirmsClear = false

    var body: some View {
        VStack(spacing: 0) {
            if showsSearch {
                HStack(spacing: 12) {
                    TextField("源内搜索", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.search)
                        .onSubmit {
                            searchFocused = false
                            searchKey = searchText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                            Task { await refresh(preferCache: searchKey == nil) }
                        }
                        .accessibilityAddTraits(.isSearchField)
                        .accessibilityIdentifier("website.sourceSearchField")
                    Button("取消", action: closeSearch)
                        .accessibilityLabel("取消搜索")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            } else if sorts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(Array(sorts.enumerated()), id: \.element.id) { index, sort in
                        Button(sort.name.isEmpty ? "默认" : sort.name) { selectedSort = index; Task { await refresh(preferCache: true) } }
                            .readingChoiceButtonStyle(isSelected: selectedSort == index)
                    }}.padding(.horizontal)
                }.padding(.vertical, 6)
            }
            GeometryReader { viewport in
                articleCollection(viewport: viewport.size)
                    .opacity(resolvingSorts ? 0 : 1)
                    .accessibilityHidden(resolvingSorts)
                    .overlay {
                        if resolvingSorts || (library.articles.isEmpty && library.refreshingFeed) {
                            RagdollLoading("正在加载列表", width: 80, axis: .vertical)
                                .accessibilityIdentifier("website.list.loading")
                        } else if library.articles.isEmpty, !library.canLoadMore {
                            ReadingIllustratedEmptyState(artwork: "RSSArticleEmptyArtwork", title: "没有文章",
                                                         message: "下拉可以重新加载文章。", bottomBalance: 0) { EmptyView() }
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: "websiteArticleList")
                    .onPreferenceChange(WebsitePaginationVisible.self) { visible in
                        if visible { requestNextPage() }
                    }
            }
            .refreshable {
                // SwiftUI can signal repeatedly while one pull stays above the threshold.
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - lastPullSignal
                lastPullSignal = now
                guard !pullInProgress, elapsed > 0.45 else { return }
                pullInProgress = true
                defer { pullInProgress = false }
                // SwiftUI may cancel its refresh callback when published loading state rebuilds the scroll view.
                await Task { await refresh() }.value
            }
        }
        .readingRouteHeader(source.sourceName, close: sheetClose) {
            Menu {
                if searchURL != nil, !showsSearch {
                    Button {
                        withAnimation(searchAnimation) { showsSearch = true }
                    } label: { Label("源内搜索", systemImage: "magnifyingglass") }
                }
                if source.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    NavigationLink { SourceLoginView(source: source.bookSourceAdapter) } label: { Label("源登录", systemImage: "person.badge.key") }
                }
                NavigationLink { RSSSourceEditorView(source: source) } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                Button(role: .destructive) { confirmsClear = true } label: {
                    if #available(iOS 16, *) {
                        Label("清空数据", systemImage: "eraser.line.dashed")
                    } else {
                        Label("清空数据", systemImage: "delete.left")
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis").labelStyle(.iconOnly)
            }
            .confirmationDialog("清空「\(source.sourceName)」所有分类的文章缓存？", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("清空数据", role: .destructive) { Task { await library.clearArticleCache(for: source) } }
                Button("取消", role: .cancel) {}
            }
        }
        .task {
            if sorts.isEmpty { sorts = await RSSSortResolver().resolve(source) }
            guard !Task.isCancelled else { return }
            resolvingSorts = false
            await refresh(preferCache: true)
        }
        .onChange(of: showsSearch) { searchFocused = $0 }
        .onChange(of: searchURL) { url in
            if url == nil, showsSearch { closeSearch() }
        }
        .readingTabBarHidden()
    }

    private var activeSort: RSSSort { sorts.indices.contains(selectedSort) ? sorts[selectedSort] : .init(name: "", url: source.sourceUrl) }

    private var searchURL: String? { source.searchUrl?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private var activeName: String { searchKey == nil ? activeSort.name : "搜索" }
    private var searchAnimation: Animation { .easeInOut(duration: reduceMotion ? 0.15 : 0.25) }

    private func closeSearch() {
        searchFocused = false
        withAnimation(searchAnimation) { showsSearch = false }
        searchText = ""
        if searchKey != nil {
            searchKey = nil
            Task { await refresh(preferCache: true) }
        }
    }

    private func refresh(preferCache: Bool = false) async {
        let url = searchKey == nil ? activeSort.url : (searchURL ?? activeSort.url)
        await library.refresh(source, sortName: activeName, sortURL: url, key: searchKey, preferCache: preferCache)
    }

    private func requestNextPage() {
        Task { await library.loadMore(source, sortName: activeName, key: searchKey) }
    }

    @ViewBuilder private func paginationFooter(viewportHeight: CGFloat) -> some View {
        if library.canLoadMore {
            VStack(spacing: 4) {
                if library.isLoadingMore {
                    HStack(spacing: 8) {
                        RagdollLoading(width: 28).accessibilityHidden(true)
                        Text("正在加载下一页")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("website.pagination.loading")
                } else if let error = library.paginationError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试加载下一页") { requestNextPage() }
                } else {
                    Button("加载下一页") { requestNextPage() }
                        .disabled(library.refreshingFeed)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                GeometryReader { footer in
                    let top = footer.frame(in: .named("websiteArticleList")).minY
                    let threshold = viewportHeight * (source.preload ? 2 : 1)
                    Color.clear.preference(key: WebsitePaginationVisible.self,
                        value: viewportHeight > 0 && top < threshold && !library.refreshingFeed &&
                            !library.isLoadingMore && library.paginationError == nil)
                }
            }
        }
    }

    @ViewBuilder private func articleCollection(viewport: CGSize) -> some View {
        if source.articleStyle == 0 {
            List {
                ForEach(library.articles) { article in
                    NavigationLink { reader(for: article) } label: {
                        RSSArticleRow(article: article, source: source, listTitle: RSSListTitle(article.title))
                    }
                    .listRowInsets(EdgeInsets(top: 17, leading: 30, bottom: 17, trailing: 28))
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ReadingTheme.groupedCanvas.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 3)
                    )
                    .onAppear { articleAppeared(article) }
                }
                paginationFooter(viewportHeight: viewport.height)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }.listStyle(.plain)
        } else if #available(iOS 16.0, *) {
            ScrollView {
                VStack(spacing: 0) {
                    articleGrid(width: viewport.width)
                    paginationFooter(viewportHeight: viewport.height)
                }
            }
        } else {
            // On iOS 15 pull-to-refresh is provided by List.
            List {
                VStack(spacing: 0) {
                    articleGrid(width: viewport.width)
                    paginationFooter(viewportHeight: viewport.height)
                }.listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            }.listStyle(.plain)
        }
    }

    private func articleAppeared(_ article: RssArticle) {
        guard library.canLoadMore, !library.refreshingFeed, !library.isLoadingMore,
              library.paginationError == nil else { return }
        if library.articles.suffix(source.preload ? 5 : 1).contains(where: { $0.id == article.id }) {
            requestNextPage()
        }
    }

    @ViewBuilder private func articleGrid(width: CGFloat) -> some View {
        if source.articleStyle == 3 {
            let spacing: CGFloat = 20
            let columnWidth = max(0, (width - 3 * spacing) / 2)
            let columns = RSSArticleCard.waterfallColumns(library.articles, width: columnWidth,
                                                         spacing: spacing, dynamicTypeSize: dynamicTypeSize)
            HStack(alignment: .top, spacing: spacing) {
                ForEach(columns.indices, id: \.self) { index in
                    LazyVStack(spacing: spacing) {
                        ForEach(columns[index], content: articleLink)
                    }
                    .frame(width: columnWidth)
                }
            }
            .padding(.horizontal, spacing).padding(.bottom, spacing)
        } else {
            LazyVGrid(columns: articleColumns, spacing: 8) {
                ForEach(library.articles, content: articleLink)
            }.padding(.horizontal, 8).padding(.bottom, 20)
        }
    }

    private func articleLink(_ article: RssArticle) -> some View {
        NavigationLink { reader(for: article) } label: {
            RSSArticleCard(article: article, style: source.articleStyle)
        }.buttonStyle(.plain)
        .onAppear { articleAppeared(article) }
    }

    private var articleColumns: [GridItem] {
        let count = source.articleStyle == 1 ? 1 : (source.articleStyle == 4 ? 3 : 2)
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8, alignment: .top), count: count)
    }

    private func reader(for article: RssArticle) -> some View {
        RSSFeedReader(article: article, source: source, sortName: activeName, searchKey: searchKey)
    }
}

private struct RSSFeedReader: View {
    @EnvironmentObject private var library: RSSLibraryModel
    let article: RssArticle
    let source: RssSource
    let sortName: String
    let searchKey: String?
    @State private var advancedTo: RssArticle?

    var body: some View {
        let current = advancedTo ?? article
        let index = library.articles.firstIndex { $0.id == current.id }
        let next = index.flatMap { library.articles.dropFirst($0 + 1).first }
        RSSArticleDetailView(article: current, source: source, nextArticle: next.map { target in
            RSSNextArticle(title: target.title) { advancedTo = target }
        })
        .id(current.id)
        .task(id: current.id) {
            if index != nil, next == nil, library.canLoadMore {
                await library.loadMore(source, sortName: sortName, key: searchKey)
            }
        }
    }
}

private struct RSSSourceDestinationView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    let sourceURL: String
    var body: some View {
        // NavigationLink can retain its destination after a source is replaced
        // by an import. Resolve current rules through the shared library.
        if let source = library.sources.first(where: { $0.sourceUrl == sourceURL }) {
            if source.singleUrl {
                RSSStandaloneReaderView(source: source, mode: .web(url: source.sourceUrl))
            } else if let mode = try? RSSStartPageResolver().resolve(source) {
                RSSStandaloneReaderView(source: source, mode: mode)
            } else {
                RSSArticleListView(source: source)
            }
        } else {
            ReadingUnavailableView("网站源已删除", systemImage: "newspaper")
        }
    }
}

private struct RSSStandaloneReaderView: View {
    let source: RssSource
    let mode: RSSReadingMode
    var sheetClose: (() -> Void)? = nil
    @State private var pageTitle: String?
    @State private var route: RSSNativeRoute?
    var body: some View {
        RSSContentReader(mode: mode, source: source, pageTitle: $pageTitle, onAction: handle)
            .readingRouteHeader(pageTitle ?? source.sourceName, close: sheetClose) { EmptyView() }
            .sheet(item: $route) { route in
                RSSRouteSheet(route: route, source: source)
            }
    }
    private func handle(_ action: RSSWebAction) {
        switch action {
        case .searchBook(let key, _): route = .search(key)
        case .addBook(let value): route = .addBook(value)
        case .download(let url, let fileName): route = .download(url: url, fileName: fileName)
        case .open(let name, let url, let title, _):
            switch name.lowercased() {
            case "login": route = .login
            case "search": if let value = title ?? url { route = .search(value) }
            case "sort": var value = source; value.sortUrl = url; route = .sort(value)
            case "rss":
                if let url { route = .rss(.init(origin: source.sourceUrl, sort: "", title: title ?? source.sourceName, link: url)) }
                else if source.singleUrl { route = .start(.web(url: source.sourceUrl)) }
                else if let mode = try? RSSStartPageResolver().resolve(source) { route = .start(mode) }
                else { route = .sort(source) }
            default: if let url, let target = URL(string: url) { UIApplication.shared.open(target) }
            }
        }
    }
}

struct RSSGalleryPhoto {
    let url: String
    var omitReferer = false
    var displayedInArticle = false

    // HTTP requests and WebKit's archived resources omit the URL fragment.
    static func resourceKey(_ url: String) -> String {
        String(url.prefix { $0 != "#" })
    }
}

struct RSSGallerySelection: Identifiable {
    let id = UUID()
    let photos: [RSSGalleryPhoto]
    let index: Int
    let displayedImages: Task<[String: Data], Never>?
    let onLocate: ((Int) -> Void)?
}

private struct RSSContentReader: View {
    let mode: RSSReadingMode
    let source: RssSource
    @Binding var pageTitle: String?
    var articleURL: String?
    var nextArticle: RSSNextArticle?
    var onRefresh: (() -> Void)?
    let onAction: (RSSWebAction) -> Void
    @State private var gallery: RSSGallerySelection?
    @State private var videoURL: URL?
    @State private var miniVideo = false
    @State private var collapseProgress: CGFloat = 0
    @State private var miniPosition = UnitPoint.bottomTrailing

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let inlineHeight = min(width * 9 / 16, geometry.size.height * 0.52)
            let inset: CGFloat = 6
            let miniWidth = min(width * 0.48, 220, max(0, geometry.size.height - 2 * inset) * 16 / 9)
            let miniHeight = miniWidth * 9 / 16
            let travelX = max(0, width - miniWidth - 2 * inset)
            let travelY = max(0, geometry.size.height - miniHeight - 2 * inset)
            let progress = miniVideo ? 1 : collapseProgress
            article
                .overlay(alignment: .topLeading) {
                    if let videoURL {
                        RSSVideoPlayer(url: videoURL, referer: URL(string: articleURL ?? source.sourceUrl),
                                       mini: miniVideo, setMini: setMini, onCollapseDrag: { distance, ended in
                                           let fraction = min(1, max(0, distance / max(1, inset + travelY)))
                                           if ended {
                                               setMini(distance > min(80, travelY * 0.25))
                                           } else {
                                               miniPosition = .bottomTrailing
                                               collapseProgress = fraction
                                           }
                                       }, onDrag: { delta in
                                           if travelX > 0 { miniPosition.x = min(1, max(0, miniPosition.x + delta.x / travelX)) }
                                           if travelY > 0 { miniPosition.y = min(1, max(0, miniPosition.y + delta.y / travelY)) }
                                       }, onClose: {
                                           self.videoURL = nil
                                           miniVideo = false
                                           collapseProgress = 0
                                       })
                            .id(videoURL)
                            .frame(width: width + (miniWidth - width) * progress,
                                   height: inlineHeight + (miniHeight - inlineHeight) * progress)
                            .clipShape(RoundedRectangle(cornerRadius: 8 * progress))
                            .shadow(radius: 3 * progress)
                            .offset(x: (inset + miniPosition.x * travelX) * progress,
                                    y: (inset + miniPosition.y * travelY) * progress)
                    }
                }
        }
        .fullScreenCover(item: $gallery) { selection in
            RSSPhotoView(photos: selection.photos, index: selection.index, source: source, referer: articleURL ?? source.sourceUrl, displayedImages: selection.displayedImages, onLocate: selection.onLocate)
        }
    }

    private func setMini(_ compact: Bool) {
        withAnimation(.easeInOut(duration: 0.32)) {
            if compact { miniPosition = .bottomTrailing }
            miniVideo = compact
            collapseProgress = 0
        }
    }

    private var article: some View {
        RSSWebReaderView(mode: mode, source: source, pageTitle: $pageTitle,
                         imageBaseURL: articleURL, onShowPhoto: { gallery = $0 }, onPlayVideo: { url in
                             setMini(false)
                             if url != videoURL { miniPosition = .bottomTrailing }
                             videoURL = url
                         }, nextArticle: nextArticle, onRefresh: onRefresh, onAction: onAction)
    }
}

// Some feeds append compact media labels to the headline. Keep their original units.
private struct RSSListTitle {
    let text: String
    let media: String?
    private static let mediaSuffix = try! NSRegularExpression(
        pattern: #"^[0-9]{1,5}[PV](?:\s*\+\s*[0-9]{1,5}[PV])*$"#, options: .caseInsensitive)

    init(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.last, end == "]" || end == "】",
           let start = trimmed.lastIndex(of: end == "]" ? "[" : "【") {
            let label = String(trimmed[trimmed.index(after: start)..<trimmed.index(before: trimmed.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let headline = trimmed[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
            if !headline.isEmpty, Self.mediaSuffix.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
                text = headline
                media = label
                return
            }
        }
        text = title
        media = nil
    }
}

private struct RSSArticleRow: View {
    let article: RssArticle
    var source: RssSource? = nil
    var listTitle: RSSListTitle? = nil

    private var summary: String? {
        // Rule-based sources without a summary rule store the opened article's HTML in description.
        if let source, source.ruleArticles?.isEmpty == false, source.ruleDescription?.nilIfEmpty == nil { return nil }
        guard let description = article.description, !description.isEmpty else { return nil }
        return MetadataTextSanitizer().clean(String(description.prefix(1024)))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(listTitle?.text ?? article.title)
                    .font(.body.weight(listTitle != nil || article.read ? .regular : .medium))
                    .foregroundStyle(article.read ? .secondary : .primary)
                    .lineSpacing(listTitle == nil ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if listTitle?.media != nil || article.pubDate?.nilIfEmpty != nil {
                    HStack(spacing: 8) {
                        if let media = listTitle?.media {
                            Text(media)
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(ReadingTheme.separator.opacity(0.65), in: Capsule())
                        }
                        if let date = article.pubDate?.nilIfEmpty { Text(date).font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if article.type == 1 { Image(systemName: "photo") }
            else if article.type == 2 { Image(systemName: "play.rectangle") }
        }
    }
}

private struct RSSArticleCard: View {
    let article: RssArticle
    let style: Int
    private static let waterfallImageHeight: CGFloat = 180
    private static let waterfallTitleLines = 9
    private static let compactInset: CGFloat = 6
    private static let verticalPadding: CGFloat = 10
    private static let dateSpacing: CGFloat = 8

    static func waterfallColumns(_ articles: [RssArticle], width: CGFloat, spacing: CGFloat,
                                 dynamicTypeSize: DynamicTypeSize) -> [[RssArticle]] {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let title = UILabel()
        title.font = .boldSystemFont(ofSize: subheadline.pointSize)
        title.numberOfLines = waterfallTitleLines
        let textSize = CGSize(width: max(1, width - 2 * compactInset), height: CGFloat.greatestFiniteMagnitude)
        let dateHeight = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits).lineHeight
        var columns = [[RssArticle](), [RssArticle]()]
        var heights = [CGFloat.zero, CGFloat.zero]
        for article in articles {
            let index = heights[0] <= heights[1] ? 0 : 1
            columns[index].append(article)
            title.text = article.title
            heights[index] += waterfallImageHeight + 2 * verticalPadding + title.sizeThatFits(textSize).height + spacing
            if let date = article.pubDate, !date.isEmpty {
                heights[index] += dateSpacing + ceil(dateHeight)
            }
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            articleImage
            Text(article.title)
                .font(style == 1 || style == 3 ? .subheadline.bold() : .caption)
                .foregroundStyle(article.read ? .secondary : .primary)
                .lineLimit(style == 3 ? Self.waterfallTitleLines : 2)
                .padding(.horizontal, style == 1 ? 12 : Self.compactInset).padding(.top, Self.verticalPadding)
            if let date = article.pubDate, !date.isEmpty {
                Text(date).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, style == 1 ? 12 : Self.compactInset).padding(.top, Self.dateSpacing).padding(.bottom, Self.verticalPadding)
            } else { Spacer().frame(height: Self.verticalPadding) }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(style == 3 ? Color(.secondarySystemBackground) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: style == 3 ? 12 : 0, style: .continuous))
        .overlay { if style == 3 { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)) } }
        .contentShape(Rectangle())
    }

    private var articleImage: some View {
        GeometryReader { column in
            Group {
                if let raw = article.image, let url = URL(string: raw) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else if phase.error != nil { placeholder }
                        else { RagdollLoading() }
                    }
                } else { placeholder }
            }
            .frame(width: column.size.width, height: column.size.height)
            .clipped()
        }
        .frame(height: imageHeight)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack { Color(.tertiarySystemFill); Image(systemName: article.type == 2 ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imageHeight: CGFloat {
        switch style {
        case 1: return 220
        case 2: return 272
        case 4: return 182
        default: return Self.waterfallImageHeight
        }
    }
}

private struct RSSArticleDetailView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    let article: RssArticle
    let source: RssSource
    var nextArticle: RSSNextArticle?
    var sheetClose: (() -> Void)? = nil
    @State private var mode: RSSReadingMode?
    @State private var pageTitle: String?
    @State private var reloadID = 0
    @State private var loadedRequest: String?
    @State private var showsBrowser = false
    @State private var nativeRoute: RSSNativeRoute?

    var body: some View {
        let browserURL = URL.originalWebPage(from: article.link, relativeTo: article.origin)
        Group {
            if let mode {
                RSSContentReader(mode: mode, source: source, pageTitle: $pageTitle, articleURL: article.link,
                                 nextArticle: nextArticle, onRefresh: { reloadID += 1 }, onAction: handleWebAction)
                    .id(loadedRequest)
            } else {
                RagdollLoading("正在加载文章", width: 80, axis: .vertical)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .readingRouteHeader(pageTitle ?? article.title, close: sheetClose) {
            Button(library.isStarred(article) ? "取消收藏" : "收藏", systemImage: library.isStarred(article) ? "star.fill" : "star") { Task { await library.toggleStar(article) } }
            if let url = URL(string: article.link) { ReadingShareLink(item: url) }
            if browserURL != nil {
                Button("浏览器打开", systemImage: "safari") { showsBrowser = true }
            }
        }
        .sheet(isPresented: $showsBrowser) {
            if let browserURL {
                InAppWebBrowser(url: browserURL, close: { showsBrowser = false }).ignoresSafeArea()
            }
        }
        .task(id: "\(article.id):\(reloadID)") {
            let request = "\(article.id):\(reloadID)"
            guard loadedRequest != request else { return }
            mode = nil
            pageTitle = nil
            await library.read(article)
            let loaded = await library.readingMode(for: article, source: source, forceRefresh: reloadID > 0)
            guard !Task.isCancelled else { return }
            loadedRequest = request
            mode = loaded
        }
        .sheet(item: $nativeRoute) { route in
            RSSRouteSheet(route: route, source: source)
        }
    }

    private func handleWebAction(_ action: RSSWebAction) {
        switch action {
        case .searchBook(let key, _): nativeRoute = .search(key)
        case .addBook(let value): nativeRoute = .addBook(value)
        case .open(let name, let url, let title, _):
            switch name.lowercased() {
            case "search": if let key = title ?? url { nativeRoute = .search(key) }
            case "login": nativeRoute = .login
            case "sort":
                var target = source
                if let url {
                    if let title, let data = try? JSONSerialization.data(withJSONObject: [title: url]) { target.sortUrl = String(decoding: data, as: UTF8.self) }
                    else { target.sortUrl = url }
                }
                nativeRoute = .sort(target)
            case "rss":
                if let url { nativeRoute = .rss(.init(origin: source.sourceUrl, sort: "", title: title ?? source.sourceName, link: url)) }
                else if source.singleUrl { nativeRoute = .start(.web(url: source.sourceUrl)) }
                else if let mode = try? RSSStartPageResolver().resolve(source) { nativeRoute = .start(mode) }
                else { nativeRoute = .sort(source) }
            default: if let url, let target = URL(string: url) { UIApplication.shared.open(target) }
            }
        case .download(let url, let fileName): nativeRoute = .download(url: url, fileName: fileName)
        }
    }
}

private enum RSSNativeRoute: Identifiable {
    case search(String), rss(RssArticle), login, sort(RssSource), addBook(String), download(url: String, fileName: String), start(RSSReadingMode)
    var id: String {
        switch self {
        case .search(let value): return "search:\(value)"
        case .rss(let value): return "rss:\(value.id)"
        case .login: return "login"
        case .sort(let value): return "sort:\(value.sourceUrl):\(value.sortUrl ?? "")"
        case .addBook(let value): return "addBook:\(value)"
        case .download(let url, _): return "download:\(url)"
        case .start(let mode): return "start:\(String(describing: mode))"
        }
    }
}

private struct RSSRouteSheet: View {
    let route: RSSNativeRoute
    let source: RssSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReadingNavigationStack {
            switch route {
            case .search(let key):
                SearchView(initialKeyword: key, sheetClose: dismiss.callAsFunction)
            case .rss(let article):
                RSSArticleDetailView(article: article, source: source, sheetClose: dismiss.callAsFunction)
            case .login:
                SourceLoginView(source: source.bookSourceAdapter, sheetClose: dismiss.callAsFunction)
            case .sort(let target):
                RSSArticleListView(source: target, sheetClose: dismiss.callAsFunction)
            case .addBook(let url):
                RSSAddBookView(bookURL: url)
            case .download(let url, let name):
                RSSDownloadView(url: url, fileName: name, source: source)
            case .start(let mode):
                RSSStandaloneReaderView(source: source, mode: mode, sheetClose: dismiss.callAsFunction)
            }
        }
    }
}

private struct RSSDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    let url: String
    let fileName: String
    let source: RssSource
    @State private var data = Data()
    @State private var loading = true
    @State private var showsExporter = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            if loading { RagdollLoading("正在下载…") }
            else if let errorMessage { ReadingUnavailableView("下载失败", systemImage: "exclamationmark.arrow.triangle.2.circlepath", description: Text(errorMessage)) }
            else {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 48)).foregroundStyle(ReadingTheme.accent)
                Text(fileName).font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).foregroundStyle(.secondary)
                Button("选择保存位置", systemImage: "folder") { showsExporter = true }.readingProminentButtonStyle()
            }
        }.padding().readingSheetTitle("文件下载").toolbar {
            ReadingSheetActions {
                ReadingSheetCloseButton { dismiss() }
            }
        }
            .task(id: url) { await download() }
            .fileExporter(isPresented: $showsExporter, document: RSSBinaryDocument(data: data), contentType: .data, defaultFilename: fileName) { result in if case .failure(let error) = result { errorMessage = error.localizedDescription } }
    }

    private func download() async {
        do {
            guard let target = URL(string: url) else { throw URLError(.badURL) }
            var request = URLRequest(url: target)
            if let headers = try? BookSourceHeaderResolver().resolve(source.bookSourceAdapter) { for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) } }
            let cookie = LegadoCookieStore.shared.cookieHeader(for: url)
            if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (value, response) = try await URLSessionHTTPTransport.shared.download(for: request)
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) { throw URLError(.badServerResponse) }
            data = value; loading = false; showsExporter = true
        } catch { errorMessage = error.localizedDescription; loading = false }
    }
}

private struct RSSBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

struct RSSPhotoView: View {
    let photos: [RSSGalleryPhoto]
    let index: Int
    let source: RssSource
    let referer: String
    var displayedImages: Task<[String: Data], Never>?
    var onLocate: ((Int) -> Void)?

    var body: some View {
        PhotoViewer(pageCount: photos.count, index: index, onLocate: onLocate) { page, retry in
            let data = try await imageData(for: photos[page], retry: retry)
            try Task.checkCancellation()
            return try PreviewPhoto(data: data)
        }
    }

    private func imageData(for photo: RSSGalleryPhoto, retry: Bool) async throws -> Data {
        let value = photo.url
        if value.lowercased().hasPrefix("data:image/"), let comma = value.firstIndex(of: ",") {
            let payload = String(value[value.index(after: comma)...])
            if value[..<comma].lowercased().contains(";base64") {
                guard let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { throw URLError(.cannotDecodeContentData) }
                return decoded
            }
            return Data((payload.removingPercentEncoding ?? payload).utf8)
        }

        if photo.displayedInArticle {
            if let data = await displayedImages?.value[RSSGalleryPhoto.resourceKey(value)] { return data }
            // Only an explicit retry may re-request an image the article already displayed.
            if !retry { throw URLError(.resourceUnavailable) }
        }
        try Task.checkCancellation()
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased()) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        let site = URL(string: source.sourceUrl)
        for (key, header) in try BookSourceHeaderResolver().resolve(source.bookSourceAdapter) {
            if ["authorization", "cookie"].contains(key.lowercased()), url.host != site?.host { continue }
            request.setValue(header, forHTTPHeaderField: key)
        }
        if photo.omitReferer {
            request.setValue(nil, forHTTPHeaderField: "Referer")
        } else if request.value(forHTTPHeaderField: "Referer") == nil, let ref = URL(string: referer),
           let host = ref.host, let scheme = ref.scheme, ["https", "http"].contains(scheme) {
            let origin = scheme + "://" + host + (ref.port.map { ":\($0)" } ?? "") + "/"
            request.setValue(origin, forHTTPHeaderField: "Referer")
        }
        let cookie = LegadoCookieStore.shared.cookieHeader(for: value)
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (bytes, response) = try await URLSessionHTTPTransport.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return bytes
    }
}

private struct RSSImportSheet: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var text = ""
    var body: some View {
        ReadingNavigationStack {
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).padding()
                .readingSheetTitle("导入网站源")
                .toolbar {
                    ReadingSheetActions {
                        Button("取消") { dismiss() }
                        ReadingSheetActionButton("导入", busyTitle: "导入中", isWorking: importing) {
                            importing = true
                            Task {
                                if await library.importText(text) { dismiss() }
                                importing = false
                            }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .disabled(importing)
        .interactiveDismissDisabled(importing)
        .modifier(WebsiteOperationStatus())
    }
}

private struct RSSExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(sources: [RssSource]) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? encoder.encode(sources)) ?? Data("[]".utf8)
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct RSSStarEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: RssStar
    @State private var saving = false
    @State private var saveError: String?
    let save: (RssStar) async throws -> Void
    init(star: RssStar, save: @escaping (RssStar) async throws -> Void) { _value = State(initialValue: star); self.save = save }
    var body: some View {
        ReadingNavigationStack {
            Form {
                TextField("标题", text: $value.title)
                TextField("分组", text: $value.group)
                ReadingLabeledContent("链接", value: value.link).textSelection(.enabled)
            }.readingSheetTitle("编辑RSS收藏").toolbar {
                ReadingSheetActions {
                    Button("取消") { dismiss() }
                    ReadingSheetActionButton(isWorking: saving) {
                        saving = true
                        Task {
                            do { try await save(value); dismiss() }
                            catch { saveError = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("收藏未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
