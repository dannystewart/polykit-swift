// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PolyKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "PolyKit", targets: ["PolyKit"]),
        .library(name: "PolyMedia", targets: ["PolyMedia"]),
    ],
    targets: [
        .target(
            name: "PolyKit",
            path: "PolyKit",
        ),
        .target(
            name: "PolyMedia",
            dependencies: [
                "PolyKit",
            ],
            path: "PolyMedia",
        ),
    ],
)
