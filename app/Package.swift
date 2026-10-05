// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tarmac",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "TarmacKit"),
        .testTarget(name: "TarmacKitTests", dependencies: ["TarmacKit"]),
        // libghostty-vt, staged by `make ghostty-vt` (scripts/fetch-ghostty-vt.sh)
        // at a pinned Ghostty commit — its C API is declared unstable.
        .binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework"),
        .target(name: "TarmacTerm", dependencies: ["GhosttyVt"]),
        .testTarget(name: "TarmacTermTests", dependencies: ["TarmacTerm", "GhosttyVt"]),
        .executableTarget(name: "tarmac-smoke", dependencies: ["TarmacKit"]),
        .executableTarget(name: "tarmac-term-demo", dependencies: ["TarmacKit", "TarmacTerm"]),
        .executableTarget(
            name: "TarmacApp",
            dependencies: ["TarmacKit", "TarmacTerm"],
            resources: [.copy("Resources/DocTemplate.html"), .copy("Resources/Web")]
        ),
    ]
)
