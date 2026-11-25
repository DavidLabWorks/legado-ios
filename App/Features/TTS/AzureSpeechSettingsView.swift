import Security
import SwiftUI

extension AzureSpeechSettings {
    static let didChange = Notification.Name("AzureSpeechSettingsDidChange")

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Legado") + ".AzureSpeech",
         kSecAttrAccount as String: "settings"]
    }

    static func load() throws -> Self? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        var status = SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.keychainQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct AzureSpeechSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appTtsEngine") private var defaultEngine = ""
    @State private var settings = AzureSpeechSettings()
    @State private var regions: [String: String] = [:]
    @State private var voices: [AzureSpeechSettings.Voice] = []
    @State private var loadedFor: [String] = []
    @State private var reload = 0
    @State private var error: String?
    @StateObject private var speech = ReaderSpeechController()

    private var credentials: [String] { [settings.region, settings.key] }
    private var canLoad: Bool { !settings.region.isEmpty && !settings.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedVoice: AzureSpeechSettings.Voice? {
        guard loadedFor == credentials else { return nil }
        return voices.first { $0.id == settings.voice }
    }

    var body: some View {
        Form {
            Section {
                Picker("区域", selection: $settings.region) {
                    Text("请选择区域").tag("")
                    ForEach(regions.keys.sorted(), id: \.self) { code in
                        Text("\(regions[code] ?? code)（\(code)）").tag(code)
                    }
                }
                .pickerStyle(.menu)
                SecureField("Speech 密钥", text: $settings.key)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
            } header: {
                Text("Azure Speech")
            } footer: {
                Text("选择 Azure 语音资源所在区域，填写密钥后会自动加载声音。")
            }
            Section("声音") {
                Picker("声音", selection: Binding(
                    get: { selectedVoice?.id ?? "" },
                    set: { settings.voice = $0 }
                )) {
                    if selectedVoice == nil { Text("待加载").tag("") }
                    ForEach(voices) { voice in
                        Text("\(voice.name)（\(voice.id)）").tag(voice.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(selectedVoice == nil)
                if selectedVoice == nil && canLoad && error == nil {
                    ProgressView("正在加载声音…")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if canLoad { Button("重新加载声音") { reload += 1 } }
                }
                Button(speech.isSpeaking ? "停止试听" : "试听") {
                    if speech.isSpeaking { speech.stop(); return }
                    do {
                        let engine = try selection().engine()
                        speech.configure(followsSystemRate: false, speechRate: 5, readByPage: true, streamsHTTPAudio: true)
                        speech.speakHTTP(engine: engine, text: "推开窗，雨已经停了。巷口的书店刚刚亮起灯。")
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(selectedVoice == nil)
                if let message = speech.errorMessage { Text(message).foregroundStyle(.red) }
            }
            Button("保存并设为默认朗读声音") {
                do {
                    let value = selection()
                    _ = try value.engine()
                    try value.save()
                    defaultEngine = AzureSpeechSettings.selection
                    NotificationCenter.default.post(name: AzureSpeechSettings.didChange, object: nil)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
            .disabled(selectedVoice == nil)
        }
        .navigationTitle("配置微软自然语音")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let file = Bundle.main.url(forResource: "AzureSpeechRegions", withExtension: "json"),
               let data = try? Data(contentsOf: file),
               let bundled = try? JSONDecoder().decode([String: String].self, from: data) {
                regions = bundled
            }
            do {
                if var saved = try AzureSpeechSettings.load() {
                    saved.region = saved.region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    settings = saved
                    if !saved.region.isEmpty && regions[saved.region] == nil { regions[saved.region] = saved.region }
                }
            } catch { self.error = error.localizedDescription }
            let url = URL(string: "https://learn.microsoft.com/zh-cn/azure/ai-services/speech-service/rest-text-to-speech?accept=text/markdown")!
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let fresh = try? AzureSpeechSettings.regionNames(in: String(decoding: data, as: UTF8.self)),
               !fresh.isEmpty, !Task.isCancelled {
                var options = fresh
                if !settings.region.isEmpty { options[settings.region] = fresh[settings.region] ?? settings.region }
                regions = options
            }
        }
        .task(id: credentials + [String(reload)]) {
            let requested = credentials
            speech.stop()
            voices = []
            loadedFor = []
            guard canLoad else { return }
            error = nil
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
                let list = try await settings.availableVoices()
                guard !Task.isCancelled, credentials == requested else { return }
                voices = list
                if !list.contains(where: { $0.id == settings.voice }), let first = list.first { settings.voice = first.id }
                loadedFor = requested
            } catch {
                if !Task.isCancelled, credentials == requested { self.error = error.localizedDescription }
            }
        }
        .onChange(of: settings.voice) { _ in speech.stop() }
        .onDisappear { speech.stop() }
    }

    private func selection() -> AzureSpeechSettings {
        var value = settings
        value.locale = selectedVoice?.locale
        return value
    }
}
