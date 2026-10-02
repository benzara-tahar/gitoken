// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitokenCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GitokenCore", targets: ["GitokenCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.9"),
    ],
    targets: [
        .target(
            name: "GitokenCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GitokenCoreTests",
            dependencies: ["GitokenCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
