// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PolyKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v26),
    ],
    products: [
        .library(name: "PolyKit", targets: ["PolyKit"]),
        .library(name: "PolyMedia", targets: ["PolyMedia"]),
        .library(name: "PolyBase", targets: ["PolyBase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
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
        .target(
            name: "PolyBase",
            dependencies: [
                "PolyKit",
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            path: "PolyBase",
        ),
        .testTarget(
            name: "PolyKitTests",
            dependencies: [
                "PolyKit",
                "PolyMedia",
                "PolyBase",
            ],
        ),
    ],
)
