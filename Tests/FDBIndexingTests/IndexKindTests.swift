// IndexKindTests.swift
// FDBIndexing Tests - IndexKind（型消去ラッパー）のテスト

import Testing
import Foundation
@testable import FDBIndexing

@Suite("IndexKind Tests")
struct IndexKindTests {

    // MARK: - Type Erasure Tests

    @Test("IndexKind wraps ScalarIndexKind")
    func testIndexKindWrapsScalar() throws {
        let scalar = ScalarIndexKind()
        let kind = try IndexKind(scalar)

        #expect(kind.identifier == "scalar")

        // デコード
        let decoded = try kind.decode(ScalarIndexKind.self)
        #expect(decoded == scalar)
    }

    @Test("IndexKind wraps CountIndexKind")
    func testIndexKindWrapsCount() throws {
        let count = CountIndexKind()
        let kind = try IndexKind(count)

        #expect(kind.identifier == "count")

        // デコード
        let decoded = try kind.decode(CountIndexKind.self)
        #expect(decoded == count)
    }

    @Test("IndexKind wraps SumIndexKind")
    func testIndexKindWrapsSum() throws {
        let sum = SumIndexKind()
        let kind = try IndexKind(sum)

        #expect(kind.identifier == "sum")

        // デコード
        let decoded = try kind.decode(SumIndexKind.self)
        #expect(decoded == sum)
    }

    @Test("IndexKind wraps MinIndexKind")
    func testIndexKindWrapsMin() throws {
        let min = MinIndexKind()
        let kind = try IndexKind(min)

        #expect(kind.identifier == "min")

        // デコード
        let decoded = try kind.decode(MinIndexKind.self)
        #expect(decoded == min)
    }

    @Test("IndexKind wraps MaxIndexKind")
    func testIndexKindWrapsMax() throws {
        let max = MaxIndexKind()
        let kind = try IndexKind(max)

        #expect(kind.identifier == "max")

        // デコード
        let decoded = try kind.decode(MaxIndexKind.self)
        #expect(decoded == max)
    }

    @Test("IndexKind wraps VersionIndexKind")
    func testIndexKindWrapsVersion() throws {
        let version = VersionIndexKind()
        let kind = try IndexKind(version)

        #expect(kind.identifier == "version")

        // デコード
        let decoded = try kind.decode(VersionIndexKind.self)
        #expect(decoded == version)
    }

    // MARK: - Type Safety Tests

    @Test("IndexKind decode throws on type mismatch")
    func testIndexKindDecodeTypeMismatch() throws {
        let scalar = ScalarIndexKind()
        let kind = try IndexKind(scalar)

        // CountIndexKindとしてデコードしようとするとエラー
        #expect(throws: IndexKindError.self) {
            try kind.decode(CountIndexKind.self)
        }
    }

    // MARK: - Codable Tests

    @Test("IndexKind is Codable (JSON)")
    func testIndexKindCodable() throws {
        let scalar = ScalarIndexKind()
        let kind = try IndexKind(scalar)

        // JSON エンコード
        let encoder = JSONEncoder()
        let data = try encoder.encode(kind)

        // JSON デコード
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(IndexKind.self, from: data)

        #expect(decoded.identifier == kind.identifier)

        // 元の型としてデコード
        let decodedScalar = try decoded.decode(ScalarIndexKind.self)
        #expect(decodedScalar == scalar)
    }

    @Test("IndexKind array is Codable")
    func testIndexKindArrayCodable() throws {
        let kinds: [IndexKind] = [
            try IndexKind(ScalarIndexKind()),
            try IndexKind(CountIndexKind()),
            try IndexKind(SumIndexKind())
        ]

        // JSON エンコード
        let encoder = JSONEncoder()
        let data = try encoder.encode(kinds)

        // JSON デコード
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([IndexKind].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded[0].identifier == "scalar")
        #expect(decoded[1].identifier == "count")
        #expect(decoded[2].identifier == "sum")
    }

    // MARK: - Hashable Tests

    @Test("IndexKind is Hashable")
    func testIndexKindHashable() throws {
        let scalar1 = try IndexKind(ScalarIndexKind())
        let scalar2 = try IndexKind(ScalarIndexKind())
        let count = try IndexKind(CountIndexKind())

        #expect(scalar1 == scalar2)
        #expect(scalar1 != count)

        // Set に格納可能
        let set: Set<IndexKind> = [scalar1, scalar2, count]
        #expect(set.count == 2)  // scalar1 と scalar2 は同じ
    }
}
