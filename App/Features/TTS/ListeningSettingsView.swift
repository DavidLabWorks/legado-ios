@preconcurrency import AVFoundation
import SwiftUI

@MainActor
private final class VoicePreviewPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?

    private var loading: Task<Void, Never>?
    private var rate: Float = 1

    func play(engine: ListeningEngine, voice: ListeningEngine.Voice, rate: Float) {
        stop()
        errorMessage = nil
        self.rate = rate
        isPlaying = true
        loading = Task {
            do {
                let sample: String
                if voice.locale.hasPrefix("en") { sample = "I opened the window and heard the city waking up." }
                else if voice.locale.hasPrefix("ja") { sample = "窓を開けると、街の音が聞こえてきました。" }
                else { sample = "推开窗，街上的人已经多了起来。" }
                let url = try await engine.download(text: sample, voice: voice.id)
                defer { try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                startPlayer(url)
            } catch {
                guard !Task.isCancelled else { return }
                stop()
                errorMessage = "无法试听：" + error.localizedDescription
            }
        }
    }

    private func startPlayer(_ url: URL) {
        do {
            let audio = try AVAudioPlayer(data: Data(contentsOf: url))
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            audio.enableRate = true
            audio.rate = rate
            player = audio
            audio.delegate = self
            isPlaying = audio.play()
            if !isPlaying {
                stop()
                errorMessage = "试听播放失败，请重试。"
            }
        } catch {
            stop()
            errorMessage = "无法播放试听音频（" + error.localizedDescription + "）"
        }
    }

    func updateRate(_ rate: Float) { self.rate = rate; player?.rate = rate }

    func stop() {
        loading?.cancel()
        loading = nil
        isPlaying = false
        errorMessage = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        if !ReaderSpeechController.shared.isSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        stop()
        if !flag { errorMessage = "试听播放中断，请重试。" }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        stop()
        errorMessage = "试听音频解码失败。"
    }
}

@MainActor
final class ListeningSleepTimer: ObservableObject {
    @Published private(set) var minutes = 0
    private var remaining: TimeInterval = 0
    private var deadline: TimeInterval?
    private var task: Task<Void, Never>?
    private var onExpiry: (() -> Void)?
    private var paused = false

    deinit { task?.cancel() }

    func set(minutes: Int) {
        self.minutes = min(180, max(0, minutes))
        remaining = TimeInterval(self.minutes * 60)
        schedule()
    }

    func start(onExpiry: @escaping () -> Void) {
        guard self.onExpiry == nil else { return }
        self.onExpiry = onExpiry
        paused = false
        schedule()
    }

    func setPaused(_ paused: Bool) {
        guard onExpiry != nil, self.paused != paused else { return }
        self.paused = paused
        if let deadline {
            remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            // An elapsed deadline already has a stop pending on the main actor.
            guard remaining > 0 else { return }
            minutes = Int(ceil(remaining / 60))
        }
        schedule()
    }

    func end() {
        guard onExpiry != nil else { return }
        onExpiry = nil
        set(minutes: 0)
    }

    private func schedule() {
        task?.cancel()
        task = nil
        deadline = nil
        guard onExpiry != nil, !paused, remaining > 0 else { return }
        let end = ProcessInfo.processInfo.systemUptime + remaining
        deadline = end
        task = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(0, end - ProcessInfo.processInfo.systemUptime)
                let minutes = Int(ceil(seconds / 60))
                if self?.minutes != minutes { self?.minutes = minutes }
                guard seconds > 0 else { self?.onExpiry?(); return }
                let untilNextMinute = seconds - Double((minutes - 1) * 60)
                do { try await Task.sleep(nanoseconds: UInt64(untilNextMinute * 1_000_000_000)) }
                catch { return }
            }
        }
    }
}

struct ListeningSettingsPalette {
    let background: Color
    let card: Color

    static let settings = Self(background: ReadingTheme.settingsCanvas, card: ReadingTheme.surface)
    static let sheet = Self(background: ReadingTheme.sheetBackground, card: ReadingTheme.sheetCard)
}

struct ListeningSettingsView: View {
    let palette: ListeningSettingsPalette
    var showsVoiceEntry = true
    @State private var showsVoices = false

