// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LovelyStack",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ShelfDropCore",
            targets: ["ShelfDropCore"]
        ),
        .executable(
            name: "ShelfDropApp",
            targets: ["ShelfDropApp"]
        ),
    ],
    targets: [
        .target(
            name: "ShelfDropCore"
        ),
        .executableTarget(
            name: "ShelfDropApp",
            dependencies: ["ShelfDropCore"]
        ),
        .testTarget(
            name: "ShelfDropCoreTests",
            dependencies: ["ShelfDropCore"]
        ),
    ]
)
