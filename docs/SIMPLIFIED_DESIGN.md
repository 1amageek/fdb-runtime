# Simplified Design - Final Architecture

## Overview

This document describes the simplified, finalized architecture for fdb-runtime and fdb-indexes packages based on the design discussion.

## Key Design Decisions

### 1. IndexKind is a Protocol (not a type-erased wrapper)

**Previous Design** (Rejected):
```swift
// Type-erased wrapper approach
public struct IndexKind: Sendable, Codable {
    let identifier: String
    let configuration: Data  // JSON-encoded

    init<K: IndexKind>(_ kind: K) throws
    func decode<K: IndexKind>(_ type: K.Type) throws -> K
}
```

**New Design** (Adopted):
```swift
// Simple protocol approach
public protocol IndexKind: Sendable, Hashable {
    static var identifier: String { get }
    static var subspaceStructure: SubspaceStructure { get }

    func makeIndexMaintainer<Item>(
        index: Index,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item>
}
```

**Benefits**:
- ✅ Simpler: No type erasure complexity
- ✅ Direct: `any IndexKind` instead of wrapper
- ✅ Extensible: Third parties implement `IndexKind` protocol
- ✅ Type-safe: Each IndexKind creates its own IndexMaintainer

### 2. All Persistable Types Have `var id`

**Design**:
```swift
public protocol Persistable: Identifiable, Sendable, Codable {
    // Identifiable requires: var id: ID { get }

    static var persistableType: String { get }
    static var allFields: [String] { get }
    static var indexDescriptors: [IndexDescriptor] { get }
}
```

**Usage**:
```swift
@Persistable
struct User {
    var id: Int64  // Required by Identifiable

    #Index<User>([\.email], type: ScalarIndexKind())

    var email: String
    var name: String
}

@Persistable
struct Article {
    var id: UUID  // Auto-generated in DocumentLayer

    #Index<Article>([\.content], type: FullTextIndexKind())

    var content: String
}
```

**Key Points**:
- ✅ All data has ID (FoundationDB requires keys)
- ✅ Field name is always `id` (consistent)
- ✅ ID type is flexible (Int64, UUID, String, etc.)
- ❌ No composite primary keys (use directory partitioning instead)
- ❌ No #PrimaryKey macro (not needed)

### 3. Composite Keys → Directory Partitioning

**Wrong Approach** (RDB thinking):
```swift
// ❌ Don't do this
#PrimaryKey<Order>([\.tenantID, \.orderID])  // Composite key

// FDB key: [R]/Order/[tenantID]/[orderID]
```

**Correct Approach** (FoundationDB thinking):
```swift
// ✅ Do this instead
struct Order: Persistable {
    var id: UUID  // Single ID
    var tenantID: String  // Partition key (not part of primary key)

    // Directory structure handles partitioning
    static var directoryPath: [String] {
        ["tenants", tenantID, "orders"]
    }
}

// FDB key: [tenants]/[tenantID]/[orders]/[id]
//          ^^^^^^^^^^^^^^^^^^^^^^^^ Directory (partition)
//                                   ^^^^ ID
```

### 4. Modular Index Layers (fdb-indexes package)

**Package Structure**:
```
fdb-runtime/
├── FDBIndexing (protocols: IndexKind, IndexMaintainer, DataAccess)
├── FDBCore (Persistable protocol + @Persistable macro)
└── FDBRuntime (FDBStore implementation)

fdb-indexes/
├── ScalarIndexLayer (ScalarIndexKind + ScalarIndexMaintainer)
├── VectorIndexLayer (VectorIndexKind + HNSW/IVF maintainers)
├── FullTextIndexLayer (FullTextIndexKind + inverted index)
└── AggregationIndexLayer (Count/Sum/Min/Max kinds)
```

**Usage** (import only what you need):
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/example/fdb-runtime", from: "1.0.0"),
    .package(url: "https://github.com/example/fdb-indexes", from: "1.0.0"),
]

targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "FDBCore", package: "fdb-runtime"),
            .product(name: "FDBRuntime", package: "fdb-runtime"),
            .product(name: "ScalarIndexLayer", package: "fdb-indexes"),  // ← Only import what you need
            .product(name: "VectorIndexLayer", package: "fdb-indexes"),
        ]
    )
]
```

```swift
// MyApp.swift
import FDBCore
import FDBRuntime
import ScalarIndexLayer
import VectorIndexLayer

