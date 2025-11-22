import Foundation
import FoundationDB
import Synchronization

/// IndexManager coordinates index registration and state management
///
/// **Design**: FDBRuntime's IndexManager is a lightweight registry that:
/// - Registers indexes by name
/// - Manages index states via IndexStateManager
/// - Provides lookup methods for indexes
///
/// **Note**: Actual index maintenance (IndexMaintainer implementations) is
/// handled by upper layers (fdb-record-layer, fdb-document-layer, etc.).
///
/// **Usage Example**:
/// ```swift
/// let indexManager = IndexManager(
///     database: database,
///     subspace: indexSubspace
/// )
///
/// // Register an index
/// indexManager.register(index: emailIndex)
///
/// // Get index state
/// let state = try await indexManager.state(of: "user_by_email")
///
/// // Enable index (transition to writeOnly)
/// try await indexManager.enable("user_by_email")
///
/// // Make index readable (after building)
/// try await indexManager.makeReadable("user_by_email")
/// ```
public final class IndexManager: Sendable {
    // MARK: - Properties

    nonisolated(unsafe) private let database: any DatabaseProtocol
    private let subspace: Subspace
    private let stateManager: IndexStateManager
    private let indexRegistry: Mutex<[String: Index]>

    // MARK: - Initialization

    /// Initialize IndexManager
    ///
    /// - Parameters:
    ///   - database: FoundationDB database
    ///   - subspace: Subspace for storing index data and state
    public init(
        database: any DatabaseProtocol,
        subspace: Subspace
    ) {
        self.database = database
        self.subspace = subspace
        self.stateManager = IndexStateManager(
            database: database,
            subspace: subspace
        )
        self.indexRegistry = Mutex([:])
    }

    // MARK: - Index Registration

    /// Register an index
    ///
    /// Registers an index definition in the manager. This makes the index
    /// available for queries and state management.
    ///
    /// - Parameter index: The index to register
    /// - Throws: IndexManagerError.duplicateIndex if index already exists
    public func register(index: Index) throws {
        try indexRegistry.withLock { registry in
            guard registry[index.name] == nil else {
                throw IndexManagerError.duplicateIndex(index.name)
            }
            registry[index.name] = index
        }
    }

    /// Register multiple indexes
    ///
    /// - Parameter indexes: Array of indexes to register
    /// - Throws: IndexManagerError.duplicateIndex if any index already exists
    public func register(indexes: [Index]) throws {
        for index in indexes {
            try register(index: index)
        }
    }

    /// Unregister an index
    ///
    /// Removes an index from the registry. This does not delete the index data
    /// from FDB or change its state.
    ///
    /// - Parameter indexName: Name of the index to unregister
    public func unregister(indexName: String) {
        _ = indexRegistry.withLock { registry in
            registry.removeValue(forKey: indexName)
        }
    }

    // MARK: - Index Lookup

    /// Get an index by name
    ///
    /// - Parameter name: Index name
    /// - Returns: The index, or nil if not found
    public func index(named name: String) -> Index? {
        return indexRegistry.withLock { registry in
            registry[name]
        }
    }

    /// Get all registered indexes
    ///
    /// - Returns: Array of all registered indexes
    public func allIndexes() -> [Index] {
        return indexRegistry.withLock { registry in
            Array(registry.values)
        }
    }

    /// Get indexes for a specific record type
    ///
    /// - Parameter recordName: The record type name
    /// - Returns: Array of indexes that apply to this record type
    public func indexes(for recordName: String) -> [Index] {
        return indexRegistry.withLock { registry in
            registry.values.filter { index in
                // Universal indexes (recordTypes == nil) apply to all types
                if index.recordTypes == nil {
                    return true
                }
                // Check if this record type is in the index's record types
                return index.recordTypes?.contains(recordName) ?? false
            }
        }
    }

    // MARK: - State Management

    /// Get the current state of an index
    ///
    /// - Parameter indexName: Name of the index
    /// - Returns: Current IndexState
    /// - Throws: Error if state read fails
    public func state(of indexName: String) async throws -> IndexState {
        return try await stateManager.state(of: indexName)
    }

    /// Get states for multiple indexes
    ///
    /// - Parameter indexNames: List of index names
    /// - Returns: Dictionary mapping index names to states
    /// - Throws: Error if state read fails
    public func states(of indexNames: [String]) async throws -> [String: IndexState] {
        return try await stateManager.states(of: indexNames)
    }

    /// Enable an index (transition to WRITE_ONLY state)
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: IndexStateError.invalidTransition if not in DISABLED state
    public func enable(_ indexName: String) async throws {
        try await stateManager.enable(indexName)
    }

    /// Make an index readable (transition to READABLE state)
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: IndexStateError.invalidTransition if not in WRITE_ONLY state
    public func makeReadable(_ indexName: String) async throws {
        try await stateManager.makeReadable(indexName)
    }

    /// Disable an index (transition to DISABLED state)
    ///
    /// - Parameter indexName: Name of the index
    /// - Throws: Error if state write fails
    public func disable(_ indexName: String) async throws {
        try await stateManager.disable(indexName)
    }

    // MARK: - Subspace Management

    /// Get the subspace for a specific index
    ///
    /// Returns the subspace where this index's data is stored:
    /// `[subspace][indexName]`
    ///
    /// - Parameter indexName: The index name
    /// - Returns: The subspace for storing this index's data
    public func indexSubspace(for indexName: String) -> Subspace {
        return subspace.subspace(indexName)
    }

    /// Get the subspace for an Index struct
    ///
    /// - Parameter index: The index
    /// - Returns: The subspace for storing this index's data
    public func indexSubspace(for index: Index) -> Subspace {
        return subspace.subspace(index.subspaceKey)
    }
}

// MARK: - Errors

/// Errors that can occur during index management
public enum IndexManagerError: Error, CustomStringConvertible {
    /// Attempted to register an index that already exists
    case duplicateIndex(String)

    /// Index not found in registry
    case indexNotFound(String)

    public var description: String {
        switch self {
        case .duplicateIndex(let name):
            return "Index '\(name)' is already registered"
        case .indexNotFound(let name):
            return "Index '\(name)' not found in registry"
        }
    }
}
