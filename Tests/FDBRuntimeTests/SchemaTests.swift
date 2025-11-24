import Testing
import Foundation
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
        static let persistableType = "User"
        static let primaryKeyFields = ["userID"]
        static let allFields = ["userID", "email", "name"]

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
            case "userID": return 1
            case "email": return 2
            case "name": return 3
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? {
            return nil
        }

        var userID: Int64
        var email: String
        var name: String
    }

    struct Order: Persistable, Codable, Sendable {
        static let persistableType = "Order"
        static let primaryKeyFields = ["orderID"]
        static let allFields = ["orderID", "userID", "amount"]

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
            case "orderID": return 1
            case "userID": return 2
            case "amount": return 3
            default: return nil
            }
        }

        static func enumMetadata(for fieldName: String) -> EnumMetadata? {
            return nil
        }

        var orderID: Int64
        var userID: Int64
        var amount: Double
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
        #expect(userEntity?.allFields == ["userID", "email", "name"])

        let orderEntity = schema.entity(for: Order.self)
        #expect(orderEntity != nil)
        #expect(orderEntity?.name == "Order")
        #expect(orderEntity?.allFields == ["orderID", "userID", "amount"])
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
}
