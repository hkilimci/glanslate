import CoreGraphics
import XCTest
@testable import GlanslateCapture
@testable import GlanslateCore
@testable import GlanslateGeometry
@testable import GlanslateOverlay

final class OverlaySessionTests: XCTestCase {
    func testNoopOverlayPresenterEmitsLifecycleEvents() async throws {
        let presenter = NoopOverlayPresenter()
        let session = sampleSession()
        let handle = await presenter.present(session)
        let events = handle.events

        let collector = Task<[OverlayEvent], Never> {
            var output: [OverlayEvent] = []
            for await event in events {
                output.append(event)
                if event == .dismissed {
                    break
                }
            }
            return output
        }

        await handle.setStyle(.subtitle)
        await handle.requestRetranslation(
            OverlayRetranslationRequest(
                targetLanguage: .de,
                provider: .deepL,
                sourceLanguage: .en
            )
        )
        await handle.pin()
        await handle.unpin()
        await handle.dismiss()

        let output = await collector.value
        let activeSessionCount = await presenter.activeSessionCount()
        XCTAssertEqual(
            output,
            [
                .styleChanged(.subtitle),
                .retranslateRequested(
                    OverlayRetranslationRequest(
                        targetLanguage: .de,
                        provider: .deepL,
                        sourceLanguage: .en
                    )
                ),
                .pinned(
                    OverlayPinnedPayload(
                        translations: session.translations,
                        thumbnailPNG: nil
                    )
                ),
                .unpinned(
                    OverlayPinnedPayload(
                        translations: session.translations,
                        thumbnailPNG: nil
                    )
                ),
                .dismissed
            ]
        )
        XCTAssertEqual(activeSessionCount, 0)
    }

    private func sampleSession() -> OverlaySessionModel {
        let topology = DisplayTopologySnapshot(entries: [
            DisplayTopologyEntry(
                displayID: 1,
                appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                backingScale: 2,
                pixelSize: CGSize(width: 200, height: 200),
                isMain: true
            )
        ])
        let block = TextBlock(
            text: "hello",
            region: DisplayLocalRect(displayID: 1, rect: CGRect(x: 10, y: 10, width: 40, height: 12)),
            detectedLanguage: .en,
            confidence: 1,
            source: .vision
        )
        let translation = Translation(block: block, translatedText: "merhaba", targetLanguage: .tr, provider: .openAI)
        return OverlaySessionModel(
            invocationID: UUID(),
            topology: topology,
            source: SourceVisualContext(
                image: makeImage(),
                region: block.region,
                topology: topology,
                pixelScale: 2
            ),
            translations: [translation]
        )
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
