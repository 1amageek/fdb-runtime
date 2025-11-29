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

FDBRuntime consists of **four modules** with clear responsibilities:

```
┌─────────────────────────────────────────────────────────┐
│                     FDBModel                             │
│  Role: Model definitions and metadata (FDB-independent) │
│  Dependencies: Swift stdlib + Foundation                │
│  Platform: iOS, macOS, Linux (all platforms)            │
│                                                          │
│  ✅ Persistable protocol                                 │
│  ✅ @Persistable macro (FDBModelMacros)                 │
│  ✅ #Index, #Directory macros                           │
│  ✅ IndexKind protocol + StandardIndexKinds             │
│     (Scalar, Count, Sum, Min, Max, Version)             │
│  ✅ IndexDescriptor, CommonIndexOptions                 │
│  ✅ TypeValidation, ULID                                │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                      FDBCore                             │
│  Role: Schema and Serialization (FDB-independent)       │
│  Dependencies: FDBModel                                  │
│  Platform: iOS, macOS, Linux (all platforms)            │
│                                                          │
│  ✅ Schema (entities, versions)                          │
│  ✅ ProtobufEncoder / ProtobufDecoder                   │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                    FDBIndexing                           │
│  Role: Index abstraction layer (FDB-dependent)          │
│  Dependencies: FDBModel + FDBCore + FoundationDB        │
│  Platform: macOS, Linux (server-only)                   │
│                                                          │
│  ✅ IndexMaintainer protocol                             │
│  ✅ IndexKindMaintainable protocol (bridge)             │
│  ✅ DataAccess static utility (not a protocol)          │
│  ✅ KeyExpression, KeyExpressionVisitor                 │
│  ✅ Index, IndexManager, OnlineIndexer                  │
│  Note: IndexMaintainer implementations in fdb-indexes   │
└────────────┬────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────┐
│                    FDBRuntime                            │
│  Role: Store and Container (FDB-dependent)              │
│  Dependencies: FDBModel + FDBCore + FDBIndexing + FDB   │
│  Platform: macOS, Linux (server-only)                   │
│                                                          │
│  ✅ FDBStore (type-independent CRUD operations)         │
│  ✅ FDBContainer (schema management, store lifecycle)   │
│  ✅ FDBContext (change tracking, SwiftData-like API)    │
│  ✅ IDValidation (ID type validation)                   │
└────────────┬────────────────────────────────────────────┘
             │ Data model layers implement protocols
             ├─────────────────┬──────────────┬───────────┐
             ▼                 ▼              ▼           ▼
┌─────────────────┐ ┌─────────────┐ ┌──────────┐ ┌──────────┐
│ fdb-record-layer│ │fdb-document │ │fdb-vector│ │fdb-graph │
│                 │ │   -layer    │ │  -layer  │ │  -layer  │
├─────────────────┤ ├─────────────┤ ├──────────┤ ├──────────┤
│ RecordStore     │ │DocumentStore│ │VectorStore││GraphStore│
│ IndexMaintainer │ │IndexMaint   │ │IndexMaint│ │IndexMaint│
│ QueryPlanner    │ │QueryBuilder │ │NNSearch  │ │Traversal │
└─────────────────┘ └─────────────┘ └──────────┘ └──────────┘
```

### Module Responsibilities

| Module | Responsibility | Platform Support | Dependencies |
|--------|---------------|------------------|--------------|
| **FDBModel** | Model definitions, IndexKind protocol, StandardIndexKinds, ULID | All platforms | None |
| **FDBCore** | Schema, Serialization | All platforms | FDBModel |
| **FDBIndexing** | IndexMaintainer protocol, IndexKindMaintainable protocol, DataAccess utilities | Server-only | FDBModel + FDBCore + FDB |
| **FDBRuntime** | FDBStore, FDBContainer, FDBContext | Server-only | FDBIndexing + FDB |

**Note**: IndexMaintainer implementations (ScalarIndexMaintainer, CountIndexMaintainer, etc.) are provided by **fdb-indexes** package.

---

## 🏗️ Architecture Principles

### 1. **Terminology: "Item" vs "Record"**

