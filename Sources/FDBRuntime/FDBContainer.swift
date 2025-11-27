import Foundation
import FoundationDB
import FDBModel
import FDBCore
import FDBIndexing
import Synchronization
import Logging

/// FDBContainer - SwiftData-like container for FoundationDB persistence
///
/// **Design Philosophy**: Like SwiftData's ModelContainer, FDBContainer manages
/// the persistence infrastructure and provides FDBContext instances for data operations.
///
/// **Responsibilities**:
/// - Schema management (version, entities, indexes)
/// - Migration execution (schema evolution)
/// - FDBContext management (main context + background contexts)
/// - DirectoryLayer singleton management
/// - Database connection management
///
/// **Usage**:
/// ```swift
/// // 1. Initialize FDB (once at app startup)
/// try await FDBClient.initialize()
///
/// // 2. Create container
/// let schema = Schema([User.self, Order.self])
/// let config = FDBConfiguration(schema: schema)
/// let container = try FDBContainer(configurations: [config])
///
/// // 3. Access main context (SwiftData-like)
/// let context = await container.mainContext
///
/// // 4. Use context for all data operations
/// context.insert(user)
/// context.insert(order)
/// try await context.save()
///
/// // 5. Fetch data
/// let users = try await context.fetch(FDBFetchDescriptor<User>())
/// ```
///
/// **Background Operations**:
/// ```swift
/// // Create new context for background work
/// let backgroundContext = container.newContext()
/// Task.detached {
///     // Perform bulk operations
///     for data in largeDataset {
///         backgroundContext.insert(Model(from: data))
///     }
///     try await backgroundContext.save()
/// }
/// ```
public final class FDBContainer: Sendable {
    // MARK: - Properties

    /// Database connection (thread-safe in FoundationDB)
    nonisolated(unsafe) public let database: any DatabaseProtocol

    /// Schema (version, entities, indexes)
    public let schema: Schema

    /// Configurations (SwiftData-compatible)
    public let configurations: [FDBConfiguration]

    /// Migrations (schema evolution) - legacy API
    private let migrations: [Migration]

    /// Migration plan (SwiftData-like API)
    nonisolated(unsafe) private var _migrationPlan: (any SchemaMigrationPlan.Type)?

    /// DirectoryLayer instance (created once, reused for all operations)
    private let directoryLayer: FoundationDB.DirectoryLayer

    /// Logger
    private let logger: Logger

    /// Root subspace for data storage
    ///
    /// All data is stored under this subspace:
    /// - Records: `[subspace]/R/[persistableType]/[id]`
    /// - Indexes: `[subspace]/I/[indexName]/[values]/[id]`
    ///
    /// **Usage**:
    /// ```swift
    /// // Default subspace (auto-created)
    /// let container = try FDBContainer(configurations: [config])
    /// // → Data at: [fdb]/R/..., [fdb]/I/...
    ///
    /// // Custom subspace (multi-tenant)
    /// let tenantSubspace = Subspace(prefix: Tuple("tenant", tenantID).pack())
    /// let container = FDBContainer(..., subspace: tenantSubspace)
    /// // → Data at: tenant/[tenantID]/R/..., tenant/[tenantID]/I/...
    /// ```
    public let subspace: Subspace

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
    /// context.insert(user)
    /// try await context.save()
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
        self._migrationPlan = nil
        self.subspace = Subspace(prefix: Tuple("fdb").pack())  // Default subspace
        self.logger = Logger(label: "com.fdb.runtime.container")
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
    ///   - subspace: Root subspace for data storage (optional, for multi-tenant)
    ///   - directoryLayer: Optional custom DirectoryLayer (for test isolation)
    ///   - logger: Optional logger
    ///
    /// **subspace Parameter**:
    ///
    /// Provides namespace isolation for multi-tenant scenarios:
    /// - `nil` (default): Data stored at `[fdb]/R/...`, `[fdb]/I/...`
    /// - non-nil: Data stored at `subspace/R/...`, `subspace/I/...`
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
    /// // Create container with custom subspace
    /// let tenantSubspace = Subspace(prefix: Tuple("tenant", tenantID).pack())
    /// let container = FDBContainer(
    ///     database: database,
    ///     schema: schema,
    ///     subspace: tenantSubspace
    /// )
    ///
    /// // Use context for data operations
    /// let context = await container.mainContext
    /// context.insert(user)
    /// try await context.save()
    /// ```
    public init(
        database: any DatabaseProtocol,
        schema: Schema,
        migrations: [Migration] = [],
        subspace: Subspace? = nil,
        directoryLayer: FoundationDB.DirectoryLayer? = nil,
        logger: Logger? = nil
    ) {
        self.database = database
        self.schema = schema
        self.configurations = []  // Empty for low-level API
        self.migrations = migrations
        self._migrationPlan = nil
        self.subspace = subspace ?? Subspace(prefix: Tuple("fdb").pack())
        self.logger = logger ?? Logger(label: "com.fdb.runtime.container")
        self._mainContext = nil

        // Initialize DirectoryLayer (singleton pattern)
        if let customLayer = directoryLayer {
            self.directoryLayer = customLayer
        } else {
            self.directoryLayer = database.makeDirectoryLayer()
        }
    }

