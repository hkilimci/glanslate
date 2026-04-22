# Glanslate — in-place macOS screen translation

## Objective
Native macOS app that translates text directly on the user's screen. Press shortcut → drag-select any screen region → app captures pixels, detects text (Accessibility arbitrated with Vision OCR) → translates line/block by line/block → renders translated result as a seamless overlay anchored to the original text coordinates. No popup, no floating window — translation appears to live inside the screen itself. "Google Lens for desktop" with Apple polish.

## Locked decisions (from grill)
- **Min target:** macOS 26.0 Tahoe. Liquid Glass design language throughout.
- **UI:** latest SwiftUI only. Observation framework (`@Observable`), `Scene`/`MenuBarExtra`/`Settings`, `.glassEffect(...)` + `GlassEffectContainer`, adaptive typography.
- **Distribution:** Developer ID signed + notarized, direct download. Not sandboxed (need reliable AX + global hotkey). MAS path deferred.
- **Global hotkey:** `KeyboardShortcuts` SPM package (sindresorhus) — user-recordable `.Name` + `Recorder` view.
- **App shape:** menu-bar primary (`LSUIElement=YES`). Settings opens as `Settings { ... }` scene on demand. Closing returns to menu-bar-only presence.
- **Screen capture:** ScreenCaptureKit (`SCScreenshotManager.captureImage`). Multi-monitor + Retina (`backingScaleFactor`) supported from v1.
- **Text detection:** arbitration between AX (primary candidate) and Vision (`VNRecognizeTextRequest(.accurate)`). Capture always runs; AX is a fast candidate, Vision always available for arbitration. Line/block level — never word-level.
- **Translation:** Hybrid. User-configured `preferredProvider` + `fallbackProvider`. Apple Translation framework (offline, native) available as a provider. Cloud providers (DeepL, Google, OpenAI) BYOK, Keychain-stored. No silent swap of providers.
- **Privacy + feedback:** captured pixels and OCR text stay in memory only unless the user pins. Cloud translation is explicit opt-in per provider with first-use disclosure that recognized text leaves the device. Routine invocation feedback uses app-owned in-process HUD toasts, not `UNUserNotificationCenter`, so notification permission is not part of onboarding.
- **Overlay styles:** Clean Patch, Blur Patch, Subtitle. Picker in Settings + per-invocation override on overlay toolbar. Live style swap during active overlay is supported.
- **Overlay controls:** dismiss (Esc), pin, hold-modifier peek-original, retranslate-to.
- **Text layout:** overlays stay visually anchored to source blocks, but may expand inside the captured selection when translated copy cannot fit legibly. Target-language directionality is honored (`ar` / `he` RTL).
- **History:** session-only by default; "Pin" persists via SwiftData and appears in Settings → History.

---

## Acceptance criteria (high-level)
- [ ] App launches headless with menu-bar item; user-configurable global hotkey fires a translation invocation.
- [ ] Pressing the hotkey dims all connected displays with a Liquid Glass selection HUD; user drags a rectangle on any one monitor. Cross-screen selection is rejected in v1.
- [ ] The invocation captures the selected region via ScreenCaptureKit into a retained `SourceVisualContext`.
- [ ] Text detection runs AX + Vision arbitration and returns `[TextBlock]` in display-local coordinates, paired with a `DisplayTopologySnapshot` taken at selection time.
- [ ] Blocks are translated via the user's `preferredProvider`; if preferred rejects (unsupported pair / missing key / API error), `fallbackProvider` is tried. User can override provider + source language per invocation from the overlay toolbar.
- [ ] First use of any cloud provider requires explicit disclosure that recognized text is sent off-device; logs, signposts, and app-managed diagnostics never contain raw source text, translated text, image bytes, or API keys.
- [ ] Translated blocks render in transparent overlay windows anchored to the original rects, with Retina backing scale respected. When translated copy cannot fit at a readable size, the patch may expand within the captured selection while keeping the source block centroid fixed and honoring LTR / RTL layout. Overlay style (Clean Patch, Blur Patch, Subtitle - selectable background and foreground color) picked from Settings; swappable live from the overlay toolbar.
- [ ] User can dismiss (Esc), pin, hold ⌥ to peek original, or retranslate to another target language. Second hotkey press cancels the active invocation and starts a new one.
- [ ] Display arrangement changes during an active invocation cancel the invocation with a user-visible toast.
- [ ] Pinned translations persist in SwiftData and re-open from Settings → History.
- [ ] App runs non-sandboxed as Developer ID signed + notarized bundle. Onboarding walks first-launch Screen Recording + Accessibility permissions with deep-links; Input Monitoring is requested just-in-time only if the chosen Esc strategy requires an event tap.
- [ ] "No text found" outcome: no overlay, single in-app HUD toast on the selected display, no history entry.

---

## Architecture

Single app target + internal Swift Package `GlanslateKit` with multi-target layout.

```
Glanslate.xcodeproj
├── Glanslate (app target, macOS 26)
│   ├── GlanslateApp.swift              (@main)
│   ├── AppRoot.swift                   (@Observable — wires InvocationController + UI roots)
│   ├── MenuBarExtraView.swift
│   ├── SettingsScene.swift             (uses SettingsStore)
│   ├── OnboardingWindow.swift
│   ├── Assets.xcassets
│   ├── Info.plist                      (LSUIElement, usage descriptions)
│   └── Glanslate.entitlements          (hardened-runtime defaults)
└── Packages/
    └── GlanslateKit/                   (local SPM, multi-target)
        ├── Package.swift
        └── Sources/
            ├── Core/                   (domain types, errors, logging)
            ├── Geometry/               (display topology + rect conversions)
            ├── Invocation/             (state machine + controller + pipeline)
            ├── Platform/               (shortcut, permissions, keychain — thin wrappers)
            ├── RegionSelect/           (per-screen HUD windows)
            ├── Capture/                (SCScreenshotManager wrapper)
            ├── TextDetect/             (concrete AX + Vision + arbitration)
            ├── Translation/            (Apple + Cloud engines + Router)
            ├── Overlay/                (base + styles + toolbar in one module)
            ├── History/                (SwiftData models + store)
            └── Settings/               (SettingsStore @Observable)
        └── Tests/
```

### Coordinate model (new, contradiction-free)

Only three spaces exist in the code:

