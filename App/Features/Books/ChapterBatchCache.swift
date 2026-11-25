import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class ChapterBatchCache: ObservableObject {
    static let shared = ChapterBatchCache()

    struct Progress {
        var total: Int
        var processed = 0
        var failed = 0
        var isActive = true

        var title: String {
            if isActive { return "正在缓存章节" }
            return failed == 0 ? "章节缓存完成" : "缓存结束，\(failed) 章失败"
        }
    }

    @Published private(set) var progress: [String: Progress]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?

    init(progress: [String: Progress] = [:]) { self.progress = progress }

    func start(book: Book, source: BookSource, jobs: [ChapterCacheJob], coordinator: ChapterContentCoordinator) {
        let url = book.bookUrl
        guard !jobs.isEmpty, tasks[url] == nil else { return }
        progress[url] = Progress(total: jobs.count)
        // Waiting for the preceding task also keeps cancelled, slow requests inside the global limit.
        let task = Task(priority: .utility) { [tail] in
            await tail?.value
            for job in jobs {
                guard !Task.isCancelled else { return }
                let result = await coordinator.load(book: book, chapter: job.chapter, source: source,
                                                    nextChapterURL: job.nextChapterURL)
                guard !Task.isCancelled else { return }
                if result.stamp == nil { progress[url]?.failed += 1 }
                progress[url]?.processed += 1
                if !result.loadedFromCache {
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                }
            }
            tasks[url] = nil
            progress[url]?.isActive = false
        }
        tail = task
        tasks[url] = task
    }

    func cancel(bookURL: String) {
        tasks.removeValue(forKey: bookURL)?.cancel()
        progress[bookURL] = nil
    }

    func clearForSourceSwitch(from oldURL: String, to newURL: String, cache: ChapterContentCache) async -> [RuleDiagnostic] {
        let urls: Set = [oldURL, newURL]
        for url in urls { cancel(bookURL: url) }
        var diagnostics: [RuleDiagnostic] = []
        for url in urls {
            do { try await cache.remove(bookURL: url) }
            catch { diagnostics.append(.init(severity: .warning, code: "cache.remove", message: error.localizedDescription, rule: url)) }
        }
        return diagnostics
    }
}