FDBRuntime uses precise terminology to clarify abstraction levels:

| Layer | Term | Meaning | Type |
|-------|------|---------|------|
| **FDBRuntime** | **item** | Type-independent data unit | `Data` (raw bytes) |
| **Upper layers** | **record/document/vector** | Type-specific data unit | `Persistable`, `Document`, etc. |

**FDBStore operates on items**:
```swift
// FDBStore API (type-independent)
func save(data: Data, for itemType: String, primaryKey: Tuple, ...) async throws
func load(for itemType: String, primaryKey: Tuple, ...) async throws -> Data?
```

**RecordStore wraps FDBStore with type safety**:
```swift
// RecordStore API (type-safe)
func save(_ record: Record) async throws
func load(primaryKey: Tuple) async throws -> Record?
```

### 2. **Shared FDBStore Across All Models**

Unlike traditional approaches where each data model has its own store, **FDBRuntime uses a single FDBStore** that is shared across all data model layers:

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
// ✅ One FDBStore, multiple typed wrappers
let store = container.store(for: subspace)

// Each layer wraps FDBStore with its own DataAccess implementation
let recordStore = RecordStore<User>(store: store, schema: schema)
let docStore = DocumentStore(store: store)
let vectorStore = VectorStore(store: store, dimensions: 768)
```

### 3. **Protocol-Based Extensibility**

FDBIndexing defines **IndexMaintainer as a protocol** and **DataAccess as a static utility**:

**DataAccess Static Utility**:
```swift
// Static utility (in FDBIndexing) - NOT a protocol
public struct DataAccess: Sendable {
    // All methods are static, work with any Persistable type

    public static func evaluate<Item: Persistable>(
        item: Item,
        expression: KeyExpression
    ) throws -> [any TupleElement]

    public static func extractField<Item: Persistable>(
        from item: Item,
        keyPath: String
    ) throws -> [any TupleElement]

    public static func serialize<Item: Persistable>(_ item: Item) throws -> FDB.Bytes
    public static func deserialize<Item: Persistable>(_ bytes: FDB.Bytes) throws -> Item
}

// Usage in any data model layer:
let values = try DataAccess.extractField(from: user, keyPath: "email")
```

**IndexMaintainer Protocol**:
```swift
// Protocol definition (in FDBIndexing)
public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Item: Persistable

    func updateIndex(oldItem: Item?, newItem: Item?, transaction: any TransactionProtocol) async throws
    func scanItem(_ item: Item, id: Tuple, transaction: any TransactionProtocol) async throws
    var customBuildStrategy: (any IndexBuildStrategy<Item>)? { get }
}

// IndexKindMaintainable bridges IndexKind to IndexMaintainer (in FDBIndexing)
public protocol IndexKindMaintainable: IndexKind {
    func makeIndexMaintainer<Item: Persistable>(...) -> any IndexMaintainer<Item>
}

// Standard implementations (in fdb-indexes package):
ScalarIndexMaintainer<Item: Persistable>   // VALUE indexes
CountIndexMaintainer<Item: Persistable>    // COUNT aggregation
SumIndexMaintainer<Item: Persistable>      // SUM aggregation
MinMaxIndexMaintainer<Item: Persistable>   // MIN/MAX tracking
VersionIndexMaintainer<Item: Persistable>  // Version-based indexes
```

### 4. **Platform Separation**

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
import FDBModel

// Define model (SSOT)
@Persistable
struct User {
    // id is auto-generated as ULID or explicitly defined
    var id: String = ULID().ulidString

    var email: String
    var name: String
}

// Use with JSON API
let user = User(email: "test@example.com", name: "Alice")
let jsonData = try JSONEncoder().encode(user)

// SwiftUI
List(users, id: \.id) { user in
    Text(user.name)
}
```

