import LocalAuthentication
import SwiftUI

struct AppLockGate<Content: View>: View {
    @ObservedObject private var lock = AppLock.shared
    @StateObject private var session = AppLockSession()
    @Environment(\.scenePhase) private var phase
    @State private var opened = false
    @State private var pendingURLs: [URL] = []
    let handleURL: (URL) -> Void
    @ViewBuilder let content: (Bool) -> Content

    private var canOpen: Bool { session.permitted && phase == .active }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if opened || canOpen || (session.permitted && session.unlockingWhileInactive) {
                content(canOpen)
                    .disabled(!session.permitted)
                    .accessibilityHidden(!session.permitted)
                    .onAppear { opened = true }
            }
        }
        .background(AppLockWindowAnchor(session: session, lock: lock))
        .onChange(of: canOpen) { allowed in
            guard allowed else { return }
            let urls = pendingURLs
            pendingURLs.removeAll()
            urls.forEach(handleURL)
        }
        .onOpenURL { url in
            if canOpen { handleURL(url) } else { pendingURLs.append(url) }
        }
    }
}

@MainActor
private final class AppLockSession: NSObject, ObservableObject {
    @Published private var authorizedID: UUID?
    private var attemptID = UUID()
    private weak var mainWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var playerWindow: ListeningPlayerWindow?
    private var cover: UIWindow?
    private let shield = UIView()
    private var previouslyHiddenFromAccessibility = false
    private var showingForm = false
    private var manuallyLocked = false
    private var backgroundedAt: UInt64?
    private var inactive = true
    private(set) var unlockingWhileInactive = false
    private let lock = AppLock.shared

    private var autoLockExpired: Bool {
        guard let backgroundedAt else { return false }
        let elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - backgroundedAt
        return lock.autoLockDelay.hasElapsed(nanoseconds: elapsed)
    }

    var permitted: Bool {
        !lock.storageUnavailable && (lock.credential == nil || (authorizedID == lock.credential?.id && !autoLockExpired))
    }

