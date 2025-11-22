# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**fdb-runtime** is a Swift package that provides a runtime foundation for data persistence and management on FoundationDB. It consists of three modules in a layered architecture:

1. **FDBIndexing** - Index metadata definitions (protocols only, platform-independent)
2. **FDBCore** - FDB-independent core functionality (Server-Client共通, all platforms)
3. **FDBRuntime** - FDB-dependent runtime layer (Server専用, macOS/Linux only)

This is a foundational package designed to support multiple data model layers (Record, Document, Vector, Graph) built on top of it.

## Build and Test Commands

### Building the Project
```bash
# Build all targets
swift build

# Build specific products
swift build --product FDBIndexing
swift build --product FDBCore
swift build --product FDBRuntime
```

### Running Tests
```bash
# Run all tests
swift test

# Run specific test targets
swift test --filter FDBIndexingTests
swift test --filter FDBCoreTests
swift test --filter FDBRuntimeTests

# Run a single test
swift test --filter FDBCoreTests.RecordableTests
```

**Note**: FDBRuntimeTests requires FoundationDB to be installed and running locally at `/usr/local/lib`.

### Clean Build
```bash
# Clean build artifacts
swift package clean

# Reset package (removes .build and Package.resolved)
swift package reset
```

## FoundationDB Fundamentals

### What is FoundationDB?

FoundationDB is a distributed, transactional key-value store designed for large-scale, mission-critical workloads with strong consistency guarantees. It provides a simple key-value interface upon which various database models (document, relational, graph) can be built.

**Core Philosophy**: Separation of concerns into distinct layers:
- Transaction processing (coordination)
- Storage management (data persistence)
- Cluster coordination (failure detection and recovery)

This architecture enables high performance, fault tolerance, and scalability while maintaining ACID transaction guarantees across the entire database.

### ACID Transaction Model

FoundationDB implements full ACID semantics:

- **Atomicity**: All changes in a transaction commit together or none do
- **Consistency**: Database always transitions between valid states
- **Isolation**: Transactions use snapshot isolation (serializable)
- **Durability**: Committed changes are permanently persisted to disk

**Optimistic Concurrency Control**: Transactions proceed without locking, then check for conflicts at commit time. If conflicts exist, the transaction fails and must be retried.

**Read-Your-Writes Semantics**: Reads within a transaction see the transaction's own uncommitted writes, enabling consistent transaction logic without explicit read-after-write handling.

### Transaction Lifecycle

1. **Read Version Acquisition**: Client obtains a read version from GRV Proxies
2. **Data Operations**: Client reads from Storage Servers, accumulates writes in memory
3. **Commit Processing**: Commit Proxy checks conflicts, gets commit version, logs to TLogs
4. **Persistence**: Storage Servers apply changes to versioned storage

### Key-Value Data Model

- **Keys**: Byte strings (typically tuple-encoded for ordering)
- **Values**: Byte strings (opaque to FoundationDB)
- **Versioning**: Linear versioning system maintains multiple versions for snapshot isolation
- **Ordering**: Keys are ordered lexicographically

**Version Types**:
- **Read Version**: Snapshot timestamp for transaction reads
- **Commit Version**: When transaction changes become visible
- **Durable Version**: Data guaranteed persisted to disk
- **Popped Version**: Old data eligible for garbage collection

### Distributed Architecture Components

- **Cluster Controller**: Central coordinator, monitors and recruits processes
- **Master Server**: Provides versioning and sequencing, coordinates recovery
- **GRV Proxies**: Handle read version requests with batching and rate limiting
- **Commit Proxies**: Process transaction commits and detect conflicts
- **Storage Servers**: Store and serve data with versioning for snapshot isolation
- **TLog Servers**: Ensure durability by maintaining transaction history

### Fault Tolerance

- **Failure Detection**: Cluster Controller monitors process health
- **Automatic Recovery**: Failed processes replaced automatically
- **Data Rebuilding**: DataDistributor restores redundancy
- **Multi-Datacenter Support**: Teams formed across failure domains
- Typical replication: 3 copies per shard across different failure domains

## Using fdb-swift-bindings

### Initialization

