// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "fdb-runtime",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // FDBIndexing: Index abstraction layer (FDB-dependent, Server-only)
        .library(
            name: "FDBIndexing",
            targets: ["FDBIndexing"]
        ),
        // FDBCore: FDB-independent core functionality (Server-only, model definitions only)
        .library(
            name: "FDBCore",
            targets: ["FDBCore"]
        ),
        // FDBRuntime: FDB-dependent runtime layer (Server-only, Store implementation)
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

        // Logging (optional, for FDBRuntime)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
    ],
    targets: [
        // MARK: - FDBIndexing (Index abstraction layer, FDB-dependent, Server-only)

        .target(
            name: "FDBIndexing",
            dependencies: [
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
            ],
            path: "Sources/FDBIndexing",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - FDBCore (FDB-independent, all platforms)

        .target(
            name: "FDBCore",
            dependencies: [
                "FDBCoreMacros",
                "FDBIndexing",
            ],
            path: "Sources/FDBCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - FDBCoreMacros (Macro plugin)

        .macro(
            name: "FDBCoreMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/FDBCoreMacros",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - FDBRuntime (FDB-dependent, Server-only)

        .target(
            name: "FDBRuntime",
            dependencies: [
                "FDBCore",
                "FDBIndexing",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/FDBRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "FDBIndexingTests",
            dependencies: [
                "FDBIndexing",
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
            ],
            path: "Tests/FDBIndexingTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
        .testTarget(
            name: "FDBCoreTests",
            dependencies: [
                "FDBCore",
                "FDBCoreMacros",
                "FDBIndexing",
            ],
            path: "Tests/FDBCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
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
                "FDBCore",
                "FDBIndexing",
            ],
            path: "Tests/FDBRuntimeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
    ]
)
