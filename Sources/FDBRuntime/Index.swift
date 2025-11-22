import Foundation
import FDBIndexing

/// Index definition
///
/// Defines a secondary index on record fields. Indexes are maintained automatically
/// when records are inserted, updated, or deleted.
///
/// **Note**: This is the FDBRuntime version which provides the core structure.
/// The full Index implementation with all features is in fdb-record-layer.
public struct Index: Sendable {
    // MARK: - Properties

    /// Unique index name
    public let name: String

    /// Index type (from fdb-indexing)
    public let type: any IndexKindProtocol

    /// Root expression defining indexed fields
    public let rootExpression: KeyExpression

    /// Subspace key (defaults to index name)
    public let subspaceKey: String

    /// Record types this index applies to (nil = universal, applies to all types)
    public let recordTypes: Set<String>?

    // MARK: - Initialization

    /// Initialize an index
    ///
    /// - Parameters:
    ///   - name: Unique index name
    ///   - type: Index type from fdb-indexing
    ///   - rootExpression: Expression defining indexed fields
    ///   - subspaceKey: Optional subspace key (defaults to name)
    ///   - recordTypes: Optional set of record type names this index applies to
    public init(
        name: String,
        type: any IndexKindProtocol,
        rootExpression: KeyExpression,
        subspaceKey: String? = nil,
        recordTypes: Set<String>? = nil
    ) {
        self.name = name
        self.type = type
        self.rootExpression = rootExpression
        self.subspaceKey = subspaceKey ?? name
        self.recordTypes = recordTypes
    }
}
