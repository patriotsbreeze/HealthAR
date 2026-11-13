// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbCapture",
    platforms: [.iOS(.v18)],
    products: [.library(name: "PlumbCapture", targets: ["PlumbCapture"])],
    dependencies: [
        .package(path: "../Contracts"),
        .package(path: "../Geometry"),
    ],
    targets: [
        .target(name: "PlumbCapture", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
            .product(name: "PlumbGeometry", package: "Geometry"),
        ]),
        .testTarget(name: "PlumbCaptureTests", dependencies: ["PlumbCapture"]),
    ],
    swiftLanguageModes: [.v5]
)
