import Foundation
import FoundationDB
import FDBCore
import Synchronization

/// FDBContext - Type-independent transaction context
///
/// Difference from RecordContext:
/// - RecordContext: Tracks typed records, type-safe change management, auto Directory resolution
/// - FDBContext: Type-independent, Data-based change tracking, explicit Subspace specification
///
/// **Responsibilities**:
/// - Change tracking (inserted, deleted) with Subspace
/// - Atomic save/delete operations
/// - Multiple Subspace support within single transaction
///
/// **Not Responsible** (implemented in upper layer fdb-record-layer):
/// - Type safety (wrapped by RecordContext)
/// - Directory auto-resolution (implemented in RecordContext)
/// - Autosave (implemented in RecordContext)
/// - ObjectIdentifier-based type tracking (implemented in RecordContext)
///
/// **Usage example**:
/// ```swift
/// let context = FDBContext(container: container)
/// let userSubspace = try await container.getOrOpenDirectory(path: ["users"])
/// let productSubspace = try await container.getOrOpenDirectory(path: ["products"])
///
/// // Insert items with explicit subspace
/// context.insert(
///     data: serializedData1,
///     for: "User",  // itemType
///     primaryKey: Tuple(1),
///     subspace: userSubspace
/// )
/// context.insert(
///     data: serializedData2,
///     for: "Product",  // itemType
///     primaryKey: Tuple(101),
///     subspace: productSubspace
/// )
///
/// // Save all changes atomically (single transaction, multiple subspaces)
/// try await context.save()
///
/// // Check for unsaved changes
/// if context.hasChanges {
///     try await context.save()
/// }
/// ```
public final class FDBContext: Sendable {
    // MARK: - Properties

    /// The container that owns this context
    public let container: FDBContainer

    /// Change tracking state
    private let stateLock: Mutex<ContextState>

    // MARK: - Initialization

    /// Initialize FDBContext
    ///
    /// - Parameters:
    ///   - container: The FDBContainer to use for storage
    ///   - autosaveEnabled: Whether to automatically save after insert/delete (default: false)
    public init(container: FDBContainer, autosaveEnabled: Bool = false) {
        self.container = container
        self.stateLock = Mutex(ContextState(autosaveEnabled: autosaveEnabled))
    }

    // MARK: - State

    private struct ContextState {
        /// Items pending insertion
        /// Key: (itemType, primaryKey) tuple
        /// Value: Serialized data
        var insertedItems: [ItemKey: Data] = [:]

        /// Items pending deletion
        /// Key: (itemType, primaryKey) tuple
        var deletedItems: Set<ItemKey> = []

        /// Whether a save operation is currently in progress
        var isSaving: Bool = false

        /// Whether to automatically save after insert/delete operations
        var autosaveEnabled: Bool

        /// Whether the context has unsaved changes
        var hasChanges: Bool {
            return !insertedItems.isEmpty || !deletedItems.isEmpty
        }

        init(autosaveEnabled: Bool = false) {
            self.autosaveEnabled = autosaveEnabled
        }
    }

    /// Internal key for tracking items with their subspace
    private struct ItemKey: Hashable {
        let itemType: String
        let primaryKey: Tuple
        let subspacePrefix: [UInt8]

        init(itemType: String, primaryKey: any TupleElement, subspace: Subspace) {
            self.itemType = itemType
            self.primaryKey = (primaryKey as? Tuple) ?? Tuple([primaryKey])
            self.subspacePrefix = subspace.prefix
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(itemType)
            hasher.combine(primaryKey.pack())
            hasher.combine(subspacePrefix)
        }

        static func == (lhs: ItemKey, rhs: ItemKey) -> Bool {
            return lhs.itemType == rhs.itemType &&
                   lhs.primaryKey.pack() == rhs.primaryKey.pack() &&
                   lhs.subspacePrefix == rhs.subspacePrefix
        }
    }

    // MARK: - Public API

    /// Whether the context has unsaved changes
    public var hasChanges: Bool {
        stateLock.withLock { state in
            state.hasChanges
        }
    }

    /// Whether to automatically save after insert/delete operations
    ///
    /// When enabled, insert() and delete() will automatically call save().
    /// When disabled (default), you must manually call save().
    public var autosaveEnabled: Bool {
        get {
            stateLock.withLock { state in
                state.autosaveEnabled
            }
        }
        set {
            stateLock.withLock { state in
                state.autosaveEnabled = newValue
            }
        }
    }

