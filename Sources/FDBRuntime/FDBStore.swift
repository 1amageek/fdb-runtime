import Foundation
import FoundationDB
import FDBIndexing
import Logging

/// FDBStore - Type-independent generic data store
///
/// Difference from RecordStore:
/// - RecordStore<Record: Recordable>: Typed, type-safe
/// - FDBStore: Type-independent, handles Data directly
///
/// **Responsibilities**:
/// - Basic CRUD operations (save, load, delete)
/// - Subspace management (records, indexes)
/// - Transaction execution
///
/// **Not Responsible** (implemented in upper layer fdb-record-layer):
/// - Index updates (uses IndexManager)
/// - Type safety (wrapped by RecordStore)
/// - Query execution (uses QueryPlanner)
///
/// **Usage example**:
/// ```swift
/// let store = FDBStore(
///     database: database,
///     subspace: subspace,
///     logger: logger
/// )
///
/// // Save (type-independent)
/// try await store.save(
///     data: serializedData,
///     for: "User",  // itemType
///     primaryKey: Tuple(123)
/// )
///
/// // Load
/// if let data = try await store.load(
///     for: "User",  // itemType
///     primaryKey: Tuple(123)
/// ) {
///     let item = try deserialize(data)
/// }
///
/// // Delete
/// try await store.delete(
///     for: "User",  // itemType
///     primaryKey: Tuple(123)
/// )
/// ```
public final class FDBStore: Sendable {
    // MARK: - Properties

    /// Database connection (thread-safe in FoundationDB)
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// Root subspace for this store
    public let subspace: Subspace

    /// Logger
    private let logger: Logger

    // MARK: - Subspaces

    /// Items subspace: [subspace]/R/[itemType]/[primaryKey] = data
    public let itemSubspace: Subspace

    /// Indexes subspace: [subspace]/I/[indexName]/... = ''
    public let indexSubspace: Subspace

    // MARK: - Initialization

    /// Initialize FDBStore
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - subspace: The root subspace for this store
    ///   - logger: Optional logger
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace,
        logger: Logger? = nil
    ) {
        self.database = database
        self.subspace = subspace
        self.logger = logger ?? Logger(label: "com.fdb.runtime.store")

        // Initialize subspaces
        self.itemSubspace = subspace.subspace("R")  // Items (kept "R" for backward compatibility)
        self.indexSubspace = subspace.subspace("I")    // Indexes
    }

    // MARK: - CRUD Operations

    /// Save data with explicit transaction
    ///
    /// - Parameters:
    ///   - data: Serialized item data
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    ///   - transaction: Transaction to use
    /// - Throws: Error if save fails
    public func save(
        data: Data,
        for itemType: String,
        primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) throws {
        let effectiveSubspace = itemSubspace.subspace(itemType)
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.pack(keyTuple)

        transaction.setValue(Array(data), for: key)
    }

    /// Save data (creates new transaction)
    ///
    /// - Parameters:
    ///   - data: Serialized item data
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    /// - Throws: Error if save fails
    public func save(
        data: Data,
        for itemType: String,
        primaryKey: any TupleElement
    ) async throws {
        try await database.withTransaction { transaction in
            try self.save(
                data: data,
                for: itemType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    /// Load data with explicit transaction
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    ///   - transaction: Transaction to use
    /// - Returns: Serialized item data, or nil if not found
    /// - Throws: Error if load fails
    public func load(
        for itemType: String,
        primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) async throws -> Data? {
        let effectiveSubspace = itemSubspace.subspace(itemType)
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.pack(keyTuple)

        if let bytes = try await transaction.getValue(for: key, snapshot: false) {
            return Data(bytes)
        }
        return nil
    }

    /// Load data (creates new transaction)
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    /// - Returns: Serialized item data, or nil if not found
    /// - Throws: Error if load fails
    public func load(
        for itemType: String,
        primaryKey: any TupleElement
    ) async throws -> Data? {
        try await database.withTransaction { transaction in
            try await self.load(
                for: itemType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    /// Delete data with explicit transaction
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    ///   - transaction: Transaction to use
    /// - Throws: Error if delete fails
    public func delete(
        for itemType: String,
        primaryKey: any TupleElement,
        transaction: any TransactionProtocol
    ) throws {
        let effectiveSubspace = itemSubspace.subspace(itemType)
        let keyTuple = (primaryKey as? Tuple) ?? Tuple([primaryKey])
        let key = effectiveSubspace.pack(keyTuple)

        transaction.clear(key: key)
    }

    /// Delete data (creates new transaction)
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    /// - Throws: Error if delete fails
    public func delete(
        for itemType: String,
        primaryKey: any TupleElement
    ) async throws {
        try await database.withTransaction { transaction in
            try self.delete(
                for: itemType,
                primaryKey: primaryKey,
                transaction: transaction
            )
        }
    }

    // MARK: - Transaction Support

    /// Execute a closure with a database transaction
    ///
    /// - Parameter operation: Closure that receives a TransactionProtocol
    /// - Returns: The result of the operation
    /// - Throws: Any error thrown by the operation
    public func withTransaction<T: Sendable>(
        _ operation: @Sendable (any TransactionProtocol) async throws -> T
    ) async throws -> T {
        return try await database.withTransaction(operation)
    }

    // MARK: - Range Operations

    /// Scan all items of a specific type with explicit transaction
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - transaction: Transaction to use
    /// - Returns: AsyncSequence of (primaryKey: Tuple, data: Data) pairs
    public func scan(
        for itemType: String,
        transaction: any TransactionProtocol
    ) -> AsyncThrowingStream<(primaryKey: Tuple, data: Data), Error> {
        let effectiveSubspace = itemSubspace.subspace(itemType)
        let (begin, end) = effectiveSubspace.range()

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await (key, value) in transaction.getRange(
                        beginSelector: .firstGreaterOrEqual(begin),
                        endSelector: .firstGreaterOrEqual(end),
                        snapshot: true
                    ) {
                        // Extract primary key from key
                        // Key format: [itemSubspace]/[itemType]/[primaryKey]
                        // We need to unpack the primaryKey portion
                        guard let unpacked = try? effectiveSubspace.unpack(key) else {
                            continue
                        }

                        continuation.yield((primaryKey: unpacked, data: Data(value)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Clear all items of a specific type with explicit transaction
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - transaction: Transaction to use
    /// - Throws: Error if clear fails
    public func clear(
        for itemType: String,
        transaction: any TransactionProtocol
    ) throws {
        let effectiveSubspace = itemSubspace.subspace(itemType)
        let (begin, end) = effectiveSubspace.range()

        transaction.clearRange(beginKey: begin, endKey: end)
    }

    /// Clear all items of a specific type (creates new transaction)
    ///
    /// - Parameter itemType: Item type name (e.g., "User")
    /// - Throws: Error if clear fails
    public func clear(for itemType: String) async throws {
        try await database.withTransaction { transaction in
            try self.clear(for: itemType, transaction: transaction)
        }
    }
}
