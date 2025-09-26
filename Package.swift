// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "polylog-swift",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "PolyLog",
            targets: ["PolyLog"]
        )
    ],
    targets: [
        .target(
            name: "PolyLog",
            path: "Sources/PolyLog"
        )

    ]
)
