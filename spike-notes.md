# Phase 0.5 Spike Notes

**Date:** 2026-04-22
**Platform:** macOS 26.0 (arm64)
**Status:** COMPLETE

---

## Decision A: Glass Sampling

**Goal:** Verify `.glassEffect(.regular.tint(.blue.opacity(0.2)), in: .rect(cornerRadius: 8))` samples underlying desktop content.

**Method:** Create `Spikes/GlassSpike/main.swift` — a borderless transparent NSWindow at `.statusBar + 1` level over Safari, observe whether the glass effect shows Safari content or only the window's own content.

**Result:** DECISION B (fallback)

**Evidence:**
- `.glassEffect()` in a borderless `NSWindow` with `backgroundColor = .clear` and `isOpaque = false` does NOT sample underlying content.
- The glass effect only captures content within the window's bounds.
- `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` with `blendingMode = .behindWindow` and a transparent background DOES sample underlying content.

**Consequence for Blur Patch style (Phase 15):**
- Blur Patch uses `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` instead of `.glassEffect()`.
- This is a documented loss in Liquid Glass fidelity but is the only reliable approach for cross-app content capture.

---

## Decision C: Key-Window Event Delivery

**Goal:** Verify Esc key delivery in an `LSUIElement` app via local `NSEvent` monitor.

**Method:** In `Spikes/GlassSpike`, add `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`. Present the same window, press Esc, verify it reaches the monitor and dismisses the window.

**Result:** DECISION C (local monitor works)

**Evidence:**
- Local event monitors work correctly in an `LSUIElement` (menu bar extra) app.
- Esc reaches `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` when the window is key.
- No issues with focus or activation — the window becomes key when needed.
- CGEventTap is NOT required for Esc delivery.

**Consequence for Overlay (Phase 17):**
- Esc dismiss uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` inside the overlay session.
- No Input Monitoring permission required for basic Esc dismiss.
- Input Monitoring prompt is deferred for just-in-time CGEventTap only if additional global shortcuts are needed beyond what KeyboardShortcuts handles.

---

## Follow-up References

| Phase | Reference |
|-------|-----------|
| Phase 14 (Clean Patch) | Uses `.glassEffect()` — this works because it's inside the overlay window's own content |
| Phase 15 (Blur Patch) | Uses `NSVisualEffectView` — fallback per Decision B |
| Phase 17 (Toolbar) | Esc via local monitor per Decision C |
| Phase 18 (Global Shortcut) | Uses KeyboardShortcuts library — handles its own global monitoring |

---

## Spike Code

Preserved in `Spikes/GlassSpike/` — do not remove. Re-verify on OS updates.
