import AppKit
import Combine
import Foundation
import SwiftUI
import GlanslateCore
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
@available(macOS 26.0, *)
@MainActor
final class AppleTranslationSessionBridge: ObservableObject {
    static let shared = AppleTranslationSessionBridge()

    @Published fileprivate var configuration: TranslationSession.Configuration?

    private var window: NSWindow?
    private var currentJob: Job?
    private var runningJobID: UUID?

    private init() {}

    func translate(
        _ blocks: [TextBlock],
        from: Language?,
        to: Language,
        needsDownload: Bool
    ) async throws -> [GlanslateCore.Translation] {
        guard currentJob == nil else {
            throw GlanslateError.translation(
                provider: .apple,
                reason: "Another Apple Translation request is already in progress."
            )
        }

        ensureWindow()
        presentHostWindow()

        return try await withCheckedThrowingContinuation { continuation in
            currentJob = Job(
                id: UUID(),
                blocks: blocks,
                sourceLanguage: from,
                targetLanguage: to,
                needsDownload: needsDownload,
                continuation: continuation
            )
            configuration = TranslationSession.Configuration(
                source: from.map { Locale.Language(identifier: $0.bcp47) },
                target: Locale.Language(identifier: to.bcp47)
            )
        }
    }

    fileprivate func snapshotForCurrentJob() -> JobSnapshot? {
        guard let job = currentJob else { return nil }
        return JobSnapshot(
            id: job.id,
            blocks: job.blocks,
            sourceLanguage: job.sourceLanguage,
            targetLanguage: job.targetLanguage,
            needsDownload: job.needsDownload
        )
    }

    fileprivate func beginRunning(jobID: UUID) -> Bool {
        guard currentJob?.id == jobID else { return false }
        guard runningJobID != jobID else { return false }
        runningJobID = jobID
        return true
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let hostView = AppleTranslationSessionHostView(bridge: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: hostView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        self.window = window
    }

    private func presentHostWindow() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    fileprivate func finish(
        jobID: UUID,
        result: Result<[GlanslateCore.Translation], Error>
    ) {
        guard let job = currentJob, job.id == jobID else { return }
        runningJobID = nil
        currentJob = nil
        configuration = nil
        window?.orderOut(nil)
        job.continuation.resume(with: result)
    }
}

@available(macOS 26.0, *)
private struct AppleTranslationSessionHostView: View {
    @ObservedObject var bridge: AppleTranslationSessionBridge

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .translationTask(bridge.configuration) { session in
                guard let job = bridge.snapshotForCurrentJob() else { return }
                guard bridge.beginRunning(jobID: job.id) else { return }

                nonisolated(unsafe) let unsafeSession = session

                let result: Result<[GlanslateCore.Translation], Error>
                do {
                    if job.needsDownload, job.sourceLanguage != nil {
                        try await unsafeSession.prepareTranslation()
                    }

                    nonisolated(unsafe) let requests = job.blocks.map {
                        TranslationSession.Request(
                            sourceText: $0.text,
                            clientIdentifier: $0.id.uuidString
                        )
                    }
                    let responses = try await unsafeSession.translations(from: requests)
                    result = .success(try makeTranslations(from: responses, job: job))
                } catch {
                    result = .failure(error)
                }

                bridge.finish(jobID: job.id, result: result)
            }
    }
}

@available(macOS 26.0, *)
private extension AppleTranslationSessionBridge {
    struct Job {
        let id: UUID
        let blocks: [TextBlock]
        let sourceLanguage: Language?
        let targetLanguage: Language
        let needsDownload: Bool
        let continuation: CheckedContinuation<[GlanslateCore.Translation], Error>
    }

    struct JobSnapshot: Sendable {
        let id: UUID
        let blocks: [TextBlock]
        let sourceLanguage: Language?
        let targetLanguage: Language
        let needsDownload: Bool
    }
}

@available(macOS 26.0, *)
private func makeTranslations(
    from responses: [TranslationSession.Response],
    job: AppleTranslationSessionBridge.JobSnapshot
) throws -> [GlanslateCore.Translation] {
    let translationsByID = Dictionary(uniqueKeysWithValues: try responses.map { response in
        guard
            let clientIdentifier = response.clientIdentifier,
            let block = job.blocks.first(where: { $0.id.uuidString == clientIdentifier })
        else {
            throw GlanslateError.translation(
                provider: .apple,
                reason: "Apple Translation returned incomplete batch results."
            )
        }

        return (
            block.id,
            GlanslateCore.Translation(
                block: block,
                translatedText: response.targetText,
                targetLanguage: job.targetLanguage,
                provider: .apple
            )
        )
    })

    let ordered = job.blocks.compactMap { translationsByID[$0.id] }
    guard ordered.count == job.blocks.count else {
        throw GlanslateError.translation(
            provider: .apple,
            reason: "Apple Translation returned incomplete batch results."
        )
    }
    return ordered
}
#endif
