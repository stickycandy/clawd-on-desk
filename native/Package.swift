// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ClawdNative",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "ClawdNativeCore", targets: ["ClawdNativeCore"]),
    .executable(name: "ClawdNative", targets: ["ClawdNative"])
  ],
  targets: [
    .target(name: "ClawdNativeCore"),
    .executableTarget(
      name: "ClawdNative",
      dependencies: ["ClawdNativeCore"],
      linkerSettings: [
        .linkedFramework("WebKit")
      ]
    ),
    .testTarget(
      name: "ClawdNativeCoreTests",
      dependencies: ["ClawdNativeCore"]
    )
  ]
)
