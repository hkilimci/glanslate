import AppKit
import CoreText
import Foundation

enum OverlayFont {
    static let postScriptName = "Questrial"

    private static let registerQuestrial: Void = {
        guard
            let url = Bundle.module.url(forResource: "Questrial-Regular", withExtension: "ttf")
                ?? Bundle.module.url(
                    forResource: "Questrial-Regular",
                    withExtension: "ttf",
                    subdirectory: "Fonts"
                )
        else {
            return
        }

        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func register() {
        _ = registerQuestrial
    }

    static func nsFont(ofSize size: CGFloat, fallbackWeight weight: NSFont.Weight = .regular) -> NSFont {
        register()

        return NSFont(name: postScriptName, size: size)
            ?? NSFont(name: "Questrial-Regular", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
}
