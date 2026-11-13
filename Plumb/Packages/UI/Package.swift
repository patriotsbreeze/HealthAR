// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbUI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbUI", targets: ["PlumbUI"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbUI", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbUITests", dependencies: ["PlumbUI"]),
    ],
    swiftLanguageModes: [.v5]
)
