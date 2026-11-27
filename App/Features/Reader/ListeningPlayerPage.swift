import SwiftUI

struct ListeningPlayerPage: View {
    @ObservedObject var reader: ReaderViewModel
    var readingPosition = 0
    var onStart: (() -> Void)?
    var onBrowseChapter: ((Int) -> Void)?
    let onClose: () -> Void

    @ObservedObject private var speech = ReaderSpeechController.shared
    @AppStorage("ttsSpeechRate") private var speed = 5
    @AppStorage("themeMode") private var themeMode = "0"
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsVoices = false
    @State private var showsSettings = false

    private var preferredScheme: ColorScheme? {
        switch themeMode {
        case "1", "3": .light
        case "2": .dark
        default: nil
        }
    }

    private var dark: Bool { (preferredScheme ?? colorScheme) == .dark }
    private var ink: Color { dark ? .white : .black }
    private var canvas: Color { dark ? .black : .white }

    private var active: Bool { speech.listeningBook?.bookUrl == reader.book.bookUrl }
    private var displayedSpeed: Int { min(15, max(0, active ? speech.speechRate : speed)) }
    private var position: Int { active ? speech.spokenPosition ?? speech.listeningPosition : readingPosition }
    private var currentParagraph: ReaderParagraph? { reader.paragraphs.last { $0.id <= position } ?? reader.paragraphs.first }

