# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**fdb-runtime** is a Swift package that provides a runtime foundation for data persistence and management on FoundationDB. It consists of three modules in a layered architecture:

1. **FDBIndexing** - Index abstraction layer (protocols and types, FoundationDB-dependent, Server専用)
2. **FDBCore** - FDB-independent core functionality (model definitions only, 現在はServer専用だがFDB非依存のため将来的に全プラットフォーム対応可能)
3. **FDBRuntime** - FDB-dependent runtime layer (Store implementation, Server専用, macOS/Linux only)

This is a foundational package designed to support **multiple data model layers** (Record, Document, Vector, Graph) built on top of it. The key design principle is that **a single FDBStore handles multiple data models simultaneously** through the LayerConfiguration abstraction.

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

**Note**: All test targets (FDBIndexingTests, FDBCoreTests, FDBRuntimeTests) require FoundationDB to be installed locally with `libfdb_c.dylib` available at `/usr/local/lib`. This is because:
- FDBIndexingTests and FDBRuntimeTests directly depend on FoundationDB
- FDBCoreTests depends on FDBIndexing, which transitively requires FoundationDB

The linker settings in Package.swift configure the rpath to `/usr/local/lib` for all test targets.

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

### IndexKind-Based Extensibility

**Status**: ✅ Fully implemented in FDBIndexing module

FDBIndexing provides a **protocol-based extensible index system** that allows third parties to add custom index types without modifying the core framework.

#### Core Design

**IndexKind Protocol**:
```swift
// FDBIndexing/IndexKind.swift

/// Defines the interface for index kinds
public protocol IndexKind: Sendable, Codable, Hashable {
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

**IndexDescriptor Design**:
```swift
// FDBIndexing/IndexDescriptor.swift

/// Index metadata descriptor (uses existential type)
public struct IndexDescriptor: Sendable {
    public let name: String
    public let keyPaths: [String]
    public let kind: any IndexKind  // Using 'any' for protocol type
    public let commonOptions: CommonIndexOptions

    public init(
        name: String,
        keyPaths: [String],
        kind: any IndexKind,
        commonOptions: CommonIndexOptions = .init()
    ) {
        self.name = name
        self.keyPaths = keyPaths
        self.kind = kind
        self.commonOptions = commonOptions
    }
}
```

**Design Note**: We use `any IndexKind` directly instead of a type-erased wrapper. This is simpler and more idiomatic in Swift 6, but means:
- ✅ Cleaner API - no wrapper type needed
- ✅ Direct protocol usage
- ❌ IndexDescriptor is not Codable (can't encode `any Protocol`)
- ❌ IndexDescriptor is not Hashable/Equatable

For serialization needs, use IndexDescriptor (metadata only, Codable) separately from runtime Index types.

#### Built-in Index Kinds

**ScalarIndexKind** (VALUE index):
```swift
public struct ScalarIndexKind: IndexKind {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        // Validate all fields are Comparable
    }

    public init() {}
}
```

**CountIndexKind** (Aggregation index):
```swift
public struct CountIndexKind: IndexKind {
    public static let identifier = "count"
    public static let subspaceStructure = SubspaceStructure.aggregation

    public static func validateTypes(_ types: [Any.Type]) throws {
        // Validate grouping fields are Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(...)
            }
        }
    }

    public init() {}
}
```

**Other Built-in IndexKinds**:
- `SumIndexKind` - Sum aggregation (identifier: "sum")
- `MinIndexKind` - Minimum value (identifier: "min")
- `MaxIndexKind` - Maximum value (identifier: "max")
- `VersionIndexKind` - Version tracking (identifier: "version")

**Note**: VectorIndexKind for vector search (HNSW/IVF) will be implemented in a separate package (fdb-indexes).

#### Usage Example

**Model definition**:
```swift
@Persistable
struct User {
    #PrimaryKey<User>([\.userID])

    // Scalar index on email (unique)
    #Index<User>([\.email], type: ScalarIndexKind(), unique: true)

    // Count index by city
    #Index<User>([\.city], type: CountIndexKind())

    var userID: Int64
    var email: String
    var city: String
    var name: String
}
```

**IndexDescriptor usage with existential types**:
```swift
// Create IndexDescriptor with concrete IndexKind
let scalarKind = ScalarIndexKind()

let descriptor = IndexDescriptor(
    name: "User_email",
    keyPaths: ["email"],
    kind: scalarKind,  // Automatically converted to 'any IndexKind'
    commonOptions: .init(unique: true)
)

