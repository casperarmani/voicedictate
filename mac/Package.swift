// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VoiceDictate",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device Parakeet speech-to-text (Core ML / Neural Engine). Pinned to the
        // revision benchmarked in the local-model bakeoff. traits: [] skips the
        // TTS/text-processing extras we don't need.
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "fc5c5f0", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "VoiceDictate",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/VoiceDictate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