1. **`CGDirectDisplayID` + `DisplayLocalRect`** — `(displayID: CGDirectDisplayID, rect: CGRect)`. `rect` origin is **top-left**, units **points**, relative to the display's **top-left corner**. This is the lingua franca.
2. **`MouseTrackingPoint`** — AppKit global (bottom-left). Only used **inside** `RegionSelect` while tracking the drag, then converted to `DisplayLocalRect` the moment the drag completes.
3. **Normalized Vision space (0...1, bottom-left)** — only inside `TextDetect/Vision`, immediately converted to `DisplayLocalRect` before leaving the module.

**Invariant:** any rect leaving a module is a `DisplayLocalRect` bound to an `entry.displayID` present in the invocation's snapshot. If the snapshot is invalidated (display change mid-pipeline), the invocation cancels. Geometry is geometry; display metadata lives on the invocation.

### Data flow (single invocation)

```
Hotkey
  └→ Shortcut.onKeyDown
       └→ InvocationController.start()                             (actor — owns currentInvocationID)
            └→ Invocation.snapshotTopology()                       (captures DisplayTopologySnapshot)
                 └→ RegionSelect.present(topology)                 → RegionSelection(DisplayLocalRect)
                      └→ Capture.snapshot(region, topology)        → SourceVisualContext (CGImage + metadata)
                           └→ TextDetect.extract(region, source, topology)
                                ├→ AXCandidate                      (concrete, fast path)
                                └→ VisionCandidate                  (always runs)
                                └→ Arbitrator                       → [TextBlock(DisplayLocalRect)]
                                     └→ TranslationRouter.translate(blocks, prefs, invocationOverrides)
                                          → [Translation]
                                               └→ OverlayEngine.present(session, retainedSource, settings)
                                                    └→ OverlayStyleRenderer picks current style each frame
```

### Key principles

- **One owner, one lifecycle:** `InvocationController` owns the current invocation and cancellation token. Every async step is cancellation-aware.
- **Capture always:** regardless of AX success, capture runs once per invocation. Styles and arbitration both consume `SourceVisualContext`. Discarded at dismissal (or downsampled + thumbnailed if pinned).
- **Protocols only where polymorphism is real:** `ScreenCapturing`, `TranslationEngine`, `OverlayPresenting`, `ShortcutBinding`. Detectors (`AXCandidate`, `VisionCandidate`) are concrete structs. `KeychainStore` concrete.
- **No callbacks. `async`/`await` throughout.** Cancellation via `Task`. `URLSession` tasks tied to invocation lifecycle.
- **Liquid Glass via `.glassEffect(...)` inside `GlassEffectContainer`** — fall back to `NSVisualEffectView` only if spike Phase 0.5 proves glass fails on transparent windows.
- **`@Observable` state containers.** No `@StateObject` / `@ObservedObject`.
- **Settings are live.** `SettingsStore` publishes updates; active overlays subscribe so style swaps apply in-place.
- **Privacy by default.** Signposts and logs are metadata-only. Raw source text, translated text, pixel buffers, and secrets never leave memory except when the user explicitly chooses a cloud provider or pins history.

### Cancellation rules (explicit table)

| Trigger | Effect |
|---|---|
| Esc while any HUD/overlay has key focus | Cancel current invocation. If overlay was pinned, unpin+close. |
| Second hotkey press | Cancel current invocation, immediately start a new one. |
| Window close request on overlay | Same as Esc. |
| `NSApplication.didChangeScreenParametersNotification` mid-invocation | Cancel invocation; show toast "Display arrangement changed — please retry". |
| Display power-off (via `CGDisplayRegisterReconfigurationCallback`) | Same as topology change. |
| Translation engine network error after all fallbacks | Surface toast; overlay not presented; invocation ends. |
| App terminate | Cancel all active invocations + dismiss overlays (non-pinned released; pinned state persisted to SwiftData before exit if user enabled auto-persist — v1: pinned are already in SwiftData the moment they are pinned, so nothing to do). |

---

## Invocation state machine

```
idle
 ├── user presses hotkey ──▶ selecting
 │    ├── Esc / cancel ──▶ idle
 │    └── region selected ──▶ capturing
 │         ├── cancel ──▶ idle
 │         ├── permission denied ──▶ permissionPrompt ──▶ idle
 │         └── captured ──▶ detecting
 │              ├── cancel ──▶ idle
 │              └── blocks returned (possibly empty) ──▶ translating | noTextToast
 │                   ├── cancel ──▶ idle
 │                   ├── translation failed (after fallback) ──▶ errorToast ──▶ idle
 │                   └── translations returned ──▶ presenting
 │                        ├── cancel ──▶ idle
 │                        ├── pinned ──▶ persisted (SwiftData) ──▶ presentingPinned
 │                        └── dismissed ──▶ idle
 └── second hotkey ──▶ cancel current ──▶ selecting (new invocation id)
```

Every state transition logs a `signpost` for Instruments.

---

## Phased plan (TDD throughout)

### Milestone 0 — Foundation + risk spike

#### Phase 0: Project scaffold


- Create Xcode project `Glanslate.xcodeproj`, macOS app target, min deployment **macOS 26.0**, Swift 6, SwiftUI lifecycle.
- Local SPM package `Packages/GlanslateKit/Package.swift` with library targets listed in Architecture; matching test targets.
- App target depends on all `GlanslateKit` libraries.
- SPM deps: `sindresorhus/KeyboardShortcuts` (pinned 2.x).
- `Info.plist`: `LSUIElement = YES`, `NSScreenCaptureUsageDescription`, `NSAccessibilityUsageDescription`, `CFBundleDisplayName = "Glanslate"`, `LSMinimumSystemVersion = 26.0`.
- `Glanslate.entitlements`: hardened-runtime defaults; no sandbox.
- Minimal `GlanslateApp`:
  ```swift
  @main
  struct GlanslateApp: App {
      var body: some Scene {
          MenuBarExtra("Glanslate", systemImage: "character.bubble") {
              Text("Glanslate")
          }
          .menuBarExtraStyle(.menu)
          Settings { Text("Settings placeholder") }
      }
  }
  ```
- Signing config via `.xcconfig` (`DEVELOPMENT_TEAM` overridable).

**Tests (acceptance):**
- [ ] `swift test --package-path Packages/GlanslateKit` green (smoke test per target).
- [ ] `xcodebuild -project Glanslate.xcodeproj -scheme Glanslate build` clean (zero warnings).
- [ ] Launch: menu-bar icon present, no dock icon, Settings opens empty.

---

#### Phase 0.5: Liquid Glass + key-window spike

