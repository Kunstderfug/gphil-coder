// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "GPhilCodec",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GPhilCodec", targets: ["GPhilCodec"])
    ],
    targets: [
        .executableTarget(
            name: "GPhilCodec",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
