# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

**fdb-runtime** is a Swift package that provides a runtime foundation for data persistence and management on FoundationDB. It consists of four modules in a layered architecture:

1. **FDBModel** - Model definitions and metadata (FDB-independent, all platforms: iOS/macOS/Linux)
   - `Persistable` protocol and `@Persistable` macro
   - `IndexKind` protocol and standard implementations (`ScalarIndexKind`, `CountIndexKind`, etc.)
   - `IndexDescriptor`, `CommonIndexOptions`, `SubspaceStructure`
   - `TypeValidation` helper functions
   - `ULID` for auto-generated IDs
2. **FDBCore** - Schema and Serialization (FDB-independent, all platforms)
   - `Schema` (entities, versions, index descriptors)
   - `ProtobufEncoder` / `ProtobufDecoder` for efficient serialization
3. **FDBIndexing** - Index abstraction layer (FDB-dependent, Server only)
   - `IndexMaintainer` protocol and implementations:
     - `ScalarIndexMaintainer` - VALUE indexes for sorting and range queries
     - `CountIndexMaintainer` - COUNT aggregation with atomic operations
     - `SumIndexMaintainer` - SUM aggregation with atomic operations
     - `MinIndexMaintainer` / `MaxIndexMaintainer` - Min/Max tracking
     - `VersionIndexMaintainer` - Version-based indexes
   - `IndexKindMaintainable` protocol - bridges IndexKind to IndexMaintainer
   - `_EntityIndexBuildable` protocol - enables existential type dispatch for OnlineIndexer
   - `DataAccess` static methods for field extraction
   - `KeyExpression` and `KeyExpressionVisitor` for index key building
   - `Index`, `IndexManager`, `IndexStateManager`, `OnlineIndexer`
4. **FDBRuntime** - Store and Container (FDB-dependent, Server only)
   - `FDBStore` (type-independent CRUD operations)
   - `FDBContainer` (schema management, store lifecycle, directory layer)
   - `FDBContext` (change tracking, batch operations)

**Module Dependencies**:
```
FDBModel (Foundation only) ← Can be used on iOS/macOS/Linux clients
    ↓
FDBCore (FDBModel only, Foundation only) ← Can be used on iOS/macOS/Linux clients
    ↓
FDBIndexing (FDBModel + FDBCore + FoundationDB) ← Server only (macOS/Linux)
    ↓
FDBRuntime (FDBModel + FDBCore + FDBIndexing + FoundationDB) ← Server only (macOS/Linux)
```

This is a foundational package designed to support **multiple data model layers** (Record, Document, Vector, Graph) built on top of it. The key design principle is that **a single FDBStore handles multiple data models simultaneously** through the LayerConfiguration abstraction.

## Build and Test Commands

### Building the Project
```bash
# Build all targets
swift build

# Build specific products
swift build --product FDBModel
swift build --product FDBCore
swift build --product FDBIndexing
swift build --product FDBRuntime
```

### Running Tests
```bash
# Run all tests
swift test

# Run specific test targets
swift test --filter FDBModelTests
swift test --filter FDBCoreTests
swift test --filter FDBIndexingTests
swift test --filter FDBRuntimeTests

# Run a single test
swift test --filter FDBCoreTests.PersistableTests
```

**Note**: Test targets have different FoundationDB requirements:
- **FDBModelTests**: Does NOT require FoundationDB (tests FDB-independent model definitions)
- **FDBCoreTests, FDBIndexingTests, FDBRuntimeTests**: Require FoundationDB installed locally with `libfdb_c.dylib` at `/usr/local/lib`

The linker settings in Package.swift configure the rpath to `/usr/local/lib` for test targets that depend on FoundationDB.

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

## FDBContainer and FDBContext Usage

### SwiftData-like API (Recommended)

**FDBContainer** provides a SwiftData-like API for simplified initialization and usage. This is the recommended approach for most applications.

#### Basic Initialization

```swift
import FDBRuntime

// 1. Application startup (once per process)
// IMPORTANT: Call this globally before creating any FDBContainer
try await FDBClient.initialize()

// 2. Create schema and configuration
let schema = Schema(
    entities: [
        // Define your entities here
        Schema.Entity(
            name: "User",
            allFields: ["userID", "email", "name"],
            indexDescriptors: [],
            enumMetadata: [:]
        )
    ],
    version: Schema.Version(1, 0, 0)
)

let config = FDBConfiguration(schema: schema)

// 3. Create container (SwiftData-like API)
let container = try FDBContainer(configurations: [config])

// 4. Access main context
let context = await container.mainContext

// 5. Use context for data operations
let userData = // ... serialize your data
context.insert(
    data: userData,
    for: "User",
    id: Tuple(user.id),
    subspace: try await container.getOrOpenDirectory(path: ["users"])
)

// 6. Save changes
try await context.save()
```

#### Key Concepts

**FDBConfiguration**: SwiftData-compatible configuration object that specifies:
- Schema (entities and indexes)
- Cluster file path (optional)
- API version (optional, for documentation only)
- In-memory mode (future feature)

**FDBContainer**: Manages:
- Database connection
- Schema versioning
- FDBStore lifecycle (creation and caching)
- FDBContext (change tracking)
- DirectoryLayer (singleton)
- Migrations

**FDBContext**: Provides change tracking and batch operations:
- `insert()`: Stage data for insertion
- `delete()`: Stage data for deletion
- `save()`: Atomically commit all changes
- `rollback()`: Discard all pending changes
- `hasChanges`: Check if there are unsaved changes

#### Important Notes

