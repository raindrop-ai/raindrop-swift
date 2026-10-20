// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "raindrop-swift",
    // Duration / ContinuousClock need iOS 16 / macOS 13. Linux uses FoundationNetworking.
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "Raindrop", targets: ["Raindrop"]),
    ],
    targets: [
        // Zero third-party dependencies, by design.
        .target(name: "Raindrop", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "RaindropTests", dependencies: ["Raindrop"]),
    ],
    swiftLanguageModes: [.v6]
)