```swift
import FoundationDB

// Initialize FoundationDB client (call once at app startup)
try await FDBClient.initialize()

// Open database connection
let database = try FDBClient.openDatabase()
```

### Transaction Pattern

All database operations in FoundationDB must occur within a transaction:

```swift
// Using withTransaction for automatic retry logic
try await database.withTransaction { transaction in
    // All operations here are atomic
    // Transaction automatically retries on conflicts

    return result
}
```

### Basic Key-Value Operations

```swift
try await database.withTransaction { transaction in
    // Set a value
    let key = [UInt8]("user:123".utf8)
    let value = [UInt8]("Alice".utf8)
    transaction.setValue(value, for: key)

    // Get a value
    if let bytes = try await transaction.getValue(for: key, snapshot: false) {
        let name = String(decoding: bytes, as: UTF8.self)
    }

    // Delete a key
    transaction.clear(key: key)

    // Clear a range
    transaction.clearRange(
        beginKey: [UInt8]("user:".utf8),
        endKey: [UInt8]("user;".utf8)
    )
}
```

### Tuples for Key Encoding

Tuples provide ordered, type-safe key encoding that preserves lexicographic ordering:

```swift
import FoundationDB

// Create tuples
let tuple1 = Tuple("users", 123, "profile")
let tuple2 = Tuple([anyTupleElement1, anyTupleElement2])

// Pack to bytes (for use as keys)
let key = tuple1.pack()  // Returns [UInt8]

// Unpack from bytes
let elements = try Tuple.unpack(from: key)
let restored = Tuple(elements)

// Supported types (all conform to TupleElement):
// - String, Int64, Int32, Int16, Int8, Int
// - UInt64, UInt32, UInt16, UInt8, UInt
// - Float, Double
// - Bool
// - UUID
// - Data/[UInt8]
// - Nested Tuple
// - Versionstamp
```

**Tuple Ordering**: Tuple encoding preserves lexicographic ordering, making tuples ideal for:
- Composite keys
- Range queries
- Hierarchical data organization

### Subspaces for Key Partitioning

Subspaces partition the key space into logical regions (like tables in SQL):

```swift
// Create subspace with tuple-encoded prefix
let userSpace = Subspace(prefix: Tuple("users").pack())

// Create nested subspaces
let activeUsers = userSpace.subspace("active")
let userById = activeUsers.subspace(12345)

// Pack keys with subspace prefix
let key = userSpace.pack(Tuple(123, "email"))

// Unpack keys (removes prefix)
let tuple = try userSpace.unpack(key)

// Check if key belongs to subspace
if userSpace.contains(key) {
    // Process key
}

// Get range for scanning all keys in subspace
let (begin, end) = userSpace.range()
```

**Important**: Use tuple-encoded prefixes via `subspace(_:)` for correct range queries. Raw binary prefixes may have limitations with keys ending in 0xFF bytes.

### Range Queries

Efficiently stream large result sets:

```swift
try await database.withTransaction { transaction in
    // Scan all users
    let userSpace = Subspace(prefix: Tuple("users").pack())
    let (begin, end) = userSpace.range()

    let sequence = transaction.getRange(
        beginSelector: .firstGreaterOrEqual(begin),
        endSelector: .firstGreaterOrEqual(end),
        snapshot: false
    )

    for try await (key, value) in sequence {
        // Process each key-value pair as it streams
        let tuple = try userSpace.unpack(key)
        // Extract user data...
    }
}
```

**Key Selectors**: Control range boundaries precisely:
- `.firstGreaterOrEqual(key)` - Start at key (inclusive)
- `.firstGreaterThan(key)` - Start after key (exclusive)
- `.lastLessOrEqual(key)` - End at key (inclusive)
- `.lastLessThan(key)` - End before key (exclusive)

### Atomic Operations

Perform atomic mutations without explicit read-modify-write:

```swift
try await database.withTransaction { transaction in
    let counterKey = Tuple("counter", "pageviews").pack()

    // Atomic increment (no read required)
    let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
    transaction.atomicOp(key: counterKey, param: increment, mutationType: .add)
}
```

**Common Atomic Operations**:
- `.add` - Add to integer
- `.bitwiseAnd` / `.bitwiseOr` / `.bitwiseXor` - Bitwise operations
- `.max` / `.min` - Update if new value is greater/less
- `.append` / `.appendIfFits` - Append bytes to value
- `.versionstampedKey` / `.versionstampedValue` - Set with transaction version

