// swift-tools-version:6.4
import PackageDescription
import Foundation

// Absolute path to this manifest's directory, so the embedded-Info.plist linker
// flag below resolves no matter what working directory the linker is invoked
// from (SwiftPM runs from the package root, but Xcode's SwiftPM integration may
// not — a relative path there fails the link with "can't open file").
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Sotto",
    defaultLocalization: "en",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.12.0"),
    ],
    targets: [
        .target(
            name: "SottoCore",
            path: "Sources/SottoCore"
        ),
        .executableTarget(
            name: "Sotto",
            dependencies: [
                "SottoCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Sotto",
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            swiftSettings: [],
            linkerSettings: [
                // Embed Info.plist into the executable's Mach-O so the *bare*
                // binary (e.g. Xcode's Run button, which launches the raw
                // SwiftPM product) still has a bundle identifier. Without this
                // Bundle.main.bundleIdentifier is nil and the system logs a
                // cascade of "missing bundle identifier" errors.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageDir)/Sources/Sotto/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "SottoTests",
            dependencies: ["SottoCore"],
            path: "Tests/SottoTests"
        )
    ]
)
