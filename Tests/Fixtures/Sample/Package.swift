// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Sample",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "Core"),
    .target(name: "Vendor"),
    .target(name: "App", dependencies: ["Core", "Vendor"]),
    .testTarget(name: "AppTests", dependencies: ["App"]),
  ],
  swiftLanguageModes: [.v5]
)