**Why before overlay phases:** two load-bearing assumptions need verification before Overlay architecture is finalized.

**Spike goals:**
1. **Glass sampling.** Create a sandbox target `Spikes/GlassSpike` containing a non-main app (or a hidden unit-test harness with an NSWindow). Present a borderless transparent `NSWindow` at `.statusBar + 1` level over the user's desktop while another app (e.g. Safari) is frontmost. Inside, a `RoundedRectangle().glassEffect(.regular.tint(.blue.opacity(0.2)), in: .rect(cornerRadius: 8))` inside a `GlassEffectContainer`. Verify visually + via screenshot comparison that the glass samples the underlying desktop content, not only content inside the window.
2. **Key-window event delivery in `LSUIElement` app.** `Info.plist` sets `LSUIElement=YES`. Present the same window and attempt:
   - Local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` while the window is `makeKey()`.
   - Does Esc reach the monitor? Does the active app lose focus when the window becomes key?
   - If local monitor is unreliable, fallback: `NSEvent.addGlobalMonitorForEvents` + `CGEventTap` passively observing keyDown; measure delivery latency.

**Outputs:** `spike-notes.md` at repo root with findings, screenshots, and a **decision**:
- **Decision A:** Glass works → Blur Patch style (Phase 12) uses `.glassEffect(...)`.
- **Decision B:** Glass fails → Blur Patch uses `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` hosted via `NSViewRepresentable`, with a documented loss in Liquid Glass fidelity.
- **Decision C:** Key-window delivery works → Esc via local monitor.
- **Decision D:** Key-window delivery fails → Esc via `CGEventTap` with `.listenOnly` (requires a just-in-time Input Monitoring step when first needed) OR a hidden always-active control panel at `.popUpMenu` level listening for local events.

**Acceptance:**
- [ ] Decisions logged in `spike-notes.md` with evidence.
- [ ] Follow-up phases reference the decision id.
- [ ] Spike code preserved under `Spikes/` (not removed) so the assumptions can be re-verified on OS updates.

---

### Milestone 1 — Core types + geometry

#### Phase 1: Core domain types

**Module:** `GlanslateKit/Core`

```swift
public struct TextBlock: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let region: DisplayLocalRect
    public let detectedLanguage: Language?   // nil when uncertain / mixed
    public let confidence: Double            // 0...1
    public let source: Source
    public enum Source: String, Hashable, Sendable { case accessibility, vision, arbitrated }
}

public struct DisplayLocalRect: Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let rect: CGRect                  // points, top-left origin within display
    public init(displayID: CGDirectDisplayID, rect: CGRect)
}

public enum Language: String, Hashable, Sendable, Codable, CaseIterable {
    case auto                                // source only — represents "auto-detect"
    case en, tr, es, fr, de, it, pt, ru, ja, ko
    case zhHans = "zh-Hans", zhHant = "zh-Hant"
    case ar, hi, pl, nl, sv, cs, uk, he
    public var displayName: String { ... }
}

public struct Translation: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let block: TextBlock
    public let translatedText: String
    public let targetLanguage: Language
    public let provider: TranslationProvider
}

public enum TranslationProvider: String, Sendable, Codable {
    case apple, deepL, google, openAI
}

public enum OverlayStyle: String, Sendable, Codable, CaseIterable {
    case cleanPatch, blurPatch, subtitle
}

public enum PermissionKind: String, Sendable {
    case screenRecording, accessibility, inputMonitoring
}

public enum GlanslateError: Error, Sendable, Equatable {
    case permissionDenied(PermissionKind)
    case capture(reason: String)
    case detection(reason: String)
    case noTextFound
    case translation(provider: TranslationProvider, reason: String)
    case unsupportedPair(TranslationProvider, from: Language?, to: Language)
    case missingAPIKey(TranslationProvider)
    case crossScreenSelectionRejected
    case displayTopologyChanged
    case cancelled
}
```

Logging: `os.Logger` subsystem `com.glanslate.app`, categories per module.

**Tests:**
- Hash stability of `TextBlock` across runs.
- `Language` Codable round-trip for every case.
- `GlanslateError` equality + localizedDescription coverage.
- `DisplayLocalRect` equality treats different `displayID` for same `rect` as non-equal.

---

#### Phase 2: Geometry / topology

**Module:** `GlanslateKit/Geometry`

```swift
public protocol DisplayTopologyProviding: Sendable {
    func current() -> DisplayTopologySnapshot
}

public struct RealDisplayTopology: DisplayTopologyProviding { public init() }

public struct GeometryConverter: Sendable {
    public init(snapshot: DisplayTopologySnapshot)

    public func displayLocal(fromAppKitGlobalPoint p: CGPoint) -> (displayID: CGDirectDisplayID, local: CGPoint)?
    public func displayLocal(fromAppKitGlobalRect r: CGRect) -> DisplayLocalRect?  // rejects cross-screen
    public func appKitGlobal(fromDisplayLocalRect r: DisplayLocalRect) -> CGRect

    public func displayLocal(visionNormalized r: CGRect, capturedFrom displayID: CGDirectDisplayID) -> DisplayLocalRect

    public func pixelRect(forDisplayLocal r: DisplayLocalRect) -> CGRect   // multiplies by backingScale
}
```

**Tests:**
- Single 1x display.
- Single 2x display.
- Dual-display side-by-side: primary 1x at (0,0), secondary 2x to the right.
- **Vertical arrangement: primary at (0,0), secondary placed above → AppKit global y negative for secondary.** Conversions must produce correct display-local coords.
- Cross-screen rect returns nil.
- Vision normalized (0.5, 0.5, 0.1, 0.1) on 2x display round-trips to expected display-local rect then expected pixel rect.

Acceptance: 100% branch coverage.

---

### Milestone 2 — Platform + Invocation

#### Phase 3: Platform wrappers (shortcut, permissions, keychain)

**Module:** `GlanslateKit/Platform`

Three thin concrete types; no unnecessary protocols.

```swift
public struct ShortcutBinding: Sendable {
    public static let translateRegion = KeyboardShortcuts.Name("translateRegion",
        default: .init(.t, modifiers: [.command, .shift]))
    public static func onTrigger(_ handler: @escaping @Sendable () -> Void) { ... }
}

public struct PermissionProbe: Sendable {
    public static func screenRecordingGranted() -> Bool          // CGPreflightScreenCaptureAccess()
    public static func accessibilityGranted(promptIfNot: Bool) -> Bool
    public static func inputMonitoringGranted() -> Bool
    public static func openPane(_ kind: PermissionKind)          // x-apple.systempreferences URLs
}

