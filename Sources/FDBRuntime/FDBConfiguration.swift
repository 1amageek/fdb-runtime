import Foundation
import FoundationDB

/// FDB configuration (SwiftData-compatible)
///
/// Corresponds to SwiftData's ModelConfiguration:
/// - Schema definition
/// - FoundationDB cluster configuration
/// - In-memory only mode (future)
///
/// **Example usage**:
/// ```swift
/// let schema = Schema([User.self, Order.self])
/// let config = FDBConfiguration(
///     schema: schema,
///     clusterFilePath: "/etc/foundationdb/fdb.cluster",
///     isStoredInMemoryOnly: false
/// )
/// let container = try FDBContainer(configurations: [config])
/// ```
public struct FDBConfiguration: Sendable {

    // MARK: - Properties

    /// Schema
    public let schema: Schema

    /// FoundationDB API version (optional)
    ///
    /// If nil, assumes API version has already been selected globally.
    /// If specified, will attempt to select this version during initialization.
    /// Note: API version can only be selected once per process.
    public let apiVersion: Int32?

    /// Cluster file path (optional)
    public let clusterFilePath: String?

    /// In-memory only mode (no persistence)
    ///
    /// Note: Currently not implemented. Reserved for future use.
    public let isStoredInMemoryOnly: Bool

    /// Allow save (for read-only mode)
    ///
    /// Note: Currently not implemented. Reserved for future use.
    public let allowsSave: Bool

    // MARK: - Initialization

    /// Create FDB configuration (SwiftData-compatible)
    ///
    /// - Parameters:
    ///   - schema: Schema
    ///   - apiVersion: FoundationDB API version (default: nil = use already selected version)
    ///   - clusterFilePath: Cluster file path (default: nil)
    ///   - isStoredInMemoryOnly: In-memory only mode (default: false, not yet implemented)
    ///   - allowsSave: Allow save operations (default: true, not yet implemented)
    ///
    /// **Example usage**:
    /// ```swift
    /// let schema = Schema([User.self, Order.self])
    /// let config = FDBConfiguration(schema: schema, isStoredInMemoryOnly: false)
    /// ```
    public init(
        schema: Schema,
        apiVersion: Int32? = nil,
        clusterFilePath: String? = nil,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true
    ) {
        self.schema = schema
        self.apiVersion = apiVersion
        self.clusterFilePath = clusterFilePath
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
    }
}

// MARK: - CustomDebugStringConvertible

extension FDBConfiguration: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "FDBConfiguration(schema: \(schema), apiVersion: \(apiVersion?.description ?? "nil"), inMemory: \(isStoredInMemoryOnly))"
    }
}
