// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Speakin",
    platforms: [.macOS(.v14)],
    targets: [
        // transcribe.cpp v0.4.1（MIT）的 xcframework，放 Vendor/ 不進 git
        .binaryTarget(name: "CTranscribe", path: "Vendor/TranscribeCpp.xcframework"),
        .executableTarget(name: "Speakin", dependencies: ["CTranscribe"], path: "Sources/Speakin",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    ]
)
