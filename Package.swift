// swift-tools-version: 5.9
import PackageDescription

// EarshotCore and the command-line tool are plain Foundation, so they also
// build (and their tests run) on Linux. The app itself needs AppKit,
// SwiftUI and AVFoundation, so it is only declared when building on macOS.
var products: [Product] = [
    .library(name: "EarshotCore", targets: ["EarshotCore"]),
    .executable(name: "earshot-cli", targets: ["earshot-cli"]),
]

var targets: [Target] = [
    .target(name: "EarshotCore"),
    .executableTarget(name: "earshot-cli", dependencies: ["EarshotCore"]),
    .testTarget(name: "EarshotCoreTests", dependencies: ["EarshotCore"]),
]

#if os(macOS)
products.append(.executable(name: "Earshot", targets: ["Earshot"]))
targets.append(.executableTarget(name: "Earshot", dependencies: ["EarshotCore"]))
#endif

let package = Package(
    name: "Earshot",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