@Persistable
struct Product {
    var id: Int64

    #Index<Product>([\.category], type: ScalarIndexKind())
    #Index<Product>([\.embedding], type: VectorIndexKind(dimensions: 384))

    var category: String
    var embedding: [Float32]
}
```

## Implementation Flow

### 1. Model Definition (Compile Time)

```swift
@Persistable
struct Product {
    var id: Int64

    #Index<Product>([\.category], type: ScalarIndexKind())
    #Index<Product>([\.embedding], type: VectorIndexKind(dimensions: 384))

    var category: String
    var embedding: [Float32]
}

// @Persistable macro generates:
extension Product: Persistable {
    static var persistableType: String { "Product" }
    static var allFields: [String] { ["id", "category", "embedding"] }
    static var indexDescriptors: [IndexDescriptor] {
        [
            IndexDescriptor(
                name: "Product_category",
                keyPaths: ["category"],
                kind: ScalarIndexKind(),  // ← Direct instance
                commonOptions: .init()
            ),
            IndexDescriptor(
                name: "Product_embedding",
                keyPaths: ["embedding"],
                kind: VectorIndexKind(dimensions: 384),  // ← Direct instance
                commonOptions: .init()
            )
        ]
    }
}
```

### 2. Store Initialization (Runtime)

```swift
// LayerConfiguration selects appropriate IndexMaintainer
public func makeIndexMaintainer<Item>(
    for index: Index,
    subspace: Subspace
) throws -> any IndexMaintainer<Item> {
    // Delegate to IndexKind
    return try index.kind.makeIndexMaintainer(index: index, subspace: subspace)
}

// IndexKind.makeIndexMaintainer() implementation
extension ScalarIndexKind {
    public func makeIndexMaintainer<Item>(
        index: Index,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        return ScalarIndexMaintainer<Item>(index: index, kind: self, subspace: subspace)
    }
}

extension VectorIndexKind {
    public func makeIndexMaintainer<Item>(
        index: Index,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        switch algorithm {
        case .hnsw(let params):
            return HNSWIndexMaintainer<Item>(...params...)
        case .flatScan:
            return FlatVectorIndexMaintainer<Item>(...)
        }
    }
}
```

### 3. Data Save (Runtime)

```swift
let product = Product(id: 123, category: "electronics", embedding: [...])

try await store.save(product)

// Internal flow:
// 1. Save to itemSubspace: [R]/Product/[123] = data
// 2. Update ScalarIndex: [I]/Product_category/["electronics"]/[123] = ''
// 3. Update VectorIndex (HNSW): [I]/Product_embedding/graph/... = HNSW structure
```

## Third-Party Extension Example

```swift
// fdb-geospatial-index package

import FDBIndexing
import FoundationDB

public struct GeohashIndexKind: IndexKind {
    public static let identifier = "com.example.geohash"
    public static let subspaceStructure = SubspaceStructure.hierarchical

    public let precision: Int

    public init(precision: Int = 9) {
        self.precision = precision
    }

    public func makeIndexMaintainer<Item>(
        index: Index,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        return GeohashIndexMaintainer<Item>(
            index: index,
            precision: precision,
            subspace: subspace
        )
    }
}

// Usage in app
import FDBCore
import GeospatialIndexLayer

@Persistable
struct Location {
    var id: UUID

    #Index<Location>(
        [\.latitude, \.longitude],
        type: GeohashIndexKind(precision: 9)
    )

    var latitude: Double
    var longitude: Double
}
```

## Runtime Algorithm Configuration (Advanced)

### Problem: Model Definition Should Not Dictate Algorithm

**Bad Design** (モデル定義時にアルゴリズム固定):
```swift
// ❌ Don't do this - algorithm hardcoded in model
@Persistable
struct Product {
    var id: Int64

    #Index<Product>(
        [\.embedding],
        type: VectorIndexKind(
            dimensions: 384,
            algorithm: .hnsw(...)  // ← Hardcoded in model
        )
    )

    var embedding: [Float32]
}
```

**Issues**:
- ❌ Cannot change algorithm without changing model code
- ❌ Cannot adapt to different environments (dev vs prod)
- ❌ HNSW requires high memory - may not be available in all environments

### Solution: Separate Model Definition from Runtime Configuration

#### 1. Model Definition (Data Structure Only)

```swift
import FDBCore
import VectorIndexLayer

