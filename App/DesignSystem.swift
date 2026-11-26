import SwiftUI

struct ReadingUnavailableView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            ContentUnavailableView {
                label
            } description: {
                description
            } actions: {
                actions
            }
        } else {
            VStack(spacing: 12) {
                label.labelStyle(ReadingUnavailableLabelStyle())
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                actions.padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ReadingUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init {
            SwiftUI.Label(title, systemImage: systemImage)
        } description: {
            description
        } actions: {
            EmptyView()
        }
    }

    @ViewBuilder
    static func search(text: String) -> some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            ContentUnavailableView.search(text: text)
        } else {
            ReadingUnavailableView(
                "无搜索结果",
                systemImage: "magnifyingglass",
                description: Text("没有找到与“\(text)”相关的内容，请尝试其他关键词。")
            )
        }
    }
}

private struct ReadingUnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            configuration.title.font(.title2.bold())
        }
    }
}

extension View {
    /// Keep filled controls dark in both appearances, independently of icon tint.
    func readingProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(ReadingTheme.accentFill)
            .foregroundStyle(ReadingTheme.onAccent)
    }

    func readingSecondaryButtonStyle() -> some View {
        buttonStyle(.bordered)
            .tint(ReadingTheme.accentFill)
            .foregroundStyle(ReadingTheme.accent)
    }

    @ViewBuilder
    func readingChoiceButtonStyle(isSelected: Bool) -> some View {
        if isSelected {
            readingProminentButtonStyle()
                .accessibilityAddTraits(.isSelected)
        } else {
            readingSecondaryButtonStyle()
        }
    }

    func readingSearchable(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        modifier(ReadingSearchModifier(text: text, isPresented: isPresented, prompt: prompt))
    }

    @ViewBuilder
    func readingListTopMargin(_ margin: CGFloat) -> some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            contentMargins(.top, margin, for: .scrollContent)
        } else {
            self
        }
    }
}

private struct ReadingSearchModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !ReadingCompatibility.usesLegacyUI {
            content.searchable(text: $text, isPresented: $isPresented, prompt: prompt)
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField(prompt, text: $text)
                                .focused($isFocused)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.search)
                            if !text.isEmpty {
                                Button {
                                    text = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("清除搜索")
                            }
                        }
                        .padding(10)
                        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 10))
                        if isFocused {
                            Button("取消") {
                                text = ""
                                isFocused = false
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ReadingTheme.canvas)
                }
                .onAppear { isFocused = isPresented }
                .onChange(of: isPresented) { isFocused = $0 }
                .onChange(of: isFocused) { isPresented = $0 }
        }
    }
}

enum ReadingTheme {
    static let accent = adaptive(0x171717, dark: 0xDADAE0)
    static let accentFill = adaptive(0x171717, dark: 0x414148)
    static let emphasisSurface = adaptive(0x171717, dark: 0x29292E)
    static let selectionBorder = adaptive(0x171717, dark: 0x777780)
    static let toggleTint = Color(uiColor: .systemGreen)
    static let accentSoft = adaptive(0xEEEEEF, dark: 0x29292C)
    static let coral = Color(red: 0.76, green: 0.48, blue: 0.27)
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.895)
    static let ink = Color.primary
    static let canvas = adaptive(0xFCFCFC, dark: 0x111113)
    static let groupedCanvas = adaptive(0xF3F3F4, dark: 0x1C1C1F)
    static let surface = adaptive(0xFFFFFF, dark: 0x232326)
    static let separator = adaptive(0xE6E6E8, dark: 0x363639)
    static let onAccent = Color.white

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