public struct KeychainStore: Sendable {
    public init(service: String = "com.glanslate.app")
    public func set(_ value: String, for account: String) throws
    public func get(_ account: String) throws -> String?
    public func delete(_ account: String) throws
}
```

**Tests:**
- `KeychainStore` integration against real Keychain with unique service names per test.
- `PermissionProbe` URL strings match current Tahoe pane URLs (hard-coded, verified manually during Phase 0.5 spike).

---

#### Phase 4: InvocationController + pipeline skeleton

**Module:** `GlanslateKit/Invocation`

The heart of the app. Single actor that owns all running invocations and their cancellation tokens.

```swift
public actor InvocationController {
    public init(
        topology: DisplayTopologyProviding,
        regionSelect: RegionSelecting,
        capture: ScreenCapturing,
        detect: TextDetectionPipeline,
        translate: TranslationRouting,
        overlay: OverlayPresenting,
        history: HistoryStoring,
        settings: SettingsStore
    )
    public func start()                   // cancels any current + starts new
    public func cancelCurrent()
    public var state: AsyncStream<InvocationState> { get }
}

public struct Invocation: Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let topology: DisplayTopologySnapshot
    public var region: DisplayLocalRect?
    public var source: SourceVisualContext?
    public var blocks: [TextBlock]?
    public var translations: [Translation]?
    public var state: InvocationState
}

public enum InvocationState: Sendable, Hashable {
    case idle
    case selecting
    case capturing
    case detecting
    case translating
    case presenting(overlaySessionID: UUID)
    case cancelled
    case errored(GlanslateError)
}

public struct SourceVisualContext: Sendable {
    public let image: CGImage
    public let region: DisplayLocalRect
    public let topology: DisplayTopologySnapshot
    public let pixelScale: CGFloat
    public let capturedAt: Date
}
```

**Tests:**
- Start → selecting → cancelled via Esc → idle.
- Two rapid starts: first cancels, second runs to completion; only the second's state transitions are observed by new subscribers.
- Topology change notification during any stage → `errored(.displayTopologyChanged)` + active overlays dismissed.
- Happy path: state progression matches enum order.

**Note:** for this phase, `regionSelect`, `capture`, `detect`, `translate`, `overlay` are injected as fakes/stubs. The controller is plumbing — real impls arrive in later phases.

---

### Milestone 3 — Capture & region select

#### Phase 5: Region-select HUD
**Module:** `GlanslateKit/RegionSelect`

**API:**
```swift
public protocol RegionSelecting: Sendable {
    func selectRegion(in topology: DisplayTopologySnapshot) async -> RegionSelection?
}

public struct RegionSelection: Sendable {
    public let region: DisplayLocalRect
    public let topology: DisplayTopologySnapshot
}
```

**Behavior:**
- One borderless `NSWindow` per topology entry at `.screenSaver - 1` level; `.canJoinAllSpaces, .stationary, .fullScreenAuxiliary`; `isOpaque = false`, clear background, `ignoresMouseEvents = false`.
- Hosts a `RegionSelectView` (NSHostingView): dim backdrop (black 18% + Liquid Glass tint), crosshair cursor via `NSCursor.crosshair`, marquee rect with 1pt stroke + 2pt glow.
- Dimension chip (W × H pt) floats near marquee, Liquid Glass.
- Esc cancels (HUD monitors its own key events — test per spike decision).
- **Cross-screen selection:** if drag starts on screen A and ends on screen B, reject with a gentle shake animation + chip text "Select on one display"; do not emit a selection.
- Mouse coords tracked via `NSEvent.mouseLocation` (AppKit global), converted to display-local the instant the drag completes via `GeometryConverter.displayLocal(fromAppKitGlobalRect:)`.

**Tests:**
- Marquee normalization (drag ↙︎ or ↗︎ both produce origin at min x/y).
- Cross-screen rejection emits nil + documented event.
- Esc → nil.
- Topology has 2 entries → 2 windows created, 2 dismissed.

Acceptance: manual drag on live system produces correct `DisplayLocalRect`.

---

#### Phase 6: ScreenCaptureKit capture

**Module:** `GlanslateKit/Capture`

```swift
public protocol ScreenCapturing: Sendable {
    func snapshot(_ region: DisplayLocalRect, topology: DisplayTopologySnapshot) async throws -> SourceVisualContext
}

