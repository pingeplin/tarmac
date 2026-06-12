// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tarmac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
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
