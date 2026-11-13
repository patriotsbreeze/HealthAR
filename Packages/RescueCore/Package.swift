// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RescueCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RescueCore", targets: ["RescueCore"])],
    targets: [
        .target(name: "RescueCore"),
        .testTarget(name: "RescueCoreTests", dependencies: ["RescueCore"]),
    ]
)