public struct SCKScreenCapturer: ScreenCapturing {
    public init(excludedBundleIDs: Set<String> = ["com.glanslate.app"])
}
```

**Impl details:**
- Pre-flight `PermissionProbe.screenRecordingGranted()` → throw `.permissionDenied(.screenRecording)` if false.
- `SCShareableContent.current` (await); filter displays by `displayID`; build `SCContentFilter(display: _, excludingApplications: ourApp, exceptingWindows: [])`.
- `SCStreamConfiguration`:
  - `sourceRect = region.rect` (points, top-left within display).
  - `width/height = Int(region.rect.width * backingScale)`, `Int(region.rect.height * backingScale)`.
  - `pixelFormat = kCVPixelFormatType_32BGRA`, `captureDynamicRange = .sdrWithExtendedRange`.
  - `showsCursor = false`, `capturesAudio = false`.
- `SCScreenshotManager.captureImage(contentFilter:configuration:)` (macOS 14+ API, works on 26).
- **HDR note:** when captured range is extended, tone-map to sRGB via `CIFilter.toneCurve` before returning; document in comments that downstream luminance analysis assumes sRGB.
- **Timing:** before building the filter, await one frame (`await Task.yield()` + a 16 ms sleep) so the HUD dismissal has been committed to the display buffer — avoids self-capture race.

**Tests:**
- Inject fake `SCContentFetching` + fake `SCCapturing` protocols (two tiny shims wrapping the real classes) to assert correct construction of `SCContentFilter`/`SCStreamConfiguration` given a region.
- Permission denied → correct error.
- HDR path: fed a mock wide-gamut `CGImage` via test-only initializer and asserted converted to sRGB.

---

#### Phase 7: Vertical slice — end-to-end smoke

**Module:** app target + test harness

**Why now:** before expanding text-detect and translation, prove the pipeline shape with fakes.

**Wire in:**
- `FakeTextDetectionPipeline` returns one hard-coded `TextBlock` at rect `(10,10,200,24)`.
- `FakeTranslationRouter` returns `"HELLO"` uppercased input.
- `MinimalOverlayPresenter` (concrete, not Liquid Glass) renders a single black-background rect with white text at the block's location in a transparent overlay window.
- `AppRoot` constructs `InvocationController` with real `RegionSelect`, real `Capture`, fake detect + translate, minimal overlay.

**Acceptance (manual):** build, launch, press ⌘⇧T, drag a region over any text, see "HELLO" rendered at (10,10) inside the region on the correct display. Esc dismisses. Second hotkey cancels + restarts. Display-change notification cancels.

This phase's fakes are kept in the test target and used thereafter for unit-testing `InvocationController` against real `RegionSelect` + `Capture`.

---

### Milestone 4 — Text detection (arbitration)

#### Phase 8: Vision text detector

**Module:** `GlanslateKit/TextDetect` (type `VisionCandidate`)

Concrete struct:
```swift
struct VisionCandidate {
    func detect(_ source: SourceVisualContext) async throws -> [TextBlock]
}
```

- `VNRecognizeTextRequest`:
  - `recognitionLevel = .accurate`
  - `usesLanguageCorrection = true`
  - `automaticallyDetectsLanguage = true`
  - `minimumTextHeight = 0.01`
- Converts each `VNRecognizedTextObservation.boundingBox` via `GeometryConverter.displayLocal(visionNormalized:capturedFrom:)` to `DisplayLocalRect`.
- Block grouping heuristic (as before):
  1. Sort observations by `rect.minY`.
  2. Merge observations whose `|Δy| < 0.6 × median line height` into lines.
  3. Merge lines into blocks when `Δy < 1.4 × line height` AND horizontal overlap > 60%.
  4. CJK vertical heuristic: if `NLLanguageRecognizer` identifies ja/ko/zh on ≥ 60% of observations AND aspect-ratio majority is tall, group by x-bands instead.
- Detected language per block: run `NLLanguageRecognizer` on the block text. If top guess confidence < 0.6 OR multiple langs above 0.2, set `detectedLanguage = nil` (mixed/unknown).

**Tests:** three fixture images (Latin paragraph, CJK column, mixed two-column code + English comment) — assert block count + rect tolerances (±3pt) + detected language matches expectation or is nil for mixed.

---

#### Phase 9: Accessibility candidate

**Module:** `GlanslateKit/TextDetect` (type `AXCandidate`)

```swift
struct AXCandidate {
    func detect(_ region: DisplayLocalRect, topology: DisplayTopologySnapshot) async throws -> AXDetectionReport
}

struct AXDetectionReport {
    let blocks: [TextBlock]
    let quality: Double     // heuristic 0...1 — see below
    let coverageRatio: Double // (sum of detected block area) / region area
}
```

**Impl:**
- Preflight `PermissionProbe.accessibilityGranted(promptIfNot: false)`. If false → returns empty report with quality = 0.
- Sample grid (e.g. 6×6) of points inside the region; for each, `AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &el)`.
- Collect unique elements (by `AXUIElementGetPid` + `kAXIdentifierAttribute` or reference equality fallback).
- For each leaf with `kAXRoleAttribute in {AXStaticText, AXTextField, AXTextArea, AXLink}`, extract `kAXValueAttribute` and `kAXFrameAttribute`. If element supports `kAXStringForRangeParameterizedAttribute`, walk range to get per-line frames via `kAXBoundsForRangeParameterizedAttribute`.
- Clip element frames against `region.rect`; discard <40% overlap.
- Map frames (AppKit global screen coords) → `DisplayLocalRect` via `GeometryConverter`.
- **Quality heuristic:** `quality = min(1, coverageRatio) * (text_len / expected_chars_for_area)`. `expected_chars_for_area` is a rough chars-per-square-inch figure derived from block median font size. Below 0.4 triggers Vision arbitration.

**Tests:** mock `AXElementTreeProviding` protocol (only boundary where protocol is kept) returning scripted trees; assert quality calculation + clipping + frame conversion.

---

#### Phase 10: Arbitrator + `TextDetectionPipeline`

**Module:** `GlanslateKit/TextDetect`

Concrete struct, no protocol (only one implementation):

```swift
struct TextDetectionPipeline {
    let ax: AXCandidate
    let vision: VisionCandidate

    func detect(_ source: SourceVisualContext) async throws -> [TextBlock] {
        async let axReport = ax.detect(source.region, topology: source.topology)
        async let visionBlocks = vision.detect(source)

        let axR = try await axReport
        let v = try await visionBlocks

        if axR.blocks.isEmpty && v.isEmpty { throw GlanslateError.noTextFound }

        // arbitration
        if axR.quality >= 0.7 && axR.coverageRatio >= 0.8 { return axR.blocks }
        if axR.blocks.isEmpty { return v }
        if v.isEmpty { return axR.blocks }
        return merge(ax: axR.blocks, vision: v)   // see below
    }
}
```

`merge`:
- For each Vision block, find overlapping AX block (>60% IOU).
- If overlap exists: prefer AX text (semantically correct), but prefer Vision rect (pixel-accurate bounds). Marked `source = .arbitrated`.
- If no overlap in AX: include the Vision block standalone.
- If AX-only block has no Vision counterpart: include AX block if its rect is supported by ≥1 Vision observation pixel (sanity check).

Capture is always available (Phase 4 pipeline always captures). AX and Vision run concurrently with `async let`. Arbitrator never silently hides better Vision results behind a low-quality AX shortcut.

**Tests:**
- AX high quality → returns AX only.
- AX empty → returns Vision.
- AX tiny + Vision large → arbitrated merge.
- Both empty → `noTextFound`.

---

### Milestone 5 — Translation

#### Phase 11: Apple Translation engine

**Module:** `GlanslateKit/Translation`

```swift
public protocol TranslationEngine: Sendable {
    var identifier: TranslationProvider { get }
    func canTranslate(from: Language?, to: Language) async -> AvailabilityStatus
    func translate(_ blocks: [TextBlock], from: Language?, to: Language) async throws -> [Translation]
}

public enum AvailabilityStatus: Sendable {
    case supported
    case needsDownload
    case unsupported
}

