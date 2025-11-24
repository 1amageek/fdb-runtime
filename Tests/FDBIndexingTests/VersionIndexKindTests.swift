// VersionIndexKindTests.swift
// FDBIndexing Tests - VersionIndexKind tests

import Testing
import Foundation
@testable import FDBIndexing

@Suite("VersionIndexKind Tests")
struct VersionIndexKindTests {

    // MARK: - Metadata Tests

    @Test("VersionIndexKind has correct identifier")
    func testIdentifier() {
        #expect(VersionIndexKind.identifier == "version")
    }

    @Test("VersionIndexKind has flat subspace structure")
    func testSubspaceStructure() {
        #expect(VersionIndexKind.subspaceStructure == .flat)
    }

    // MARK: - Type Validation Tests

    @Test("VersionIndexKind validates single field")
    func testValidateSingleField() throws {
        // Any type (not actually used)
        try VersionIndexKind.validateTypes([Int.self])
        try VersionIndexKind.validateTypes([String.self])
        try VersionIndexKind.validateTypes([Double.self])
    }

    @Test("VersionIndexKind rejects multiple fields")
    func testRejectMultipleFields() {
        #expect(throws: IndexError.self) {
            try VersionIndexKind.validateTypes([Int.self, String.self])
        }
    }

    @Test("VersionIndexKind rejects empty fields")
    func testRejectEmptyFields() {
        #expect(throws: IndexError.self) {
            try VersionIndexKind.validateTypes([])
        }
    }

    // MARK: - Codable Tests

    @Test("VersionIndexKind is Codable")
    func testCodable() throws {
        let kind = VersionIndexKind()

        // JSON encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(kind)

        // JSON decoding
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VersionIndexKind.self, from: data)

        #expect(decoded == kind)
    }

    // MARK: - Hashable Tests

    @Test("VersionIndexKind is Hashable")
    func testHashable() {
        let kind1 = VersionIndexKind()
        let kind2 = VersionIndexKind()

        #expect(kind1 == kind2)
        #expect(kind1.hashValue == kind2.hashValue)
    }
}
