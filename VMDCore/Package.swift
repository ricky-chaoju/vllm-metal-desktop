// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VMDCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VMDCore", targets: ["VMDCore"])
    ],
    targets: [
        .target(
            name: "VMDCore",
            resources: [
                .copy("Resources/hf_download.py")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "VMDCoreTests",
            dependencies: ["VMDCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
