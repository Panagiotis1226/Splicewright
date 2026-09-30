// swift-tools-version: 6.0
import PackageDescription

// SWCore is pure Swift (Foundation only) so the timeline model and its tests
// build and run anywhere, including Linux CI. Everything that touches Apple
// media frameworks or UI is macOS-only and is left out of the manifest elsewhere.

var targets: [Target] = [
    .target(name: "SWCore"),
    .testTarget(name: "SWCoreTests", dependencies: ["SWCore"]),
]

var libraryTargets = ["SWCore"]

#if os(macOS)
// Apple-framework modules build in Swift 5 language mode: AVFoundation and
// AppKit are not fully Sendable-annotated, and strict checking there would
// only add noise until those SDKs catch up.
let appleFrameworkSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

targets += [
    .target(name: "SWMedia", dependencies: ["SWCore"], swiftSettings: appleFrameworkSettings),
    .target(name: "SWUI", dependencies: ["SWCore", "SWMedia"], swiftSettings: appleFrameworkSettings),
    .testTarget(name: "SWMediaTests", dependencies: ["SWMedia"], swiftSettings: appleFrameworkSettings),
]
libraryTargets += ["SWMedia", "SWUI"]
#endif

let package = Package(
    name: "SplicewrightKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SplicewrightKit", targets: libraryTargets),
    ],
    targets: targets
)
