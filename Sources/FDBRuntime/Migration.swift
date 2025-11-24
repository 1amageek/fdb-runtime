import Foundation
import FoundationDB
import FDBIndexing

/// Migration Definition
///
/// Defines a schema migration from one version to another.
/// Migrations are applied automatically to evolve the schema and data over time.
///
/// **Migration Types**:
/// 1. **Index Migration**: Add/remove/rebuild indexes
/// 2. **Data Migration**: Transform item data
/// 3. **Schema Migration**: Change field types or constraints
///
/// **Example**:
/// ```swift
/// let migration = Migration(
///     fromVersion: Schema.Version(1, 0, 0),
///     toVersion: Schema.Version(2, 0, 0),
///     description: "Add email index"
/// ) { context in
///     // Add new index
///     let emailIndex = IndexDescriptor(
///         name: "email_index",
///         keyPaths: ["email"],
///         kind: ScalarIndexKind(),
///         commonOptions: .init()
///     )
///     try await context.addIndex(emailIndex)
/// }
/// ```
public struct Migration: Sendable {
    // MARK: - Properties

    /// Source schema version
    public let fromVersion: Schema.Version

    /// Target schema version
    public let toVersion: Schema.Version

    /// Human-readable description of this migration
    public let description: String

    /// Migration execution function
    public let execute: @Sendable (MigrationContext) async throws -> Void

    // MARK: - Initialization

    /// Initialize a migration
    ///
    /// - Parameters:
    ///   - fromVersion: Source schema version
    ///   - toVersion: Target schema version
    ///   - description: Description of the migration
    ///   - execute: Migration execution closure
    public init(
        fromVersion: Schema.Version,
        toVersion: Schema.Version,
        description: String,
        execute: @escaping @Sendable (MigrationContext) async throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.description = description
        self.execute = execute
    }
}

// MARK: - Migration Context

/// Context provided to migrations during execution
///
/// Provides access to database operations and migration utilities.
public struct MigrationContext: Sendable {
    // MARK: - Properties

    /// Database instance
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// Schema being migrated to
    public let schema: Schema

    /// Metadata subspace for storing migration progress
    public let metadataSubspace: Subspace

    /// Type-erased store registry
    ///
    /// Maps item type names to their corresponding FDBStores.
    private let storeRegistry: [String: FDBStore]

    // MARK: - Initialization

    internal init(
        database: any DatabaseProtocol,
        schema: Schema,
        metadataSubspace: Subspace,
        storeRegistry: [String: FDBStore]
    ) {
        self.database = database
        self.schema = schema
        self.metadataSubspace = metadataSubspace
        self.storeRegistry = storeRegistry
    }

    // MARK: - Store Access

    /// Get FDBStore for an item type
    ///
    /// - Parameter itemType: Item type name
    /// - Returns: FDBStore
    /// - Throws: Error if store not found
    public func store(for itemType: String) throws -> FDBStore {
        guard let store = storeRegistry[itemType] else {
            throw FDBRuntimeError.invalidArgument(
                "FDBStore for '\(itemType)' not found in registry. " +
                "Available stores: \(storeRegistry.keys.sorted().joined(separator: ", "))"
            )
        }
        return store
    }

    // MARK: - Index Operations

    /// Add a new index and build it online
    ///
    /// **Important Constraint**:
    /// - Index names **must be unique across all entities** in the schema
    /// - This allows `identifyTargetEntity()` to unambiguously match an index to its owner
    /// - If multiple entities have indexes with the same name, an error is thrown
    ///
    /// **Implementation**:
    /// 1. Identify target entity from index name or keyPaths
    /// 2. Convert IndexDescriptor to Index with proper itemTypes
    /// 3. Register index with IndexManager for target entity store only
    /// 4. Enable index (sets to writeOnly via IndexStateManager)
    /// 5. Build index (via OnlineIndexer - TODO)
    /// 6. Mark as readable (via IndexStateManager - TODO, after build completes)
    ///
    /// **Current Limitation**:
    /// - Index is left in writeOnly state (not readable)
    /// - OnlineIndexer integration is required to complete the build and transition to readable
    ///
    /// - Parameter indexDescriptor: The index descriptor to add
    /// - Throws: Error if index addition fails or target entity cannot be determined
    public func addIndex(_ indexDescriptor: IndexDescriptor) async throws {
        // 1. Identify target entity from Schema
        let targetEntity = try identifyTargetEntity(for: indexDescriptor)

        // 2. Get store for target entity
        guard let store = storeRegistry[targetEntity.name] else {
            throw FDBRuntimeError.internalError(
                "FDBStore for entity '\(targetEntity.name)' not found in registry. " +
                "Available stores: \(storeRegistry.keys.sorted().joined(separator: ", "))"
            )
        }

        let indexManager = IndexManager(
            database: database,
            subspace: store.indexSubspace
        )

        // 3. Convert IndexDescriptor to Index with itemTypes
        let index = try convertDescriptorToIndex(
            indexDescriptor,
            itemTypes: Set([targetEntity.name])
        )

        // 4. Register index (in-memory, fails if already registered)
        do {
            try indexManager.register(index: index)
        } catch IndexManagerError.duplicateIndex {
            // Index already registered in this IndexManager instance - OK
            // This can happen if migration is run multiple times
        }

        // 5. Enable index (disabled → writeOnly)
        // Check current state first to ensure idempotency
        let currentState = try await indexManager.state(of: index.name)

        switch currentState {
        case .disabled:
            // Normal case: enable the index
            try await indexManager.enable(index.name)
        case .writeOnly, .readable:
            // Index already enabled/built - skip (idempotent operation)
            // This can happen if:
            // - Migration is run multiple times
            // - Index was manually enabled before migration
            break
        }

        // TODO: Build index via OnlineIndexer
        // Until OnlineIndexer is integrated, index remains in writeOnly state
        // This prevents empty indexes from being marked readable
        //
        // ⚠️ IMPORTANT: Index is now in writeOnly state (NOT queryable)
        // Queries will NOT use this index until OnlineIndexer builds it.
        // Required steps to make queryable:
        //   1. Implement OnlineIndexer integration here
        //   2. Build the index with OnlineIndexer
        //   3. Call: indexManager.makeReadable(index.name)

        // FUTURE: After OnlineIndexer builds the index
        // try await indexManager.makeReadable(index.name)
    }

