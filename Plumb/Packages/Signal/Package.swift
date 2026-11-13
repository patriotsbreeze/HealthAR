// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbSignal",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbSignal", targets: ["PlumbSignal"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbSignal", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbSignalTests", dependencies: ["PlumbSignal"]),
    ],
    swiftLanguageModes: [.v5]
)
