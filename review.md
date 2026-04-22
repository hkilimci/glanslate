# Glanslate Code Review — Dead / Redundant Code and Related Issues

Scope: `App/`, `Packages/GlanslateKit/Sources/`, `Spikes/`.

Legend: **[dead]** unused symbol, **[redundant]** duplicated / replaceable logic, **[bug]** likely-broken behavior, **[smell]** fragile or non-obvious.

---

## Dead code — safe to delete

1. **[dead] `MinimalOverlayPresenter` typealias** — `Packages/GlanslateKit/Sources/Overlay/MinimalOverlayPresenter.swift:105`
   `public typealias MinimalOverlayPresenter = OverlayEngine` has zero references outside its own definition. Remove the alias; consider renaming the file to `OverlayEngine.swift` for consistency.

2. **[dead] `OverlaySessionHandle.retranslate(to:)`** — `Packages/GlanslateKit/Sources/Overlay/OverlaySession.swift:122`
   Convenience wrapper never called. Toolbar + tests go through `requestRetranslation(_:)` directly.

3. **[dead] `GeometryConverter.pixelRect(forDisplayLocal:)`** — `Packages/GlanslateKit/Sources/Geometry/GeometryConverter.swift:77`
   Not referenced anywhere. Drop it.

4. **[dead] `Language.nlLanguage`** — `Packages/GlanslateKit/Sources/TextDetect/VisionCandidate.swift:169`
   Inverse of `Language.from(nlCode:)`. Nothing reads it.

5. **[dead] `ErrorToastPresenter.positionOnDisplay(_:displayID:)`** — `Packages/GlanslateKit/Sources/Overlay/ErrorToast.swift:43`
   Private method never invoked; duplicates the real logic in `ToastWindow.positionOnDisplay(displayID:)` (line 96).

6. **[dead] `SettingsStore.openAIModel`** — `Packages/GlanslateKit/Sources/Settings/SettingsStore.swift:27,53,68`
   Persisted and restored but never read. `OpenAIEngine` is constructed in `AppRoot.init` (`App/AppRoot.swift:33`) using the default `{ "gpt-5.4-mini" }` closure, so the setting has no effect. Either wire it through (`OpenAIEngine(model: { settingsStore.openAIModel })`) and add a Settings UI field, or remove the property.

7. **[dead] `SettingsStore.didShowOnboarding`** — `Packages/GlanslateKit/Sources/Settings/SettingsStore.swift:38,60,75`
   Onboarding gates itself via `UserDefaults.standard.bool(forKey: "didShowOnboarding")` (`App/OnboardingWindow.swift:251`). The `SettingsStore` copy is never read — two parallel paths to the same key. Drop the `SettingsStore` property (or reverse: make onboarding read through `SettingsStore`).

8. **[dead] `OnboardingPresenter.dismiss()`** — `App/OnboardingWindow.swift:261`
   Never called. Dismissal happens in `OnboardingWindowDelegate.windowWillClose` and `finishOnboarding()`.

9. **[dead] `OnboardingPresenter.isPresented` / `@Published`** — `App/OnboardingWindow.swift:247`
   No SwiftUI view observes it; the binding is only used to flip the flag back to `false` when the window closes. Since nothing else reads it, the whole presenter could collapse to `checkAndShow()` + a retained `NSWindowController`.

10. **[dead] `ShortcutBinding.removeAllHandlers`** — `Packages/GlanslateKit/Sources/Platform/ShortcutBinding.swift:18`
    Not called. If there is no teardown path, remove it.

11. **[dead?] `PermissionProbe.requestScreenRecording` / `requestInputMonitoring` / `inputMonitoringGranted` and `PermissionKind.inputMonitoring`** — `Packages/GlanslateKit/Sources/Platform/PermissionProbe.swift`, `Sources/Core/OverlayStyle.swift:19`
    Not referenced by the app or tests. `PermissionKind.inputMonitoring` only surfaces in `PermissionProbe.openPane`. Decide: either wire them to onboarding / an "always-on hotkey" flow, or prune together.

12. **[dead] Most `GlanslateLog` categories** — `Packages/GlanslateKit/Sources/Core/Logging.swift`
    Only `history` and `translate` are used. `app`, `invocation`, `regionSelect`, `capture`, `textDetect`, `overlay`, `platform`, `settings`, and `signpost` are defined but never logged to. Add actual logging or prune the unused entries.

---

## Redundant / duplicated logic

13. **[redundant] Duplicate NSScreen → displayID lookup** — `Packages/GlanslateKit/Sources/Overlay/ErrorToast.swift:44-49` and `:97-102`
    Both sites open-code `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID`. The cast is also fragile — the raw value is `NSNumber`, so casting directly to `CGDirectDisplayID` (UInt32) works only because of bridging. `DisplayTopology.swift:79` already exposes `NSScreen.displayID` that does the correct `NSNumber.uint32Value` conversion. Replace both occurrences with the extension.

14. **[redundant] Two `positionOnDisplay` implementations in `ErrorToast.swift`** — one on `ErrorToastPresenter` (dead, item 5), one on `ToastWindow`. Keep the `ToastWindow` one.

15. **[redundant] `persistedBinding` duplicated across settings tabs** — `App/SettingsSceneView.swift:116` and `:179`
    Two identical generic helper functions in sibling views. Extract to a shared helper on `SettingsStore` or a free function.

16. **[redundant] `SettingsStore.persist()` called per-mutation** — every binding setter goes `set = $0; settings.persist()`. Each call encodes + writes every field. Consider moving persistence to a `didSet` or using property-level writes, or batch via a debounce.

