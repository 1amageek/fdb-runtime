import Foundation
import FDBIndexing

/// @Persistable macro declaration
///
/// Generates Persistable protocol conformance with metadata methods.
///
/// **Supports all data model layers**:
/// - RecordLayer (RDB): Use #PrimaryKey for relational model
/// - DocumentLayer (DocumentDB): No #PrimaryKey, auto-generates ObjectID
/// - VectorLayer (Vector search): Use #Index with VectorIndexKind
/// - GraphLayer (GraphDB): Define nodes and edges with relationships
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///     #Index<User>([\.email], type: ScalarIndexKind(), unique: true)
///
///     var userID: Int64
///     var email: String
///     var name: String
/// }
/// ```
///
/// **Generated code**:
/// - static var persistableType: String
/// - static var allFields: [String]
/// - static var indexDescriptors: [IndexDescriptor]
/// - static var primaryKeyFields: [String] (if #PrimaryKey exists)
/// - static func fieldNumber(for fieldName: String) -> Int?
/// - static func enumMetadata(for fieldName: String) -> EnumMetadata?
///
/// **Note**: primaryKeyFields is only generated if #PrimaryKey is declared.
/// The Persistable protocol itself does not require primaryKeyFields (layer-independent).
@attached(member, names: named(persistableType), named(primaryKeyFields), named(allFields), named(indexDescriptors), named(fieldNumber), named(enumMetadata))
@attached(extension, conformances: Persistable, Codable, Sendable)
public macro Persistable() = #externalMacro(module: "FDBCoreMacros", type: "PersistableMacro")

/// #PrimaryKey macro declaration
///
/// Declares primary key fields for a persistable type.
///
/// **Usage**:
/// ```swift
/// #PrimaryKey<User>([\.userID])
/// #PrimaryKey<User>([\.country, \.userID])  // Composite key
/// ```
///
/// This is a marker macro. The @Persistable macro reads the #PrimaryKey declaration
/// and generates the primaryKeyFields property.
///
/// **Layer-specific behavior**:
/// - RecordLayer: Primary key is required
/// - DocumentLayer: Primary key is optional (auto-generates ObjectID if not specified)
/// - VectorLayer: Primary key typically required for vector lookups
/// - GraphLayer: Nodes and edges have separate primary keys
@freestanding(declaration)
public macro PrimaryKey<T>(_ keyPaths: [PartialKeyPath<T>]) = #externalMacro(module: "FDBCoreMacros", type: "PrimaryKeyMacro")

/// #Index macro declaration
///
/// Declares an index on specified fields.
///
/// **Usage**:
/// ```swift
/// // Import specific IndexKind from fdb-indexes package
/// import ScalarIndexLayer
/// import VectorIndexLayer
///
/// @Persistable
/// struct Product {
///     var id: Int64
///
///     #Index<Product>([\.email], type: ScalarIndexKind(), unique: true)
///     #Index<Product>([\.embedding], type: VectorIndexKind(dimensions: 384))
///
///     var email: String
///     var embedding: [Float32]
/// }
/// ```
///
/// This is a marker macro. The @Persistable macro reads the #Index declaration
/// and generates the indexDescriptors array.
///
/// **Parameters**:
/// - keyPaths: Array of KeyPaths to indexed fields
/// - type: IndexKind implementation (must import from fdb-indexes package)
/// - unique: Uniqueness constraint (default: false)
/// - name: Custom index name (default: auto-generated from field names)
///
/// **Index Types** (from fdb-indexes package):
/// - ScalarIndexKind: VALUE index for sorting and range queries
/// - VectorIndexKind: Vector similarity search (HNSW, IVF, flat scan)
/// - FullTextIndexKind: Full-text search with inverted index
/// - CountIndexKind, SumIndexKind, MinIndexKind, MaxIndexKind: Aggregation indexes
/// - GeohashIndexKind: Geospatial indexing (third-party example)
@freestanding(declaration)
public macro Index<T: Persistable>(
    _ keyPaths: [PartialKeyPath<T>],
    type: any IndexKind,
    unique: Bool = false,
    name: String? = nil
) = #externalMacro(module: "FDBCoreMacros", type: "IndexMacro")

/// #Directory macro declaration
///
/// Declares directory path for a persistable type (for FDBRuntime).
///
/// **Usage**:
/// ```swift
/// #Directory<User>("app", "users")
/// #Directory<Order>("tenants", Field(\.accountID), "orders", layer: .partition)
/// ```
///
/// This macro validates the directory path syntax. The actual directory
/// functionality is provided by FDBRuntime.
@freestanding(declaration)
public macro Directory<T>(_ elements: Any..., layer: DirectoryLayer = .recordStore) = #externalMacro(module: "FDBCoreMacros", type: "DirectoryMacro")

/// Directory layer type
///
/// Used by #Directory macro to specify the directory layer type.
public enum DirectoryLayer: String, Sendable, Codable {
    /// Standard RecordStore directory (default)
    case recordStore = "record_store"

    /// Multi-tenant partition (requires at least one Field in path)
    case partition = "partition"
}

/// Field reference for dynamic directory paths
///
/// Used in #Directory macro to reference record fields.
///
/// **Example**:
/// ```swift
/// #Directory<Order>("tenants", Field(\.accountID), "orders")
/// ```
public struct Field<T, V> {
    public let keyPath: KeyPath<T, V>

    public init(_ keyPath: KeyPath<T, V>) {
        self.keyPath = keyPath
    }
}