1. **Global Initialization**: `FDBClient.initialize()` must be called **once** at application startup, **before** creating any FDBContainer:
   ```swift
   // ✅ Correct: Global initialization
   @main
   struct MyApp {
       static func main() async throws {
           // Initialize FDB (once)
           try await FDBClient.initialize()

           // Create containers as needed
           let container = try FDBContainer(configurations: [config])

           // ... rest of application
       }
   }
   ```

2. **API Version**: If specified in FDBConfiguration, it's for documentation only. The actual API version must be selected globally via `FDBClient.selectAPIVersion()` before initialization:
   ```swift
   // Optional: Select specific API version (before initialize)
   try FDBClient.selectAPIVersion(710)  // FDB 7.1.0

   // Initialize FDB
   try await FDBClient.initialize()
   ```

3. **MainContext**: The main context is created lazily and must be accessed from `@MainActor`:
   ```swift
   @MainActor
   func performDatabaseOperation() async throws {
       let context = container.mainContext
       // ... use context
   }
   ```

#### Example: Complete Application

```swift
import FDBRuntime
import Foundation

@main
struct MyApp {
    static func main() async throws {
        // 1. Global FDB initialization (once)
        try await FDBClient.initialize()

        // 2. Define schema
        let schema = Schema(
            entities: [
                Schema.Entity(
                    name: "User",
                    allFields: ["userID", "email", "name"],
                    indexDescriptors: [],
                    enumMetadata: [:]
                )
            ],
            version: Schema.Version(1, 0, 0)
        )

        // 3. Create configuration
        let config = FDBConfiguration(schema: schema)

        // 4. Create container (SwiftData-like API)
        let container = try FDBContainer(configurations: [config])

        // 5. Get directory for users
        let userSubspace = try await container.getOrOpenDirectory(path: ["users"])

        // 6. Access main context
        let context = await container.mainContext

        // 7. Insert data
        let userData = // ... serialize your data
        context.insert(
            data: userData,
            for: "User",
            id: Tuple(user.id),
            subspace: userSubspace
        )

        // 8. Save changes
        try await context.save()

        print("User saved successfully")
    }
}
```

### Low-Level API (Advanced)

For advanced use cases where you need manual control over database initialization:

```swift
import FDBRuntime

// 1. Manual initialization
try await FDBClient.initialize()
let database = try FDBClient.openDatabase()

// 2. Create schema
let schema = Schema(...)

// 3. Create container with explicit database
let container = FDBContainer(
    database: database,
    schema: schema,
    migrations: [],
    rootSubspace: nil,  // Optional: for multi-tenant isolation
    directoryLayer: nil,  // Optional: for test isolation
    logger: nil  // Optional: custom logger
)

// 4. Use container...
```

### Testing with FDBContainer

For tests, use a custom DirectoryLayer for isolation:

```swift
import Testing
@testable import FDBRuntime

@Suite("FDBContainer Tests")
struct FDBContainerTests {

    @Test func testContainerInitialization() async throws {
        // Use global FDB initialization
        await FDBTestEnvironment.shared.ensureInitialized()

        let database = try FDBClient.openDatabase()

        // Create test-specific subspace
        let testSubspace = Subspace(prefix: Tuple("test", UUID().uuidString).pack())

        // Create custom DirectoryLayer for isolation
        let testDirectoryLayer = DirectoryLayer(
            database: database,
            nodeSubspace: testSubspace.subspace(0xFE),
            contentSubspace: testSubspace
        )

        // Create container with test DirectoryLayer
        let schema = Schema(entities: [], version: Schema.Version(1, 0, 0))
        let config = FDBConfiguration(schema: schema)
        let container = try FDBContainer(
            configurations: [config],
            directoryLayer: testDirectoryLayer
        )

        // ... test operations
    }
}
```

## Architecture and Design Principles

### Layered Architecture

The codebase follows a strict layered architecture where each layer has clear responsibilities:

```
FDBModel (FDB-independent, all platforms)
  - Persistable protocol, @Persistable macro
  - IndexKind protocol, StandardIndexKinds (Scalar, Count, Sum, Min, Max, Version)
  - IndexDescriptor, TypeValidation, ULID
    ↓
FDBCore (FDB-independent, all platforms)
  - Schema (entities, versions)
  - Serialization (ProtobufEncoder/Decoder)
    ↓
FDBIndexing (FDB-dependent, server only)
  - DataAccess, KeyExpression, KeyExpressionVisitor
  - IndexMaintainer protocol, IndexKindMaintainable protocol
  - _EntityIndexBuildable protocol (existential type dispatch)
  - Maintainer implementations: Scalar, Count, Sum, Min, Max, Version
  - Index, IndexManager, OnlineIndexer, EntityIndexBuilder
    ↓
FDBRuntime (FDB-dependent, server only)
  - FDBStore, FDBContainer, FDBContext
  - Migration, MigrationContext
    ↓
Upper layers (fdb-record-layer, fdb-document-layer, etc.)
```

### IndexKind-Based Extensibility

**Status**: ✅ Fully implemented in FDBModel module (protocol and standard implementations)

FDBModel provides a **protocol-based extensible index system** that allows third parties to add custom index types without modifying the core framework. The protocol and standard implementations are FDB-independent, enabling use on all platforms including iOS clients.

#### Core Design

