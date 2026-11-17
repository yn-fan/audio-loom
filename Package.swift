// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioLoom",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AudioLoom", targets: ["AudioLoom"])],
    targets: [
        .target(name: "AudioCore"),
        .target(name: "OutputControl"),
        .executableTarget(name: "AudioLoom", dependencies: ["AudioCore", "OutputControl"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore"]),
        .testTarget(name: "OutputControlTests", dependencies: ["OutputControl"])
    ]
)