    // MARK: - Context Management

    /// Access the main context (SwiftData-like API)
    ///
    /// The main context is created lazily on first access.
    /// This must be accessed from the MainActor.
    ///
    /// **Example**:
    /// ```swift
    /// let context = await container.mainContext
    /// context.insert(user)
    /// context.insert(order)
    /// try await context.save()
    ///
    /// let users = try await context.fetch(FDBFetchDescriptor<User>())
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

    /// Create a new context for background operations
    ///
    /// Use this method when you need to perform database operations
    /// outside the main thread, such as bulk imports or background processing.
    ///
    /// **Example**:
    /// ```swift
    /// let backgroundContext = container.newContext()
    ///
    /// Task.detached {
    ///     // Perform bulk operations
    ///     for data in largeDataset {
    ///         let model = Model(from: data)
    ///         backgroundContext.insert(model)
    ///     }
    ///     try await backgroundContext.save()
    /// }
    /// ```
    ///
    /// - Parameter autosaveEnabled: Whether to automatically save after operations (default: false)
    /// - Returns: New FDBContext instance
    public func newContext(autosaveEnabled: Bool = false) -> FDBContext {
        return FDBContext(container: self, autosaveEnabled: autosaveEnabled)
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

    // MARK: - Migration Management

    /// Get metadata subspace for this container
    ///
    /// Returns the metadata subspace under the container's root subspace.
    /// Metadata is stored at: `[subspace]/_metadata/...`
    ///
    /// - Returns: Metadata subspace
    private func getMetadataSubspace() -> Subspace {
        return subspace.subspace("_metadata")
    }

    /// Get the current schema version from FDB
    ///
    /// Reads the schema version metadata from the database.
    ///
    /// **Storage Location**: `[subspace]/_metadata/schema/version`
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
    /// **Storage Location**: `[subspace]/_metadata/schema/version`
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
        // 0. Validate schema before migration
        try schema.validateIndexNames()

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

            // Build store info registry for migration context
            var storeRegistry: [String: MigrationStoreInfo] = [:]
            for entity in schema.entities {
                // Get or create subspace for entity
                let entitySubspace = try await getOrOpenDirectory(path: [entity.name])
                let info = MigrationStoreInfo(
                    subspace: entitySubspace,
                    indexSubspace: entitySubspace.subspace("I")
                )
                storeRegistry[entity.name] = info
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

// MARK: - SwiftData-like API

extension FDBContainer {
    /// Initialize FDBContainer with VersionedSchema and MigrationPlan (SwiftData-like API)
    ///
    /// **Recommended for new applications**: This initializer provides a SwiftData-like API
    /// for schema management and migrations.
    ///
    /// **Important**: FDBClient.initialize() must be called globally **before** creating FDBContainer.
    ///
    /// **Example**:
    /// ```swift
    /// // Define versioned schemas
    /// enum AppSchemaV1: VersionedSchema {
    ///     static let versionIdentifier = Schema.Version(1, 0, 0)
    ///     static let models: [any Persistable.Type] = [User.self]
    /// }
    ///
    /// enum AppSchemaV2: VersionedSchema {
    ///     static let versionIdentifier = Schema.Version(2, 0, 0)
    ///     static let models: [any Persistable.Type] = [User.self, Order.self]
    /// }
    ///
    /// // Define migration plan
    /// enum AppMigrationPlan: SchemaMigrationPlan {
    ///     static var schemas: [any VersionedSchema.Type] {
    ///         [AppSchemaV1.self, AppSchemaV2.self]
    ///     }
    ///     static var stages: [MigrationStage] {
    ///         [MigrationStage.lightweight(fromVersion: AppSchemaV1.self, toVersion: AppSchemaV2.self)]
    ///     }
    /// }
    ///
    /// // Create container
    /// let container = try FDBContainer(
    ///     for: AppSchemaV2.self,
    ///     migrationPlan: AppMigrationPlan.self
    /// )
    /// try await container.migrateIfNeeded()
    /// ```
    ///
    /// - Parameters:
    ///   - schema: The current VersionedSchema type
    ///   - migrationPlan: The SchemaMigrationPlan type defining migration path
    ///   - clusterFilePath: Optional path to cluster file
    /// - Throws: Error if initialization fails
    public convenience init<S: VersionedSchema, P: SchemaMigrationPlan>(
        for schema: S.Type,
        migrationPlan: P.Type,
        clusterFilePath: String? = nil
    ) throws {
        // Validate migration plan
        try P.validate()

        // Create schema from VersionedSchema
        let schemaInstance = S.makeSchema()

        // Open database connection
        let database = try FDBClient.openDatabase(clusterFilePath: clusterFilePath)

        // Create default subspace
        let subspace = Subspace(prefix: Tuple("fdb").pack())

        // Use memberwise init pattern via internal initializer
        self.init(
            database: database,
            schema: schemaInstance,
            configurations: [],
            migrations: [],
            migrationPlan: migrationPlan,
            subspace: subspace,
            directoryLayer: database.makeDirectoryLayer(),
            logger: Logger(label: "com.fdb.runtime.container")
        )
    }

    /// Internal initializer with all parameters including migration plan
    internal convenience init(
        database: any DatabaseProtocol,
        schema: Schema,
        configurations: [FDBConfiguration],
        migrations: [Migration],
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        subspace: Subspace,
        directoryLayer: FoundationDB.DirectoryLayer,
        logger: Logger
    ) {
        self.init(
            database: database,
            schema: schema,
            migrations: migrations,
            subspace: subspace,
            directoryLayer: directoryLayer,
            logger: logger
        )
        // Note: migrationPlan is set via _setMigrationPlan after init
        _setMigrationPlan(migrationPlan)
    }

    /// Internal method to set migration plan after initialization
    ///
    /// This is needed because we use a var with nonisolated(unsafe) to allow
    /// setting during the convenience initializer chain.
    private func _setMigrationPlan(_ plan: (any SchemaMigrationPlan.Type)?) {
        self._migrationPlan = plan
    }

    /// Migrate to the current schema version if needed
    ///
    /// This method checks the current database schema version and applies
    /// any necessary migrations to reach the current schema version.
    ///
    /// **Execution Flow**:
    /// 1. Get current version from database
    /// 2. Compare with target version from migration plan
    /// 3. Find migration path (sequence of stages)
    /// 4. Execute each stage in order
    /// 5. Update version after each successful stage
    ///
    /// **Example**:
    /// ```swift
    /// let container = try FDBContainer(
    ///     for: AppSchemaV2.self,
    ///     migrationPlan: AppMigrationPlan.self
    /// )
    ///
    /// // Run migrations
    /// try await container.migrateIfNeeded()
    ///
    /// // Now safe to use the container
    /// let context = await container.mainContext
    /// ```
    ///
    /// - Throws: Error if migration fails
    public func migrateIfNeeded() async throws {
        guard let plan = _migrationPlan else {
            // No migration plan - nothing to do
            return
        }

        guard let targetVersion = plan.currentVersion else {
            throw FDBRuntimeError.internalError("Migration plan has no schemas")
        }

        // Validate schema
        try schema.validateIndexNames()

        // Get current version
        let currentVersion = try await getCurrentSchemaVersion()

        if currentVersion == nil {
            // New database - set initial version
            try await setCurrentSchemaVersion(targetVersion)
            logger.info("Set initial schema version: \(targetVersion)")
            return
        }

        if currentVersion! >= targetVersion {
            // Already at or past target version
            return
        }

        // Find migration path
        let stages = try plan.findPath(from: currentVersion!, to: targetVersion)

        if stages.isEmpty {
            return
        }

        logger.info("Starting migration from \(currentVersion!) to \(targetVersion)")

        // Execute each stage
        for stage in stages {
            try await executeStage(stage)
        }

        logger.info("Migration complete: now at version \(targetVersion)")
    }

    /// Execute a single migration stage
    ///
    /// - Parameter stage: The MigrationStage to execute
    /// - Throws: Error if stage execution fails
    private func executeStage(_ stage: MigrationStage) async throws {
        logger.info("Executing \(stage.migrationDescription)")

        // Build store info registry
        let storeRegistry = try await buildStoreRegistry()

        // Create migration context
        let context = MigrationContext(
            database: database,
            schema: schema,
            metadataSubspace: getMetadataSubspace(),
            storeRegistry: storeRegistry
        )

        // 1. Execute willMigrate if present
        if let willMigrate = stage.willMigrate {
            logger.info("Running willMigrate hook")
            try await willMigrate(context)
        }

        // 2. Execute lightweight migration (index changes)
        try await executeLightweightMigration(stage: stage, context: context)

        // 3. Execute didMigrate if present
        if let didMigrate = stage.didMigrate {
            logger.info("Running didMigrate hook")
            try await didMigrate(context)
        }

        // 4. Update version
        try await setCurrentSchemaVersion(stage.toVersionIdentifier)
        logger.info("Updated schema version to \(stage.toVersionIdentifier)")
    }

    /// Execute lightweight migration steps (index additions/removals)
    ///
    /// - Parameters:
    ///   - stage: The migration stage
    ///   - context: The migration context
    /// - Throws: Error if migration fails
    private func executeLightweightMigration(
        stage: MigrationStage,
        context: MigrationContext
    ) async throws {
        let indexChanges = stage.indexChanges

        // Add new indexes
        for descriptor in stage.addedIndexDescriptors {
            logger.info("Adding index: \(descriptor.name)")
            try await context.addIndex(descriptor)
        }

        // Remove old indexes
        for indexName in indexChanges.removed {
            logger.info("Removing index: \(indexName)")
            // Use fromVersion as addedVersion (approximate)
            try await context.removeIndex(
                indexName: indexName,
                addedVersion: stage.fromVersionIdentifier
            )
        }
    }

    /// Build store info registry from schema entities
    ///
    /// - Returns: Dictionary mapping entity names to MigrationStoreInfo
    /// - Throws: Error if directory operations fail
    private func buildStoreRegistry() async throws -> [String: MigrationStoreInfo] {
        var registry: [String: MigrationStoreInfo] = [:]

        for entity in schema.entities {
            let entitySubspace = try await getOrOpenDirectory(path: [entity.name])
            let info = MigrationStoreInfo(
                subspace: entitySubspace,
                indexSubspace: entitySubspace.subspace("I")
            )
            registry[entity.name] = info
        }

        return registry
    }
}
