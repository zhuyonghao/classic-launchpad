// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClassicLaunchpad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClassicLaunchpad", targets: ["ClassicLaunchpad"])
    ],
    targets: [
        .target(name: "CMultitouchBridge", path: "Sources/CMultitouchBridge",
                linkerSettings: [.linkedFramework("CoreFoundation")]),
        .executableTarget(name: "ClassicLaunchpad", dependencies: ["CMultitouchBridge"], path: "Sources/Launchpad")
    ],
    swiftLanguageVersions: [.v5]
)
