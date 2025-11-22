// swift-tools-version: 6.0
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
        .visionOS(.v1)
    ],
    products: [
        // FDBIndexing: インデックスメタデータ層（全プラットフォーム、依存なし）
        .library(
            name: "FDBIndexing",
            targets: ["FDBIndexing"]
        ),
        // FDBCore: FDB非依存のコア機能（Server-Client共通）
        .library(
            name: "FDBCore",
            targets: ["FDBCore"]
        ),
        // FDBRuntime: FDB依存の実行基盤（Server専用）
        .library(
            name: "FDBRuntime",
            targets: ["FDBRuntime"]
        ),
    ],
    dependencies: [
        // FoundationDB Swift Bindings (Server専用)
        .package(path: "../fdb-swift-bindings"),

        // Swift Syntax (マクロ用)
        .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),

        // Logging (optional, for FDBRuntime)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
    ],
    targets: [
        // MARK: - FDBIndexing (メタデータ層、全プラットフォーム、依存なし)

        .target(
            name: "FDBIndexing",
            dependencies: [],
            path: "Sources/FDBIndexing",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - FDBCore (FDB非依存、全プラットフォーム)

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

        // MARK: - FDBCoreMacros (マクロプラグイン)

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

        // MARK: - FDBRuntime (FDB依存、Server専用)

        .target(
            name: "FDBRuntime",
            dependencies: [
                "FDBCore",
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
            dependencies: ["FDBIndexing"],
            path: "Tests/FDBIndexingTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
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
            ]
        ),
        .testTarget(
            name: "FDBRuntimeTests",
            dependencies: ["FDBRuntime", "FDBCore"],
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
