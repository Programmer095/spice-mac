// swift-tools-version:5.9
import PackageDescription

// Note: tests use a tiny dependency-free runner (the `pvecheck` executable) instead
// of XCTest, matching VVConfig/SpiceInputMap — XCTest ships only with full Xcode.
// Run them with: `swift run pvecheck`.
let package = Package(
    name: "PVEClient",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PVEClient", targets: ["PVEClient"]),
        .executable(name: "pvecheck", targets: ["pvecheck"]),
        .executable(name: "hangcheck", targets: ["hangcheck"]),
    ],
    targets: [
        .target(name: "PVEClient"),
        .executableTarget(name: "pvecheck", dependencies: ["PVEClient"]),
        // Opens real sockets, so it lives apart from pvecheck's socket-free checks.
        .executableTarget(name: "hangcheck", dependencies: ["PVEClient"]),
    ]
)
