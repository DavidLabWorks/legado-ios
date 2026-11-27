import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SourceExportDocument<Source: Codable & Sendable>: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let sources: [Source]

    init(sources: [Source]) { self.sources = sources }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        sources = try JSONDecoder().decode([Source].self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return FileWrapper(regularFileWithContents: try encoder.encode(sources))
    }
}

func sourceExportFilename(_ name: String?, fallback: String) -> String {
    let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
    let filename = (name ?? "").components(separatedBy: separators).joined(separator: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return filename.isEmpty ? fallback : filename
}

enum ReadingCompatibility {
    static var usesLegacyUI: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiLegacyCompatibility")
        #else
        false
        #endif
    }
}

struct ReadingNavigationStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            NavigationStack { content }
        } else {
            NavigationView { content }.navigationViewStyle(.stack)
        }
    }
}

struct ReadingLabeledContent<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            LabeledContent(title) { content }
        } else {
            HStack {
                Text(title)
                Spacer()
                content.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }
}

extension ReadingLabeledContent where Content == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value) }
    }
}

struct ReadingTextField: View {
    let title: String
    @Binding var text: String
    var axis: Axis

    init(_ title: String, text: Binding<String>, axis: Axis) {
        self.title = title
        _text = text
        self.axis = axis
    }

    var body: some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            TextField(title, text: $text, axis: axis)
        } else if axis == .vertical {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 80).accessibilityLabel(title)
            }
        } else {
            TextField(title, text: $text)
        }
    }
}

struct ReadingShareLink<Label: View>: View {
    private let items: [Any]
    private let label: Label

    init(item: String, @ViewBuilder label: () -> Label) {
        items = [item]
        self.label = label()
    }

    init(item: URL, @ViewBuilder label: () -> Label) {
        items = [item]
        self.label = label()
    }

    var body: some View {
        Button { presentShareSheet() } label: { label }
    }

    private func presentShareSheet() {
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !(presenter is UIActivityViewController) else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}

extension ReadingShareLink where Label == SwiftUI.Label<Text, Image> {
    init(item: URL) {
        self.init(item: item) { SwiftUI.Label("分享", systemImage: "square.and.arrow.up") }
    }
}

struct ReadingPhotoPicker<Label: View>: View {
    let onData: (Data) -> Void
    let onError: (Error) -> Void
    @ViewBuilder var label: Label
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: { label }
            .readingPhotoPicker(isPresented: $isPresented, onData: onData, onError: onError)
    }
}

private struct ReadingPhotoPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onData: (Data) -> Void
    let onError: (Error) -> Void
    @State private var pendingResult: Result<Data, Error>?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            let result = pendingResult
            pendingResult = nil
            switch result {
            case .success(let data): onData(data)
            case .failure(let error): onError(error)
            case nil: break
            }
        }) {
            ReadingPhotoPickerController { result in
                // Apply changes after the picker finishes dismissing, so a
                // Form update cannot remove its presenter mid-transition.
                pendingResult = result
                isPresented = false
            }
        }
    }
}

struct ReadingPhotoPickerController: UIViewControllerRepresentable {
    let onResult: @MainActor (Result<Data, Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: @MainActor (Result<Data, Error>?) -> Void

        init(onResult: @escaping @MainActor (Result<Data, Error>?) -> Void) {
            self.onResult = onResult
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { onResult(nil); return }
            loadImage(from: provider)
        }

        func loadImage(from provider: NSItemProvider) {
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier
            provider.loadDataRepresentation(forTypeIdentifier: identifier, completionHandler: didLoadImageData)
        }

        // Photos calls back on NSItemProvider-callback-queue. A method reference
        // preserves explicit nonisolation in optimized device builds, whereas a
        // closure here can infer MainActor and assert before reaching the Task.
        nonisolated private func didLoadImageData(_ data: Data?, _ error: (any Error)?) {
            let result: Result<Data, Error>
            if let data { result = .success(data) }
            else { result = .failure(error ?? CocoaError(.fileReadCorruptFile)) }
            Task { @MainActor [weak self] in
                self?.onResult(result)
            }
        }
    }
}

