// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FreeSpeech",
    // macOS 26: required for the on-device FoundationModels rewrite engine.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure-Foundation logic kept separate so it is unit-testable without linking whisper.
        .target(name: "FreeSpeechCore", path: "Sources/FreeSpeechCore"),
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "FreeSpeech",
            dependencies: ["FreeSpeechCore", "CWhisper"],
            path: "Sources/FreeSpeech",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("IOKit"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "FreeSpeechCoreTests",
            dependencies: ["FreeSpeechCore"],
            path: "Tests/FreeSpeechCoreTests"
        ),
    ]
)
