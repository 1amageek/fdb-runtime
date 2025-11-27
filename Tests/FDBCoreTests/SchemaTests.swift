import Testing
import Foundation
import FDBModel
@testable import FDBRuntime
@testable import FDBCore
@testable import FDBIndexing

/// Tests for Schema functionality
///
/// **Coverage**:
/// - Schema initialization from Persistable types
/// - IndexDescriptor collection from multiple entities
/// - Entity lookup by type and name
/// - Version comparison and equality
@Suite("Schema Tests")
struct SchemaTests {

    // MARK: - Test Types

    struct User: Persistable, Codable, Sendable {
        typealias ID = Int64

        var id: Int64 = Int64.random(in: 1...Int64.max)

        static let persistableType = "User"
        static let allFields = ["id", "email", "name"]

        static let indexDescriptors: [IndexDescriptor] = [
            IndexDescriptor(
                name: "User_email",
                keyPaths: ["email"],
                kind: ScalarIndexKind(),
                commonOptions: .init(unique: true)
            )
        ]

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "id": return 1
            case "email": return 2
            case "name": return 3
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? {
            return nil
        }

        var email: String
        var name: String

        subscript(dynamicMember member: String) -> (any Sendable)? {
            switch member {
            case "id": return id
            case "email": return email
            case "name": return name
            default: return nil
            }
        }
    }

    struct Order: Persistable, Codable, Sendable {
        typealias ID = Int64

        var id: Int64 = Int64.random(in: 1...Int64.max)

        static let persistableType = "Order"
        static let allFields = ["id", "userID", "amount"]

        static let indexDescriptors: [IndexDescriptor] = [
            IndexDescriptor(
                name: "Order_userID",
                keyPaths: ["userID"],
                kind: ScalarIndexKind(),
                commonOptions: .init()
            ),
            IndexDescriptor(
                name: "Order_amount",
                keyPaths: ["amount"],
                kind: ScalarIndexKind(),
                commonOptions: .init()
            )
        ]

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "id": return 1
            case "userID": return 2
            case "amount": return 3
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? {
            return nil
        }

        var userID: Int64
        var amount: Double

        subscript(dynamicMember member: String) -> (any Sendable)? {
            switch member {
            case "id": return id
            case "userID": return userID
            case "amount": return amount
            default: return nil
            }
        }
    }

    // MARK: - Tests

    /// Test: Schema collects indexDescriptors from multiple entities
    @Test("Schema collects indexDescriptors from multiple entities")
    func schemaCollectsIndexDescriptors() {
        let schema = Schema([User.self, Order.self], version: Schema.Version(1, 0, 0))

        // Should have 3 indexes total (1 from User + 2 from Order)
        #expect(schema.indexDescriptors.count == 3)

        // Check User indexes
        let userIndexes = schema.indexDescriptors.filter { $0.name.hasPrefix("User_") }
        #expect(userIndexes.count == 1)
        #expect(userIndexes[0].name == "User_email")
        #expect(userIndexes[0].isUnique == true)

        // Check Order indexes
        let orderIndexes = schema.indexDescriptors.filter { $0.name.hasPrefix("Order_") }
        #expect(orderIndexes.count == 2)
        #expect(orderIndexes.contains(where: { $0.name == "Order_userID" }))
        #expect(orderIndexes.contains(where: { $0.name == "Order_amount" }))
    }

    /// Test: Schema allows manual indexDescriptor addition
    @Test("Schema merges manual indexDescriptors")
    func schemaMergesManualIndexDescriptors() {
        let manualIndex = IndexDescriptor(
            name: "Manual_index",
            keyPaths: ["field"],
            kind: ScalarIndexKind(),
            commonOptions: .init()
        )

        let schema = Schema(
            [User.self],
            version: Schema.Version(1, 0, 0),
            indexDescriptors: [manualIndex]
        )

        // Should have User_email + Manual_index = 2 indexes
        #expect(schema.indexDescriptors.count == 2)
        #expect(schema.indexDescriptor(named: "User_email") != nil)
        #expect(schema.indexDescriptor(named: "Manual_index") != nil)
    }

    /// Test: Entity lookup by type
    @Test("Entity lookup by type")
    func entityLookupByType() {
        let schema = Schema([User.self, Order.self])

        let userEntity = schema.entity(for: User.self)
        #expect(userEntity != nil)
        #expect(userEntity?.name == "User")
        #expect(userEntity?.allFields == ["id", "email", "name"])

        let orderEntity = schema.entity(for: Order.self)
        #expect(orderEntity != nil)
        #expect(orderEntity?.name == "Order")
        #expect(orderEntity?.allFields == ["id", "userID", "amount"])
    }

