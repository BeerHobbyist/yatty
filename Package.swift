// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Yatty",
  platforms: [.macOS(.v26)],
  targets: [
    // Built from ThirdParty/ghostty by scripts/build-ghostty.sh.
    .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    .executableTarget(
      name: "Yatty",
      dependencies: ["GhosttyKit"],
      path: "Sources/Yatty",
      linkerSettings: [
        .linkedFramework("Carbon"),
        .linkedLibrary("c++"),
      ]
    ),
    .testTarget(name: "YattyTests", dependencies: ["Yatty"], path: "Tests/YattyTests"),
  ]
)
