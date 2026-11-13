// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbAgents",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbAgents", targets: ["PlumbAgents"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbAgents", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbAgentsTests", dependencies: ["PlumbAgents"]),
    ],
    swiftLanguageModes: [.v5]
)
