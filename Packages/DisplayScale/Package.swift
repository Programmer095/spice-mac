// swift-tools-version:5.9
import PackageDescription

// Pure geometry for the display-zoom feature: guest resolution <-> window points
// <-> drawable pixels. Deliberately independent of AppKit and CocoaSpice so it
// builds and is verifiable with just the Swift toolchain (no Xcode, no native SPICE
// sysroot).
//
// Note: tests use a tiny dependency-free runner (the `scalecheck` executable)
// instead of XCTest, because XCTest/swift-testing are unavailable with Command Line
// Tools (they ship only with full Xcode). Run them with: `swift run scalecheck`.
let package = Package(
    name: "DisplayScale",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "DisplayScale", targets: ["DisplayScale"]),
        .executable(name: "scalecheck", targets: ["scalecheck"]),
    ],
    targets: [
        .target(name: "DisplayScale"),
        .executableTarget(name: "scalecheck", dependencies: ["DisplayScale"]),
    ]
)
