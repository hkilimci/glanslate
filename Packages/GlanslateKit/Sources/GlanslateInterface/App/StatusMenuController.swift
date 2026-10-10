import AppKit
import GlanslateCore
import GlanslateSystem

/// The menu bar item and its menu, rebuilt each time it opens so it always
/// reflects the current shortcut, language, and provider.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let environment: AppEnvironment
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Glanslate")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Glanslate"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = .terminationOnRemoval
        statusItem.isVisible = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = environment.settings

        let translate = item("Translate Region", symbol: "text.viewfinder", action: #selector(translateRegion))
        if let combo = settings.translateShortcut, let key = Self.keyEquivalent(for: combo) {
            translate.keyEquivalent = key
            translate.keyEquivalentModifierMask = combo.modifiers.eventFlags
        }
        if !environment.permissions.screenRecording {
            translate.toolTip = "Screen Recording permission is required"
        }
        menu.addItem(translate)
        menu.addItem(.separator())

        let target = item("Translate To: \(settings.targetLanguage.localizedName())", symbol: "character.bubble", action: nil)
        target.submenu = languageMenu(selected: settings.targetLanguage)
        menu.addItem(target)

        let provider = item("Provider: \(settings.preferredProvider.displayName)", symbol: "server.rack", action: nil)
        provider.submenu = providerMenu()
        menu.addItem(provider)

        menu.addItem(.separator())
        menu.addItem(item("Saved Translations…", symbol: "pin", action: #selector(openSaved)))
        let settingsItem = item("Settings…", symbol: "gearshape", action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(item("About Glanslate", symbol: nil, action: #selector(showAbout)))
        let quit = item("Quit Glanslate", symbol: nil, action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: Submenus

    private func languageMenu(selected: Language) -> NSMenu {
        let submenu = NSMenu()
        for language in Language.sortedCatalog() {
            let entry = NSMenuItem(title: language.localizedName(), action: #selector(selectTarget(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.code
            entry.state = language == selected ? .on : .off
            submenu.addItem(entry)
        }
        return submenu
    }

    private func providerMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for provider in TranslationProvider.allCases {
            var title = provider.displayName
            if !environment.hasCredential(for: provider) { title += " — Not Set Up" }
            let entry = NSMenuItem(title: title, action: #selector(selectProvider(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = provider.rawValue
            entry.state = provider == environment.settings.preferredProvider ? .on : .off
            entry.image = NSImage(systemSymbolName: provider.isOnDevice ? "laptopcomputer" : "cloud", accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let onDevice = NSMenuItem(title: "Prefer On-Device When Available", action: #selector(togglePrefersOnDevice), keyEquivalent: "")
        onDevice.target = self
        onDevice.state = environment.settings.prefersOnDevice ? .on : .off
        submenu.addItem(onDevice)
        submenu.addItem(.separator())
        let configure = NSMenuItem(title: "Translation Settings…", action: #selector(openTranslationSettings), keyEquivalent: "")
        configure.target = self
        submenu.addItem(configure)
        return submenu
    }

    private func item(_ title: String, symbol: String?, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    /// Menus can only display single-character key equivalents.
    static func keyEquivalent(for combo: KeyCombo) -> String? {
        if combo.keyCode == 0x31 { return " " }
        guard combo.key.count == 1 else { return nil }
        return combo.key.lowercased()
    }

    // MARK: Actions

    @objc private func translateRegion() {
        // Let the menu finish closing before the selection interface appears.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            environment.commands.translateRegion()
        }
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        environment.settings.targetLanguage = Language(code)
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = TranslationProvider(rawValue: raw) else { return }
        environment.settings.preferredProvider = provider
        if !environment.hasCredential(for: provider) {
            environment.commands.openSettings(.translation)
        }
    }

    @objc private func togglePrefersOnDevice() {
        environment.settings.prefersOnDevice.toggle()
    }

    @objc private func openTranslationSettings() { environment.commands.openSettings(.translation) }
    @objc private func openSaved() { environment.commands.openSavedTranslations() }
    @objc private func openSettings() { environment.commands.openSettings(environment.settingsSection) }
    @objc private func showAbout() { environment.commands.showAbout() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// The standard application menus. They matter even for a menu bar app:
/// they provide ⌘C/⌘V in text fields and the usual window commands.
@MainActor
enum MainMenuBuilder {
    static func makeMainMenu(target: AppController) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Glanslate")
        appMenu.addItem(withTitle: "About Glanslate", action: #selector(AppController.aboutAction(_:)), keyEquivalent: "").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppController.openSettingsAction(_:)), keyEquivalent: ",").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Translate Region", action: #selector(AppController.translateRegionAction(_:)), keyEquivalent: "").target = target
        appMenu.addItem(withTitle: "Saved Translations", action: #selector(AppController.openSavedAction(_:)), keyEquivalent: "").target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Glanslate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Glanslate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenuItem(window))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
