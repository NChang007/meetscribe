// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meetscribe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "meetscribe", targets: ["MeetscribeCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetscribeCLI",
            dependencies: [
                "MeetscribeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "MeetscribeCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .testTarget(
            name: "MeetscribeCoreTests",
            dependencies: ["MeetscribeCore"]
        ),
    ]
)
