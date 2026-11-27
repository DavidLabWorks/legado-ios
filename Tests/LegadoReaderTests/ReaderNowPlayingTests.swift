import AVFoundation
import Combine
import MediaPlayer
import XCTest
@testable import Legado

@MainActor
final class ReaderNowPlayingTests: XCTestCase {
    func testLiveLibreTTSPlaybackVerification() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEGADO_LIVE_LIBRETTS"] == "1", "需要启用在线语音服务测试")
        try await checkLivePlayback(.libreTTS)
    }

    func testLiveCommunityPlaybackVerification() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEGADO_LIVE_COMMUNITY_TTS"] == "1", "需要启用在线语音服务测试")
        for engine in [ListeningEngine.edgeOne, .pptBoard] {
            try await checkLivePlayback(engine)
        }
    }

    func testLiveFengwmAndWanxiangPlayback() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LEGADO_LIVE_FENGWM_WANXIANG"] == "1")
        for engine in [ListeningEngine.fengwmEdge, .fengwmAzure, .fengwmVolcengine, .wanxiang] {
            try await checkLivePlayback(engine, voiceID: engine.defaultVoices[1].id)
        }
    }

    private func checkLivePlayback(_ provider: ListeningEngine, voiceID: String = ListeningEngine.yunxi.id) async throws {
        let voices = try await provider.voices()
        XCTAssertTrue(voices.contains { $0.id == voiceID })
        let engine = AVAudioEngine()
        let speech = ReaderSpeechController(engine: engine)
        let sound = expectation(description: "在线音频已到达播放器")
        Self.observeFirstSound(engine.mainMixerNode, sound: sound)
        defer {
            speech.stop()
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        speech.speak("小船驶过桥洞。窗外下起了小雨。", voice: ListeningVoice(engine: provider, id: voiceID))
        await fulfillment(of: [sound], timeout: 60)
        XCTAssertNil(speech.errorMessage)
    }

    func testLibreVoiceCatalogAndSavedSelectionUseChineseAndEnglish() throws {
        let locales = ["fr-FR", "en-US", "zh-TW", "wuu-CN", "zh-CN", "ja-JP", "yue-CN", "en-GB"]
        let catalog = locales.map { ["Locale": $0, "LocalName": $0, "ShortName": $0 + "-Voice"] }
        let voices = try ListeningEngine.libreTTS.decodeVoices(JSONEncoder().encode(catalog))
        XCTAssertEqual(voices.map(\.locale), ["wuu-CN", "yue-CN", "zh-CN", "zh-TW", "en-GB", "en-US"])
        for voice in voices { XCTAssertEqual(ListeningEngine.libreTTS.supportedVoiceID(voice.id), voice.id) }
        XCTAssertEqual(ListeningEngine.libreTTS.supportedVoiceID("ja-JP-NanamiNeural"), ListeningEngine.xiaoxiao.id)
    }

    func testCommunityVoiceCatalogs() throws {
        let ppt = #"[{"Locale":"zh-CN","ShortName":"zh-CN-YunxiNeural"},{"Locale":"en-US","ShortName":"en-US-JennyNeural"}]"#
        let pptVoices = try ListeningEngine.pptBoard.decodeVoices(Data(ppt.utf8))
        XCTAssertEqual(pptVoices.map(\.name), ["云希", "Jenny"])
        let edge = "{ value: 'zh-CN-sichuan-YunxiNeural', name: '云希', desc: '四川话' }, { value: 'en-US-GuyNeural', name: 'Guy' }"
        let edgeVoices = try ListeningEngine.edgeOne.decodeVoices(Data(edge.utf8))
        XCTAssertEqual(edgeVoices.map(\.name), ["云希（四川话）", "Guy"])
        XCTAssertEqual(edgeVoices.map(\.locale), ["zh-CN", "en-US"])
        XCTAssertThrowsError(try ListeningEngine.edgeOne.decodeVoices(Data("<html/>".utf8)))
    }

    func testProviderVoiceIdentifiersRemainSelectable() throws {
        let fire = #"{"provider":"volcengine","voices":[{"voice_name":"zh_female_story","label":"少儿故事 中英混"},{"voice_name":"jp_female_hana","label":"温柔女声 日语"}]}"#
        let voices = try ListeningEngine.fengwmVolcengine.decodeVoices(Data(fire.utf8))
        XCTAssertEqual(voices.map(\.locale), ["zh-CN", "ja"])
        XCTAssertEqual(ListeningEngine.fengwmVolcengine.supportedVoiceID(voices[1].id), "jp_female_hana")
        XCTAssertThrowsError(try ListeningEngine.fengwmEdge.decodeVoices(Data(fire.utf8)))
        let wanxiang = #"{"data":{"voices":[{"voice":"zh-HK-HiuGaaiNeural","name":"曉佳"}]}}"#
        let voice = try XCTUnwrap(ListeningEngine.wanxiang.decodeVoices(Data(wanxiang.utf8)).first)
        XCTAssertEqual(voice, .init(id: "zh-HK-HiuGaaiNeural", name: "曉佳", locale: "zh-HK"))
    }

    func testWanxiangParagraphsFitTheServiceLimitWithoutDroppingText() {
        let atLimit = String(repeating: "雨", count: 1_500)
        XCTAssertEqual(ListeningEngine.wanxiang.synthesisChunks(atLimit), [atLimit[...]])
        let text = String(repeating: "窗外下着雨。👩🏽‍💻", count: 400)
        let chunks = ListeningEngine.wanxiang.synthesisChunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { (1...1_500).contains($0.unicodeScalars.count) })
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertEqual(ListeningEngine.libreTTS.synthesisChunks(text), [text[...]])
    }

    private nonisolated static func sampleAudio(text: String, voice: ListeningVoice) async throws -> Data {
        let samples = (0..<24_000).map { Float(sin(Double($0) * 0.03) * 0.02) }
        return samples.withUnsafeBytes { Data($0) }
    }

    func testContinuousPlaybackAcrossUnevenParagraphs() async throws {
        let speech = ReaderSpeechController(loadAudio: Self.sampleAudio)
        defer { speech.stop() }
        speech.configure(speechRate: 15)
        let text = """
        推开窗户的时候他看见街上的人已经渐渐多了起来外面又下起了小雨。
        好。
        书上记着从1998年到2025年这二十八年间运到河对岸那家小店的旧书一共有32548本其中有12468本至今仍然收藏在镇上的图书馆里。
        """
        speech.speak(text)
        let start = ProcessInfo.processInfo.systemUptime
        var firstAudio: TimeInterval?
        var pauses = [TimeInterval]()
        var positions = Set<Int>()
        while speech.isSpeaking && ProcessInfo.processInfo.systemUptime - start < 60 {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if let position = speech.spokenPosition { positions.insert(position) }
            if speech.isPreparingAudio {
                if firstAudio != nil && pauses.isEmpty { pauses.append(elapsed) }
            } else if firstAudio == nil {
                firstAudio = elapsed
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(speech.errorMessage)
        XCTAssertEqual(positions.count, 3)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertTrue(pauses.isEmpty, "段落间重新缓冲，距起播请求 \(pauses) 秒")
        if let firstAudio {
            XCTContext.runActivity(named: String(format: "首次出声 %.2f 秒", firstAudio)) { _ in }
        }
    }

    func testSynthesisRequestsContainOneOriginalParagraphEach() async throws {
        let paragraphs = [String(repeating: "天亮了，风还没有停。  ", count: 8) + "他推开门。",
                          "“走吧！”她说。"]
        let requests = InterruptedAudioRequests(failingText: "", failures: 0)
        let speech = ReaderSpeechController { text, voice in
            try await requests.record(text)
            return try await Self.sampleAudio(text: text, voice: voice)
        }
        defer { speech.stop() }
        speech.speak(paragraphs.joined(separator: "\r\n\r\n"))
        for _ in 0..<120 where speech.isSpeaking {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let calls = await requests.calls
        XCTAssertEqual(calls, paragraphs)
        XCTAssertNil(speech.errorMessage)
        XCTAssertFalse(speech.isSpeaking)
    }

    func testChangingVoiceUsesOnlyUnreadPassagesAndKeepsPauseState() async throws {
        let original = ListeningVoice(engine: .libreTTS, id: "one")
        let selected = ListeningVoice(engine: .edgeOne, id: "two")
        for pauseBeforeChoosing in [false, true] {
            let calls = InterruptedAudioRequests(failingText: "", failures: 0)
            let speech = ReaderSpeechController { text, voice in
                try await calls.record(voice.id + text)
                return try await Self.sampleAudio(text: text, voice: voice)
            }
            var positions = [Int]()
            let observation = speech.$spokenPosition.compactMap { $0 }.sink { positions.append($0) }
            defer { observation.cancel(); speech.stop() }
            let text = pauseBeforeChoosing ? "第一句。\n第二句。\n第三句。" : "第一句。第二句。\n第三句。"
            speech.speak(text, voice: original)
            for _ in 0..<150 where speech.spokenPosition == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(speech.spokenPosition, 0)
            if pauseBeforeChoosing { speech.pauseOrResume() }
            speech.changeVoice(to: selected)
            XCTAssertTrue(speech.isChangingVoice)
            XCTAssertEqual(speech.isPaused, pauseBeforeChoosing)
            if pauseBeforeChoosing {
                try await Task.sleep(nanoseconds: 120_000_000)
                XCTAssertEqual(positions, [0])
                speech.pauseOrResume()
            }
            for _ in 0..<200 where speech.isSpeaking { try await Task.sleep(nanoseconds: 30_000_000) }
            let requests = await calls.calls
            XCTAssertEqual(requests.filter { $0.hasPrefix("two") }, ["two第二句。", "two第三句。"])
            XCTAssertEqual(positions, pauseBeforeChoosing ? [0, 5, 10] : [0, 4, 9])
            XCTAssertNil(speech.errorMessage)
        }
    }

    func testVoiceChangedWhileBufferingUsesLatestSelectionAtFirstPassage() async throws {
        let calls = InterruptedAudioRequests(failingText: "", failures: 0)
        let speech = ReaderSpeechController { text, voice in
            try await calls.record(voice.id + text)
            if voice.id != "latest" { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return try await Self.sampleAudio(text: text, voice: voice)
        }
        defer { speech.stop() }
        speech.speak("开头。", voice: .init(engine: .edgeOne, id: "old"))
        for _ in 0..<100 {
            if !(await calls.calls).isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        speech.changeVoice(to: .init(engine: .edgeOne, id: "intermediate"))
        speech.changeVoice(to: .init(engine: .pptBoard, id: "latest"))
        for _ in 0..<150 where speech.spokenPosition == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(speech.spokenPosition, 0)
        let requests = await calls.calls
        XCTAssertEqual(requests.last, "latest开头。")
        XCTAssertFalse(speech.isChangingVoice)
        XCTAssertNil(speech.errorMessage)
    }

    func testNetworkLossRetriesOnlyMissingAudioAndPlaysEachPassageOnce() async throws {
        let lines = ["第一句。", "第二句。", "最后一句。"]
        let requests = InterruptedAudioRequests(failingText: lines[1], failures: 2)
        let (playbackStarted, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let speech = ReaderSpeechController { text, voice in
            if text == lines[1] {
                for await _ in playbackStarted { }
            }
            try await requests.record(text)
            return try await Self.sampleAudio(text: text, voice: voice)
        }
        defer { speech.stop() }
        var positions = [Int]()
        let observation = speech.$spokenPosition.compactMap { $0 }.sink { position in
            positions.append(position)
            if position == 0 { signal.finish() }
        }
        defer { observation.cancel() }
        speech.speak(lines.joined(separator: "\n"))
        for _ in 0..<240 where speech.isSpeaking {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let calls = await requests.calls
        XCTAssertEqual(calls, [lines[0], lines[1], lines[1], lines[1], lines[2]])
        XCTAssertEqual(positions, [0, 5, 10])
        XCTAssertNil(speech.errorMessage)
        XCTAssertFalse(speech.isSpeaking)
    }

    func testRetryLimitPausesSilentlyAndPlayContinuesWithMissingAudio() async throws {
        let lines = ["雨停了。", "天亮了。"]
        let requests = InterruptedAudioRequests(failingText: lines[1], failures: 5)
        let speech = ReaderSpeechController { text, voice in
            try await requests.record(text)
            return try await Self.sampleAudio(text: text, voice: voice)
        }
        defer { speech.stop() }
        var positions = [Int]()
        let observation = speech.$spokenPosition.compactMap { $0 }.sink { positions.append($0) }
        defer { observation.cancel() }
        speech.speak(lines.joined(separator: "\n"))
        for _ in 0..<240 where speech.isSpeaking {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(speech.isPaused)
        XCTAssertNil(speech.errorMessage)
        let beforeResume = await requests.calls
        XCTAssertEqual(beforeResume, [lines[0]] + Array(repeating: lines[1], count: 5))
        speech.pauseOrResume()
        for _ in 0..<140 where speech.isSpeaking {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let afterResume = await requests.calls
        XCTAssertEqual(afterResume, beforeResume + [lines[1]])
        XCTAssertEqual(positions, [0, 5])
        XCTAssertFalse(speech.isSpeaking)
    }

    func testStoppingDuringRetryCancelsTheOldDownload() async throws {
        let requests = InterruptedAudioRequests(failingText: "旧章节。", failures: 5)
        let speech = ReaderSpeechController { text, voice in
            try await requests.record(text)
            return try await Self.sampleAudio(text: text, voice: voice)
        }
        defer { speech.stop() }
        speech.speak("旧章节。")
        for _ in 0..<100 {
            if await requests.calls.count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        speech.stop()
        speech.speak("新章节。")
        for _ in 0..<120 where speech.isSpeaking {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let calls = await requests.calls
        XCTAssertEqual(calls, ["旧章节。", "旧章节。", "新章节。"])
        XCTAssertNil(speech.errorMessage)
    }

    func testFailedNextChapterKeepsPlayerAndRetriesSameChapter() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = BookSource(bookSourceUrl: "https://fixture.test", bookSourceName: "测试")
        let book = Book(bookUrl: "fixture://book", name: "测试书", origin: source.id)
        let chapters = (0..<2).map { BookChapter(url: "fixture://chapter/\($0)", title: "", bookUrl: book.bookUrl, index: $0) }
        let loader = RetryChapterLoader()
        let reader = ReaderViewModel(book: book, chapters: chapters, initialIndex: 0, source: source,
                                     service: loader, cache: ChapterContentCache(directory: folder))
        await reader.load(rules: [], prefetchNextChapter: false)
        let library = BookLibraryModel(repository: InMemoryBookRepository(), chapterRepository: InMemoryBookChapterRepository())
        let rules = ReplaceRuleLibraryModel(repository: InMemoryReplaceRuleRepository())
        let speech = ReaderSpeechController(loadAudio: Self.sampleAudio)
        defer { speech.stop() }
        let playerAppearance = speech.$listeningChapter.compactMap { $0 }.sink { _ in
            XCTAssertTrue(speech.isPreparingAudio, "迷你播放器出现时就应显示加载动画")
        }
        defer { playerAppearance.cancel() }
        speech.startListening(to: reader, at: 0, voice: ListeningVoice(engine: .libreTTS, id: ListeningEngine.xiaoxiao.id), library: library, rules: rules)
        var heardSecondChapter = false
        for _ in 0..<200 where speech.listeningBook != nil {
            if speech.listeningChapter == 1, speech.spokenPosition != nil { heardSecondChapter = true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(heardSecondChapter)
        XCTAssertNil(speech.errorMessage)
        XCTAssertNil(speech.listeningBook)
    }

    func testSustainedPlaybackOfShortDialogue() async throws {
        try await checkSustainedDialogue(setting: 6)
    }

    func testSustainedPlaybackOfShortDialogueAtDoubleSpeed() async throws {
        try await checkSustainedDialogue(setting: 15)
    }

    private func checkSustainedDialogue(setting: Int) async throws {
        let speech = ReaderSpeechController(loadAudio: Self.sampleAudio)
        defer { speech.stop() }
        speech.configure(speechRate: setting)
        let lines = ["真的？", "你等等。", "听见了吗？", "是风声。", "再听听。", "我去看看。", "小心点。", "知道了。"]
        let chapter = (0..<96).map { lines[$0 % lines.count] }.joined(separator: "\n")
        speech.speak(chapter)
        let start = ProcessInfo.processInfo.systemUptime
        var firstAudio: TimeInterval?
        var buffering = true
        var stalls: [TimeInterval] = []
        var positions = Set<Int>()
        var backgroundPositions = Set<Int>()
        while speech.isSpeaking, ProcessInfo.processInfo.systemUptime - start < 200 {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if let position = speech.spokenPosition {
                positions.insert(position)
                if UIApplication.shared.applicationState == .background { backgroundPositions.insert(position) }
            }
            if speech.isPreparingAudio != buffering {
                buffering = speech.isPreparingAudio
                if buffering { stalls.append(elapsed) }
                else if firstAudio == nil { firstAudio = elapsed }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("Dialogue playback", ReaderSpeechController.playbackRate(for: setting), "first", firstAudio ?? -1, "stalls", stalls,
              "positions", positions.count, "in background", backgroundPositions.count, "elapsed", ProcessInfo.processInfo.systemUptime - start)
        XCTAssertNil(speech.errorMessage)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(positions.count, 96)
        XCTAssertTrue(stalls.isEmpty, "朗读中途重新缓冲 \(stalls)")
    }

    func testPauseWhilePreparingFirstPassage() async throws {
        let speech = ReaderSpeechController(loadAudio: Self.sampleAudio)
        defer { speech.stop() }
        speech.speak("窗外下起了小雨。")
        XCTAssertTrue(speech.isPreparingAudio)
        speech.pauseOrResume()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(speech.isPaused)
        XCTAssertFalse(speech.isPreparingAudio)
        XCTAssertNil(speech.spokenText)
        speech.pauseOrResume()
        XCTAssertTrue(speech.isPreparingAudio)
        for _ in 0..<150 where speech.isPreparingAudio { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(speech.spokenText)
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType, mayResume: Bool = false) async throws {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                       AVAudioSessionInterruptionOptionKey: mayResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testSystemInterruptionPausesAndResumesBufferedSpeech() async throws {
        let engine = AVAudioEngine()
        let speech = ReaderSpeechController(engine: engine) { text, _ in
            // Only the first 150 ms of the chapter contains a loud tone.
            let samples = (0..<24_000).map { frame in
                let level = text == "第一句。" && frame < 3_600 ? 0.5 : 0.02
                return Float(sin(Double(frame) * 0.03) * level)
            }
            return samples.withUnsafeBytes { Data($0) }
        }
        var positions = [Int]()
        let observer = speech.$spokenPosition.compactMap { $0 }.sink { positions.append($0) }
        defer { observer.cancel(); speech.stop() }
        speech.configure(speechRate: 5, ignoresAudioFocus: true)
        speech.speak("第一句。\n第二句。\n第三句。")
        for _ in 0..<150 where speech.spokenPosition == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(positions, [0])
        try await Task.sleep(nanoseconds: 350_000_000)
        engine.pause()
        try await postInterruption(.began)
        XCTAssertTrue(speech.isPaused)
        XCTAssertFalse(speech.isSpeaking)
        let rateKey = MPNowPlayingInfoPropertyPlaybackRate
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[rateKey] as? Double, 0)
        try await postInterruption(.began)
        let audible = expectation(description: "续播输出剩余音频")
        audible.assertForOverFulfill = false
        let replayed = expectation(description: "已听过的开头再次出声")
        replayed.isInverted = true
        Self.observeResumedSound(engine.mainMixerNode, audible: audible, replayed: replayed)
        defer { engine.mainMixerNode.removeTap(onBus: 0) }
        try await postInterruption(.ended, mayResume: true)
        await fulfillment(of: [audible, replayed], timeout: 1)
        for _ in 0..<200 where speech.isSpeaking { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(positions, [0, 5, 10])
        XCTAssertFalse(speech.isPaused)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertNil(speech.errorMessage)
    }

    private nonisolated static func observeResumedSound(_ mixer: AVAudioMixerNode, audible: XCTestExpectation,
                                                        replayed: XCTestExpectation) {
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            if samples.contains(where: { abs($0) > 0.2 }) { replayed.fulfill() }
            if samples.contains(where: { abs($0) > 0.003 }) { audible.fulfill() }
        }
    }

    func testInterruptionHonorsManualPauseAndSystemResumeHint() async throws {
        let speech = ReaderSpeechController(loadAudio: Self.sampleAudio)
        defer { speech.stop() }
        speech.speak("第一句。\n第二句。")
        for _ in 0..<150 where speech.spokenPosition == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        try await postInterruption(.began)
        try await postInterruption(.ended)
        XCTAssertTrue(speech.isPaused)
        speech.pauseOrResume()
        for _ in 0..<100 where speech.isPreparingAudio { try await Task.sleep(nanoseconds: 20_000_000) }
        speech.pauseOrResume()
        try await postInterruption(.began)
        try await postInterruption(.ended, mayResume: true)
        XCTAssertTrue(speech.isPaused)
        XCTAssertFalse(speech.isSpeaking)
    }

    func testFirstPlayRendersVoiceWithoutManualResume() async throws {
        let engine = AVAudioEngine()
        let speech = ReaderSpeechController(engine: engine, loadAudio: Self.sampleAudio)
        let sound = expectation(description: "混音器输出朗读语音")
        Self.observeFirstSound(engine.mainMixerNode, sound: sound)
        defer {
            speech.stop()
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        speech.speak("推开窗子，街上的人已经多了起来。")
        XCTAssertTrue(speech.isPreparingAudio)
        XCTAssertNil(speech.spokenText)
        // Let preparation begin, then simulate an engine suspended before the first buffer.
        await Task.yield()
        engine.pause()
        await fulfillment(of: [sound], timeout: 12)
        for _ in 0..<20 where speech.isPreparingAudio { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(engine.isRunning)
        XCTAssertFalse(speech.isPreparingAudio)
        XCTAssertNil(speech.errorMessage)
    }

    private nonisolated static func observeFirstSound(_ mixer: AVAudioMixerNode, sound: XCTestExpectation) {
        sound.assertForOverFulfill = false
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            if UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).contains(where: { abs($0) > 0.001 }) {
                sound.fulfill()
            }
        }
    }

    func testPublishesChapterBeforeFirstBufferAndTracksPlayback() async throws {
        let speech = ReaderSpeechController(loadAudio: Self.sampleAudio)
        defer { speech.stop() }
        let center = MPNowPlayingInfoCenter.default()
        let size = CGSize(width: 72, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        speech.configure(speechRate: 8, bookName: "测试书名", chapterTitle: "第一章", author: "作者",
                         coverAddress: "data:image/png;base64," + cover.base64EncodedString())
        let chapter = String(repeating: "窗外下起了小雨。\n", count: 10)
        speech.speak(chapter)
        XCTAssertTrue(speech.isSpeaking, speech.errorMessage ?? "")
        let info = try XCTUnwrap(center.nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "第一章")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "测试书名")
        XCTAssertNotNil(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertGreaterThan(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0, 0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        for _ in 0..<300 where speech.isPreparingAudio {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double), 1.3, accuracy: 0.001)
        XCTAssertEqual(speech.spokenText, .chapterTitle)
        XCTAssertNil(speech.spokenPosition)
        let artwork = try XCTUnwrap(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(artwork.bounds.size, size)
        XCTAssertEqual(artwork.image(at: CGSize(width: 48, height: 48))?.size, CGSize(width: 48, height: 48))
        try await Task.sleep(nanoseconds: 300_000_000)
        speech.pauseOrResume()
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertGreaterThan(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0, 0)
        speech.pauseOrResume()
        for _ in 0..<20 where speech.isPreparingAudio { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0, 0)
        for _ in 0..<100 where speech.spokenPosition == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(speech.spokenPosition, 0)
        XCTAssertEqual(speech.spokenText, .body((chapter as NSString).range(of: "窗外下起了小雨。")))
        speech.configure(speechRate: 5, bookName: "测试书名", chapterTitle: "第二章")
        speech.speak(chapter)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "第二章")
        speech.stop()
        XCTAssertNil(center.nowPlayingInfo)
    }
}

private actor RetryChapterLoader: ChapterContentLoading {
    private var failedOnce = false

    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?,
                     maxPages: Int) async -> ChapterContentReport {
        if chapter.index == 1, !failedOnce {
            failedOnce = true
            return .init(diagnostics: [.init(severity: .error, code: "content.request", message: "连接中断", rule: chapter.url)])
        }
        return .init(title: chapter.title, content: chapter.index == 0 ? "开始。" : "已经重新连上了。")
    }
}

private actor InterruptedAudioRequests {
    let failingText: String
    var failures: Int
    private(set) var calls = [String]()

    init(failingText: String, failures: Int) {
        self.failingText = failingText
        self.failures = failures
    }

    func record(_ text: String) throws {
        calls.append(text)
        if text == failingText, failures > 0 {
            failures -= 1
            throw URLError(.networkConnectionLost)
        }
    }
}
