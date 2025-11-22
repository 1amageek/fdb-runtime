// IndexKind.swift
// FDBIndexing - Type-erased index kind wrapper
//
// Type-erased wrapper for storing any IndexKindProtocol implementation in Codable form.
// Allows storing different index kinds in the same array.

import Foundation

/// Type-erased index kind wrapper
///
/// **Purpose**: Store any IndexKindProtocol implementation in Codable form
///
/// **Mechanism**:
/// 1. Identify kind by `identifier`
/// 2. Store JSON-encoded data in `configuration`
/// 3. Type-safely decode with `decode<Kind>()`
///
/// **Benefits**:
/// - Store different kinds in the same array
/// - Codable support (persistence & serialization)
/// - Maintain type safety (validated during decode)
///
/// **Example**:
/// ```swift
/// // Encoding
/// let scalarKind = try IndexKind(ScalarIndexKind())
/// let vectorKind = try IndexKind(
///     VectorIndexKind(dimensions: 384, metric: .cosine)
/// )
///
/// // Store in array
/// let kinds: [IndexKind] = [scalarKind, vectorKind]
///
/// // Codable (JSON persistence)
/// let jsonData = try JSONEncoder().encode(kinds)
/// let decoded = try JSONDecoder().decode([IndexKind].self, from: jsonData)
///
/// // Decoding
/// let vector = try vectorKind.decode(VectorIndexKind.self)
/// print(vector.dimensions)  // 384
/// ```
public struct IndexKind: Sendable, Codable, Hashable {
    /// Kind identifier (IndexKindProtocol.identifier)
    ///
    /// **Purpose**: Determine correct kind type during decode
    ///
    /// **Examples**:
    /// - "scalar"
    /// - "vector"
    /// - "com.mycompany.bloom_filter"
    public let identifier: String

    /// JSON-encoded configuration data
    ///
    /// **Content**: Kind-specific configuration (dimensions, metric, etc.)
    ///
    /// **Note**: This Data is JSON-encoded, supporting only Codable-conforming types.
    public let configuration: Data

    /// Type-safe initializer
    ///
    /// **Example**:
    /// ```swift
    /// // Built-in kind
    /// let scalar = try IndexKind(ScalarIndexKind())
    ///
    /// // Extended kind (with configuration)
    /// let vector = try IndexKind(
    ///     VectorIndexKind(dimensions: 768, metric: .cosine)
    /// )
    ///
    /// // Third-party kind
    /// let bloom = try IndexKind(
    ///     BloomFilterIndexKind(
    ///         falsePositiveRate: 0.01,
    ///         expectedCapacity: 10000
    ///     )
    /// )
    /// ```
    ///
    /// - Parameter kind: Concrete index kind
    /// - Throws: JSON encoding error
    public init<Kind: IndexKindProtocol>(_ kind: Kind) throws {
        self.identifier = Kind.identifier
        self.configuration = try JSONEncoder().encode(kind)
    }

    /// Type-safe decode
    ///
    /// **Type check**: Error if identifier mismatch
    ///
    /// **Example**:
    /// ```swift
    /// let kind: IndexKind = ...
    ///
    /// // Correct kind decode
    /// let vector = try kind.decode(VectorIndexKind.self)
    /// print(vector.dimensions)  // OK
    ///
    /// // Wrong kind decode
    /// let scalar = try kind.decode(ScalarIndexKind.self)  // Error: typeMismatch
    /// ```
    ///
    /// - Parameter type: Expected kind type
    /// - Returns: Decoded kind
    /// - Throws:
    ///   - IndexKindError.typeMismatch: identifier mismatch
    ///   - DecodingError: JSON decoding error
    public func decode<Kind: IndexKindProtocol>(_ type: Kind.Type) throws -> Kind {
        guard identifier == Kind.identifier else {
            throw IndexKindError.typeMismatch(
                expected: Kind.identifier,
                actual: identifier
            )
        }
        return try JSONDecoder().decode(type, from: configuration)
    }
}

// MARK: - IndexKindError

/// IndexKind error type
///
/// **Example**:
/// ```swift
/// do {
///     let scalar = try vectorKind.decode(ScalarIndexKind.self)
/// } catch IndexKindError.typeMismatch(let expected, let actual) {
///     print("Expected: \(expected), Actual: \(actual)")
/// }
/// ```
public enum IndexKindError: Error, CustomStringConvertible {
    /// Type mismatch error
    ///
    /// Occurs when expected identifier differs from actual during decode.
    ///
    /// - Parameters:
    ///   - expected: Expected identifier
    ///   - actual: Actual identifier
    case typeMismatch(expected: String, actual: String)

    /// Unsupported kind
    ///
    /// Occurs when attempting to use unregistered kind in execution layer.
    ///
    /// - Parameter identifier: Unsupported identifier
    case unsupportedKind(String)

    public var description: String {
        switch self {
        case let .typeMismatch(expected, actual):
            return "IndexKind type mismatch: expected '\(expected)', but got '\(actual)'"

        case let .unsupportedKind(identifier):
            return "Unsupported index kind: '\(identifier)'"
        }
    }
}

// MARK: - Convenience Extensions

extension IndexKind {
    /// Convenience constructors for built-in kinds
    ///
    /// **Example**:
    /// ```swift
    /// let scalar = try IndexKind.scalar
    /// let count = try IndexKind.count
    /// let sum = try IndexKind.sum
    /// ```
    ///
    /// **Note**: These methods will be added after built-in kind implementations.
    /// Implementations are placed in respective IndexKind definition files.
}
