// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RescueLive",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RescueLive", targets: ["RescueLive"])],
    dependencies: [.package(path: "../RescueCore")],
    targets: [
        .target(name: "RescueLive", dependencies: ["RescueCore"]),
        .testTarget(name: "RescueLiveTests", dependencies: ["RescueLive", "RescueCore"]),
    ]
)