public struct AppleTranslationEngine: TranslationEngine { ... }
```

- `LanguageAvailability().status(from:to:)` → map.
- If `needsDownload`: surface via `AsyncStream<PrepareProgress>` on `SettingsStore`; show one-shot modal when user picks a target that requires download.
- Translate with `TranslationSession.translate(_:)` batch API (macOS 26 expanded batch; verify via docs at impl time).

**Tests:**
- Mock `LanguageAvailabilityProviding` (injected protocol) returning all three states.
- ID alignment: input block ids must match output translation ids.

---

#### Phase 12: Cloud engines + Router

**Module:** `GlanslateKit/Translation/Cloud`

Three concrete engines (`DeepLEngine`, `GoogleEngine`, `OpenAIEngine`) each conforming to `TranslationEngine`. Shared `HTTPClient` thin wrapper over `URLSession` (no external dep). Keys pulled from `KeychainStore` per call.

Common cloud policy:
- First-use disclosure gate per provider. Until the user accepts "recognized text will be sent to this provider", router must refuse cloud translation for that provider.
- `HTTPClient` defaults: 15 s request timeout, cancellation-aware requests, retry once on `408` / `429` / `5xx` with jittered exponential backoff capped at 1.5 s.
- Never retry auth / validation failures (`400`, `401`, `403`, `404`).
- Observability is metadata-only: provider, batch size, status code, latency, retry count. Request / response bodies, API keys, OCR text, and translated text are always redacted.

**DeepL:**
- `POST https://{base}/v2/translate` where `{base}` chosen by key suffix (`:fx` → `api-free.deepl.com`).
- Body: `text=[...]&target_lang=...&preserve_formatting=1&tag_handling=xml`. Use XML tag `<b>` around each block with `id` attribute so response order is preserved regardless of batching.
- Auth header `DeepL-Auth-Key <key>`.
- Batch up to 50 blocks per request; split larger batches.

**Google:**
- `POST https://translation.googleapis.com/v3/projects/{projectId}/locations/global:translateText?key={apiKey}`.
- `contents: [String]`, `sourceLanguageCode`, `targetLanguageCode`, `mimeType: text/plain`.
- Batch up to 1024.

**OpenAI:**
- `POST https://api.openai.com/v1/responses`.
- Structured output schema `{translations: [{id: string, text: string}]}`.
- Model default `gpt-5.4-mini`, overridable in Settings.
- Prompt template: preserve original line breaks within a block; don't translate proper nouns, code, identifiers; follow user glossary (stub v1, populated later).

**Router (concrete actor):**
```swift
public actor TranslationRouter: TranslationRouting {
    public init(engines: [TranslationProvider: TranslationEngine], settings: SettingsStore, keychain: KeychainStore)

    public func translate(_ blocks: [TextBlock], to target: Language,
                          invocationOverride: InvocationRoutingOverride? = nil) async throws -> [Translation]
}

public struct InvocationRoutingOverride: Sendable {
    public let provider: TranslationProvider?
    public let sourceLanguage: Language?  // .auto = let engine detect
}
```

Explicit routing policy (NO hidden Apple default):

1. `preferred = invocationOverride?.provider ?? settings.preferredProvider`.
2. `preferred` engine's `canTranslate(from:to:)` queried.
3. If `supported` or `needsDownload` → use preferred (download flow triggers if needed).
4. If `unsupported` or key missing → try `settings.fallbackProvider`.
5. If fallback also unavailable → throw `unsupportedPair` with clear error surfaced as toast.

Source language handling:
- `invocationOverride?.sourceLanguage ?? dominant detectedLanguage across blocks if > 0.7 confidence ?? nil` (auto-detect at engine).
- If mixed-language invocation and engine accepts auto, pass nil.

**Tests:**
- Mock `URLProtocol` for each engine; golden request bodies; round-trip id alignment.
- Router policy matrix: preferred supported → preferred; preferred unsupported → fallback; both unavailable → error.
- Override beats preferred.
- Detected language uncertain → passed as nil.
- First-use disclosure gate blocks sends until accepted.
- `429` / `5xx` retried once; auth failure is not retried; cancellation aborts immediately.

---

### Milestone 6 — Overlay (one owner, full scope)

#### Phase 13: OverlayEngine foundation
**Module:** `GlanslateKit/Overlay` — single module owning windows, session, all three style renderers, toolbar.

```swift
public protocol OverlayPresenting: Sendable {
    func present(_ session: OverlaySessionModel) async -> OverlaySessionHandle
    func dismissAll() async
}

public struct OverlaySessionModel: Sendable {
    public let invocationID: UUID
    public let topology: DisplayTopologySnapshot
    public let source: SourceVisualContext   // retained for styles
    public let translations: [Translation]
}

public actor OverlaySessionHandle {
    public func pin() async
    public func retranslate(to: Language) async
    public func setStyle(_ style: OverlayStyle) async    // live swap
    public func dismiss() async
    public var events: AsyncStream<OverlayEvent> { get }
}

public enum OverlayEvent: Sendable {
    case styleChanged(OverlayStyle)
    case retranslateRequested(Language)
    case pinned
    case dismissed
    case peekBegan; case peekEnded
}
```

Base responsibilities:
- One `NSWindow` per entry in `session.topology`; hosts `OverlayRootView` (SwiftUI) sized to entry's `frame`.
- Hit-test strategy decided in Phase 0.5 spike: either window key + local monitor, OR window `ignoresMouseEvents = true` + a tiny always-on "control panel" window capturing keys.
- `OverlayRootView` observes `SettingsStore` for `overlayStyle`, `overlayOpacity`, `peekModifier`.
- Text-fit policy: render inside the original block rect at the preferred size first. If translated text does not fit, prefer extra wrapping, then symmetric expansion within `session.source.region.rect` while keeping the source block center fixed; only then scale down, never below the readability floor (14 pt for patch styles, 12 pt for subtitle).
- Writing direction: `translation.targetLanguage` of `ar` or `he` sets `.rightToLeft` layout, trailing alignment, and mirrored wrapping; all other targets use `.leftToRight`.
- For each translation, absolutely-positioned subview using `DisplayLocalRect` → window-local rect via `GeometryConverter`.
- Active `OverlayStyleRenderer` picks current style each frame (latest-wins):
  ```swift
  protocol OverlayStyleRenderer {
      associatedtype Body: View
      @ViewBuilder func body(for translation: Translation, source: SourceVisualContext, settings: SettingsStore) -> Body
  }
  ```
- Modifier-hold peek: global monitor watches `.flagsChanged`; toggles alpha on translations (0 → reveal original), doesn't dismiss.
- Dismissal: Esc → `handle.dismiss()`. Second hotkey → `InvocationController` cancels current → dismissAll.
- Memory budget: on dismissal (non-pinned), release `SourceVisualContext`. On pin, crop source to block bounds union, downsample to max 512×512 PNG, persist via SwiftData; release full-resolution.

