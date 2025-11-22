import Foundation
import FDBIndexing

/// @Model macro declaration
///
/// Generates Model protocol conformance with metadata methods.
///
/// **Supports all layers**:
/// - RecordLayer (RDB): Use #PrimaryKey for relational model
/// - DocumentLayer (DocumentDB): No #PrimaryKey, auto-generates ObjectID
/// - GraphLayer (GraphDB): Define nodes with relationships
///
/// **Usage**:
/// ```swift
/// @Model
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
/// - static var modelName: String
/// - static var allFields: [String]
/// - static var indexDescriptors: [IndexDescriptor]
/// - static var primaryKeyFields: [String] (if #PrimaryKey exists)
/// - static func fieldNumber(for fieldName: String) -> Int?
/// - static func enumMetadata(for fieldName: String) -> EnumMetadata?
///
/// **Note**: primaryKeyFields is only generated if #PrimaryKey is declared.
/// The Model protocol itself does not require primaryKeyFields (layer-independent).
@attached(member, names: named(modelName), named(primaryKeyFields), named(allFields), named(indexDescriptors), named(fieldNumber), named(enumMetadata))
@attached(extension, conformances: Model, Codable, Sendable)
public macro Model() = #externalMacro(module: "FDBCoreMacros", type: "ModelMacro")

/// @Recordable macro (backward compatibility)
@available(*, deprecated, renamed: "Model")
@attached(member, names: named(modelName), named(primaryKeyFields), named(allFields), named(indexDescriptors), named(fieldNumber), named(enumMetadata))
@attached(extension, conformances: Model, Codable, Sendable)
public macro Recordable() = #externalMacro(module: "FDBCoreMacros", type: "ModelMacro")

/// #PrimaryKey macro declaration
///
/// Declares primary key fields for a record.
///
/// **Usage**:
/// ```swift
/// #PrimaryKey<User>([\.userID])
/// #PrimaryKey<User>([\.country, \.userID])  // Composite key
/// ```
///
/// This is a marker macro. The @Recordable macro reads the #PrimaryKey declaration
/// and generates the primaryKeyFields property.
@freestanding(declaration)
public macro PrimaryKey<T>(_ keyPaths: [PartialKeyPath<T>]) = #externalMacro(module: "FDBCoreMacros", type: "PrimaryKeyMacro")

/// #Index macro declaration
///
/// Declares an index on specified fields.
///
/// **Usage**:
/// ```swift
/// #Index<User>([\.email], type: ScalarIndexKind(), unique: true)
/// #Index<User>([\.country, \.city], type: ScalarIndexKind())
/// #Index<User>([\.embedding], type: VectorIndexKind(dimensions: 384))
/// ```
///
/// This is a marker macro. The @Recordable macro reads the #Index declaration
/// and generates the indexDescriptors array.
///
/// **Parameters**:
/// - keyPaths: Array of KeyPaths to indexed fields
/// - type: IndexKind implementation (default: ScalarIndexKind())
/// - unique: Uniqueness constraint (default: false)
/// - name: Custom index name (default: auto-generated from field names)
@freestanding(declaration)
public macro Index<T>(
    _ keyPaths: [PartialKeyPath<T>],
    type: any IndexKindProtocol = ScalarIndexKind(),
    unique: Bool = false,
    name: String? = nil
) = #externalMacro(module: "FDBCoreMacros", type: "IndexMacro")

/// #Directory macro declaration
///
/// Declares directory path for a record type (for FDBRuntime).
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
