// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceDictate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceDictate",
            path: "Sources/VoiceDictate"
        )
    ]
)
