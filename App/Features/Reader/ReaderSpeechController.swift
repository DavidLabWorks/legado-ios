@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparingAudio = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionCount = 0
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var spokenPosition: Int?
    private var audioSessionActive = false
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let speed = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var queue: [(passage: Int, frames: Int)] = []
    private var queuedFrames = 0
    private var waitingForReserve = true
    private var reserveSeconds = 6.0
    private var generation = 0
    private var producerFinished = false
    private var pack: OfflineVoicePack?
    private var playbackTask: Task<Void, Never>?
    private var phrases: [SpokenPassage] = []
    private var phraseIndex = 0
    private var offlineVoice = OfflineVoice.uncleFu
    static func playbackRate(for setting: Int) -> Float {
        min(2, max(0.5, (Float(setting) + 5) / 10))
    }

    private var speechRate = 5
    private var continuesAcrossChapters = false
    private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var resumesAfterInterruption = false
    private var ignoresAudioFocus = false
    private var pausesForPhoneCalls = false
    private var mediaButtonPerNext = false
    private var chapterLength = 0
    private var firstPosition = 0
    private var synthesizedEnd = 0
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
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onRemoteStop: (() -> Void)?

    deinit {
        coverTask?.cancel()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
    }

    func stop() {
        stopCurrentPlayback()
        coverTask?.cancel()
        coverTask = nil
        phrases = []
        phraseIndex = 0
        pack = nil
        continuesAcrossChapters = false
        isSpeaking = false
        isPaused = false
        resumesAfterInterruption = false
        if audioSessionActive {
            updateNowPlaying()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
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

    func speak(_ text: String, reading range: NSRange? = nil, continuesAcrossChapters: Bool = false, voice: OfflineVoice = .preferred, pack selectedPack: OfflineVoicePack? = OfflineVoicePack.selected) {
        stop()
        errorMessage = nil
        guard let selectedPack, selectedPack == .zipvoice, selectedPack.isInstalled else {
            errorMessage = "请先下载或导入 ZipVoice 离线语音包。"
            return
        }
        offlineVoice = selectedPack.resolve(voice)
        pack = selectedPack
        chapterLength = text.utf16.count
        phrases = SpokenPassage.passages(in: text, reading: range)
        guard !phrases.isEmpty else {
            if continuesAcrossChapters { completionCount += 1 }
            return
        }
        guard activateAudioSession() else { return }
        self.continuesAcrossChapters = continuesAcrossChapters
        isSpeaking = true
        playCurrentAudioSegment()
        loadCoverIfNeeded()
    }

    func pauseOrResume() {
        if isPaused { resumePlayback() }
        else if isSpeaking { pausePlayback() }
    }

    func clearError() { errorMessage = nil }

    private func activateAudioSession() -> Bool {
        if notificationTokens.isEmpty {
            observeAudioSession()
            installRemoteCommands()
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: ignoresAudioFocus ? [.mixWithOthers] : [])
            try session.setActive(true)
            audioSessionActive = true
            return true
        } catch {
            stop()
            errorMessage = "无法启用朗读音频（" + error.localizedDescription + "）"
            return false
        }
    }

    private func pausePlayback() {
        guard isSpeaking else { return }
        elapsedInBuffer = currentBufferTime
        bufferStartedAt = nil
        node.pause()
        isPreparingAudio = false
        isPaused = true
        isSpeaking = false
        updateNowPlaying()
    }

    private func resumePlayback() {
        guard isPaused, activateAudioSession() else { return }
        isPaused = false
        isSpeaking = true
        isPreparingAudio = queue.isEmpty
        do {
            if !engine.isRunning { try engine.start() }
            tryPlayQueuedAudio()
        } catch { fail(error) }
        updateNowPlaying()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: OfflineVoicePack.didRemove, object: nil, queue: .main) { [weak self] note in
            guard let value = note.object as? String else { return }
            Task { @MainActor in
                guard let self, self.pack?.rawValue == value else { return }
                self.stop()
                self.onRemoteStop?()
            }
        })
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
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            resumesAfterInterruption = isSpeaking
            if isSpeaking { pausePlayback() }
        case .ended:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumesAfterInterruption, options.contains(.shouldResume) { resumePlayback() }
            resumesAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        if isSpeaking { pausePlayback() }
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
            controller.onRemoteStop?()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.skipForward(usesChapterPreference: true) }
        addRemoteTarget(center.previousTrackCommand) { $0.skipBackward(usesChapterPreference: true) }
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

    func nextSegment() {
        guard isSpeaking || isPaused else { return }
        skipForward(usesChapterPreference: false)
    }

    func previousSegment() {
        guard isSpeaking || isPaused else { return }
        skipBackward(usesChapterPreference: false)
    }

    private func skipForward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onNextChapter?()
        } else if phraseIndex + 1 < phrases.count {
            stopCurrentPlayback()
            phraseIndex += 1
            playCurrentAudioSegment()
        } else {
            onNextChapter?()
        }
    }

    private func skipBackward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onPreviousChapter?()
        } else if phraseIndex > 0 {
            stopCurrentPlayback()
            phraseIndex -= 1
            playCurrentAudioSegment()
        } else {
            onPreviousChapter?()
        }
    }

    private func stopCurrentPlayback() {
        isPreparingAudio = false
        generation &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        node.stop()
        engine.stop()
        queue.removeAll()
        queuedFrames = 0
        producerFinished = false
        waitingForReserve = true
        reserveSeconds = 6
        spokenRange = nil
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
        let secondsPerCharacter = synthesizedEnd > firstPosition
            ? generated / Double(synthesizedEnd - firstPosition) : estimatedSecondsPerCharacter
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

    private func playCurrentAudioSegment() {
        guard phrases.indices.contains(phraseIndex) else {
            stop()
            return
        }
        isPreparingAudio = true
        isPaused = false
        isSpeaking = true
        firstPosition = phrases[phraseIndex].position
        synthesizedEnd = firstPosition
        synthesizedFrames = 0
        elapsedInBuffer = 0
        bufferStartedAt = nil
        updateNowPlaying()
        guard let pack else { return }
        let voice = offlineVoice
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
                try engine.start()
                try await prepareAudio(from: start, voice: voice, pack: pack, run: run)
                try Task.checkCancellation()
                producerFinished = true
                if queue.isEmpty { finishNaturally() }
                else { tryPlayQueuedAudio() }
            } catch {
                if !Task.isCancelled && generation == run { fail(error) }
            }
        }
    }

    private enum PreparedSpeech {
        case codes(OfflineSpeech.Passage)
        case pcm(Data)
    }

    private func prepareAudio(from start: Int, voice: OfflineVoice, pack: OfflineVoicePack, run: Int) async throws {
        let speech = OfflineSpeech.shared
        if pack == .zipvoice { await speech.unload() }
        else { await ZipVoiceSpeech.shared.unload() }
        var index = start
        try await withThrowingTaskGroup(of: Void.self) { decoding in
            while index < phrases.count {
                try Task.checkCancellation()
                while isPaused || queuedPlaybackSeconds >= 48 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let end = SpokenPassage.groupEnd(in: phrases, from: index, characterLimit: queuedPlaybackSeconds < 10 ? 24 : 60)
                let group = phrases[index..<end]
                let paragraphEnds = end < phrases.count && phrases[end - 1].paragraph != phrases[end].paragraph
                let started = ProcessInfo.processInfo.systemUptime
                let text = group.map(\.text).joined(separator: " ")
                let prepared: PreparedSpeech
                if pack == .zipvoice {
                    prepared = .pcm(try await ZipVoiceSpeech.shared.synthesize(text, voice: voice))
                } else {
                    prepared = .codes(try await speech.prepare(text, voice: voice, pack: pack))
                }
                // The preceding decode can play immediately. Wait for it before submitting
                // this one, so cached passages and retries cannot reorder the audio.
                _ = try await decoding.next()
                try Task.checkCancellation()
                decoding.addTask { [self] in
                    let audio: Data
                    switch prepared {
                    case .codes(let passage): audio = try await speech.decoder.decode(passage)
                    case .pcm(let samples): audio = samples
                    }
                    try Task.checkCancellation()
                    var clips = SpokenPassage.splitAudio(audio, for: group)
                    if paragraphEnds { SpokenPassage.finishParagraph(&clips[clips.count - 1]) }
                    try await MainActor.run {
                        guard generation == run else { throw CancellationError() }
                        if waitingForReserve {
                            let characters = Double(group.reduce(0) { $0 + $1.text.count })
                            let synthesis = ProcessInfo.processInfo.systemUptime - started
                            let playback = Double(audio.count / MemoryLayout<Float>.size) / (24_000 * Double(speed.rate))
                            if pack == .zipvoice, spokenRange == nil, end < phrases.count {
                                // Cover the next synthesis call, especially after a short opening line.
                                let nextEnd = SpokenPassage.groupEnd(in: phrases, from: end, characterLimit: 24)
                                let nextCharacters = phrases[end..<nextEnd].reduce(0) { $0 + $1.text.count }
                                reserveSeconds = min(9, max(2.5, synthesis * Double(nextCharacters) / characters * 1.35))
                            } else {
                                reserveSeconds = SpokenPassage.playbackReserve(
                                    in: phrases, from: end,
                                    synthesisPerCharacter: synthesis / characters,
                                    playbackPerCharacter: playback / characters,
                                    recovering: spokenRange != nil
                                )
                            }
                        }
                        for (index, clip) in zip(group.indices, clips) {
                            try enqueue(clip, passage: index, run: run)
                        }
                        tryPlayQueuedAudio()
                    }
                }
                index = end
            }
            try await decoding.waitForAll()
        }
    }

    private var queuedPlaybackSeconds: TimeInterval {
        Double(queuedFrames) / (24_000 * Double(speed.rate))
    }

    private func enqueue(_ data: Data, passage: Int, run: Int) throws {
        let frames = data.count / MemoryLayout<Float>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        buffer.frameLength = buffer.frameCapacity
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: data.count))
        queue.append((passage, frames))
        queuedFrames += frames
        synthesizedFrames += frames
        synthesizedEnd = phrases[passage].position + phrases[passage].text.utf16.count
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didPlayBuffer(run: run) }
        }
    }

    private func tryPlayQueuedAudio() {
        guard !isPaused, let first = queue.first else { return }
        if !node.isPlaying {
            guard !waitingForReserve || queuedPlaybackSeconds >= reserveSeconds || producerFinished else {
                isPreparingAudio = true
                return
            }
            waitingForReserve = false
            node.play()
            bufferStartedAt = ProcessInfo.processInfo.systemUptime
            updateNowPlaying()
        }
        phraseIndex = first.passage
        let passage = phrases[phraseIndex]
        if spokenRange != passage.sentence { spokenRange = passage.sentence }
        if spokenPosition != passage.position { spokenPosition = passage.position }
        if isPreparingAudio { isPreparingAudio = false }
    }

    private func didPlayBuffer(run: Int) {
        guard run == generation, !queue.isEmpty else { return }
        queuedFrames -= queue.removeFirst().frames
        elapsedInBuffer = 0
        bufferStartedAt = !queue.isEmpty && !isPaused ? ProcessInfo.processInfo.systemUptime : nil
        if !queue.isEmpty { tryPlayQueuedAudio() }
        else if producerFinished { finishNaturally() }
        else {
            node.pause()
            waitingForReserve = true
            isPreparingAudio = !isPaused
        }
        if audioSessionActive { updateNowPlaying() }
    }

    private func fail(_ error: Error) {
        stop()
        errorMessage = error.localizedDescription
    }

    private func finishNaturally() {
        let shouldContinue = continuesAcrossChapters
        stop()
        if shouldContinue { completionCount += 1 }
    }
}
