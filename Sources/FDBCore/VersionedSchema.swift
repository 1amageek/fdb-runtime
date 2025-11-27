import Foundation
import FDBModel

/// VersionedSchema - SwiftData-compatible protocol for defining schema versions
///
/// **Design**: Each schema version is represented as a type conforming to this protocol.
/// This enables type-safe schema evolution with compile-time checks.
///
/// **Example usage**:
/// ```swift
/// enum AppSchemaV1: VersionedSchema {
///     static let versionIdentifier = Schema.Version(1, 0, 0)
///     static let models: [any Persistable.Type] = [User.self, Order.self]
///
///     @Persistable
///     struct User {
///         var id: String = ULID().ulidString
///         var name: String
///         var email: String
///
///         #Index<User>([\.email], unique: true)
///     }
///
///     @Persistable
///     struct Order {
///         var id: String = ULID().ulidString
///         var userId: String
///         var total: Double
///     }
/// }
///
/// enum AppSchemaV2: VersionedSchema {
///     static let versionIdentifier = Schema.Version(2, 0, 0)
///     static let models: [any Persistable.Type] = [User.self, Order.self]
///
///     @Persistable
///     struct User {
///         var id: String = ULID().ulidString
///         var name: String
///         var email: String
///         var age: Int = 0  // New field
///
///         #Index<User>([\.email], unique: true)
///         #Index<User>([\.age])  // New index
///     }
///
///     // Order unchanged, can be re-exported
///     typealias Order = AppSchemaV1.Order
/// }
///
/// // Type alias for current schema
/// typealias User = AppSchemaV2.User
/// typealias Order = AppSchemaV2.Order
/// ```
public protocol VersionedSchema: Sendable {
    /// Schema version identifier
    ///
    /// Uniquely identifies this schema version using semantic versioning.
    static var versionIdentifier: Schema.Version { get }

    /// Persistable types included in this schema version
    ///
    /// List all model types that exist in this schema version.
    /// Order doesn't matter for functionality, but consistent ordering
    /// helps with debugging and migration comparisons.
    static var models: [any Persistable.Type] { get }
}

// MARK: - VersionedSchema Extensions

extension VersionedSchema {
    /// Create a Schema instance from this VersionedSchema
    ///
    /// Converts the protocol type to a concrete Schema object that can be
    /// used with FDBContainer.
    ///
    /// - Returns: Schema instance with version and models
    public static func makeSchema() -> Schema {
        return Schema(models, version: versionIdentifier)
    }

    /// Get all index descriptors from models in this schema version
    ///
    /// Aggregates indexDescriptors from all Persistable types.
    ///
    /// - Returns: Array of all index descriptors
    public static var allIndexDescriptors: [IndexDescriptor] {
        return models.flatMap { $0.indexDescriptors }
    }

    /// Get all index names from this schema version
    ///
    /// - Returns: Set of index names
    public static var indexNames: Set<String> {
        return Set(allIndexDescriptors.map(\.name))
    }
}

// MARK: - Schema Comparison Helpers

extension VersionedSchema {
    /// Compare indexes between two schema versions
    ///
    /// Returns the differences in indexes between this schema and another.
    ///
    /// - Parameter other: Another VersionedSchema type
    /// - Returns: Tuple of (added indexes, removed indexes)
    public static func indexChanges(
        from other: any VersionedSchema.Type
    ) -> (added: Set<String>, removed: Set<String>) {
        let currentIndexes = Self.indexNames
        let otherIndexes = other.indexNames

        let added = currentIndexes.subtracting(otherIndexes)
        let removed = otherIndexes.subtracting(currentIndexes)

        return (added: added, removed: removed)
    }

    /// Check if migration from another schema is a "lightweight" migration
    ///
    /// A lightweight migration only involves index additions/removals and
    /// field additions (with defaults). No data transformation is needed.
    ///
    /// - Parameter other: Previous schema version
    /// - Returns: true if lightweight migration is possible
    public static func canLightweightMigrate(
        from other: any VersionedSchema.Type
    ) -> Bool {
        // Get field changes
        let currentFields = Set(models.flatMap { $0.allFields })
        let otherFields = Set(other.models.flatMap { $0.allFields })

        // Field removal requires custom migration (data loss)
        let removedFields = otherFields.subtracting(currentFields)
        if !removedFields.isEmpty {
            return false
        }

        // Index changes are always lightweight
        // Field additions are lightweight (new fields get default values)
        return true
    }
}
