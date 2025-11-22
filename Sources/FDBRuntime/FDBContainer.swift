import Foundation
import FoundationDB
import Synchronization
import Logging

/// FDBContainer - Type-independent generic container
///
/// Difference from RecordContainer:
/// - RecordContainer: Schema-dependent, manages typed RecordStore
/// - FDBContainer: Schema-independent, manages type-independent FDBStore
///
/// **Responsibilities**:
/// - FDBStore lifecycle management (creation, caching)
/// - DirectoryLayer singleton management
/// - Database connection management
///
/// **Not Responsible** (implemented in upper layer fdb-record-layer):
/// - Schema management (implemented in RecordContainer)
/// - Migration execution (implemented in MigrationManager)
/// - StatisticsManager management (implemented in RecordContainer)
///
/// **Usage example**:
/// ```swift
/// let container = FDBContainer(
///     database: database,
///     logger: logger
/// )
///
/// // Get or create store for a specific subspace
/// let store = container.store(for: subspace)
///
/// // Use the store
/// try await store.save(
///     data: serializedData,
///     for: "User",  // itemType
///     primaryKey: Tuple(123)
/// )
/// ```
public final class FDBContainer: Sendable {
    // MARK: - Properties

    /// Database connection (thread-safe in FoundationDB)
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// DirectoryLayer instance (created once, reused for all operations)
    private let directoryLayer: DirectoryLayer

    /// Logger
    private let logger: Logger

    /// FDBStore cache
    /// Key: Subspace (identified by prefix bytes)
    /// Value: FDBStore instance
    private let storeCache: Mutex<[Data: FDBStore]>

    // MARK: - Initialization

    /// Initialize FDBContainer
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - directoryLayer: Optional custom DirectoryLayer (for test isolation)
    ///   - logger: Optional logger
    ///
    /// **DirectoryLayer Parameter**:
    ///
    /// The `directoryLayer` parameter is for test isolation.
    /// - `nil` (default): Creates default DirectoryLayer with `database.makeDirectoryLayer()`
    /// - non-nil: Uses custom DirectoryLayer (isolated subspace for testing)
    ///
    /// ```swift
    /// // Production environment: Default DirectoryLayer
    /// let container = FDBContainer(database: database)
    ///
    /// // Test environment: Isolated subspace
    /// let testSubspace = Subspace(prefix: Tuple("test", UUID().uuidString).pack())
    /// let testDirectoryLayer = DirectoryLayer(
    ///     database: database,
    ///     nodeSubspace: testSubspace.subspace(0xFE),
    ///     contentSubspace: testSubspace
    /// )
    /// let container = FDBContainer(
    ///     database: database,
    ///     directoryLayer: testDirectoryLayer
    /// )
    /// ```
    public init(
        database: any DatabaseProtocol,
        directoryLayer: DirectoryLayer? = nil,
        logger: Logger? = nil
    ) {
        self.database = database
        self.logger = logger ?? Logger(label: "com.fdb.runtime.container")
        self.storeCache = Mutex([:])

        // Initialize DirectoryLayer (singleton pattern)
        if let customLayer = directoryLayer {
            self.directoryLayer = customLayer
        } else {
            self.directoryLayer = database.makeDirectoryLayer()
        }
    }

    // MARK: - Store Management

    /// Get or create FDBStore for a specific subspace
    ///
    /// Stores are cached by subspace prefix to avoid creating multiple instances
    /// for the same subspace.
    ///
    /// - Parameter subspace: The subspace for the store
    /// - Returns: FDBStore instance (cached or newly created)
    public func store(for subspace: Subspace) -> FDBStore {
        let cacheKey = Data(subspace.prefix)

        return storeCache.withLock { cache in
            if let existing = cache[cacheKey] {
                return existing
            }

            let newStore = FDBStore(
                database: database,
                subspace: subspace,
                logger: logger
            )
            cache[cacheKey] = newStore
            return newStore
        }
    }

    // MARK: - Directory Operations

    /// Get or open a directory path
    ///
    /// Directories are managed by DirectoryLayer for efficient key prefix allocation.
    ///
    /// - Parameters:
    ///   - path: Directory path components (e.g., ["app", "users"])
    ///   - layer: Optional directory layer type
    /// - Returns: Subspace for the directory
    /// - Throws: Error if directory operation fails
    public func getOrOpenDirectory(
        path: [String],
        layer: DirectoryType? = nil
    ) async throws -> Subspace {
        let dirSubspace = try await directoryLayer.createOrOpen(
            path: path,
            type: layer
        )
        return dirSubspace.subspace
    }

    /// Create a new directory (fails if already exists)
    ///
    /// - Parameters:
    ///   - path: Directory path components
    ///   - layer: Optional directory layer type
    ///   - prefix: Optional custom prefix
    /// - Returns: Subspace for the directory
    /// - Throws: Error if directory already exists or creation fails
    public func createDirectory(
        path: [String],
        layer: DirectoryType? = nil,
        prefix: FDB.Bytes? = nil
    ) async throws -> Subspace {
        let dirSubspace = try await directoryLayer.create(
            path: path,
            type: layer,
            prefix: prefix
        )
        return dirSubspace.subspace
    }

    /// Open an existing directory
    ///
    /// - Parameter path: Directory path components
    /// - Returns: Subspace for the directory
    /// - Throws: Error if directory doesn't exist or open fails
    public func openDirectory(path: [String]) async throws -> Subspace {
        let dirSubspace = try await directoryLayer.open(path: path)
        return dirSubspace.subspace
    }

    /// Move a directory to a new path
    ///
    /// - Parameters:
    ///   - oldPath: Current directory path
    ///   - newPath: New directory path
    /// - Returns: Subspace for the moved directory
    /// - Throws: Error if move fails
    public func moveDirectory(
        oldPath: [String],
        newPath: [String]
    ) async throws -> Subspace {
        let dirSubspace = try await directoryLayer.move(
            oldPath: oldPath,
            newPath: newPath
        )
        return dirSubspace.subspace
    }

    /// Remove a directory
    ///
    /// - Parameter path: Directory path to remove
    /// - Throws: Error if remove fails
    public func removeDirectory(path: [String]) async throws {
        try await directoryLayer.remove(path: path)
    }

    /// Check if a directory exists
    ///
    /// - Parameter path: Directory path to check
    /// - Returns: true if directory exists, false otherwise
    /// - Throws: Error if check fails
    public func directoryExists(path: [String]) async throws -> Bool {
        return try await directoryLayer.exists(path: path)
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

    // MARK: - Cache Management

    /// Clear the store cache
    ///
    /// This forces all subsequent `store(for:)` calls to create new FDBStore instances.
    /// Useful for testing or when subspaces are reconfigured.
    public func clearStoreCache() {
        storeCache.withLock { cache in
            cache.removeAll()
        }
    }

    /// Get the number of cached stores
    ///
    /// Useful for testing and monitoring.
    ///
    /// - Returns: Number of FDBStore instances in cache
    public func cachedStoreCount() -> Int {
        return storeCache.withLock { cache in
            cache.count
        }
    }
}
