# FDBRuntime

**A unified runtime foundation for building diverse data models on FoundationDB**

FDBRuntime provides the core abstractions and protocols for building type-safe, high-performance data layers on FoundationDB. It supports multiple data models (Record, Document, Vector, Graph) through a common foundation while maintaining flexibility and extensibility.

[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS%20%7C%20Linux-blue.svg)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🎯 Purpose & Background

### Why FDBRuntime?

**Problem**: Building different data models (structured records, flexible documents, vector embeddings, graph relationships) on FoundationDB requires duplicating common infrastructure:
- Index management systems
- Schema evolution
- Query optimization
- Transaction coordination
- Storage abstractions

**Solution**: FDBRuntime provides a **unified foundation** that:
- ✅ Defines common protocols (IndexMaintainer, DataAccess, IndexKind)
- ✅ Provides shared implementations (FDBStore, IndexManager, built-in index types)
- ✅ Enables multiple data models to coexist on the same infrastructure
- ✅ Maintains type safety through Swift's type system
- ✅ Supports both server (FoundationDB) and client (iOS/macOS) environments

### Design Philosophy

**"One runtime, many models"**

Instead of building separate, incompatible systems for different data needs, FDBRuntime provides:

1. **Protocol-based extensibility**: New data models extend core protocols
2. **Shared infrastructure**: FDBStore, IndexManager, built-in indexes are reused
3. **Platform separation**: FDB-independent core (FDBCore) vs server runtime (FDBRuntime)
4. **Type safety**: Leverage Swift's type system for compile-time guarantees

---

## 📦 Module Structure

FDBRuntime consists of **three modules** with clear responsibilities:

```
┌─────────────────────────────────────────────────────────┐
│                    FDBIndexing                           │
│  Role: Index metadata abstractions                      │
│  Dependencies: Swift stdlib + Foundation                │
│  Platform: iOS, macOS, Linux, tvOS, watchOS, visionOS   │
│                                                          │
│  ✅ IndexKindProtocol (protocol definition)             │
│  ✅ Built-in IndexKinds (Scalar, Count, Sum, etc.)      │
│  ✅ IndexDescriptor (metadata container)                │
│  ✅ IndexAnnotatable (annotation protocol)              │
│  ✅ TypeValidation (compile-time type checks)           │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                     FDBCore                              │
│  Role: FDB-independent core (client-server shared)      │
│  Dependencies: FDBIndexing + Swift stdlib               │
│  Platform: iOS, macOS, Linux, tvOS, watchOS, visionOS   │
│                                                          │
│  ✅ Recordable protocol                                 │
│  ✅ @Recordable macro (FDBCoreMacros)                   │
│  ✅ EnumMetadata                                        │
│  ✅ Codable support (JSON, Protobuf)                    │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                   FDBRuntime                             │
│  Role: Abstract runtime foundation (server-only)        │
│  Dependencies: FDBCore + FoundationDB                   │
│  Platform: macOS, Linux (server-only)                   │
│                                                          │
│  ✅ FDBStore (type-independent, operates on items)      │
│  ✅ FDBContainer (container management)                 │
│  ✅ FDBContext (change tracking, SwiftData-like API)    │
│  ✅ IndexMaintainer protocol (index update interface)   │
│  ✅ DataAccess protocol (data access interface)         │
│  ✅ IndexManager (index registration & management)      │
└────────────┬────────────────────────────────────────────┘
             │ Implementations in data model layers
             ├─────────────────┬──────────────┬───────────┐
             │                 │              │           │
             ▼                 ▼              ▼           ▼
┌─────────────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────┐
│ fdb-record-layer│ │fdb-document │ │fdb-vector│ │fdb-graph │
│                 │ │   -layer    │ │  -layer  │ │  -layer  │
├─────────────────┤ ├─────────────┤ ├──────────┤ ├──────────┤
│ RecordStore     │ │DocumentStore│ │VectorStore││GraphStore│
│ DataAccess      │ │DataAccess   │ │DataAccess│ │DataAccess│
│ IndexMaintainer │ │Maintainer   │ │Maintainer│ │Maintainer│
│ QueryPlanner    │ │QueryBuilder │ │NNSearch  │ │Traversal │
│ Recordable      │ │Document     │ │Vector    │ │Node/Edge │
└─────────────────┘ └─────────────┘ └──────────┘ └──────────┘
```

### Module Responsibilities