**IndexKind Protocol**:
```swift
// FDBModel/IndexKind.swift

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
// FDBModel/IndexDescriptor.swift

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
    // id is auto-generated as ULID if not defined
    // var id: String = ULID().ulidString  // (auto-generated)

    // Scalar index on email (unique)
    #Index<User>([\.email], type: ScalarIndexKind(), unique: true)

    // Count index by city
    #Index<User>([\.city], type: CountIndexKind())

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

### Index Building Architecture

FDBIndexing provides a comprehensive index building system that handles both runtime index maintenance and batch index building during migrations.

#### IndexKindMaintainable Protocol

The `IndexKindMaintainable` protocol bridges IndexKind metadata to IndexMaintainer implementations:

```swift
// Sources/FDBIndexing/IndexKindMaintainable.swift

public protocol IndexKindMaintainable: IndexKind {
    /// Create an IndexMaintainer for this index kind
    func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item>
}

// Each IndexKind implements this protocol
extension ScalarIndexKind: IndexKindMaintainable {
    public func makeIndexMaintainer<Item: Persistable>(...) -> any IndexMaintainer<Item> {
        return ScalarIndexMaintainer<Item>(...)
    }
}

extension CountIndexKind: IndexKindMaintainable { ... }
extension SumIndexKind: IndexKindMaintainable { ... }
extension MinIndexKind: IndexKindMaintainable { ... }
extension MaxIndexKind: IndexKindMaintainable { ... }
extension VersionIndexKind: IndexKindMaintainable { ... }
```

#### _EntityIndexBuildable Protocol (Existential Type Dispatch)

Swift's existential dispatch doesn't call specialized protocol extensions. When you have `type: any Persistable.Type` and call a method, Swift uses the default implementation, not a specialized `where Self: Codable` extension.

The `_EntityIndexBuildable` protocol solves this by enabling existential type dispatch for OnlineIndexer:

```swift
// Sources/FDBIndexing/EntityIndexBuilder.swift

/// Internal protocol for existential type dispatch
public protocol _EntityIndexBuildable: Persistable {
    static func _buildIndex(
        database: any DatabaseProtocol,
        itemSubspace: Subspace,
        indexSubspace: Subspace,
        index: Index,
        indexStateManager: IndexStateManager,
        batchSize: Int
    ) async throws
}

// Automatic conformance for all Codable Persistable types
extension Persistable where Self: Codable {
    public static func _buildIndex(...) async throws {
        try await Self.buildEntityIndex(...)
    }
}
```

**Usage in MigrationContext**:

```swift
// MigrationContext.addIndex uses persistableType directly
try await EntityIndexBuilder.buildIndex(
    forPersistableType: targetEntity.persistableType,  // any Persistable.Type
    database: database,
    itemSubspace: itemSubspace,
    indexSubspace: indexSubspace,
    index: index,
    indexStateManager: indexManager.stateManager,
    batchSize: batchSize
)
```

**How it works**:
1. `Schema.Entity` stores `persistableType: any Persistable.Type`
2. `EntityIndexBuilder.buildIndex(forPersistableType:)` casts to `any _EntityIndexBuildable.Type`
3. If successful, calls `_buildIndex()` which dispatches to the concrete type's implementation
4. The concrete implementation uses `OnlineIndexer<Self>` with the correct type

#### IndexBuilderRegistry (Optional)

For advanced use cases, `IndexBuilderRegistry` provides manual type registration:

```swift
// Manual registration (optional - not needed for normal usage)
IndexBuilderRegistry.shared.register(User.self)

// Build index by entity name
try await IndexBuilderRegistry.shared.buildIndex(
    entityName: "User",
    database: database,
    ...
)
```

**Note**: The primary index building flow uses `_EntityIndexBuildable` and doesn't require manual registration.

---

### Key Design Decisions

1. **FDBStore is Type-Independent and Shared Across All Layers**
   - `FDBStore` operates on `Data` (serialized bytes), not typed items
   - All data model layers (Record, Document, Vector, Graph) reuse the same `FDBStore`
   - Upper layers add type-safety through wrappers (e.g., `RecordStore<Record>` in fdb-record-layer)
   - Location: `Sources/FDBRuntime/FDBStore.swift`

2. **Protocol-Based Design in FDBIndexing**
   - `IndexMaintainer<Item>` protocol - defines interface for index maintenance
   - `IndexKindMaintainable` protocol - bridges IndexKind to IndexMaintainer at runtime
   - `_EntityIndexBuildable` protocol - enables existential type dispatch for OnlineIndexer
   - `DataAccess` static struct - provides field extraction utilities for all Persistable types
   - Built-in IndexMaintainer implementations:
     - `ScalarIndexMaintainer` - VALUE indexes for sorting and range queries
     - `CountIndexMaintainer` - COUNT aggregation with atomic add operations
     - `SumIndexMaintainer` - SUM aggregation with atomic add operations
     - `MinIndexMaintainer` / `MaxIndexMaintainer` - Min/Max tracking via sorted keys
     - `VersionIndexMaintainer` - Version-based indexes
   - Upper layers can provide additional IndexMaintainer implementations (e.g., VectorIndexMaintainer)

3. **Separation of Concerns**
   - **FDBModel**: Persistable protocol, @Persistable macro, IndexKind/IndexDescriptor metadata, StandardIndexKinds, TypeValidation, ULID - FDB-independent, works on all platforms
   - **FDBCore**: Schema and Serialization (ProtobufEncoder/Decoder) - FDB-independent, works on all platforms
   - **FDBIndexing**: DataAccess, KeyExpression, IndexMaintainer protocol, IndexKindMaintainable, _EntityIndexBuildable, all Maintainer implementations (Scalar, Count, Sum, Min, Max, Version), Index, IndexManager, OnlineIndexer, EntityIndexBuilder - FDB-dependent, server only
   - **FDBRuntime**: Store management (FDBStore, FDBContainer, FDBContext), Migration - FDB-dependent, server only

4. **Macro-Generated Code**
   - The `@Persistable` macro generates metadata (persistableType, id, allFields, indexDescriptors)
   - The macro auto-generates `var id: String = ULID().ulidString` if user doesn't define it
   - `#Index<T>`, `#Directory` macros provide declarative definitions
   - Macro implementation: `Sources/FDBModelMacros/PersistableMacro.swift`