### Directory Layer

The Directory Layer manages namespaces and prevents key prefix collisions:

```swift
// Create DirectoryLayer (typically via FDBContainer)
let directoryLayer = database.makeDirectoryLayer()

// Create or open directory
let userDir = try await directoryLayer.createOrOpen(path: ["app", "users"])
let subspace = userDir.subspace  // Get Subspace for this directory

// Directory operations
let dir = try await directoryLayer.create(path: ["app", "posts"])
let existing = try await directoryLayer.open(path: ["app", "users"])
let moved = try await directoryLayer.move(oldPath: ["app", "temp"], newPath: ["app", "archive"])
try await directoryLayer.remove(path: ["app", "old"])
let exists = try await directoryLayer.exists(path: ["app", "users"])
```

**Benefits**:
- Automatic prefix allocation (prevents collisions)
- Human-readable paths
- Efficient prefix management
- Safe directory removal (clears all data in directory)

### Transaction Options

Configure transaction behavior:

```swift
let transaction = try database.createTransaction()

// Timeout (milliseconds)
try transaction.setOption(to: nil, forOption: .timeout(5000))

// Retry limit
try transaction.setOption(to: nil, forOption: .retryLimit(100))

// Read-only hint (optimization)
try transaction.setOption(to: nil, forOption: .readYourWritesDisable)

// Snapshot reads (don't cause conflicts)
let value = try await transaction.getValue(for: key, snapshot: true)
```

### Best Practices for This Project

1. **Always Use Transactions**: Never perform operations outside `withTransaction` - it handles retries automatically

2. **Use Tuples for Keys**: Tuple encoding preserves ordering and is type-safe:
   ```swift
   let key = Tuple("User", userID, "email").pack()  // ✅ Good
   let key = "User:\(userID):email".data(using: .utf8)  // ❌ Avoid
   ```

3. **Use Subspaces for Organization**: Partition data logically:
   ```swift
   let recordSpace = subspace.subspace("R")  // Records
   let indexSpace = subspace.subspace("I")   // Indexes
   ```

4. **Leverage Directory Layer**: Use FDBContainer's directory operations for namespace management

5. **Keep Transactions Small**: Large transactions increase conflict probability
   - Aim for < 10 MB of data per transaction
   - Avoid long-running transactions (> 5 seconds)

6. **Use Snapshot Reads**: For reads that don't need conflict detection:
   ```swift
   let value = try await transaction.getValue(for: key, snapshot: true)
   ```

7. **Batch Operations**: Use range queries instead of individual gets:
   ```swift
   // ✅ Efficient
   for try await (key, value) in transaction.getRange(...) { }

   // ❌ Inefficient
   for id in ids {
       let value = try await transaction.getValue(for: makeKey(id))
   }
   ```

8. **Handle Errors Properly**: `withTransaction` automatically retries on conflicts, but you should handle other errors:
   ```swift
   do {
       try await database.withTransaction { transaction in
           // Operations...
       }
   } catch let error as FDBError {
       // Handle FDB-specific errors
   }
   ```

## Architecture and Design Principles

### Layered Architecture

The codebase follows a strict layered architecture where each layer has clear responsibilities:

```
FDBIndexing (metadata protocols)
    ↓
FDBCore (FDB-independent, all platforms)
    ↓
FDBRuntime (FDB-dependent protocols + common implementations)
    ↓
Upper layers (fdb-record-layer, fdb-document-layer, etc.)
```

### IndexKindProtocol-Based Extensibility

**Status**: ✅ Fully implemented in FDBIndexing module

FDBIndexing provides a **protocol-based extensible index system** that allows third parties to add custom index types without modifying the core framework.

#### Core Design

