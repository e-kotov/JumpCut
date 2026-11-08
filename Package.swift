// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "JumpCut",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Exposes the CStrafe target so the standalone `bench/` measurement
        // package (a dev tool, not part of the shipped JumpCut app) can import
        // the exact same synthesis code path via `.package(path: "..")`. This
        // is the only concession the main package makes to bench; the app
        // itself does not consume this product.
        .library(name: "CStrafe", targets: ["CStrafe"])
    ],
    targets: [
        .target(
            name: "CStrafe",
            path: "Sources/CStrafe",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "JumpCut",
            dependencies: ["CStrafe"],
            path: "Sources/JumpCut"
        ),
        .testTarget(
            name: "JumpCutTests",
            dependencies: ["JumpCut", "CStrafe"],
            path: "Tests/JumpCutTests"
        )
    ]
)
