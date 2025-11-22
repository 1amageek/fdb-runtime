// IndexDescriptorTests.swift
// FDBIndexing Tests - IndexDescriptor のテスト

import Testing
import Foundation
@testable import FDBIndexing

@Suite("IndexDescriptor Tests")
struct IndexDescriptorTests {

    // MARK: - Initialization Tests

    @Test("IndexDescriptor initializes with all parameters")
    func testInitialization() throws {
        let kind = try IndexKind(ScalarIndexKind())
        let options = CommonIndexOptions(unique: true, sparse: false, metadata: ["key": "value"])

        let descriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind,
            commonOptions: options
        )

        #expect(descriptor.name == "User_email")
        #expect(descriptor.keyPaths == ["email"])
        #expect(descriptor.kind.identifier == "scalar")
        #expect(descriptor.commonOptions.unique == true)
        #expect(descriptor.commonOptions.sparse == false)
        #expect(descriptor.commonOptions.metadata == ["key": "value"])
    }

    @Test("IndexDescriptor initializes with default options")
    func testInitializationWithDefaults() throws {
        let kind = try IndexKind(ScalarIndexKind())

        let descriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind
        )

        #expect(descriptor.name == "User_email")
        #expect(descriptor.keyPaths == ["email"])
        #expect(descriptor.commonOptions.unique == false)
        #expect(descriptor.commonOptions.sparse == false)
        #expect(descriptor.commonOptions.metadata.isEmpty)
    }

    // MARK: - Convenience Properties Tests

    @Test("IndexDescriptor isUnique property")
    func testIsUniqueProperty() throws {
        let kind = try IndexKind(ScalarIndexKind())

        let uniqueDescriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind,
            commonOptions: .init(unique: true)
        )
        #expect(uniqueDescriptor.isUnique == true)

        let nonUniqueDescriptor = IndexDescriptor(
            name: "User_city",
            keyPaths: ["city"],
            kind: kind,
            commonOptions: .init(unique: false)
        )
        #expect(nonUniqueDescriptor.isUnique == false)
    }

    @Test("IndexDescriptor isSparse property")
    func testIsSparseProperty() throws {
        let kind = try IndexKind(ScalarIndexKind())

        let sparseDescriptor = IndexDescriptor(
            name: "User_nickname",
            keyPaths: ["nickname"],
            kind: kind,
            commonOptions: .init(sparse: true)
        )
        #expect(sparseDescriptor.isSparse == true)

        let nonSparseDescriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind,
            commonOptions: .init(sparse: false)
        )
        #expect(nonSparseDescriptor.isSparse == false)
    }

    @Test("IndexDescriptor kindIdentifier property")
    func testKindIdentifierProperty() throws {
        let scalarKind = try IndexKind(ScalarIndexKind())
        let countKind = try IndexKind(CountIndexKind())

        let scalarDescriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: scalarKind
        )
        #expect(scalarDescriptor.kindIdentifier == "scalar")

        let countDescriptor = IndexDescriptor(
            name: "User_count_by_city",
            keyPaths: ["city"],
            kind: countKind
        )
        #expect(countDescriptor.kindIdentifier == "count")
    }

    // MARK: - Composite Index Tests

    @Test("IndexDescriptor with composite key paths")
    func testCompositeKeyPaths() throws {
        let kind = try IndexKind(ScalarIndexKind())

        let descriptor = IndexDescriptor(
            name: "Product_category_price",
            keyPaths: ["category", "price"],
            kind: kind
        )

        #expect(descriptor.keyPaths.count == 2)
        #expect(descriptor.keyPaths == ["category", "price"])
    }

    // MARK: - Different Index Kinds Tests

    @Test("IndexDescriptor with CountIndexKind")
    func testCountIndexKind() throws {
        let kind = try IndexKind(CountIndexKind())

        let descriptor = IndexDescriptor(
            name: "User_count_by_city",
            keyPaths: ["city"],
            kind: kind
        )

        #expect(descriptor.kindIdentifier == "count")
    }

    @Test("IndexDescriptor with SumIndexKind")
    func testSumIndexKind() throws {
        let kind = try IndexKind(SumIndexKind())

        let descriptor = IndexDescriptor(
            name: "Employee_salary_by_dept",
            keyPaths: ["department", "salary"],
            kind: kind
        )

        #expect(descriptor.kindIdentifier == "sum")
        #expect(descriptor.keyPaths == ["department", "salary"])
    }

    @Test("IndexDescriptor with MinIndexKind")
    func testMinIndexKind() throws {
        let kind = try IndexKind(MinIndexKind())

        let descriptor = IndexDescriptor(
            name: "Product_min_price_by_region",
            keyPaths: ["region", "price"],
            kind: kind
        )

        #expect(descriptor.kindIdentifier == "min")
    }

    @Test("IndexDescriptor with MaxIndexKind")
    func testMaxIndexKind() throws {
        let kind = try IndexKind(MaxIndexKind())

        let descriptor = IndexDescriptor(
            name: "Product_max_price_by_region",
            keyPaths: ["region", "price"],
            kind: kind
        )

        #expect(descriptor.kindIdentifier == "max")
    }

    @Test("IndexDescriptor with VersionIndexKind")
    func testVersionIndexKind() throws {
        let kind = try IndexKind(VersionIndexKind())

        let descriptor = IndexDescriptor(
            name: "Document_version_index",
            keyPaths: ["_version"],
            kind: kind
        )

        #expect(descriptor.kindIdentifier == "version")
    }

    // MARK: - Codable Tests

    @Test("IndexDescriptor is Codable")
    func testCodable() throws {
        let kind = try IndexKind(ScalarIndexKind())
        let descriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind,
            commonOptions: .init(unique: true, metadata: ["category": "user"])
        )

        // JSON エンコード
        let encoder = JSONEncoder()
        let data = try encoder.encode(descriptor)

        // JSON デコード
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(IndexDescriptor.self, from: data)

        #expect(decoded.name == descriptor.name)
        #expect(decoded.keyPaths == descriptor.keyPaths)
        #expect(decoded.kindIdentifier == descriptor.kindIdentifier)
        #expect(decoded.isUnique == descriptor.isUnique)
        #expect(decoded.commonOptions.metadata == descriptor.commonOptions.metadata)
    }

    @Test("IndexDescriptor array is Codable")
    func testArrayCodable() throws {
        let descriptors = [
            IndexDescriptor(
                name: "User_email",
                keyPaths: ["email"],
                kind: try IndexKind(ScalarIndexKind()),
                commonOptions: .init(unique: true)
            ),
            IndexDescriptor(
                name: "User_count_by_city",
                keyPaths: ["city"],
                kind: try IndexKind(CountIndexKind())
            )
        ]

        // JSON エンコード
        let encoder = JSONEncoder()
        let data = try encoder.encode(descriptors)

        // JSON デコード
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([IndexDescriptor].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].name == "User_email")
        #expect(decoded[1].name == "User_count_by_city")
    }

    // MARK: - Hashable Tests

    @Test("IndexDescriptor is Hashable")
    func testHashable() throws {
        let kind1 = try IndexKind(ScalarIndexKind())
        let kind2 = try IndexKind(ScalarIndexKind())

        let descriptor1 = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind1,
            commonOptions: .init(unique: true)
        )

        let descriptor2 = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind2,
            commonOptions: .init(unique: true)
        )

        let descriptor3 = IndexDescriptor(
            name: "User_city",
            keyPaths: ["city"],
            kind: kind1
        )

        #expect(descriptor1 == descriptor2)
        #expect(descriptor1 != descriptor3)

        // Set に格納可能
        let set: Set<IndexDescriptor> = [descriptor1, descriptor2, descriptor3]
        #expect(set.count == 2)  // descriptor1 と descriptor2 は同じ
    }

    // MARK: - Description Tests

    @Test("IndexDescriptor description includes key information")
    func testDescription() throws {
        let kind = try IndexKind(ScalarIndexKind())
        let descriptor = IndexDescriptor(
            name: "User_email",
            keyPaths: ["email"],
            kind: kind,
            commonOptions: .init(unique: true, sparse: false, metadata: ["key": "value"])
        )

        let description = descriptor.description

        #expect(description.contains("User_email"))
        #expect(description.contains("scalar"))
        #expect(description.contains("email"))
        #expect(description.contains("unique: true"))
        #expect(description.contains("metadata"))
    }
}
