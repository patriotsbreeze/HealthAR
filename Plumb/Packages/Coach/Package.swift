// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlumbCoach",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PlumbCoach", targets: ["PlumbCoach"])],
    dependencies: [
        .package(path: "../Contracts"),
    ],
    targets: [
        .target(name: "PlumbCoach", dependencies: [
            .product(name: "PlumbContracts", package: "Contracts"),
        ]),
        .testTarget(name: "PlumbCoachTests", dependencies: ["PlumbCoach"]),
    ],
    swiftLanguageModes: [.v5]
)
