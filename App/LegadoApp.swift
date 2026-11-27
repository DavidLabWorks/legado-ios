import SwiftUI

@main
struct LegadoApp: App {
    @UIApplicationDelegateAdaptor(LegadoAppDelegate.self) private var appDelegate
    @StateObject private var sourceLibrary: SourceLibraryModel
    @StateObject private var bookLibrary: BookLibraryModel
    @StateObject private var replaceRuleLibrary: ReplaceRuleLibraryModel
    @StateObject private var readingActivity: ReadingActivityModel
    @StateObject private var rssLibrary: RSSLibraryModel
    @StateObject private var ruleSubscriptions: RuleSubscriptionModel

    @State private var sourcesLoaded = false
    @State private var readingSharedLink = false

    init() {
        UIRefreshControl.appearance().showsRagdoll = true
        if UserDefaults.standard.string(forKey: "systemTtsVoice") == "auto-mandarin" {
            UserDefaults.standard.removeObject(forKey: "systemTtsVoice")
        }
        // Earlier versions stored downloadable speech models and partial downloads here.
        Task.detached(priority: .utility) {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: support.appendingPathComponent("OfflineSpeech/v1"))
        }
        AppDiagnostics.shared.start()
        SourceWebViewExecutorRegistry.shared.register(WKSourceWebViewExecutor())
        SourceVerification.shared.register { source, image in
            try await SourceVerificationPresenter.shared.request(source: source, data: image)
        }
        let demo = ProcessInfo.processInfo.arguments.contains("-uiDemo")
        _sourceLibrary = StateObject(wrappedValue: demo
            ? SourceLibraryModel.demo(sources: DemoContent.sources)
            : SourceLibraryModel.live())
        _bookLibrary = StateObject(wrappedValue: demo
            ? BookLibraryModel.demo(books: DemoContent.books)
            : BookLibraryModel.live())
        _replaceRuleLibrary = StateObject(wrappedValue: demo
            ? ReplaceRuleLibraryModel.demo()
            : ReplaceRuleLibraryModel.live())
        _readingActivity = StateObject(wrappedValue: demo
            ? ReadingActivityModel.demo(bookmarks: DemoContent.bookmarks, records: DemoContent.readRecords)
            : ReadingActivityModel.live())
        var rssDatabaseURL = LegadoDatabase.defaultURL()
        #if DEBUG
        if demo, let path = ProcessInfo.processInfo.environment["LEGADO_UI_RSS_DATABASE"] {
            rssDatabaseURL = URL(fileURLWithPath: path)
        }
        #endif
        _rssLibrary = StateObject(wrappedValue: RSSLibraryModel.live(databaseURL: rssDatabaseURL))
        _ruleSubscriptions = StateObject(wrappedValue: RuleSubscriptionModel())
    }

    var body: some Scene {
        WindowGroup {
            AppLockGate(handleURL: handleURL) { canOpen in
                let readyForShare = canOpen && sourcesLoaded && sourceLibrary.pendingImport == nil && sourceLibrary.notice == nil
                withAppModels(RootTabView())
                    .onAppear {
                        if readyForShare { Task { await previewNextSharedLink() } }
                    }
                    .onChange(of: readyForShare) { ready in
                        if ready { Task { await previewNextSharedLink() } }
                    }
                    .task {
                        await sourceLibrary.load()
                        sourcesLoaded = true
                        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiAutomationImportURL"),
                           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                           let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                            await sourceLibrary.handleDeepLink(url)
                            if ProcessInfo.processInfo.arguments.contains("-uiAutomation") {
                                sourceLibrary.notice = nil
                            }
                        }
                        await bookLibrary.loadInitialShelf()
                        await replaceRuleLibrary.load()
                        await readingActivity.load()
                        await rssLibrary.load()
                        await ruleSubscriptions.load()
                        if UserDefaults.standard.bool(forKey: "auto_refresh") {
                            await bookLibrary.checkForUpdates(sources: sourceLibrary.sources, onlyRead: UserDefaults.standard.bool(forKey: "onlyUpdateRead"))
                        }
                        await ruleSubscriptions.checkAutomaticUpdates(bookSources: sourceLibrary, rssSources: rssLibrary, replaceRules: replaceRuleLibrary)
                    }
            }
            .task {
                if UIApplication.shared.isProtectedDataAvailable {
                    await bookLibrary.loadInitialShelf()
                }
            }
        }
    }

    private func withAppModels<V: View>(_ view: V) -> some View {
        view
            .environmentObject(sourceLibrary)
            .environmentObject(bookLibrary)
            .environmentObject(replaceRuleLibrary)
            .environmentObject(readingActivity)
            .environmentObject(rssLibrary)
            .environmentObject(ruleSubscriptions)
    }

    @MainActor
    private func previewNextSharedLink() async {
        guard !readingSharedLink, sourceLibrary.pendingImport == nil, sourceLibrary.notice == nil else { return }
        readingSharedLink = true
        defer { readingSharedLink = false }
        do {
            guard let file = try SharedLinkInbox.nextFile() else { return }
            let preview: SourceLibraryModel.PendingImport
            do {
                let link = try String(contentsOf: file, encoding: .utf8)
                preview = try await sourceLibrary.preparePreview(link)
            } catch {
                guard sourceLibrary.pendingImport == nil, sourceLibrary.notice == nil else { return }
                try FileManager.default.removeItem(at: file)
                throw error
            }
            guard sourceLibrary.pendingImport == nil, sourceLibrary.notice == nil else { return }
            try FileManager.default.removeItem(at: file)
            sourceLibrary.pendingImport = preview
        } catch {
            sourceLibrary.notice = .init(kind: .error, title: "分享链接导入失败", detail: error.localizedDescription)
        }
    }

    private func handleURL(_ url: URL) {
        Task {
            if url.isFileURL && url.pathExtension.lowercased() == "epub" {
                let file = LocalBookImportFile(url: url)
                await bookLibrary.load()
                await bookLibrary.importPickedLocalFiles([file])
                sourceLibrary.notice = .init(kind: bookLibrary.errorMessage == nil ? .success : .error,
                                             title: bookLibrary.errorMessage == nil ? "EPUB 已加入书架" : "导入失败",
                                             detail: bookLibrary.errorMessage ?? url.lastPathComponent)
                return
            }
            await sourceLibrary.load()
            if RuleImportInput.isDeepLink(url, for: "replaceRule") {
                await replaceRuleLibrary.load()
                await replaceRuleLibrary.importText(url.absoluteString)
                if let notice = replaceRuleLibrary.notice {
                    sourceLibrary.notice = .init(kind: notice.kind == .error ? .error : .success, title: notice.title, detail: notice.detail)
                    replaceRuleLibrary.notice = nil
                }
            } else { await sourceLibrary.handleDeepLink(url) }
        }
    }
}

final class LegadoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderScreenOrientation.supportedOrientations
    }
}
