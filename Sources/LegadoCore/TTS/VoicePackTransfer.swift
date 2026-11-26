import Foundation

/// The manifest provides the byte count even when the server sends a chunked body.
final class VoicePackTransfer: NSObject, URLSessionDownloadDelegate, Sendable {
    private let bytes: AsyncThrowingStream<Int64, Error>.Continuation
    private let destination: URL
    private let contentRange: String?
    private let expectedSize: Int64

    private init(bytes: AsyncThrowingStream<Int64, Error>.Continuation, destination: URL, expectedSize: Int64, contentRange: String?) {
        self.contentRange = contentRange
        self.bytes = bytes
        self.destination = destination
        self.expectedSize = expectedSize
    }

    static func download(_ request: URLRequest, to destination: URL, size: Int64, contentRange: String? = nil,
                         report: @Sendable (Int64) async -> Void) async throws {
        let (stream, continuation) = AsyncThrowingStream<Int64, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delegate = VoicePackTransfer(bytes: continuation, destination: destination, expectedSize: size, contentRange: contentRange)
        let task = URLSession.shared.downloadTask(with: request)
        task.delegate = delegate
        defer { task.cancel() }
        try Task.checkCancellation()
        task.resume()
        var lastBytes: Int64 = 0
        var lastUpdate: TimeInterval = 0
        for try await bytes in stream {
            let now = ProcessInfo.processInfo.systemUptime
            if bytes > lastBytes && (lastBytes == 0 || bytes == size || now - lastUpdate >= 0.5) {
                await report(bytes)
                lastBytes = bytes
                lastUpdate = now
            }
        }
        try Task.checkCancellation()
    }

    private func accepts(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if let contentRange {
            return http.statusCode == 206 && http.value(forHTTPHeaderField: "Content-Range") == contentRange
        }
        return http.statusCode == 200
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard accepts(downloadTask.response) else { return }
        bytes.yield(min(totalBytesWritten, expectedSize))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard accepts(downloadTask.response),
                  try location.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(expectedSize) else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            bytes.yield(expectedSize)
            bytes.finish()
        } catch { bytes.finish(throwing: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { bytes.finish(throwing: error) }
    }
}
