// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ClawdNative",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "ClawdNativeCore", targets: ["ClawdNativeCore"]),
    .executable(name: "ClawdNative", targets: ["ClawdNative"]),
    .executable(name: "ClawdNativeHook", targets: ["ClawdNativeHook"])
  ],
  targets: [
    .target(
      name: "ClawdNativeCore",
      linkerSettings: [
        .linkedFramework("JavaScriptCore")
      ]
    ),
    .executableTarget(
      name: "ClawdNative",
      dependencies: ["ClawdNativeCore"],
      linkerSettings: [
        .linkedFramework("WebKit")
      ]
    ),
    .executableTarget(
      name: "ClawdNativeHook",
      dependencies: ["ClawdNativeCore"]
    ),
    .testTarget(
      name: "ClawdNativeCoreTests",
      dependencies: ["ClawdNativeCore"]
    )
  ]
)
