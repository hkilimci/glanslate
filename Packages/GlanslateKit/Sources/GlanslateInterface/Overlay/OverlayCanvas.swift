import GlanslateCore
import GlanslateSystem
import SwiftUI

/// Everything drawn over the captured region: a progress outline while
/// working, then the translated blocks at their original positions.
struct OverlayCanvas: View {
    let session: GlanceSession
    let settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let region = session.region.rect
        ZStack(alignment: .topLeading) {
            if session.result == nil, session.phase != .failed {
                WorkingOutline()
            }
            if let result = session.result {
                blocks(result, origin: region.origin)
                    .opacity(session.isRevealingOriginal ? 0 : 1)
                    .animation(MotionAwareAnimation.quick(reduceMotion), value: session.isRevealingOriginal)
                    .transition(.opacity)
            }
        }
        .frame(width: region.width, height: region.height, alignment: .topLeading)
        .animation(MotionAwareAnimation.standard(reduceMotion), value: session.result?.outcome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Translation overlay")
    }

    private func blocks(_ result: GlanceResult, origin: CGPoint) -> some View {
        let layouts = Dictionary(uniqueKeysWithValues: session.blockLayouts.map { ($0.id, $0) })
        let rightToLeft = result.outcome.target.isRightToLeft
        return ZStack(alignment: .topLeading) {
            ForEach(result.pairs) { pair in
                if let layout = layouts[pair.id] {
                    TranslatedBlockView(
                        text: pair.translation,
                        original: pair.block.text,
                        layout: layout,
                        style: session.style,
                        backdrop: session.backdrops[pair.id],
                        subtitle: settings.subtitle,
                        isRightToLeft: rightToLeft,
                        isSingleLine: pair.block.lines.count <= 1
                    )
                    .frame(width: layout.frame.width, height: layout.frame.height)
                    .offset(x: layout.frame.minX - origin.x, y: layout.frame.minY - origin.y)
                }
            }
        }
    }
}

/// A calm pulsing outline that marks the region while text is read and translated.
private struct WorkingOutline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .opacity(reduceMotion ? 0.8 : (isBright ? 0.95 : 0.35))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isBright = true }
            }
            .accessibilityHidden(true)
    }
}
