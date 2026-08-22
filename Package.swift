// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioReader",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "AudioReader", targets: ["AudioReader"])
    ],
    targets: [
        .executableTarget(
            name: "AudioReader",
            path: "Sources/AudioReader",
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
