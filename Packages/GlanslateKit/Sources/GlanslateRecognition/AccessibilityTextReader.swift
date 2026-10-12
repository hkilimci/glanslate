import ApplicationServices
import CoreGraphics
import Foundation
import GlanslateCore

/// Reads exact text from the Accessibility elements under a screen rectangle.
///
/// Only used when the user has granted Accessibility access. The walk is
/// bounded in elements and time, each request has a short messaging timeout,
/// and Glanslate's own windows are skipped.
public struct AccessibilityTextReader: Sendable {
    public var timeBudget: Duration = .milliseconds(450)
    public var maximumElements = 400

    public init() {}

    public static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Text fragments whose frames lie mostly inside `quartzRect` (Quartz global space).
    public func fragments(in quartzRect: CGRect) async -> [(text: String, quartzFrame: CGRect)] {
        guard Self.isAvailable, quartzRect.width > 0, quartzRect.height > 0 else { return [] }
        let budget = timeBudget
        let limit = maximumElements
        let walk = Task.detached(priority: .userInitiated) {
            Walker(rect: quartzRect, deadline: ContinuousClock.now + budget, limit: limit).run()
        }
        // Detached work doesn't inherit cancellation; forward it so an abandoned glance stops walking.
        return await withTaskCancellationHandler {
            await walk.value
        } onCancel: {
            walk.cancel()
        }
    }
}

private struct Walker {
    let rect: CGRect
    let deadline: ContinuousClock.Instant
    let limit: Int
    let ownPID = ProcessInfo.processInfo.processIdentifier

    static let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea", "AXHeading"]
    static let titledRoles: Set<String> = ["AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTab"]

    func run() -> [(text: String, quartzFrame: CGRect)] {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)

        var roots: [AXUIElement] = []
        for point in samplePoints() {
            guard !expired, !Task.isCancelled else { break }
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
                  let element, pid(of: element) != ownPID else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            // Climb a little so siblings of the hit element are visited too.
            let container = parent(of: element).flatMap { parent(of: $0) ?? $0 } ?? element
            if !roots.contains(where: { CFEqual($0, container) }) { roots.append(container) }
        }

        var results: [(text: String, quartzFrame: CGRect)] = []
        var visited: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = roots.map { ($0, 0) }
        while !queue.isEmpty, visited.count < limit, !expired, !Task.isCancelled {
            let (element, depth) = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)

            guard let frame = frame(of: element), frame.intersects(rect) else { continue }
            let role = string(element, "AXRole") ?? ""
            if let text = text(of: element, role: role) {
                let inside = frame.intersection(rect).area / max(frame.area, 1)
                if inside >= 0.5 { results.append((text, frame)) }
                if Self.textRoles.contains(role) { continue }
            }
            if depth < 6 {
                queue += children(of: element).map { ($0, depth + 1) }
            }
        }
        return results
    }

    private var expired: Bool { ContinuousClock.now >= deadline }

    private func samplePoints() -> [CGPoint] {
        let columns = 6, rows = 5
        var points: [CGPoint] = []
        for row in 0..<rows {
            for column in 0..<columns {
                points.append(CGPoint(
                    x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(rows)
                ))
            }
        }
        return points
    }

    private func text(of element: AXUIElement, role: String) -> String? {
        let raw: String?
        if Self.textRoles.contains(role) {
            raw = string(element, "AXValue") ?? string(element, "AXTitle")
        } else if Self.titledRoles.contains(role) {
            raw = string(element, "AXTitle")
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > 2_000 ? nil : text
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.prefix(200).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
