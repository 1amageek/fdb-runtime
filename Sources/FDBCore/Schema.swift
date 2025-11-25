import Foundation
import FDBModel
import Synchronization

/// Schema - Type-independent schema management
///
/// **Design**: FDBRuntime's type-independent schema definition
/// - Uses Entity (metadata) with field names and IndexDescriptor
/// - Uses IndexDescriptor (metadata) instead of Index (runtime)
/// - Supports all upper layers (record-layer, graph-layer, document-layer)
///
/// **Example usage**:
/// ```swift
/// let schema = Schema(
///     [User.self, Order.self, Message.self],
///     version: Schema.Version(1, 0, 0)
/// )
///
/// // Entity access
/// let userEntity = schema.entity(for: User.self)
/// print("Indices: \(userEntity?.indexDescriptors ?? [])")
/// ```
public final class Schema: Sendable {

    // MARK: - Version

    /// Schema version
    ///
    /// Uses semantic versioning:
    /// - major: Incompatible changes
    /// - minor: Backward-compatible feature additions
    /// - patch: Backward-compatible bug fixes
    public struct Version: Sendable, Hashable, Codable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        /// Create a version
        ///
        /// - Parameters:
        ///   - major: Major version
        ///   - minor: Minor version
        ///   - patch: Patch version
        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String {
            return "\(major).\(minor).\(patch)"
        }

        // Codable
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.major = try container.decode(Int.self, forKey: .major)
            self.minor = try container.decode(Int.self, forKey: .minor)
            self.patch = try container.decode(Int.self, forKey: .patch)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(major, forKey: .major)
            try container.encode(minor, forKey: .minor)
            try container.encode(patch, forKey: .patch)
        }

        private enum CodingKeys: String, CodingKey {
            case major, minor, patch
        }
    }

    // MARK: - Entity

    /// Entity metadata (type-independent)
    ///
    /// Corresponds to a Persistable type's metadata.
    public struct Entity: Sendable {
        /// Entity name (same as Persistable.persistableType)
        public let name: String

        /// All field names
        public let allFields: [String]

        /// Index descriptors (metadata only)
        public let indexDescriptors: [IndexDescriptor]

        /// Enum metadata for enum fields
        public let enumMetadata: [String: EnumMetadata]

        /// Initialize from Persistable type
        public init(from type: any Persistable.Type) {
            self.name = type.persistableType
            self.allFields = type.allFields
            self.indexDescriptors = type.indexDescriptors

            // Extract enum metadata
            var enumMeta: [String: EnumMetadata] = [:]
            for field in type.allFields {
                if let meta = type.enumMetadata(for: field) {
                    enumMeta[field] = meta
                }
            }
            self.enumMetadata = enumMeta
        }

        /// Manual initializer for testing
        public init(
            name: String,
            allFields: [String],
            indexDescriptors: [IndexDescriptor],
            enumMetadata: [String: EnumMetadata] = [:]
        ) {
            self.name = name
            self.allFields = allFields
            self.indexDescriptors = indexDescriptors
            self.enumMetadata = enumMetadata
        }
    }

    // MARK: - Properties

    /// Schema version
    public let version: Version

    /// Encoding version (for compatibility)
    public let encodingVersion: Version

    /// All entities
    public let entities: [Entity]

    /// Access entities by name
    public let entitiesByName: [String: Entity]

    /// Former indexes (schema evolution)
    /// Records of deleted indexes (schema definition only)
    public let formerIndexes: [String: FormerIndex]

    /// Index descriptors (metadata only)
    public let indexDescriptors: [IndexDescriptor]

    /// Indexes by name for quick lookup
    internal let indexDescriptorsByName: [String: IndexDescriptor]

    // MARK: - Initialization

    /// Create schema from array of Persistable types
    ///
    /// - Parameters:
    ///   - types: Array of Persistable types
    ///   - version: Schema version
    ///   - indexDescriptors: Additional index descriptors (optional, merged with type-defined indexes)
    ///
    /// **Index Collection**:
    /// This initializer automatically collects IndexDescriptors from types:
    /// 1. Collects `indexDescriptors` from each Persistable type (defined by macros)
    /// 2. Merges with manually provided indexDescriptors
    ///
    /// **Example usage**:
    /// ```swift
    /// let schema = Schema([User.self, Order.self])  // Indexes auto-collected
    /// ```
    public init(
        _ types: [any Persistable.Type],
        version: Version = Version(1, 0, 0),
        indexDescriptors: [IndexDescriptor] = []
    ) {
        self.version = version
        self.encodingVersion = version

        // Build entities
        var entities: [Entity] = []
        var entitiesByName: [String: Entity] = [:]

        for type in types {
            let entity = Entity(from: type)
            entities.append(entity)
            entitiesByName[entity.name] = entity
        }

        self.entities = entities
        self.entitiesByName = entitiesByName

        // Collect index descriptors from types
        var allIndexDescriptors: [IndexDescriptor] = []

        for type in types {
            // Get IndexDescriptors from type (generated by macros)
            let descriptors = type.indexDescriptors
            allIndexDescriptors.append(contentsOf: descriptors)
        }

        // Merge with manually provided descriptors
        allIndexDescriptors.append(contentsOf: indexDescriptors)

        // Store index descriptors
        self.indexDescriptors = allIndexDescriptors
        var indexDescriptorsByName: [String: IndexDescriptor] = [:]
        for descriptor in allIndexDescriptors {
            indexDescriptorsByName[descriptor.name] = descriptor
        }
        self.indexDescriptorsByName = indexDescriptorsByName

        // Former indexes (empty for now, future: migration support)
        self.formerIndexes = [:]
    }

    /// Test-only initializer for manual Schema construction
    ///
    /// - Parameters:
    ///   - entities: Array of Entity objects
    ///   - version: Schema version
    ///   - indexDescriptors: Index descriptors (optional)
    public init(
        entities: [Entity],
        version: Version = Version(1, 0, 0),
        indexDescriptors: [IndexDescriptor] = []
    ) {
        self.version = version
        self.encodingVersion = version

        // Build entity maps
        var entitiesByName: [String: Entity] = [:]
        for entity in entities {
            entitiesByName[entity.name] = entity
        }

        self.entities = entities
        self.entitiesByName = entitiesByName

        // Store index descriptors
        self.indexDescriptors = indexDescriptors
        var indexDescriptorsByName: [String: IndexDescriptor] = [:]
        for descriptor in indexDescriptors {
            indexDescriptorsByName[descriptor.name] = descriptor
        }
        self.indexDescriptorsByName = indexDescriptorsByName

        // Former indexes (empty for test schemas)
        self.formerIndexes = [:]
    }

    // MARK: - Entity Access

    /// Get entity for type
    ///
    /// - Parameter type: Persistable type
    /// - Returns: Entity (nil if not found)
    public func entity<T: Persistable>(for type: T.Type) -> Entity? {
        return entitiesByName[T.persistableType]
    }

    /// Get entity by name
    ///
    /// - Parameter name: Entity name
    /// - Returns: Entity (nil if not found)
    public func entity(named name: String) -> Entity? {
        return entitiesByName[name]
    }

    // MARK: - Index Access

    /// Get index descriptor by name
    ///
    /// - Parameter name: Index name
    /// - Returns: IndexDescriptor (nil if not found)
    public func indexDescriptor(named name: String) -> IndexDescriptor? {
        return indexDescriptorsByName[name]
    }

    /// Get index descriptors for a specific item type
    ///
    /// Returns all index descriptors from the entity's indexDescriptors.
    ///
    /// - Parameter itemType: The item type name
    /// - Returns: Array of applicable index descriptors
    public func indexDescriptors(for itemType: String) -> [IndexDescriptor] {
        guard let entity = entitiesByName[itemType] else {
            return []
        }
        return entity.indexDescriptors
    }
}

