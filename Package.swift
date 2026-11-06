// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
]

let package = Package(
    name: "unladen",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Unladen", targets: ["Unladen"]),
        .library(name: "UnladenAsyncHTTPClient", targets: ["UnladenAsyncHTTPClient"]),
        .executable(name: "unladen", targets: ["UnladenServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.37.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        // Shared foundation: JSON, SSE, wire model, protocol codecs, profiles, transport.
        .target(
            name: "UnladenCore",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings,
        ),
        // Public semantic API for Swift developers.
        .target(
            name: "Unladen",
            dependencies: ["UnladenCore"],
            swiftSettings: swiftSettings,
        ),
        // HTTPTransport backed by AsyncHTTPClient, for Linux and the gateway.
        .target(
            name: "UnladenAsyncHTTPClient",
            dependencies: [
                "UnladenCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            swiftSettings: swiftSettings,
        ),
        // The `unladen` protocol-translating gateway server.
        .executableTarget(
            name: "UnladenServer",
            dependencies: [
                "UnladenCore",
                "UnladenAsyncHTTPClient",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenCoreTests",
            dependencies: ["UnladenCore"],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenTests",
            dependencies: ["Unladen"],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenServerTests",
            dependencies: ["UnladenServer"],
            swiftSettings: swiftSettings,
        ),
    ]
)