    /// Test: Entity lookup by name
    @Test("Entity lookup by name")
    func entityLookupByName() {
        let schema = Schema([User.self, Order.self])

        let userEntity = schema.entity(named: "User")
        #expect(userEntity != nil)
        #expect(userEntity?.name == "User")

        let orderEntity = schema.entity(named: "Order")
        #expect(orderEntity != nil)
        #expect(orderEntity?.name == "Order")

        let unknownEntity = schema.entity(named: "Unknown")
        #expect(unknownEntity == nil)
    }

    /// Test: IndexDescriptor lookup
    @Test("IndexDescriptor lookup")
    func indexDescriptorLookup() {
        let schema = Schema([User.self, Order.self])

        let emailIndex = schema.indexDescriptor(named: "User_email")
        #expect(emailIndex != nil)
        #expect(emailIndex?.name == "User_email")
        #expect(emailIndex?.keyPaths == ["email"])

        let unknownIndex = schema.indexDescriptor(named: "Unknown_index")
        #expect(unknownIndex == nil)
    }

    /// Test: IndexDescriptors for item type
    @Test("IndexDescriptors for item type")
    func indexDescriptorsForItemType() {
        let schema = Schema([User.self, Order.self])

        let userIndexes = schema.indexDescriptors(for: "User")
        #expect(userIndexes.count == 1)
        #expect(userIndexes[0].name == "User_email")

        let orderIndexes = schema.indexDescriptors(for: "Order")
        #expect(orderIndexes.count == 2)

        let unknownIndexes = schema.indexDescriptors(for: "Unknown")
        #expect(unknownIndexes.isEmpty)
    }

    /// Test: Version comparison
    @Test("Version comparison")
    func versionComparison() {
        let v100 = Schema.Version(1, 0, 0)
        let v110 = Schema.Version(1, 1, 0)
        let v200 = Schema.Version(2, 0, 0)

        #expect(v100 < v110)
        #expect(v110 < v200)
        #expect(v100 < v200)

        #expect(v200 > v110)
        #expect(v110 > v100)

        #expect(v100 == Schema.Version(1, 0, 0))
        #expect(v100 != v110)
    }

    /// Test: Schema equality
    @Test("Schema equality")
    func schemaEquality() {
        let schema1 = Schema([User.self, Order.self], version: Schema.Version(1, 0, 0))
        let schema2 = Schema([User.self, Order.self], version: Schema.Version(1, 0, 0))
        let schema3 = Schema([User.self], version: Schema.Version(1, 0, 0))
        let schema4 = Schema([User.self, Order.self], version: Schema.Version(2, 0, 0))

        // Same entities, same version
        #expect(schema1 == schema2)

        // Different entities
        #expect(schema1 != schema3)

        // Same entities, different version
        #expect(schema1 != schema4)
    }

    /// Test: Schema hashability
    @Test("Schema hashability")
    func schemaHashability() {
        let schema1 = Schema([User.self, Order.self], version: Schema.Version(1, 0, 0))
        let schema2 = Schema([User.self, Order.self], version: Schema.Version(1, 0, 0))

        var set = Set<Schema>()
        set.insert(schema1)
        set.insert(schema2)

        // Should only have 1 element (schemas are equal)
        #expect(set.count == 1)
    }

    /// Test: validateIndexNames passes for unique index names
    ///
    /// Note: As of the current implementation, Schema initializer enforces
    /// unique index names via preconditionFailure. This test verifies the
    /// validateIndexNames() method still works for valid schemas.
    @Test("validateIndexNames passes for unique index names")
    func validateIndexNamesPassesForUniqueNames() throws {
        let schema = Schema([User.self, Order.self])

        // Should not throw - all index names are unique
        // Note: Schema init already validates this, so this always passes
        try schema.validateIndexNames()
    }

    // Note: The test for duplicate index names has been removed because
    // Schema initializer now uses preconditionFailure to prevent duplicate
    // index names at initialization time. This is a developer error that
    // should be caught immediately during development.
    //
    // Creating a Schema with duplicate index names will crash the application,
    // which is the intended behavior for programming errors.

    // MARK: - Internal Consistency Tests

    /// Test: indexDescriptorsByName dictionary matches indexDescriptors array
    ///
    /// This test verifies that the internal data structures are consistent.
    /// Every index in indexDescriptors should be accessible via indexDescriptor(named:).
    @Test("indexDescriptorsByName matches indexDescriptors array")
    func indexDescriptorsByNameConsistency() {
        let schema = Schema([User.self, Order.self])

        // Every index in the array should be in the dictionary
        for descriptor in schema.indexDescriptors {
            let found = schema.indexDescriptor(named: descriptor.name)
            #expect(found != nil, "Index '\(descriptor.name)' not found in indexDescriptorsByName")
            #expect(found?.name == descriptor.name)
            #expect(found?.keyPaths == descriptor.keyPaths)
        }

        // Count should match
        #expect(schema.indexDescriptors.count == 3) // 1 User + 2 Order
    }

