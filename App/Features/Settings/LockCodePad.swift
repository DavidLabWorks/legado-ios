import SwiftUI

/// Shared by setup, credential changes and the separate lock-screen window.
struct LockCodePad: View {
    let title: String
    var legacyPassword = false
    @Binding var message: String
    var cancel: (() -> Void)?
    var faceID: (() -> Void)?
    var showsFaceIDButton = false
    var acceptedPIN = false
    let submit: (String) -> Void

    @State private var input = ""
    @Environment(\.scenePhase) private var phase
    @ScaledMetric(relativeTo: .title) private var numberSize: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(78, max(48, (geometry.size.height - 200) / 5.8),
                               max(48, (geometry.size.width - 80) / 3.5))
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack {
                        if let cancel {
                            Button(action: cancel) {
                                Text("取消").font(.body)
                                    .padding(.horizontal, 16).frame(minHeight: 44)
                                    .lockGlass(in: Capsule())
                                    .contentShape(Capsule())
                            }
                        }
                        Spacer()
                    }
                    .frame(height: 44)
                    Spacer(minLength: 8)
                    Group {
                        if let faceID {
                            Button(action: faceID) {
                                Image(systemName: "faceid")
                                    .font(.system(size: 30))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("使用 Face ID 解锁")
                            .opacity(showsFaceIDButton ? 1 : 0)
                            .allowsHitTesting(showsFaceIDButton)
                            .accessibilityHidden(!showsFaceIDButton)
                        } else {
                            ReadingHeaderArtwork.appLock
                                .aspectRatio(220.0 / 72, contentMode: .fit)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: geometry.size.height < 600 ? 44 : 66)
                    Text(title).font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 18)
                    if legacyPassword {
                        legacyEntry
                    } else {
                        let digitCount = acceptedPIN ? AppLock.pinLength : input.count
                        HStack(spacing: 15) {
                            ForEach(0..<AppLock.pinLength, id: \.self) { index in
                                Circle()
                                    .fill(index < digitCount ? Color.primary : .clear)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5))
                                    .frame(width: 12, height: 12)
                            }
                        }
                        .padding(.top, 16)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("密码输入进度")
                        .accessibilityValue("已输入 \(digitCount) 位，共 \(AppLock.pinLength) 位")
                    }
                    Text(message)
                        .font(.footnote.weight(.medium)).multilineTextAlignment(.center)
                        .frame(minHeight: 26).padding(.top, 6)
                    if !legacyPassword {
                        Spacer(minLength: 8)
                        let columns = Array(repeating: GridItem(.fixed(diameter), spacing: 22), count: 3)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(1...9, id: \.self) { digit in digitKey(digit, diameter: diameter) }
                            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                            digitKey(0, diameter: diameter)
                            accessory("delete.left", label: "删除一位") {
                                if !input.isEmpty { input.removeLast() }
                            }
                            .disabled(input.isEmpty)
                        }
                    }
                    Spacer(minLength: 20)
                }
                .lockGlassGroup()
                .padding(.horizontal, 16)
                // The three spacers share this adjustment, lifting the header by 12 pt and the keypad by 24 pt.
                .padding(.bottom, cancel == nil && !legacyPassword ? min(36, max(0, geometry.size.height - 600)) : 0)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .background((cancel == nil ? ReadingTheme.canvas : ReadingTheme.settingsCanvas).ignoresSafeArea())
        .onDisappear { input = "" }
        .onChange(of: phase) { if $0 == .background { input = "" } }
        .onChange(of: message) { text in
            if !text.isEmpty { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }

    private func digitKey(_ digit: Int, diameter: CGFloat) -> some View {
        Button {
            guard input.count < AppLock.pinLength else { return }
            message = ""
            input.append(String(digit))
            if input.count == AppLock.pinLength { finish() }
        } label: {
            Text(String(digit)).font(.system(size: min(numberSize, diameter * 0.63), weight: .regular))
                .frame(width: diameter, height: diameter)
                .lockGlass(in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(String(digit))
        .accessibilityIdentifier("appLock.digit.\(digit)")
    }

    private func accessory(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2)
                .frame(width: 44, height: 44)
                .lockGlass(in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var legacyEntry: some View {
        VStack(spacing: 16) {
            SecureField("原应用密码", text: $input)
                .textInputAutocapitalization(.never).disableAutocorrection(true)
                .textContentType(.password).submitLabel(.done).onSubmit(finish)
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            Button(action: finish) {
                Text("验证密码").padding(.horizontal, 22).frame(minHeight: 44)
                    .lockGlass(in: Capsule())
            }
            .disabled(input.isEmpty)
        }
        .frame(maxWidth: 320)
        .padding(.top, 18)
    }

    private func finish() {
        guard !input.isEmpty else { return }
        let value = input
        input = ""
        submit(value)
    }
}

extension View {
    @ViewBuilder func lockGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *), !ReadingCompatibility.usesLegacyUI {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder func lockGlassGroup() -> some View {
        if #available(iOS 26, *), !ReadingCompatibility.usesLegacyUI {
            GlassEffectContainer(spacing: 5) { self }
        } else {
            self
        }
    }
}
