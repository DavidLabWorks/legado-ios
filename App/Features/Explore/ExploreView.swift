import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @Environment(\.colorScheme) private var colorScheme

    private var sources: [BookSource] {
        sourceLibrary.sources
            .filter { $0.enabled && $0.enabledExplore && !($0.exploreUrl?.isEmpty ?? true) }
            .sorted {
                if $0.customOrder != $1.customOrder { return $0.customOrder < $1.customOrder }
                return $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending
            }
    }

    var body: some View {
        SourceBrowsePage(showsExploreWave: !sources.isEmpty) {
            header
            VStack(spacing: 0) {
                SourceBrowseSectionHeading(title: "分类与榜单", countText: "\(sources.count)个书源", hasSources: !sources.isEmpty,
                                           countIdentifier: "explore.sourceCount") {
                    SourceManagementView()
                }
                if sources.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            NavigationLink { ExploreSourceView(source: source) } label: {
                                ExploreSourceRow(source: source, position: index)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, sources.isEmpty ? 24 : 20)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("explore.scroll")
    }

    private var header: some View {
        ReadingPageHeader(title: "发现", subtitle: "下一本好书，在这里遇见") {
            NavigationLink { SearchView() } label: { ReadingToolbarIcon(systemName: "magnifyingglass") }
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("explore.search")
            NavigationLink { SourceManagementView() } label: { ReadingToolbarIcon(systemName: "slider.horizontal.3") }
                .accessibilityLabel("书源管理")
                .accessibilityIdentifier("explore.manageSources")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image("ExploreEmptyBook")
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 100)
                .opacity(colorScheme == .dark ? 0.75 : 1)
                .accessibilityHidden(true)
            Text("暂无发现书源")
                .font(.title3.bold())
                .padding(.top, 12)
            Text("添加带有发现分类的书源，即可在这里浏览书籍")
                .font(.subheadline)
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            NavigationLink { SourceManagementView() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                    Text("添加书源").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(ReadingTheme.onAccent)
                .frame(width: 166, height: 40)
                .background {
                    Capsule().fill(LinearGradient(
                        colors: [ReadingTheme.accentFill, ReadingTheme.emphasisSurface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                }
                .padding(.vertical, 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("explore.addSource")
            .padding(.top, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 54)
    }
}

struct SourceBrowseSectionHeading<Destination: View>: View {
    let title: String
    let countText: String
    let hasSources: Bool
    let countIdentifier: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        HStack(spacing: 10) {
            if hasSources {
                Capsule()
                    .fill(ReadingTheme.ink)
                    .frame(width: 4, height: 18)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            NavigationLink { destination() } label: {
                HStack(spacing: 5) {
                    Text(countText)
                        .font(.footnote)
                    if hasSources {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(countIdentifier)
        }
        .padding(.horizontal, hasSources ? 3 : 0)
        .padding(.bottom, hasSources ? 10 : 0)
    }
}

struct SourceBrowsePage<Content: View>: View {
    @Environment(\.refresh) private var refresh
    var showsExploreWave = false
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                ScrollView { pageContent }
            } else if refresh != nil {
                List { pageContent.listRowInsets(EdgeInsets()).listRowSeparator(.hidden) }
                    .listStyle(.plain)
            } else {
                ScrollView { pageContent }
            }
        }
        .background {
            ReadingTheme.canvas.ignoresSafeArea()
                .overlay(alignment: .top) {
                    if showsExploreWave {
                        ExploreHeaderWave()
                            .fill(ReadingTheme.groupedCanvas.opacity(0.6))
                            .frame(height: 160)
                            .padding(.top, 46)
                            .accessibilityHidden(true)
                    }
                }
        }
        .navigationBarHidden(true)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
    }
}

private struct ExploreSourceRow: View {
    let source: BookSource
    let position: Int
    var body: some View {
        SourceBrowseRow(title: source.bookSourceName,
                        detail: source.groups.isEmpty ? (URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl) : source.groups.joined(separator: " · ")) {
            ExploreSourceIcon(source: source, position: position)
        }
    }
}

private struct ExploreSourceIcon: View {
    let source: BookSource
    let position: Int

    var body: some View {
        Group {
            if source.bookSourceType == 1 {
                Image(systemName: "headphones")
            } else {
                switch position % 7 {
                case 0: Image(systemName: "cloud")
                case 1, 4: ExploreGem().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                case 3: Image(systemName: UIImage(systemName: "party.popper") == nil ? "sparkles" : "party.popper")
                case 6: ExploreStackIcon().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                default: Image(systemName: "book")
                }
            }
        }
        .font(.system(size: 25, weight: .light))
        .foregroundStyle(ReadingTheme.ink)
    }
}

private struct ExploreGem: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.04, 0.32))
        [point(0.23, 0.08), point(0.77, 0.08), point(0.96, 0.32), point(0.5, 0.94)].forEach { path.addLine(to: $0) }
        path.closeSubpath()
        path.move(to: point(0.04, 0.32)); path.addLine(to: point(0.96, 0.32))
        path.move(to: point(0.37, 0.08)); path.addLine(to: point(0.29, 0.32)); path.addLine(to: point(0.5, 0.94))
        path.move(to: point(0.63, 0.08)); path.addLine(to: point(0.71, 0.32)); path.addLine(to: point(0.5, 0.94))
        return path
    }
}

private struct ExploreStackIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0..<3 {
            let y = rect.minY + rect.height * (0.12 + CGFloat(row) * 0.25)
            let spine = CGRect(x: rect.minX + rect.width * 0.1, y: y,
                               width: rect.width * 0.78, height: rect.height * 0.23)
            path.addRoundedRect(in: spine, cornerSize: CGSize(width: rect.width * 0.1, height: rect.height * 0.1))
            path.move(to: CGPoint(x: spine.maxX - rect.width * 0.14, y: spine.minY))
            path.addQuadCurve(to: CGPoint(x: spine.maxX - rect.width * 0.14, y: spine.maxY),
                              control: CGPoint(x: spine.maxX, y: spine.midY))
        }
        return path
    }
}

