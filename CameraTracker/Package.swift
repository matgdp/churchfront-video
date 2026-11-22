// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CameraTracker",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CameraTracker", targets: ["CameraTracker"])],
    targets: [
        .target(name: "CameraControl"),
        .executableTarget(name: "CameraTracker", dependencies: ["CameraControl"]),
        .testTarget(name: "CameraTrackerTests", dependencies: ["CameraTracker"]),
        .testTarget(name: "CameraControlTests", dependencies: ["CameraControl"]),
    ]
)