**IndexKindProtocol**:
```swift
// FDBIndexing/IndexKindProtocol.swift

/// Defines the interface for index kinds
public protocol IndexKindProtocol: Sendable, Codable, Hashable {
    /// Unique identifier (e.g., "scalar", "vector", "com.mycompany.custom")
    static var identifier: String { get }

    /// Subspace structure type
    static var subspaceStructure: SubspaceStructure { get }

    /// Validate whether this index kind supports specified types
    static func validateTypes(_ types: [Any.Type]) throws
}

/// Subspace structure types
public enum SubspaceStructure: String, Sendable, Codable {
    /// Flat structure: [value][pk] = ''
    case flat

    /// Hierarchical structure: HNSW graphs, etc.
    case hierarchical

    /// Aggregated values stored directly: COUNT, SUM
    case aggregation
}
```

**IndexKind Type-Erased Wrapper**:
```swift
// FDBIndexing/IndexKind.swift

/// Type-erased wrapper for IndexKindProtocol implementations
public struct IndexKind: Sendable, Codable, Hashable {
    /// Index kind identifier
    public let identifier: String

    /// JSON-encoded configuration data
    public let configuration: Data

    /// Type-safe initialization
    public init<Kind: IndexKindProtocol>(_ kind: Kind) throws {
        self.identifier = Kind.identifier
        self.configuration = try JSONEncoder().encode(kind)
    }

    /// Type-safe decoding
    public func decode<Kind: IndexKindProtocol>(_ type: Kind.Type) throws -> Kind {
        guard identifier == Kind.identifier else {
            throw IndexKindError.typeMismatch(
                expected: Kind.identifier,
                actual: identifier
            )
        }
        return try JSONDecoder().decode(type, from: configuration)
    }
}
```

#### Built-in Index Kinds

**ScalarIndexKind** (VALUE index):
```swift
public struct ScalarIndexKind: IndexKindProtocol {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        // Validate all fields are Comparable
    }

    public init() {}
}
```

**VectorIndexKind** (Vector search with HNSW/IVF):
```swift
public struct VectorIndexKind: IndexKindProtocol {
    public static let identifier = "vector"
    public static let subspaceStructure = SubspaceStructure.hierarchical

    public let dimensions: Int
    public let metric: VectorMetric
    public let algorithm: VectorAlgorithm

    public init(
        dimensions: Int,
        metric: VectorMetric = .cosine,
        algorithm: VectorAlgorithm = .flatScan
    ) {
        self.dimensions = dimensions
        self.metric = metric
        self.algorithm = algorithm
    }

    public static func validateTypes(_ types: [Any.Type]) throws {
        // Validate single array field ([Float32], [Float], [Double])
    }
}

public enum VectorAlgorithm: Sendable, Codable, Hashable {
    case flatScan
    case hnsw(HNSWParameters)
    case ivf(IVFParameters)
}
```

#### Usage Example

**Model definition**:
```swift
@Model
struct Product {
    #PrimaryKey<Product>([\.productID])

    // Scalar index
    #Index<Product>([\.category], type: ScalarIndexKind())

    // Vector index with HNSW
    #Index<Product>(
        [\.embedding],
        type: VectorIndexKind(
            dimensions: 384,
            metric: .cosine,
            algorithm: .hnsw(HNSWParameters(m: 16, efConstruction: 200))
        )
    )

    var productID: Int64
    var category: String
    var embedding: [Float32]
}
```

**IndexKind encoding/decoding**:
```swift
// Encoding
let vectorKind = try IndexKind(
    VectorIndexKind(
        dimensions: 384,
        metric: .cosine,
        algorithm: .hnsw(HNSWParameters.default)
    )
)

// Stored as JSON in IndexDescriptor
let descriptor = IndexDescriptor(
    name: "Product_embedding",
    keyPaths: ["embedding"],
    kind: vectorKind,
    commonOptions: .init()
)

// Decoding
let vector = try descriptor.kind.decode(VectorIndexKind.self)
print(vector.dimensions)  // 384
print(vector.metric)       // .cosine

switch vector.algorithm {
case .hnsw(let params):
    print("HNSW: m=\(params.m)")
case .flatScan:
    print("Flat scan")
}
```

#### Benefits of Protocol-Based Design

| Benefit | Description |
|---------|-------------|
| **Protocol-Based** | Implement IndexKindProtocol to add new index types |
| **Type-Safe** | decode() provides type-safe reconstruction |
| **Codable** | All parameters stored as JSON |
| **Third-Party Extension** | Add custom indexes without modifying FDBIndexing |
| **Validation** | validateTypes() enforces type constraints |
| **Explicit Structure** | SubspaceStructure defines index organization |

