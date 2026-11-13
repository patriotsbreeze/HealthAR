// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbSound",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbSound", targets: ["PlumbSound"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbSound", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbSoundTests", dependencies: ["PlumbSound"]),
    ],
    swiftLanguageModes: [.v5]
)