**Tests:**
- Session lifecycle (present → dismiss → no leaks verified via weak refs in test).
- Style swap reflected by next render frame.
- Display-change mid-session dismisses gracefully.
- Long-text expansion stays within invocation bounds and preserves the source block center.
- Arabic / Hebrew target renders with correct alignment and wrapping.

---

#### Phase 14: Clean Patch renderer
**Module:** `GlanslateKit/Overlay/Styles/CleanPatch`

- Background: `RoundedRectangle(cornerRadius: 6)` filled by choice logic:
  - If `SourceVisualContext` area luminance variance < 0.1 → solid matched tint pulled from average color (muted, 94% opacity).
  - Else `.regularMaterial` + `.glassEffect(.regular)` (if spike Decision A) or `NSVisualEffectView(material: .contentBackground)` (Decision B).
- Text: `.font(.system(.body, design: .default))`, `.minimumScaleFactor(0.6)`, padding `max(2, blockHeight * 0.08)`.
- Contrast: luminance sampled from (tone-mapped sRGB) source rect; text `.white`/`.black` accordingly; 0.5pt shadow.
- Rounded edges bleed 1pt outside the block rect to hide AA seams.

**Acceptance (manual):** overlay fully covers original text with minimal visual intrusion; readable on dark + light backgrounds.

---

#### Phase 15: Blur Patch renderer
**Module:** `GlanslateKit/Overlay/Styles/BlurPatch`

- **If spike Decision A (glass works over desktop):** `GlassEffectContainer { Rectangle().glassEffect(.regular.tint(autoTint), in: .rect(cornerRadius: 8)) }`. Tint derived from average color of block region in source.
- **If spike Decision B:** place the cropped block region from `SourceVisualContext` behind the text, blurred via `Image(cgImage:).blur(radius: 18)`, then text with subtle tint overlay.
- Custom `TextRenderer` with 0.5pt stroke + matched text color.

**Acceptance:** modern look, original text obscured, translation legible.

---

#### Phase 16: Subtitle renderer
**Module:** `GlanslateKit/Overlay/Styles/Subtitle`

- Transparent backdrop.
- Custom `TextRenderer` drawing:
  - Outline: text path stroked 1pt (black with 0.9 alpha).
  - Fill: `.white` (or sampled contrast color).
  - Shadow: `.black.opacity(0.7)`, radius 2, y 1.
- Optional hairline `.strokeBorder(.black.opacity(0.12))` on the block rect (user toggle in Settings).

**Acceptance:** translation floats over source text without fully hiding it; works over photos, video thumbnails, busy UIs.

---

#### Phase 17: Overlay toolbar
**Module:** `GlanslateKit/Overlay/Toolbar`

- Liquid Glass chip anchored top-right of the invocation's union rect.
- Buttons: Dismiss, Pin, Peek hold indicator, Retranslate-to (dropdown), Style picker (segmented 3-way), Provider override (dropdown — Apple/DeepL/Google/OpenAI).
- Hover reveal: 30% alpha at rest, 100% when pointer within 80pt (via `onHover` + frame-target).
- Keyboard: Esc dismiss; ⌘P pin; hold `peekModifier` (configurable).
- Actions dispatch to `OverlaySessionHandle`.

**Tests:** action routing; hover opacity state machine.

---

### Milestone 7 — Shortcut + UI shell

#### Phase 18: Global shortcut wiring

**Module:** `GlanslateKit/Platform` (extending `ShortcutBinding`)

- `ShortcutBinding.onTrigger { Task { await appRoot.invocationController.start() } }`.
- Reentry: `start()` always cancels current and starts new (policy resolved per review).

**Tests:** fake binding + controller; three rapid triggers → only one finished invocation.

---

#### Phase 19: Settings scene
**Module:** app target + `GlanslateKit/Settings`

`SettingsStore` (`@Observable`) holds:
- `preferredProvider: TranslationProvider`, `fallbackProvider: TranslationProvider`
- BYOK — keys read/written via `KeychainStore`, never cached in store itself
- `acceptedCloudDisclosureProviders: Set<TranslationProvider>`
- `defaultTargetLanguage: Language`
- `overlayStyle: OverlayStyle`, `overlayOpacity: Double`, `peekModifier: ModifierKey`
- `showOnboarding: Bool`

Scene:
- Tabs (SF Symbols, Tahoe tab bar): Shortcut, Translation, Overlay, History, About.
- Shortcut tab: `KeyboardShortcuts.Recorder("Translate Region", name: .translateRegion)`.
- Translation tab: preferred + fallback pickers; per-provider SecureField for API key + test-connection button; cloud providers show an explicit "recognized text leaves this Mac" disclosure before enablement.
- Overlay tab: style picker live-preview; opacity slider; peek modifier; toggle for Subtitle's hairline border.
- History tab: SwiftData `@Query` list.
- About tab: version, license, support link.

Changes propagate to any active overlay session via `SettingsStore` subscription.

---

#### Phase 20: Onboarding window
**Module:** app target

- First run (`UserDefaults.didShowOnboarding == false`) presents a `Window` scene (style `.plain`, 640×480, Liquid Glass).
- Three steps: welcome, Screen Recording permission, Accessibility permission.
- Each step polls `PermissionProbe` every 500 ms until granted; auto-advances.
- Deep-link buttons via `PermissionProbe.openPane(_:)`.
- Final step: inline `KeyboardShortcuts.Recorder`. Close sets `didShowOnboarding = true`.
- Input Monitoring prompt deferred: only shown the first time a global event tap is required (per spike decision), as a separate just-in-time sheet rather than a mandatory first-run step.

---

### Milestone 8 — History

#### Phase 21: SwiftData pinned translations

**Module:** `GlanslateKit/History`

```swift
@Model
public final class PinnedTranslation {
    @Attribute(.unique) public var id: UUID
    public var sourceText: String
    public var translatedText: String
    public var sourceLanguage: String    // raw language code; nil stored as "auto"
    public var targetLanguage: String
    public var provider: String
    public var createdAt: Date
    public var snapshotPNG: Data?
    public init(...)
}

public protocol HistoryStoring: Sendable {
    func pin(_ translation: Translation, thumbnail: Data?) async throws
    func list() async throws -> [PinnedTranslation]
    func delete(_ id: UUID) async throws
}
```

