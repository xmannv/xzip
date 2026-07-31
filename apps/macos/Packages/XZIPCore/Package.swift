// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "XZIPCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "XZIPDomain", targets: ["XZIPDomain"]),
        .library(name: "XZIPCore", targets: ["XZIPCore"]),
        .library(name: "XZIPRuntime", targets: ["XZIPRuntime"]),
        .library(name: "XZIPArchiveListing", targets: ["XZIPArchiveListing"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/marcprux/swift-archive.git",
            exact: "3.8.9",
            // libarchive ships its lzma decoder behind an off-by-default trait.
            // Without it, listing any LZMA2-compressed 7z (7-Zip's default
            // encoding) fails — which broke Quick Look for virtually every
            // real-world .7z; only stored (`Copy`) archives previewed.
            traits: ["LZMASupport"]
        )
    ],
    targets: [
        .target(
            name: "XZIPDomain",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "XZIPCore",
            dependencies: ["XZIPDomain"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "XZIPRuntime",
            dependencies: ["XZIPDomain", "XZIPCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(name: "XZIPArchiveListingCLocale"),
        .target(
            name: "XZIPArchiveListing",
            dependencies: [
                "XZIPArchiveListingCLocale",
                "XZIPCore",
                .product(name: "Archive", package: "swift-archive")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "XZIPDomainTests",
            dependencies: ["XZIPDomain"],
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
        ),
        .testTarget(
            name: "XZIPRuntimeTests",
            dependencies: ["XZIPRuntime", "XZIPDomain", "XZIPCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "XZIPArchiveListingTests",
            dependencies: [
                "XZIPArchiveListing",
                "XZIPCore",
                .product(name: "Archive", package: "swift-archive")
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