| Module | Responsibility | Platform Support | Dependencies |
|--------|---------------|------------------|--------------|
| **FDBIndexing** | Index metadata abstractions (protocols + built-ins) | All platforms | None |
| **FDBCore** | FDB-independent core, model definitions | All platforms | FDBIndexing |
| **FDBRuntime** | Abstract runtime protocols + shared implementations (operates on type-independent "items") | Server-only | FDBCore + FoundationDB |

---

## 🏗️ Architecture Principles

### 1. **Shared FDBStore Across All Models**

Unlike traditional approaches where each data model has its own store (RecordStore, DocumentStore, etc.), **FDBRuntime uses a single FDBStore** that is shared across all data model layers:

> **Terminology Note**: FDBStore operates on **"items"** (type-independent data) internally, while upper layers (RecordStore, DocumentStore, etc.) work with typed **"records"** or **"documents"**. This distinction clarifies that FDBStore is a low-level storage abstraction operating on raw `Data`, not a type-safe layer.

**Traditional (fragmented)**:
```swift
// ❌ Each model has its own store type
let recordStore = RecordStore<User>(...)
let documentStore = DocumentStore(...)
let vectorStore = VectorStore(...)
// → Code duplication, incompatible abstractions
```

**FDBRuntime (unified)**:
```swift
// ✅ One FDBStore, multiple access patterns
let store = container.store(for: subspace)

// Different data models use the same store (each implementing DataAccess protocol)
let recordDataAccess = RecordDataAccess<User>(store: store, schema: schema)
let docDataAccess = DocumentDataAccess(store: store)
let vectorDataAccess = VectorDataAccess(store: store, dimensions: 768)
```

### 2. **Protocol-Based Extensibility**

FDBRuntime defines **protocols**, not concrete implementations:

```swift
// Protocol definition (in FDBRuntime)
public protocol IndexMaintainer: Sendable {
    func updateIndex(...) async throws
    func removeIndex(...) async throws
}

// Implementations (in data model layers)
// fdb-record-layer:
struct RecordIndexMaintainer<Record>: IndexMaintainer { ... }

// fdb-document-layer:
struct DocumentIndexMaintainer: IndexMaintainer { ... }

// fdb-vector-layer:
struct VectorIndexMaintainer: IndexMaintainer { ... }
```

### 3. **Platform Separation**

```
Client (iOS/macOS)          Server (macOS/Linux)
┌───────────────┐           ┌───────────────────┐
│  FDBIndexing  │           │   FDBIndexing     │
│  FDBCore      │           │   FDBCore         │
│               │           │   FDBRuntime      │
│               │           │   fdb-*-layer     │
└───────────────┘           └───────────────────┘
     │                              │
     │ JSON/REST API                │ FoundationDB
     ▼                              ▼
┌───────────────┐           ┌───────────────────┐
│  SwiftUI App  │ ◀────────▶│  Vapor/Hummingbird│
└───────────────┘           └───────────────────┘
```

**Client-side**:
- Uses `FDBCore` + `FDBIndexing` for model definitions
- Codable support for JSON APIs
- No FoundationDB dependency

**Server-side**:
- Uses `FDBRuntime` for full persistence
- Implements IndexMaintainer, DataAccess protocols
- Connects to FoundationDB cluster

---

## 🚀 Getting Started

### Installation

Add to your `Package.swift`:

**For client projects (iOS/macOS)**:
```swift
dependencies: [
    .package(url: "https://github.com/1amageek/fdb-runtime.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "FDBCore", package: "fdb-runtime"),
        ]
    )
]
```

**For server projects**:
```swift
dependencies: [
    .package(url: "https://github.com/1amageek/fdb-runtime.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourServer",
        dependencies: [
            .product(name: "FDBRuntime", package: "fdb-runtime"),
        ]
    )
]
```

### Basic Usage

**Client-side (iOS/macOS)**:
```swift
import FDBCore

// Define model (SSOT)
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    var userID: Int64
    var email: String
    var name: String
}

// Use with JSON API
let user = User(userID: 1, email: "test@example.com", name: "Alice")
let jsonData = try JSONEncoder().encode(user)

// SwiftUI
List(users, id: \.userID) { user in
    Text(user.name)
}
```

**Server-side**:
```swift
import FDBCore      // Model definitions
import FDBRuntime   // FDBStore, protocols
import FDBRecordLayer  // Type-safe extensions

// Define model with indexes
@Recordable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email], type: ScalarIndexKind())  // ← From FDBIndexing

    var userID: Int64
    var email: String
    var name: String
}

// FDBStore is shared across all models
// Note: FDBStore internally operates on "items" (type-independent Data),
//       while RecordStore provides type-safe "record" operations
let container = FDBContainer(database: database)
let subspace = try await container.getOrOpenDirectory(path: ["users"])
let store = container.store(for: subspace)

// Use type-safe extensions (fdb-record-layer)
let recordStore = RecordStore<User>(store: store, schema: schema)
try await recordStore.save(user)
```