    private func cover(width: CGFloat, height: CGFloat) -> some View {
        BookCoverArtwork(title: reader.book.name, author: reader.book.author, remoteURL: reader.book.displayCoverURL,
                         width: width, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { space in
                if space.size.width > space.size.height * 1.5 {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            heading
                            artwork
                        }
                        .frame(width: space.size.width * 0.33)
                        VStack(spacing: 10) {
                            paragraph
                            controls
                        }
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 0) {
                        heading.padding(.horizontal, 28).padding(.top, 8)
                        GeometryReader { bodySpace in
                            VStack(spacing: 0) {
                                artwork
                                paragraph
                                    .frame(height: min(bodySpace.size.height * 0.38, 160))
                                    .padding(.horizontal, 28)
                            }
                        }
                        controls.padding(.horizontal, 24)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ink)
        .buttonStyle(.plain)
        .background {
            GeometryReader { area in
                cover(width: 80, height: 100)
                    .scaleEffect(max(area.size.width / 80, area.size.height / 100) * 1.3)
                    .frame(width: area.size.width, height: area.size.height)
                    .blur(radius: 42)
                    .overlay(LinearGradient(colors: [canvas.opacity(dark ? 0.54 : 0.84), canvas.opacity(dark ? 0.28 : 0.70), canvas.opacity(dark ? 0.74 : 0.92)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .background(canvas).clipped().ignoresSafeArea().accessibilityHidden(true)
        }
        .background(ListeningPlayerViewport(tint: ink, background: canvas, showsFullPlayer: true))
        .onChange(of: active) { playing in
            if !playing && onStart == nil { onClose() }
        }
        .sheet(isPresented: $showsVoices) { ListeningVoiceSheet(playerBookURL: reader.book.bookUrl) }
        .sheet(isPresented: $showsSettings) { ListeningSettingsSheet() }
        .preferredColorScheme(preferredScheme)
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("收起播放器")
            Spacer()
            if active {
                Button("结束朗读") {
                    speech.stop()
                    if onStart != nil { onClose() }
                }
                .font(.subheadline).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(reader.title).font(.title2.weight(.semibold)).lineLimit(2)
                .accessibilityIdentifier("listening.chapter")
            HStack(spacing: 10) {
                Text(reader.book.name).lineLimit(1)
                if active && speech.isPaused && speech.errorMessage != nil {
                    Text("朗读已暂停，点播放重试").font(.caption)
                } else if active && speech.isChangingVoice {
                    Label(speech.isPaused ? "继续播放后换声" : "正在切换音色", systemImage: "waveform").font(.caption)
                } else if active && speech.isPreparingAudio {
                    Label("正在缓冲", systemImage: "waveform").font(.caption)
                }
            }
            .font(.subheadline).foregroundStyle(ink.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artwork: some View {
        GeometryReader { space in
            let width = max(1, min(space.size.width * 0.60, space.size.height * 0.63, 245))
            cover(width: width, height: width * 1.35)
                .shadow(color: .black.opacity(0.38), radius: 16, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var paragraph: some View {
        let passage = currentParagraph
        return GeometryReader { space in
            ScrollView {
                Text(passage?.text ?? reader.currentChapterError ?? "")
                    .font(.body).lineSpacing(5)
                    .frame(maxWidth: .infinity, minHeight: space.size.height, alignment: .leading)
                    .accessibilityIdentifier("listening.paragraph")
            }
            .id(passage?.id)
        }
        .id(reader.currentIndex)
    }

    private var controls: some View {
        let progress = min(1, Double(max(0, position)) / Double(max(1, reader.content.utf16.count)))
        let action = active ? (speech.isPaused ? "继续播放" : "暂停播放") : "开始听书"
        return VStack(spacing: 10) {
            HStack(spacing: 0) {
                ListeningTimerControl(playerActive: speech.listeningBook != nil)
                speedMenu
                Button { showsVoices = true } label: { tool("声音引擎", icon: "waveform") }
                    .accessibilityLabel("声音引擎")
                Button { showsSettings = true } label: { tool("设置", icon: "slider.horizontal.3") }
                    .accessibilityLabel("播放设置")
            }
            HStack(spacing: 10) {
                ProgressView(value: progress).tint(ink)
                Text("本章 \(Int(progress * 100))%").font(.caption2.monospacedDigit())
                    .foregroundStyle(ink.opacity(0.75))
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("本章朗读位置")
            .accessibilityValue("\(Int(progress * 100))%")
            HStack(spacing: 36) {
                chapterButton(-1)
                Button {
                    if active { speech.pauseOrResume() } else { onStart?() }
                } label: {
                    ZStack {
                        Circle().fill(ink)
                        Image(systemName: active && !speech.isPaused ? "pause.fill" : "play.fill")
                            .font(.title2).foregroundStyle(canvas)
                    }.frame(width: 62, height: 62)
                }
                .accessibilityLabel(action)
                .accessibilityValue(active && speech.isPreparingAudio ? "正在缓冲" : "")
                .disabled(!active && (onStart == nil || !reader.hasLoadedCurrentChapter || reader.hasImageContent || reader.content.isEmpty))
                chapterButton(1)
            }
        }
        .padding(.bottom, 8)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(0...15, id: \.self) { setting in
                Button { setSpeed(setting) } label: {
                    if setting == displayedSpeed {
                        Label(speedLabel(setting), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(setting))
                    }
                }
                .accessibilityAddTraits(setting == displayedSpeed ? .isSelected : [])
            }
        } label: {
            tool(speedLabel(displayedSpeed), icon: "speedometer")
        }
        .accessibilityLabel("语速")
        .accessibilityValue(speedLabel(displayedSpeed))
        .id(displayedSpeed)
    }

    private func setSpeed(_ value: Int) {
        speed = value
        if speech.listeningBook != nil { speech.updatePlaybackRate(value) }
    }

    private func speedLabel(_ setting: Int) -> String {
        String(format: "%.1f×", ReaderSpeechController.playbackRate(for: setting))
    }

    private func tool(_ title: String, icon: String) -> some View {
        VStack(spacing: 4) { Image(systemName: icon); Text(title).font(.caption) }
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func chapterButton(_ direction: Int) -> some View {
        let enabled = (active || onBrowseChapter != nil) && (direction < 0 ? reader.canGoPrevious : reader.canGoNext)
        return Button {
            if active { speech.moveChapter(direction) } else { onBrowseChapter?(direction) }
        } label: {
            Image(systemName: direction < 0 ? "backward.end.fill" : "forward.end.fill")
                .font(.title3).frame(width: 44, height: 44)
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(direction < 0 ? "上一章" : "下一章")
    }
}