**Server-side**:
```swift
import FDBModel     // Model definitions
import FDBRuntime   // FDBStore, protocols
import FDBRecordLayer  // Type-safe extensions (upper layer)

// Define model with indexes
@Persistable
struct User {
    // id is auto-generated as ULID
    var id: String = ULID().ulidString

    #Index<User>([\.email], type: ScalarIndexKind(), unique: true)

    var email: String
    var name: String
}

// FDBStore operates on type-independent items (Data)
let container = FDBContainer(database: database)
let subspace = try await container.getOrOpenDirectory(path: ["users"])
let store = container.store(for: subspace)

// RecordStore provides type-safe wrapper
let recordStore = RecordStore<User>(store: store, schema: schema)
try await recordStore.save(user)
```

---

## ⚠️ Important Operational Considerations

### Index Registration Persistence

**Critical**: Index definitions are stored **in-memory only** and are **NOT persisted** to FoundationDB.

**Implications**:
- ✅ **Application Startup**: You **MUST** re-register all indexes on each process start
- ✅ **Multiple Instances**: Each process instance must register the same set of indexes
- ✅ **Schema Management**: Upper layers (fdb-record-layer) are responsible for persisting schema metadata

**Bootstrap Pattern**:
```swift
// 1. Load schema from FDB (upper layer responsibility)
let schema = try await loadPersistedSchema(from: database)

// 2. Register all indexes from schema on EVERY startup
let indexManager = IndexManager(database: database, subspace: indexSubspace)
for indexDescriptor in schema.indexes {
    let index = try Index(from: indexDescriptor, recordType: recordType)
    try indexManager.register(index: index)
}

// 3. Now ready for operations
let state = try await indexManager.state(of: "user_by_email")
```

**Multi-Process Coordination**:
- All processes **must** register identical index sets
- Index state (DISABLED/WRITE_ONLY/READABLE) **is** persisted in FDB
- Schema versioning should be handled by upper layers

**Why This Design?**:
- ✅ Separation of concerns: FDBRuntime handles runtime, upper layers handle schema persistence
- ✅ Flexibility: Different deployment strategies for schema management
- ✅ Performance: No schema lookup overhead on every operation

See `IndexManager` documentation in `Sources/FDBRuntime/IndexManager.swift` for details.

---

## 📊 Built-in Index Types

FDBModel module provides **protocol-based extensible index system** with built-in IndexKind definitions.
IndexMaintainer implementations are provided by **fdb-indexes** package:

| IndexKind | Identifier | Use Case | Complexity |
|-----------|-----------|----------|------------|
| **ScalarIndexKind** | `"scalar"` | Standard B-tree index, range queries | O(log n) |
| **CountIndexKind** | `"count"` | Count records per group | O(1) update |
| **SumIndexKind** | `"sum"` | Sum numeric fields per group | O(1) update |
| **MinIndexKind** | `"min"` | Track minimum value per group | O(log n) |
| **MaxIndexKind** | `"max"` | Track maximum value per group | O(log n) |
| **VersionIndexKind** | `"version"` | Optimistic concurrency control | O(1) |
| **VectorIndexKind** | `"vector"` | Vector search (HNSW/IVF/Flat) | O(log n) / O(n) |

### IndexKind Design

All index kinds implement `IndexKind`, enabling type-safe extensibility:

```swift
public protocol IndexKind: Sendable, Codable, Hashable {
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
import FDBModel  // Persistable, IndexKind, StandardIndexKinds

@Persistable
struct Product {
    var id: Int64  // Explicit Int64 ID

    // Scalar indexes
    #Index<Product>([\.category], type: ScalarIndexKind())
    #Index<Product>([\.category], type: CountIndexKind())
    #Index<Product>([\.category, \.price], type: SumIndexKind())
    #Index<Product>([\.category, \.price], type: MinIndexKind())
    #Index<Product>([\.category, \.price], type: MaxIndexKind())

    var category: String
    var price: Double
}
```

**Vector Indexes** (planned for fdb-indexes package):
```swift
@Persistable
struct Product {
    var id: Int64

    // Note: VectorIndexKind will be provided by fdb-indexes package
    // Example syntax (not yet implemented):
    #Index<Product>([\.embedding], type: VectorIndexKind(dimensions: 384))

    var name: String
    var embedding: [Float32]
}
```

### Custom IndexKinds

Extend FDBModel with your own IndexKind:

