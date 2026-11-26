@preconcurrency import KSPlayer
import SwiftUI

struct RSSVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let referer: URL?
    let mini: Bool
    let setMini: (Bool) -> Void
    let onCollapseDrag: (CGFloat, Bool) -> Void
    let onDrag: (CGPoint) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> ArticlePlayerView { ArticlePlayerView() }

    func makeUIViewController(context: Context) -> UIViewController {
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        let host = UIViewController()
        let player = context.coordinator
        player.inlineHost = host
        player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        player.attach(to: host.view)
        player.accessibilityIdentifier = "website.video.player"
        player.backgroundColor = .black
        player.installSizeControls()
        player.toolBar.playbackRateButton.accessibilityLabel = "播放速度"
        player.toolBar.timeLabel.accessibilityIdentifier = "website.video.time"
        player.installSeekSlider()
        let options = KSOptions()
        options.isAccurateSeek = true
        options.registerRemoteControll = false
        options.canStartPictureInPictureAutomaticallyFromInline = false
        options.userAgent = ApplicationSettingsStore.shared.settings.effectiveUserAgent
        options.formatContextOptions["protocol_whitelist"] = "http,https,tcp,tls,crypto,httpproxy"
        if let referer, let scheme = referer.scheme, ["http", "https"].contains(scheme),
           var origin = URLComponents(url: referer, resolvingAgainstBaseURL: true) {
            origin.user = nil
            origin.password = nil
            origin.path = "/"
            origin.query = nil
            origin.fragment = nil
            if let address = origin.string { options.appendHeader(["Referer": address]) }
        }
        player.set(resource: KSPlayerResource(url: url, options: options, name: url.lastPathComponent))
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let player = context.coordinator
        player.dragMini = onDrag
        player.backBlock = onClose
        player.setMini = setMini
        player.collapseDrag = onCollapseDrag
        player.mini = mini
    }

    static func dismantleUIViewController(_ host: UIViewController, coordinator player: ArticlePlayerView) {
        player.fullscreen?.dismiss(animated: false)
        player.playerLayer?.stop()
        player.playerLayer = nil
        player.backBlock = nil
        player.setMini = nil
        player.collapseDrag = nil
        player.dragMini = nil
    }

    // UIControl receives the full touch sequence. UISlider draws the track and supports VoiceOver.
    final class SeekSlider: UIControl {
        let slider = UISlider()

        override init(frame: CGRect) {
            super.init(frame: frame)
            slider.frame = bounds
            slider.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            slider.accessibilityLabel = "播放进度"
            slider.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                onSeek?(Double(slider.value), .touchUpInside)
            }, for: .valueChanged)
            addSubview(slider)
            let scrub = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
            scrub.minimumPressDuration = 0
            scrub.allowableMovement = .greatestFiniteMagnitude
            addGestureRecognizer(scrub)
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override var isEnabled: Bool {
            didSet { slider.isEnabled = isEnabled }
        }

        var onSeek: ((Double, ControlEvents) -> Void)?

        @objc private func scrub(_ gesture: UILongPressGestureRecognizer) {
            guard isEnabled else { return }
            let track = slider.trackRect(forBounds: bounds)
            let start = slider.thumbRect(forBounds: bounds, trackRect: track, value: slider.minimumValue).midX
            let end = slider.thumbRect(forBounds: bounds, trackRect: track, value: slider.maximumValue).midX
            guard start != end else { return }
            let fraction = min(1, max(0, (gesture.location(in: self).x - start) / (end - start)))
            let target = slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)
            switch gesture.state {
            case .began, .changed:
                if gesture.state == .began { onSeek?(Double(slider.value), .touchDown) }
                slider.value = target
                onSeek?(Double(target), .valueChanged)
            case .ended:
                slider.value = target
                onSeek?(Double(target), .touchUpInside)
            case .cancelled, .failed:
                onSeek?(Double(slider.value), .touchCancel)
            default: break
            }
        }
    }

    final class LandscapeController: UIViewController {
        var onDismiss: (() -> Void)?
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
        override var prefersStatusBarHidden: Bool { true }
        override var prefersHomeIndicatorAutoHidden: Bool { true }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil {
                onDismiss?()
                onDismiss = nil
            }
        }
    }

    final class ArticlePlayerView: IOSVideoPlayerView, UIGestureRecognizerDelegate {
        weak var inlineHost: UIViewController?
        weak var fullscreen: LandscapeController?
        var setMini: ((Bool) -> Void)?
        var collapseDrag: ((CGFloat, Bool) -> Void)?
        var dragMini: ((CGPoint) -> Void)?
        var mini = false {
            didSet { if mini != oldValue { refreshControls() } }
        }
        private let miniControls = UIView()
        private let shrink = UIButton()
        private let miniPlay = UIButton()
        private let seekSlider = SeekSlider()

        override func setupUIComponents() {
            loadingIndector = RagdollImageView(width: 56)
            super.setupUIComponents()
        }

        override func customizeUIComponents() {
            super.customizeUIComponents()
            // KSPlayer installs a fixed width of 25 pt on its back button.
            backButton.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil }?.constant = 44
            backButton.setImage(nil, for: .normal)
            backButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            backButton.setTitleColor(.white, for: .normal)
            backButton.setTitleColor(.white.withAlphaComponent(0.6), for: .highlighted)
            navigationBar.setCustomSpacing(16, after: backButton)
            let divider = UIView()
            divider.backgroundColor = .white.withAlphaComponent(0.4)
            divider.isUserInteractionEnabled = false
            divider.translatesAutoresizingMaskIntoConstraints = false
            navigationBar.addSubview(divider)
            NSLayoutConstraint.activate([
                divider.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
                divider.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: 14),
            ])

            for button in [toolBar.definitionButton, toolBar.audioSwitchButton, toolBar.videoSwitchButton,
                           toolBar.srtButton, toolBar.pipButton] {
                button.removeFromSuperview()
            }
        }

        func installSeekSlider() {
            let original = toolBar.timeSlider
            original.isHidden = true
            seekSlider.isEnabled = false
            seekSlider.slider.minimumTrackTintColor = .white
            seekSlider.slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
            }
            seekSlider.slider.setThumbImage(thumb, for: .normal)
            seekSlider.onSeek = { [weak self] value, event in self?.trackSeek(value, event: event) }
            bottomMaskView.addSubview(seekSlider)
            seekSlider.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                seekSlider.leadingAnchor.constraint(equalTo: original.leadingAnchor),
                seekSlider.trailingAnchor.constraint(equalTo: original.trailingAnchor),
                seekSlider.bottomAnchor.constraint(equalTo: original.bottomAnchor),
                seekSlider.heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        override func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
            guard !isScrubbing, pendingSeek == nil else { return }
            super.player(layer: layer, currentTime: currentTime, totalTime: totalTime)
            let original = toolBar.timeSlider
            seekSlider.slider.maximumValue = original.maximumValue
            seekSlider.slider.value = original.value
            seekSlider.isEnabled = original.isPlayable && toolBar.isSeekable && totalTime.isFinite && totalTime > 0
        }

        private var isScrubbing = false
        private var pendingSeek: UUID?
        private var panStartTime: TimeInterval = 0
        private lazy var seekPan = UIPanGestureRecognizer(target: self, action: #selector(scrub(_:)))
        private lazy var collapsePan = UIPanGestureRecognizer(target: self, action: #selector(collapse(_:)))

        private func trackSeek(_ value: Double, event: ControlEvents) {
            switch event {
            case .touchDown: isScrubbing = true
            case .valueChanged:
                slider(value: value, event: .valueChanged)
                seekSlider.slider.value = Float(value)
            case .touchUpInside:
                isScrubbing = false
                toolBar.currentTime = value
                slider(value: value, event: .touchUpInside)
            default:
                isScrubbing = false
                if let layer = playerLayer {
                    player(layer: layer, currentTime: layer.player.currentPlaybackTime, totalTime: layer.player.duration)
                }
            }
        }

        override func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
            guard let layer = playerLayer, layer.player.isReadyToPlay, toolBar.isSeekable,
                  time.isFinite else { completion(false); return }
            let request = UUID()
            pendingSeek = request
            layer.player.seek(time: time) { [weak self, weak layer] finished in
                guard let self, let layer, pendingSeek == request else { completion(false); return }
                pendingSeek = nil
                if finished {
                    if layer.state.isPlaying { layer.play() } else { layer.pause() }
                }
                completion(finished)
            }
        }

        @objc private func scrub(_ pan: UIPanGestureRecognizer) {
            guard let layer = playerLayer else { return }
            if pan.state == .began {
                panStartTime = toolBar.currentTime
                trackSeek(panStartTime, event: .touchDown)
            }
            let fraction = pan.translation(in: self).x / max(1, bounds.width)
            let duration = layer.player.duration
            let target = min(duration, max(0, panStartTime + fraction * duration))
            switch pan.state {
            case .began, .changed:
                showSeekToView(second: target, isAdd: fraction >= 0)
                trackSeek(target, event: .valueChanged)
            case .ended:
                hideSeekToView()
                trackSeek(target, event: .valueChanged)
                trackSeek(target, event: .touchUpInside)
            case .cancelled, .failed:
                hideSeekToView()
                trackSeek(target, event: .touchCancel)
            default: break
            }
        }

        func attach(to host: UIView) {
            host.addSubview(self)
            frame = host.bounds
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // The toolbar fades in. Its progress track should accept the first tap during that animation.
            if isMaskShow, !controllerView.isHidden, !isLock, seekSlider.isEnabled,
               seekSlider.bounds.contains(seekSlider.convert(point, from: self)) {
                return seekSlider
            }
            return super.hitTest(point, with: event)
        }

        func installSizeControls() {
            for gesture in [tapGesture, doubleTapGesture, panGesture, longPressGesture, seekPan] {
                gesture.delegate = self
            }
            seekPan.maximumNumberOfTouches = 1
            controllerView.addGestureRecognizer(seekPan)
            panGesture.require(toFail: seekPan)
            collapsePan.delegate = self
            collapsePan.maximumNumberOfTouches = 1
            controllerView.addGestureRecognizer(collapsePan)
            panGesture.require(toFail: collapsePan)
            shrink.setImage(UIImage(systemName: "pip.enter"), for: .normal)
            shrink.tintColor = .white
            shrink.accessibilityLabel = "缩小为悬浮窗"
            shrink.addAction(UIAction { [weak self] _ in self?.setMini?(true) }, for: .touchUpInside)
            navigationBar.addArrangedSubview(shrink)
            shrink.widthAnchor.constraint(equalToConstant: 44).isActive = true

            addSubview(miniControls)
            miniControls.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveMini(_:))))
            let restoreTap = UITapGestureRecognizer(target: self, action: #selector(restoreFromMini))
            restoreTap.numberOfTapsRequired = 2
            restoreTap.delegate = self
            miniControls.addGestureRecognizer(restoreTap)
            miniControls.frame = bounds
            miniControls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addMiniButton(UIButton(), symbol: "xmark", label: "关闭视频", top: true, left: true) { [weak self] in
                self?.backBlock?()
            }
            addMiniButton(miniPlay, symbol: "play.fill", label: "播放", top: false, left: true) { [weak self] in
                self?.toolBar.playButton.sendActions(for: .primaryActionTriggered)
            }
            addMiniButton(UIButton(), symbol: "arrow.up.left.and.arrow.down.right", label: "还原为顶部半屏", top: false, left: false) { [weak self] in
                self?.restoreFromMini()
            }
            refreshControls()
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGesture {
                let velocity = panGesture.velocity(in: self)
                return abs(velocity.y) >= abs(velocity.x) && super.gestureRecognizerShouldBegin(gestureRecognizer)
            }
            if gestureRecognizer === seekPan {
                let velocity = seekPan.velocity(in: self)
                guard let player = playerLayer?.player else { return false }
                return !mini && !isLock && toolBar.isSeekable && player.duration.isFinite && player.duration > 0 &&
                    abs(velocity.x) > abs(velocity.y)
            }
            guard gestureRecognizer === collapsePan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            let velocity = collapsePan.velocity(in: window)
            return !mini && fullscreen == nil && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var hit = touch.view
            while let view = hit, view !== controllerView {
                if view === replayButton && gestureRecognizer === seekPan { return true }
                if view is UIControl { return false }
                hit = view.superview
            }
            return true
        }

        @objc private func collapse(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began, .changed: collapseDrag?(pan.translation(in: window).y, false)
            case .ended: collapseDrag?(pan.translation(in: window).y, true)
            case .cancelled, .failed: collapseDrag?(0, true)
            default: break
            }
        }

        override func updateUI(isFullScreen: Bool) {
            guard isFullScreen else {
                fullscreen?.dismiss(animated: true)
                return
            }
            guard !mini, fullscreen == nil, let inlineHost, let scene = inlineHost.view.window?.windowScene else { return }
            let originalOrientation = scene.interfaceOrientation
            let controller = LandscapeController()
            fullscreen = controller
            controller.modalPresentationStyle = .fullScreen
            if #available(iOS 18.0, *) {
                controller.preferredTransition = .zoom { [weak inlineHost] _ in inlineHost?.view }
            }
            controller.view.backgroundColor = .black
            controller.onDismiss = { [weak self, weak inlineHost, weak scene] in
                guard let self, let inlineHost else { return }
                self.attach(to: inlineHost.view)
                self.fullscreen = nil
                self.landscapeButton.isSelected = false
                self.updateUI(isLandscape: false)
                DispatchQueue.main.async {
                    if #available(iOS 16, *), let scene, originalOrientation != .unknown {
                        inlineHost.view.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                        let mask = UIInterfaceOrientationMask(rawValue: 1 << originalOrientation.rawValue)
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                    } else {
                        UIViewController.attemptRotationToDeviceOrientation()
                    }
                }
            }
            attach(to: controller.view)
            landscapeButton.isSelected = true
            updateUI(isLandscape: true)
            inlineHost.present(controller, animated: true)
        }

        override func onButtonPressed(type: PlayerButtonType, button: UIButton) {
            if type == .back, fullscreen != nil {
                updateUI(isFullScreen: false)
            } else {
                super.onButtonPressed(type: type, button: button)
            }
        }

        @objc private func restoreFromMini() {
            setMini?(false)
        }

        @objc private func moveMini(_ pan: UIPanGestureRecognizer) {
            guard let window, [.began, .changed, .ended].contains(pan.state) else { return }
            let delta = pan.translation(in: window)
            pan.setTranslation(.zero, in: window)
            dragMini?(delta)
        }

        private func addMiniButton(_ button: UIButton, symbol: String, label: String,
                                   top: Bool, left: Bool, action: @escaping () -> Void) {
            miniControls.addSubview(button)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = .white
            button.layer.shadowOpacity = 0.9
            button.layer.shadowRadius = 2
            button.layer.shadowOffset = .zero
            button.accessibilityLabel = label
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
                top ? button.topAnchor.constraint(equalTo: miniControls.topAnchor)
                    : button.bottomAnchor.constraint(equalTo: miniControls.bottomAnchor),
                left ? button.leadingAnchor.constraint(equalTo: miniControls.leadingAnchor)
                     : button.trailingAnchor.constraint(equalTo: miniControls.trailingAnchor),
            ])
        }

        private func refreshControls() {
            let full = landscapeButton.isSelected
            let compact = mini && !full
            controllerView.isHidden = compact
            miniControls.isHidden = !compact
            shrink.isHidden = full
            landscapeButton.isHidden = false
            landscapeButton.accessibilityLabel = full ? "退出全屏" : "全屏"
            backButton.setTitle(full ? "返回" : "关闭", for: .normal)
            backButton.accessibilityLabel = full ? "退出全屏播放" : "关闭视频"
            toolBar.playbackRateButton.isHidden = false
        }

        override func updateUI(isLandscape: Bool) {
            super.updateUI(isLandscape: isLandscape)
            refreshControls()
        }

        override func player(layer: KSPlayerLayer, state: KSPlayerState) {
            super.player(layer: layer, state: state)
            miniPlay.setImage(UIImage(systemName: state.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
            miniPlay.accessibilityLabel = state.isPlaying ? "暂停" : "播放"
            if state == .error {
                titleLabel.text = "视频加载失败，点播放重试"
            } else if state == .readyToPlay {
                let duration = layer.player.duration
                if duration.isFinite && duration > 0 {
                    // VOD playlists support time-based seeking even without HTTP byte ranges.
                    if layer.options.formatName == "hls" { toolBar.isSeekable = true }
                    seekSlider.slider.maximumValue = Float(duration)
                    seekSlider.isEnabled = toolBar.isSeekable
                }
                // A fullscreen display layer can enter system PiP even with inline auto-start disabled.
                // In KSPlayer 2.3.4 this delegate only recreates the PiP source when the layer changes.
                (layer.player as? KSMEPlayer)?.videoOutput?.displayLayerDelegate = nil
                layer.player.pipController?.contentSource = nil
                titleLabel.text = layer.url.lastPathComponent
            }
        }
    }
}

extension RagdollImageView: @preconcurrency LoadingIndector {}
