// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RescueAudio",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "RescueAudio", targets: ["RescueAudio"])],
    dependencies: [.package(path: "../RescueCore")],
    targets: [
        .target(name: "RescueAudio", dependencies: ["RescueCore"]),
        .testTarget(name: "RescueAudioTests", dependencies: ["RescueAudio", "RescueCore"]),
    ]
)
