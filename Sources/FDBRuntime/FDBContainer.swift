import Foundation
import FoundationDB
import FDBModel
import FDBCore
import FDBIndexing
import Synchronization
import Logging

/// FDBContainer - Complete implementation for type-independent persistence
///
/// **Design Philosophy**: FDBContainer is the COMPLETE implementation extracted
/// from FDBRecordLayer to be universally usable across all upper layers:
/// - record-layer: Typed RecordStore wrapper
/// - graph-layer: Graph data structures
/// - document-layer: JSON/Document storage
///
/// **Complete Responsibilities**:
/// - Schema management (version, entities, indexes)
/// - Migration execution (schema evolution)
/// - FDBStore lifecycle management (creation, caching)
/// - FDBContext management (change tracking, autosave)
/// - DirectoryLayer singleton management
/// - Database connection management
///
/// **Usage example (SwiftData-like API)**:
/// ```swift
/// // Simple initialization (recommended)
/// let schema = Schema([User.self, Order.self])
/// let config = FDBConfiguration(schema: schema)
/// let container = try FDBContainer(configurations: [config])
///
/// // Access main context
/// let context = await container.mainContext
/// await context.insert(data: userData, for: "User", primaryKey: Tuple(123))
/// try await context.save()
/// ```
///
/// **Low-level usage**:
/// ```swift
/// // Manual database initialization
/// let database = try FDBClient.openDatabase()
/// let container = FDBContainer(
///     database: database,
///     schema: schema,
///     migrations: [migration1, migration2]
/// )
///
/// // Get or create store for a specific subspace
/// let store = container.store(for: subspace)
/// ```
public final class FDBContainer: Sendable {
    // MARK: - Properties

    /// Database connection (thread-safe in FoundationDB)
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// Schema (version, entities, indexes)
    public let schema: Schema

    /// Configurations (SwiftData-compatible)
    public let configurations: [FDBConfiguration]

    /// Migrations (schema evolution)
    private let migrations: [Migration]

    /// DirectoryLayer instance (created once, reused for all operations)
    private let directoryLayer: FoundationDB.DirectoryLayer

    /// Logger
    private let logger: Logger

    /// Root subspace for this container (for metadata isolation)
    ///
    /// **Purpose**: Provides namespace isolation for multi-tenant or multiple container scenarios
    /// - If provided: Metadata is stored under `rootSubspace.subspace("_metadata")`
    /// - If nil: Metadata is stored under `Subspace(prefix: [0xFE])` (default, shared)
    ///
    /// **Example**:
    /// ```swift
    /// // Isolated container (multi-tenant)
    /// let tenantSubspace = Subspace(prefix: Tuple("tenant", tenantID).pack())
    /// let container = FDBContainer(..., rootSubspace: tenantSubspace)
    /// // → Metadata at: tenantSubspace/_metadata/schema/version
    ///
    /// // Shared container (default)
    /// let container = FDBContainer(..., rootSubspace: nil)
    /// // → Metadata at: [0xFE]/schema/version
    /// ```
    public let rootSubspace: Subspace?

    /// FDBStore cache
    /// Key: Subspace (identified by prefix bytes)
    /// Value: FDBStore instance
    private let storeCache: Mutex<[Data: FDBStore]>

    /// Main context (SwiftData-like API)
    /// Created lazily on first access
    @MainActor
    private var _mainContext: FDBContext?

    // MARK: - Initialization

