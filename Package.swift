// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FreeKit",
    // macOS 26: required for the on-device FoundationModels rewrite engine.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure-Foundation logic kept separate so it is unit-testable without linking whisper.
        .target(name: "FreeKitCore", path: "Sources/FreeKitCore"),
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .systemLibrary(name: "CIMobileDevice", path: "Sources/CIMobileDevice"),
        .executableTarget(
            name: "FreeKit",
            dependencies: ["FreeKitCore", "CWhisper", "CIMobileDevice"],
            path: "Sources/FreeKit",
            // Per-module orientation docs, not build inputs — excluded so SPM doesn't warn
            // about "unhandled" files on every build.
            exclude: [
                "Shell/README.md",
                "Modules/Shared/README.md",
                "Modules/Speech/README.md",
                "Modules/Notebook/README.md",
                "Modules/Convert/README.md",
                "Modules/Clop/README.md",
                "Modules/Shelf/README.md",
                "Modules/BoringNotch/README.md",
                "Modules/AppCleaner/README.md",
                "Modules/Autoclick/README.md",
                "Modules/Stats/README.md",
                "Modules/HyperKey/README.md",
                "Modules/Amphetamine/README.md",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "FreeKitCoreTests",
            dependencies: ["FreeKitCore"],
            path: "Tests/FreeKitCoreTests"
        ),
    ]
)