- `ModelContainer(for: PinnedTranslation.self)` constructed at app start; injected via `AppRoot`.
- Overlay `pin()` serializes one row + calls `OverlayEngine` to discard the full-res source and keep the thumbnail.

**Tests:** in-memory container round-trip; pin/delete.

---

### Milestone 9 — End-to-end polish

#### Phase 22: Integration hardening

- Replace fakes from Phase 7 with real detectors + translators.
- Error UX: app-owned transient HUD toasts on the affected display for:
  - No text found
  - Display topology changed
  - Translation failed (after fallback)
  - Cross-screen selection rejected
  - Permission denied (open onboarding step inline)
- Signposts around each pipeline stage.
- Review cancellation coverage: Instruments leak check on 10 rapid-fire invocations; expect zero leaked windows or views.

---

### Milestone 10 — Distribution

#### Phase 23: Signing + notarization + packaging

**Module:** repo-level (`scripts/`, `.xcconfig`)

- `scripts/release.sh`: `xcodebuild archive` → `exportArchive` with Developer ID → `notarytool submit --wait` → `stapler staple` → DMG via `create-dmg`.
- `scripts/make-dmg.sh` config.
- In-app "Check for updates…" menu item that opens GitHub releases page (Sparkle deferred to v1.1).
- GitHub Action workflow `release.yml` — committed but disabled by default.

**Acceptance:** produce notarized, stapled DMG that launches cleanly on a separate Mac.

---

### Milestone 11 — Final QA

#### Phase 24: QA pass

- `swift test --package-path Packages/GlanslateKit` 100% green.
- `xcodebuild` clean build, zero warnings.
- Manual E2E matrix:
  1. Single 1x display, Safari article, Apple EN→TR, Clean Patch. AX path expected.
  2. Single 2x display, PDF in Preview, DeepL fallback, Blur Patch. Vision path expected.
  3. Dual monitor side-by-side, selection on each. Vertical dual arrangement (secondary above primary). Drag crossing screens → rejected.
  4. Canva / Figma canvas → Vision path, arbitration visible in logs.
  5. Image-only region → no-text toast, no overlay.
  6. Permission revoke mid-session → graceful re-prompt, no crash.
  7. 10 rapid-fire hotkey presses → final overlay only; no leaks.
  8. Provider override per-invocation via toolbar.
  9. Source language override when detection is wrong.
  10. Live style swap with overlay active.
  11. Pin + restart app + re-open pinned translation.
  12. Compact source rect translated to German or Turkish expands symmetrically without clipping or toolbar overlap.
  13. Arabic or Hebrew target language renders RTL with correct wrapping and punctuation order.

---

## Risks

1. **`.glassEffect()` over desktop inside transparent borderless `NSWindow`.** If it only samples inside its own compositing group, Blur Patch loses the core illusion. → Phase 0.5 spike; fallback to `NSVisualEffectView` with documented fidelity loss.
2. **Key-window delivery in `LSUIElement` app.** A click-through borderless overlay may not reliably become key. → Phase 0.5 spike decides between local monitor, global event tap, or always-on control panel.
3. **HUD → capture self-exclusion race.** If the HUD window has not actually removed itself from the window list by the time SCK filters, the snapshot could include our own UI. Mitigation: sequencing rule + 16 ms yield; test harness in Phase 6 asserts no self-pixels.
4. **Source retention memory cliff.** Retaining `CGImage` for every non-dismissed session on a 6K display is ~60 MB each; 10 rapid invocations → 600 MB. Mitigation: only one active non-pinned invocation at a time (enforced by `InvocationController`); pinned sessions downsample to 512×512 PNG immediately.
5. **AX permission friction.** System prompt for Accessibility on Tahoe can only be triggered by user action (toggle in System Settings). Mitigation: onboarding explains + deep-links; app degrades to Vision-only if AX denied.
6. **KeyboardShortcuts SPM on macOS 26.** Package is maintained but Tahoe-specific regressions possible. Mitigation: fallback `RegisterEventHotKey` wrapper (Carbon.HIToolbox) if needed.
7. **AX API reliability for Electron / Canvas apps.** Expected to be low; arbitration handles by trusting Vision. Confirmed during Phase 10 manual pass.
8. **Apple Translation first-run model download latency.** Mitigation: trigger `prepareTranslation` when the user sets `defaultTargetLanguage` in Settings.
9. **macOS 26 Liquid Glass API evolution between beta betas.** Mitigation: pin to a specific SDK version in `.xcconfig`; rebuild on OS updates.
10. **HDR + extended-range capture.** Mitigation: tone-map to sRGB before any contrast/luminance analysis; all color decisions happen in sRGB.
11. **Cloud privacy expectation mismatch.** Users may assume all translation stays local. Mitigation: provider-specific disclosure gate, metadata-only observability, and Apple provider as the obvious default.
12. **Translated text expansion can break the illusion on dense UIs.** Mitigation: explicit fit policy, symmetric growth capped to invocation bounds, and RTL / long-text QA fixtures.

---

## Out of scope for v1

- Full-screen / active-window modes (toggle stub only).
- Speech → text (audio translation).
- Continuous / streaming region re-translation.
- Per-app glossaries.
- iCloud sync of pinned history.
- Sparkle auto-update.
- Mac App Store distribution.
- Cross-screen region selection.

---

## Agent assignment summary

| Milestone / Phase | Rationale |
|---|---|---|
| 0 Scaffold | mechanical |
| 0.5 Spike | empirical risk buy-down |
| 1 Core types | pure Swift |
| 2 Geometry | math + TDD-heavy |
| 3 Platform wrappers | thin wrappers |
| 4 InvocationController | actor + state machine |
| 5 Region HUD | logic then Liquid Glass |
| 6 Capture | SCK wrapping |
| 7 Vertical slice | integration first contact |
| 8 Vision | deterministic API |
| 9 AX | system API |
| 10 Arbitrator | rules + tests |
| 11 Apple Translation | Apple API |
| 12 Cloud + Router | HTTP plumbing |
| 13 Overlay base | NSWindow architecture |
| 14 Clean Patch | Liquid Glass taste |
| 15 Blur Patch | Liquid Glass taste |
| 16 Subtitle | TextRenderer craft |
| 17 Toolbar | both |
| 18 Shortcut | SPM wiring |
| 19 Settings | both |
| 20 Onboarding | UX |
| 21 SwiftData | boilerplate |
| 22 Integration | hardening |
| 23 Distribution | scripts |
| 24 Final QA | verification |