// Access static properties via type(of:)
let identifier = type(of: descriptor.kind).identifier  // "scalar"
let structure = type(of: descriptor.kind).subspaceStructure  // .flat

// Type casting to concrete type when needed
if let scalar = descriptor.kind as? ScalarIndexKind {
    print("This is a scalar index")
}

// Example with CountIndexKind
let countKind = CountIndexKind()
let countDescriptor = IndexDescriptor(
    name: "User_count_by_city",
    keyPaths: ["city"],
    kind: countKind,
    commonOptions: .init()
)

if let count = countDescriptor.kind as? CountIndexKind {
    print("Aggregation structure: \(type(of: count).subspaceStructure)")  // .aggregation
}
```

#### Benefits of Protocol-Based Design

| Benefit | Description |
|---------|-------------|
| **Protocol-Based** | Implement IndexKind protocol to add new index types |
| **Simple API** | Direct use of `any IndexKind`, no wrapper types |
| **Type-Safe Runtime** | Use `as?` casting for type-safe access to concrete types |
| **Third-Party Extension** | Add custom indexes without modifying FDBIndexing |
| **Validation** | validateTypes() enforces type constraints |
| **Explicit Structure** | SubspaceStructure defines index organization |

**Trade-offs**:
- ✅ Simpler, more idiomatic Swift 6 design
- ✅ No type-erased wrapper complexity
- ❌ IndexDescriptor is not Codable (existential types can't conform)
- ❌ IndexDescriptor is not Hashable/Equatable

#### Implementation Selection in Upper Layers

Upper layers (e.g., fdb-record-layer) use type casting to dispatch to appropriate implementations:

```swift
// IndexManager implementation selection (pseudo-code for upper layers)
let kindIdentifier = type(of: descriptor.kind).identifier

switch kindIdentifier {
case "scalar":
    if let scalar = descriptor.kind as? ScalarIndexKind {
        return ScalarIndexMaintainer(
            index: descriptor,
            subspace: indexSubspace
        )
    }

case "count":
    if let count = descriptor.kind as? CountIndexKind {
        return CountIndexMaintainer(
            index: descriptor,
            subspace: indexSubspace
        )
    }

case "sum":
    if let sum = descriptor.kind as? SumIndexKind {
        return SumIndexMaintainer(
            index: descriptor,
            subspace: indexSubspace
        )
    }

default:
    throw IndexError.unknownKind(kindIdentifier)
}
```

**Note**: This is pseudo-code showing how upper layers would implement IndexMaintainer selection. The actual implementation would be in packages like fdb-record-layer.

---

### Key Design Decisions

1. **FDBStore is Type-Independent and Shared Across All Layers**
   - `FDBStore` operates on `Data` (serialized bytes), not typed items
   - All data model layers (Record, Document, Vector, Graph) reuse the same `FDBStore`
   - Upper layers add type-safety through wrappers (e.g., `RecordStore<Record>` in fdb-record-layer)
   - Location: `Sources/FDBRuntime/FDBStore.swift`

2. **Protocol-Based Design in FDBRuntime**
   - `IndexMaintainer<Item>` protocol - defines interface for index maintenance
   - `DataAccess<Item>` protocol - defines interface for item field access
   - Concrete implementations are in upper layers (e.g., fdb-record-layer)
   - This allows different data models to provide their own implementations

3. **Separation of Concerns**
   - **FDBIndexing**: Only metadata (IndexKind, IndexDescriptor) - no FDB dependency
   - **FDBCore**: Recordable protocol + @Persistable macro - FDB-independent, works on iOS/macOS clients
   - **FDBRuntime**: Store management (FDBStore, FDBContainer), protocols (IndexMaintainer, DataAccess), built-in IndexKinds

4. **Macro-Generated Code**
   - The `@Persistable` macro generates metadata (persistableType, primaryKeyFields, indexDescriptors)
   - `#PrimaryKey<T>`, `#Index<T>`, `#Directory` macros provide declarative definitions
   - Macro implementation: `Sources/FDBCoreMacros/RecordableMacro.swift`