@Persistable
struct Product {
    var id: Int64

    // Only specify data structure properties
    #Index<Product>([\.embedding], type: VectorIndexKind(dimensions: 384, metric: .cosine))

    var embedding: [Float32]
}
```

**Note**: No algorithm specification in model - only dimensions and metric (data properties).

#### 2. Runtime Configuration (Algorithm Selection)

**String-based approach** (current fdb-record-layer implementation):
```swift
let schema = Schema(
    [Product.self],
    indexConfigurations: [
        IndexConfiguration(
            indexName: "Product_embedding",
            vectorStrategy: .hnswBatch
        )
    ]
)
```

**KeyPath-based approach** (proposed, type-safe):
```swift
let schema = Schema(
    [Product.self],
    indexConfigurations: IndexConfigurationBuilder()
        .configure(Product.self, \.embedding, algorithm: .vectorHNSW(.default))
        .build()
)
```

#### 3. Environment-Based Algorithm Selection

```swift
// Development: Low memory, fast startup
#if DEBUG
let vectorAlgorithm: AlgorithmConfiguration = .vectorFlatScan
#else
// Production: High performance
let vectorAlgorithm: AlgorithmConfiguration = .vectorHNSW(
    HNSWParameters(m: 16, efConstruction: 200, efSearch: 100)
)
#endif

let schema = Schema(
    [Product.self],
    indexConfigurations: IndexConfigurationBuilder()
        .configure(Product.self, \.embedding, algorithm: vectorAlgorithm)
        .build()
)
```

#### 4. Multiple Index Configuration

```swift
let schema = Schema(
    [Product.self, User.self, Location.self],
    indexConfigurations: IndexConfigurationBuilder()
        // Product: Large dataset → HNSW
        .configure(Product.self, \.embedding, algorithm: .vectorHNSW(.default))

        // User: Small dataset → Flat scan
        .configure(User.self, \.avatar_embedding, algorithm: .vectorFlatScan)

        // Location: Spatial index level
        .configure(Location.self, \.coordinates, algorithm: .spatial(level: 15))

        .build()
)
```

### IndexKind Protocol Definition

```swift
public protocol IndexKind: Sendable, Codable, Hashable {
    static var identifier: String { get }
    static var subspaceStructure: SubspaceStructure { get }
    static func validateTypes(_ types: [Any.Type]) throws

    // NOTE: makeIndexMaintainer is NOT a protocol requirement
    // It is implemented by concrete IndexKind types in upper layers (fdb-indexes)
}
```

**Design Decision**: `makeIndexMaintainer` is NOT part of the protocol requirement.

**Rationale**:
- FDBIndexing contains **metadata-only** IndexKind definitions (used by @Persistable macro, schema, tests)
- Actual IndexMaintainer implementations are in **separate packages** (fdb-indexes, third-party packages)
- Requiring makeIndexMaintainer would create **circular dependency** (fdb-runtime → fdb-indexes → fdb-runtime)

**Implementation Pattern** (in fdb-indexes or third-party packages):
```swift
// ScalarIndexKind definition (in fdb-runtime/FDBIndexing)
public struct ScalarIndexKind: IndexKind {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat
    public static func validateTypes(_ types: [Any.Type]) throws { ... }
    public init() {}
}

// ScalarIndexKind.makeIndexMaintainer (in fdb-indexes/ScalarIndexLayer)
extension ScalarIndexKind {
    public func makeIndexMaintainer<Item: Sendable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return ScalarIndexMaintainer<Item>(index: index, kind: self, subspace: subspace)
    }
}
```

### AlgorithmConfiguration

```swift
/// Runtime algorithm configuration
public enum AlgorithmConfiguration: Sendable {
    // Vector algorithms
    case vectorFlatScan
    case vectorHNSW(HNSWParameters)
    case vectorIVF(IVFParameters)

    // Spatial algorithms
    case spatial(level: Int)

    // Full-text algorithms
    case fullTextStandard
    case fullTextAdvanced(stemming: Bool, stopwords: [String])

