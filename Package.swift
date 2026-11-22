// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VisionCull",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "VisionCullCore", targets: ["VisionCullCore"]),
        .executable(name: "visioncull", targets: ["VisionCullCLI"]),
        .executable(name: "VisionCullApp", targets: ["VisionCullApp"]),
    ],
    targets: [
        .target(name: "VisionCullCore"),
        .executableTarget(name: "VisionCullCLI", dependencies: ["VisionCullCore"]),
        .executableTarget(name: "VisionCullApp", dependencies: ["VisionCullCore"]),
        .testTarget(name: "VisionCullCoreTests", dependencies: ["VisionCullCore"], resources: [.copy("Fixtures")]),
    ]
)
