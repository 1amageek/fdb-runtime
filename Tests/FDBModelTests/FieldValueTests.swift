import Testing
import Foundation
@testable import FDBModel

@Suite("FieldValue Tests")
struct FieldValueTests {

    // MARK: - Initialization

    @Test("Init from Int64")
    func testInitInt64() {
        let value = FieldValue.int64(42)
        #expect(value.int64Value == 42)
        #expect(value.isNumeric == true)
        #expect(value.isNull == false)
    }

    @Test("Init from Double")
    func testInitDouble() {
        let value = FieldValue.double(3.14)
        #expect(value.doubleValue == 3.14)
        #expect(value.isNumeric == true)
        #expect(value.isNull == false)
    }

    @Test("Init from String")
    func testInitString() {
        let value = FieldValue.string("hello")
        #expect(value.stringValue == "hello")
        #expect(value.isNumeric == false)
        #expect(value.isNull == false)
    }

    @Test("Init from Bool")
    func testInitBool() {
        let trueValue = FieldValue.bool(true)
        let falseValue = FieldValue.bool(false)

        #expect(trueValue.boolValue == true)
        #expect(falseValue.boolValue == false)
        #expect(trueValue.isNumeric == false)
    }

    @Test("Init from Data")
    func testInitData() {
        let data = Data([1, 2, 3, 4])
        let value = FieldValue.data(data)

        #expect(value.dataValue == data)
        #expect(value.isNumeric == false)
    }

    @Test("Init null")
    func testInitNull() {
        let value = FieldValue.null

        #expect(value.isNull == true)
        #expect(value.isNumeric == false)
        #expect(value.int64Value == nil)
        #expect(value.stringValue == nil)
    }

    // MARK: - Convenience Initializer

    @Test("Convenience init from Int")
    func testConvenienceInitInt() {
        let value = FieldValue(42 as Int)
        #expect(value?.int64Value == 42)
    }

    @Test("Convenience init from Int32")
    func testConvenienceInitInt32() {
        let value = FieldValue(Int32(42))
        #expect(value?.int64Value == 42)
    }

    @Test("Convenience init from Float")
    func testConvenienceInitFloat() {
        let value = FieldValue(Float(3.14))
        #expect(value?.doubleValue != nil)
    }

    @Test("Convenience init from NSNull")
    func testConvenienceInitNSNull() {
        let value = FieldValue(NSNull())
        #expect(value?.isNull == true)
    }

    @Test("Convenience init from unsupported type returns nil")
    func testConvenienceInitUnsupported() {
        struct CustomType {}
        let value = FieldValue(CustomType())
        #expect(value == nil)
    }

    // MARK: - asDouble

    @Test("asDouble for int64")
    func testAsDoubleInt64() {
        let value = FieldValue.int64(42)
        #expect(value.asDouble == 42.0)
    }

    @Test("asDouble for double")
    func testAsDoubleDouble() {
        let value = FieldValue.double(3.14)
        #expect(value.asDouble == 3.14)
    }

    @Test("asDouble for non-numeric returns nil")
    func testAsDoubleNonNumeric() {
        let value = FieldValue.string("hello")
        #expect(value.asDouble == nil)
    }

    // MARK: - Comparable

    @Test("Int64 comparison")
    func testInt64Comparison() {
        let a = FieldValue.int64(10)
        let b = FieldValue.int64(20)

        #expect(a < b)
        #expect(!(b < a))
        #expect(a == FieldValue.int64(10))
    }

    @Test("Double comparison")
    func testDoubleComparison() {
        let a = FieldValue.double(1.5)
        let b = FieldValue.double(2.5)

        #expect(a < b)
        #expect(!(b < a))
    }

    @Test("String comparison")
    func testStringComparison() {
        let a = FieldValue.string("apple")
        let b = FieldValue.string("banana")

        #expect(a < b)
        #expect(!(b < a))
    }

    @Test("Bool comparison (false < true)")
    func testBoolComparison() {
        let falseVal = FieldValue.bool(false)
        let trueVal = FieldValue.bool(true)

        #expect(falseVal < trueVal)
        #expect(!(trueVal < falseVal))
    }