    /// Test: Entity.indexDescriptors matches schema.indexDescriptors(for:)
    ///
    /// Verifies that indexes retrieved by entity name match the entity's own indexes.
    @Test("Entity indexDescriptors matches schema indexDescriptors(for:)")
    func entityIndexDescriptorsConsistency() {
        let schema = Schema([User.self, Order.self])

        // User entity
        let userEntity = schema.entity(for: User.self)
        let userIndexesFromSchema = schema.indexDescriptors(for: "User")
        #expect(userEntity?.indexDescriptors.count == userIndexesFromSchema.count)

        for entityIndex in userEntity?.indexDescriptors ?? [] {
            let found = userIndexesFromSchema.contains { $0.name == entityIndex.name }
            #expect(found, "Entity index '\(entityIndex.name)' not found via schema.indexDescriptors(for:)")
        }

        // Order entity
        let orderEntity = schema.entity(for: Order.self)
        let orderIndexesFromSchema = schema.indexDescriptors(for: "Order")
        #expect(orderEntity?.indexDescriptors.count == orderIndexesFromSchema.count)
    }

    /// Test: Manual indexDescriptors are included in indexDescriptorsByName
    ///
    /// Verifies that manually added indexes are properly tracked.
    @Test("Manual indexDescriptors are in indexDescriptorsByName")
    func manualIndexDescriptorsInDictionary() {
        let manualIndex = IndexDescriptor(
            name: "Custom_manual_index",
            keyPaths: ["someField"],
            kind: ScalarIndexKind(),
            commonOptions: .init()
        )

        let schema = Schema(
            [User.self],
            version: Schema.Version(1, 0, 0),
            indexDescriptors: [manualIndex]
        )

        // Manual index should be accessible
        let found = schema.indexDescriptor(named: "Custom_manual_index")
        #expect(found != nil)
        #expect(found?.keyPaths == ["someField"])

        // Total count: 1 from User + 1 manual
        #expect(schema.indexDescriptors.count == 2)
    }

    // MARK: - Edge Case Tests

    /// Test: Empty schema (no entities)
    @Test("Empty schema with no entities")
    func emptySchema() {
        let schema = Schema([] as [any Persistable.Type])

        #expect(schema.entities.isEmpty)
        #expect(schema.indexDescriptors.isEmpty)
        #expect(schema.entity(named: "Unknown") == nil)
        #expect(schema.indexDescriptor(named: "Unknown") == nil)
    }

    /// Test: Entity without indexes
    struct NoIndexEntity: Persistable, Codable, Sendable {
        typealias ID = String
        var id: String = UUID().uuidString

        static let persistableType = "NoIndexEntity"
        static let allFields = ["id", "data"]
        static let indexDescriptors: [IndexDescriptor] = []

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "id": return 1
            case "data": return 2
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

        var data: String

        subscript(dynamicMember member: String) -> (any Sendable)? {
            switch member {
            case "id": return id
            case "data": return data
            default: return nil
            }
        }
    }

    @Test("Entity without indexes")
    func entityWithoutIndexes() {
        let schema = Schema([NoIndexEntity.self])

        let entity = schema.entity(for: NoIndexEntity.self)
        #expect(entity != nil)
        #expect(entity?.indexDescriptors.isEmpty == true)
        #expect(schema.indexDescriptors.isEmpty)
        #expect(schema.indexDescriptors(for: "NoIndexEntity").isEmpty)
    }

    /// Test: Composite index (multiple keyPaths)
    struct CompositeIndexEntity: Persistable, Codable, Sendable {
        typealias ID = String
        var id: String = UUID().uuidString

        static let persistableType = "CompositeIndexEntity"
        static let allFields = ["id", "field1", "field2", "field3"]
        static let indexDescriptors: [IndexDescriptor] = [
            IndexDescriptor(
                name: "CompositeIndexEntity_composite",
                keyPaths: ["field1", "field2", "field3"],
                kind: ScalarIndexKind(),
                commonOptions: .init()
            )
        ]

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "id": return 1
            case "field1": return 2
            case "field2": return 3
            case "field3": return 4
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

        var field1: String
        var field2: Int
        var field3: Bool

        subscript(dynamicMember member: String) -> (any Sendable)? {
            switch member {
            case "id": return id
            case "field1": return field1
            case "field2": return field2
            case "field3": return field3
            default: return nil
            }
        }
    }