private struct ReadingLocalBookFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onFiles: ([LocalBookImportFile]) -> Void
    let onError: (Error) -> Void
    @State private var pickedFiles: [LocalBookImportFile] = []
    @State private var pickerHasDismissed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            pickerHasDismissed = true
            deliverFilesWhenReady()
        }) {
            let epub = UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")
            ReadingImportPicker(contentTypes: [.plainText, epub], allowsMultipleSelection: true) { urls in
                pickedFiles = urls.map { LocalBookImportFile(url: $0) }
                isPresented = false
                deliverFilesWhenReady()
            } onCancel: {
                pickedFiles = []
                isPresented = false
            }
            .onAppear {
                pickedFiles = []
                pickerHasDismissed = false
            }
        }
    }

    private func deliverFilesWhenReady() {
        // Providers may return their copies before or after dismissing Files.
        guard pickerHasDismissed, !pickedFiles.isEmpty else { return }
        let files = pickedFiles
        pickedFiles = []
        guard files.allSatisfy({ LocalBookService.supports($0.url) && !$0.url.hasDirectoryPath }) else {
            onError(LocalBookError.unsupportedFormat)
            return
        }
        onFiles(files)
    }
}

struct JSONImportPicker: ViewModifier {
    @Binding var isPresented: Bool
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var pickedFiles: [SourceImportFile] = []
    @State private var pickerHasDismissed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            pickerHasDismissed = true
            previewWhenReady()
        }) {
            // File providers may label JSON as generic data or support copying only.
            // Multiple selection also gives Files an explicit Open button.
            ReadingImportPicker(contentTypes: [.item], allowsMultipleSelection: true) { urls in
                pickedFiles = urls.map(SourceImportFile.init)
                isPresented = false
                previewWhenReady()
            } onCancel: {
                isPresented = false
            }
            .onAppear { pickerHasDismissed = false }
        }
    }

    private func previewWhenReady() {
        // Providers can finish copying before or after the picker dismisses.
        guard pickerHasDismissed, !pickedFiles.isEmpty else { return }
        let files = pickedFiles
        pickedFiles = []
        Task { await library.previewPickedFiles(files) }
    }
}

struct ReadingImportPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onPick: @MainActor ([URL]) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ReadingImportPicker

        init(parent: ReadingImportPicker) { self.parent = parent }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
    }
}

enum ReadingSheetDetent { case medium, large }

extension View {
    func readingLocalBookFileImporter(
        isPresented: Binding<Bool>,
        onFiles: @escaping ([LocalBookImportFile]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> some View {
        modifier(ReadingLocalBookFileImporterModifier(isPresented: isPresented, onFiles: onFiles, onError: onError))
    }

    func readingPhotoPicker(
        isPresented: Binding<Bool>,
        onData: @escaping (Data) -> Void,
        onError: @escaping (Error) -> Void
    ) -> some View {
        modifier(ReadingPhotoPickerModifier(isPresented: isPresented, onData: onData, onError: onError))
    }

    @ViewBuilder
    func readingNumericTransition() -> some View {
        if #available(iOS 16.0, *) { contentTransition(.numericText()) }
        else { self }
    }

    @ViewBuilder
    func readingNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>, @ViewBuilder destination: () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(NavigationLink(isActive: isPresented, destination: destination) { EmptyView() }.hidden())
        }
    }