#### Implementation Selection in FDBRuntime

Upper layers (e.g., fdb-record-layer) use the identifier to dispatch to appropriate implementations:

```swift
// IndexManager implementation selection
switch index.kind.identifier {
case "scalar":
    let scalar = try index.kind.decode(ScalarIndexKind.self)
    return ScalarIndexMaintainer(...)

case "vector":
    let vector = try index.kind.decode(VectorIndexKind.self)

    switch vector.algorithm {
    case .hnsw(let params):
        return HNSWIndexMaintainer(
            dimensions: vector.dimensions,
            metric: vector.metric,
            params: params,
            ...
        )
    case .flatScan:
        return FlatVectorIndexMaintainer(...)
    }

default:
    throw IndexError.unknownKind(index.kind.identifier)
}
```

---

### Key Design Decisions

1. **FDBStore is Type-Independent and Shared Across All Layers**
   - `FDBStore` operates on `Data` (serialized bytes), not typed items
   - All data model layers (Record, Document, Vector, Graph) reuse the same `FDBStore`
   - Upper layers add type-safety through wrappers (e.g., `RecordStore<Record>` in fdb-record-layer)
   - Location: `Sources/FDBRuntime/FDBStore.swift`

2. **Protocol-Based Design in FDBRuntime**
   - `IndexMaintainer<Record>` protocol - defines interface for index maintenance
   - `DataAccess<Item>` protocol - defines interface for item field access
   - Concrete implementations are in upper layers (e.g., fdb-record-layer)
   - This allows different data models to provide their own implementations

3. **Separation of Concerns**
   - **FDBIndexing**: Only metadata (IndexKindProtocol, IndexDescriptor) - no FDB dependency
   - **FDBCore**: Recordable protocol + @Recordable macro - FDB-independent, works on iOS/macOS clients
   - **FDBRuntime**: Store management (FDBStore, FDBContainer), protocols (IndexMaintainer, DataAccess), built-in IndexKinds

4. **Macro-Generated Code**
   - The `@Recordable` macro generates metadata (recordName, primaryKeyFields, indexDescriptors)
   - `#PrimaryKey<T>`, `#Index<T>`, `#Directory` macros provide declarative definitions
   - Macro implementation: `Sources/FDBCoreMacros/RecordableMacro.swift`

5. **Terminology: "Item" vs "Record"**
   - **FDBRuntime layer** (FDBStore, FDBContext, FDBContainer): Uses **"item"** terminology
     - Type-independent, works with raw `Data`
     - Parameters: `itemType`, `itemSubspace`, `insertedItems`, `deletedItems`
     - Reason: Avoids confusion with typed "Record" models in upper layers
   - **Upper layers** (fdb-record-layer, protocols): Uses **"record"** terminology
     - Type-dependent, works with `Recordable` protocol
     - Parameters: `recordName`, `Record` generic type, `DataAccess`, `IndexMaintainer<Record>`
     - Reason: Domain language for typed data models
   - **Backward compatibility**: Subspace prefix remains "R" (not changed to "I" for items)

### Key Components

#### FDBStore (Sources/FDBRuntime/FDBStore.swift)
- Type-independent data store operating on `Data`
- Manages two subspaces: `itemSubspace` (R/) and `indexSubspace` (I/)
- Provides basic CRUD: `save()`, `load()`, `delete()`, `scan()`, `clear()`
- All methods accept `itemType` parameter (e.g., "User", "Product")
- Both transaction-aware and standalone methods
- **Not responsible for**: Index updates (delegated to IndexManager), type safety (added by upper layers), query execution (handled by upper layers)

#### FDBContainer (Sources/FDBRuntime/FDBContainer.swift)
- Manages FDBStore lifecycle (creation and caching)
- Handles DirectoryLayer singleton
- Provides directory operations: `getOrOpenDirectory()`, `createDirectory()`, `openDirectory()`, `moveDirectory()`, `removeDirectory()`
- Caches FDBStore instances by subspace prefix