    func attach(_ window: UIWindow) {
        guard mainWindow !== window else { return }
        NotificationCenter.default.removeObserver(self)
        if let cover {
            cover.isHidden = true
            mainWindow?.accessibilityElementsHidden = previouslyHiddenFromAccessibility
        }
        cover = nil
        showingForm = false
        unlockingWhileInactive = false
        playerWindow?.isHidden = true
        playerWindow = nil
        mainWindow = window
        guard let scene = window.windowScene else { return }
        playerWindow = ListeningPlayerWindow(mainWindow: window, scene: scene)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(lockNow), name: AppLock.lockNowNotification, object: nil)
        center.addObserver(self, selector: #selector(deactivate), name: UIScene.willDeactivateNotification, object: scene)
        center.addObserver(self, selector: #selector(background), name: UIScene.didEnterBackgroundNotification, object: scene)
        center.addObserver(self, selector: #selector(activate), name: UIScene.didActivateNotification, object: scene)
        inactive = scene.activationState != .foregroundActive
        refresh()
    }

    @objc private func deactivate() {
        unlockingWhileInactive = false
        inactive = true
        refresh()
    }

    @objc private func lockNow() {
        manuallyLocked = true
        unlockingWhileInactive = false
        attemptID = UUID()
        authorizedID = nil
        showingForm = false
        refresh()
    }

    @objc private func background() {
        if backgroundedAt == nil { backgroundedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
        attemptID = UUID()
        if autoLockExpired { authorizedID = nil }
        showingForm = false
        cover?.rootViewController = nil
        deactivate()
    }

    @objc private func activate() {
        if autoLockExpired { authorizedID = nil }
        backgroundedAt = nil
        if lock.storageUnavailable { lock.reload() }
        inactive = false
        unlockingWhileInactive = false
        refresh()
    }

    func refresh() {
        guard let scene = mainWindow?.windowScene else { return }
        let needsCover = !permitted || (inactive && !unlockingWhileInactive && lock.credential != nil)
        playerWindow?.setCovered(needsCover)
        guard needsCover else {
            manuallyLocked = false
            if let cover {
                let animateUnlock = showingForm && authorizedID != nil && lock.credential?.id == authorizedID
                self.cover = nil
                showingForm = false
                cover.accessibilityElementsHidden = true
                mainWindow?.accessibilityElementsHidden = previouslyHiddenFromAccessibility
                if cover.isKeyWindow {
                    let next = previousKeyWindow.flatMap { $0.isHidden ? nil : $0 } ?? mainWindow
                    next?.makeKey()
                }
                if animateUnlock {
                    dismissUnlockedCover(cover)
                } else {
                    cover.isHidden = true
                }
            }
            return
        }

        // A separate scene window also covers reader sheets and website verification prompts.
        let window: UIWindow
        if let cover {
            window = cover
        } else {
            previouslyHiddenFromAccessibility = mainWindow?.accessibilityElementsHidden ?? false
            mainWindow?.accessibilityElementsHidden = true
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            window.backgroundColor = .systemBackground
            cover = window
        }
        if inactive {
            // Face ID can deactivate the scene. The lock form already covers the app
            // until background() removes it for the app switcher snapshot.
            if showingForm { return }
            if window.rootViewController == nil { window.rootViewController = UIViewController() }
            shield.backgroundColor = .systemBackground
            shield.frame = window.bounds
            shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(shield)
            window.isHidden = false
        } else {
            if !showingForm {
                let attempt = attemptID
                let form = AppUnlockView(automaticallyStartFaceID: !manuallyLocked) { [weak self] id in
                    guard let self, self.attemptID == attempt, self.lock.credential?.id == id,
                          let state = self.mainWindow?.windowScene?.activationState,
                          state == .foregroundActive || state == .foregroundInactive else { return }
                    self.cover?.rootViewController?.view.isUserInteractionEnabled = false
                    // Face ID can finish while its system UI still owns the foreground.
                    self.unlockingWhileInactive = self.inactive && state == .foregroundInactive
                    self.authorizedID = id
                    self.refresh()
                }
                window.rootViewController = UIHostingController(rootView: form)
                showingForm = true
            }
            shield.removeFromSuperview()
            window.makeKeyAndVisible()
        }
    }

    private func dismissUnlockedCover(_ window: UIWindow) {
        if UIAccessibility.isReduceMotionEnabled || UserDefaults.standard.string(forKey: "themeMode") == "3" {
            UIView.animate(withDuration: 0.15, animations: { window.alpha = 0 }) { _ in window.isHidden = true }
            return
        }

        // Move only the opaque lock screen. The live destination stays in place underneath.
        window.backgroundColor = .clear
        let animator = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut) {
            window.rootViewController?.view.transform = CGAffineTransform(translationX: 0, y: -window.bounds.height)
        }
        animator.addCompletion { _ in window.isHidden = true }
        animator.startAnimation()
    }
}

private struct AppLockWindowAnchor: UIViewRepresentable {
    let session: AppLockSession
    @ObservedObject var lock: AppLock

    final class Anchor: UIView {
        weak var session: AppLockSession?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // UIKit detaches the presenting view during a full-screen reader presentation.
            if let window { session?.attach(window) }
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.session = session
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) { session.refresh() }
}

private struct AppUnlockView: View {
    @ObservedObject private var lock = AppLock.shared
    @AppStorage("themeMode") private var themeMode = "0"
    @State private var message = ""
    @State private var context: LAContext?
    @State private var showsFaceIDButton = false
    @State private var acceptedPIN = false
    let automaticallyStartFaceID: Bool
    let unlock: (UUID) -> Void

    var body: some View {
        Group {
            if lock.storageUnavailable {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.largeTitle)
                    Text("请先解锁设备，再读取应用密码。")
                    Button { lock.reload() } label: {
                        Text("重试").padding(.horizontal, 22).frame(minHeight: 44)
                            .lockGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                LockCodePad(title: lock.credential?.numericPIN == true ? "输入喵阅锁定码" : "输入原应用密码",
                            legacyPassword: lock.credential?.numericPIN != true, message: $message,
                            faceID: lock.credential?.faceIDState == nil ? nil : { Task { await verifyFaceID() } },
                            showsFaceIDButton: showsFaceIDButton,
                            acceptedPIN: acceptedPIN,
                            submit: { verify($0) })
                    .disabled(context != nil)
                    .task {
                        if automaticallyStartFaceID { await verifyFaceID() }
                        else { showsFaceIDButton = true }
                    }
            }
        }
        .preferredColorScheme(themeMode == "2" ? .dark : (themeMode == "1" || themeMode == "3" ? .light : nil))
        .onDisappear { context?.invalidate() }
    }

    private func verify(_ password: String) {
        guard let id = lock.credential?.id else { return }
        do {
            try lock.verify(password)
            acceptedPIN = lock.credential?.numericPIN == true
            unlock(id)
        } catch { message = error.localizedDescription }
    }

    private func verifyFaceID() async {
        guard context == nil, let record = lock.credential, let expected = record.faceIDState else { return }
        let attempt = LAContext()
        context = attempt
        showsFaceIDButton = false
        defer { context = nil }
        do {
            let state = try await AppLock.authenticateFaceID(attempt)
            guard state == expected, lock.credential?.faceIDState == state else {
                message = "Face ID 设置已变更，请使用应用密码。"
                return
            }
            unlock(record.id)
        } catch {
            message = "请使用应用密码，或重试 Face ID。"
            showsFaceIDButton = true
        }
    }
}
