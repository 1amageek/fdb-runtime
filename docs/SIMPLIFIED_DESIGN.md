# Simplified Design - Final Architecture

## Overview

This document describes the simplified, finalized architecture for fdb-runtime and fdb-indexes packages based on the design discussion.

**Last Updated**: 2025-11-29

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

**Current Design** (Adopted):
```swift
// Simple protocol approach (in FDBModel)
public protocol IndexKind: Sendable, Codable, Hashable {
    static var identifier: String { get }
    static var subspaceStructure: SubspaceStructure { get }
    static func validateTypes(_ types: [Any.Type]) throws
}
```

**Note**: `makeIndexMaintainer` is NOT part of the protocol. IndexMaintainer creation is handled by the upper layers (fdb-indexes, fdb-record-layer) that implement concrete IndexMaintainer types.

**Benefits**:
- ✅ Simpler: No type erasure complexity
- ✅ Direct: `any IndexKind` instead of wrapper
- ✅ Extensible: Third parties implement `IndexKind` protocol
- ✅ Decoupled: IndexKind (FDBModel) separated from IndexMaintainer (FDBIndexing)

### 2. All Persistable Types Have `var id`

**Design**:
```swift
public protocol Persistable: Sendable, Codable {
    associatedtype ID: Sendable & Hashable & Codable
    var id: ID { get }

    static var persistableType: String { get }
    static var allFields: [String] { get }
    static var indexDescriptors: [IndexDescriptor] { get }
}
```

**Important**: When used with FDBRuntime (server-side), the ID type is validated at runtime
to ensure it conforms to `TupleElement` for FDB key encoding. This cannot be enforced at
compile time because FDBModel is platform-independent (iOS/macOS clients don't need FDB types).

**Usage**:
```swift
@Persistable
struct User {
    // ULID auto-generated (default)
    var id: String = ULID().ulidString

    #Index<User>([\.email], type: ScalarIndexKind(), unique: true)

    var email: String
    var name: String
}

@Persistable
struct Article {
    // Or use explicit Int64 ID
    var id: Int64

    var content: String
}
```

**Key Points**:
- ✅ All data has ID (FoundationDB requires keys)
- ✅ Field name is always `id` (consistent)
- ✅ ID type must conform to `Sendable & Hashable & Codable` (compile-time)
- ✅ ID type must conform to `TupleElement` at runtime for FDB storage
- ✅ ULID auto-generated if not defined (sortable unique IDs)
- ❌ No composite primary keys (use directory partitioning instead)
- ❌ No #PrimaryKey macro (removed)

### 3. Composite Keys → Directory Partitioning

**Wrong Approach** (RDB thinking):
```swift
// ❌ Don't do this - composite keys are not supported
// #PrimaryKey<Order>([\.tenantID, \.orderID])  // Removed
```

**Correct Approach** (FoundationDB thinking):
```swift
// ✅ Do this instead
@Persistable
struct Order {
    var id: String = ULID().ulidString  // Single ID
    var tenantID: String  // Partition key (stored as field)

    // Use #Directory for partitioning
    #Directory<Order>("tenants", Field(\.tenantID), "orders")
}

// FDB key: [tenants]/[tenantID]/[orders]/R/Order/[id]
//          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Directory (partition)
//                                           ^^^^ ID
```

### 4. Modular Index Architecture

**Package Structure**:
```
fdb-runtime/
├── FDBModel (Persistable protocol, IndexKind protocol, StandardIndexKinds, ULID)
├── FDBCore (Schema, ProtobufEncoder/Decoder)
├── FDBIndexing (IndexMaintainer protocol, IndexKindMaintainable protocol, DataAccess utilities)
└── FDBRuntime (FDBStore, FDBContainer, FDBContext)

fdb-indexes/ (separate package)
├── ScalarIndexLayer (ScalarIndexMaintainer for VALUE indexes)
├── AggregationIndexLayer (CountIndexMaintainer, SumIndexMaintainer)
├── MinMaxIndexLayer (MinIndexMaintainer, MaxIndexMaintainer)
├── VersionIndexLayer (VersionIndexMaintainer)
├── VectorIndexLayer (VectorIndexKind + HNSW/IVF maintainers) - planned
├── FullTextIndexLayer (FullTextIndexKind + inverted index) - planned
└── SpatialIndexLayer (S2, Geohash, etc.) - planned
```

**Note**: StandardIndexKinds (Scalar, Count, Sum, Min, Max, Version) are defined in FDBModel.
IndexMaintainer implementations are in **fdb-indexes** package.

**Usage** (import only what you need):
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/example/fdb-runtime", from: "1.0.0"),
    // .package(url: "https://github.com/example/fdb-indexes", from: "1.0.0"),  // For advanced indexes
]

targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "FDBModel", package: "fdb-runtime"),  // Model definitions
            .product(name: "FDBRuntime", package: "fdb-runtime"),  // Server runtime
            // .product(name: "VectorIndexLayer", package: "fdb-indexes"),  // When needed
        ]
    )
]
```

```swift
// MyApp.swift
import FDBModel
import FDBRuntime

@Persistable
struct Product {
    var id: Int64

    #Index<Product>([\.category], type: ScalarIndexKind())

    var category: String
}
```

## Implementation Flow

### 1. Model Definition (Compile Time)

```swift
@Persistable
struct Product {
    var id: Int64

    #Index<Product>([\.category], type: ScalarIndexKind())

    var category: String
    var name: String
}

