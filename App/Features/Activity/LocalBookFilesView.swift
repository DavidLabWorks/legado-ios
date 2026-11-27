import SwiftUI

struct LocalBookFilesView: View {
    @EnvironmentObject private var library: BookLibraryModel
    @StateObject private var model = BookFileOperations()
    @State private var files: [LocalFileEntry]?
    @State private var loadError: String?
    @State private var query = ""
    @State private var sortBySize = false
    @State private var importsFile = false
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var renameURL: URL?
    @State private var newName = ""
    @State private var pendingDeletion: [URL] = []

    private var localBooks: [Book] { library.books.filter { $0.origin == "local" } }
    private var isEmpty: Bool { files?.isEmpty == true && localBooks.isEmpty && loadError == nil }

    private struct Item: Identifiable {
        let file: LocalFileEntry
        let book: Book?
        var id: URL { file.url }
        var name: String {
            if let book, !book.originName.isEmpty { return book.originName }
            return file.url.lastPathComponent
        }
    }

    private var displayedFiles: [Item] {
        let books = Dictionary(localBooks.map { ($0.bookUrl, $0) }, uniquingKeysWith: { first, _ in first })
        return (files ?? []).map { Item(file: $0, book: books[$0.url.absoluteString]) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted {
                if sortBySize, $0.file.bytes != $1.file.bytes { return $0.file.bytes > $1.file.bytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var missingBooks: [Book] {
        guard let files else { return [] }
        let available = Set(files.map(\.url.absoluteString))
        return localBooks.filter { !available.contains($0.bookUrl) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    private func reload() async {
        do {
            let entries = try await library.localFiles.list()
            guard !Task.isCancelled else { return }
            files = entries
            loadError = nil
            selection.formIntersection(entries.map(\.url))
            if entries.isEmpty { selecting = false }
        } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    }

    private var fileList: some View {
        Group {
            if isEmpty {
                ReadingIllustratedEmptyState(artwork: "BookshelfEmptyArtwork", title: "还没有本地书籍文件",
                                             message: "从系统“文件”选择 TXT 或 EPUB，即可加入书架。") {
                    Button { importsFile = true } label: {
                        Label("导入 TXT / EPUB", systemImage: "square.and.arrow.down").managementPrimaryAction()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)
                }
            } else {
                List(selection: $selection) {
                    if let loadError {
                        Text(loadError)
                        Button("重新读取") { Task { await reload() } }
                    } else if files != nil {
                        localFilesSection
                    } else {
                        RagdollLoading("正在读取文件…")
                    }
                }
                .readingManagementList()
                .safeAreaInset(edge: .top, spacing: 0) {
                    ReadingPillSearchField(placeholder: "搜索本地文件", text: $query, fill: ReadingTheme.surface)
                        .background(ReadingTheme.settingsCanvas)
                }
            }
        }
        .background(ReadingTheme.settingsCanvas)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .readingPageTitle("本地书籍文件")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button("完成") { selecting = false; selection.removeAll() }
                } else if !isEmpty, files != nil {
                    Button("导入 TXT / EPUB", systemImage: "square.and.arrow.down") { importsFile = true }
                    Menu {
                        Button("选择文件", systemImage: "checkmark.circle") { selecting = true }
                            .disabled(displayedFiles.isEmpty)
                        Picker("排序", selection: $sortBySize) {
                            Text("按名称").tag(false)
                            Text("按大小").tag(true)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("更多")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button(selection.count == displayedFiles.count ? "取消全选" : "全选") {
                        selection = selection.count == displayedFiles.count ? [] : Set(displayedFiles.map(\.id))
                    }
                    Spacer()
                    Button("删除 \(selection.count) 个文件", role: .destructive) { pendingDeletion = Array(selection) }
                        .disabled(selection.isEmpty)
                }
                .padding().background(.bar)
            }
        }
        .task(id: library.books) { await reload() }
        .refreshable { await reload() }
        .onChange(of: query) { _ in selection.removeAll() }
    }

    private var importAndRenameView: some View {
        fileList
        .readingLocalBookFileImporter(isPresented: $importsFile) { files in
            Task {
                await model.run {
                    await library.importPickedLocalFiles(files)
                    model.errorMessage = library.errorMessage
                    library.clearError()
                    await reload()
                }
            }
        } onError: { error in
            model.errorMessage = error.localizedDescription
        }
        .alert("重命名文件", isPresented: Binding(get: { renameURL != nil }, set: { if !$0 { renameURL = nil } }), presenting: renameURL) { url in
            TextField("文件名", text: $newName)
            Button("取消", role: .cancel) { renameURL = nil }
            Button("保存") {
                let name = newName
                renameURL = nil
                Task {
                    await model.run {
                        try await library.renameLocalFile(at: url, to: name)
                        await reload()
                    }
                }
            }
        } message: { _ in
            Text("保留原文件格式，书架中的书名、书签和阅读进度不变。")
        }
    }

    private var deletionView: some View {
        importAndRenameView
        .alert("删除 \(pendingDeletion.count) 个文件？", isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }), presenting: pendingDeletion) { urls in
            Button("删除文件并移出书架", role: .destructive) {
                pendingDeletion = []
                Task {
                    await model.run {
                        let names = Dictionary(uniqueKeysWithValues: displayedFiles.map { ($0.id, $0.name) })
                        var failures: [String] = []
                        for url in urls {
                            do { try await library.deleteLocalFile(at: url) }
                            catch { failures.append("\(names[url] ?? url.lastPathComponent)：\(error.localizedDescription)") }
                        }
                        await reload()
                        selection.removeAll()
                        if !failures.isEmpty { model.errorMessage = failures.joined(separator: "\n") }
                    }
                }
            }
            Button("取消", role: .cancel) { pendingDeletion = [] }
        } message: { _ in
            Text("将删除应用内文件及对应书架条目，系统“文件”中用于导入的原文件保留。")
        }
    }

    var body: some View {
        deletionView.modifier(BookFileOperationFeedback(model: model))
    }

    @ViewBuilder private var localFilesSection: some View {
        Section {
            if displayedFiles.isEmpty {
                if query.isEmpty {
                    ReadingUnavailableView("还没有本地文件", systemImage: "doc.text",
                                           description: Text("从系统“文件”导入 TXT 或 EPUB，即可离线阅读。"))
                } else {
                    ReadingUnavailableView.search(text: query)
                }
            }
            ForEach(displayedFiles) { item in
                Group {
                    if selecting { fileLabel(item) }
                    else if let book = item.book {
                        NavigationLink { BookshelfReadView(book: book, source: nil) } label: { fileLabel(item) }
                    } else {
                        Button { Task { await model.run { try await library.addLocalFile(at: item.id) } } } label: { fileLabel(item) }
                    }
                }
                .tag(item.id)
                .contextMenu {
                    Button("导出文件", systemImage: "square.and.arrow.up") { export(item) }
                    Button("重命名", systemImage: "pencil") { renameURL = item.id; newName = item.name }
                    Button("删除文件", systemImage: "trash", role: .destructive) { pendingDeletion = [item.id] }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { pendingDeletion = [item.id] }
                    Button("导出", systemImage: "square.and.arrow.up") { export(item) }.tint(.blue)
                }
            }
        } header: {
            let entries = files ?? []
            let totalBytes = entries.reduce(0) { $0 + $1.bytes }
            Text("共 \(entries.count) 个文件 · \(totalBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                .textCase(nil)
        }
        .listRowBackground(ReadingTheme.surface)
        if !missingBooks.isEmpty {
            Section("文件已丢失") {
                ForEach(missingBooks) { book in
                    HStack {
                        Label(book.name, systemImage: "doc.badge.ellipsis")
                        Spacer()
                        Button("移出书架", role: .destructive) {
                            Task {
                                await library.remove(bookURL: book.bookUrl)
                                model.errorMessage = library.errorMessage
                                library.clearError()
                            }
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func fileLabel(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.id.pathExtension.lowercased() == "epub" ? "book.closed" : "doc.text")
                .font(.title3)
                .frame(width: 40, height: 48)
                .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: item.file.bytes, countStyle: .file))
                    if let modified = item.file.modified { Text(modified, style: .date) }
                }.font(.caption).foregroundStyle(.secondary)
                if let book = item.book {
                    Text("书架：\(book.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else { Text("点按加入书架").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func export(_ item: Item) {
        Task {
            await model.run {
                let export = try await model.exporter.originalFile(item.id, filename: item.name)
                model.present(export)
            }
        }
    }
}
