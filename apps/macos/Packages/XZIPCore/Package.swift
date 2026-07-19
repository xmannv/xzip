// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XZIPCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "XZIPCore", targets: ["XZIPCore"])
    ],
    targets: [
        .target(
            name: "XZIPCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "XZIPCoreTests",
            dependencies: ["XZIPCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
