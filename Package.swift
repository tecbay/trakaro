// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackaroCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrackaroCore", targets: ["TrackaroCore"]),
        .library(name: "TrackaroMCP", targets: ["TrackaroMCP"]),
        .library(name: "TrackaroKit", targets: ["TrackaroKit"]),
        .executable(name: "trackaro-mcp", targets: ["trackaro-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "TrackaroCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "TrackaroMCP",
            dependencies: ["TrackaroCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "TrackaroKit",
            dependencies: ["TrackaroCore"]
        ),
        .executableTarget(
            name: "trackaro-mcp",
            dependencies: ["TrackaroCore", "TrackaroMCP", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "TrackaroCoreTests",
            dependencies: ["TrackaroCore"]
        ),
        .testTarget(
            name: "TrackaroKitTests",
            dependencies: ["TrackaroCore", "TrackaroKit"]
        ),
        .testTarget(
            name: "TrackaroMCPTests",
            dependencies: ["TrackaroCore", "TrackaroMCP", .product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
