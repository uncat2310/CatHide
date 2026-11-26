// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CatHide",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MosaicCore",
            targets: ["MosaicCore"]
        ),
        .executable(
            name: "CatHide",
            targets: ["CatHide"]
        )
    ],
    targets: [
        .target(
            name: "MosaicCore"
        ),
        .executableTarget(
            name: "CatHide",
            dependencies: ["MosaicCore"],
            path: "Sources/MosaicPen"
        ),
        .testTarget(
            name: "MosaicCoreTests",
            dependencies: ["MosaicCore"]
        )
    ]
)
