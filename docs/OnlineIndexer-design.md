# OnlineIndexer Design

## Overview

OnlineIndexer provides batch index building infrastructure for FDBRuntime. It supports both standard scan-based builds (for most index types) and custom build strategies (e.g., HNSW bulk construction).

## Architecture

### Layered Design

```
┌─────────────────────────────────────────────────────────────┐
│ FDBIndexing (Protocols)                                     │
│  ├── IndexBuildStrategy<Item>: Protocol for custom builds  │
│  └── IndexMaintainer.customBuildStrategy: Optional property│
└─────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ FDBRuntime (Infrastructure)                                 │
│  ├── OnlineIndexer<Item>: Batch index builder              │
│  ├── RangeSet: Progress tracking for resumable builds      │
│  └── IndexStateManager: State transitions (writeOnly→readable)│
└─────────────────────────────────────────────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ fdb-indexes (Implementations)                               │
│  ├── ScalarIndexMaintainer                                  │
│  │   └── customBuildStrategy = nil (standard build)         │
│  ├── CountIndexMaintainer                                   │
│  │   └── customBuildStrategy = nil (standard build)         │
│  └── HNSWIndexMaintainer                                    │
│      └── customBuildStrategy = HNSWBuildStrategy()          │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Principles

1. **No Direct Dependencies**: FDBRuntime does not depend on fdb-indexes
2. **Protocol-Based Extension**: Custom build strategies via `IndexBuildStrategy` protocol
3. **Default Behavior**: Most indexes use standard scan-based build (no custom strategy needed)
4. **Type Safety**: Generics ensure compile-time type checking
5. **Resumable Builds**: RangeSet tracks progress across transactions

## Components

### 1. IndexBuildStrategy Protocol (FDBIndexing)

**Location**: `Sources/FDBIndexing/IndexBuildStrategy.swift`

**Purpose**: Define interface for custom index build strategies

```swift
public protocol IndexBuildStrategy<Item>: Sendable {
    associatedtype Item: Sendable

    func buildIndex(
        database: any DatabaseProtocol,
        itemSubspace: Subspace,
        indexSubspace: Subspace,
        itemType: String,
        index: Index,
        dataAccess: any DataAccess<Item>
    ) async throws
}
```

**When to Use**:
- Index requires bulk construction (e.g., HNSW graph)
- Standard item-by-item scanning is inefficient
- Need access to all data at once

**When NOT to Use**:
- Standard VALUE indexes (ScalarIndexMaintainer)
- Aggregation indexes (COUNT, SUM, AVG)
- Indexes that can be built incrementally

### 2. IndexMaintainer Extension (FDBIndexing)

**Location**: `Sources/FDBIndexing/IndexMaintainer.swift`

**Addition**: Optional `customBuildStrategy` property

```swift
public protocol IndexMaintainer<Item>: Sendable {
    // Existing methods
    func updateIndex(...) async throws
    func scanItem(...) async throws

    // New property
    var customBuildStrategy: (any IndexBuildStrategy<Item>)? { get }
}

extension IndexMaintainer {
    // Default: no custom strategy
    public var customBuildStrategy: (any IndexBuildStrategy<Item>)? { nil }
}
```

### 3. OnlineIndexer (FDBRuntime)

**Location**: `Sources/FDBRuntime/OnlineIndexer.swift`

**Purpose**: Batch index building with progress tracking

**Key Features**:
- Delegates to `IndexBuildStrategy` if provided
- Falls back to standard scan-based build
- RangeSet-based progress tracking (resumable)
- Batch processing with throttling
- State management (writeOnly → readable)

**Usage Flow**:

```
Migration.addIndex()
    ↓
IndexManager.makeOnlineIndexer()
    ↓
OnlineIndexer.buildIndex()
    ├─→ Has customBuildStrategy?
    │   ├─ Yes → customStrategy.buildIndex()
    │   └─ No  → buildIndexInBatches()
    ↓
