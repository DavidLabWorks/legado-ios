import Combine
import SwiftUI

private struct ListeningPlayerControls: View {
    let book: Book
    @ObservedObject var speech: ReaderSpeechController
    let tint: Color
    let background: Color
    let openPlayer: () -> Void
    @AppStorage("themeMode") private var themeMode = "0"
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationStartedAt: Date?
    @State private var playedDuration: TimeInterval = 0
    static let buttonSize: CGFloat = 44
    private var buttonSize: CGFloat { Self.buttonSize }

    private var cover: some View {
        let rotates = speech.isSpeaking && !speech.isPreparingAudio && !reduceMotion
        let artwork = BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.displayCoverURL,
                                       width: 34, height: 34)
            .clipShape(Circle())
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !rotates)) { context in
            let elapsed = playedDuration + (rotationStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
            artwork.rotationEffect(.degrees(elapsed * 30))
        }
        .onAppear { if rotates { rotationStartedAt = .now } }
        .onChange(of: rotates) { playing in
            let now = Date()
            if let start = rotationStartedAt { playedDuration += now.timeIntervalSince(start) }
            rotationStartedAt = playing ? now : nil
        }
        .accessibilityHidden(true)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openPlayer) {
                cover
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("打开《\(book.name)》播放器")
            .accessibilityIdentifier("listening.openPlayer")
            Button { speech.pauseOrResume() } label: {
                ZStack {
                    Circle().fill(tint.opacity(0.10))
                    if speech.isPreparingAudio {
                        RagdollLoading(width: 24)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .offset(x: speech.isPaused ? 1 : 0)
                    }
                }
                .frame(width: 28, height: 28)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
            }
            .disabled(!speech.isSpeaking && !speech.isPaused)
            .accessibilityLabel(speech.isPaused ? "继续播放" : "暂停播放")
            .accessibilityValue(speech.isPreparingAudio ? "正在缓冲" : "")

            Button(action: speech.stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.75))
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭播放器")
        }
        .environment(\.layoutDirection, .leftToRight)
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background {
            Capsule().fill(background)
                .overlay(Capsule().strokeBorder(tint.opacity(0.15), lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .environment(\.colorScheme, themeMode == "2" ? .dark : (themeMode == "1" || themeMode == "3" ? .light : systemColorScheme))
    }
}

// The window covers presented sheets but never becomes key or handles touches outside the capsule.
final class ListeningPlayerWindow: UIWindow, UIGestureRecognizerDelegate {
    private weak var mainWindow: UIWindow?
    private weak var tabBar: UITabBar?
    // The full player can be presented above a reader or another sheet.
    private var viewports: [ListeningPlayerViewport.Anchor] = []
    private var viewport: ListeningPlayerViewport.Anchor? { viewports.last }
    private let speech = ReaderSpeechController.shared
    private var observation: AnyCancellable?
    private var host: UIHostingController<ListeningPlayerControls>?
    private var covered = true
    private var dockedRight = false
    private var verticalFraction: CGFloat = 1
    private var touchStart = CGPoint.zero
    private var dragOrigin: CGPoint?
    private var capsuleSize: CGSize {
        let side = ListeningPlayerControls.buttonSize
        return CGSize(width: 3 * side, height: side)
    }

    override var canBecomeKey: Bool { false }

    init(mainWindow: UIWindow, scene: UIWindowScene) {
        self.mainWindow = mainWindow
        super.init(windowScene: scene)
        windowLevel = .init(rawValue: UIWindow.Level.alert.rawValue + 0.5)
        backgroundColor = .clear
        let container = UIViewController()
        container.view.backgroundColor = .clear
        rootViewController = container
        observation = speech.$listeningChapter.map { $0 != nil }.removeDuplicates().sink { [weak self] active in
            self?.setBook(active ? self?.speech.listeningBook : nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCovered(_ value: Bool) {
        covered = value
        isHidden = covered || host == nil || viewports.contains { $0.showsFullPlayer }
    }

    private func setBook(_ book: Book?) {
        if let host {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            self.host = nil
        }
        dragOrigin = nil
        dockedRight = false
        verticalFraction = 1
        if let book, let container = rootViewController {
            let host = UIHostingController(rootView: controls(for: book))
            self.host = host
            host.view.backgroundColor = .clear
            container.addChild(host)
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            host.view.addGestureRecognizer(pan)
        }
        setCovered(covered)
        setNeedsLayout()
    }

    private func controls(for book: Book) -> ListeningPlayerControls {
        ListeningPlayerControls(book: book, speech: speech, tint: viewport?.tint ?? ReadingTheme.ink,
                                background: viewport?.fill ?? ReadingTheme.surface) { [weak self] in self?.openPlayer() }
    }

    private func openPlayer() {
        guard !covered, let scene = windowScene, scene.activationState == .foregroundActive,
              let window = scene.windows.first(where: \.isKeyWindow) ?? mainWindow,
              var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingPresented, !presenter.isBeingDismissed else { return }
        guard let reader = speech.listeningReader else { return }
        let page = UIHostingController(rootView: ListeningPlayerPage(reader: reader) { [weak presenter] in
            presenter?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        })
        page.modalPresentationStyle = .overFullScreen
        presenter.present(page, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    fileprivate func attach(_ anchor: ListeningPlayerViewport.Anchor) {
        viewports.append(anchor)
        refreshViewport()
    }

    fileprivate func viewportStyleChanged(_ anchor: ListeningPlayerViewport.Anchor) {
        if anchor === viewport { refreshViewport() }
    }

    fileprivate func detach(_ anchor: ListeningPlayerViewport.Anchor) {
        let wasCurrent = anchor === viewport
        viewports.removeAll { $0 === anchor }
        if wasCurrent || anchor.showsFullPlayer { refreshViewport() }
    }

    private func refreshViewport() {
        setCovered(covered)
        if let host, let book = speech.listeningBook { host.rootView = controls(for: book) }
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !covered, let view = host?.view, view.point(inside: view.convert(point, from: self), with: event)
        else { return nil }
        return super.hitTest(point, with: event)
    }

    private var safeBounds: CGRect { bounds.inset(by: mainWindow?.safeAreaInsets ?? safeAreaInsets) }

    func useTabBar(_ bar: UITabBar) {
        tabBar = bar
        setNeedsLayout()
    }

    private func clampedCenter(_ point: CGPoint) -> CGPoint {
        let safe = safeBounds
        let area = viewport.map { $0.convert($0.bounds, to: self).intersection(safe) }
        var available = area.flatMap { $0.isEmpty ? nil : $0 } ?? safe
        if let bar = tabBar, bar.window === mainWindow, !bar.isHidden, bar.alpha > 0 {
            let frame = bar.convert(bar.bounds, to: self)
            if frame.minY > safe.midY, frame.intersects(safe) {
                available.size.height = max(0, min(available.maxY, frame.minY - 8) - available.minY)
            }
        }
        let half = capsuleSize.height / 2
        let inset = min(safe.width / 2, capsuleSize.width / 2 + 12)
        let minY = max(safe.minY + half + 10, min(available.minY + half, available.midY))
        let maxY = max(minY, min(safe.maxY - half - 10, max(available.maxY - half, available.midY)))
        return CGPoint(x: min(max(point.x, safe.minX + inset), safe.maxX - inset),
                       y: min(max(point.y, minY), maxY))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let view = host?.view, dragOrigin == nil else { return }
        let safe = safeBounds
        let inset = capsuleSize.height / 2 + 10
        let y = safe.minY + inset + verticalFraction * max(0, safe.height - 2 * inset)
        view.bounds.size = capsuleSize
        view.center = clampedCenter(CGPoint(x: dockedRight ? safe.maxX : safe.minX, y: y))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchStart = touch.location(in: self)
        return true
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let view = host?.view else { return }
        if gesture.state == .began { dragOrigin = view.center }
        guard let origin = dragOrigin else { return }
        let touch = gesture.location(in: self)
        let delta = CGPoint(x: touch.x - touchStart.x, y: touch.y - touchStart.y)
        let center = clampedCenter(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        switch gesture.state {
        case .began, .changed:
            view.center = center
        case .ended, .cancelled, .failed:
            if gesture.state == .ended {
                dockedRight = center.x > safeBounds.midX
                let inset = capsuleSize.height / 2 + 10
                if delta.y != 0, safeBounds.height > 2 * inset {
                    verticalFraction = (center.y - safeBounds.minY - inset) / (safeBounds.height - 2 * inset)
                }
            }
            dragOrigin = nil
            setNeedsLayout()
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) { self.layoutIfNeeded() }
        default: break
        }
    }
}

struct ListeningPlayerViewport: UIViewRepresentable {
    let tint: Color
    let background: Color
    var showsFullPlayer = false

    final class Anchor: UIView {
        fileprivate var showsFullPlayer = false
        fileprivate var tint = Color.primary
        fileprivate var fill = ReadingTheme.surface
        fileprivate weak var overlay: ListeningPlayerWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            overlay?.detach(self)
            overlay = window?.windowScene?.windows.compactMap { $0 as? ListeningPlayerWindow }.first
            overlay?.attach(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            overlay?.setNeedsLayout()
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) {
        guard view.tint != tint || view.fill != background || view.showsFullPlayer != showsFullPlayer else { return }
        view.showsFullPlayer = showsFullPlayer
        view.tint = tint
        view.fill = background
        view.overlay?.viewportStyleChanged(view)
    }
}
