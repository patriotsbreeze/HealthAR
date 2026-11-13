// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbSession",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbSession", targets: ["PlumbSession"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbSession", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbSessionTests", dependencies: ["PlumbSession"]),
    ],
    swiftLanguageModes: [.v5]
)
