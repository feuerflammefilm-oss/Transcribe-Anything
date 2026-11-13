// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TranscribeAnything",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "TranscribeAnything",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/TranscribeAnything",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
