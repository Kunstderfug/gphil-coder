// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GPhil MediaFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GPhilCoderCore", targets: ["GPhilCoderCore"]),
        .executable(name: "GPhil MediaFlow", targets: ["GPhilCoder"])
    ],
    targets: [
        .target(
            name: "GPhilCoderCore"
        ),
        .executableTarget(
            name: "GPhilCoder",
            dependencies: ["GPhilCoderCore"]
        ),
        .testTarget(
            name: "GPhilCoderTests",
            dependencies: ["GPhilCoderCore", "GPhilCoder"],
            exclude: ["TESTING.md"]
        )
    ]
)
