// swift-tools-version: 6.3
import PackageDescription

// Standalone measurement/video tool. Kept OUT of the main strafe package on
// purpose: strafe advertises a ~1,080-line auditable surface (see SECURITY.md),
// and none of this benchmark harness ships in the app. bench depends on the
// main package purely to reuse the CStrafe synthesis code path, so the numbers
// exercise the exact same `strafe_post_switch_gesture` the app calls.
let package = Package(
    name: "bench",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "bench",
            dependencies: [
                // The path dependency's identity is the directory name
                // (jumpcut), matching the parent repository directory identity.
                .product(name: "CStrafe", package: "jumpcut")
            ],
            path: "Sources/bench",
            swiftSettings: [
                // Match the main repo: Swift 6 strict concurrency, warnings are
                // errors. No third-party deps anywhere.
                .unsafeFlags(["-warnings-as-errors"])
            ]
        )
    ]
)