IndexStateManager.makeReadable()
```

### 4. RangeSet (FDBRuntime)

**Location**: `Sources/FDBRuntime/RangeSet.swift`

**Purpose**: Track progress for resumable builds

**Key Features**:
- Codable (persisted to FDB)
- Tracks completed ranges
- Provides next batch for processing
- Handles transaction boundaries

**Storage**:
```
[indexSubspace]["_progress"][indexName] = RangeSet (JSON)
```

### 5. HNSWBuildStrategy (fdb-indexes)

**Location**: `fdb-indexes/Sources/VectorIndexLayer/HNSWBuildStrategy.swift`

**Purpose**: Efficient bulk HNSW graph construction

**Algorithm**:
1. Load all vectors from item storage (single scan)
2. Save vectors to flat index (batch write)
3. Build HNSW graph in batches (avoid timeout)

**Why Custom Strategy Needed**:
- HNSW insertion is O(log n) per node
- Nested loops in pruning logic cause high transaction ops
- Standard scan-based build causes timeouts for large graphs
- Bulk construction is more efficient

## Implementation Details

### Standard Scan-Based Build

**Used by**: ScalarIndexMaintainer, CountIndexMaintainer, etc.

**Process**:
```
1. Get item range: [R]/[itemType]/*
2. Create RangeSet from range
3. Loop until RangeSet is empty:
   a. Get next batch (e.g., 100 items)
   b. For each item in batch:
      - Deserialize item
      - Call indexMaintainer.scanItem()
   c. Mark batch as completed in RangeSet
   d. Save progress to FDB
   e. Throttle if configured
4. Clear progress after completion
5. Transition to readable state
```

**Transaction Budget**: Low per item (~10-20 ops)

### Custom HNSW Build

**Used by**: HNSWIndexMaintainer only

**Process**:
```
1. Scan all items, extract vectors (read-only transaction)
2. Save all vectors to flat index (batch write)
3. Build HNSW graph in batches:
   - Batch size: 50 items (smaller due to complexity)
   - Each batch: insert nodes into graph
   - Avoids timeout by splitting work
4. Transition to readable state
```

**Transaction Budget**: High per item (~3000-12000 ops depending on graph level)

## Integration Points

### Migration.addIndex()

**Location**: `Sources/FDBRuntime/Migration.swift`

**Integration**:
```swift
public func addIndex(_ indexDescriptor: IndexDescriptor) async throws {
    // ... existing code ...

    // Enable index (disabled → writeOnly)
    try await indexManager.enable(index.name)

    // Build index using OnlineIndexer
    let onlineIndexer = try indexManager.makeOnlineIndexer(
        for: index.name,
        itemType: targetEntity.name,
        batchSize: 100
    )
    try await onlineIndexer.buildIndex(clearFirst: false)

    // State transition (writeOnly → readable) handled by OnlineIndexer
}
```

### IndexManager Factory

**Location**: `Sources/FDBRuntime/IndexManager.swift`

**New Method**:
```swift
extension IndexManager {
    public func makeOnlineIndexer<Item: Sendable>(
        for indexName: String,
        itemType: String,
        batchSize: Int = 100,
        throttleDelayMs: Int = 0
    ) throws -> OnlineIndexer<Item> {
        // Get index
        guard let index = registeredIndexes[indexName] else {
            throw IndexManagerError.indexNotFound(indexName)
        }

        // TODO: Get DataAccess and IndexMaintainer from LayerConfiguration
        // For now, this requires upper layer integration

        return OnlineIndexer(
            database: database,
            itemSubspace: itemSubspace,
            indexSubspace: indexSubspace,
            itemType: itemType,
            index: index,
            dataAccess: dataAccess,
            indexMaintainer: indexMaintainer,
            indexStateManager: indexStateManager,
            batchSize: batchSize,
            throttleDelayMs: throttleDelayMs
        )
    }
}
```

## Future Work

### LayerConfiguration Integration

**Goal**: Type-erased factory for OnlineIndexer creation

**Challenge**: OnlineIndexer is generic over `Item: Sendable`

**Approach**:
```swift
public protocol LayerConfiguration: Sendable {
    func makeOnlineIndexer(
        for index: Index,
        itemType: String,
        database: any DatabaseProtocol,
        itemSubspace: Subspace,
        indexSubspace: Subspace,
        indexStateManager: IndexStateManager,
        batchSize: Int,
        throttleDelayMs: Int
    ) throws -> any OnlineIndexerProtocol
}

public protocol OnlineIndexerProtocol: Sendable {
    func buildIndex(clearFirst: Bool) async throws
}

extension OnlineIndexer: OnlineIndexerProtocol { }
```

This allows IndexManager to create OnlineIndexer without knowing the concrete Item type.

## Testing Strategy

### Unit Tests (FDBRuntime)

**Location**: `Tests/FDBRuntimeTests/OnlineIndexerTests.swift`

**Coverage**:
- Standard scan-based build with mock IndexMaintainer
- Progress tracking with RangeSet
- Resumable builds (interrupted and resumed)
- State transitions (writeOnly → readable)
- Throttling behavior
- Error handling

### Integration Tests (fdb-indexes)

**Location**: `Tests/VectorIndexLayerTests/HNSWBuildStrategyTests.swift`

**Coverage**:
- HNSW bulk build with real data
- Large graph construction (1000+ vectors)
- Verify graph correctness after build
- Compare with incremental build (if applicable)
- Performance benchmarks

## Performance Considerations

### Standard Build

- **Batch size**: 100 items (configurable)
- **Transaction timeout**: ~5 seconds per batch
- **Memory**: O(batchSize) - bounded
- **Throughput**: ~1000-5000 items/second (depending on index complexity)

### HNSW Build

- **Batch size**: 50 nodes (smaller due to complexity)
- **Transaction timeout**: ~5 seconds per batch
- **Memory**: O(totalVectors) initially, then O(batchSize)
- **Throughput**: ~10-50 nodes/second (depending on graph size and parameters)

### Throttling

- `throttleDelayMs = 0`: No delay (maximum throughput)
- `throttleDelayMs > 0`: Adds delay between batches (reduces FDB load)
- Recommended: 10-100ms for large builds in production

## Error Handling

### Recoverable Errors

- **Transaction conflicts**: Retry automatically (via `withTransaction`)
- **Timeout**: Progress saved, resume from last batch
- **Network errors**: Progress saved, resume from last batch

### Non-Recoverable Errors

- **Invalid data**: Abort build, report error
- **Index validation failure**: Abort build, report error
- **Insufficient permissions**: Abort build, report error

**Recovery**: Clear progress, fix data, restart build

## Example Usage

### Standard Index (Scalar)

```swift
// In Migration
let emailIndex = IndexDescriptor(
    name: "User_email",
    keyPaths: ["email"],
    kind: try IndexKind(ScalarIndexKind()),
    commonOptions: .init()
)

try await context.addIndex(emailIndex)
// OnlineIndexer uses standard scan-based build automatically
```

### HNSW Index (Custom Build)

```swift
// In Migration
let embeddingIndex = IndexDescriptor(
    name: "Product_embedding",
    keyPaths: ["embedding"],
    kind: try IndexKind(VectorIndexKind(
        dimensions: 384,
        metric: .cosine,
        algorithm: .hnsw(HNSWParameters(m: 16, efConstruction: 200))
    )),
    commonOptions: .init()
)

try await context.addIndex(embeddingIndex)
// OnlineIndexer detects HNSWBuildStrategy and uses custom build
```

## Migration Path

### Phase 1: Basic Implementation (Current)
- Implement IndexBuildStrategy protocol
- Implement OnlineIndexer with standard build
- Add RangeSet for progress tracking
- Integrate with Migration.addIndex()

### Phase 2: HNSW Integration
- Implement HNSWBuildStrategy in fdb-indexes
- Add customBuildStrategy to HNSWIndexMaintainer
- Test bulk HNSW builds

### Phase 3: LayerConfiguration Integration
- Add OnlineIndexerProtocol for type erasure
- Integrate with LayerConfiguration factory
- Remove manual DataAccess/IndexMaintainer passing

### Phase 4: Advanced Features
- Parallel batch processing
- Progress reporting (percentage complete)
- Build statistics (items/second, ETA)
- Cancellation support
