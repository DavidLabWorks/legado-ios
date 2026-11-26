import SwiftUI

@MainActor
final class LocalBookDetailViewModel: ObservableObject {
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var loadedBook: Book?
    private var generation = 0

    func load(book: Book, library: BookLibraryModel) async {
        guard loadedBook != book else { return }
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let loaded = try await library.localReadingChapters(for: book)
            guard generation == request, !Task.isCancelled else { return }
            chapters = loaded
            loadedBook = book
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct LocalBookDetailView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @StateObject private var model = LocalBookDetailViewModel()
    @State private var showsTocRule = false

    private var currentBook: Book { library.books.first { $0.bookUrl == book.bookUrl } ?? book }

    var body: some View {
        let book = currentBook
        List {
            VStack(spacing: 16) {
                VStack(spacing: 14) {
                    BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverURL, width: 108, height: 154, allowsPreview: true)
                    Text(book.name).font(.title2.bold())
                    if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary) }
                    HStack {
                        StatusPill(text: "本地 " + (URL(string: book.bookUrl)?.pathExtension.uppercased() ?? "TXT"), systemImage: "doc.text.fill")
                        if let charset = book.charset { StatusPill(text: charset, color: ReadingTheme.coral, systemImage: "character") }
                    }
                    Text(book.originName).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 12)

                if let intro = book.intro, !intro.isEmpty {
                    ReadingCard { Text(intro).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            if model.isLoading {
                HStack { Spacer(); ProgressView("正在识别章节…"); Spacer() }.padding(.vertical, 28)
            } else if let error = model.errorMessage {
                ReadingUnavailableView("无法读取本地书", systemImage: "doc.badge.ellipsis", description: Text(error))
            } else {
                BookDetailChapterRows(book: book, chapters: model.chapters)
            }
        }
        .listStyle(.plain)
        .readingScrollContentBackgroundHidden()
        .background(ReadingTheme.canvas)
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if URL(string: book.bookUrl)?.pathExtension.lowercased() == "txt" {
                        Button("重新分章", systemImage: "list.bullet.indent") { showsTocRule = true }
                    }
                    Button("移出书架", systemImage: "trash", role: .destructive) {
                        Task {
                            await library.remove(bookURL: book.bookUrl)
                            if !library.contains(book) { dismiss() }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("本地书操作")
            }
        }
        .task(id: book) { await model.load(book: book, library: library) }
        .sheet(isPresented: $showsTocRule) { LocalBookTocRuleView(book: book) }
    }
}

private struct LocalBookTocRuleView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var rules: [TxtTocRule] = []
    @State private var selection = "current"
    @State private var splitLongChapter = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var selectedRule: TxtTocRule? {
        switch selection {
        case "automatic": return nil
        case "none": return TxtTocRule(name: "不识别章节标题", rule: "")
        case "current":
            guard !book.tocUrl.isEmpty else { return nil }
            let pieces = book.tocUrl.components(separatedBy: TxtTocRuleSelector.separator)
            return TxtTocRule(name: "当前规则", rule: pieces[0],
                              replacement: pieces.dropFirst().joined(separator: TxtTocRuleSelector.separator))
        default: return rules.first { String($0.id) == selection }
        }
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section("目录规则") {
                    if !book.tocUrl.isEmpty { choice("保留当前规则", value: "current") }
                    choice("自动识别", value: "automatic")
                    choice("不识别章节标题", value: "none")
                    ForEach(rules) { rule in choice(rule.name, value: String(rule.id)) }
                    if isLoading { ProgressView("正在读取规则…") }
                }
                Section {
                    Toggle("拆分超长章节", isOn: $splitLongChapter)
                } footer: {
                    Text("重新识别当前 TXT 文件的目录，并尽量保留阅读位置。原文件、书籍信息和书签保持不变。")
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .disabled(isSaving)
            .navigationTitle("重新分章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在重建…" : "重建目录") {
                        isSaving = true
                        errorMessage = nil
                        Task {
                            let succeeded = await library.rebuildLocalBook(bookURL: book.bookUrl, rule: selectedRule,
                                                                          splitLongChapter: splitLongChapter)
                            isSaving = false
                            if succeeded { dismiss() }
                            else { errorMessage = library.errorMessage ?? "目录未能重建，请重试。" }
                        }
                    }.disabled(isSaving || isLoading)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .task {
                splitLongChapter = book.readConfig?.splitLongChapter ?? true
                if book.tocUrl.isEmpty { selection = "automatic" }
                do { rules = try await library.localTocRules() }
                catch { errorMessage = error.localizedDescription }
                isLoading = false
            }
        }
    }

    private func choice(_ title: String, value: String) -> some View {
        Button { selection = value } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selection == value { Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent) }
            }
        }
        .accessibilityIdentifier("localTocRule." + value)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
