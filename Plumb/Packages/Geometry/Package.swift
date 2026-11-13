// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbGeometry",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbGeometry", targets: ["PlumbGeometry"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbGeometry", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbGeometryTests", dependencies: ["PlumbGeometry"]),
    ],
    swiftLanguageModes: [.v5]
)
