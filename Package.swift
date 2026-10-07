// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Runa",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RunaCore", targets: ["RunaCore"]),
        .library(name: "RunaDesign", targets: ["RunaDesign"]),
        .executable(name: "runa", targets: ["RunaCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "RunaCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(name: "RunaDesign"),
        .executableTarget(
            name: "RunaCLI",
            dependencies: [
                "RunaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "RunaCoreTests",
            dependencies: ["RunaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
