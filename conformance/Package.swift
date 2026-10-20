// swift-tools-version: 6.0
// Conformance driver for Raindrop's cross-SDK conformance suite. A separate package so
// the SDK's own product list stays clean; it depends on the SDK by path.
import PackageDescription

let package = Package(
    name: "raindrop-conformance",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "raindrop-swift", path: "..")],
    targets: [
        .executableTarget(
            name: "raindrop-conformance",
            dependencies: [.product(name: "Raindrop", package: "raindrop-swift")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
