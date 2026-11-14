// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RescueVision",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RescueVision", targets: ["RescueVision"])],
    dependencies: [.package(path: "../RescueCore")],
    targets: [
        .target(name: "RescueVision", dependencies: ["RescueCore"], resources: [.copy("Resources/Ghost.usdz")]),
        .testTarget(name: "RescueVisionTests", dependencies: ["RescueVision"]),
    ]
)