    var body: some View {
        List {
            if showsVoiceEntry {
                Button { showsVoices = true } label: {
                    HStack {
                        Label("声音引擎", systemImage: "waveform")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(palette.card)
            }
            ListeningMoreOptions().listRowBackground(palette.card)
        }
        .listStyle(.insetGrouped)
        .readingScrollContentBackgroundHidden()
        .background(palette.background)
        .sheet(isPresented: $showsVoices) { ListeningVoiceSheet() }
    }
}

struct ListeningVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    var playerBookURL: String?
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @State private var engine = ListeningVoice.preferred.engine
    @State private var draftVoices: [ListeningEngine: String] = [:]
    @StateObject private var preview = VoicePreviewPlayer()
    @State private var playerActive = ReaderSpeechController.shared.listeningBook != nil

    private var rate: Float { ReaderSpeechController.playbackRate(for: ttsSpeechRate) }

    private var editsActiveVoice: Bool {
        guard let book = ReaderSpeechController.shared.listeningBook else { return false }
        return playerBookURL == nil || playerBookURL == book.bookUrl
    }

    private func selection(for engine: ListeningEngine) -> Binding<String> {
        Binding {
            draftVoices[engine] ?? engine.supportedVoiceID(UserDefaults.standard.string(forKey: engine.voicePreferenceKey))
        } set: { id in
            draftVoices[engine] = id
        }
    }

    private func confirmVoice() {
        let voice = ListeningVoice(engine: engine, id: selection(for: engine).wrappedValue)
        preview.stop()
        let defaults = UserDefaults.standard
        defaults.set(voice.id, forKey: engine.voicePreferenceKey)
        defaults.set(engine.rawValue, forKey: ListeningEngine.preferenceKey)
        if editsActiveVoice { ReaderSpeechController.shared.changeVoice(to: voice) }
        dismiss()
    }

    @ViewBuilder private var settingsRows: some View {
        Section {
            Picker("朗读引擎", selection: $engine) {
                ForEach(ListeningEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityValue(engine.title)
            .accessibilityIdentifier("listening.engine")
        }
        Section {
            ListeningVoiceSection(engine: engine, rate: rate, isListening: playerActive, preview: preview,
                                  selectedVoiceID: selection(for: engine))
                .id(engine)
        } header: {
            Text("声音")
        } footer: {
            if editsActiveVoice {
                Text("确定后，从下一句开始使用所选音色。")
            }
        }
    }

    var body: some View {
        ReadingNavigationStack {
            List { settingsRows.listRowBackground(ReadingTheme.sheetCard) }
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.sheetBackground)
                .readingSheetTitle("声音引擎")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("取消") { dismiss() }
                        Button("确定", action: confirmVoice).font(.body.weight(.semibold))
                    }
                }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
        .tint(ReadingTheme.accent)
        .onChange(of: engine) { _ in preview.stop() }
        .onReceive(ReaderSpeechController.shared.$listeningChapter) { chapter in
            let active = chapter != nil
            guard playerActive != active else { return }
            playerActive = active
            if active && preview.isPlaying { preview.stop() }
        }
        .onChange(of: ttsSpeechRate) { setting in
            preview.updateRate(rate)
            if playerActive { ReaderSpeechController.shared.updatePlaybackRate(setting) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                preview.stop()
            }
        }
        .onDisappear { preview.stop() }
    }
}

private struct ListeningVoiceSection: View {
    let engine: ListeningEngine
    let rate: Float
    let isListening: Bool
    @ObservedObject var preview: VoicePreviewPlayer
    @Binding var selectedVoiceID: String
    @State private var voices: [ListeningEngine.Voice]
    @FocusState private var searchFocused: Bool
    @State private var voiceQuery = ""
    @State private var catalogLoading = false
    @State private var catalogError: String?
    @State private var catalogAttempt = 0

    private var selectedVoice: ListeningEngine.Voice {
        voices.first { $0.id == selectedVoiceID } ?? .init(id: selectedVoiceID, name: selectedVoiceID)
    }

    init(engine: ListeningEngine, rate: Float, isListening: Bool, preview: VoicePreviewPlayer,
         selectedVoiceID: Binding<String>) {
        _selectedVoiceID = selectedVoiceID
        self.engine = engine
        self.rate = rate
        self.isListening = isListening
        self.preview = preview
        _voices = State(initialValue: engine.defaultVoices)
    }

