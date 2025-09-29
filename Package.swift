// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "polykit-swift",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "Polykit", targets: ["Polykit"]),
    ],
    targets: [
        .target(
            name: "Polykit",
            path: "Sources/Polykit",
        ),
    ],
)