// @Persistable macro generates:
extension Product: Persistable {
    static var persistableType: String { "Product" }
    static var allFields: [String] { ["id", "category", "name"] }
    static var indexDescriptors: [IndexDescriptor] {
        [
            IndexDescriptor(
                name: "Product_category",
                keyPaths: ["category"],
                kind: ScalarIndexKind(),  // ← Direct instance
                commonOptions: .init()
            )
        ]
    }
}
```

### 2. Store Initialization (Runtime)

```swift
// IndexMaintainer creation is handled by fdb-indexes package
// IndexKindMaintainable protocol bridges IndexKind to IndexMaintainer

let index = Index(descriptor: descriptor, itemType: "Product")

// ScalarIndexKind conforms to IndexKindMaintainable (in fdb-indexes)
let maintainer = (descriptor.kind as? IndexKindMaintainable)?.makeIndexMaintainer(
    index: index,
    subspace: indexSubspace,
    idExpression: idExpression
)

// fdb-indexes provides implementations for standard IndexKinds:
// - ScalarIndexKind → ScalarIndexMaintainer
// - CountIndexKind → CountIndexMaintainer
// - SumIndexKind → SumIndexMaintainer
// - MinIndexKind / MaxIndexKind → MinMaxIndexMaintainer
// - VersionIndexKind → VersionIndexMaintainer
```

### 3. Data Save (Runtime)

```swift
let product = Product(id: 123, category: "electronics", name: "Laptop")

try await store.save(product)

// Internal flow:
// 1. Save to itemSubspace: [R]/Product/[123] = data
// 2. Update ScalarIndex: [I]/Product_category/["electronics"]/[123] = ''
```

## Third-Party Extension Example

```swift
// fdb-geospatial-index package

import FDBModel
import FDBIndexing
import FoundationDB

// 1. Define IndexKind in your FDB-independent module
public struct GeohashIndexKind: IndexKind {
    public static let identifier = "com.example.geohash"
    public static let subspaceStructure = SubspaceStructure.hierarchical

    public let precision: Int

    public init(precision: Int = 9) {
        self.precision = precision
    }

    public static func validateTypes(_ types: [Any.Type]) throws {
        // Validation logic
    }
}

// 2. Implement IndexKindMaintainable in your FDB-dependent module
extension GeohashIndexKind: IndexKindMaintainable {
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return GeohashIndexMaintainer<Item>(
            index: index,
            precision: precision,
            subspace: subspace,
            idExpression: idExpression
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
// In FDBModel - FDB-independent, all platforms
public protocol IndexKind: Sendable, Codable, Hashable {
    static var identifier: String { get }
    static var subspaceStructure: SubspaceStructure { get }
    static func validateTypes(_ types: [Any.Type]) throws
}
```

### IndexKindMaintainable Protocol Definition

```swift
// In FDBIndexing - FDB-dependent, bridges IndexKind to IndexMaintainer
public protocol IndexKindMaintainable: IndexKind {
    func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item>
}
```

**Design Decision**: `makeIndexMaintainer` is in separate `IndexKindMaintainable` protocol.

**Rationale**:
- `IndexKind` is in FDBModel (FDB-independent, all platforms)
- `IndexKindMaintainable` is in FDBIndexing (FDB-dependent, server only)
- This separation allows IndexKind to be used on iOS clients without FDB dependency
- Implementors (fdb-indexes, third-party packages) provide IndexKindMaintainable conformance

**Implementation Pattern** (in fdb-indexes):
```swift
// ScalarIndexKind definition (in fdb-runtime/FDBModel)
public struct ScalarIndexKind: IndexKind {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat
    public static func validateTypes(_ types: [Any.Type]) throws { ... }
    public init() {}
}

// IndexKindMaintainable conformance (in fdb-indexes/ScalarIndexLayer)
extension ScalarIndexKind: IndexKindMaintainable {
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return ScalarIndexMaintainer<Item>(index: index, subspace: subspace, idExpression: idExpression)
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
| **IndexKind** | Protocol in FDBModel (not type-erased wrapper) |
| **ID Management** | All types have `var id` with TupleElement constraint |
| **ID Generation** | ULID auto-generated if not defined |
| **Composite Keys** | Not supported (use directory partitioning) |
| **#PrimaryKey macro** | Removed (not needed) |
| **IndexKindMaintainable** | Bridge protocol in FDBIndexing (connects IndexKind to IndexMaintainer) |
| **Standard Indexes** | Implementations in **fdb-indexes** package (Scalar, Count, Sum, Min, Max, Version) |
| **Advanced Indexes** | Planned for fdb-indexes package (Vector, FullText, Spatial) |
| **Third-Party Extension** | Implement IndexKind + IndexKindMaintainable + IndexMaintainer |
| **DataAccess** | Static utility (not a protocol) |

## Migration from Old Design

### Before (Old)
```swift
@Persistable
struct User {
    #PrimaryKey<User>([\.userID])  // ← Removed
    #Index<User>([\.email], type: ScalarIndexKind())

    var userID: Int64  // ← Named differently
    var email: String
}
```

### After (Current)
```swift
@Persistable
struct User {
    var id: Int64  // Required, named 'id'
    // Or: var id: String = ULID().ulidString  // Auto-generated

    #Index<User>([\.email], type: ScalarIndexKind(), unique: true)

    var email: String
}
```

### Key Changes
1. ✅ Primary key field must be named `id`
2. ✅ ID type must conform to `TupleElement` (String, Int64, UUID, etc.)
3. ❌ Remove `#PrimaryKey` macro (no longer exists)
4. ✅ Use ULID for auto-generated sortable IDs
5. ✅ Import `FDBModel` for model definitions