private struct ExploreHeaderWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.23, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.65),
                      control1: CGPoint(x: rect.width * 0.73, y: -rect.height * 0.35),
                      control2: CGPoint(x: rect.width * 0.72, y: rect.height * 0.17))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct ExploreSourceView: View {
    @StateObject private var model: ExploreSourceViewModel

    init(source: BookSource) {
        _model = StateObject(wrappedValue: ExploreSourceViewModel(
            source: source,
            demoBooks: ProcessInfo.processInfo.arguments.contains("-uiDemo") ? DemoContent.exploreBooks : nil
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.kinds.count > 1 {
                kindPicker
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        content
                        if model.isLoadingMore { RagdollLoading("继续加载…").padding(.vertical, 12) }
                        if let error = model.paginationError {
                            VStack(spacing: 8) {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button("重试加载下一页") { model.retryNextPage() }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .id("booksTop")
                }
                .accessibilityIdentifier("explore.books")
                .onChange(of: model.selectedKind?.id) { _ in
                    proxy.scrollTo("booksTop", anchor: .top)
                }
                .refreshable { await model.reload() }
            }
        }
        .background(ReadingTheme.canvas)
        .readingPageTitle(model.source.bookSourceName)
        .task { await model.load() }
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.kinds) { kind in
                    let selected = model.selectedKind?.id == kind.id
                    Button {
                        Task { await model.select(kind: kind) }
                    } label: {
                        Text(kind.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : .secondary)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if selected {
                            Capsule().fill(Color.primary).frame(height: 2)
                        }
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            RagdollLoading("正在加载小说…", width: 72, axis: .vertical)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        case .empty:
            ReadingUnavailableView(
                "暂无小说",
                systemImage: "books.vertical",
                description: Text("当前书源或分类暂时没有内容，可以下拉刷新。")
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
        case .failed where model.books.isEmpty:
            ReadingUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(model.diagnostics.first?.message ?? "书源发现规则解析失败。")
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
        default:
            ForEach(model.books) { book in
                NavigationLink {
                    BookDetailView(searchBook: book, source: model.source)
                } label: {
                    ExploreBookRow(book: book)
                }
                .buttonStyle(.plain)
                .onAppear { model.loadNextPageIfNeeded(current: book) }
            }
        }
    }
}

private struct ExploreBookRow: View {
    let book: SearchBook

    private var byline: String {
        let author = book.author.isEmpty ? "未知作者" : book.author
        guard let kind = book.kind, !kind.isEmpty else { return author }
        return "\(author) · \(kind)"
    }

    var body: some View {
        HStack(spacing: 12) {
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL, width: 60, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.headline)
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(2)
                Text(byline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                .padding(.leading, 72)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
