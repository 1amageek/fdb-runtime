import Testing
import Foundation
@testable import FDBModel

/// Tests for @Persistable macro
@Suite("@Persistable Macro Tests")
struct ModelMacroTests {

    /// Test basic @Persistable expansion
    @Test("Basic @Persistable generates id and metadata")
    func basicModel() {
        // Verify generated properties
        #expect(BasicUser.persistableType == "BasicUser")
        #expect(BasicUser.allFields.contains("id"))
        #expect(BasicUser.allFields.contains("email"))
        #expect(BasicUser.allFields.contains("name"))
        #expect(BasicUser.indexDescriptors.isEmpty)

        // Verify auto-generated id
        let user = BasicUser(email: "test@example.com", name: "Alice")
        #expect(!user.id.isEmpty)
    }

    /// Test @Persistable with #Index
    @Test("@Persistable with single Index")
    func modelWithIndex() {
        // Verify index descriptors
        #expect(IndexedUser.indexDescriptors.count == 1)

        let emailIndex = IndexedUser.indexDescriptors[0]
        #expect(emailIndex.name == "IndexedUser_email")
        #expect(emailIndex.keyPaths == ["email"])
        #expect(emailIndex.kindIdentifier == "scalar")
        #expect(emailIndex.isUnique == true)
    }

    /// Test @Persistable with multiple indexes
    @Test("@Persistable with multiple indexes")
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

    /// Test @Persistable with custom index name
    @Test("@Persistable with custom index name")
    func modelWithCustomIndexName() {
        // Verify custom index name
        #expect(CustomNamedUser.indexDescriptors.count == 1)
        let emailIndex = CustomNamedUser.indexDescriptors[0]
        #expect(emailIndex.name == "user_email_idx")
    }

    /// Test @Persistable with custom type name
    @Test("@Persistable with custom type name")
    func modelWithCustomTypeName() {
        // Verify custom type name
        #expect(Member.persistableType == "User")
    }

    /// Test @Persistable with user-defined id
    @Test("@Persistable with user-defined id")
    func modelWithUserDefinedId() {
        // Verify user-defined id is used (with auto-generated default)
        let order = Order(orderID: 12345, amount: 99.99)
        #expect(order.id > 0)  // Auto-generated timestamp-based id
        #expect(Order.allFields.contains("id"))
    }

    /// Test @Persistable fieldNumber generation
    @Test("fieldNumber method generates sequential numbers")
    func fieldNumberGeneration() {
        // Verify field numbers (id is first if auto-generated)
        #expect(FieldNumberUser.fieldNumber(for: "id") == 1)
        #expect(FieldNumberUser.fieldNumber(for: "email") == 2)
        #expect(FieldNumberUser.fieldNumber(for: "name") == 3)
        #expect(FieldNumberUser.fieldNumber(for: "nonexistent") == nil)
    }

    /// Test @Persistable with different IndexKinds
    @Test("@Persistable with different IndexKind types")
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

    /// Test @Persistable Codable conformance
    @Test("@Persistable generates Codable conformance")
    func modelCodableConformance() throws {
        let user = CodableUser(email: "test@example.com", name: "Alice")

        // Verify Codable works
        let encoder = JSONEncoder()
        let data = try encoder.encode(user)
        #expect(data.count > 0)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CodableUser.self, from: data)
        #expect(decoded.id == user.id)
        #expect(decoded.email == user.email)
        #expect(decoded.name == user.name)
    }

    /// Test @Persistable Sendable conformance
    @Test("@Persistable generates Sendable conformance")
    func modelSendableConformance() {
        // This test verifies that the compiler accepts User as Sendable
        let _: any Sendable = SendableUser(email: "test@example.com")
    }

    /// Test @Persistable init without id parameter
    @Test("@Persistable init does not include id parameter")
    func initWithoutIdParameter() {
        // Create user without specifying id
        let user = BasicUser(email: "test@example.com", name: "Alice")

        // id should be auto-generated (ULID format: 26 characters)
        #expect(user.id.count == 26)
        #expect(!user.id.isEmpty)
    }

    /// Test @Persistable dynamic member lookup
    @Test("@Persistable supports dynamic member lookup")
    func dynamicMemberLookup() {
        let user = BasicUser(email: "test@example.com", name: "Alice")

        // Access fields via dynamic member lookup
        #expect(user[dynamicMember: "email"] as? String == "test@example.com")
        #expect(user[dynamicMember: "name"] as? String == "Alice")
        #expect(user[dynamicMember: "nonexistent"] == nil)
    }
}

// MARK: - Test Structs (File Scope)

@Persistable
struct BasicUser {
    var email: String
    var name: String
}

@Persistable
struct IndexedUser {
    #Index<IndexedUser>([\.email], type: ScalarIndexKind(), unique: true)

    var email: String
    var name: String
}

@Persistable
struct Product {
    #Index<Product>([\.category], type: ScalarIndexKind())
    #Index<Product>([\.category, \.price], type: ScalarIndexKind())

    var category: String
    var price: Double
    var name: String
}

@Persistable
struct CustomNamedUser {
    #Index<CustomNamedUser>([\.email], type: ScalarIndexKind(), name: "user_email_idx")

    var email: String
}

@Persistable(type: "User")
struct Member {
    var name: String
}

@Persistable
struct Order {
    var id: Int64 = Int64(Date().timeIntervalSince1970 * 1000)  // User-defined id with default
    var orderID: Int64
    var amount: Double
}

@Persistable
struct FieldNumberUser {
    var email: String
    var name: String
}

@Persistable
struct Analytics {
    #Index<Analytics>([\.category], type: ScalarIndexKind())
    #Index<Analytics>([\.category], type: CountIndexKind())
    #Index<Analytics>([\.category, \.value], type: SumIndexKind())

    var category: String
    var value: Double
}

@Persistable
struct CodableUser {
    var email: String
    var name: String
}

@Persistable
struct SendableUser {
    var email: String
}
