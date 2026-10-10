import Foundation
import Testing
@testable import GlanslateCore

@Suite("Cancellation and stale results")
@MainActor
struct CancellationTests {
    @Test func newerRunsReplaceOlderOnesEvenWhenTheyFinishLater() async {
        let runner = LatestTaskRunner<String>()
        var delivered: [String] = []

        runner.run({
            // Ignores cancellation on purpose, like a network call that already completed.
            try? await Task.sleep(for: .milliseconds(150))
            return "old"
        }, completion: { delivered.append((try? $0.get()) ?? "error") })

        runner.run({
            try await Task.sleep(for: .milliseconds(10))
            return "new"
        }, completion: { delivered.append((try? $0.get()) ?? "error") })

        await runner.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(delivered == ["new"])
        #expect(!runner.isRunning)
    }

    @Test func startingANewRunCancelsThePreviousTask() async {
        let runner = LatestTaskRunner<Bool>()
        let observed = CancellationProbe()

        runner.run({
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                await observed.markCancelled()
            }
            return true
        }, completion: { _ in })
        try? await Task.sleep(for: .milliseconds(20))
        runner.run({ false }, completion: { _ in })

        await runner.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await observed.wasCancelled)
    }

    @Test func cancelDiscardsTheResult() async {
        let runner = LatestTaskRunner<Int>()
        var delivered = false
        runner.run({
            try? await Task.sleep(for: .milliseconds(50))
            return 1
        }, completion: { _ in delivered = true })
        runner.cancel()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!delivered)
        #expect(!runner.isRunning)
    }

    @Test func failuresAreDeliveredForTheLatestRun() async {
        let runner = LatestTaskRunner<Int>()
        var error: GlanslateError?
        runner.run({ throw GlanslateError.noTextFound }, completion: { result in
            if case .failure(let failure) = result { error = failure as? GlanslateError }
        })
        await runner.waitUntilIdle()
        #expect(error == .noTextFound)
    }
}

private actor CancellationProbe {
    var wasCancelled = false
    func markCancelled() { wasCancelled = true }
}
