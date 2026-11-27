import SwiftUI
import UIKit

@MainActor
final class BookFileOperations: ObservableObject {
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var readyExport: BookFileExport?
    @Published var partialExport: BookFileExport?
    private var activeExport: BookFileExport?
    let exporter = BookFileExporter()

    func run(_ operation: () async throws -> Void) async {
        guard !isWorking, activeExport == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await operation() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func present(_ file: BookFileExport) {
        activeExport = file
        if file.isPartial { partialExport = file }
        else { readyExport = file }
    }

    deinit {
        if let file = activeExport {
            let exporter = exporter
            Task { try? await exporter.discard(file) }
        }
    }

    func finishExport() {
        guard let file = activeExport else { return }
        activeExport = nil
        readyExport = nil
        partialExport = nil
        Task { try? await exporter.discard(file) }
    }
}

struct BookFileOperationFeedback: ViewModifier {
    @ObservedObject var model: BookFileOperations
    @State private var confirmsPartialExport = false

    func body(content: Content) -> some View {
        content
        .disabled(model.isWorking)
        .overlay {
            if model.isWorking {
                RagdollLoading("正在处理文件…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: model.partialExport?.id) { value in confirmsPartialExport = value != nil }
        .onChange(of: confirmsPartialExport) { isPresented in
            if !isPresented {
                Task { @MainActor in
                    await Task.yield()
                    if !confirmsPartialExport, model.readyExport == nil { model.finishExport() }
                }
            }
        }
        .alert("缓存正文不完整", isPresented: $confirmsPartialExport, presenting: model.partialExport) { file in
            Button("导出已缓存内容") {
                model.readyExport = file
                model.partialExport = nil
            }
            Button("取消", role: .cancel) { model.finishExport() }
        } message: { file in
            Text("已缓存 \(file.cachedChapters)/\(file.totalChapters) 章。导出文件会标记未缓存章节，可先返回详情缓存完整后再导出。")
        }
        .sheet(item: $model.readyExport, onDismiss: { model.finishExport() }) { file in
            FileExportPicker(url: file.url) { model.readyExport = nil }
        }
        .alert("文件操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "未知错误") }
    }
}

private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCompletion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: () -> Void
        init(_ completion: @escaping () -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion() }
    }
}