5. **Terminology: "Item" vs "Record"**
   - **FDBRuntime layer** (FDBStore, FDBContext, FDBContainer): Uses **"item"** terminology
     - Type-independent, works with raw `Data`
     - Parameters: `itemType`, `itemSubspace`, `insertedItems`, `deletedItems`
     - Reason: Avoids confusion with typed "Record" models in upper layers
   - **Upper layers** (fdb-record-layer, protocols): Uses **"record"** terminology
     - Type-dependent, works with `Persistable` protocol
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

#### IndexMaintainer Protocol (Sources/FDBIndexing/IndexMaintainer.swift)
- Protocol definition for index maintenance
- Key methods:
  - `updateIndex(oldItem:newItem:transaction:)` - called on insert/update/delete
  - `scanItem(_:id:transaction:)` - called during batch indexing
  - `customBuildStrategy` - optional custom bulk build logic (e.g., for HNSW)
- **ScalarIndexMaintainer** implementation provided in FDBIndexing for VALUE indexes

#### DataAccess (Sources/FDBIndexing/DataAccess.swift)
- **Static utility struct** (not a protocol) for extracting field values from Persistable items
- Uses Persistable's `@dynamicMemberLookup` subscript for field access
- Key static methods:
  - `evaluate(item:expression:)` - evaluate KeyExpression (uses Visitor pattern)
  - `extractField(from:keyPath:)` - extract single field value as TupleElements
  - `extractId(from:using:)` - extract item ID using KeyExpression
  - `serialize(_:)` / `deserialize(_:)` - item serialization via ProtobufEncoder/Decoder
- Uses `DataAccessEvaluator` visitor for KeyExpression traversal
- **Note**: Works with any Persistable type via generics

#### Persistable Protocol (Sources/FDBModel/Persistable.swift)
- FDB-independent interface for persistable types
- Generated by `@Persistable` macro
- Provides: `id` (auto-generated ULID or user-defined), `persistableType`, `allFields`, `indexDescriptors`
- Conforms to `Sendable` and `Codable`
- Uses `@dynamicMemberLookup` for field access by name

#### ID Type Requirements

**Important**: When used with FDBRuntime (server-side), the ID type **MUST** conform to `TupleElement` for FDB key encoding. This cannot be enforced at compile time because FDBModel is platform-independent.

**Supported ID types** (conform to TupleElement):
- `String` (recommended: ULID for sortable unique IDs)
- `Int64`, `Int32`, `Int16`, `Int8`, `Int`
- `UInt64`, `UInt32`, `UInt16`, `UInt8`, `UInt`
- `UUID`
- `Double`, `Float`
- `Bool`
- `Data`, `[UInt8]`

**Runtime Validation**:
```swift
import FDBRuntime

// Validate ID before storage operations
let user = User(email: "test@example.com", name: "Test")
let validatedID = try user.validateIDForStorage()  // Throws if ID type invalid

// Or use the helper function
let id = try validateID(user.id, for: User.persistableType)
```

**Error Handling**:
```swift
do {
    let validatedID = try user.validateIDForStorage()
    context.insert(data: data, for: "User", id: validatedID, subspace: subspace)
} catch let error as IDTypeValidationError {
    // Handle invalid ID type (custom struct, unsupported enum, etc.)
    print(error.description)
}
```

### Data Flow

**Save Operation**:
```
User Code → RecordStore (upper layer)
  → serialize record
  → FDBStore.save(data, itemType, id, transaction)
    → store in itemSubspace: [R]/[itemType]/[id]
  → IndexMaintainer.updateIndex() (via IndexManager in upper layer)
    → update entries in indexSubspace: [I]/[indexName]/...
```

**Load Operation**:
```
User Code → RecordStore (upper layer)
  → FDBStore.load(itemType, id, transaction)
    → fetch from itemSubspace: [R]/[itemType]/[id]
  → deserialize data to record
  → return record
```

### Subspace Structure