17. **[redundant] `@MainActor` on `HistoryStoring.pin` + per-translation save** — `Packages/GlanslateKit/Sources/Invocation/InvocationController.swift:293`
    `persistPinnedPayload` iterates `payload.translations` and calls `history.pin(...)` once per entry, each invocation creating a fresh `ModelContext` and `save()`. Insert all records into one context and `save()` once.

---

## Bugs / likely-broken behavior

18. **[bug] `OpenAIEngine` default model is not a real model** — `Packages/GlanslateKit/Sources/Translation/OpenAIEngine.swift:16`
    `"gpt-5.4-mini"` does not exist. The app will 400 on first OpenAI call. Use a real model id and (per item 6) wire it through `SettingsStore.openAIModel`.

19. **[bug] `OpenAIEngine` sends `response_format` to `/v1/responses`** — `OpenAIEngine.swift:72-83`
    The Responses API expects `text.format.{type,json_schema}`, not top-level `response_format` (that field belongs to the Chat Completions endpoint). Structured output will be ignored or rejected.

20. **[bug] `GoogleEngine` uses v3 endpoint with API-key query auth** — `Packages/GlanslateKit/Sources/Translation/GoogleEngine.swift:39`
    `translation.googleapis.com/v3/projects/.../locations/global:translateText?key=<key>` — v3 requires an OAuth2 bearer token (`Authorization: Bearer`), not an API key. Either switch to the v2 `language.googleapis.com/language/translate/v2` endpoint (which accepts `?key=`) or exchange a service-account key for an access token.

21. **[bug] `AppleTranslationEngine.extractText` uses `Mirror`** — `Packages/GlanslateKit/Sources/Translation/AppleTranslationEngine.swift:94`
    `TranslationSession.Response` exposes `targetText: String` directly. Reflecting for "the first non-empty String child" is fragile and silently returns `""` if Apple renames the field. Use `response.targetText`.

22. **[bug] `AppleLanguageAvailability.availability` compares via `String(describing:)`** — `AppleTranslationEngine.swift:26-33`
    Depends on the stringified case name ("installed"/"notInstalled"). Switch on the actual `LanguageAvailability.Status` enum.

23. **[bug] `AsyncStreamBroadcaster.stream()` seed delivery race** — `Packages/GlanslateKit/Sources/Invocation/InvocationController.swift:354-366`
    Reads `latest` under the lock, then yields the seed *after* unlocking. A concurrent `yield(x)` between unlock and `continuation.yield(seed)` can deliver state out of order (new value first, then stale seed). Yield the seed while still holding the lock, or keep continuation registration and seed delivery under the same critical section.

24. **[bug] `TranslationRouter.dominantLanguage` too strict** — `TranslationRouter.swift:81-90`
    Early-returns `nil` the moment any block has `detectedLanguage == nil`. AX blocks never set a language, so any mixed AX+Vision result nullifies detection. Skip nil entries instead of aborting.

25. **[smell] `SCKScreenCapturer` excludes HUD by bundle ID + 16ms sleep** — `SCKScreenCapturer.swift:15-17,40`
    Relies on the HUD app sharing `com.glanslate.app` bundle ID and on the window leaving the window list within 16 ms. Pass the HUD's `SCWindow` via `exceptingWindows:` for a deterministic exclusion.

26. **[smell] `HTTPClient.perform` "magic 60s" override** — `HTTPClient.swift:25`
    `if req.timeoutInterval == 60 { req.timeoutInterval = timeout }` silently rewrites the caller's timeout whenever it happens to equal URLSession's default. Either always override, or expose an explicit parameter.

27. **[smell] `OverlayEngine.lastDisplayID` leaks across dismissals** — `MinimalOverlayPresenter.swift:15,23`
    Set on `present()`, never cleared on `dismissAll`/`dismissSession`. Error toasts that fire after an overlay is dismissed still target the last overlay's display.

28. **[smell] `AppRoot.init` formatting glitch** — `App/AppRoot.swift:27-28`
    Indentation on `let router` line is off (8 spaces vs the rest of the block). Run through the formatter.

29. **[smell] `Spikes/GlassSpike/main.swift` not wired to SPM/Xcode** — committed as a loose `main.swift` with a `swiftc` build comment. Either move into a dedicated SPM executable target or gitignore/delete after the spike lands.

---

## Minor / low-priority

30. `AXCandidate.coverageRatio` sums raw block areas without union — can exceed 1 before clamp. Doc-comment it as a heuristic or compute a true union.
31. `TranslationProvider.toolbarLabel` and `Language.toolbarLabel` live as extensions inside `Overlay/OverlayToolbar.swift`. Consider moving to `Core` so other views can reuse (e.g. Settings provider picker).
32. `NoopOverlayPresenter` is only used in tests — fine as-is, but mark the type `internal` or move to a `TestSupport` target if public surface isn't needed.
33. `OverlayLayoutEngine.renderedBlocks` runs `NSString.boundingRect` off-main; harmless today but Swift 6 strict concurrency may flag `NSFont` usage from non-main contexts depending on caller.

---

## Suggested cleanup order

1. Delete items **1–5, 10, 14** — purely dead and zero-risk.
2. Decide on **6, 7, 8, 9, 11, 12** together (onboarding + settings consolidation + logging surface).
3. Fix **18–22** before shipping OpenAI / Google / Apple paths — current state means only Apple Translation (via the Mirror hack) and DeepL are realistically working.
4. Refactor **13, 15, 16, 17** while touching the affected files.
5. Address **23–28** opportunistically during the next pass on each subsystem.
