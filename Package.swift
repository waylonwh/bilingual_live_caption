// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BilingualLiveCaption",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "BilingualLiveCaption", targets: ["BilingualLiveCaption"])],
    targets: [
        .target(name: "CaptionCore"),
        .executableTarget(name: "BilingualLiveCaption", dependencies: ["CaptionCore"]),
        .testTarget(name: "CaptionCoreTests", dependencies: ["CaptionCore", "BilingualLiveCaption"])
    ],
    swiftLanguageModes: [.v5]
)
