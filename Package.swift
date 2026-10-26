// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowsManager",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "WMCore", targets: ["WMCore"]),
        .executable(name: "spaceslab", targets: ["spaceslab"]),
        .executable(name: "WindowsManagerApp", targets: ["WindowsManagerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "WMCore",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "spaceslab",
            dependencies: ["WMCore"]
        ),
        .executableTarget(
            name: "WindowsManagerApp",
            dependencies: [
                "WMCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "WMCoreTests",
            dependencies: ["WMCore"],
            swiftSettings: [
                // Command Line Tools keep the swift-testing macro plugin in a folder SwiftPM does not
                // pass to the compiler; without this `swift test` fails with "plugin for module
                // 'TestingMacros' not found". The folder is simply ignored when it does not exist.
                .unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
            ]
        ),
    ],
    // Swift 5 language mode: the private C APIs we call are not strict-concurrency friendly.
    swiftLanguageModes: [.v5]
)