    /// Insert an item for later saving
    ///
    /// The item is not persisted until `save()` is called.
    ///
    /// - Parameters:
    ///   - data: Serialized item data
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    ///   - subspace: Subspace where the item will be stored
    public func insert(
        data: Data,
        for itemType: String,
        primaryKey: any TupleElement,
        subspace: Subspace
    ) {
        let key = ItemKey(itemType: itemType, primaryKey: primaryKey, subspace: subspace)

        stateLock.withLock { state in
            state.insertedItems[key] = data
            state.deletedItems.remove(key)  // Cancel delete if exists
        }
    }

    /// Delete an item for later removal
    ///
    /// The item is not removed until `save()` is called.
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value (Tuple or TupleElement)
    ///   - subspace: Subspace where the item is stored
    public func delete(
        for itemType: String,
        primaryKey: any TupleElement,
        subspace: Subspace
    ) {
        let key = ItemKey(itemType: itemType, primaryKey: primaryKey, subspace: subspace)

        stateLock.withLock { state in
            // If item was inserted but not saved, just remove it (cancel insert)
            // Otherwise, mark for deletion
            if state.insertedItems.removeValue(forKey: key) != nil {
                // Item was inserted in this context - just cancel the insert
                // No need to add to deletedItems since it doesn't exist in DB
            } else {
                // Item exists in DB - mark for deletion
                state.deletedItems.insert(key)
            }
        }
    }

    /// Save all pending changes atomically
    ///
    /// All insertions and deletions are executed in a single transaction.
    /// If any operation fails, all changes are rolled back.
    ///
    /// - Throws: FDBContextError.concurrentSaveNotAllowed if another save is in progress
    /// - Throws: Error if save fails
    public func save() async throws {
        // Get changes snapshot and clear changes atomically
        let (insertedSnapshot, deletedSnapshot) = stateLock.withLock { state -> ([ItemKey: Data], Set<ItemKey>) in
            guard state.hasChanges else {
                // No changes to save - return immediately
                return ([:], [])
            }

            // Take snapshot and clear changes atomically
            // This ensures concurrent saves see no changes and return early
            let inserted = state.insertedItems
            let deleted = state.deletedItems

            state.insertedItems.removeAll()
            state.deletedItems.removeAll()
            state.isSaving = true

            return (inserted, deleted)
        }

        // Early return if no changes
        guard !insertedSnapshot.isEmpty || !deletedSnapshot.isEmpty else {
            return
        }

        do {
            // Execute all operations in a single transaction
            try await container.withTransaction { transaction in
                // Cache stores by subspace prefix for efficiency
                var storeCache: [[UInt8]: FDBStore] = [:]

                // Process insertions
                for (key, data) in insertedSnapshot {
                    // Get or create store for this subspace
                    let store: FDBStore
                    if let cached = storeCache[key.subspacePrefix] {
                        store = cached
                    } else {
                        let subspace = Subspace(prefix: key.subspacePrefix)
                        store = container.store(for: subspace)
                        storeCache[key.subspacePrefix] = store
                    }

                    try store.save(
                        data: data,
                        for: key.itemType,
                        primaryKey: key.primaryKey,
                        transaction: transaction
                    )
                }

                // Process deletions
                for key in deletedSnapshot {
                    // Get or create store for this subspace
                    let store: FDBStore
                    if let cached = storeCache[key.subspacePrefix] {
                        store = cached
                    } else {
                        let subspace = Subspace(prefix: key.subspacePrefix)
                        store = container.store(for: subspace)
                        storeCache[key.subspacePrefix] = store
                    }

                    try store.delete(
                        for: key.itemType,
                        primaryKey: key.primaryKey,
                        transaction: transaction
                    )
                }
            }

            // Reset saving flag after successful save
            // Note: Changes were already cleared before transaction (line 214-215)
            stateLock.withLock { state in
                state.isSaving = false
            }
        } catch {
            // Restore changes on error (transaction failed, need to retry)
            stateLock.withLock { state in
                // Restore insertedItems
                for (key, data) in insertedSnapshot {
                    state.insertedItems[key] = data
                }
                // Restore deletedItems
                for key in deletedSnapshot {
                    state.deletedItems.insert(key)
                }
                state.isSaving = false
            }
            throw error
        }
    }