    var body: some View {
        HStack {
            ReadingPillSearchField(placeholder: "搜索声音或语言", text: $voiceQuery)
                .focused($searchFocused)
            if !isListening {
                Button {
                    if preview.isPlaying { preview.stop() }
                    else { preview.play(engine: engine, voice: selectedVoice, rate: rate) }
                } label: {
                    Image(systemName: preview.isPlaying ? "stop.fill" : "speaker.wave.2")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(preview.isPlaying ? "停止试听" : "试听")
                .accessibilityValue(selectedVoice.name)
            }
        }
        .task(id: catalogAttempt) {
            catalogError = nil
            catalogLoading = true
            defer { if !Task.isCancelled { catalogLoading = false } }
            do {
                let list = try await engine.voices()
                try Task.checkCancellation()
                voices = list
                if !list.contains(where: { $0.id == selectedVoiceID }), let first = list.first {
                    selectedVoiceID = first.id
                }
            } catch {
                if !Task.isCancelled { catalogError = "声音列表加载失败：" + error.localizedDescription }
            }
        }
        onlineVoiceRows
        if let error = preview.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
    }

    @ViewBuilder private var onlineVoiceRows: some View {
        let displayed = visibleVoices
        ForEach(displayed) { voice in
            Button {
                preview.stop()
                selectedVoiceID = voice.id
                searchFocused = false
            } label: {
                HStack {
                    Text(voice.name)
                    if !voice.locale.isEmpty { Text(voice.languageName).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if selectedVoiceID == voice.id {
                        Image(systemName: "checkmark").foregroundStyle(ReadingTheme.accent)
                    }
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("listening.voice." + voice.id)
            .accessibilityAddTraits(selectedVoiceID == voice.id ? .isSelected : [])
        }
        if displayed.isEmpty && !catalogLoading { Text("没有匹配的声音").foregroundStyle(.secondary) }
        if catalogLoading && voices.count <= 2 {
            ProgressView("正在加载声音列表")
        }
        if let catalogError {
            Text(catalogError).font(.footnote).foregroundStyle(.secondary)
            Button("重新加载声音") { catalogAttempt += 1 }
        }
    }

    private var visibleVoices: [ListeningEngine.Voice] {
        guard !voiceQuery.isEmpty else { return voices }
        return voices.filter {
            $0.name.localizedCaseInsensitiveContains(voiceQuery) || $0.id.localizedCaseInsensitiveContains(voiceQuery)
                || $0.languageName.localizedCaseInsensitiveContains(voiceQuery)
        }
    }
}

struct ListeningTimerControl: View {
    let playerActive: Bool
    @ObservedObject private var sleepTimer = ReaderSpeechController.shared.sleepTimer
    @State private var showsTimer = false
    @State private var customMinutes = ""
    @FocusState private var editingMinutes: Bool
    private let presets = [0, 15, 30, 45, 60, 90, 120, 180]

    private var duration: String { sleepTimer.minutes == 0 ? "关闭" : "\(sleepTimer.minutes) 分钟" }
    private var timerValue: String { playerActive && sleepTimer.minutes > 0 ? "剩余 " + duration : duration }
    private var enteredMinutes: Int? {
        guard let value = Int(customMinutes), (1...180).contains(value) else { return nil }
        return value
    }

    var body: some View {
        Button {
            customMinutes = presets.contains(sleepTimer.minutes) ? "" : String(sleepTimer.minutes)
            showsTimer = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "timer")
                Text(sleepTimer.minutes > 0 ? duration : "定时").font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("定时关闭").accessibilityValue(timerValue)
        .accessibilityIdentifier("listening.timer")
        .sheet(isPresented: $showsTimer) {
            ReadingNavigationStack {
                List {
                    Section("自定义分钟数") {
                        HStack {
                            TextField("1–180", text: $customMinutes)
                                .keyboardType(.numberPad)
                                .focused($editingMinutes)
                                .accessibilityLabel("自定义分钟数")
                                .onSubmit { if let enteredMinutes { apply(enteredMinutes) } }
                            Text("分钟").foregroundStyle(.secondary)
                            Button("确定") { if let enteredMinutes { apply(enteredMinutes) } }
                                .buttonStyle(.borderless)
                                .disabled(enteredMinutes == nil)
                        }
                    }.listRowBackground(ReadingTheme.sheetCard)
                    Section {
                        ForEach(presets, id: \.self) { minutes in
                            Button { apply(minutes) } label: {
                                HStack {
                                    Text(minutes == 0 ? "关闭" : "\(minutes) 分钟")
                                    Spacer()
                                    if sleepTimer.minutes == minutes { Image(systemName: "checkmark") }
                                }.contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("listening.timer.preset.\(minutes)")
                        }
                    }.listRowBackground(ReadingTheme.sheetCard)
                }
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.sheetBackground)
                .tint(ReadingTheme.accent)
                .readingSheetTitle("定时关闭")
                .toolbar { ReadingSheetCloseAction { showsTimer = false } }
            }
        }
    }

    private func apply(_ minutes: Int) {
        sleepTimer.set(minutes: minutes)
        editingMinutes = false
        showsTimer = false
    }
}

private struct ListeningMoreOptions: View {
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false

    var body: some View {
        Section("更多播放设置") {
            Toggle("朗读时保持亮屏", isOn: $readAloudWakeLock)
            Toggle("忽略音频焦点", isOn: $ignoreAudioFocus)
            if ignoreAudioFocus {
                Toggle("来电时暂停", isOn: $pauseReadAloudWhilePhoneCalls)
            }
            Toggle("媒体上一首/下一首切换章节", isOn: $mediaButtonPerNext)
        }
        .toggleStyle(SwitchToggleStyle(tint: ReadingTheme.toggleTint))
    }
}

struct ListeningSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReadingNavigationStack {
            ListeningSettingsView(palette: .sheet, showsVoiceEntry: false)
                .readingSheetTitle("听书设置")
                .toolbar { ReadingSheetCloseAction { dismiss() } }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }
}
