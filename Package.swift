// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GarminPulse",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GarminPulse", targets: ["GarminBar"])],
    targets: [
        .executableTarget(name: "GarminBar", path: "Sources/GarminBar", resources: [.process("Resources")]),
        .testTarget(name: "GarminBarTests", dependencies: ["GarminBar"])
    ],
    swiftLanguageVersions: [.v5]
)
