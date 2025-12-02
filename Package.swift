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
    ],
    targets: [
        .target(
            name: "PolyKit",
            path: "Sources/PolyKit",
        ),
    ],
)
