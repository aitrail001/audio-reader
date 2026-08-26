// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioReader",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "AudioReaderDomain", targets: ["AudioReaderDomain"]),
        .library(name: "AudioReaderLocalStore", targets: ["AudioReaderLocalStore"]),
        .executable(name: "AudioReader", targets: ["AudioReader"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "AudioReaderDomain",
            path: "Sources/AudioReaderDomain"
        ),
        .target(
            name: "AudioReaderLocalStore",
            dependencies: [
                "AudioReaderDomain"
            ],
            path: "Sources/AudioReaderLocalStore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AudioReader",
            dependencies: [
                "AudioReaderDomain",
                "AudioReaderLocalStore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/AudioReader",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
                .linkedFramework("Speech"),
                .linkedFramework("FoundationModels"),
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
            name: "AudioReaderDomainTests",
            dependencies: [
                "AudioReaderDomain"
            ]
        ),
        .testTarget(
            name: "AudioReaderLocalStoreTests",
            dependencies: [
                "AudioReaderLocalStore"
            ]
        ),
        .testTarget(
            name: "AudioReaderTests",
            dependencies: [
                "AudioReader",
                "AudioReaderDomain",
                "AudioReaderLocalStore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ]
)
