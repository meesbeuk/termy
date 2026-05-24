// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Termy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Termy", targets: ["Termy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Termy",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Termy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