    @ViewBuilder
    func readingScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            scrollContentBackground(.hidden)
        } else {
            background(ReadingUIKitConfiguration { controller in
                func clearTables(in view: UIView) {
                    if let table = view as? UITableView { table.backgroundColor = .clear }
                    for child in view.subviews { clearTables(in: child) }
                }
                if let parent = controller.parent { clearTables(in: parent.view) }
            })
        }
    }

    @ViewBuilder
    func readingScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            scrollDismissesKeyboard(.immediately)
        } else {
            simultaneousGesture(DragGesture().onChanged { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
        }
    }

    @ViewBuilder
    func readingTabBarBackground() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            toolbarBackground(ReadingTheme.canvas, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
        } else {
            background(ReadingUIKitConfiguration { controller in
                let appearance = UITabBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor(ReadingTheme.canvas)
                controller.tabBarController?.tabBar.standardAppearance = appearance
                controller.tabBarController?.tabBar.scrollEdgeAppearance = appearance
            })
        }
    }

    @ViewBuilder
    func readingTabBarHidden(_ hidden: Bool = true) -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            toolbar(hidden ? .hidden : .automatic, for: .tabBar)
        } else {
            background { if hidden { ReadingHiddenTabBar() } }
        }
    }

    @ViewBuilder
    func readingHomeIndicatorHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }

    @ViewBuilder
    func readingSheetSurface() -> some View {
        let page = background(ReadingTheme.sheetBackground.ignoresSafeArea())
        if #available(iOS 16, *) {
            let opaqueBar = page
                .toolbarBackground(ReadingTheme.sheetBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
            if #available(iOS 16.4, *) {
                opaqueBar.presentationBackground(ReadingTheme.sheetBackground)
            } else {
                opaqueBar
            }
        } else {
            page
        }
    }

    @ViewBuilder
    func readingPresentationDetents(_ detents: [ReadingSheetDetent]) -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            presentationDetents(Set(detents.map { $0 == .medium ? PresentationDetent.medium : .large }))
        } else {
            background(ReadingUIKitConfiguration { controller in
                var current: UIViewController? = controller
                while let candidate = current {
                    if let sheet = candidate.presentationController as? UISheetPresentationController {
                        sheet.detents = detents.map { $0 == .medium ? .medium() : .large() }
                        break
                    }
                    current = candidate.parent
                }
            })
        }
    }

    @ViewBuilder
    func readingPresentationDragIndicator() -> some View {
        if #available(iOS 16.0, *), !ReadingCompatibility.usesLegacyUI {
            presentationDragIndicator(.visible)
        } else {
            background(ReadingUIKitConfiguration { controller in
                var current: UIViewController? = controller
                while let candidate = current {
                    if let sheet = candidate.presentationController as? UISheetPresentationController {
                        if !sheet.prefersGrabberVisible { sheet.prefersGrabberVisible = true }
                        break
                    }
                    current = candidate.parent
                }
            })
        }
    }
}

private struct ReadingUIKitConfiguration: UIViewControllerRepresentable {
    let configure: (UIViewController) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(configure: configure) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.configure = configure }

    final class Controller: UIViewController {
        var configure: (UIViewController) -> Void

        init(configure: @escaping (UIViewController) -> Void) {
            self.configure = configure
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); configure(self) }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); configure(self) }
    }
}

private struct ReadingHiddenTabBar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var tabs: UITabBarController?
        private var previouslyHidden: Bool?

        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let tabs = tabBarController else { return }
            self.tabs = tabs
            if previouslyHidden == nil { previouslyHidden = tabs.tabBar.isHidden }
            tabs.tabBar.isHidden = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard previouslyHidden == false, let tabs else { return }
            if let root = navigationController?.viewControllers.first, let transition = transitionCoordinator,
               transition.isAnimated, transition.viewController(forKey: .to) === root {
                transition.animate(alongsideTransition: nil) { context in
                    if !context.isCancelled && tabs.tabBar.isHidden { tabs.showReadingTabBar(animated: true) }
                }
            } else {
                tabs.tabBar.isHidden = false
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            previouslyHidden = nil
        }
    }
}

struct HomeTabBar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var wasHidden = false

        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            wasHidden = tabBarController?.readingTabBarIsHidden == true
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let tabs = tabBarController else { return }
            if wasHidden || tabs.readingTabBarIsHidden { tabs.showReadingTabBar(animated: animated) }
            updatePlayerBoundary()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updatePlayerBoundary()
        }

        private func updatePlayerBoundary() {
            guard let bar = tabBarController?.tabBar, let scene = view.window?.windowScene else { return }
            scene.windows.compactMap { $0 as? ListeningPlayerWindow }.first?.useTabBar(bar)
        }
    }
}

private extension UITabBarController {
    var readingTabBarIsHidden: Bool {
        if #available(iOS 18, *), !ReadingCompatibility.usesLegacyUI { return isTabBarHidden }
        return tabBar.isHidden
    }

    func showReadingTabBar(animated: Bool) {
        if #available(iOS 18, *), !ReadingCompatibility.usesLegacyUI {
            setTabBarHidden(false, animated: false)
        } else {
            tabBar.isHidden = false
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled,
              UserDefaults.standard.string(forKey: "themeMode") != "3" else { return }
        view.layoutIfNeeded()
        let distance = view.bounds.maxY - tabBar.convert(tabBar.bounds, to: view).minY
        // Animate only the presentation layer so the system retains the bar's final layout.
        let slide = CABasicAnimation(keyPath: "position.y")
        slide.isAdditive = true
        slide.fromValue = max(tabBar.bounds.height, distance)
        slide.toValue = 0
        slide.duration = 0.24
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tabBar.layer.add(slide, forKey: "homeTabBarReveal")
    }
}
