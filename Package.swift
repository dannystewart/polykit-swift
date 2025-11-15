// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PolyKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "PolyKit", targets: ["PolyKit"]),
    ],
    targets: [
        .target(
            name: "PolyKit",
            path: "Sources/PolyKit",
            exclude: ["Integrations/SEQ_README.md"],
        ),
    ],
)
