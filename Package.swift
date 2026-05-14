// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GPhilCoder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GPhilCoder", targets: ["GPhilCoder"])
    ],
    targets: [
        .executableTarget(
            name: "GPhilCoder"
        )
    ]
)