struct ReadingPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    var artwork: ReadingHeaderArtwork? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(ReadingTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HStack(spacing: 10) { actions }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .background(alignment: .bottomTrailing) {
            if let artwork {
                artwork.aspectRatio(220.0 / 72, contentMode: .fit)
                    .frame(width: artwork == .websites ? 172 : 220)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }
}

enum ReadingHeaderArtwork: View {
    case bookshelf, websites, profile

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 220, y: size.height / 72)
            let paper = GraphicsContext.Shading.color(ReadingTheme.groupedCanvas)
            let edge = GraphicsContext.Shading.color(ReadingTheme.separator.opacity(0.75))
            switch self {
            case .bookshelf:
                // A shallow open spread with a second leaf showing under the fore edge.
                var spread = Path()
                spread.move(to: CGPoint(x: 4, y: 50))
                spread.addQuadCurve(to: CGPoint(x: 64, y: 34), control: CGPoint(x: 39, y: 48))
                spread.addQuadCurve(to: CGPoint(x: 112, y: 52), control: CGPoint(x: 94, y: 33))
                spread.addQuadCurve(to: CGPoint(x: 199, y: 15), control: CGPoint(x: 139, y: 22))
                spread.addLine(to: CGPoint(x: 216, y: 35))
                spread.addQuadCurve(to: CGPoint(x: 116, y: 66), control: CGPoint(x: 157, y: 41))
                spread.addQuadCurve(to: CGPoint(x: 4, y: 50), control: CGPoint(x: 69, y: 46))
                spread.closeSubpath()
                context.fill(spread.offsetBy(dx: 0, dy: 5), with: edge)
                context.fill(spread, with: paper)
                var fold = Path()
                fold.move(to: CGPoint(x: 112, y: 52))
                fold.addQuadCurve(to: CGPoint(x: 116, y: 65), control: CGPoint(x: 115, y: 59))
                context.stroke(fold, with: edge, lineWidth: 1.5)
            case .profile:
                // A closed journal with a ribbon peeking out between the pages.
                var cover = Path()
                cover.move(to: CGPoint(x: 82, y: 40))
                cover.addLine(to: CGPoint(x: 163, y: 12))
                cover.addQuadCurve(to: CGPoint(x: 168, y: 12), control: CGPoint(x: 166, y: 11))
                cover.addLine(to: CGPoint(x: 208, y: 32))
                cover.addLine(to: CGPoint(x: 121, y: 64))
                cover.addLine(to: CGPoint(x: 82, y: 45))
                cover.addQuadCurve(to: CGPoint(x: 82, y: 40), control: CGPoint(x: 78, y: 42))
                cover.closeSubpath()
                context.fill(cover.offsetBy(dx: 0, dy: 4), with: edge)
                context.fill(cover, with: paper)

                var ribbon = Path()
                ribbon.move(to: CGPoint(x: 149, y: 54))
                ribbon.addLine(to: CGPoint(x: 160, y: 50))
                ribbon.addLine(to: CGPoint(x: 175, y: 58))
                ribbon.addLine(to: CGPoint(x: 167, y: 59))
                ribbon.addLine(to: CGPoint(x: 164, y: 62))
                ribbon.closeSubpath()
                context.fill(ribbon, with: .color(ReadingTheme.ink.opacity(0.13)))
            case .websites:
                // Three outward sweeps share the rounded ends of a printed RSS mark.
                let origin = CGPoint(x: 68, y: 64)
                context.fill(Path(ellipseIn: CGRect(x: origin.x - 5, y: origin.y - 5, width: 10, height: 10)), with: edge)
                for (index, reach) in [40.0, 84.0, 132.0].enumerated() {
                    var signal = Path()
                    signal.move(to: CGPoint(x: origin.x + reach * 0.10, y: origin.y - reach * 0.43))
                    signal.addQuadCurve(to: CGPoint(x: origin.x + reach, y: origin.y),
                                        control: CGPoint(x: origin.x + reach * 0.67, y: origin.y - reach * 0.48))
                    context.stroke(signal, with: index == 0 ? edge : paper,
                                   style: StrokeStyle(lineWidth: 6 + CGFloat(index) * 2, lineCap: .round))
                }
            }
        }
    }
}