    @Test("Data comparison (lexicographic)")
    func testDataComparison() {
        let a = FieldValue.data(Data([1, 2, 3]))
        let b = FieldValue.data(Data([1, 2, 4]))

        #expect(a < b)
    }

    @Test("Null is less than everything")
    func testNullComparison() {
        let nullVal = FieldValue.null
        let intVal = FieldValue.int64(0)
        let strVal = FieldValue.string("")

        #expect(nullVal < intVal)
        #expect(nullVal < strVal)
        #expect(!(intVal < nullVal))
    }

    @Test("Cross-type numeric comparison")
    func testCrossTypeNumericComparison() {
        let intVal = FieldValue.int64(10)
        let doubleVal = FieldValue.double(10.5)

        #expect(intVal < doubleVal)
        #expect(!(doubleVal < intVal))
    }

    // MARK: - Hashable

    @Test("Same values have same hash")
    func testHashableSameValues() {
        let a = FieldValue.string("test")
        let b = FieldValue.string("test")

        #expect(a.hashValue == b.hashValue)
    }

    @Test("Can be used in Set")
    func testSetUsage() {
        var set: Set<FieldValue> = []
        set.insert(.int64(1))
        set.insert(.int64(2))
        set.insert(.int64(1))  // Duplicate

        #expect(set.count == 2)
    }

    @Test("Can be used as Dictionary key")
    func testDictionaryUsage() {
        var dict: [FieldValue: String] = [:]
        dict[.string("key1")] = "value1"
        dict[.string("key2")] = "value2"

        #expect(dict[.string("key1")] == "value1")
        #expect(dict[.string("key2")] == "value2")
    }

    // MARK: - Codable

    @Test("Encode and decode int64")
    func testCodableInt64() throws {
        let original = FieldValue.int64(42)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let restored = try decoder.decode(FieldValue.self, from: data)

        #expect(original == restored)
    }

    @Test("Encode and decode all types")
    func testCodableAllTypes() throws {
        let values: [FieldValue] = [
            .int64(42),
            .double(3.14),
            .string("hello"),
            .bool(true),
            .data(Data([1, 2, 3])),
            .null
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for original in values {
            let data = try encoder.encode(original)
            let restored = try decoder.decode(FieldValue.self, from: data)
            #expect(original == restored)
        }
    }

    // MARK: - Description

    @Test("Int64 description")
    func testInt64Description() {
        let value = FieldValue.int64(42)
        #expect(value.description == "int64(42)")
    }

    @Test("Double description")
    func testDoubleDescription() {
        let value = FieldValue.double(3.14)
        #expect(value.description == "double(3.14)")
    }

    @Test("String description")
    func testStringDescription() {
        let value = FieldValue.string("hello")
        #expect(value.description == "string(\"hello\")")
    }

    @Test("Bool description")
    func testBoolDescription() {
        let value = FieldValue.bool(true)
        #expect(value.description == "bool(true)")
    }

    @Test("Data description")
    func testDataDescription() {
        let value = FieldValue.data(Data([1, 2, 3]))
        #expect(value.description == "data(3 bytes)")
    }

    @Test("Null description")
    func testNullDescription() {
        let value = FieldValue.null
        #expect(value.description == "null")
    }

    // MARK: - Stable Hash

    @Test("Stable hash is deterministic")
    func testStableHashDeterministic() {
        let value = FieldValue.string("test")

        let hash1 = value.stableHash()
        let hash2 = value.stableHash()

        #expect(hash1 == hash2)
    }

    @Test("Different types produce different hashes")
    func testStableHashDifferentTypes() {
        let intVal = FieldValue.int64(1)
        let strVal = FieldValue.string("1")

        #expect(intVal.stableHash() != strVal.stableHash())
    }

    @Test("Stable hash for all types")
    func testStableHashAllTypes() {
        let values: [FieldValue] = [
            .int64(42),
            .double(3.14),
            .string("hello"),
            .bool(true),
            .data(Data([1, 2, 3])),
            .null
        ]

        var hashes: Set<UInt64> = []
        for value in values {
            let hash = value.stableHash()
            hashes.insert(hash)
        }

        // All values should have unique hashes
        #expect(hashes.count == values.count)
    }
}
