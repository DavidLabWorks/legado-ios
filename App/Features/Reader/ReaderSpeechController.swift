@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI

enum ReaderSpokenText: Equatable {
    case chapterTitle
    case body(NSRange)
}

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject {
    static let shared = ReaderSpeechController()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparingAudio = false
    @Published private(set) var isPaused = false {
        didSet { sleepTimer.setPaused(isPaused) }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var listeningChapter: Int?
    private(set) var listeningReader: ReaderViewModel?
    var listeningBook: Book? { listeningReader?.book }
    private(set) var errorBookURL: String?
    private(set) var listeningPosition = 0
    private var preparationTaskID: UIBackgroundTaskIdentifier = .invalid
    private var needsChapterAudio = false
    private var chapterTask: Task<Void, Never>?
    let sleepTimer = ListeningSleepTimer()
    private var library: BookLibraryModel?
    private var rules: ReplaceRuleLibraryModel?
    @Published private(set) var spokenText: ReaderSpokenText?
    @Published private(set) var spokenPosition: Int?
    private var audioSessionActive = false
    private var renderStartTask: Task<Void, Never>?
    private var downloadResume: CheckedContinuation<Void, Never>?
    private let loadAudio: @Sendable (String, ListeningVoice) async throws -> Data
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let speed = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private struct QueuedAudio {
        let passage: Int
        let buffer: AVAudioPCMBuffer
        var frames: Int { Int(buffer.frameLength) }
    }
    private var queue: [QueuedAudio] = []
    private var scheduleID = 0
    private var needsRescheduling = false
    private var headSampleTime: AVAudioFramePosition = 0
    private var queuedFrames = 0
    private var waitingForReserve = true
    private var reserveSeconds = 6.0
    private var generation = 0
    private var producerFinished = false
    private var playbackTask: Task<Void, Never>?
    private var phrases: [SpokenPassage] = []
    private var phraseIndex = 0
    private var listeningVoice = ListeningVoice.preferred
    private var nextUnheardPassage = 0
    private struct VoiceHandoff {
        let afterPassage: Int
        let firstAudio: Task<Data, Error>?
    }
    private var handoff: VoiceHandoff?
    @Published private(set) var isChangingVoice = false
    static func playbackRate(for setting: Int) -> Float {
        min(2, max(0.5, (Float(setting) + 5) / 10))
    }

    @Published private(set) var speechRate = 5
    private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var resumesAfterInterruption = false
    private var ignoresAudioFocus = false
    private var pausesForPhoneCalls = false
    private var mediaButtonPerNext = false
    private var chapterLength = 0
    private var firstPosition = 0
    private var synthesizedEnd = 0
    private var synthesizedCharacters = 0
    private var synthesizedFrames = 0
    private var elapsedInBuffer: TimeInterval = 0
    private var bufferStartedAt: TimeInterval?
    private let estimatedSecondsPerCharacter = 0.24
    private var coverAddress: String?
    private var coverTask: Task<Void, Never>?
    private var coverArtwork: MPMediaItemArtwork?
    private lazy var defaultArtwork = UIImage(named: "BrandIcon").map(Self.artwork(for:))
    private var bookName = ""
    private var chapterTitle = ""
    private var author = ""

    init(engine: AVAudioEngine = AVAudioEngine(),
         loadAudio: @escaping @Sendable (String, ListeningVoice) async throws -> Data = ListeningEngine.audio) {
        self.engine = engine
        self.loadAudio = loadAudio
        super.init()
    }

    deinit {
        coverTask?.cancel()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
    }

    func startListening(to reader: ReaderViewModel, at position: Int, voice: ListeningVoice,
                        library: BookLibraryModel, rules: ReplaceRuleLibraryModel) {
        clearListeningSession()
        listeningReader = ReaderViewModel(copying: reader, position: position)
        self.library = library
        self.rules = rules
        errorBookURL = reader.book.bookUrl
        isPreparingAudio = true
        listeningChapter = reader.currentIndex
        listeningPosition = reader.paragraphs.last(where: { $0.id <= position })?.id ?? 0
        bookName = reader.book.name
        chapterTitle = reader.title
        author = reader.book.author
        let range = NSRange(location: listeningPosition, length: reader.content.utf16.count - listeningPosition)
        sleepTimer.start { [weak self] in self?.stop() }
        speak(reader.content, reading: range, voice: voice)
    }

    func moveChapter(_ direction: Int) {
        guard let reader = listeningReader,
              direction < 0 ? reader.canGoPrevious : reader.canGoNext else { return }
        saveListeningProgress()
        chapterTask?.cancel()
        chapterTask = nil
        stopCurrentPlayback()
        isPreparingAudio = true
        phrases = []
        phraseIndex = 0
        if direction < 0 { reader.goPrevious() } else { reader.goNext() }
        chapterTitle = reader.title
        listeningPosition = 0
        listeningChapter = reader.currentIndex
        saveListeningProgress()
        needsChapterAudio = true
        loadListeningChapter(reader)
    }

    private func beginPreparationTime() {
        guard preparationTaskID == .invalid else { return }
        preparationTaskID = UIApplication.shared.beginBackgroundTask(withName: "Prepare reader audio") { [weak self] in
            guard let self else { return }
            self.endPreparationTime()
            if self.isPreparingAudio, self.listeningReader != nil {
                self.pausePlayback()
            }
        }
    }

    private func endPreparationTime() {
        guard preparationTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(preparationTaskID)
        preparationTaskID = .invalid
    }

    private func loadListeningChapter(_ reader: ReaderViewModel) {
        isPaused = false
        isSpeaking = true
        isPreparingAudio = true
        beginPreparationTime()
        updateNowPlaying()
        guard chapterTask == nil else { return }
        chapterTask = Task {
            do {
                try await retryDownload {
                    let retry = reader.currentChapterError != nil
                    await reader.load(rules: rules?.rules ?? [], forceRefresh: retry, prefetchNextChapter: false)
                    if let message = reader.currentChapterError {
                        let failure = reader.diagnostics.first { $0.severity == .error }
                        throw ChapterLoadFailure(message: message, isRequestError: failure?.code == "content.request")
                    }
                }
            } catch {
                if !Task.isCancelled {
                    chapterTask = nil
                    pauseForRetry(error.localizedDescription)
                }
                return
            }
            guard !Task.isCancelled else { return }
            chapterTask = nil
            guard !reader.content.isEmpty, !reader.hasImageContent else {
                pauseForRetry("当前章节没有可朗读的正文。")
                return
            }
            guard !isPaused else { return }
            chapterTitle = reader.title
            let length = reader.content.utf16.count
            let start = min(listeningPosition, length)
            needsChapterAudio = false
            speak(reader.content, reading: NSRange(location: start, length: length - start), voice: listeningVoice)
        }
    }

    private func pauseForRetry(_ reason: String) {
        endPreparationTime()
        needsChapterAudio = true
        stopCurrentPlayback()
        isPreparingAudio = false
        isSpeaking = false
        isPaused = true
        saveListeningProgress()
        errorMessage = reason
        updateNowPlaying()
        DiagnosticLog.shared.record(.warning, category: "朗读", message: "已保留播放进度，可重试。 " + reason)
    }

    func saveListeningProgress() {
        guard let library, let reader = listeningReader, listeningChapter == reader.currentIndex,
              let chapter = reader.currentChapter else { return }
        let book = reader.book
        let position = listeningPosition
        Task { await library.updateProgress(for: book, chapter: chapter, position: position) }
    }

    func stop() {
        sleepTimer.end()
        clearListeningSession()
    }

    private func clearListeningSession() {
        saveListeningProgress()
        chapterTask?.cancel()
        chapterTask = nil
        listeningReader?.stopBackgroundReading()
        listeningReader = nil
        listeningChapter = nil
        library = nil
        rules = nil
        needsChapterAudio = false
        stopAudio()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
        remoteCommandTargets.removeAll()
    }

    private func stopAudio() {
        endPreparationTime()
        stopCurrentPlayback()
        isPreparingAudio = false
        coverTask?.cancel()
        coverTask = nil
        phrases = []
        phraseIndex = 0
        let hadPlayback = isSpeaking || isPaused || audioSessionActive
        isSpeaking = false
        isPaused = false
        resumesAfterInterruption = false
        if hadPlayback { updateNowPlaying() }
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    func updatePlaybackRate(_ setting: Int) {
        if bufferStartedAt != nil {
            elapsedInBuffer = currentBufferTime
            bufferStartedAt = ProcessInfo.processInfo.systemUptime
        }
        speechRate = setting
        speed.rate = Self.playbackRate(for: setting)
        if listeningReader != nil { updateNowPlaying() }
    }

    func configure(
        speechRate: Int,
        ignoresAudioFocus: Bool = false,
        pausesForPhoneCalls: Bool = false,
        mediaButtonPerNext: Bool = false,
        bookName: String = "",
        chapterTitle: String = "",
        author: String = "",
        coverAddress: String? = nil
    ) {
        self.speechRate = min(max(speechRate, 0), 45)
        self.ignoresAudioFocus = ignoresAudioFocus
        self.pausesForPhoneCalls = pausesForPhoneCalls
        self.mediaButtonPerNext = mediaButtonPerNext
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        self.author = author
        if self.coverAddress != coverAddress {
            coverTask?.cancel()
            coverTask = nil
            coverArtwork = nil
            self.coverAddress = coverAddress
        }
    }

    func speak(_ text: String, reading range: NSRange? = nil, voice: ListeningVoice = ListeningVoice.preferred) {
        if notificationTokens.isEmpty {
            observeAudioSession()
            installRemoteCommands()
        }
        stopCurrentPlayback()
        phraseIndex = 0
        phrases = []
        isPreparingAudio = true
        errorMessage = nil
        listeningVoice = voice
        chapterLength = text.utf16.count
        isPaused = false
        isSpeaking = true
        firstPosition = range?.location ?? 0
        synthesizedEnd = firstPosition
        synthesizedCharacters = 0
        synthesizedFrames = 0
        beginPreparationTime()
        updateNowPlaying()
        let title = chapterTitle
        playbackTask = Task {
            let passages = await Self.preparePassages(text, range: range, title: title)
            guard !Task.isCancelled else { return }
            guard !passages.isEmpty else {
                finishNaturally()
                return
            }
            phrases = passages
            guard isPaused || audioSessionActive || activateAudioSession() else { return }
            playCurrentAudioSegment(paused: isPaused)
            loadCoverIfNeeded()
        }
    }

    private nonisolated static func preparePassages(_ text: String, range: NSRange?, title: String) async -> [SpokenPassage] {
        SpokenPassage.chapterPassages(in: text, reading: range, title: title)
    }

    func pauseOrResume() {
        if isPaused { resumePlayback() }
        else if isSpeaking { pausePlayback() }
    }

    func changeVoice(to voice: ListeningVoice) {
        guard isSpeaking || isPaused, voice != listeningVoice else { return }
        listeningVoice = voice
        guard !phrases.isEmpty, !needsChapterAudio else { return }
        handoff?.firstAudio?.cancel()
        if let current = queue.first, bufferStartedAt != nil || elapsedInBuffer > 0 || node.isPlaying {
            // Keep the audible buffer intact and prepare its successor using the newly selected voice.
            playbackTask?.cancel()
            wakeDownload()
            let next = current.passage + 1
            let audio: Task<Data, Error>?
            if phrases.indices.contains(next) {
                let text = String(phrases[next].synthesisText)
                audio = Task { [loadAudio] in try await loadAudio(text, voice) }
            } else {
                audio = nil
            }
            handoff = VoiceHandoff(afterPassage: current.passage, firstAudio: audio)
            isChangingVoice = true
        } else {
            resumeWithSelectedVoice(at: queue.first?.passage ?? nextUnheardPassage, firstAudio: nil)
        }
    }

    private func resumeWithSelectedVoice(at index: Int, firstAudio: Task<Data, Error>?) {
        let paused = isPaused
        handoff = nil
        stopCurrentPlayback()
        guard phrases.indices.contains(index) else {
            firstAudio?.cancel()
            finishNaturally()
            return
        }
        phraseIndex = index
        listeningPosition = phrases[index].position
        isChangingVoice = true
        playCurrentAudioSegment(paused: paused, firstAudio: firstAudio)
    }

    func clearError() { errorMessage = nil }

    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: ignoresAudioFocus ? [.mixWithOthers] : [])
            try? session.setPrefersNoInterruptionsFromSystemAlerts(ignoresAudioFocus && !pausesForPhoneCalls)
            try session.setActive(true)
            audioSessionActive = true
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func pausePlayback() {
        resumesAfterInterruption = false
        guard isSpeaking else { return }
        endPreparationTime()
        elapsedInBuffer = currentBufferTime
        bufferStartedAt = nil
        renderStartTask?.cancel()
        renderStartTask = nil
        node.pause()
        saveListeningProgress()
        isPreparingAudio = false
        isPaused = true
        isSpeaking = false
        updateNowPlaying()
    }

    private func resumePlayback() {
        resumesAfterInterruption = false
        guard isPaused else { return }
        if needsChapterAudio, chapterTask == nil, let reader = listeningReader {
            errorMessage = nil
            loadListeningChapter(reader)
            return
        }
        isPaused = false
        isSpeaking = true
        isPreparingAudio = true
        wakeDownload()
        beginPreparationTime()
        tryPlayQueuedAudio()
        updateNowPlaying()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleAudioInterruption(type: type, options: options) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
    }

    private func handleAudioInterruption(type raw: UInt?, options rawOptions: UInt) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard isSpeaking || isPaused else { return }
            audioSessionActive = false
            let wasPlaying = isSpeaking
            let sample = bufferStartedAt != nil || node.isPlaying ? renderedSample : nil
            if wasPlaying { pausePlayback() }
            if !needsRescheduling {
                if let sample, sample > headSampleTime, let first = queue.first, wasPlaying {
                    let frames = min(Int64(first.frames), sample - headSampleTime)
                    elapsedInBuffer = Double(frames) / format.sampleRate
                }
                // Stopping a node also fires callbacks for unheard buffers.
                scheduleID &+= 1
                needsRescheduling = true
                node.stop()
            }
            if wasPlaying { resumesAfterInterruption = true }
        case .ended:
            let shouldResume = resumesAfterInterruption &&
                AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            resumesAfterInterruption = false
            if shouldResume { resumePlayback() }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        pausePlayback()
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        addRemoteTarget(center.playCommand) { $0.resumePlayback() }
        addRemoteTarget(center.pauseCommand) { $0.pausePlayback() }
        addRemoteTarget(center.togglePlayPauseCommand) { controller in
            controller.isPaused ? controller.resumePlayback() : controller.pausePlayback()
        }
        addRemoteTarget(center.stopCommand) { controller in
            controller.stop()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.skipForward() }
        addRemoteTarget(center.previousTrackCommand) { $0.skipBackward() }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (ReaderSpeechController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func skipForward() {
        if mediaButtonPerNext {
            moveChapter(1)
        } else if phraseIndex + 1 < phrases.count {
            stopCurrentPlayback()
            phraseIndex += 1
            playCurrentAudioSegment()
        } else {
            moveChapter(1)
        }
    }

    private func skipBackward() {
        if mediaButtonPerNext {
            moveChapter(-1)
        } else if phraseIndex > 0 {
            stopCurrentPlayback()
            phraseIndex -= 1
            playCurrentAudioSegment()
        } else {
            moveChapter(-1)
        }
    }

    private func stopCurrentPlayback() {
        handoff?.firstAudio?.cancel()
        handoff = nil
        isChangingVoice = false
        renderStartTask?.cancel()
        renderStartTask = nil
        generation &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        wakeDownload()
        node.stop()
        engine.stop()
        queue.removeAll()
        headSampleTime = 0
        needsRescheduling = false
        queuedFrames = 0
        bufferStartedAt = nil
        elapsedInBuffer = 0
        producerFinished = false
        waitingForReserve = true
        reserveSeconds = 6
        spokenText = nil
        spokenPosition = nil
    }

    nonisolated private static func artwork(for image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { size in
            guard size.width > 0, size.height > 0 else { return image }
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                      width: width, height: height))
            }
        }
    }

    private func loadCoverIfNeeded() {
        guard coverArtwork == nil, let coverAddress, !coverAddress.isEmpty else { return }
        coverTask = Task { [weak self] in
            guard let image = await BookCoverImage.thumbnail(for: coverAddress),
                  !Task.isCancelled, let self, self.audioSessionActive else { return }
            self.coverArtwork = Self.artwork(for: image)
            self.updateNowPlaying()
        }
    }

    private var currentBufferTime: TimeInterval {
        let interval = bufferStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        return min(Double(queue.first?.frames ?? 0) / format.sampleRate,
                   elapsedInBuffer + interval * Double(speed.rate))
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard isSpeaking || isPaused else {
            center.nowPlayingInfo = nil
            return
        }
        // PCM lengths are exact. Only the text outside the synthesized span needs an estimate.
        let start = Double(firstPosition) * estimatedSecondsPerCharacter
        let generated = Double(synthesizedFrames) / format.sampleRate
        let remaining = max(0, chapterLength - synthesizedEnd)
        let secondsPerCharacter = synthesizedCharacters > 0
            ? generated / Double(synthesizedCharacters) : estimatedSecondsPerCharacter
        let duration = start + generated + Double(remaining) * secondsPerCharacter
        let elapsed = start + Double(synthesizedFrames - queuedFrames) / format.sampleRate + currentBufferTime
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle.isEmpty ? (bookName.isEmpty ? "正在朗读" : bookName) : chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookName,
            MPMediaItemPropertyArtist: [bookName, author].filter { !$0.isEmpty }.joined(separator: " · "),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: bufferStartedAt == nil ? 0.0 : Double(speed.rate)
        ]
        info[MPMediaItemPropertyArtwork] = coverArtwork ?? defaultArtwork
        center.nowPlayingInfo = info
    }

    private func playCurrentAudioSegment(paused: Bool = false, firstAudio: Task<Data, Error>? = nil) {
        nextUnheardPassage = phraseIndex
        guard phrases.indices.contains(phraseIndex) else {
            stop()
            return
        }
        isPreparingAudio = !paused
        isPaused = paused
        isSpeaking = !paused
        firstPosition = phrases[phraseIndex].position
        synthesizedEnd = firstPosition
        synthesizedCharacters = 0
        synthesizedFrames = 0
        elapsedInBuffer = 0
        bufferStartedAt = nil
        updateNowPlaying()
        if !paused { beginPreparationTime() }
        let voice = listeningVoice
        let run = generation
        let start = phraseIndex
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                if node.engine == nil {
                    engine.attach(node)
                    engine.attach(speed)
                    engine.connect(node, to: speed, format: format)
                    engine.connect(speed, to: engine.mainMixerNode, format: format)
                }
                speed.rate = Self.playbackRate(for: speechRate)
                try await withTaskCancellationHandler {
                    try await prepareAudio(from: start, voice: voice, run: run, firstAudio: firstAudio)
                } onCancel: {
                    firstAudio?.cancel()
                }
                try Task.checkCancellation()
                producerFinished = true
                if queue.isEmpty { finishNaturally() }
                else { tryPlayQueuedAudio() }
            } catch {
                if !Task.isCancelled && generation == run { fail(error) }
            }
        }
    }

    private struct ChapterLoadFailure: LocalizedError {
        let message: String
        let isRequestError: Bool
        var errorDescription: String? { message }
    }

    private func wakeDownload() {
        downloadResume?.resume()
        downloadResume = nil
    }

    private func retryDownload<T>(_ request: () async throws -> T) async throws -> T {
        let delays: [UInt64] = [0, 1, 2, 4]
        var retries = 0
        while true {
            try Task.checkCancellation()
            if isPaused {
                await withCheckedContinuation { downloadResume = $0 }
                continue
            }
            do {
                return try await request()
            } catch {
                try Task.checkCancellation()
                let retryable = (error as? ChapterLoadFailure)?.isRequestError ?? ListeningEngine.isTemporaryFailure(error)
                guard retryable else { throw error }
                if retries == delays.count {
                    DiagnosticLog.shared.record(.warning, category: "朗读", message: "多次重连失败，已保留播放位置。 " + error.localizedDescription)
                    pausePlayback()
                    retries = 0
                } else {
                    let delay = delays[retries]
                    retries += 1
                    if delay > 0 { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                }
            }
        }
    }

    private func prepareAudio(from start: Int, voice: ListeningVoice, run: Int, firstAudio: Task<Data, Error>?) async throws {
        var prefetched = firstAudio
        let passages = phrases
        var index = start
        var measuredCharacters = 0
        var synthesisTime = 0.0
        var playbackTime = 0.0
        try await withThrowingTaskGroup(of: Void.self) { processing in
            while index < passages.count {
                try Task.checkCancellation()
                while isPaused || queuedPlaybackSeconds >= 48 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let end = SpokenPassage.groupEnd(in: passages, from: index)
                let group = passages[index..<end]
                let text = String(passages[index].synthesisText)
                let (pcm, downloadTime) = try await retryDownload {
                    let started = ProcessInfo.processInfo.systemUptime
                    let audio: Data
                    if let first = prefetched {
                        prefetched = nil
                        audio = try await first.value
                    } else {
                        audio = try await loadAudio(text, voice)
                    }
                    return (audio, ProcessInfo.processInfo.systemUptime - started)
                }
                try Task.checkCancellation()
                let padding = end < passages.count ? SpokenPassage.paragraphPaddingFrames(in: pcm) : 0
                let frames = pcm.count / MemoryLayout<Float>.size + padding
                measuredCharacters += text.count
                synthesisTime += downloadTime
                playbackTime += Double(frames) / (format.sampleRate * Double(speed.rate))
                let synthesisPerCharacter = synthesisTime / Double(measuredCharacters)
                let playbackPerCharacter = playbackTime / Double(measuredCharacters)

                // Queue groups in order while the next request is in flight.
                _ = try await processing.next()
                try Task.checkCancellation()
                processing.addTask { [self] in
                    try Task.checkCancellation()
                    var clips = SpokenPassage.splitAudio(pcm, for: group)
                    if padding > 0 { clips[clips.count - 1].append(Data(count: padding * MemoryLayout<Float>.size)) }
                    try await MainActor.run {
                        guard generation == run, !Task.isCancelled, handoff == nil else { throw CancellationError() }
                        if waitingForReserve {
                            reserveSeconds = SpokenPassage.playbackReserve(
                                in: passages, from: end, synthesisPerCharacter: synthesisPerCharacter,
                                playbackPerCharacter: playbackPerCharacter, recovering: synthesizedFrames > queuedFrames
                            )
                        }
                        for (index, clip) in zip(group.indices, clips) {
                            try enqueue(clip, passage: index, run: run)
                            let phrase = passages[index]
                            synthesizedCharacters += phrase.text.utf16.count
                            if !phrase.isChapterTitle { synthesizedEnd = phrase.position + phrase.text.utf16.count }
                        }
                        tryPlayQueuedAudio()
                    }
                }
                index = end
            }
            try await processing.waitForAll()
        }
    }

    private var queuedPlaybackSeconds: TimeInterval {
        max(0, Double(queuedFrames) / format.sampleRate - currentBufferTime) / Double(speed.rate)
    }

    private func enqueue(_ data: Data, passage: Int, run: Int) throws {
        let frames = data.count / MemoryLayout<Float>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        buffer.frameLength = buffer.frameCapacity
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: data.count))
        queue.append(QueuedAudio(passage: passage, buffer: buffer))
        queuedFrames += frames
        synthesizedFrames += frames
        if !needsRescheduling { schedule(buffer, run: run) }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, run: Int) {
        let id = scheduleID
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didPlayBuffer(run: run, scheduleID: id) }
        }
    }

    private func rescheduleInterruptedAudio() throws {
        guard needsRescheduling, let first = queue.first else { return }
        let offset = min(first.frames - 1, Int((elapsedInBuffer * format.sampleRate).rounded()))
        headSampleTime = -Int64(offset)
        if offset > 0 {
            let remaining = AVAudioFrameCount(first.frames - offset)
            guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining),
                  let output = tail.floatChannelData?[0], let input = first.buffer.floatChannelData?[0] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            tail.frameLength = remaining
            output.update(from: input + offset, count: Int(remaining))
            schedule(tail, run: generation)
        } else {
            schedule(first.buffer, run: generation)
        }
        for clip in queue.dropFirst() { schedule(clip.buffer, run: generation) }
        needsRescheduling = false
    }

    private func tryPlayQueuedAudio() {
        guard !isPaused, !queue.isEmpty else { return }
        if bufferStartedAt != nil, engine.isRunning, node.isPlaying {
            publishCurrentPassage()
            return
        }
        guard renderStartTask == nil else { return }
        isPreparingAudio = true
        guard !waitingForReserve || queuedPlaybackSeconds >= reserveSeconds || producerFinished else { return }
        waitingForReserve = false
        bufferStartedAt = nil
        renderStartTask = Task {
            // A route or session change during synthesis can leave a scheduled node without a running output.
            // Confirm that the player's sample clock advances before publishing a positive playback rate.
            for _ in 0..<2 {
                guard !Task.isCancelled, activateAudioSession() else { return }
                do {
                    try rescheduleInterruptedAudio()
                    if !engine.isRunning { try engine.start() }
                    let initial = renderedSample ?? 0
                    node.play()
                    for _ in 0..<30 {
                        try await Task.sleep(nanoseconds: 40_000_000)
                        if engine.isRunning, let sample = renderedSample, sample > initial {
                            renderStartTask = nil
                            bufferStartedAt = ProcessInfo.processInfo.systemUptime
                            endPreparationTime()
                            publishCurrentPassage()
                            updateNowPlaying()
                            return
                        }
                    }
                    node.pause()
                    engine.pause()
                } catch {
                    if !Task.isCancelled { fail(error) }
                    return
                }
            }
            pauseForRetry("音频输出未启动，请点播放重试。")
        }
    }

    private var renderedSample: AVAudioFramePosition? {
        guard let render = node.lastRenderTime else { return nil }
        return node.playerTime(forNodeTime: render)?.sampleTime
    }

    private func publishCurrentPassage() {
        guard let first = queue.first else { return }
        phraseIndex = first.passage
        let passage = phrases[phraseIndex]
        let target: ReaderSpokenText = passage.isChapterTitle ? .chapterTitle : .body(passage.sentence)
        let position = passage.isChapterTitle ? nil : passage.position
        if spokenText != target { spokenText = target }
        if let position { listeningPosition = position }
        if spokenPosition != position { spokenPosition = position }
        if isPreparingAudio { isPreparingAudio = false }
        if handoff == nil && isChangingVoice { isChangingVoice = false }
    }

    private func didPlayBuffer(run: Int, scheduleID: Int) {
        guard run == generation, scheduleID == self.scheduleID, engine.isRunning, !queue.isEmpty else { return }
        renderStartTask?.cancel()
        renderStartTask = nil
        endPreparationTime()
        let completed = queue.removeFirst()
        headSampleTime += Int64(completed.frames)
        nextUnheardPassage = completed.passage + 1
        if let handoff, handoff.afterPassage == completed.passage {
            resumeWithSelectedVoice(at: nextUnheardPassage, firstAudio: handoff.firstAudio)
            return
        }
        queuedFrames -= completed.frames
        elapsedInBuffer = 0
        bufferStartedAt = !queue.isEmpty && !isPaused ? ProcessInfo.processInfo.systemUptime : nil
        if !queue.isEmpty { tryPlayQueuedAudio() }
        else if producerFinished { finishNaturally() }
        else {
            node.pause()
            waitingForReserve = true
            isPreparingAudio = !isPaused
            if !isPaused { beginPreparationTime() }
        }
        if audioSessionActive { updateNowPlaying() }
    }

    private func fail(_ error: Error) {
        if listeningReader != nil {
            pauseForRetry(error.localizedDescription)
            return
        }
        stop()
        errorMessage = error.localizedDescription
    }

    private func finishNaturally() {
        if listeningReader?.canGoNext == true {
            moveChapter(1)
        } else {
            stop()
        }
    }
}