struct ReadingToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(ReadingTheme.accent)
            .frame(width: 44, height: 44)
            .background(ReadingTheme.groupedCanvas, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SourceGroupPicker: View {
    let groups: [String]
    @Binding var selection: String?

    var body: some View {
        Picker("分组", selection: $selection) {
            Text("全部").tag(String?.none)
            Text("未分组").tag(String?.some(""))
            ForEach(groups, id: \.self) { group in
                Text(group).tag(String?.some(group))
            }
        }
    }
}

struct SourceManagementRow: View {
    let name: String
    let url: String
    let groups: [String]
    let enabled: Bool
    var showsToggle = true
    let onEnabledChanged: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: enabled ? "network" : "network.slash")
                .font(.system(size: 20))
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(enabled ? Color.primary : .secondary)
                Text(groups.isEmpty ? (URL(string: url)?.host ?? url) : groups.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if showsToggle {
                Toggle("启用", isOn: Binding(
                    get: { enabled },
                    set: { enabled in
                        Task { @MainActor in onEnabledChanged(enabled) }
                    }
                ))
                .labelsHidden()
                .tint(.green)
                .accessibilityLabel("启用\(name)")
            }
        }
        .padding(.vertical, 5)
    }
}

struct SourceBrowseRow<Icon: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var icon: Icon
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 16) {
            icon
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [ReadingTheme.groupedCanvas.opacity(0.65), ReadingTheme.groupedCanvas.opacity(0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: nameSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ReadingTheme.ink.opacity(0.55))
                .padding(.trailing, 4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ReadingTheme.surface)
                .shadow(color: .black.opacity(0.035), radius: 12, y: 6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

enum BookReadingPresentation {
    static func hasStarted(_ book: Book) -> Bool {
        book.durChapterIndex > 0 || book.durChapterPos > 0 || book.durChapterTime > 0
    }

    static func progress(_ book: Book) -> Double {
        guard hasStarted(book), book.totalChapterNum > 0 else { return 0 }
        return min(1, max(0, Double(book.durChapterIndex + 1) / Double(book.totalChapterNum)))
    }

    static func position(_ book: Book) -> String {
        if let title = book.durChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        guard hasStarted(book) else { return "尚未阅读" }
        return book.totalChapterNum > 0
            ? "第\(book.durChapterIndex + 1)章 · 共\(book.totalChapterNum)章"
            : "已读至第\(book.durChapterIndex + 1)章"
    }

    static func progressLabel(_ book: Book) -> String {
        guard hasStarted(book) else { return "尚未阅读" }
        guard book.totalChapterNum > 0 else { return "已开始阅读" }
        return "已读\(Int((progress(book) * 100).rounded()))%"
    }
}

struct ReadingProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(ReadingTheme.separator)
                .overlay(alignment: .leading) {
                    Capsule().fill(ReadingTheme.accent)
                        .frame(width: geometry.size.width * min(1, max(0, value)))
                }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

struct BookCoverArtwork: View {
    let title: String
    var author: String = ""
    var remoteURL: String?
    var width: CGFloat = 68
    var height: CGFloat = 96
    var allowsPreview = false
    @State private var showsPreview = false
    @State private var loadedCover: (url: URL, photo: PreviewPhoto)?

    private var coverStyle: Int {
        switch title {
        case "长夜里的灯": 0
        case "群星沉默时": 1
        case "山海入梦来": 2
        default: title.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 3 }
        }
    }

    private var coverColor: Color {
        switch coverStyle {
        case 1: Color(red: 0.22, green: 0.35, blue: 0.44)
        case 2: Color(red: 0.71, green: 0.44, blue: 0.34)
        default: Color(red: 0.14, green: 0.15, blue: 0.16)
        }
    }

    var body: some View {
        if allowsPreview, let url = remoteURL.flatMap(URL.init(string:)) {
            Group {
                if let loadedCover, loadedCover.url == url {
                    Button { showsPreview = true } label: {
                        artwork(Image(uiImage: loadedCover.photo.image).resizable().scaledToFill())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看封面")
                    .fullScreenCover(isPresented: $showsPreview) {
                        PhotoViewer(imageLabel: title) { _ in loadedCover.photo }
                    }
                } else {
                    artwork(placeholder)
                }
            }
            .task(id: url) {
                guard loadedCover?.url != url else { return }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    try Task.checkCancellation()
                    loadedCover = (url, try PreviewPhoto(data: data))
                } catch {
                    if !Task.isCancelled { loadedCover = nil }
                }
            }
        } else if let remoteURL, remoteURL.hasPrefix("data:image/"),
           let comma = remoteURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(remoteURL[remoteURL.index(after: comma)...])),
           let image = UIImage(data: data) {
            artwork(Image(uiImage: image).resizable().scaledToFill())
        } else {
            AsyncImage(url: remoteURL.flatMap(URL.init(string:))) { phase in
                if case .success(let image) = phase {
                    artwork(image.resizable().scaledToFill())
                } else {
                    artwork(placeholder)
                }
            }
        }
    }

    private func artwork(_ content: some View) -> some View {
        content
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.15)).frame(width: max(2, width * 0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack(alignment: .topLeading) {
            coverColor
            Canvas { context, size in
                drawArtwork(context: context, size: size)
            }
            VStack(alignment: .leading, spacing: width * 0.10) {
                Text(coverStyle == 0 ? title.map(String.init).joined(separator: "\n") : title)
                    .font(.system(size: max(9, width * (coverStyle == 0 ? 0.16 : 0.18)), weight: .medium, design: .serif))
                    .lineLimit(coverStyle == 0 ? 7 : 4)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: coverStyle == 0 ? width * 0.32 : .infinity, alignment: .leading)
                if !author.isEmpty, width >= 50 {
                    Text(author)
                        .font(.system(size: max(7, width * 0.09)))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.94))
            .padding(width * 0.15)
            .padding(.top, coverStyle == 1 ? height * 0.33 : 0)
        }
    }

    private func drawArtwork(context: GraphicsContext, size: CGSize) {
        if coverStyle == 0 {
            let moon = CGRect(x: size.width * 0.68, y: size.height * 0.18, width: size.width * 0.17, height: size.width * 0.17)
            context.fill(Path(ellipseIn: moon), with: .color(Color(red: 0.89, green: 0.87, blue: 0.81)))
        } else if coverStyle == 1 {
            let normalizedPoints: [CGPoint] = [
                .init(x: 0.12, y: 0.19), .init(x: 0.39, y: 0.11), .init(x: 0.62, y: 0.22),
                .init(x: 0.88, y: 0.13), .init(x: 0.76, y: 0.42), .init(x: 0.33, y: 0.48)
            ]
            let points = normalizedPoints.map { point in
                CGPoint(x: point.x * size.width, y: point.y * size.height)
            }
            var constellation = Path()
            constellation.addLines(points)
            context.stroke(constellation, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
            for point in points {
                context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.7)))
            }
        } else {
            let arch = CGRect(x: size.width * 0.28, y: size.height * 0.40, width: size.width * 0.58, height: size.height * 0.48)
            context.fill(Path(roundedRect: arch, cornerRadius: size.width * 0.29), with: .color(.white.opacity(0.25)))
        }
        for index in 0..<3 {
            var horizon = Path()
            let baseline = size.height * (0.78 + CGFloat(index) * 0.065)
            horizon.move(to: CGPoint(x: 0, y: baseline))
            horizon.addCurve(
                to: CGPoint(x: size.width, y: baseline + 8),
                control1: CGPoint(x: size.width * 0.3, y: baseline + 18),
                control2: CGPoint(x: size.width * 0.6, y: baseline - 20)
            )
            context.stroke(horizon, with: .color(.white.opacity(0.17)), lineWidth: 0.7)
        }

    }
}

struct ReadingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = ReadingTheme.accent
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }
}

/// A persistent search field for management pages, including their empty states.
struct ReadingPillSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .regular))
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
                .frame(minWidth: 28, minHeight: 28)
            }
        }
        .foregroundStyle(ReadingTheme.ink)
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .background(ReadingTheme.accentSoft, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

struct ReadingIllustratedEmptyState<Actions: View>: View {
    let artwork: String
    let title: String
    let message: String
    var bottomBalance: CGFloat = 88
    @ViewBuilder var actions: Actions

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Image(artwork)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 164, height: 128)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(ReadingTheme.ink)
                        .padding(.top, 16)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, bottomBalance + 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .readingScrollDismissesKeyboard()
        }
    }
}

struct ReadingSoftCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(ReadingTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ReadingTheme.separator.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.045), radius: 12, x: 0, y: 5)
    }
}