// MARK: - CustomDebugStringConvertible

extension Schema: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "Schema(version: \(version), entities: \(entities.count))"
    }
}

// MARK: - Equatable

extension Schema: Equatable {
    public static func == (lhs: Schema, rhs: Schema) -> Bool {
        // Compare versions
        guard lhs.version == rhs.version else {
            return false
        }

        // Compare entity names (Entity is not Equatable due to IndexDescriptor)
        let lhsNames = Set(lhs.entitiesByName.keys)
        let rhsNames = Set(rhs.entitiesByName.keys)
        return lhsNames == rhsNames
    }
}

// MARK: - Hashable

extension Schema: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        // Use sorted entity names to ensure order-independent hashing
        for name in entitiesByName.keys.sorted() {
            hasher.combine(name)
        }
    }
}

// MARK: - Schema.Version Comparable

extension Schema.Version: Comparable {
    public static func < (lhs: Schema.Version, rhs: Schema.Version) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

// MARK: - FormerIndex

/// Former index metadata (for schema evolution)
///
/// Records when an index was added and removed, helping with
/// schema migration and backward compatibility.
public struct FormerIndex: Sendable, Hashable, Equatable {
    /// Index name
    public let name: String

    /// Version when the index was originally added
    public let addedVersion: Schema.Version

    /// Timestamp when the index was removed (seconds since epoch)
    public let removedTimestamp: Double

    public init(
        name: String,
        addedVersion: Schema.Version,
        removedTimestamp: Double
    ) {
        self.name = name
        self.addedVersion = addedVersion
        self.removedTimestamp = removedTimestamp
    }
}
