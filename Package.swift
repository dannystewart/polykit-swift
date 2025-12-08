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
        .library(name: "PolyBase", targets: ["PolyBase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "PolyKit",
            path: "Sources/PolyKit",
        ),
        .target(
            name: "PolyBase",
            dependencies: [
                "PolyKit",
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            path: "Sources/PolyBase",
        ),
    ],
)
