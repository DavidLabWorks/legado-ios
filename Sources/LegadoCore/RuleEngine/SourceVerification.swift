import Foundation

/// A synchronous JS call waits on its rule worker while the main actor handles user input.
final class SourceVerification: @unchecked Sendable {
    typealias Presenter = @MainActor @Sendable (String, Data) async throws -> String
    static let shared = SourceVerification()
    private let lock = NSLock()
    private var presentation: Presenter?

    func register(_ presenter: @escaping Presenter) {
        lock.withLock { presentation = presenter }
    }

    func request(source: String, image: Data, context: RuleExecutionContext) throws -> String {
        guard !Thread.isMainThread, let present = lock.withLock({ presentation }) else {
            throw RuleEngineError.invalidInput(rule: "java.getVerificationCode", expected: "当前无法显示验证码")
        }
        let signal = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        nonisolated(unsafe) var answer: Result<String, Error>?
        let task = Task { @MainActor in
            let result: Result<String, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await present(source, image))
            } catch { result = .failure(error) }
            resultLock.withLock { answer = result }
            signal.signal()
        }
        defer { task.cancel() }
        while signal.wait(timeout: .now() + 0.2) == .timedOut { try context.checkCancellation() }
        try context.checkCancellation()
        return try resultLock.withLock { try answer!.get() }
    }
}
