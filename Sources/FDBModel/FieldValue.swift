import struct Foundation.Data

#if canImport(ObjectiveC)
import class Foundation.NSNull
#endif

/// Represents a field value that can be compared and hashed
///
/// Used for query conditions, statistics (HyperLogLog), and field comparisons.
/// Similar to fdb-record-layer's ComparableValue.
///
/// **Supported Types**:
/// - `int64`: 64-bit signed integer
/// - `double`: 64-bit floating point
/// - `string`: UTF-8 string
/// - `bool`: Boolean value
/// - `data`: Binary data
/// - `null`: Null/missing value
///
/// **Usage**:
/// ```swift
/// let value = FieldValue.string("hello")
/// let number = FieldValue.int64(42)
///
/// // Comparison
/// if value < FieldValue.string("world") {
///     print("'hello' comes before 'world'")
/// }
///
/// // For HyperLogLog
/// var hll = HyperLogLog()
/// hll.add(value)
/// ```
public enum FieldValue: Sendable, Hashable, Codable {
    case int64(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)
    case data(Data)
    case null

    // MARK: - Convenience Initializers

    /// Create from any supported type
    ///
    /// Returns nil if the value type is not supported.
    public init?(_ value: Any) {
        switch value {
        case let v as Int64:
            self = .int64(v)
        case let v as Int:
            self = .int64(Int64(v))
        case let v as Int32:
            self = .int64(Int64(v))
        case let v as Int16:
            self = .int64(Int64(v))
        case let v as Int8:
            self = .int64(Int64(v))
        case let v as UInt64:
            self = .int64(Int64(bitPattern: v))
        case let v as UInt:
            self = .int64(Int64(v))
        case let v as UInt32:
            self = .int64(Int64(v))
        case let v as UInt16:
            self = .int64(Int64(v))
        case let v as UInt8:
            self = .int64(Int64(v))
        case let v as Double:
            self = .double(v)
        case let v as Float:
            self = .double(Double(v))
        case let v as String:
            self = .string(v)
        case let v as Bool:
            self = .bool(v)
        case let v as Data:
            self = .data(v)
        #if canImport(ObjectiveC)
        case is NSNull:
            self = .null
        #endif
        case nil as Any?:
            self = .null
        default:
            return nil
        }
    }

    // MARK: - Type Checks

    /// Returns true if this is a null value
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Returns true if this is a numeric value (int64 or double)
    public var isNumeric: Bool {
        switch self {
        case .int64, .double:
            return true
        default:
            return false
        }
    }

    // MARK: - Value Extraction

    /// Get the value as Int64, or nil if not an integer
    public var int64Value: Int64? {
        if case .int64(let v) = self { return v }
        return nil
    }

    /// Get the value as Double, or nil if not a double
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }

    /// Get the value as String, or nil if not a string
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Get the value as Bool, or nil if not a boolean
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Get the value as Data, or nil if not binary data
    public var dataValue: Data? {
        if case .data(let v) = self { return v }
        return nil
    }

    /// Get the numeric value as Double (works for both int64 and double)
    public var asDouble: Double? {
        switch self {
        case .int64(let v):
            return Double(v)
        case .double(let v):
            return v
        default:
            return nil
        }
    }
}

// MARK: - Comparable

extension FieldValue: Comparable {
    public static func < (lhs: FieldValue, rhs: FieldValue) -> Bool {
        switch (lhs, rhs) {
        // Same type comparisons
        case (.int64(let l), .int64(let r)):
            return l < r
        case (.double(let l), .double(let r)):
            return l < r
        case (.string(let l), .string(let r)):
            return l < r
        case (.bool(let l), .bool(let r)):
            return !l && r  // false < true
        case (.data(let l), .data(let r)):
            return l.lexicographicallyPrecedes(r)

        // Cross-type numeric comparisons
        case (.int64(let l), .double(let r)):
            return Double(l) < r
        case (.double(let l), .int64(let r)):
            return l < Double(r)

        // Null handling: null is less than everything else
        case (.null, .null):
            return false
        case (.null, _):
            return true
        case (_, .null):
            return false

        // Different non-comparable types: use type order
        default:
            return lhs.typeOrder < rhs.typeOrder
        }
    }

    /// Type ordering for cross-type comparison
    private var typeOrder: Int {
        switch self {
        case .null: return 0
        case .bool: return 1
        case .int64: return 2
        case .double: return 3
        case .string: return 4
        case .data: return 5
        }
    }
}

// MARK: - CustomStringConvertible

extension FieldValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int64(let v):
            return "int64(\(v))"
        case .double(let v):
            return "double(\(v))"
        case .string(let v):
            return "string(\"\(v)\")"
        case .bool(let v):
            return "bool(\(v))"
        case .data(let v):
            return "data(\(v.count) bytes)"
        case .null:
            return "null"
        }
    }
}

// MARK: - Stable Hash

extension FieldValue {
    /// Compute a stable 64-bit hash for HyperLogLog
    ///
    /// This hash function is:
    /// - **Deterministic**: Same value always produces same hash
    /// - **Uniformly distributed**: Minimizes hash collisions
    /// - **Stable across runs**: Same value produces same hash even after restart
    ///
    /// - Returns: 64-bit hash value
    public func stableHash() -> UInt64 {
        var hasher = StableHasher()

        switch self {
        case .int64(let value):
            hasher.combine(Int64(0))  // Type discriminator
            hasher.combine(value)

        case .double(let value):
            hasher.combine(Int64(1))  // Type discriminator
            hasher.combine(value.bitPattern)

        case .string(let value):
            hasher.combine(Int64(2))  // Type discriminator
            hasher.combine(value)

        case .bool(let value):
            hasher.combine(Int64(3))  // Type discriminator
            hasher.combine(value)

        case .data(let value):
            hasher.combine(Int64(4))  // Type discriminator
            hasher.combine(value)

        case .null:
            hasher.combine(Int64(5))  // Type discriminator
        }

        return hasher.finalize()
    }
}

// MARK: - StableHasher

/// A hasher that produces stable, deterministic hashes
///
/// Unlike Swift's built-in Hasher, this produces the same hash value
/// across different runs of the program, which is essential for
/// database statistics that need to be persisted.
private struct StableHasher {
    private var state: UInt64 = 0xcbf29ce484222325  // FNV-1a offset basis

    mutating func combine(_ value: Int64) {
        combine(UInt64(bitPattern: value))
    }

    mutating func combine(_ value: UInt64) {
        // FNV-1a hash algorithm
        let bytes = withUnsafeBytes(of: value) { Array($0) }
        for byte in bytes {
            state ^= UInt64(byte)
            state = state &* 0x100000001b3  // FNV-1a prime
        }
    }

    mutating func combine(_ value: String) {
        let bytes = value.utf8
        for byte in bytes {
            state ^= UInt64(byte)
            state = state &* 0x100000001b3
        }
    }

    mutating func combine(_ value: Bool) {
        combine(value ? Int64(1) : Int64(0))
    }

    mutating func combine(_ value: Data) {
        for byte in value {
            state ^= UInt64(byte)
            state = state &* 0x100000001b3
        }
    }

    func finalize() -> UInt64 {
        return state
    }
}
