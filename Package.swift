// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClassicLaunchpad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClassicLaunchpad", targets: ["ClassicLaunchpad"])
    ],
    targets: [
        .executableTarget(name: "ClassicLaunchpad", path: "Sources/Launchpad")
    ],
    swiftLanguageVersions: [.v5]
)
