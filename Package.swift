// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "polykit-swift",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "PolyLog", targets: ["PolyLog"]),
        .library(name: "PolyText", targets: ["PolyText"]),
    ],
    targets: [
        .target(
            name: "PolyLog",
            dependencies: ["PolyText"],
            path: "Sources/PolyLog",
        ),
        .target(
            name: "PolyText",
            path: "Sources/PolyText"
        ),

    ],
)