5. **Terminology: "Item" vs "Record"**
   - **FDBRuntime layer** (FDBStore, FDBContext, FDBContainer): Uses **"item"** terminology
     - Type-independent, works with raw `Data`
     - Parameters: `itemType`, `itemSubspace`, `insertedItems`, `deletedItems`
     - Reason: Avoids confusion with typed "Record" models in upper layers
   - **Upper layers** (fdb-record-layer, protocols): Uses **"record"** terminology
     - Type-dependent, works with `Recordable` protocol
     - Parameters: `persistableType`, `Record` generic type, `DataAccess`, `IndexMaintainer<Item>`
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
  - `updateIndex(oldItem:newItem:dataAccess:transaction:)` - called on insert/update/delete
  - `scanItem(_:primaryKey:dataAccess:transaction:)` - called during batch indexing

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

#### Recordable Protocol (Sources/FDBCore/Recordable.swift)
- FDB-independent interface for records
- Generated by `@Persistable` macro
- Provides metadata: `persistableType`, `primaryKeyFields`, `allFields`, `indexDescriptors`
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
- `Tests/FDBIndexingTests/` - Index metadata and IndexKind tests
- `Tests/FDBCoreTests/` - Persistable protocol and @Persistable macro tests
- `Tests/FDBRuntimeTests/` - FDBStore, IndexState, KeyExpression tests

### Test Requirements

All test targets require FoundationDB to be installed locally:

1. **FoundationDB installed locally** - `libfdb_c.dylib` must be available at `/usr/local/lib`
2. **FoundationDB server running** (for FDBRuntimeTests only)
3. **Library path configured** - All test targets use linker settings to find the library

**Why all tests need FoundationDB**:
- **FDBIndexingTests**: Tests IndexKind implementations that use FoundationDB types (Tuple, TupleElement)
- **FDBCoreTests**: Depends on FDBIndexing, which requires FoundationDB types
- **FDBRuntimeTests**: Directly tests FDBStore operations against FoundationDB

### Linker Settings

All three test targets in Package.swift have linker settings configured:

```swift
linkerSettings: [
    .unsafeFlags(["-L/usr/local/lib"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
]
```

This ensures `libfdb_c.dylib` can be loaded at runtime, both from command-line (`swift test`) and from Xcode.

## Dependencies

- **fdb-swift-bindings** (local path: `../fdb-swift-bindings`) - FoundationDB Swift bindings
- **swift-syntax** - For @Persistable macro implementation
- **swift-log** - Logging support for FDBRuntime

## Related Projects

This package is part of a larger ecosystem:
- **fdb-indexing** - Index metadata abstraction (dependency of FDBCore)
- **fdb-swift-bindings** - FoundationDB Swift bindings (dependency of FDBRuntime)
- **fdb-record-layer** - Structured record layer (builds on top of this package)

## Design Philosophy

### Multi-Layer Architecture: Single Store, Multiple Data Models

The foundational design principle of **fdb-runtime** is that **a single FDBStore instance can simultaneously serve multiple data model layers** (Record, Document, Vector, Graph). This is achieved through the **LayerConfiguration abstraction**.

#### Why This Matters

Traditional database frameworks typically have:
- One store per data model (RecordStore, DocumentStore, GraphStore)
- Separate transaction scopes
- Data duplication when mixing models
- Complex integration between different stores

**fdb-runtime's approach**:
- ✅ Single FDBStore handles all data models
- ✅ Single transaction scope across models
- ✅ No data duplication
- ✅ Seamless integration (e.g., store a Document, query via Graph, index as Vector)

#### How It Works

```swift
// FDBStore is type-independent - operates on Data
let store = FDBStore(database: database, subspace: rootSubspace)

// Each layer provides its LayerConfiguration
let recordLayer: LayerConfiguration = RecordLayerConfig()
let documentLayer: LayerConfiguration = DocumentLayerConfig()
let vectorLayer: LayerConfiguration = VectorLayerConfig()

// Store accepts items from any layer
try await store.save(
    data: serializedRecord,
    for: "User",  // itemType from RecordLayer
    primaryKey: Tuple(123),
    transaction: transaction
)

try await store.save(
    data: serializedDocument,
    for: "UserDoc",  // itemType from DocumentLayer
    primaryKey: Tuple("user_123"),
    transaction: transaction
)

// Indexes work across layers
// Example: A Document indexed by Vector embedding and Graph relationship
```

### LayerConfiguration Pattern

**Note**: LayerConfiguration is a **design pattern for upper layers** (fdb-record-layer, fdb-document-layer, etc.). It is **not implemented in fdb-runtime** - the code below is a conceptual example.

**LayerConfiguration** would be the contract between FDBStore and upper-layer data models:

```swift
// Design example (not in fdb-runtime)
// Would be in: Sources/FDBIndexing/LayerConfiguration.swift (future)

public protocol LayerConfiguration: Sendable {
    /// Item types supported by this layer (e.g., ["User", "Product"])
    var itemTypes: Set<String> { get }

    /// Factory: Create DataAccess for item type
    func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item>

    /// Factory: Create IndexMaintainer for index and item type
    func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item>
}
```

#### Example: Record Layer Configuration

```swift
// Design example (would be in fdb-record-layer package, not in fdb-runtime)
struct RecordLayerConfiguration: LayerConfiguration {
    var itemTypes: Set<String> {
        // All @Persistable types registered in schema
        return Set(schema.recordTypes.map(\.persistableType))
    }

    func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
        guard let recordType = schema.recordType(named: itemType) else {
            throw ConfigurationError.unsupportedItemType(itemType)
        }
        return RecordDataAccess<Item>(recordType: recordType)
    }

    func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        switch index.type.identifier {
        case "scalar":
            return ScalarIndexMaintainer(index: index, subspace: subspace)
        case "vector":
            let kind = try index.type.decode(VectorIndexKind.self)
            return VectorIndexMaintainer(kind: kind, subspace: subspace)
        default:
            throw ConfigurationError.unsupportedIndexType(index.type.identifier)
        }
    }
}
```

#### Example: Document Layer Configuration

```swift
// Design example (would be in fdb-document-layer package, not in fdb-runtime)
struct DocumentLayerConfiguration: LayerConfiguration {
    var itemTypes: Set<String> {
        // Document collections registered in schema
        return Set(schema.collections.map(\.name))
    }

    func makeDataAccess<Item>(for itemType: String) throws -> any DataAccess<Item> {
        guard let collection = schema.collection(named: itemType) else {
            throw ConfigurationError.unsupportedItemType(itemType)
        }
        return DocumentDataAccess<Item>(collection: collection)
    }

    func makeIndexMaintainer<Item>(
        for index: Index,
        itemType: String,
        subspace: Subspace
    ) throws -> any IndexMaintainer<Item> {
        // Document layer might support different index types
        switch index.type.identifier {
        case "scalar":
            return DocumentScalarIndexMaintainer(index: index, subspace: subspace)
        case "fulltext":
            return FullTextIndexMaintainer(index: index, subspace: subspace)
        default:
            throw ConfigurationError.unsupportedIndexType(index.type.identifier)
        }
    }
}
```

### Protocol-Based Abstraction: DataAccess and IndexMaintainer

The **DataAccess** and **IndexMaintainer** protocols are the extension points that allow each layer to provide its own implementation.

#### DataAccess: Field Extraction and Serialization

```swift
// Sources/FDBIndexing/DataAccess.swift

public protocol DataAccess<Item>: Sendable {
    associatedtype Item: Sendable

    /// Get item type name (e.g., "User", "UserDoc")
    func itemType(for item: Item) -> String

    /// Extract field value as TupleElements (for indexing)
    func extractField(from item: Item, fieldName: String) throws -> [any TupleElement]

    /// Serialize item to bytes
    func serialize(_ item: Item) throws -> FDB.Bytes

    /// Deserialize bytes to item
    func deserialize(_ bytes: FDB.Bytes) throws -> Item

    /// Evaluate KeyExpression on item (uses Visitor pattern)
    func evaluate(item: Item, expression: KeyExpression) throws -> [any TupleElement]

    // ... more methods
}
```

**Why This Matters**:
- **Record Layer**: Implements using Swift reflection (Mirror API) or macro-generated code
- **Document Layer**: Implements using JSONPath or XPath-like expressions
- **Vector Layer**: Implements by extracting embeddings from various formats
- **Graph Layer**: Implements by traversing node/edge structures

Each layer has different field access semantics, but FDBStore doesn't need to know - it just uses the DataAccess protocol.

#### IndexMaintainer: Index Update Logic

```swift
// Sources/FDBIndexing/IndexMaintainer.swift

public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Record: Sendable

    /// Update index when record changes
    func updateIndex(
        oldItem: Record?,
        newItem: Record?,
        dataAccess: any DataAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan record during batch indexing
    func scanItem(
        _ record: Record,
        primaryKey: Tuple,
        dataAccess: any DataAccess<Record>,
        transaction: any TransactionProtocol
    ) async throws
}
```