    /// Initialize FDBContainer with configurations (SwiftData-compatible)
    ///
    /// **Recommended**: Use this initializer for SwiftData-like API.
    ///
    /// **Important**: FDBClient.initialize() must be called globally **before** creating FDBContainer.
    /// Typically, this is done at application startup (once per process):
    /// ```swift
    /// // At application startup (once)
    /// try await FDBClient.initialize()
    ///
    /// // Later, create containers as needed
    /// let schema = Schema([User.self, Order.self])
    /// let config = FDBConfiguration(schema: schema)
    /// let container = try FDBContainer(configurations: [config])
    /// ```
    ///
    /// - Parameters:
    ///   - configurations: Array of FDBConfiguration objects
    ///   - migrations: Array of migrations for schema evolution (optional)
    ///   - directoryLayer: Optional custom DirectoryLayer (for test isolation)
    ///
    /// **Example**:
    /// ```swift
    /// let schema = Schema([User.self, Order.self])
    /// let config = FDBConfiguration(schema: schema)
    /// let container = try FDBContainer(configurations: [config])
    ///
    /// // Access main context
    /// let context = await container.mainContext
    /// ```
    ///
    /// - Throws: Error if database connection fails or no configurations provided
    public init(
        configurations: [FDBConfiguration],
        migrations: [Migration] = [],
        directoryLayer: FoundationDB.DirectoryLayer? = nil
    ) throws {
        guard let firstConfig = configurations.first else {
            throw FDBRuntimeError.internalError("At least one configuration is required")
        }

        // Note: API version selection must be done globally before creating FDBContainer
        // If apiVersion is specified in configuration, it's for documentation purposes only
        // The actual API version selection should be done via FDBClient at application startup
        if let apiVersion = firstConfig.apiVersion {
            // Log warning if apiVersion is specified (it should be selected globally before)
            let logger = Logger(label: "com.fdb.runtime.container")
            logger.warning("API version \(apiVersion) specified in configuration, but API version must be selected globally before FDBContainer initialization. This value is ignored.")
        }

        // Open database connection
        let database = try FDBClient.openDatabase(clusterFilePath: firstConfig.clusterFilePath)

        // Initialize properties
        self.database = database
        self.schema = firstConfig.schema
        self.configurations = configurations
        self.migrations = migrations
        self.rootSubspace = nil  // SwiftData-like API uses default shared metadata
        self.logger = Logger(label: "com.fdb.runtime.container")
        self.storeCache = Mutex([:])
        self._mainContext = nil

        // Initialize DirectoryLayer (singleton pattern)
        if let customLayer = directoryLayer {
            self.directoryLayer = customLayer
        } else {
            self.directoryLayer = database.makeDirectoryLayer()
        }
    }

    /// Initialize FDBContainer (low-level API)
    ///
    /// **Use this initializer only when you need manual control over database initialization.**
    /// For typical use cases, prefer `init(configurations:)`.
    ///
    /// - Parameters:
    ///   - database: The FDB database
    ///   - schema: Schema defining entities and indexes
    ///   - migrations: Array of migrations for schema evolution (optional)
    ///   - rootSubspace: Root subspace for metadata isolation (optional, for multi-tenant)
    ///   - directoryLayer: Optional custom DirectoryLayer (for test isolation)
    ///   - logger: Optional logger
    ///
    /// **rootSubspace Parameter**:
    ///
    /// Provides namespace isolation for multi-tenant or multiple container scenarios:
    /// - `nil` (default): Metadata stored at `[0xFE]/schema/version` (shared)
    /// - non-nil: Metadata stored at `rootSubspace/_metadata/schema/version` (isolated)
    ///
    /// **DirectoryLayer Parameter**:
    ///
    /// The `directoryLayer` parameter is for test isolation.
    /// - `nil` (default): Creates default DirectoryLayer with `database.makeDirectoryLayer()`
    /// - non-nil: Uses custom DirectoryLayer (isolated subspace for testing)
    ///
    /// **Example**:
    /// ```swift
    /// // Manual database initialization
    /// try await FDBClient.initialize()
    /// let database = try FDBClient.openDatabase()
    ///
    /// // Create container
    /// let container = FDBContainer(
    ///     database: database,
    ///     schema: schema,
    ///     migrations: [migration1, migration2]
    /// )
    /// ```
    public init(
        database: any DatabaseProtocol,
        schema: Schema,
        migrations: [Migration] = [],
        rootSubspace: Subspace? = nil,
        directoryLayer: FoundationDB.DirectoryLayer? = nil,
        logger: Logger? = nil
    ) {
        self.database = database
        self.schema = schema
        self.configurations = []  // Empty for low-level API
        self.migrations = migrations
        self.rootSubspace = rootSubspace
        self.logger = logger ?? Logger(label: "com.fdb.runtime.container")
        self.storeCache = Mutex([:])
        self._mainContext = nil

        // Initialize DirectoryLayer (singleton pattern)
        if let customLayer = directoryLayer {
            self.directoryLayer = customLayer
        } else {
            self.directoryLayer = database.makeDirectoryLayer()
        }
    }

