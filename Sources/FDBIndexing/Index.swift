import Foundation

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

    /// Index kind (metadata only - no execution logic)
    public let kind: any IndexKind

    /// Root expression defining indexed fields
    public let rootExpression: KeyExpression

    /// Subspace key (defaults to index name)
    public let subspaceKey: String

    /// Item types this index applies to (nil = universal, applies to all types)
    ///
    /// **Terminology**: Uses "itemTypes" (not "recordTypes") for layer-independent terminology.
    /// Compatible with Persistable types across all layers (record-layer, graph-layer, document-layer).
    public let itemTypes: Set<String>?

    // MARK: - Initialization

    /// Initialize an index
    ///
    /// - Parameters:
    ///   - name: Unique index name
    ///   - kind: Index kind (any IndexKind protocol implementation)
    ///   - rootExpression: Expression defining indexed fields
    ///   - subspaceKey: Optional subspace key (defaults to name)
    ///   - itemTypes: Optional set of item type names this index applies to (nil = universal)
    public init(
        name: String,
        kind: any IndexKind,
        rootExpression: KeyExpression,
        subspaceKey: String? = nil,
        itemTypes: Set<String>? = nil
    ) {
        self.name = name
        self.kind = kind
        self.rootExpression = rootExpression
        self.subspaceKey = subspaceKey ?? name
        self.itemTypes = itemTypes
    }
}
