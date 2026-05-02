// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sable",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Sable", targets: ["SableApp"]),
        .library(name: "SableCore", targets: ["SableCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.3.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.3"),
    ],
    targets: [
        .executableTarget(
            name: "SableApp",
            dependencies: [
                "SableCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/SableApp"
        ),
        .target(
            name: "SableCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/SableCore"
        ),
        .testTarget(
            name: "SableCoreTests",
            dependencies: ["SableCore"],
            path: "Tests/SableCoreTests"
        ),
    ]
)