    /// Remove an index and add FormerIndex entry
    ///
    /// **Implementation**:
    /// 1. Identify target entity from Schema
    /// 2. Create FormerIndex metadata entry
    /// 3. Disable index (via IndexStateManager)
    /// 4. Clear all index data (range clear)
    ///
    /// - Parameters:
    ///   - indexName: Name of the index to remove
    ///   - addedVersion: Version when index was originally added
    /// - Throws: Error if index removal fails or index not found in schema
    public func removeIndex(
        indexName: String,
        addedVersion: Schema.Version
    ) async throws {
        // 1. Find index descriptor in schema to identify target entity
        guard let indexDescriptor = schema.indexDescriptor(named: indexName) else {
            throw FDBRuntimeError.indexNotFound(
                "Index '\(indexName)' not found in schema. Cannot determine target entity."
            )
        }

        // 2. Identify target entity
        let targetEntity = try identifyTargetEntity(for: indexDescriptor)

        // 3. Get store for target entity
        guard let store = storeRegistry[targetEntity.name] else {
            throw FDBRuntimeError.internalError(
                "FDBStore for entity '\(targetEntity.name)' not found in registry"
            )
        }

        // 4. Create FormerIndex entry
        let formerIndexKey = store.subspace
            .subspace("storeInfo")
            .subspace("formerIndexes")
            .pack(Tuple(indexName))

        try await database.withTransaction { transaction in
            let timestamp = Date().timeIntervalSince1970
            transaction.setValue(
                Tuple(
                    Int64(addedVersion.major),
                    Int64(addedVersion.minor),
                    Int64(addedVersion.patch),
                    timestamp
                ).pack(),
                for: formerIndexKey
            )
        }

        // 5. Disable index
        let indexManager = IndexManager(
            database: database,
            subspace: store.indexSubspace
        )
        try await indexManager.disable(indexName)

        // 6. Clear index data
        let indexRange = store.indexSubspace.subspace(indexName).range()
        try await database.withTransaction { transaction in
            transaction.clearRange(
                beginKey: indexRange.begin,
                endKey: indexRange.end
            )
        }
    }

