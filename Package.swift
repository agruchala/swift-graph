// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SwiftGraph",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "swiftgraph", targets: ["swiftgraph"])],
  dependencies: [
    // swift-6.3.3-RELEASE (non-semver tag, pinned by commit)
    .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "003ac41513ba291f10ff1a0147ae68588914668d"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.1"),
  ],
  targets: [
    .target(name: "SwiftGraphCore", dependencies: [.product(name: "IndexStoreDB", package: "indexstore-db")]),
    .executableTarget(name: "swiftgraph", dependencies: [
      "SwiftGraphCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
    .testTarget(name: "SwiftGraphCoreTests", dependencies: ["SwiftGraphCore"], exclude: []),
  ]
)
