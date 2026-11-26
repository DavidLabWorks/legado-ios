import SwiftUI
import WebKit
import ImageIO

struct BookCoverSearchView: View {
    let book: Book
    @EnvironmentObject private var library: BookLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: String?
    @State private var pendingSave: String?
    @State private var problem: String?

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                Text(problem ?? "长按图片，为《\(book.name)》设置封面。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                CoverImageBrowser(title: book.name) { image in
                    problem = nil
                    candidate = image
                } onError: { problem = $0 }
                .disabled(pendingSave != nil)
            }
            .overlay { if pendingSave != nil { ProgressView("正在保存封面…").padding().background(.regularMaterial) } }
            .navigationTitle("必应图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(pendingSave != nil) }
            }
            .alert("将这张图片设为《\(book.name)》的封面？", isPresented: Binding(
                get: { candidate != nil }, set: { if !$0 { candidate = nil } }
            ), presenting: candidate) { image in
                Button("设置封面") { pendingSave = image }
                Button("取消", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(pendingSave != nil)
        .task(id: pendingSave) {
            guard let pendingSave else { return }
            do {
                let data = try await BookCoverImage.imageData(for: pendingSave)
                try await library.setCover(for: book, imageData: data)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                problem = "封面保存失败：\(error.localizedDescription)"
            }
            self.pendingSave = nil
        }
    }

}

enum BookCoverImage {
    static func thumbnail(for address: String) async -> UIImage? {
        guard let data = try? await imageData(for: address), !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 512]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    static func imageData(for address: String) async throws -> Data {
        if address.hasPrefix("data:image/"), let comma = address.firstIndex(of: ","),
           let data = Data(base64Encoded: String(address[address.index(after: comma)...])) { return data }
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased()) else { throw URLError(.badURL) }
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }
}

private struct CoverImageBrowser: UIViewRepresentable {
    let title: String
    let onImage: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(browser: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let disableCallout = "document.documentElement.style.webkitTouchCallout = 'none'"
        configuration.userContentController.addUserScript(.init(source: disableCallout, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = false
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectImage(_:)))
        press.minimumPressDuration = 0.4
        press.delegate = context.coordinator
        web.addGestureRecognizer(press)
        var search = URLComponents(string: "https://www.bing.com/images/search")!
        search.queryItems = [URLQueryItem(name: "q", value: title)]
        search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let url = search.url { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
        let browser: CoverImageBrowser
        init(browser: CoverImageBrowser) { self.browser = browser }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func selectImage(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began, let web = press.view as? WKWebView,
                  web.bounds.width > 0, web.bounds.height > 0 else { return }
            let point = press.location(in: web)
            let args = ["x": point.x / web.bounds.width, "y": point.y / web.bounds.height]
            let page = web.url
            Task {
                do {
                    let result = try await web.callAsyncJavaScript(Self.imageAtPoint, arguments: args, in: nil, contentWorld: .defaultClient)
                    if web.window != nil, web.url == page, let address = result as? String { browser.onImage(address) }
                } catch {
                    if web.window != nil, web.url == page { browser.onError("没有读到这张图片，请打开大图后再长按。") }
                }
            }
        }

        private static let imageAtPoint = #"""
        const px = x * (window.visualViewport?.width || innerWidth);
        const py = y * (window.visualViewport?.height || innerHeight);
        const hits = document.elementsFromPoint(px, py);
        let image = hits.find(el => el instanceof HTMLImageElement);
        if (!image) {
            for (const el of hits) {
                const container = el.closest('a,button,[role="button"]');
                if (!container) continue;
                image = Array.from(container.querySelectorAll('img')).find(img => {
                    const r = img.getBoundingClientRect();
                    return r.left <= px && px < r.right && r.top <= py && py < r.bottom;
                });
                if (image) break;
            }
        }
        if (!image || !image.naturalWidth || !image.naturalHeight) return null;
        const scale = Math.min(1, 512 / Math.max(image.naturalWidth, image.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(scale * image.naturalWidth));
        canvas.height = Math.max(1, Math.round(scale * image.naturalHeight));
        try {
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = 'white';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
            return canvas.toDataURL('image/jpeg', 0.9);
        } catch {
            const src = image.currentSrc || image.src;
            if (/^https?:\/\//i.test(src)) return src;
            throw new Error('image unavailable');
        }
        """#

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.targetFrame?.isMainFrame != false,
               !["https", "http"].contains(action.request.url?.scheme?.lowercased()) {
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, ["https", "http"].contains(action.request.url?.scheme?.lowercased()) {
                webView.load(action.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            if (error as? URLError)?.code != .cancelled { browser.onError(error.localizedDescription) }
        }
    }
}
