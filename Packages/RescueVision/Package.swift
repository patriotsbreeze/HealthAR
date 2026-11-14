// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RescueVision",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RescueVision", targets: ["RescueVision"])],
    dependencies: [.package(path: "../RescueCore")],
    targets: [
        .target(name: "RescueVision", dependencies: ["RescueCore"], resources: [
            .copy("Resources/Ghost.usdz"),
            .copy("Resources/Hands.usdz"),
            .copy("Resources/GripReminder.mp4"),
            .copy("Resources/GripReminder.png"),
        ]),
        .testTarget(name: "RescueVisionTests", dependencies: ["RescueVision"]),
    ]
)
