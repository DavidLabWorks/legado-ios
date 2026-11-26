@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class VoicePackDownloads: ObservableObject {
    static let shared = VoicePackDownloads()
    @Published private(set) var busy = false
    struct Progress: Equatable {
        var bytes: Int64
        var status: String
    }
    @Published var progress = Progress(bytes: 0, status: "")
    @Published var installing = false
    @Published var message: String?
    private var task: Task<Void, Never>?

    init() {
        let root = OfflineVoicePack.root
        for item in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent.hasPrefix(".install-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func start(imported: URL? = nil) {
        guard !busy, !OfflineVoicePack.zipvoice.isInstalled else { return }
        busy = true
        progress = Progress(bytes: ZipVoiceDownload.savedBytes, status: "正在连接…")
        message = nil
        installing = false
        task = Task {
            defer { busy = false; task = nil }
            do {
                if let imported {
                    let scoped = imported.startAccessingSecurityScopedResource()
                    defer { if scoped { imported.stopAccessingSecurityScopedResource() } }
                    try await install(from: imported)
                } else {
                    try await ZipVoiceDownload.install { bytes, status in
                        await MainActor.run { self.progress = Progress(bytes: bytes, status: status) }
                    }
                }
                try? FileManager.default.removeItem(at: OfflineVoicePack.zipvoice.partialArchive)
                try? FileManager.default.removeItem(at: ZipVoiceDownload.stage)
                UserDefaults.standard.set(OfflineVoice.preferred.rawValue, forKey: OfflineVoice.preferenceKey)
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func install(from file: URL) async throws {
        installing = true
        let work = Task.detached(priority: .utility) {
            try OfflineVoicePack.installZipVoice(archive: file)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func cancel() { task?.cancel() }

    func remove(_ pack: OfflineVoicePack) {
        guard !busy else { return }
        objectWillChange.send()
        do { try pack.remove(); message = nil }
        catch { message = "删除失败：" + error.localizedDescription }
    }

}

@MainActor
private final class VoicePreviewPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?

    func play(voice: OfflineVoice, rate: Float) {
        stop()
        errorMessage = nil
        let name = "zipvoice-" + voice.speaker
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "VoicePreviews") else {
            errorMessage = "找不到所选声音的试听音频。"
            return
        }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
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

    func updateRate(_ rate: Float) { player?.rate = rate }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

private extension View {
    func listeningCard() -> some View {
        padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ListeningSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let presented: Bool
    let isListening: Bool
    let canStart: Bool
    let speechTimerRemaining: Int
    let onStart: (() -> Void)?

    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @ObservedObject private var downloads = VoicePackDownloads.shared
    @AppStorage(OfflineVoice.preferenceKey) private var voiceID = OfflineVoice.uncleFu.rawValue
    @StateObject private var preview = VoicePreviewPlayer()
    @State private var pendingRemoval: OfflineVoicePack?
    @State private var showsImporter = false
    @State private var showsMore = false
    @State private var editsTimer = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private let ink = Color(red: 0.09, green: 0.23, blue: 0.21)
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.48, green: 0.84, blue: 0.72) : ink
    }

    private var rate: Float { ReaderSpeechController.playbackRate(for: ttsSpeechRate) }

    init(presented: Bool = false, isListening: Bool = false, canStart: Bool = true, speechTimerRemaining: Int = 0, onStart: (() -> Void)? = nil) {
        self.presented = presented
        self.isListening = isListening
        self.canStart = canStart
        self.speechTimerRemaining = speechTimerRemaining
        self.onStart = onStart
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }

    private var settingsContent: some View {
        let installedPack = OfflineVoicePack.selected
        let legacyPacks = OfflineVoicePack.allCases.filter { $0 != .zipvoice && $0.hasStoredFiles }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if installedPack != nil {
                    voiceCard
                } else {
                    zipVoiceRow
                }
                playbackCard
                if installedPack != nil { zipVoiceRow }
                moreOptions
                if !legacyPacks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("旧语音包清理").font(.headline)
                        ForEach(legacyPacks) { pack in
                            Button("清理「" + pack.title + "」", role: .destructive) { pendingRemoval = pack }
                                .disabled(downloads.busy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).listeningCard()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    @ViewBuilder private var settingsPage: some View {
        if presented {
            settingsContent.readingSheetTitle("听书设置").toolbar {
                ReadingSheetActions {
                    ReadingSheetCloseButton { dismiss() }
                }
            }
        } else {
            settingsContent.navigationTitle("听书设置").navigationBarTitleDisplayMode(.inline)
        }
    }

    var body: some View {
        let installedPack = OfflineVoicePack.selected
        let canPlay = canStart && installedPack != nil && !downloads.busy
        return settingsPage
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(accent)
        .safeAreaInset(edge: .bottom) {
            if let onStart {
                Button {
                    preview.stop()
                    onStart()
                } label: {
                    Label("开始听书", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!canPlay)
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .onChange(of: ttsSpeechRate) { _ in preview.updateRate(rate) }
        .onChange(of: installedPack) { _ in preview.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                preview.stop()
            }
        }
        .onDisappear { preview.stop() }
        .alert("删除本机语音包？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { pack in
            Button("删除", role: .destructive) {
                preview.stop()
                downloads.remove(pack)
            }
            Button("取消", role: .cancel) {}
        } message: { pack in
            Text("将清理「" + pack.title + "」的本机模型和下载缓存。以后可以重新下载。")
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.zip]) { result in
            do { downloads.start(imported: try result.get()) }
            catch { downloads.message = error.localizedDescription }
        }
    }

    private var voiceCard: some View {
        let selectedVoice = OfflineVoice(rawValue: voiceID) ?? .uncleFu
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("朗读声音", systemImage: "headphones").font(.headline)
                Spacer()
                Button {
                    if preview.isPlaying { preview.stop() }
                    else { preview.play(voice: selectedVoice, rate: rate) }
                } label: {
                    Label(preview.isPlaying ? "停止试听" : "试听", systemImage: preview.isPlaying ? "stop.fill" : "play.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.14), in: Capsule())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(isListening)
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { voiceChoices(selected: selectedVoice) }
            } else {
                HStack(spacing: 10) { voiceChoices(selected: selectedVoice) }
            }
            if let error = preview.errorMessage { Text(error).font(.footnote) }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(ink, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func voiceChoices(selected: OfflineVoice) -> some View {
        ForEach(OfflineVoice.allCases, id: \.self) { voice in
            let isSelected = voice == selected
            Button {
                preview.stop()
                voiceID = voice.rawValue
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(voice == .uncleFu ? "男声" : "女声").font(.subheadline)
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                    }
                    Text(voice == .uncleFu ? "Uncle_Fu" : "Serena")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                }
                .padding(12)
                .foregroundStyle(isSelected ? ink : .white)
                .background(isSelected ? Color(red: 0.86, green: 0.94, blue: 0.88) : .white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("朗读语速", systemImage: "speedometer").font(.headline)
                Spacer()
                Text(String(format: "%.1f×", rate)).font(.headline.monospacedDigit()).foregroundStyle(accent)
            }
            Slider(value: Binding(get: { Double(rate) }, set: { ttsSpeechRate = Int(($0 * 10).rounded()) - 5 }),
                   in: 0.5...2, step: 0.1)
                .accessibilityLabel("朗读语速")
                .accessibilityValue(String(format: "%.1f 倍", rate))
            Divider()
            Menu {
                ForEach([0, 15, 30, 45, 60, 90, 120, 180], id: \.self) { minutes in
                    Button {
                        editsTimer = false
                        ttsTimer = minutes
                    } label: {
                        let title = minutes == 0 ? "关闭" : "\(minutes) 分钟"
                        if ttsTimer == minutes { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
                Button("自定义分钟数") { editsTimer = true }
            } label: {
                HStack {
                    Label("定时关闭", systemImage: "moon.zzz").foregroundStyle(.primary)
                    Spacer()
                    Text(ttsTimer == 0 ? "关闭" : "\(ttsTimer) 分钟").foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if editsTimer { Stepper("\(ttsTimer) 分钟", value: $ttsTimer, in: 0...180) }
            if speechTimerRemaining > 0 {
                Text("本次朗读还剩 \(speechTimerRemaining) 分钟").font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(isOn: $readAloudByPage) { Label("按页朗读", systemImage: "book") }
                .accessibilityLabel("按页朗读")
                .accessibilityIdentifier("listening.byPage")
        }
        .listeningCard()
    }

    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showsMore) {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Toggle("朗读时保持亮屏", isOn: $readAloudWakeLock)
                Toggle("忽略音频焦点", isOn: $ignoreAudioFocus)
                if ignoreAudioFocus {
                    Toggle("来电时暂停", isOn: $pauseReadAloudWhilePhoneCalls)
                }
                Toggle("媒体上一首/下一首切换章节", isOn: $mediaButtonPerNext)
            }.padding(.top, 6)
        } label: {
            Label("更多播放设置", systemImage: "slider.horizontal.3")
        }
        .listeningCard()
    }

    private var zipVoiceRow: some View {
        let pack = OfflineVoicePack.zipvoice
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shippingbox")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(accent)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("ZipVoice 离线语音包").font(.headline)
                    Text((pack.isInstalled ? "已安装" : "男声和女声") + " · " + megabytes(ZipVoiceDownload.size) + " MB")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                if pack.isInstalled {
                    Menu {
                        Button("删除语音包", role: .destructive) { pendingRemoval = pack }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("管理离线语音包")
                }
            }
            if downloads.busy {
                if downloads.installing { RagdollLoading("正在校验并安装…") }
                else {
                    ProgressView(value: Double(downloads.progress.bytes), total: Double(ZipVoiceDownload.size))
                    HStack { RagdollLoading(width: 32); Text(downloads.progress.status).monospacedDigit() }
                    HStack(spacing: 4) {
                        Text(verbatim: megabytes(ZipVoiceDownload.size))
                            .hidden()
                            .overlay(alignment: .trailing) {
                                Text(verbatim: megabytes(downloads.progress.bytes))
                            }
                        Text(verbatim: "MB / " + ByteCountFormatter.string(fromByteCount: ZipVoiceDownload.size, countStyle: .decimal))
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(megabytes(downloads.progress.bytes)) MB，共 \(ByteCountFormatter.string(fromByteCount: ZipVoiceDownload.size, countStyle: .decimal))")
                    .transaction { $0.animation = nil }
                }
                Button("取消") { downloads.cancel() }
            } else if !pack.isInstalled {
                Text("下载或导入后即可开始听书。").font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button(ZipVoiceDownload.savedBytes > 0 ? "继续下载" : "下载") { downloads.start() }
                        .buttonStyle(.borderedProminent)
                    Button("从文件导入") { showsImporter = true }
                }
            }
            if let message = downloads.message { Text(message).font(.footnote).foregroundStyle(.red) }
            if !pack.isInstalled && pack.hasStoredFiles && !downloads.busy {
                Button("清理未完成的下载", role: .destructive) {
                    pendingRemoval = pack
                }
            }
        }.listeningCard()
    }
}

struct OfflineVoicePackSheet: View {
    var body: some View {
        ReadingNavigationStack { ListeningSettingsView(presented: true) }
    }
}
