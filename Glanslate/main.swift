import AppKit
import GlanslateInterface

// Glanslate runs from the menu bar. The delegate is kept alive for the
// lifetime of the process because `NSApplication.delegate` is weak.
MainActor.assumeIsolated {
    let delegate = GlanslateAppDelegate()
    let application = NSApplication.shared
    application.delegate = delegate
    withExtendedLifetime(delegate) {
        application.run()
    }
}
