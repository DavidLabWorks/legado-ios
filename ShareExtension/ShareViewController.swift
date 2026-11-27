import UIKit

final class ShareViewController: UIViewController {
    private var started = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        view.backgroundColor = .systemBackground
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in self.receive(url) }
            }
        } else if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                let text = string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = text.flatMap { $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? URL(string: $0) : nil }
                Task { @MainActor in self.receive(url) }
            }
        } else {
            receive(nil)
        }
    }

    private func receive(_ url: URL?) {
        let message: String
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false {
            do {
                try SharedLinkInbox.save(url)
                message = "已接收链接。打开喵阅即可预览并确认导入。"
            } catch {
                message = "保存链接失败：\(error.localizedDescription)"
            }
        } else {
            message = "请分享一个 HTTP 或 HTTPS 链接。"
        }
        let alert = UIAlertController(title: "喵阅", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "完成", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
