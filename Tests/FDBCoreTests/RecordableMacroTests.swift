import Testing
import Foundation
import FDBCore
import FDBIndexing

/// Tests for @Model macro
@Suite("@Model Macro Tests")
struct ModelMacroTests {

    /// Test basic @Model expansion
    @Test("Basic @Model with PrimaryKey")
    func basicModel() {
        // Verify generated properties
        #expect(BasicUser.modelName == "BasicUser")
        #expect(BasicUser.primaryKeyFields == ["userID"])
        #expect(BasicUser.allFields == ["userID", "email", "name"])
        #expect(BasicUser.indexDescriptors.isEmpty)
    }

    /// Test @Model with #Index
    @Test("@Model with single Index")
    func modelWithIndex() {
        // Verify index descriptors
        #expect(IndexedUser.indexDescriptors.count == 1)

        let emailIndex = IndexedUser.indexDescriptors[0]
        #expect(emailIndex.name == "IndexedUser_email")
        #expect(emailIndex.keyPaths == ["email"])
        #expect(emailIndex.kindIdentifier == "scalar")
        #expect(emailIndex.isUnique == true)
    }

    /// Test @Model with multiple indexes
    @Test("@Model with multiple indexes")
    func modelWithMultipleIndexes() {
        // Verify multiple indexes
        #expect(Product.indexDescriptors.count == 2)

        // First index: category
        let categoryIndex = Product.indexDescriptors[0]
        #expect(categoryIndex.name == "Product_category")
        #expect(categoryIndex.keyPaths == ["category"])
        #expect(categoryIndex.kindIdentifier == "scalar")
        #expect(categoryIndex.isUnique == false)

        // Second index: category + price
        let compositeIndex = Product.indexDescriptors[1]
        #expect(compositeIndex.name == "Product_category_price")
        #expect(compositeIndex.keyPaths == ["category", "price"])
        #expect(compositeIndex.kindIdentifier == "scalar")
    }

    /// Test @Model with custom index name
    @Test("@Model with custom index name")
    func modelWithCustomIndexName() {
        // Verify custom index name
        #expect(CustomNamedUser.indexDescriptors.count == 1)
        let emailIndex = CustomNamedUser.indexDescriptors[0]
        #expect(emailIndex.name == "user_email_idx")
    }

    /// Test @Model with composite primary key
    @Test("@Model with composite primary key")
    func modelWithCompositePrimaryKey() {
        // Verify composite primary key
        #expect(Order.primaryKeyFields == ["accountID", "orderID"])
        #expect(Order.allFields == ["accountID", "orderID", "amount"])
    }

    /// Test @Model fieldNumber generation
    @Test("fieldNumber method generates sequential numbers")
    func fieldNumberGeneration() {
        // Verify field numbers
        #expect(FieldNumberUser.fieldNumber(for: "userID") == 1)
        #expect(FieldNumberUser.fieldNumber(for: "email") == 2)
        #expect(FieldNumberUser.fieldNumber(for: "name") == 3)
        #expect(FieldNumberUser.fieldNumber(for: "nonexistent") == nil)
    }

    /// Test @Model with different IndexKinds
    @Test("@Model with different IndexKind types")
    func modelWithDifferentIndexKinds() {
        // Verify different index kinds
        #expect(Analytics.indexDescriptors.count == 3)

        let scalarIndex = Analytics.indexDescriptors[0]
        #expect(scalarIndex.kindIdentifier == "scalar")

        let countIndex = Analytics.indexDescriptors[1]
        #expect(countIndex.kindIdentifier == "count")

        let sumIndex = Analytics.indexDescriptors[2]
        #expect(sumIndex.kindIdentifier == "sum")
    }

    /// Test @Model Codable conformance
    @Test("@Model generates Codable conformance")
    func modelCodableConformance() throws {
        let user = CodableUser(userID: 1, email: "test@example.com", name: "Alice")

        // Verify Codable works
        let encoder = JSONEncoder()
        let data = try encoder.encode(user)
        #expect(data.count > 0)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CodableUser.self, from: data)
        #expect(decoded.userID == user.userID)
        #expect(decoded.email == user.email)
        #expect(decoded.name == user.name)
    }

    /// Test @Model Sendable conformance
    @Test("@Model generates Sendable conformance")
    func modelSendableConformance() {
        // This test verifies that the compiler accepts User as Sendable
        let _: any Sendable = SendableUser(userID: 1, email: "test@example.com")
    }
}

// MARK: - Test Structs (File Scope)

@Model
struct BasicUser {
    #PrimaryKey<BasicUser>([\.userID])

    var userID: Int64
    var email: String
    var name: String
}

@Model
struct IndexedUser {
    #PrimaryKey<IndexedUser>([\.userID])
    #Index<IndexedUser>([\.email], type: ScalarIndexKind(), unique: true)

    var userID: Int64
    var email: String
    var name: String
}

@Model
struct Product {
    #PrimaryKey<Product>([\.productID])
    #Index<Product>([\.category], type: ScalarIndexKind())
    #Index<Product>([\.category, \.price], type: ScalarIndexKind())

    var productID: Int64
    var category: String
    var price: Double
    var name: String
}

@Model
struct CustomNamedUser {
    #PrimaryKey<CustomNamedUser>([\.userID])
    #Index<CustomNamedUser>([\.email], type: ScalarIndexKind(), name: "user_email_idx")

    var userID: Int64
    var email: String
}

@Model
struct Order {
    #PrimaryKey<Order>([\.accountID, \.orderID])

    var accountID: String
    var orderID: Int64
    var amount: Double
}

@Model
struct FieldNumberUser {
    #PrimaryKey<FieldNumberUser>([\.userID])

    var userID: Int64
    var email: String
    var name: String
}

@Model
struct Analytics {
    #PrimaryKey<Analytics>([\.eventID])
    #Index<Analytics>([\.category], type: ScalarIndexKind())
    #Index<Analytics>([\.category], type: CountIndexKind())
    #Index<Analytics>([\.category, \.value], type: SumIndexKind())

    var eventID: Int64
    var category: String
    var value: Double
}

@Model
struct CodableUser {
    #PrimaryKey<CodableUser>([\.userID])

    var userID: Int64
    var email: String
    var name: String
}

@Model
struct SendableUser {
    #PrimaryKey<SendableUser>([\.userID])

    var userID: Int64
    var email: String
}
