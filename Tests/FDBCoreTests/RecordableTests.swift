import Testing
import Foundation
import FDBIndexing
@testable import FDBCore

@Suite("Model Protocol Tests")
struct ModelProtocolTests {

    // Test struct implementing Model manually
    struct TestUser: Model {
        static var modelName: String { "TestUser" }
        static var primaryKeyFields: [String] { ["userID"] }
        static var allFields: [String] { ["userID", "email", "name"] }
        static var indexDescriptors: [IndexDescriptor] { [] }

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

    @Test("Model modelName")
    func testModelName() {
        #expect(TestUser.modelName == "TestUser")
    }

    @Test("Model primaryKeyFields")
    func testPrimaryKeyFields() {
        #expect(TestUser.primaryKeyFields == ["userID"])
    }

    @Test("Model allFields")
    func testAllFields() {
        #expect(TestUser.allFields == ["userID", "email", "name"])
    }

    @Test("Model fieldNumber")
    func testFieldNumber() {
        #expect(TestUser.fieldNumber(for: "userID") == 1)
        #expect(TestUser.fieldNumber(for: "email") == 2)
        #expect(TestUser.fieldNumber(for: "name") == 3)
        #expect(TestUser.fieldNumber(for: "unknown") == nil)
    }

    @Test("Model Codable conformance")
    func testCodable() throws {
        let user = TestUser(userID: 1, email: "test@example.com", name: "Alice")

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(user)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TestUser.self, from: data)

        #expect(decoded.userID == user.userID)
        #expect(decoded.email == user.email)
        #expect(decoded.name == user.name)
    }

    @Test("Model Sendable conformance")
    func testSendable() {
        // If this compiles, Sendable conformance is working
        let user = TestUser(userID: 1, email: "test@example.com", name: "Alice")

        Task {
            let _ = user  // Can be captured in async context
        }

        #expect(user.userID == 1)
    }
}
