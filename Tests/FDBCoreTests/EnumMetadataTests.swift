import Testing
import Foundation
@testable import FDBCore

@Suite("EnumMetadata Tests")
struct EnumMetadataTests {

    @Test("EnumMetadata initialization")
    func testInit() {
        let metadata = EnumMetadata(
            typeName: "Status",
            cases: ["active", "inactive", "pending"]
        )

        #expect(metadata.typeName == "Status")
        #expect(metadata.cases == ["active", "inactive", "pending"])
    }

    @Test("EnumMetadata isValidCase - valid cases")
    func testIsValidCaseValid() {
        let metadata = EnumMetadata(
            typeName: "Status",
            cases: ["active", "inactive", "pending"]
        )

        #expect(metadata.isValidCase("active") == true)
        #expect(metadata.isValidCase("inactive") == true)
        #expect(metadata.isValidCase("pending") == true)
    }

    @Test("EnumMetadata isValidCase - invalid cases")
    func testIsValidCaseInvalid() {
        let metadata = EnumMetadata(
            typeName: "Status",
            cases: ["active", "inactive", "pending"]
        )

        #expect(metadata.isValidCase("unknown") == false)
        #expect(metadata.isValidCase("") == false)
        #expect(metadata.isValidCase("ACTIVE") == false)  // Case sensitive
    }

    @Test("EnumMetadata Equatable conformance")
    func testEquatable() {
        let metadata1 = EnumMetadata(
            typeName: "Status",
            cases: ["active", "inactive"]
        )

        let metadata2 = EnumMetadata(
            typeName: "Status",
            cases: ["active", "inactive"]
        )

        let metadata3 = EnumMetadata(
            typeName: "Status",
            cases: ["active", "pending"]  // Different cases
        )

        #expect(metadata1 == metadata2)
        #expect(metadata1 != metadata3)
    }

    @Test("EnumMetadata Sendable conformance")
    func testSendable() {
        let metadata = EnumMetadata(
            typeName: "Status",
            cases: ["active", "inactive"]
        )

        Task {
            let _ = metadata  // Can be captured in async context
        }

        #expect(metadata.typeName == "Status")
    }
}
