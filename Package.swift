// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.12.0"),
        // On-device Qwen via MLX-Swift (no Python). The HuggingFace + Tokenizers
        // packages back the MLXHuggingFace loader macros.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Sotto",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/Sotto",
            swiftSettings: [.define("SOTTO_MLX")]
        )
    ]
)