    @Test("Composite index with multiple keyPaths")
    func compositeIndex() {
        let schema = Schema([CompositeIndexEntity.self])

        let index = schema.indexDescriptor(named: "CompositeIndexEntity_composite")
        #expect(index != nil)
        #expect(index?.keyPaths == ["field1", "field2", "field3"])
        #expect(index?.keyPaths.count == 3)
    }

    // MARK: - Index Options Preservation Tests

    /// Test: Unique option is preserved through Schema
    @Test("Index unique option is preserved")
    func indexUniqueOptionPreserved() {
        let schema = Schema([User.self, Order.self])

        // User_email is unique
        let emailIndex = schema.indexDescriptor(named: "User_email")
        #expect(emailIndex?.isUnique == true)
        #expect(emailIndex?.commonOptions.unique == true)

        // Order_userID is not unique
        let userIDIndex = schema.indexDescriptor(named: "Order_userID")
        #expect(userIDIndex?.isUnique == false)
        #expect(userIDIndex?.commonOptions.unique == false)
    }

    /// Test: Sparse option is preserved through Schema
    struct SparseIndexEntity: Persistable, Codable, Sendable {
        typealias ID = String
        var id: String = UUID().uuidString

        static let persistableType = "SparseIndexEntity"
        static let allFields = ["id", "optionalField"]
        static let indexDescriptors: [IndexDescriptor] = [
            IndexDescriptor(
                name: "SparseIndexEntity_optional",
                keyPaths: ["optionalField"],
                kind: ScalarIndexKind(),
                commonOptions: .init(sparse: true)
            )
        ]

        static func fieldNumber(for fieldName: String) -> Int? {
            switch fieldName {
            case "id": return 1
            case "optionalField": return 2
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

        var optionalField: String?

        subscript(dynamicMember member: String) -> (any Sendable)? {
            switch member {
            case "id": return id
            case "optionalField": return optionalField
            default: return nil
            }
        }
    }

    @Test("Index sparse option is preserved")
    func indexSparseOptionPreserved() {
        let schema = Schema([SparseIndexEntity.self])

        let index = schema.indexDescriptor(named: "SparseIndexEntity_optional")
        #expect(index?.commonOptions.sparse == true)
    }

    // MARK: - Initializer Consistency Tests

    /// Test: Schema(entities:) produces consistent results with entity-defined indexes
    @Test("Schema entities initializer collects indexes from entities")
    func schemaEntitiesInitializerConsistency() {
        // Create entities manually
        let userEntity = Schema.Entity(
            name: "TestUser",
            allFields: ["id", "email"],
            indexDescriptors: [
                IndexDescriptor(
                    name: "TestUser_email",
                    keyPaths: ["email"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init(unique: true)
                )
            ]
        )

        let schema = Schema(
            entities: [userEntity],
            version: Schema.Version(1, 0, 0)
        )

        // Index should be collected from entity
        #expect(schema.indexDescriptors.count == 1)
        #expect(schema.indexDescriptor(named: "TestUser_email") != nil)
        #expect(schema.indexDescriptor(named: "TestUser_email")?.isUnique == true)
    }

    /// Test: Schema(entities:) with additional manual indexDescriptors
    @Test("Schema entities initializer merges manual indexes")
    func schemaEntitiesInitializerMergesManualIndexes() {
        let entity = Schema.Entity(
            name: "TestEntity",
            allFields: ["id", "field1"],
            indexDescriptors: [
                IndexDescriptor(
                    name: "TestEntity_field1",
                    keyPaths: ["field1"],
                    kind: ScalarIndexKind(),
                    commonOptions: .init()
                )
            ]
        )

        let manualIndex = IndexDescriptor(
            name: "TestEntity_manual",
            keyPaths: ["field1", "id"],
            kind: ScalarIndexKind(),
            commonOptions: .init()
        )

        let schema = Schema(
            entities: [entity],
            version: Schema.Version(1, 0, 0),
            indexDescriptors: [manualIndex]
        )

        // Both indexes should be present
        #expect(schema.indexDescriptors.count == 2)
        #expect(schema.indexDescriptor(named: "TestEntity_field1") != nil)
        #expect(schema.indexDescriptor(named: "TestEntity_manual") != nil)
    }

    // MARK: - Version Edge Cases

    /// Test: Version with zero values
    @Test("Version with zero values")
    func versionWithZeros() {
        let v000 = Schema.Version(0, 0, 0)
        let v001 = Schema.Version(0, 0, 1)
        let v010 = Schema.Version(0, 1, 0)

        #expect(v000 < v001)
        #expect(v001 < v010)
        #expect(v000 < v010)
    }

    /// Test: Version string description
    @Test("Version string description")
    func versionDescription() {
        let version = Schema.Version(2, 5, 10)
        #expect(version.description == "2.5.10")
    }
}