    /// Rollback all pending changes
    ///
    /// Clears the inserted and deleted item sets without persisting.
    public func rollback() {
        stateLock.withLock { state in
            state.insertedItems.removeAll()
            state.deletedItems.removeAll()
            state.isSaving = false
        }
    }

    /// Reset the context to initial state
    ///
    /// Equivalent to `rollback()`.
    public func reset() {
        rollback()
    }

    // MARK: - Fetch API

    /// Fetch items of a specific type from a subspace
    ///
    /// Returns an async sequence of (primaryKey, data) tuples.
    ///
    /// **Example**:
    /// ```swift
    /// let userSubspace = try await container.getOrOpenDirectory(path: ["users"])
    /// for try await (primaryKey, data) in context.fetch(for: "User", from: userSubspace) {
    ///     // Process each user
    ///     print("User \(primaryKey): \(data.count) bytes")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - subspace: Subspace to fetch from
    /// - Returns: Async sequence of (primaryKey: Tuple, data: Data) tuples
    public func fetch(
        for itemType: String,
        from subspace: Subspace
    ) -> AsyncThrowingStream<(primaryKey: Tuple, data: Data), Error> {
        let store = container.store(for: subspace)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await container.withTransaction { transaction in
                        let sequence = store.scan(for: itemType, transaction: transaction)

                        for try await (primaryKey, data) in sequence {
                            continuation.yield((primaryKey: primaryKey, data: data))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Fetch a single item by primary key
    ///
    /// **Example**:
    /// ```swift
    /// let userSubspace = try await container.getOrOpenDirectory(path: ["users"])
    /// if let data = try await context.fetch(for: "User", primaryKey: Tuple(123), from: userSubspace) {
    ///     // Process user data
    ///     print("User found: \(data.count) bytes")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - itemType: Item type name (e.g., "User")
    ///   - primaryKey: Primary key value
    ///   - subspace: Subspace to fetch from
    /// - Returns: Serialized data, or nil if not found
    /// - Throws: Error if fetch fails
    public func fetch(
        for itemType: String,
        primaryKey: any TupleElement,
        from subspace: Subspace
    ) async throws -> Data? {
        let store = container.store(for: subspace)
        return try await store.load(
            for: itemType,
            primaryKey: primaryKey
        )
    }

    // MARK: - Internal API (for upper layers)

    /// Insert an item with explicit store tracking
    ///
    /// **Internal use**: This method is used by upper layers to track
    /// items with their correct stores.
    ///
    /// - Parameters:
    ///   - data: Serialized item data
    ///   - itemType: Item type name
    ///   - primaryKey: Primary key value
    ///   - store: The FDBStore to use for this item
    internal func insertWithStore(
        data: Data,
        for itemType: String,
        primaryKey: any TupleElement,
        store: FDBStore
    ) {
        let key = ItemKey(itemType: itemType, primaryKey: primaryKey, subspace: store.subspace)

        stateLock.withLock { state in
            state.insertedItems[key] = data
            state.deletedItems.remove(key)
        }
    }

    /// Delete an item with explicit store tracking
    ///
    /// **Internal use**: This method is used by upper layers to track
    /// items with their correct stores.
    ///
    /// - Parameters:
    ///   - itemType: Item type name
    ///   - primaryKey: Primary key value
    ///   - store: The FDBStore to use for this item
    internal func deleteWithStore(
        for itemType: String,
        primaryKey: any TupleElement,
        store: FDBStore
    ) {
        let key = ItemKey(itemType: itemType, primaryKey: primaryKey, subspace: store.subspace)

        stateLock.withLock { state in
            state.deletedItems.insert(key)
            state.insertedItems.removeValue(forKey: key)
        }
    }
}

// MARK: - Errors

/// Errors that can occur during FDBContext operations
public enum FDBContextError: Error, CustomStringConvertible {
    /// Attempted to save while another save operation is in progress
    case concurrentSaveNotAllowed

    public var description: String {
        switch self {
        case .concurrentSaveNotAllowed:
            return "FDBContextError: Cannot save while another save operation is in progress"
        }
    }
}

// MARK: - CustomStringConvertible

extension FDBContext: CustomStringConvertible {
    public var description: String {
        let (insertedCount, deletedCount) = stateLock.withLock { state in
            (state.insertedItems.count, state.deletedItems.count)
        }

        return """
        FDBContext(
            insertedItems: \(insertedCount),
            deletedItems: \(deletedCount),
            hasChanges: \(hasChanges)
        )
        """
    }
}