    /// Rebuild an existing index
    ///
    /// **Implementation**:
    /// 1. Identify target entity from Schema
    /// 2. Disable index (via IndexStateManager)
    /// 3. Clear existing index data (range clear)
    /// 4. Re-register index with proper itemTypes
    /// 5. Enable index (→ writeOnly state)
    /// 6. Build index (via OnlineIndexer - TODO)
    ///
    /// **Current Limitation**:
    /// - Index is left in writeOnly state (not readable)
    /// - OnlineIndexer integration is required to complete the rebuild
    ///
    /// - Parameter indexName: Name of the index to rebuild
    /// - Throws: Error if rebuild fails or index not found in schema
    public func rebuildIndex(indexName: String) async throws {
        // 1. Find index descriptor in schema
        guard let indexDescriptor = schema.indexDescriptor(named: indexName) else {
            throw FDBRuntimeError.indexNotFound(
                "Index '\(indexName)' not found in schema"
            )
        }

        // 2. Identify target entity
        let targetEntity = try identifyTargetEntity(for: indexDescriptor)

        // 3. Get store for target entity
        guard let store = storeRegistry[targetEntity.name] else {
            throw FDBRuntimeError.internalError(
                "FDBStore for entity '\(targetEntity.name)' not found in registry"
            )
        }

        let indexManager = IndexManager(
            database: database,
            subspace: store.indexSubspace
        )

        // 4. Disable index
        try await indexManager.disable(indexName)

        // 5. Clear existing data
        let indexRange = store.indexSubspace.subspace(indexName).range()
        try await database.withTransaction { transaction in
            transaction.clearRange(
                beginKey: indexRange.begin,
                endKey: indexRange.end
            )
        }

        // 6. Re-register index with itemTypes
        let index = try convertDescriptorToIndex(
            indexDescriptor,
            itemTypes: Set([targetEntity.name])
        )
        do {
            try indexManager.register(index: index)
        } catch IndexManagerError.duplicateIndex {
            // Index already registered - OK
        }

        // 7. Enable index (→ writeOnly state)
        // Should always succeed since we just disabled it, but check for safety
        let currentState = try await indexManager.state(of: indexName)
        if currentState == .disabled {
            try await indexManager.enable(indexName)
        }

        // TODO: Build index via OnlineIndexer
        // Until OnlineIndexer is integrated, index remains in writeOnly state

        // FUTURE: After OnlineIndexer rebuilds the index
        // try await indexManager.makeReadable(indexName)
    }

    // MARK: - Utility

    /// Execute arbitrary database operation
    ///
    /// - Parameter operation: Operation to execute
    /// - Returns: Operation result
    /// - Throws: Any error from the operation
    public func executeOperation<T: Sendable>(
        _ operation: @escaping @Sendable (any TransactionProtocol) async throws -> T
    ) async throws -> T {
        return try await database.withTransaction { transaction in
            try await operation(transaction)
        }
    }

    // MARK: - Private Helpers

    /// Identify target entity for an index descriptor
    ///
    /// This method matches an IndexDescriptor to its corresponding entity in the Schema
    /// by checking which entity contains this index in its indexDescriptors.
    ///
    /// - Parameter descriptor: IndexDescriptor to match
    /// - Returns: Target entity
    /// - Throws: Error if no entity owns this index or multiple entities claim it
    private func identifyTargetEntity(for descriptor: IndexDescriptor) throws -> Schema.Entity {
        var matchingEntities: [Schema.Entity] = []

        for entity in schema.entities {
            // Check if this entity contains the descriptor
            if entity.indexDescriptors.contains(where: { $0.name == descriptor.name }) {
                matchingEntities.append(entity)
            }
        }

        guard !matchingEntities.isEmpty else {
            throw FDBRuntimeError.indexNotFound(
                "Index '\(descriptor.name)' is not associated with any entity in schema. " +
                "Available entities: \(schema.entities.map { $0.name }.joined(separator: ", "))"
            )
        }

        guard matchingEntities.count == 1 else {
            throw FDBRuntimeError.internalError(
                "Index '\(descriptor.name)' is associated with multiple entities: " +
                "\(matchingEntities.map { $0.name }.joined(separator: ", ")). " +
                "Index names must be unique across all entities."
            )
        }

        return matchingEntities[0]
    }

    /// Convert IndexDescriptor to Index with itemTypes
    ///
    /// This converts metadata-only IndexDescriptor to runtime Index objects.
    ///
    /// - Parameters:
    ///   - descriptor: IndexDescriptor from schema
    ///   - itemTypes: Set of item type names that this index applies to
    /// - Returns: Index object
    /// - Throws: Error if conversion fails
    private func convertDescriptorToIndex(
        _ descriptor: IndexDescriptor,
        itemTypes: Set<String>
    ) throws -> Index {
        // Build KeyExpression from field names
        let keyExpression: KeyExpression

        if descriptor.keyPaths.count == 1 {
            // Single field index
            keyExpression = FieldKeyExpression(fieldName: descriptor.keyPaths[0])
        } else {
            // Composite index
            keyExpression = ConcatenateKeyExpression(
                children: descriptor.keyPaths.map { FieldKeyExpression(fieldName: $0) }
            )
        }

        // Create Index with proper itemTypes scope
        return Index(
            name: descriptor.name,
            kind: descriptor.kind,
            rootExpression: keyExpression,
            subspaceKey: descriptor.name,
            itemTypes: itemTypes  // Scoped to specific entity
        )
    }
}

// MARK: - Migration Extensions

extension Migration: Identifiable {
    public var id: String {
        return "\(fromVersion)-\(toVersion)"
    }
}

// MARK: - FDBRuntimeError

/// FDBRuntime error types
public enum FDBRuntimeError: Error, CustomStringConvertible {
    /// Invalid argument
    case invalidArgument(String)

    /// Index not found
    case indexNotFound(String)

    /// Internal error
    case internalError(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .indexNotFound(let message):
            return "Index not found: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
