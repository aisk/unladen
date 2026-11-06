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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        // Shared foundation: JSON, SSE, wire model, protocol codecs, profiles, transport.
        .target(
            name: "UnladenCore",
            dependencies: [
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(
                    name: "HTTPTypesFoundation",
                    package: "swift-http-types",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS]),
                ),
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
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
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
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings,
        ),
        // Checks shared by the test targets (stream well-formedness, JSON
        // canonical form). Not a product.
        .target(
            name: "UnladenTestSupport",
            dependencies: ["UnladenCore"],
            path: "Tests/UnladenTestSupport",
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenCoreTests",
            dependencies: ["UnladenCore", "UnladenTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenAsyncHTTPClientTests",
            dependencies: [
                "UnladenAsyncHTTPClient",
                "UnladenCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenTests",
            dependencies: [
                "Unladen",
                "UnladenCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "UnladenServerTests",
            dependencies: [
                "UnladenServer",
                "UnladenCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings,
        ),
        // Replays of real vendor traffic (see Scripts/recordings) through
        // every layer: codecs, upstream calls, the library and the gateway.
        .testTarget(
            name: "UnladenReplayTests",
            dependencies: [
                "Unladen",
                "UnladenCore",
                "UnladenServer",
                "UnladenTestSupport",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            resources: [.copy("Recordings")],
            swiftSettings: swiftSettings,
        ),
    ]
)
