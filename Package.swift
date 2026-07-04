// swift-tools-version:6.4
import PackageDescription

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
            resources: [.process("Resources")],
            swiftSettings: []
        ),
        .testTarget(
            name: "SottoTests",
            dependencies: ["SottoCore"],
            path: "Tests/SottoTests"
        )
    ]
)
