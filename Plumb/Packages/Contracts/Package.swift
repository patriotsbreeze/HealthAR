// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbContracts",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbContracts", targets: ["PlumbContracts"])],
    targets: [
        .target(name: "PlumbContracts"),
        .testTarget(name: "PlumbContractsTests", dependencies: ["PlumbContracts"]),
    ],
    swiftLanguageModes: [.v5]
)
