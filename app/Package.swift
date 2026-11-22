// swift-tools-version: 6.2
import PackageDescription

// On for the three product targets. MemberImportVisibility: a file uses only
// the members of modules it imports itself; it does not stop a file from
// importing a module. It can also change which overload a call picks in a file
// that leaned on another file's import (it did in MarkdownBlocks.swift, which
// now imports Foundation itself), so compare the built objects when a target
// is added to this list. ExistentialAny: a protocol used as a type says `any`. Warnings as errors are NOT set here: the
// compiler is not pinned, and a new warning from an Xcode update must not stop
// `make run`, `make bundle` or the test job. `make lint ONLY=swiftc` holds them.
let strict: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Tarmac",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "TarmacKit", swiftSettings: strict),
        .testTarget(name: "TarmacKitTests", dependencies: ["TarmacKit"]),
        // libghostty-vt, staged by `make ghostty-vt` (scripts/fetch-ghostty-vt.sh)
        // at a pinned Ghostty commit — its C API is declared unstable.
        .binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework"),
        .target(name: "TarmacTerm", dependencies: ["GhosttyVt"], swiftSettings: strict),
        .testTarget(name: "TarmacTermTests", dependencies: ["TarmacTerm", "GhosttyVt"]),
        .executableTarget(name: "tarmac-smoke", dependencies: ["TarmacKit"]),
        .executableTarget(name: "tarmac-term-demo", dependencies: ["TarmacKit", "TarmacTerm"]),
        .executableTarget(
            name: "TarmacApp",
            dependencies: ["TarmacKit", "TarmacTerm"],
            resources: [.copy("Resources/DocTemplate.html"), .copy("Resources/Web")],
            swiftSettings: strict
        ),
    ]
)
