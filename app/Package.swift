// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tarmac",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned past v1.13.0 to commit c2fe63d ("Fix macOS dictation and IME
        // support in NSTextInputClient", #501) — the first commit with working
        // CJK marked-text / IME on macOS. v1.13.0 ships stub NSTextInputClient
        // methods (hasMarkedText hardcoded false, setMarkedText discards the
        // composition) so the candidate window can't display. No tag contains
        // #501 yet; revert to `from: "1.14.0"` once a release ships it.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", revision: "c2fe63d1a244e98a4fbadc7b77b93799ceb97389"),
    ],
    targets: [
        .target(name: "TarmacKit"),
        .testTarget(name: "TarmacKitTests", dependencies: ["TarmacKit"]),
        .executableTarget(
            name: "TarmacApp",
            dependencies: [
                "TarmacKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.copy("Resources/DocTemplate.html")]
        ),
        .executableTarget(name: "tarmac-smoke", dependencies: ["TarmacKit"]),
    ]
)