---

## 📊 Built-in Index Types

FDBIndexing module provides **protocol-based extensible index system** with 7 built-in IndexKind implementations:

| IndexKind | Identifier | Use Case | Complexity |
|-----------|-----------|----------|------------|
| **ScalarIndexKind** | `"scalar"` | Standard B-tree index, range queries | O(log n) |
| **CountIndexKind** | `"count"` | Count records per group | O(1) update |
| **SumIndexKind** | `"sum"` | Sum numeric fields per group | O(1) update |
| **MinIndexKind** | `"min"` | Track minimum value per group | O(log n) |
| **MaxIndexKind** | `"max"` | Track maximum value per group | O(log n) |
| **VersionIndexKind** | `"version"` | Optimistic concurrency control | O(1) |
| **VectorIndexKind** | `"vector"` | Vector search (HNSW/IVF/Flat) | O(log n) / O(n) |

### IndexKindProtocol Design

All index kinds implement `IndexKindProtocol`, enabling type-safe extensibility:

```swift
public protocol IndexKindProtocol: Sendable, Codable, Hashable {
    static var identifier: String { get }
    static var subspaceStructure: SubspaceStructure { get }
    static func validateTypes(_ types: [Any.Type]) throws
}
```

**Key Features**:
- ✅ **Type-Safe**: Configuration stored as Codable JSON
- ✅ **Extensible**: Third parties can add custom index kinds
- ✅ **Validated**: Type constraints enforced at compile-time
- ✅ **Structured**: SubspaceStructure defines index organization

### Using Built-in IndexKinds

**Scalar Indexes** (VALUE, COUNT, SUM, MIN/MAX):
```swift
import FDBCore
import FDBIndexing  // Built-in IndexKinds

@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    // Scalar indexes
    #Index<Product>([\.category], type: ScalarIndexKind())
    #Index<Product>([\.category], type: CountIndexKind())
    #Index<Product>([\.category, \.price], type: SumIndexKind())
    #Index<Product>([\.category, \.price], type: MinIndexKind())
    #Index<Product>([\.category, \.price], type: MaxIndexKind())

    var productID: Int64
    var category: String
    var price: Double
}
```

**Vector Indexes** (with algorithm selection):
```swift
@Recordable
struct Product {
    #PrimaryKey<Product>([\.productID])

    // Flat scan (small datasets < 1K)
    #Index<Product>(
        [\.embedding],
        type: VectorIndexKind(
            dimensions: 384,
            metric: .cosine,
            algorithm: .flatScan
        )
    )

    // HNSW (large datasets > 10K)
    #Index<Product>(
        [\.embedding],
        type: VectorIndexKind(
            dimensions: 384,
            metric: .cosine,
            algorithm: .hnsw(HNSWParameters(
                m: 16,
                efConstruction: 200
            ))
        )
    )

    // IVF (medium datasets 1K-10K)
    #Index<Product>(
        [\.embedding],
        type: VectorIndexKind(
            dimensions: 384,
            metric: .l2,
            algorithm: .ivf(IVFParameters(
                nClusters: 100,
                nProbe: 10
            ))
        )
    )

    var productID: Int64
    var name: String
    var embedding: [Float32]
}
```

**IndexKind Storage**:
```swift
// All IndexKind configurations are stored as JSON
let vectorKind = try IndexKind(
    VectorIndexKind(
        dimensions: 384,
        metric: .cosine,
        algorithm: .hnsw(HNSWParameters.default)
    )
)

// Type-safe decoding
let vector = try vectorKind.decode(VectorIndexKind.self)
print(vector.dimensions)  // 384
print(vector.metric)       // .cosine

switch vector.algorithm {
case .hnsw(let params):
    print("HNSW: m=\(params.m), efConstruction=\(params.efConstruction)")
case .flatScan:
    print("Flat scan")
case .ivf(let params):
    print("IVF: nClusters=\(params.nClusters)")
}
```

### Custom IndexKinds

Extend FDBRuntime with your own IndexKind:

```swift
import FDBIndexing

public struct BloomFilterIndexKind: IndexKindProtocol {
    public static var identifier: String { "bloom_filter" }
    public var falsePositiveRate: Double

    public init(falsePositiveRate: Double = 0.01) {
        self.falsePositiveRate = falsePositiveRate
    }

    public func validate(fields: [String], recordType: Any.Type) throws {
        // Validation logic
    }

    public var subspaceStructure: SubspaceStructure {
        .flat
    }
}

// Use in models
#Index<Product>([\.tags], type: BloomFilterIndexKind())
```

