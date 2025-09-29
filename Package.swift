// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "polykit-swift",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "PolyCmd", targets: ["PolyCmd"]),
        .library(name: "PolyLog", targets: ["PolyLog"]),
        .library(name: "PolyText", targets: ["PolyText"]),
        .executable(name: "walkingman", targets: ["WalkingMan"]),
    ],
    targets: [
        .target(
            name: "PolyCmd",
            path: "Sources/PolyCmd",
        ),
        .target(
            name: "PolyLog",
            dependencies: ["PolyText"],
            path: "Sources/PolyLog",
        ),
        .target(
            name: "PolyText",
            path: "Sources/PolyText",
        ),
        .executableTarget(
            name: "WalkingMan",
            dependencies: ["PolyText"],
            path: "Sources/WalkingMan",
        ),
    ],
)
