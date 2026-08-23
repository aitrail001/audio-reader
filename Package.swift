// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioReader",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .executable(name: "AudioReader", targets: ["AudioReader"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .executableTarget(
            name: "AudioReader",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/AudioReader",
            linkerSettings: [
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreServices", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("MediaPlayer", .when(platforms: [.iOS])),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "AudioReaderTests",
            dependencies: [
                "AudioReader",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ]
)