    // MARK: - Main Context

    /// Access the main context (SwiftData-like API)
    ///
    /// The main context is created lazily on first access.
    /// This must be accessed from the MainActor.
    ///
    /// **Example**:
    /// ```swift
    /// let context = await container.mainContext
    /// await context.insert(data: userData, for: "User", primaryKey: Tuple(123))
    /// try await context.save()
    /// ```
    @MainActor
    public var mainContext: FDBContext {
        get {
            if let existing = _mainContext {
                return existing
            }
            let newContext = FDBContext(container: self)
            _mainContext = newContext
            return newContext
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

    // MARK: - Migration Management

    /// Get metadata subspace for this container
    ///
    /// **Behavior**:
    /// - If `rootSubspace` is set: Returns `rootSubspace.subspace("_metadata")`
    /// - If `rootSubspace` is nil: Returns `Subspace(prefix: [0xFE])` (shared)
    ///
    /// - Returns: Metadata subspace
    private func getMetadataSubspace() -> Subspace {
        if let root = rootSubspace {
            return root.subspace("_metadata")
        } else {
            return Subspace(prefix: [0xFE])  // Default: shared metadata space
        }
    }

    /// Get the current schema version from FDB
    ///
    /// Reads the schema version metadata from the database.
    ///
    /// **Storage Location**:
    /// - With rootSubspace: `rootSubspace/_metadata/schema/version`
    /// - Without rootSubspace: `[0xFE]/schema/version` (shared)
    ///
    /// - Returns: Current schema version, or nil if no version is set
    /// - Throws: Error if version read fails
    public func getCurrentSchemaVersion() async throws -> Schema.Version? {
        let metadataSubspace = getMetadataSubspace()
        let versionKey = metadataSubspace
            .subspace("schema")
            .pack(Tuple("version"))

        return try await database.withTransaction { transaction -> Schema.Version? in
            guard let versionBytes = try await transaction.getValue(for: versionKey, snapshot: true) else {
                return nil
            }

            let tuple = try Tuple.unpack(from: versionBytes)
            guard tuple.count == 3 else {
                throw FDBRuntimeError.internalError("Invalid version format in database")
            }

            // Support multiple formats for backwards compatibility:
            // - (Int64, Int64, Int64) - old format
            // - (Int64, Int, Int) - mixed format (transitional)
            // - (Int, Int, Int) - new format
            let major: Int
            let minor: Int
            let patch: Int

            if let maj64 = tuple[0] as? Int64 {
                // First element is Int64
                major = Int(maj64)

                if let min64 = tuple[1] as? Int64, let pat64 = tuple[2] as? Int64 {
                    // All Int64 (old format)
                    minor = Int(min64)
                    patch = Int(pat64)
                } else if let minInt = tuple[1] as? Int, let patInt = tuple[2] as? Int {
                    // Mixed format (Int64, Int, Int)
                    minor = minInt
                    patch = patInt
                } else {
                    throw FDBRuntimeError.internalError("Invalid version format in database")
                }
            } else if let majInt = tuple[0] as? Int,
                      let minInt = tuple[1] as? Int,
                      let patInt = tuple[2] as? Int {
                // All Int (new format)
                major = majInt
                minor = minInt
                patch = patInt
            } else {
                throw FDBRuntimeError.internalError("Invalid version format in database")
            }

            return Schema.Version(major, minor, patch)
        }
    }

    /// Set the current schema version in FDB
    ///
    /// Writes the schema version metadata to the database.
    ///
    /// **Storage Location**:
    /// - With rootSubspace: `rootSubspace/_metadata/schema/version`
    /// - Without rootSubspace: `[0xFE]/schema/version` (shared)
    ///
    /// - Parameter version: Schema version to set
    /// - Throws: Error if version write fails
    public func setCurrentSchemaVersion(_ version: Schema.Version) async throws {
        let metadataSubspace = getMetadataSubspace()
        let versionKey = metadataSubspace
            .subspace("schema")
            .pack(Tuple("version"))

        try await database.withTransaction { transaction in
            let versionTuple = Tuple(
                version.major,
                version.minor,
                version.patch
            )
            transaction.setValue(versionTuple.pack(), for: versionKey)
        }
    }

    /// Migrate to a specific schema version
    ///
    /// Executes all migrations needed to reach the target version.
    ///
    /// **Migration Flow**:
    /// 1. Get current version from FDB
    /// 2. Find migration path (chain of migrations)
    /// 3. Execute migrations in order
    /// 4. Update current version
    ///
    /// **Example**:
    /// ```swift
    /// try await container.migrate(to: Schema.Version(2, 0, 0))
    /// ```
    ///
    /// - Parameter targetVersion: Target schema version
    /// - Throws: Error if migration fails
    public func migrate(to targetVersion: Schema.Version) async throws {
        // 1. Get current version
        guard let currentVersion = try await getCurrentSchemaVersion() else {
            // No current version: set to target version (initial setup)
            try await setCurrentSchemaVersion(targetVersion)
            return
        }

        // Already at target version
        if currentVersion == targetVersion {
            return
        }

        // 2. Find migration path
        let migrationPath = try findMigrationPath(from: currentVersion, to: targetVersion)

        // 3. Execute migrations
        for migration in migrationPath {
            logger.info("Applying migration: \(migration.description)")

            // Build store registry for migration context
            var storeRegistry: [String: FDBStore] = [:]
            for entity in schema.entities {
                // Get or create subspace for entity
                let entitySubspace = try await getOrOpenDirectory(path: [entity.name])
                let store = self.store(for: entitySubspace)
                storeRegistry[entity.name] = store
            }

            // Create migration context with proper metadata subspace
            let metadataSubspace = getMetadataSubspace()
            let context = MigrationContext(
                database: database,
                schema: schema,
                metadataSubspace: metadataSubspace,
                storeRegistry: storeRegistry
            )

            // Execute migration
            try await migration.execute(context)

            // Update current version
            try await setCurrentSchemaVersion(migration.toVersion)

            logger.info("Migration complete: \(currentVersion) → \(migration.toVersion)")
        }
    }

    /// Find migration path from current version to target version
    ///
    /// - Parameters:
    ///   - fromVersion: Current schema version
    ///   - toVersion: Target schema version
    /// - Returns: Array of migrations to execute (in order)
    /// - Throws: Error if no migration path found
    private func findMigrationPath(
        from fromVersion: Schema.Version,
        to toVersion: Schema.Version
    ) throws -> [Migration] {
        var path: [Migration] = []
        var currentVersion = fromVersion

        while currentVersion < toVersion {
            // Find next migration
            guard let nextMigration = migrations.first(where: { $0.fromVersion == currentVersion }) else {
                throw FDBRuntimeError.internalError(
                    "No migration path found from \(fromVersion) to \(toVersion). " +
                    "Stuck at version \(currentVersion)"
                )
            }

            path.append(nextMigration)
            currentVersion = nextMigration.toVersion
        }

        return path
    }
}
