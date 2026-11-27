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
    func load(book: Book, source: BookSource?, library: BookLibraryModel, bookmark: Bookmark? = nil) async {
        guard chapters.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let missingChapter = "当前目录中找不到书签对应章节。"
        if book.origin == "local" {
            do {
                let loaded = try await library.localReadingChapters(for: book)
                try Task.checkCancellation()
                guard !loaded.isEmpty else { throw LocalBookError.emptyFile }
                if let bookmark {
                    guard let restored = Self.restoredBook(book, chapters: loaded, bookmark: bookmark) else {
                        errorMessage = missingChapter
                        return
                    }
                    resolvedBook = restored
                } else {
                    resolvedBook = book
                }
                chapters = loaded
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        if bookmark != nil, source == nil {
            errorMessage = "书源已删除或未启用。"
            return
        }
        let stored = await library.updateCoordinator.storedChapters(bookURL: book.bookUrl)
        if let restored = Self.restoredBook(book, chapters: stored, bookmark: bookmark) {
            chapters = stored
            resolvedBook = restored
            return
        }
        guard let source else {
            errorMessage = "目录与阅读进度不一致，且当前书籍的书源不存在。请先恢复或更换书源。"
            return
        }
        let report = await library.updateCoordinator.refresh(book: book, source: source, persistDirectory: false)
        if report.refreshed, let restored = Self.restoredBook(report.book, chapters: report.chapters, bookmark: bookmark) {
            if !(await library.commitPreparedUpdate(requestedBook: book, report: report)) {
                errorMessage = "更新后的书籍保存失败，已保留原书籍和阅读位置。"
                return
            }
            chapters = report.chapters
            resolvedBook = restored
        } else {
            errorMessage = report.diagnostics.first?.message ?? (bookmark == nil ? "目录刷新后仍与阅读进度不一致，请稍后重试。" : missingChapter)
        }
    }

    static func restoredBook(_ book: Book, chapters: [BookChapter], bookmark: Bookmark? = nil) -> Book? {
        if let bookmark {
            guard let index = bookmark.resolvedChapterIndex(in: chapters) else { return nil }
            var restored = book
            restored.durChapterIndex = index
            restored.durChapterTitle = chapters[index].title
            restored.durChapterPos = max(0, bookmark.chapterPosition)
            if restored.readConfig == nil, bookmark.epubLocation != nil { restored.readConfig = BookReadConfig() }
            restored.readConfig?.epubLocation = bookmark.epubLocation
            return restored
        }
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
