import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookshelfReadViewModel: ObservableObject {
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var resolvedBook: Book?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    func load(book: Book, source: BookSource?, library: BookLibraryModel) async {
        guard chapters.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if book.origin == "local" {
            do {
                let loaded = try await library.localReadingChapters(for: book)
                try Task.checkCancellation()
                guard !loaded.isEmpty else { throw LocalBookError.emptyFile }
                chapters = loaded
                resolvedBook = book
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let stored = await library.updateCoordinator.storedChapters(bookURL: book.bookUrl)
        if let restored = Self.restoredBook(book, chapters: stored) {
            chapters = stored
            resolvedBook = restored
            return
        }
        guard let source else {
            errorMessage = "目录与阅读进度不一致，且当前书籍的书源不存在。请先恢复或更换书源。"
            return
        }
        let report = await library.updateCoordinator.refresh(book: book, source: source, persistDirectory: false)
        if report.refreshed, Self.matchesReadingProgress(report.book, chapters: report.chapters) {
            if !(await library.commitPreparedUpdate(requestedBook: book, report: report)) {
                errorMessage = "更新后的书籍保存失败，已保留原书籍和阅读位置。"
                return
            }
            chapters = report.chapters
            resolvedBook = report.book
        } else {
            errorMessage = report.diagnostics.first?.message ?? "目录刷新后仍与阅读进度不一致，请稍后重试。"
        }
    }

    static func restoredBook(_ book: Book, chapters: [BookChapter]) -> Book? {
        if matchesReadingProgress(book, chapters: chapters) { return book }
        guard let title = book.durChapterTitle, !title.isEmpty else { return nil }
        let matches = chapters.indices.filter { !chapters[$0].isVolume && chapters[$0].title == title }
        guard matches.count == 1, let index = matches.first else { return nil }
        var restored = book
        restored.durChapterIndex = index
        restored.totalChapterNum = chapters.count
        return restored
    }

    static func matchesReadingProgress(_ book: Book, chapters: [BookChapter]) -> Bool {
        guard chapters.indices.contains(book.durChapterIndex) else { return false }
        if let title = book.durChapterTitle, !title.isEmpty {
            return chapters[book.durChapterIndex].title == title
        }
        return book.totalChapterNum == 0 || book.totalChapterNum == chapters.count
    }
}
