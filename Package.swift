// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "fdb-runtime",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        // FDBModel: Model definitions (FDB-independent, all platforms)
        .library(
            name: "FDBModel",
            targets: ["FDBModel"]
        ),
        // FDBCore: Core functionality (FDB-dependent, Server-only)
        .library(
            name: "FDBCore",
            targets: ["FDBCore"]
        ),
        // FDBIndexing: Index functionality (FDB-dependent, Server-only)
        .library(
            name: "FDBIndexing",
            targets: ["FDBIndexing"]
        ),
        // FDBRuntime: Container, Store, Context (FDB-dependent, Server-only)
        .library(
            name: "FDBRuntime",
            targets: ["FDBRuntime"]
        ),
    ],
    dependencies: [
        // FoundationDB Swift Bindings (Server-only)
        .package(path: "../fdb-swift-bindings"),

        // Swift Syntax (for macros)
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),

        // Logging (optional, for FDBCore)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),

        // Metrics (for observability)
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
    ],
    targets: [
        // MARK: - FDBModel (Model definitions, FDB-independent, all platforms)

        .target(
            name: "FDBModel",
            dependencies: [
                "FDBModelMacros",
            ],
            path: "Sources/FDBModel",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - FDBModelMacros (Macro plugin)

        .macro(
            name: "FDBModelMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/FDBModelMacros",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - FDBCore (Schema and Serialization, FDB-independent, all platforms)

        .target(
            name: "FDBCore",
            dependencies: [
                "FDBModel",
            ]
        ),

        // MARK: - FDBIndexing (Index functionality, FDB-dependent, Server-only)

        .target(
            name: "FDBIndexing",
            dependencies: [
                "FDBModel",
                "FDBCore",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),

        // MARK: - FDBRuntime (Container, Store, Context, FDB-dependent, Server-only)

        .target(
            name: "FDBRuntime",
            dependencies: [
                "FDBModel",
                "FDBCore",
                "FDBIndexing",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "FDBModelTests",
            dependencies: [
                "FDBModel",
                "FDBModelMacros",
            ]
        ),
        .testTarget(
            name: "FDBCoreTests",
            dependencies: [
                "FDBCore",
                "FDBModel",
                "FDBRuntime",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
        .testTarget(
            name: "FDBIndexingTests",
            dependencies: [
                "FDBIndexing",
                "FDBRuntime",
                "FDBCore",
                "FDBModel",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
        .testTarget(
            name: "FDBRuntimeTests",
            dependencies: [
                "FDBRuntime",
                "FDBIndexing",
                "FDBCore",
                "FDBModel",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
    ]
)
