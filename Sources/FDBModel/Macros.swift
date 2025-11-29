import Foundation

/// @Persistable macro declaration
///
/// Generates Persistable protocol conformance with metadata methods and ID management.
///
/// **Supports all data model layers**:
/// - RecordLayer (RDB): Structured records with indexes
/// - DocumentLayer (DocumentDB): Flexible documents
/// - VectorLayer (Vector search): Use #Index with VectorIndexKind
/// - GraphLayer (GraphDB): Define nodes and edges with relationships
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     var id: String = ULID().ulidString  // Optional: auto-generated if omitted
///
///     #Directory<User>("users")
///     #Index<User>([\.email], unique: true)
///
///     var email: String
///     var name: String
/// }
/// ```
///
/// **With custom type name** (for renaming stability):
/// ```swift
/// @Persistable(type: "User")
/// struct Member {
///     var id: String = ULID().ulidString
///     var name: String
/// }
/// // persistableType = "User" (not "Member")
/// ```
///
/// **Generated code**:
/// - `var id: String = ULID().ulidString` (if not user-defined)
/// - `static var persistableType: String`
/// - `static var allFields: [String]`
/// - `static var indexDescriptors: [IndexDescriptor]`
/// - `static func fieldNumber(for fieldName: String) -> Int?`
/// - `static func enumMetadata(for fieldName: String) -> EnumMetadata?`
/// - `init(...)` (without `id` parameter)
///
/// **ID Behavior**:
/// - If user defines `id` field: uses that type and default value
/// - If user omits `id` field: macro adds `var id: String = ULID().ulidString`
/// - `id` is NOT included in the generated initializer
@attached(member, names: named(id), named(persistableType), named(allFields), named(indexDescriptors), named(fieldNumber), named(enumMetadata), named(subscript), named(init), named(fieldName), named(CodingKeys))
@attached(extension, conformances: Persistable, Codable, Sendable)
public macro Persistable() = #externalMacro(module: "FDBModelMacros", type: "PersistableMacro")

/// @Persistable macro with custom type name
///
/// **Usage**:
/// ```swift
/// @Persistable(type: "User")
/// struct Member {
///     var name: String
/// }
/// // persistableType = "User"
/// ```
@attached(member, names: named(id), named(persistableType), named(allFields), named(indexDescriptors), named(fieldNumber), named(enumMetadata), named(subscript), named(init), named(fieldName), named(CodingKeys))
@attached(extension, conformances: Persistable, Codable, Sendable)
public macro Persistable(type: String) = #externalMacro(module: "FDBModelMacros", type: "PersistableMacro")

/// #Index macro declaration
///
/// Declares an index on specified fields.
///
/// **Usage**:
/// ```swift
/// import FDBModel
///
/// @Persistable
/// struct Product {
///     var id: String = ULID().ulidString
///
///     // Standard index kinds (from FDBModel)
///     #Index<Product>([\.email], type: ScalarIndexKind(), unique: true)
///     #Index<Product>([\.category], type: CountIndexKind())
///
///     // If type is omitted, defaults to ScalarIndexKind()
///     #Index<Product>([\.name])
///
///     var email: String
///     var name: String
///     var category: String
/// }
/// ```
///
/// This is a marker macro. The @Persistable macro reads the #Index declaration
/// and generates the indexDescriptors array.
///
/// **Parameters**:
/// - keyPaths: Array of KeyPaths to indexed fields
/// - type: IndexKind implementation (default: ScalarIndexKind())
/// - unique: Uniqueness constraint (default: false)
/// - name: Custom index name (default: auto-generated from field names)
///
/// **Standard Index Kinds** (from FDBModel - FDB-independent):
/// - `ScalarIndexKind`: VALUE index for sorting and range queries (default)
/// - `CountIndexKind`: Count aggregation by grouping fields
/// - `SumIndexKind`: Sum aggregation by grouping fields
/// - `MinIndexKind`: Minimum value tracking by grouping fields
/// - `MaxIndexKind`: Maximum value tracking by grouping fields
/// - `VersionIndexKind`: Version tracking index
///
/// **Extended Index Kinds** (from fdb-indexes package - FDB-dependent):
/// - `VectorIndexKind`: Vector similarity search (HNSW, IVF, flat scan)
/// - `FullTextIndexKind`: Full-text search with inverted index
/// - Custom third-party implementations
@freestanding(declaration)
public macro Index<T: Persistable>(
    _ keyPaths: [PartialKeyPath<T>],
    type: any IndexKind = ScalarIndexKind(),
    unique: Bool = false,
    name: String? = nil
) = #externalMacro(module: "FDBModelMacros", type: "IndexMacro")

/// #Directory macro declaration
///
/// Declares directory path for a persistable type (for FDBRuntime).
///
/// **Usage**:
/// ```swift
/// #Directory<User>("app", "users")
/// #Directory<Order>("tenants", Field(\.tenantID), "orders", layer: .partition)
/// ```
///
/// This macro validates the directory path syntax. The actual directory
/// functionality is provided by FDBRuntime.
@freestanding(declaration)
public macro Directory<T>(_ elements: Any..., layer: DirectoryLayer = .recordStore) = #externalMacro(module: "FDBModelMacros", type: "DirectoryMacro")

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
/// #Directory<Order>("tenants", Field(\.tenantID), "orders")
/// ```
public struct Field<T, V> {
    public let keyPath: KeyPath<T, V>

    public init(_ keyPath: KeyPath<T, V>) {
        self.keyPath = keyPath
    }
}

// MARK: - @Transient Macro

/// @Transient macro declaration
///
/// Marks a property as transient (excluded from persistence and allFields).
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     var id: String = ULID().ulidString
///     var email: String
///     var name: String
///
///     @Transient
///     var cachedFullName: String?  // Not persisted to database
///
///     @Transient
///     var isOnline: Bool = false   // Runtime-only state
/// }
/// ```
///
/// **Effects**:
/// - Field is excluded from `allFields` array
/// - Field is excluded from Codable serialization
/// - Field is excluded from generated initializer
/// - Field is excluded from `subscript(dynamicMember:)`
///
/// **Requirements**:
/// - Field must have a default value (since it's excluded from initializer)
@attached(peer)
public macro Transient() = #externalMacro(module: "FDBModelMacros", type: "TransientMacro")