**Why This Matters**:
- **ScalarIndexMaintainer**: Maintains VALUE indexes (simple key-value mapping)
- **VectorIndexMaintainer**: Maintains HNSW graphs or flat vector indexes
- **FullTextIndexMaintainer**: Maintains inverted indexes for text search
- **GraphIndexMaintainer**: Maintains adjacency lists for graph queries

Each index type has different maintenance logic, but FDBStore doesn't need to know - it delegates to IndexMaintainer.

### Module Organization Rationale

#### Why Protocols Moved to FDBIndexing

**FDBIndexing contains**:
```
FDBIndexing/
  ├── LayerConfiguration.swift
  ├── IndexMaintainer.swift
  ├── DataAccess.swift
  ├── Index.swift
  ├── KeyExpression.swift
  └── IndexKind.swift
```

**Rationale**:
1. **Abstraction Layer**: These protocols define the contract between FDBStore and upper layers
2. **Shared by Multiple Layers**: Record, Document, Vector, Graph layers all implement these protocols
3. **Dependency Direction**: FDBRuntime depends on FDBIndexing (implements the protocols), not vice versa
4. **Extension Point**: Third-party layers can implement these protocols without modifying FDBRuntime

#### FDBIndexing: Why FoundationDB-Dependent?

**Original Confusion**:
- Old comments suggested FDBIndexing should be "FDB-independent metadata only"
- This was based on seeing IndexDescriptor and IndexKind (pure metadata)

**Reality**:
- **IndexDescriptor/IndexKind**: Metadata (no FDB types) - can be shared with clients
- **Index/DataAccess/IndexMaintainer**: Runtime abstractions (use FDB types: Tuple, Subspace, TransactionProtocol)

