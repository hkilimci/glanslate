import Foundation

/// Runs one asynchronous operation at a time and delivers only the newest result.
///
/// Starting a new run cancels the previous one. A result that arrives after a
/// newer run started — or after ``cancel()`` — is dropped, so an outdated
/// translation can never replace a newer one, even if its task ignores
/// cancellation and finishes anyway.
@MainActor
public final class LatestTaskRunner<Output: Sendable> {
    public private(set) var isRunning = false
    private var generation = 0
    private var task: Task<Void, Never>?

    public init() {}

    public func run(
        _ operation: @escaping @Sendable () async throws -> Output,
        completion: @escaping @MainActor (Result<Output, any Error>) -> Void
    ) {
        task?.cancel()
        generation += 1
        let current = generation
        isRunning = true
        task = Task { [weak self] in
            let result: Result<Output, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == current else { return }
            self.isRunning = false
            self.task = nil
            completion(result)
        }
    }

    /// Cancels the running operation; its result, if any, is discarded.
    public func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
    }

    /// Waits for the current operation to finish. Intended for tests.
    public func waitUntilIdle() async {
        while let task {
            await task.value
            if self.task == task { break }
        }
    }
}