    // Future: other configurable algorithms
}
```

### IndexConfigurationBuilder (Type-Safe)

```swift
public struct IndexConfigurationBuilder {
    private var configurations: [String: AlgorithmConfiguration] = [:]

    /// Type-safe configuration using KeyPath
    public func configure<Model: Persistable, Value>(
        _ modelType: Model.Type,
        _ keyPath: KeyPath<Model, Value>,
        algorithm: AlgorithmConfiguration
    ) -> IndexConfigurationBuilder {
        var builder = self
        let indexName = "\(Model.persistableType)_\(Model.fieldName(for: keyPath))"
        builder.configurations[indexName] = algorithm
        return builder
    }

    public func build() -> [String: AlgorithmConfiguration] {
        return configurations
    }
}
```

**Benefits**:
- ✅ **Type-safe**: KeyPath ensures field exists on model
- ✅ **Refactoring-friendly**: Field renaming tracked by compiler
- ✅ **IDE support**: Auto-completion works
- ✅ **Runtime flexibility**: Change algorithm per environment
- ✅ **Model separation**: Model definition independent of runtime optimization

### @Persistable Macro Extension

The `@Persistable` macro generates `fieldName(for:)` method for KeyPath mapping:

```swift
@Persistable
struct Product {
    var id: Int64
    var embedding: [Float32]
}

// Generated by macro:
extension Product {
    public static func fieldName<Value>(for keyPath: KeyPath<Product, Value>) -> String {
        switch keyPath {
        case \Product.id:
            return "id"
        case \Product.embedding:
            return "embedding"
        default:
            fatalError("Unknown KeyPath")
        }
    }
}
```

### VectorIndexKind Implementation

```swift
public struct VectorIndexKind: IndexKind {
    public static let identifier = "vector"
    public static let subspaceStructure = SubspaceStructure.hierarchical

    public let dimensions: Int
    public let metric: VectorMetric

    public init(dimensions: Int, metric: VectorMetric = .cosine) {
        self.dimensions = dimensions
        self.metric = metric
    }

    public func makeIndexMaintainer<Item>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {

        // Select algorithm from configuration
        let algorithm: VectorAlgorithm
        if let config = configuration {
            switch config {
            case .vectorFlatScan:
                algorithm = .flatScan
            case .vectorHNSW(let params):
                algorithm = .hnsw(params)
            case .vectorIVF(let params):
                algorithm = .ivf(params)
            default:
                throw IndexError.incompatibleConfiguration
            }
        } else {
            // Default: flatScan (safe fallback)
            algorithm = .flatScan
        }

        // Create maintainer based on algorithm
        switch algorithm {
        case .flatScan:
            return FlatVectorIndexMaintainer<Item>(...)
        case .hnsw(let params):
            return HNSWIndexMaintainer<Item>(..., params: params)
        case .ivf(let params):
            return IVFIndexMaintainer<Item>(..., params: params)
        }
    }
}
```

## Summary

| Aspect | Design Choice |
|--------|---------------|
| **IndexKind** | Protocol (not type-erased wrapper) |
| **ID Management** | All types have `var id` (Identifiable) |
| **Composite Keys** | Not supported (use directory partitioning) |
| **#PrimaryKey macro** | Removed (not needed) |
| **Capability Protocols** | Removed (not needed) |
| **Modular Indexes** | Separate fdb-indexes package |
| **Third-Party Extension** | Implement IndexKind protocol |
| **Algorithm Configuration** | Runtime selection via IndexConfigurationBuilder |
| **Model-Algorithm Separation** | Model defines structure, runtime selects algorithm |

## Migration from Old Design

### Before
```swift
@Persistable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], type: ScalarIndexKind())

    var userID: Int64
    var email: String
}
```

### After
```swift
@Persistable
struct User {
    var id: Int64  // Renamed from userID, Required by Identifiable

    #Index<User>([\.email], type: ScalarIndexKind())

    var email: String
}
```

### Key Changes
1. ✅ Rename primary key field to `id`
2. ❌ Remove `#PrimaryKey` macro
3. ✅ Import specific IndexLayers from fdb-indexes
4. ✅ Use `any IndexKind` directly (no wrapper)