**Decision**:
- FDBIndexing is **FoundationDB-dependent** (like fdb-record-layer's FDBRecordLayer)
- This allows protocols to use FDB types directly (Tuple, TupleElement, Subspace)
- Client apps (iOS/macOS) don't need these protocols - they only need metadata (IndexDescriptor)

**Platform Impact**:
```swift
// Package.swift
.target(
    name: "FDBIndexing",
    dependencies: [
        .product(name: "FoundationDB", package: "fdb-swift-bindings"),
    ],
    platforms: [.macOS(.v15)]  // Server-only
)
```

### IndexDescriptor vs Index: Metadata vs Runtime

**Two Different Concerns**:

| Aspect | IndexDescriptor | Index |
|--------|----------------|-------|
| **Purpose** | Schema metadata, serializable | Runtime index definition |
| **Dependencies** | Foundation-only | FoundationDB (Tuple, Subspace) |
| **Platform** | All (iOS, macOS, Linux) | Server-only (macOS, Linux) |
| **Location** | FDBIndexing | FDBIndexing |
| **Usage** | Schema versioning, client sharing | Index maintenance at runtime |
| **Codable** | ✅ Yes | ❌ No (contains KeyExpression tree) |

**Why Both Exist**:
```swift
// IndexDescriptor: Metadata (can be sent to iOS client)
public struct IndexDescriptor: Sendable, Codable {
    public let name: String
    public let keyPaths: [String]  // Strings, not KeyPath
    public let kind: IndexKind     // Type-erased, Codable
    public let commonOptions: CommonIndexOptions
}

// Index: Runtime definition (server-only)
public struct Index: Sendable {
    public let name: String
    public let type: any IndexKind  // Concrete protocol type
    public let rootExpression: KeyExpression  // Complex tree structure
    public let subspaceKey: String
    public let recordTypes: Set<String>?
}

// Conversion: Metadata → Runtime
extension Index {
    public init(descriptor: IndexDescriptor, recordType: String) throws {
        self.name = descriptor.name
        self.type = descriptor.kind  // Decode to concrete IndexKind
        self.rootExpression = try KeyExpression.fromKeyPaths(descriptor.keyPaths)
        self.subspaceKey = descriptor.name
        self.recordTypes = Set([recordType])
    }
}
```

### Platform and Dependency Decisions

#### Platform Matrix

| Module | Platforms | FoundationDB Dependency | Reason |
|--------|-----------|------------------------|--------|
| **FDBIndexing** | macOS, Linux | ✅ Yes | Protocol abstractions use FDB types |
| **FDBCore** | macOS, Linux (現在) | ❌ No (FDBIndexingに依存) | FDB非依存だが現在はPackage.swiftでmacOSのみ、将来的に全プラットフォーム対応可能 |
| **FDBRuntime** | macOS, Linux | ✅ Yes | Server-side store implementation |

#### Dependency Graph

```
fdb-runtime (this package)
├── FDBIndexing (macOS/Linux, FDB-dependent)
│   └── Depends on: FoundationDB
│
├── FDBCore (All platforms, FDB-independent)
│   └── Depends on: FDBIndexing (metadata only)
│
└── FDBRuntime (macOS/Linux, FDB-dependent)
    ├── Depends on: FDBCore, FDBIndexing, FoundationDB
    └── Uses: DataAccess, IndexMaintainer protocols from FDBIndexing

Upper layers (separate packages)
├── fdb-record-layer
│   └── Implements: RecordLayerConfiguration, RecordDataAccess, various IndexMaintainers
│
├── fdb-document-layer
│   └── Implements: DocumentLayerConfiguration, DocumentDataAccess, FullTextIndexMaintainer
│
└── fdb-vector-layer
    └── Implements: VectorLayerConfiguration, VectorDataAccess, HNSWIndexMaintainer
```

#### Why This Structure?

**Client Apps (iOS/macOS)**:
```swift
import FDBCore  // Only this - get @Persistable, metadata

@Persistable
struct User {
    #PrimaryKey<User>([\.userID])
    var userID: Int64
    var name: String
}

// Use Codable for JSON API
let user = User(userID: 123, name: "Alice")
let json = try JSONEncoder().encode(user)
```

**Server Apps (macOS/Linux)**:
```swift
import FDBCore       // Model definitions
import FDBRuntime    // Store management
import FDBRecordLayer  // Typed RecordStore

@Persistable
struct User {
    #PrimaryKey<User>([\.userID])
    #Index<User>([\.email])
    var userID: Int64
    var email: String
    var name: String
}

// Use RecordStore for FDB persistence
let store = try await RecordStore(
    database: database,
    schema: Schema([User.self]),
    subspace: subspace
)

try await store.save(user)
```

### Data Flow Across Layers

**Example: Saving a Document with Vector Index**

```swift
// User code (fdb-document-layer)
let document = Document(
    id: "doc123",
    content: "Machine learning tutorial",
    embedding: getEmbedding("Machine learning tutorial")
)

try await documentStore.save(document)

// Internal flow:
// 1. DocumentStore (fdb-document-layer)
//    → serialize document to Data
//    → get LayerConfiguration
//
// 2. FDBStore (fdb-runtime)
//    → save(data, itemType: "Document", primaryKey: Tuple("doc123"), transaction)
//    → store in [R]/Document/doc123 = data
//
// 3. LayerConfiguration.makeIndexMaintainer()
//    → returns VectorIndexMaintainer (from fdb-vector-layer)
//
// 4. VectorIndexMaintainer.updateIndex()
//    → extract embedding via DataAccess.extractField()
//    → build HNSW graph in [I]/document_embedding/...
//
// 5. All operations in single transaction
//    → atomic: document storage + vector index update
```

### Summary: Design Principles

1. **Single Store, Multiple Models**: FDBStore is type-independent, serves all data layers simultaneously

2. **Protocol-Based Extension**: DataAccess and IndexMaintainer define contracts, each layer provides implementations

3. **LayerConfiguration Factory**: Upper layers register their ItemTypes and provide factories for DataAccess/IndexMaintainer

4. **Clear Module Boundaries**:
   - FDBIndexing: Protocols + metadata (FDB-dependent, server-only)
   - FDBCore: Model definitions (FDB-independent, all platforms)
   - FDBRuntime: Store implementation (FDB-dependent, server-only)

5. **Metadata vs Runtime Separation**: IndexDescriptor (Codable metadata) vs Index (runtime with KeyExpression tree)

6. **Platform-Aware Design**: Client apps get model definitions only, server apps get full persistence stack

This architecture enables **composable data models** where a single FDBStore handles Records, Documents, Vectors, and Graphs in the same transaction, with each layer contributing its own indexing and query capabilities.

## Important File Locations

- Core protocols: `Sources/FDBCore/Recordable.swift`
- Macro implementation: `Sources/FDBCoreMacros/RecordableMacro.swift`
- Store implementation: `Sources/FDBRuntime/FDBStore.swift`
- Container: `Sources/FDBRuntime/FDBContainer.swift`
- Protocol definitions: `Sources/FDBIndexing/IndexMaintainer.swift`, `Sources/FDBIndexing/DataAccess.swift`, `Sources/FDBIndexing/LayerConfiguration.swift`
- Architecture documentation: `docs/architecture.md`
