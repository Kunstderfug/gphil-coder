// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GPhilCoder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GPhilCoderCore", targets: ["GPhilCoderCore"]),
        .executable(name: "GPhilCoder", targets: ["GPhilCoder"])
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
            dependencies: ["GPhilCoderCore"]
        )
    ]
)
