// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbReplay",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PlumbReplay", targets: ["PlumbReplay"]),
        .executable(name: "plumb-replay", targets: ["plumb-replay"]),
    ],
    dependencies: [
        .package(path: "../Contracts"),
        .package(path: "../Geometry"),
        .package(path: "../Signal"),
    ],
    targets: [
        .target(name: "PlumbReplay", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
            .product(name: "PlumbGeometry", package: "Geometry"),
            .product(name: "PlumbSignal", package: "Signal"),
        ]),
        .executableTarget(name: "plumb-replay", dependencies: ["PlumbReplay"]),
        .testTarget(name: "PlumbReplayTests", dependencies: [
            "PlumbReplay",
            .product(name: "PlumbContracts", package: "Contracts"),
            .product(name: "PlumbGeometry", package: "Geometry"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
