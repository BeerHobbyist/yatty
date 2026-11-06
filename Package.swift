// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Yatty",
  platforms: [.macOS(.v26)],
  targets: [
    // Built from ThirdParty/ghostty by scripts/build-ghostty.sh.
    .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    // What the app and the `yatty` CLI say to each other.
    .target(name: "YattyProtocol", path: "Sources/YattyProtocol"),
    .executableTarget(
      name: "Yatty",
      dependencies: ["GhosttyKit", "YattyProtocol"],
      path: "Sources/Yatty",
      linkerSettings: [
        .linkedFramework("Carbon"),
        .linkedLibrary("c++"),
      ]
    ),
    // Installed in the app bundle as Contents/Resources/bin/yatty.
    .executableTarget(name: "yatty-cli", dependencies: ["YattyProtocol"], path: "Sources/YattyCLI"),
    .testTarget(name: "YattyTests", dependencies: ["Yatty", "YattyProtocol"], path: "Tests/YattyTests"),
  ]
)
