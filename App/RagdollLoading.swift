import SwiftUI
import UIKit
import ImageIO
import WebKit

/// The six registered frames share one canvas, so resizing never shifts the baseline.
final class RagdollImageView: UIImageView {
    fileprivate static let artwork = NSDataAsset(name: "RagdollRun")?.data
    fileprivate static let frames: [UIImage] = {
        guard let artwork, let source = CGImageSourceCreateWithData(artwork as CFData, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap { index in
            CGImageSourceCreateImageAtIndex(source, index, nil).map { UIImage(cgImage: $0) }
        }
    }()

    static func size(width: CGFloat) -> CGSize {
        CGSize(width: width, height: width * 5 / 8)
    }

    private let preferredSize: CGSize
    override var intrinsicContentSize: CGSize { preferredSize }

    init(width: CGFloat) {
        preferredSize = Self.size(width: width)
        super.init(frame: CGRect(origin: .zero, size: preferredSize))
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = false
        image = Self.frames.first
        animationImages = Self.frames
        animationDuration = 0.58
        NotificationCenter.default.addObserver(self, selector: #selector(updatePlayback),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    override var isHidden: Bool { didSet { updatePlayback() } }

    override func startAnimating() {
        guard window != nil, !isHidden, !UIAccessibility.isReduceMotionEnabled else { return }
        super.startAnimating()
    }

    @objc private func updatePlayback() {
        if window != nil, !isHidden, !UIAccessibility.isReduceMotionEnabled {
            if !isAnimating { startAnimating() }
        } else {
            stopAnimating()
        }
    }
}

private struct RagdollSprite: UIViewRepresentable {
    let width: CGFloat
    func makeUIView(context: Context) -> RagdollImageView { RagdollImageView(width: width) }
    func updateUIView(_ view: RagdollImageView, context: Context) {}
}

struct RagdollLoading: View {
    private let title: LocalizedStringKey?
    private let width: CGFloat
    private let axis: Axis

    init(_ title: LocalizedStringKey? = nil, width: CGFloat = 44, axis: Axis = .horizontal) {
        self.title = title
        self.width = width
        self.axis = axis
    }

    var body: some View {
        Group {
            if let title {
                if axis == .vertical {
                    VStack(spacing: 8) { sprite; Text(title).multilineTextAlignment(.center) }
                } else {
                    HStack(spacing: 8) { sprite; Text(title) }
                }
            } else {
                sprite
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title ?? "正在加载"))
    }

    private var sprite: some View {
        RagdollSprite(width: width)
            .frame(width: width, height: RagdollImageView.size(width: width).height)
    }
}

// Keep the native pull gesture and refresh action. Only its artwork changes.
extension UIRefreshControl {
    @objc dynamic var showsRagdoll: Bool {
        get { subviews.contains { $0 is RagdollImageView } }
        set {
            guard newValue, !showsRagdoll else { return }
            tintColor = .clear
            let cat = RagdollImageView(width: 40)
            cat.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cat)
            NSLayoutConstraint.activate([
                cat.centerXAnchor.constraint(equalTo: centerXAnchor),
                cat.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }
}

/// Main-document navigation and loading indicators inside source HTML use the same artwork.
final class ReadingWebView: WKWebView {
    private let cat = RagdollImageView(width: 80)
    private var loadingObservation: NSKeyValueObservation?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        if let script = Self.pageLoadingStyle {
            configuration.userContentController.addUserScript(script)
        }
        super.init(frame: frame, configuration: configuration)
        cat.isHidden = true
        cat.isAccessibilityElement = true
        cat.accessibilityLabel = "正在加载网页"
        addSubview(cat)
        loadingObservation = observe(\.isLoading, options: [.old, .new]) { [weak self] web, change in
            guard change.oldValue != change.newValue else { return }
            self?.cat.isHidden = !web.isLoading
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func hideNavigationIndicator() {
        cat.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cat.center = CGPoint(x: bounds.midX, y: bounds.midY)
        bringSubviewToFront(cat)
    }

    // Style the indicator itself. A busy container may contain a usable form or list.
    private static let pageLoadingStyle: WKUserScript? = {
        guard let artwork = RagdollImageView.artwork, let still = RagdollImageView.frames.first?.pngData() else { return nil }
        let css = """
        :root { --legado-loader: url(data:image/png;base64,\(artwork.base64EncodedString())); }
        @media (prefers-reduced-motion: reduce) {
          :root { --legado-loader: url(data:image/png;base64,\(still.base64EncodedString())); }
        }
        :is(i, span, div, b):is(.spinner, .loader, .loading-spinner, .loading-indicator, .spinner-border,
            .spinner-grow, .fa-spinner, .loading, #loader, #spinner, #loading, [role="progressbar"]:not([aria-valuenow])):empty,
        progress:indeterminate, .lds-ring, .lds-roller, .lds-spinner, .van-loading__spinner,
        .ant-spin-dot, .weui-loading, .el-loading-spinner svg.circular,
        svg:is(.spinner, .loader, .loading-spinner, .loading-indicator, .animate-spin),
        img:is(.spinner, .loader, .loading-spinner, [src$="/loading.gif" i], [src$="/spinner.gif" i], [alt="loading" i], [alt="加载中"]) {
          content: var(--legado-loader) !important;
          width: var(--legado-loading-width, 2.5em) !important;
          height: auto !important;
          aspect-ratio: 8 / 5 !important;
          object-fit: contain !important;
          animation: none !important;
          border: 0 !important;
          background: transparent !important;
        }
        [data-legado-loading-label]::before {
          content: "" !important;
          display: inline-block;
          vertical-align: middle;
          width: var(--legado-loading-width, 2.5em);
          aspect-ratio: 8 / 5;
          margin-inline-end: .4em;
          background: var(--legado-loader) center / contain no-repeat;
        }
        """
        let script = """
        (() => {
          const style = document.createElement('style');
          style.textContent = \(String(decoding: try! JSONEncoder().encode(css), as: UTF8.self));
          (document.head || document.documentElement).append(style);

          // Some sites replace a plain text node when the next page arrives.
          function label(element) {
            if (!element || element.nodeType !== Node.ELEMENT_NODE || !element.matches('p, div, span, button, small, li, [role="status"]')) return;
            const text = element.childElementCount === 0 ? element.textContent.trim() : '';
            const loading = /^(?:loading|加载中|正在加载)(?:[.…。 ]*)$/i.test(text);
            element.toggleAttribute('data-legado-loading-label', loading);
          }
          function inspect(node) {
            if (node.nodeType === Node.TEXT_NODE) { label(node.parentElement); return; }
            const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) label(walker.currentNode.parentElement);
          }
          if (document.body) inspect(document.body);
          new MutationObserver(records => {
            for (const record of records) {
              if (record.type === 'characterData') label(record.target.parentElement);
              else {
                label(record.target);
                record.addedNodes.forEach(inspect);
              }
            }
          }).observe(document.documentElement, {subtree: true, childList: true, characterData: true});
        })();
        """
        return WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
    }()
}