---

## 🌐 Ecosystem & Roadmap

FDBRuntime is the **foundation** for a family of data model layers:

### Current Status

| Layer | Status | Description |
|-------|--------|-------------|
| **fdb-record-layer** | ✅ Production | Structured records (SwiftData-like API) |
| **fdb-indexing** | ✅ Integrated | Now part of fdb-runtime |
| **fdb-swift-bindings** | ✅ Stable | FoundationDB Swift bindings |

### Planned Layers

| Layer | Status | Description |
|-------|--------|-------------|
| **fdb-document-layer** | 🚧 Planned | Flexible document store (MongoDB-like) |
| **fdb-vector-layer** | 🚧 Planned | Vector embeddings (HNSW, FAISS-like) |
| **fdb-graph-layer** | 🚧 Planned | Graph database (Neo4j-like traversals) |
| **fdb-timeseries-layer** | 💡 Concept | Time-series data optimization |

### Integration Example

Multiple data models can coexist on the same FoundationDB cluster:

```swift
import FDBRuntime
import FDBRecordLayer
import FDBDocumentLayer
import FDBVectorLayer

let container = FDBContainer(database: database)

// Structured records
let userStore = try await RecordStore<User>(
    store: container.store(for: "users"),
    schema: userSchema
)

// Flexible documents
let eventStore = try await DocumentStore(
    store: container.store(for: "events")
)

// Vector embeddings
let embeddingStore = try await VectorStore(
    store: container.store(for: "embeddings"),
    dimensions: 768
)

// All share the same FDBStore infrastructure
```

---

## 🔧 Key Design Decisions

### 1. **FDBIndexing Integration (Nov 2025)**

**Previously**: fdb-indexing was a separate package
**Now**: Integrated into fdb-runtime as a module

**Rationale**:
- fdb-indexing had no external dependencies
- Only used by fdb-runtime and its layers
- Simplifies package management for users
- Maintains zero-dependency index metadata abstractions

### 2. **FDBStore as Common Foundation**

**Decision**: All data model layers share a single FDBStore type

**Benefits**:
- No code duplication across layers
- Cross-model transactions are possible
- Consistent storage abstractions
- Easier to maintain and optimize

### 3. **Protocol-Based Architecture**

**Decision**: FDBRuntime provides protocols, not concrete implementations

**Benefits**:
- Each data model layer can optimize for its use case
- No unnecessary coupling between layers
- Easy to add new data models
- Compile-time type safety

---

## 📚 Documentation

- **[Architecture Guide](docs/architecture.md)** - Detailed design decisions
- **[FDBCore API Reference](docs/fdbcore-api.md)** - Client-side API
- **[FDBRuntime API Reference](docs/fdbruntime-api.md)** - Server-side protocols
- **[Built-in IndexKinds](docs/builtin-indexes.md)** - Index type reference
- **[Custom IndexKind Tutorial](docs/custom-indexkind.md)** - Extend with your own

---

## 🤝 Contributing

Contributions are welcome! Areas of interest:

- New built-in IndexKind implementations
- Performance optimizations for FDBStore
- Additional data model layers (document, vector, graph)
- Cross-platform support improvements
- Documentation and examples

---

## 📄 License

MIT License - See [LICENSE](LICENSE) for details

---

## 🔗 Related Projects

- [fdb-swift-bindings](https://github.com/1amageek/fdb-swift-bindings) - FoundationDB Swift bindings
- [fdb-record-layer](https://github.com/1amageek/fdb-record-layer) - Structured record layer
- [FoundationDB](https://www.foundationdb.org/) - Official FoundationDB project

---

**Status**: ✅ **Production Ready** - FDBIndexing integrated, FDBCore stable, FDBRuntime protocols established

**Last Updated**: 2025-11-22

---

## 💡 Philosophy

> "A good runtime makes the simple easy and the complex possible."

FDBRuntime aims to:
- Make **common patterns simple** (built-in indexes, standard CRUD)
- Make **complex patterns possible** (custom indexes, cross-model queries)
- Maintain **flexibility** (protocol-based, extensible)
- Ensure **safety** (type-safe, compile-time checks)
- Support **diversity** (multiple data models on one foundation)

The goal is not to replace specialized databases, but to provide a **unified foundation** where different data models can coexist, interoperate, and leverage shared infrastructure on FoundationDB.
