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
        .library(name: "AudioReaderNetworking", targets: ["AudioReaderNetworking"]),
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
        .target(
            name: "AudioReaderNetworking",
            dependencies: [
                "AudioReaderDomain"
            ],
            path: "Sources/AudioReaderNetworking",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "AudioReader",
            dependencies: [
                "AudioReaderDomain",
                "AudioReaderLocalStore",
                "AudioReaderNetworking",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/AudioReader",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AuthenticationServices"),
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
            name: "AudioReaderNetworkingTests",
            dependencies: [
                "AudioReaderNetworking"
            ]
        ),
        .testTarget(
            name: "AudioReaderTests",
            dependencies: [
                "AudioReader",
                "AudioReaderDomain",
                "AudioReaderLocalStore",
                "AudioReaderNetworking",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ]
)