#### IndexMaintainer Protocol (Sources/FDBRuntime/IndexMaintainer.swift)
- Protocol definition only (implementations in upper layers)
- Key methods:
  - `updateIndex(oldRecord:newRecord:dataAccess:transaction:)` - called on insert/update/delete
  - `scanRecord(_:primaryKey:dataAccess:transaction:)` - called during batch indexing

#### DataAccess Protocol (Sources/FDBRuntime/DataAccess.swift)
- Protocol for extracting metadata and field values from items
- Key methods:
  - `itemType(for:)` - get item type name
  - `evaluate(item:expression:)` - evaluate KeyExpression (uses Visitor pattern)
  - `extractField(from:fieldName:)` - extract single field value
  - `serialize(_:)` / `deserialize(_:)` - item serialization
- Default implementations provided via protocol extensions
- Supports covering index reconstruction (optional via `supportsReconstruction`)
- **Note**: Upper layers (fdb-record-layer) implement DataAccess for their typed models (e.g., Recordable)
- **Backward compatibility**: `RecordAccess<Record>` typealias available for existing code

#### Recordable Protocol (Sources/FDBCore/Recordable.swift)
- FDB-independent interface for records
- Generated by `@Recordable` macro
- Provides metadata: `recordName`, `primaryKeyFields`, `allFields`, `indexDescriptors`
- Conforms to `Sendable` and `Codable`

### Data Flow

**Save Operation**:
```
User Code → RecordStore (upper layer)
  → serialize record
  → FDBStore.save(data, itemType, primaryKey, transaction)
    → store in itemSubspace: [R]/[itemType]/[primaryKey]
  → IndexMaintainer.updateIndex() (via IndexManager in upper layer)
    → update entries in indexSubspace: [I]/[indexName]/...
```

**Load Operation**:
```
User Code → RecordStore (upper layer)
  → FDBStore.load(itemType, primaryKey, transaction)
    → fetch from itemSubspace: [R]/[itemType]/[primaryKey]
  → deserialize data to record
  → return record
```

### Subspace Structure

All data is organized under a root subspace with two main sections:
- **R/** - Item storage: `[subspace]/R/[itemType]/[primaryKey] = data`
- **I/** - Index storage: `[subspace]/I/[indexName]/... = ''`

**Note**: The subspace prefix "R" is kept for backward compatibility, even though the terminology changed from "record" to "item".

### Platform Considerations

- **FDBIndexing**: All platforms (iOS, macOS, Linux, tvOS, watchOS, visionOS)
- **FDBCore**: All platforms (FDB-independent)
- **FDBRuntime**: macOS, Linux only (requires FoundationDB bindings)
- Swift 6 language mode enabled for all targets

## Testing Notes

### Test Structure
- `Tests/FDBIndexingTests/` - Index metadata tests
- `Tests/FDBCoreTests/` - Recordable protocol and macro tests
- `Tests/FDBRuntimeTests/` - FDBStore, IndexState, KeyExpression tests

### FDBRuntime Test Requirements
FDBRuntimeTests requires:
1. FoundationDB installed locally
2. FoundationDB server running
3. Library path configured: `/usr/local/lib`

The linker settings in Package.swift:
```swift
linkerSettings: [
    .unsafeFlags(["-L/usr/local/lib"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
]
```

## Dependencies

- **fdb-swift-bindings** (local path: `../fdb-swift-bindings`) - FoundationDB Swift bindings
- **swift-syntax** - For @Recordable macro implementation
- **swift-log** - Logging support for FDBRuntime

## Related Projects

This package is part of a larger ecosystem:
- **fdb-indexing** - Index metadata abstraction (dependency of FDBCore)
- **fdb-swift-bindings** - FoundationDB Swift bindings (dependency of FDBRuntime)
- **fdb-record-layer** - Structured record layer (builds on top of this package)

## Important File Locations

- Core protocols: `Sources/FDBCore/Recordable.swift`
- Macro implementation: `Sources/FDBCoreMacros/RecordableMacro.swift`
- Store implementation: `Sources/FDBRuntime/FDBStore.swift`
- Container: `Sources/FDBRuntime/FDBContainer.swift`
- Protocol definitions: `Sources/FDBRuntime/IndexMaintainer.swift`, `Sources/FDBRuntime/DataAccess.swift`
- Architecture documentation: `docs/architecture.md`