All data is organized under a root subspace with two main sections:
- **R/** - Item storage: `[subspace]/R/[itemType]/[id] = data`
- **I/** - Index storage: `[subspace]/I/[indexName]/... = ''`

**Note**: The subspace prefix "R" is kept for backward compatibility, even though the terminology changed from "record" to "item".

### Platform Considerations

- **FDBModel**: All platforms (iOS, macOS, Linux, tvOS, watchOS, visionOS) - FDB-independent
- **FDBCore**: All platforms (iOS, macOS, Linux, tvOS, watchOS, visionOS) - FDB-independent
- **FDBIndexing**: macOS, Linux only (requires FoundationDB bindings)
- **FDBRuntime**: macOS, Linux only (requires FoundationDB bindings)
- Swift tools version: 6.2
- Swift 6 language mode enabled for all targets

## Observability and Statistics

### Metrics (swift-metrics)

FDBIndexing uses [swift-metrics](https://github.com/apple/swift-metrics) for observability:

**OnlineIndexer Metrics**:
- `fdb_indexer_items_indexed_total` - Counter for items indexed
- `fdb_indexer_batches_processed_total` - Counter for batches processed
- `fdb_indexer_batch_duration_seconds` - Timer for batch duration
- `fdb_indexer_errors_total` - Counter for errors

**OnlineIndexScrubber Metrics**:
- `fdb_scrubber_entries_scanned_total` - Counter for index entries scanned
- `fdb_scrubber_items_scanned_total` - Counter for items scanned
- `fdb_scrubber_dangling_entries_total` - Counter for dangling entries detected
- `fdb_scrubber_missing_entries_total` - Counter for missing entries detected
- `fdb_scrubber_entries_repaired_total` - Counter for entries repaired
- `fdb_scrubber_duration_seconds` - Timer for scrub duration
- `fdb_scrubber_errors_total` - Counter for errors

**FDBDataStore Metrics** (internal via DataStoreDelegate):
- `fdb_datastore_operations_total` - Counter for operations (save/fetch/delete)
- `fdb_datastore_operation_duration_seconds` - Timer for operation duration
- `fdb_datastore_items_total` - Counter for items processed

### OnlineIndexScrubber

Index consistency verification and repair tool:

```swift
let scrubber = OnlineIndexScrubber<User>(
    database: database,
    itemSubspace: itemSubspace,
    indexSubspace: indexSubspace,
    itemType: "User",
    index: emailIndex,
    indexMaintainer: emailIndexMaintainer,
    configuration: .default  // or .conservative, .aggressive
)

// Run scrubbing (detection only by default)
let result = try await scrubber.scrubIndex()

if result.isHealthy {
    print("Index is healthy")
} else {
    print("Issues found: \(result.summary.issuesDetected)")
}
```

**Two-Phase Scanning**:
1. **Phase 1 (Index → Item)**: Detects dangling entries (index entries without items)
2. **Phase 2 (Item → Index)**: Detects missing entries (items without index entries)

**Configuration Presets**:
- `.default` - Balanced settings (1,000 entries/batch, no repair)
- `.conservative` - Production environments (100 entries/batch, throttling)
- `.aggressive` - Maintenance windows (10,000 entries/batch, repair enabled)

### HyperLogLog (Cardinality Estimation)

Probabilistic cardinality estimation using HyperLogLog algorithm:

```swift
import FDBModel

var hll = HyperLogLog()

// Add values
for user in users {
    hll.add(.string(user.email))
}

// Get estimated cardinality
let uniqueCount = hll.cardinality()
print("Estimated unique emails: ~\(uniqueCount)")  // ±2% accuracy

// Merge estimators (for distributed counting)
var hll2 = HyperLogLog()
// ... add values
hll.merge(hll2)
```

**Properties**:
- ~16KB memory (16,384 registers)
- ±2% accuracy (standard error: 0.81%)
- Codable for persistence

### FieldValue

Type-safe enum for comparable field values:

```swift
import FDBModel

let intValue = FieldValue.int64(42)
let strValue = FieldValue.string("hello")
let nullValue = FieldValue.null

// Comparison
if intValue < FieldValue.int64(100) { }

// Used by HyperLogLog
var hll = HyperLogLog()
hll.add(intValue)
```

**Supported Types**: `int64`, `double`, `string`, `bool`, `data`, `null`

## Testing Notes

### Test Structure
- `Tests/FDBModelTests/` - @Persistable macro tests, Persistable protocol tests (FDB-independent)
- `Tests/FDBCoreTests/` - Schema tests (requires FDBRuntime for some integration tests)
- `Tests/FDBIndexingTests/` - ScalarIndexMaintainer, OnlineIndexer, DataAccess tests
- `Tests/FDBRuntimeTests/` - FDBStore, FDBContext, FDBContainer tests

### Test Requirements

**FDBModelTests**: Does NOT require FoundationDB - tests FDB-independent model definitions

**FDBCoreTests, FDBIndexingTests, FDBRuntimeTests**: Require FoundationDB installed locally:
1. **FoundationDB installed locally** - `libfdb_c.dylib` must be available at `/usr/local/lib`
2. **FoundationDB server running** (for integration tests)
3. **Library path configured** - Test targets use linker settings to find the library

**Why most tests need FoundationDB**:
- **FDBCoreTests**: Some tests depend on FDBRuntime for integration testing
- **FDBIndexingTests**: Tests DataAccess, KeyExpression, ScalarIndexMaintainer using FDB types (Tuple, TupleElement)
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

## Swift Concurrency Pattern

### final class + Mutex パターン

**重要**: このプロジェクトは `actor` を使用せず、`final class: Sendable` + `Mutex` パターンを採用。

**理由**: スループット最適化
- actorはシリアライズされた実行 → 低スループット
- Mutexは細粒度ロック → 高い並行性
- データベースI/O中も他のタスクを実行可能

**実装パターン**:
```swift
import Synchronization

public final class ClassName: Sendable {
    // 1. DatabaseProtocolは内部的にスレッドセーフ
    nonisolated(unsafe) private let database: any DatabaseProtocol

    // 2. 可変状態はMutexで保護（structにまとめる）
    private struct State: Sendable {
        var counter: Int = 0
        var isRunning: Bool = false
    }
    private let state: Mutex<State>

    public init(database: any DatabaseProtocol) {
        self.database = database
        self.state = Mutex(State())
    }

    // 3. withLockで状態アクセス（ロックスコープは最小限）
    public func operation() async throws {
        let count = state.withLock { state in
            state.counter += 1
            return state.counter
        }

        // I/O中はロックを保持しない
        try await database.withTransaction { transaction in
            // 他のタスクは getProgress() などを呼べる
        }
    }
}
```

**ガイドライン**:
1. ✅ `final class: Sendable` を使用（actorは使用しない）
2. ✅ `DatabaseProtocol` には `nonisolated(unsafe)` を使用
3. ✅ 可変状態は `Mutex<State>` で保護（Stateは`Sendable`なstruct）
4. ✅ ロックスコープは最小限（I/Oを含めない）
5. ❌ `NSLock` は使用しない（async contextで問題が発生する）
6. ❌ `@unchecked Sendable` は避ける（Mutexで適切に保護）

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
    id: Tuple(user.id),
    transaction: transaction
)

try await store.save(
    data: serializedDocument,
    for: "UserDoc",  // itemType from DocumentLayer
    id: Tuple(document.id),
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

### DataAccess and IndexMaintainer

**DataAccess** is a static utility struct and **IndexMaintainer** is a protocol that allows each layer to provide its own index maintenance implementation.

#### DataAccess: Static Field Extraction Utilities

```swift
// Sources/FDBIndexing/DataAccess.swift

/// Static utility struct (not a protocol) for extracting field values
public struct DataAccess: Sendable {
    // Private init - all methods are static

    /// Evaluate KeyExpression to extract field values
    public static func evaluate<Item: Persistable>(
        item: Item,
        expression: KeyExpression
    ) throws -> [any TupleElement]

    /// Extract a single field using Persistable's subscript
    public static func extractField<Item: Persistable>(
        from item: Item,
        keyPath: String
    ) throws -> [any TupleElement]

    /// Extract id from an item using the id expression
    public static func extractId<Item: Persistable>(
        from item: Item,
        using idExpression: KeyExpression
    ) throws -> Tuple

    /// Serialize item to bytes using ProtobufEncoder
    public static func serialize<Item: Persistable>(_ item: Item) throws -> FDB.Bytes

    /// Deserialize bytes to item using ProtobufDecoder
    public static func deserialize<Item: Persistable>(_ bytes: FDB.Bytes) throws -> Item
}
```

**Design Decision**: DataAccess is a static utility struct rather than a protocol because:
- All Persistable types have the same field access mechanism (`@dynamicMemberLookup` subscript)
- No need for different implementations per data layer
- Simpler API - just call `DataAccess.extractField(from: item, keyPath: "email")`

#### IndexMaintainer: Index Update Logic

```swift
// Sources/FDBIndexing/IndexMaintainer.swift

public protocol IndexMaintainer<Item>: Sendable {
    associatedtype Item: Persistable

    /// Update index when item changes
    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        transaction: any TransactionProtocol
    ) async throws

    /// Scan item during batch indexing
    func scanItem(
        _ item: Item,
        id: Tuple,
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

#### Current Module Structure

**FDBModel** (FDB-independent, all platforms):
```
FDBModel/
  ├── Persistable.swift          # Protocol + @dynamicMemberLookup
  ├── Macros.swift               # @Persistable, #Index, #Directory macros
  ├── IndexKind.swift            # Protocol for index kinds
  ├── StandardIndexKinds.swift   # Scalar, Count, Sum, Min, Max, Version
  ├── IndexDescriptor.swift      # Index metadata
  ├── CommonIndexOptions.swift   # Unique, sparse, metadata
  ├── SubspaceStructure.swift    # flat, hierarchical, aggregation
  ├── TypeValidation.swift       # isComparable, isNumeric helpers
  ├── ULID.swift                 # Auto-generated sortable IDs
  └── EnumMetadata.swift         # Enum field metadata
```

**FDBCore** (FDB-independent, all platforms):
```
FDBCore/
  ├── Schema.swift               # Entity definitions, versioning
  └── Serialization/
      ├── ProtobufEncoder.swift  # Efficient binary serialization
      └── ProtobufDecoder.swift
```

**FDBIndexing** (FDB-dependent, server only):
```
FDBIndexing/
  ├── DataAccess.swift           # Static field extraction utilities
  ├── KeyExpression.swift        # Field, Concatenate, Literal, etc.
  ├── KeyExpressionVisitor.swift # Visitor pattern for evaluation
  ├── IndexMaintainer.swift      # Protocol for index maintenance
  ├── ScalarIndexMaintainer.swift # VALUE index implementation
  ├── Index.swift                # Runtime index definition
  ├── IndexManager.swift         # Index registry and lifecycle
  ├── IndexStateManager.swift    # Index build state tracking
  ├── OnlineIndexer.swift        # Background index building
  └── IndexBuildStrategy.swift   # Custom build strategies (e.g., HNSW)
```

**Rationale for FDBModel/FDBIndexing Split**:
1. **Platform Independence**: IndexKind, IndexDescriptor can be used on iOS clients
2. **Clean Dependencies**: FDBModel has no FoundationDB dependency
3. **Runtime vs Metadata**: IndexDescriptor (metadata) vs Index (runtime with KeyExpression)
4. **Extension Point**: Third-party index kinds can be added in FDBModel without FDB

#### Why FDBIndexing is FoundationDB-Dependent

**FDBModel** (client-shareable):
- `IndexKind` protocol, `IndexDescriptor` - pure metadata, Codable
- `TypeValidation` - uses Swift types only

**FDBIndexing** (server-only):
- `DataAccess` - uses FDB types (Tuple, TupleElement)
- `KeyExpression` - uses FDB types for key building
- `IndexMaintainer` - uses TransactionProtocol
- `ScalarIndexMaintainer` - full FDB integration

**Platform Impact**:
```swift
// Package.swift
.target(
    name: "FDBModel",
    dependencies: ["FDBModelMacros"],  // No FoundationDB!
    // All platforms supported
)

.target(
    name: "FDBIndexing",
    dependencies: [
        "FDBModel",
        "FDBCore",
        .product(name: "FoundationDB", package: "fdb-swift-bindings"),
    ]
    // macOS/Linux only
)
```

### IndexDescriptor vs Index: Metadata vs Runtime

**Two Different Concerns**:

| Aspect | IndexDescriptor | Index |
|--------|----------------|-------|
| **Purpose** | Schema metadata, serializable | Runtime index definition |
| **Dependencies** | Foundation-only | FoundationDB (Tuple, Subspace) |
| **Platform** | All (iOS, macOS, Linux) | Server-only (macOS, Linux) |
| **Location** | FDBModel | FDBIndexing |
| **Usage** | Schema versioning, client sharing | Index maintenance at runtime |
| **Codable** | ❌ No (uses `any IndexKind`) | ❌ No (contains KeyExpression tree) |

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
    public let itemTypes: Set<String>?
}

// Conversion: Metadata → Runtime
extension Index {
    public init(descriptor: IndexDescriptor, itemType: String) throws {
        self.name = descriptor.name
        self.type = descriptor.kind  // Decode to concrete IndexKind
        self.rootExpression = try KeyExpression.fromKeyPaths(descriptor.keyPaths)
        self.subspaceKey = descriptor.name
        self.itemTypes = Set([itemType])
    }
}
```

### Platform and Dependency Decisions

#### Platform Matrix

| Module | Platforms | FoundationDB Dependency | Reason |
|--------|-----------|------------------------|--------|
| **FDBModel** | All (iOS, macOS, Linux, etc.) | ❌ No | Model definitions, metadata, ULID - client-shareable |
| **FDBCore** | All (iOS, macOS, Linux, etc.) | ❌ No | Schema, Serialization - client-shareable |
| **FDBIndexing** | macOS, Linux | ✅ Yes | DataAccess, KeyExpression, IndexMaintainer use FDB types |
| **FDBRuntime** | macOS, Linux | ✅ Yes | Server-side store implementation |

#### Dependency Graph

```
fdb-runtime (this package)
├── FDBModel (All platforms, FDB-independent)
│   └── Depends on: FDBModelMacros only
│
├── FDBCore (All platforms, FDB-independent)
│   └── Depends on: FDBModel
│
├── FDBIndexing (macOS/Linux, FDB-dependent)
│   └── Depends on: FDBModel, FDBCore, FoundationDB
│
└── FDBRuntime (macOS/Linux, FDB-dependent)
    └── Depends on: FDBModel, FDBCore, FDBIndexing, FoundationDB

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
import FDBModel  // Only this - get @Persistable, metadata

@Persistable
struct User {
    // id is auto-generated as ULID
    var email: String
    var name: String
}

// Use Codable for JSON API
let user = User(email: "alice@example.com", name: "Alice")
print(user.id)  // Auto-generated ULID: "01HXXXXXXXXXXXXXXXXXXXXXX"
let json = try JSONEncoder().encode(user)
```

**Server Apps (macOS/Linux)**:
```swift
import FDBModel      // Model definitions
import FDBRuntime    // Store management
import FDBRecordLayer  // Typed RecordStore

@Persistable
struct User {
    // id is auto-generated as ULID
    #Index<User>([\.email], unique: true)

    var email: String
    var name: String
}

// Use RecordStore for FDB persistence
let store = try await RecordStore(
    database: database,
    schema: Schema([User.self]),
    subspace: subspace
)

let user = User(email: "alice@example.com", name: "Alice")
try await store.save(user)  // Uses user.id as the key
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
//    → save(data, itemType: "Document", id: Tuple(document.id), transaction)
//    → store in [R]/Document/[id] = data
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

2. **Protocol-Based Extension**: IndexKind and IndexMaintainer define contracts, each layer provides implementations

3. **LayerConfiguration Factory**: Upper layers register their ItemTypes and provide factories for IndexMaintainer

4. **Clear Module Boundaries**:
   - FDBModel: Model definitions, IndexKind/IndexDescriptor metadata (FDB-independent, all platforms)
   - FDBCore: Schema, Serialization (FDB-independent, all platforms)
   - FDBIndexing: DataAccess, KeyExpression, IndexMaintainer, ScalarIndexMaintainer (FDB-dependent, server-only)
   - FDBRuntime: Store implementation (FDB-dependent, server-only)

5. **Metadata vs Runtime Separation**: IndexDescriptor (metadata) vs Index (runtime with KeyExpression tree)

6. **Platform-Aware Design**: Client apps get model definitions (FDBModel/FDBCore), server apps get full persistence stack

This architecture enables **composable data models** where a single FDBStore handles Records, Documents, Vectors, and Graphs in the same transaction, with each layer contributing its own indexing and query capabilities.

## Important File Locations

### FDBModel (FDB-independent, all platforms)
- Persistable protocol: `Sources/FDBModel/Persistable.swift`
- Macro definitions: `Sources/FDBModel/Macros.swift`
- IndexKind protocol: `Sources/FDBModel/IndexKind.swift`
- Standard IndexKinds: `Sources/FDBModel/StandardIndexKinds.swift`
- IndexDescriptor: `Sources/FDBModel/IndexDescriptor.swift`
- TypeValidation: `Sources/FDBModel/TypeValidation.swift`
- ULID implementation: `Sources/FDBModel/ULID.swift`
- HyperLogLog: `Sources/FDBModel/HyperLogLog.swift`
- FieldValue: `Sources/FDBModel/FieldValue.swift`
- Macro implementation: `Sources/FDBModelMacros/PersistableMacro.swift`

### FDBCore (FDB-independent, all platforms)
- Schema: `Sources/FDBCore/Schema.swift`
- Serialization: `Sources/FDBCore/Serialization/ProtobufEncoder.swift`, `Sources/FDBCore/Serialization/ProtobufDecoder.swift`

### FDBIndexing (FDB-dependent, server only)
- DataAccess: `Sources/FDBIndexing/DataAccess.swift`
- KeyExpression: `Sources/FDBIndexing/KeyExpression.swift`
- KeyExpressionVisitor: `Sources/FDBIndexing/KeyExpressionVisitor.swift`
- IndexMaintainer protocol: `Sources/FDBIndexing/IndexMaintainer.swift`
- IndexKindMaintainable protocol: `Sources/FDBIndexing/IndexKindMaintainable.swift`
- Maintainer implementations:
  - ScalarIndexMaintainer: `Sources/FDBIndexing/ScalarIndexMaintainer.swift`
  - CountIndexMaintainer: `Sources/FDBIndexing/CountIndexMaintainer.swift`
  - SumIndexMaintainer: `Sources/FDBIndexing/SumIndexMaintainer.swift`
  - MinIndexMaintainer: `Sources/FDBIndexing/MinIndexMaintainer.swift`
  - MaxIndexMaintainer: `Sources/FDBIndexing/MaxIndexMaintainer.swift`
  - VersionIndexMaintainer: `Sources/FDBIndexing/VersionIndexMaintainer.swift`
- EntityIndexBuilder: `Sources/FDBIndexing/EntityIndexBuilder.swift`
- Index: `Sources/FDBIndexing/Index.swift`
- IndexManager: `Sources/FDBIndexing/IndexManager.swift`
- OnlineIndexer: `Sources/FDBIndexing/OnlineIndexer.swift`
- OnlineIndexScrubber: `Sources/FDBIndexing/OnlineIndexScrubber.swift`
- ScrubberTypes: `Sources/FDBIndexing/ScrubberTypes.swift`
- RangeSet: `Sources/FDBIndexing/RangeSet.swift`

### FDBRuntime (FDB-dependent, server only)
- FDBDataStore: `Sources/FDBRuntime/FDBDataStore.swift`
- FDBContainer: `Sources/FDBRuntime/FDBContainer.swift`
- FDBContext: `Sources/FDBRuntime/FDBContext.swift`
- ID validation: `Sources/FDBRuntime/IDValidation.swift`
- Internal metrics delegate: `Sources/FDBRuntime/Internal/DataStoreDelegate.swift`, `Sources/FDBRuntime/Internal/MetricsDataStoreDelegate.swift`

### Documentation
- ID design: `docs/ID-DESIGN.md`

## Current Limitations

### Nested Fields Not Supported

The `#Index` macro and `DataAccess.evaluate()` currently do **not** support nested field paths (e.g., `\.address.city`). Only top-level fields are supported for indexing.

**Workaround**: Flatten nested data into top-level fields if indexing is needed:

```swift
// ❌ Not supported
@Persistable
struct User {
    var address: Address
    // #Index<User>([\.address.city])  // Won't work
}

// ✅ Supported
@Persistable
struct User {
    var addressCity: String  // Flattened
    #Index<User>([\.addressCity])
}
```

### Index Key Expression Limitations

- `FieldKeyExpression` only supports single-level field names
- Complex expressions (nested objects, computed properties) are not supported
- Array fields cannot be indexed directly (no multi-value index support yet)

### Manual Schema.Entity Prevents Online Index Building

When `Schema.Entity` is created with the manual initializer (without a concrete `Persistable.Type`), the `persistableType` property becomes a placeholder (`_PlaceholderPersistable`). This means:

- **OnlineIndexer cannot build indexes** for manually created entities
- The `_EntityIndexBuildable` conformance check will fail

**Solution**: Always use `Schema([User.self, Product.self])` or `Schema.Entity(from: User.self)` when you need OnlineIndexer support during migrations.

```swift
// ✅ Correct: Use Persistable types
let schema = Schema([User.self, Product.self])

// ❌ Avoid for migrations: Manual entity creation
let entity = Schema.Entity(
    name: "User",
    allFields: ["id", "email"],
    indexDescriptors: []
)  // OnlineIndexer won't work
```

### Unique Constraint ID Comparison Uses String Conversion

The unique constraint check in `FDBDataStore.checkUniqueConstraint` compares IDs using `String(describing:)` conversion. This could theoretically cause false positives if different ID types have the same string representation.

**Example of potential issue**:
```swift
// Int64(123) and String("123") would compare as equal
// This is unlikely in practice but worth noting
```

**Mitigation**: Use consistent ID types across your schema. The recommended approach is to use `String` (ULID) for all IDs.

### Aggregation Index Keys Remain at Zero

`CountIndexMaintainer` and `SumIndexMaintainer` use FDB atomic operations for efficiency. When a count or sum reaches zero, the key is **not deleted** - it remains with a zero value.

**Impact**:
- Storage: Slightly increased storage usage for zero-value keys
- Queries: Zero values are still returned in range scans

**Workaround**: If you need to clean up zero-value keys, implement periodic cleanup in your application layer:

```swift
// Example: Clean up zero-count keys
func cleanupZeroCounts(in subspace: Subspace, transaction: any TransactionProtocol) async throws {
    let (begin, end) = subspace.range()
    for try await (key, value) in transaction.getRange(begin: begin, end: end, snapshot: false) {
        let count = value.withUnsafeBytes { $0.load(as: Int64.self) }
        if count == 0 {
            transaction.clear(key: key)
        }
    }
}
```
