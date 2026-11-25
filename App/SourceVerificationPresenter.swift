import SwiftUI

@MainActor
final class SourceVerificationPresenter {
    static let shared = SourceVerificationPresenter()

    private struct Prompt {
        let id: UUID
        let source: String
        let image: UIImage
        let response: CheckedContinuation<String, Error>
    }

    private var prompts: [Prompt] = []
    private var window: UIWindow?
    private weak var previousWindow: UIWindow?

    func request(source: String, data: Data) async throws -> String {
        guard let image = UIImage(data: data) else {
            throw RuleEngineError.invalidInput(rule: "java.getVerificationCode", expected: "网站返回的验证码图片无法显示")
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { response in
                prompts.append(Prompt(id: id, source: source, image: image, response: response))
                if prompts.count == 1 { showNext() }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    private func showNext() {
        guard let prompt = prompts.first else {
            window?.isHidden = true
            window = nil
            previousWindow?.makeKey()
            previousWindow = nil
            return
        }
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                finish(prompt.id, with: .failure(CancellationError()))
                return
            }
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = .alert
            overlay.backgroundColor = .clear
            window = overlay
        }
        let view = VerificationForm(source: prompt.source, image: prompt.image) { answer in
            self.finish(prompt.id, with: answer.map(Result.success) ?? .failure(CancellationError()))
        }
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        window?.rootViewController = host
        window?.makeKeyAndVisible()
    }

    private func finish(_ id: UUID, with result: Result<String, Error>) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = prompts.remove(at: index)
        if index == 0 { showNext() }
        prompt.response.resume(with: result)
    }
}

private struct VerificationForm: View {
    let source: String
    let image: UIImage
    let finish: (String?) -> Void
    @State private var input = ""
    @FocusState private var focused: Bool
    private var answer: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("输入验证码").font(.headline)
                Text(source).font(.subheadline)
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 80).accessibilityLabel("网站验证码图片")
                TextField("图片中的字符", text: $input)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .submitLabel(.done).onSubmit { if !answer.isEmpty { finish(answer) } }
                HStack {
                    Button("取消", role: .cancel) { finish(nil) }
                    Spacer()
                    Button("确认") { finish(answer) }.buttonStyle(.borderedProminent).disabled(answer.isEmpty)
                }
            }
            .padding(22).frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding().onAppear { focused = true }
        }
    }
}
