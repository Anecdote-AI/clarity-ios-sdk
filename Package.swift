// swift-tools-version: 5.10
import PackageDescription

// Clarity iOS support SDK. This manifest is mirrored verbatim to the public
// distribution repo (Anecdote-AI/clarity-ios-sdk) on release, so it must only
// reference Sources/ and Tests/ — the demo app and the e2e suite are wired
// through project.yml (XcodeGen) instead and never leave the monorepo.
let package = Package(
    name: "ClaritySDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ClaritySDK", targets: ["ClaritySDK"]),
        // The `get_location` in-app tool's CoreLocation provider, apart from
        // the core so an app that does not use location never links it.
        .library(name: "ClarityLocation", targets: ["ClarityLocation"]),
    ],
    targets: [
        .target(name: "ClaritySDK", path: "Sources/ClaritySDK"),
        .target(name: "ClarityLocation", dependencies: ["ClaritySDK"], path: "Sources/ClarityLocation"),
        // Pure-Swift core tests: run on Linux (`swift test`) and macOS alike.
        .testTarget(
            name: "ClarityCoreTests",
            dependencies: ["ClaritySDK"],
            path: "Tests/ClarityCoreTests",
            // Read from disk by path: the golden fixtures shared with Android.
            exclude: ["Fixtures"]
        ),
    ]
)
