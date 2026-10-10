import AppKit
import GlanslateCore
import GlanslateSystem

/// Explains, before first use, exactly what a cloud provider receives, and
/// records the user's answer.
struct ConsentPrompter: ConsentGate {
    let settings: AppSettings

    func requestConsent(for provider: TranslationProvider) async -> Bool {
        await Self.ask(provider, settings: settings)
    }

    @MainActor
    static func ask(_ provider: TranslationProvider, settings: AppSettings) async -> Bool {
        if settings.hasConsent(for: provider) { return true }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        alert.messageText = "Translate with \(provider.displayName)?"
        alert.informativeText = Self.disclosure(for: provider)
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.showsHelp = provider.privacyPolicyURL != nil
        let helpDelegate = PrivacyHelpDelegate(url: provider.privacyPolicyURL)
        alert.delegate = helpDelegate

        NSApp.activate()
        let response = withExtendedLifetime(helpDelegate) { alert.runModal() }
        let granted = response == .alertFirstButtonReturn
        if granted { settings.setConsent(true, for: provider) }
        return granted
    }

    static func disclosure(for provider: TranslationProvider) -> String {
        """
        Glanslate will send the text it recognized in your selection to \(provider.dataRecipient) to translate it. \
        The screenshot itself never leaves your Mac — capture and text recognition always happen on device.

        You can change this anytime in Settings › Translation.
        """
    }
}

/// Opens the provider's privacy policy from the alert's help button.
@MainActor
private final class PrivacyHelpDelegate: NSObject, NSAlertDelegate {
    let url: URL?

    init(url: URL?) {
        self.url = url
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
