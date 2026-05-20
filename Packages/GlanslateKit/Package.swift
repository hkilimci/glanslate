// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlanslateKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GlanslateCore", targets: ["GlanslateCore"]),
        .library(name: "GlanslateGeometry", targets: ["GlanslateGeometry"]),
        .library(name: "GlanslatePlatform", targets: ["GlanslatePlatform"]),
        .library(name: "GlanslateInvocation", targets: ["GlanslateInvocation"]),
        .library(name: "GlanslateRegionSelect", targets: ["GlanslateRegionSelect"]),
        .library(name: "GlanslateCapture", targets: ["GlanslateCapture"]),
        .library(name: "GlanslateTextDetect", targets: ["GlanslateTextDetect"]),
        .library(name: "GlanslateTranslation", targets: ["GlanslateTranslation"]),
        .library(name: "GlanslateOverlay", targets: ["GlanslateOverlay"]),
        .library(name: "GlanslateHistory", targets: ["GlanslateHistory"]),
        .library(name: "GlanslateSettings", targets: ["GlanslateSettings"]),
        .library(name: "GlanslateKit", targets: ["GlanslateKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(name: "GlanslateCore", path: "Sources/Core"),
        .target(name: "GlanslateGeometry", dependencies: ["GlanslateCore"], path: "Sources/Geometry"),
        .target(
            name: "GlanslatePlatform",
            dependencies: [
                "GlanslateCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Platform"
        ),
        .target(
            name: "GlanslateSettings",
            dependencies: ["GlanslateCore", "GlanslatePlatform"],
            path: "Sources/Settings"
        ),
        .target(
            name: "GlanslateCapture",
            dependencies: ["GlanslateCore", "GlanslateGeometry", "GlanslatePlatform"],
            path: "Sources/Capture"
        ),
        .target(
            name: "GlanslateTextDetect",
            dependencies: ["GlanslateCore", "GlanslateGeometry", "GlanslatePlatform", "GlanslateCapture"],
            path: "Sources/TextDetect"
        ),
        .target(
            name: "GlanslateTranslation",
            dependencies: ["GlanslateCore", "GlanslatePlatform", "GlanslateSettings"],
            path: "Sources/Translation"
        ),
        .target(
            name: "GlanslateRegionSelect",
            dependencies: ["GlanslateCore", "GlanslateGeometry", "GlanslatePlatform"],
            path: "Sources/RegionSelect"
        ),
        .target(
            name: "GlanslateHistory",
            dependencies: ["GlanslateCore"],
            path: "Sources/History"
        ),
        .target(
            name: "GlanslateOverlay",
            dependencies: [
                "GlanslateCore", "GlanslateGeometry", "GlanslateCapture",
                "GlanslateTranslation", "GlanslateSettings", "GlanslateHistory",
            ],
            path: "Sources/Overlay",
            resources: [.process("Resources")]
        ),
        .target(
            name: "GlanslateInvocation",
            dependencies: [
                "GlanslateCore", "GlanslateGeometry", "GlanslatePlatform",
                "GlanslateRegionSelect", "GlanslateCapture", "GlanslateTextDetect",
                "GlanslateTranslation", "GlanslateOverlay", "GlanslateHistory",
                "GlanslateSettings",
            ],
            path: "Sources/Invocation"
        ),
        .target(
            name: "GlanslateKit",
            dependencies: [
                "GlanslateCore", "GlanslateGeometry", "GlanslatePlatform",
                "GlanslateInvocation", "GlanslateRegionSelect", "GlanslateCapture",
                "GlanslateTextDetect", "GlanslateTranslation", "GlanslateOverlay",
                "GlanslateHistory", "GlanslateSettings",
            ],
            path: "Sources/Umbrella"
        ),

        .testTarget(name: "CoreTests", dependencies: ["GlanslateCore"], path: "Tests/CoreTests"),
        .testTarget(name: "GeometryTests", dependencies: ["GlanslateGeometry", "GlanslateCore"], path: "Tests/GeometryTests"),
        .testTarget(name: "PlatformTests", dependencies: ["GlanslatePlatform", "GlanslateCore"], path: "Tests/PlatformTests"),
        .testTarget(name: "InvocationTests", dependencies: ["GlanslateInvocation"], path: "Tests/InvocationTests"),
        .testTarget(
            name: "RegionSelectTests",
            dependencies: ["GlanslateRegionSelect", "GlanslateGeometry", "GlanslateCore"],
            path: "Tests/RegionSelectTests"
        ),
        .testTarget(name: "TextDetectTests", dependencies: ["GlanslateTextDetect"], path: "Tests/TextDetectTests"),
        .testTarget(name: "TranslationTests", dependencies: ["GlanslateTranslation"], path: "Tests/TranslationTests"),
        .testTarget(name: "OverlayTests", dependencies: ["GlanslateOverlay"], path: "Tests/OverlayTests"),
        .testTarget(name: "HistoryTests", dependencies: ["GlanslateHistory"], path: "Tests/HistoryTests"),
        .testTarget(name: "SettingsTests", dependencies: ["GlanslateSettings"], path: "Tests/SettingsTests"),
    ],
    swiftLanguageModes: [.v6]
)
