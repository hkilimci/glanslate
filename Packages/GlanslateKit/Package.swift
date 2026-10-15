// swift-tools-version: 6.2
import PackageDescription

// GlanslateCore is plain Foundation so its domain logic (geometry, grouping,
// routing, layout) builds and tests on any Swift toolchain. Everything that
// touches AppKit, ScreenCaptureKit, Vision, Translation, or SwiftData is
// macOS-only and is declared below the platform check.

var products: [Product] = [
    .library(name: "GlanslateCore", targets: ["GlanslateCore"]),
]

var targets: [Target] = [
    .target(name: "GlanslateCore"),
    .testTarget(name: "GlanslateCoreTests", dependencies: ["GlanslateCore"]),
]

#if os(macOS)
products += [
    .library(name: "GlanslateInterface", targets: ["GlanslateInterface"]),
]

targets += [
    .target(name: "GlanslateSystem", dependencies: ["GlanslateCore"]),
    .target(name: "GlanslateCapture", dependencies: ["GlanslateCore"]),
    .target(name: "GlanslateRecognition", dependencies: ["GlanslateCore"]),
    .target(name: "GlanslateAppleTranslation", dependencies: ["GlanslateCore"]),
    .target(name: "GlanslatePersistence", dependencies: ["GlanslateCore"]),
    .target(
        name: "GlanslateInterface",
        dependencies: [
            "GlanslateCore",
            "GlanslateSystem",
            "GlanslateCapture",
            "GlanslateRecognition",
            "GlanslateAppleTranslation",
            "GlanslatePersistence",
        ]
    ),
    .testTarget(name: "GlanslatePersistenceTests", dependencies: ["GlanslatePersistence", "GlanslateCore"]),
    .testTarget(name: "GlanslateSystemTests", dependencies: ["GlanslateSystem", "GlanslateCore"]),
    .testTarget(name: "GlanslateAppleTranslationTests", dependencies: ["GlanslateAppleTranslation", "GlanslateCore"]),
    .testTarget(
        name: "GlanslateInterfaceTests",
        dependencies: ["GlanslateInterface", "GlanslateCore", "GlanslateSystem", "GlanslatePersistence"]
    ),
]
#endif

let package = Package(
    name: "GlanslateKit",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
