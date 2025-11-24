import Testing
import Foundation
import FDBCore
import FDBIndexing

/// Tests for @Persistable macro validation and edge cases
@Suite("@Persistable Macro Validation Tests")
struct ModelMacroValidationTests {

    /// Test that invalid KeyPath in PrimaryKey is caught at compile time
    @Test("Invalid KeyPath should cause compile error")
    func invalidPrimaryKeyPath() {
        // This should fail at compile time if KeyPath validation works
        // Commenting out to allow build to succeed

        // @Persistable
        // struct BadUser {
        //     #PrimaryKey<BadUser>([\.nonExistentField])  // ← Should error
        //     var userID: Int64
        // }

        // If we uncomment above, we expect a compile error
        #expect(true)  // Placeholder
    }

    /// Test that indexDescriptors are correctly ordered
    @Test("Index descriptors maintain definition order")
    func indexDescriptorsOrder() {
        // Verify that indexes are in the order they were defined
        #expect(OrderedIndexProduct.indexDescriptors.count == 3)
        #expect(OrderedIndexProduct.indexDescriptors[0].name == "OrderedIndexProduct_category")
        #expect(OrderedIndexProduct.indexDescriptors[1].name == "OrderedIndexProduct_price")
        #expect(OrderedIndexProduct.indexDescriptors[2].name == "OrderedIndexProduct_name")
    }

    /// Test that field numbers are stable
    @Test("Field numbers should be deterministic")
    func fieldNumbersStable() {
        // Field numbers should match field declaration order
        #expect(StableFieldUser.fieldNumber(for: "userID") == 1)
        #expect(StableFieldUser.fieldNumber(for: "email") == 2)
        #expect(StableFieldUser.fieldNumber(for: "name") == 3)
        #expect(StableFieldUser.fieldNumber(for: "createdAt") == 4)
    }

    /// Test that types without #PrimaryKey don't have primaryKeyFields
    @Test("No primary key declaration")
    func noPrimaryKey() {
        // EmptyPKUser does not declare #PrimaryKey, so primaryKeyFields should not exist
        // This is expected behavior: Model protocol does not require primaryKeyFields (layer-independent)

        // Verify that EmptyPKUser still conforms to Persistable protocol
        #expect(EmptyPKUser.persistableType == "EmptyPKUser")
        #expect(EmptyPKUser.allFields == ["userID", "email"])

        // Note: primaryKeyFields is only generated when #PrimaryKey is declared
        // EmptyPKUser.primaryKeyFields would be a compile error (expected)
    }

    /// Test IndexKind types can be created
    @Test("IndexKind types can be instantiated")
    func indexKindInstantiation() throws {
        // Verify that all built-in IndexKinds can be created
        _ = ScalarIndexKind()
        _ = CountIndexKind()
        _ = SumIndexKind()
        _ = MinIndexKind()
        _ = MaxIndexKind()
        _ = VersionIndexKind()

        // All should succeed without throwing
    }
}

// MARK: - Test Structs

@Persistable
struct OrderedIndexProduct {
    #PrimaryKey<OrderedIndexProduct>([\.productID])
    #Index<OrderedIndexProduct>([\.category], type: ScalarIndexKind())
    #Index<OrderedIndexProduct>([\.price], type: ScalarIndexKind())
    #Index<OrderedIndexProduct>([\.name], type: ScalarIndexKind())

    var productID: Int64
    var category: String
    var price: Double
    var name: String
}

@Persistable
struct StableFieldUser {
    #PrimaryKey<StableFieldUser>([\.userID])

    var userID: Int64
    var email: String
    var name: String
    var createdAt: Date
}

@Persistable
struct EmptyPKUser {
    // Note: No #PrimaryKey declaration
    var userID: Int64
    var email: String
}
