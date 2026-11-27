import LocalAuthentication
import SwiftUI

struct AppLockSettingsView: View {
    private enum Action { case change, disable, faceID }

    @ObservedObject private var lock = AppLock.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var action: Action?
    @State private var oldPassword: String?
    @State private var proposed: String?
    @State private var message = ""
    @State private var context: LAContext?
    @State private var showsSaveError = false

    private var checkingCurrent: Bool { action != nil && oldPassword == nil }
    private var title: String {
        if checkingCurrent {
            return lock.credential?.numericPIN == true ? "输入当前锁定码" : "输入原应用密码"
        }
        return proposed == nil ? "设置 6 位数字锁定码" : "再次输入锁定码"
    }

    var body: some View {
        Group {
            if let record = lock.credential, action == nil {
                List {
                    Section {
                        Button("关闭应用锁", role: .destructive) { action = .disable }
                        Button("更改锁定码") { action = .change }
                            .foregroundStyle(ReadingTheme.accent)
                    } footer: {
                        Text("轻点书架右上角的锁形按钮，可立即锁定喵阅。")
                    }
                    .listRowBackground(ReadingTheme.surface)

                    Section {
                        Menu {
                            Picker("自动锁定", selection: Binding(
                                get: { lock.autoLockDelay },
                                set: { delay in
                                    do { try lock.setAutoLockDelay(delay) }
                                    catch { message = error.localizedDescription; showsSaveError = true }
                                }
                            )) {
                                ForEach(AppLock.AutoLockDelay.allCases, id: \.self) { delay in
                                    Text(delay.title).tag(delay)
                                }
                            }
                        } label: {
                            HStack {
                                Text("自动锁定").foregroundStyle(.primary)
                                Spacer()
                                Text(lock.autoLockDelay.title).foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("appLock.delay")
                        if AppLock.supportsFaceID || record.faceIDState != nil {
                            Toggle("使用 Face ID 解锁", isOn: Binding(
                                get: { record.faceIDState != nil },
                                set: { _ in action = .faceID }
                            ))
                            .tint(ReadingTheme.toggleTint)
                        }
                    } header: {
                        Text("锁定与解锁")
                    } footer: {
                        Text("自动锁定从切到后台时开始计时。重新启动喵阅时始终需要解锁。")
                    }
                    .listRowBackground(ReadingTheme.surface)
                }
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.settingsCanvas.ignoresSafeArea())
                .readingPageTitle("应用锁")
                .readingTabBarHidden()
                .alert("无法更新自动锁定", isPresented: $showsSaveError) {
                    Button("好") { message = "" }
                } message: { Text(message) }
            } else {
                LockCodePad(title: title, legacyPassword: checkingCurrent && lock.credential?.numericPIN != true,
                            message: $message, cancel: cancelEntry, submit: { handle($0) })
                    .id(title)
                    .disabled(context != nil)
                    .navigationBarHidden(true)
                    .readingTabBarHidden()
            }
        }
        .onDisappear { reset() }
        .onChange(of: phase) { if $0 == .background { reset() } }
        .onChange(of: lock.credential?.id) { _ in reset() }
    }

    private func handle(_ value: String) {
        message = ""
        do {
            if checkingCurrent, let action {
                switch action {
                case .change:
                    try lock.verify(value)
                    oldPassword = value
                case .disable:
                    try lock.disable(password: value)
                    reset()
                    dismiss()
                case .faceID:
                    try lock.verify(value)
                    guard let record = lock.credential else { return }
                    if record.faceIDState != nil {
                        try lock.setFaceID(nil, for: record.id)
                        reset()
                    } else {
                        let attempt = LAContext()
                        context = attempt
                        Task { await enableFaceID(attempt, for: record.id) }
                    }
                }
            } else if let proposed {
                guard value == proposed else {
                    self.proposed = nil
                    message = "两次输入不一致，请重新设置。"
                    return
                }
                try lock.setPassword(value, replacing: oldPassword ?? "")
                reset()
            } else {
                proposed = value
            }
        } catch { message = error.localizedDescription }
    }

    private func enableFaceID(_ attempt: LAContext, for id: UUID) async {
        do {
            let state = try await AppLock.authenticateFaceID(attempt)
            guard context === attempt else { return }
            try lock.setFaceID(state, for: id)
            reset()
        } catch {
            guard context === attempt else { return }
            context = nil
            message = error.localizedDescription
        }
    }

    private func cancelEntry() {
        let settingUp = lock.credential == nil
        reset()
        if settingUp { dismiss() }
    }

    private func reset() {
        context?.invalidate()
        context = nil
        oldPassword = nil
        proposed = nil
        action = nil
        message = ""
    }
}