```swift
import FDBModel

public struct BloomFilterIndexKind: IndexKind {
    public static let identifier = "bloom_filter"
    public static let subspaceStructure = SubspaceStructure.flat

    public var falsePositiveRate: Double

    public init(falsePositiveRate: Double = 0.01) {
        self.falsePositiveRate = falsePositiveRate
    }

    public static func validateTypes(_ types: [Any.Type]) throws {
        // Validation logic
    }
}

// Use in models
@Persistable
struct Product {
    var id: String = ULID().ulidString

    #Index<Product>([\.tags], type: BloomFilterIndexKind())

    var tags: [String]
}
```

---

## 🌐 Ecosystem & Roadmap

FDBRuntime is the **foundation** for a family of data model layers:

### Current Status

| Layer | Status | Description |
|-------|--------|-------------|
| **fdb-indexes** | ✅ Production | IndexMaintainer implementations (Scalar, Count, Sum, Min, Max, Version) |
| **fdb-record-layer** | ✅ Production | Structured records (SwiftData-like API) |
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

// All layers share the same FDBStore infrastructure
let userStore = try await RecordStore<User>(
    store: container.store(for: "users"),
    schema: userSchema
)

let eventStore = try await DocumentStore(
    store: container.store(for: "events")
)

let embeddingStore = try await VectorStore(
    store: container.store(for: "embeddings"),
    dimensions: 768
)
```

---

## 🔧 Key Design Decisions

### 1. **IndexMaintainer Implementation Separation (Nov 2025)**

**Design**: IndexMaintainer protocol is in fdb-runtime/FDBIndexing, implementations are in fdb-indexes package

**Rationale**:
- Clean separation between protocol definition and implementation
- fdb-runtime provides abstractions (IndexMaintainer, IndexKindMaintainable protocols)
- fdb-indexes provides concrete implementations (ScalarIndexMaintainer, CountIndexMaintainer, etc.)
- Third parties can provide custom implementations without modifying fdb-runtime

### 2. **FDBStore as Common Foundation**

**Decision**: All data model layers share a single FDBStore type

**Benefits**:
- No code duplication across layers
- Cross-model transactions are possible
- Consistent storage abstractions
- Easier to maintain and optimize

### 3. **Protocol-Based Architecture**

**Decision**: FDBIndexing provides protocols (IndexMaintainer, IndexKindMaintainable), fdb-indexes provides implementations

**Benefits**:
- Each data model layer can optimize for its use case
- No unnecessary coupling between layers
- Easy to add new data models
- Compile-time type safety
- Standard implementations available via fdb-indexes package

### 4. **Terminology Precision**

**Decision**: Use "item" in FDBRuntime, "record/document/vector" in upper layers

**Benefits**:
- Clarifies type-independent vs type-dependent layers
- Reduces confusion about abstraction levels
- Consistent with other storage systems terminology

---

## 📚 Documentation

- **[Architecture Guide](docs/architecture.md)** - Detailed design decisions (日本語)
- **[Design Decisions](docs/SIMPLIFIED_DESIGN.md)** - Key design decisions and migration notes
- **[ID Design](docs/ID-DESIGN.md)** - ID management design
- **[Container Configuration](docs/CONTAINER-CONFIGURATION-DESIGN.md)** - FDBContainer/FDBConfiguration design

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

- [fdb-indexes](https://github.com/1amageek/fdb-indexes) - IndexMaintainer implementations (Scalar, Count, Sum, Min, Max, Version)
- [fdb-swift-bindings](https://github.com/1amageek/fdb-swift-bindings) - FoundationDB Swift bindings
- [fdb-record-layer](https://github.com/1amageek/fdb-record-layer) - Structured record layer
- [FoundationDB](https://www.foundationdb.org/) - Official FoundationDB project

---

**Status**: ✅ **Production Ready** - 4-module architecture (FDBModel → FDBCore → FDBIndexing → FDBRuntime), IndexMaintainer protocol established, DataAccess utilities implemented. IndexMaintainer implementations in fdb-indexes package.

**Last Updated**: 2025-11-29

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
