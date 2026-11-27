import SwiftUI

struct RSSAddBookView: View {
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @Environment(\.dismiss) private var dismiss
    let bookURL: String
    @State private var detail: (book: Book, source: BookSource)?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let detail {
                BookDetailView(book: detail.book, source: detail.source, close: { dismiss() })
            } else {
                Group {
                    if let errorMessage {
                        ReadingUnavailableView("无法添加书籍", systemImage: "doc.badge.ellipsis", description: Text(errorMessage))
                    } else {
                        VStack(spacing: 14) {
                            RagdollLoading("正在匹配书源并解析详情…")
                            Text(bookURL).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                        }.padding()
                    }
                }
                .readingSheetTitle("添加到书架")
                .toolbar { ReadingSheetActions { ReadingSheetCloseButton { dismiss() } } }
            }
        }
        .task(id: bookURL) { await load() }
    }

    private func load() async {
        if let book = books.books.first(where: { $0.bookUrl == bookURL }),
           let source = sources.sources.first(where: { $0.bookSourceUrl == book.origin }) {
            detail = (book, source)
            return
        }
        do {
            let result = try await AddBookURLService().resolve(bookURL: bookURL, sources: sources.sources)
            detail = (result.book, result.source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
