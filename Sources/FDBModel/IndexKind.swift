// IndexKind.swift
// FDBCore - Protocol for defining index kind metadata
//
// Extension point allowing third parties to define custom index kinds.
// New kinds can be added without modifying FDBCore itself.
//
// **Note**: This is the metadata-only base protocol. For runtime capabilities
// (creating IndexMaintainer), see IndexKind protocol in FDBIndexing.

/// Protocol for defining index kinds
///
/// **Extensibility**: Third parties can define custom kinds
/// - No FDBIndexing modification required
/// - New kinds added via protocol implementation only
///
/// **Naming convention**:
/// - Built-in: Lowercase words ("scalar", "count", "vector")
/// - Extended: Reverse DNS format ("com.mycompany.bloom_filter")
///
/// **Design principles**:
/// - Type-safe validation (using Any.Type)
/// - Structure declaration (SubspaceStructure)
/// - Separation of implementation (no execution logic)
///
/// **Example**:
/// ```swift
/// // Built-in kind (in fdb-indexes/ScalarIndexLayer)
/// public struct ScalarIndexKind: IndexKind {
///     public static let identifier = "scalar"
///     public static let subspaceStructure = SubspaceStructure.flat
///
///     public static func validateTypes(_ types: [Any.Type]) throws {
///         for type in types {
///             guard TypeValidation.isComparable(type) else {
///                 throw IndexTypeValidationError.unsupportedType(...)
///             }
///         }
///     }
///
///     public init() {}
/// }
///
/// // Third-party kind (in third-party package)
/// public struct BloomFilterIndexKind: IndexKind {
///     public static let identifier = "com.mycompany.bloom_filter"
///     public static let subspaceStructure = SubspaceStructure.flat
///
///     public let falsePositiveRate: Double
///     public let expectedCapacity: Int
///
///     public static func validateTypes(_ types: [Any.Type]) throws {
///         // Custom validation logic
///     }
///
///     public init(falsePositiveRate: Double, expectedCapacity: Int) {
///         self.falsePositiveRate = falsePositiveRate
///         self.expectedCapacity = expectedCapacity
///     }
/// }
/// ```
public protocol IndexKind: Sendable, Codable, Hashable {
    /// Unique identifier for this kind
    ///
    /// **Naming convention**:
    /// - Built-in kinds: Lowercase words ("scalar", "count", "vector")
    /// - Extended kinds: Reverse DNS format ("com.mycompany.bloom_filter")
    ///
    /// **Examples**:
    /// - "scalar" (built-in)
    /// - "vector" (extended: FDBRecordVector)
    /// - "com.mycompany.bloom_filter" (third-party)
    ///
    /// **Note**: This identifier is used in IndexKind's type erasure mechanism.
    /// No two kinds may share the same identifier.
    static var identifier: String { get }

    /// Subspace structure type
    ///
    /// **Purpose**: Execution layer determines Subspace creation strategy
    /// - `.flat`: Simple key structure [value][pk]
    /// - `.hierarchical`: Complex hierarchy (consider DirectoryLayer)
    /// - `.aggregation`: Store aggregated value directly [groupKey] → value
    ///
    /// **Note**: DirectoryLayer usage decision is delegated to execution layer
    ///
    /// **Examples**:
    /// ```swift
    /// // Scalar
    /// static var subspaceStructure: SubspaceStructure { .flat }
    ///
    /// // Vector (HNSW)
    /// static var subspaceStructure: SubspaceStructure { .hierarchical }
    ///
    /// // Count
    /// static var subspaceStructure: SubspaceStructure { .aggregation }
    /// ```
    static var subspaceStructure: SubspaceStructure { get }

    /// Validate whether this index kind supports specified types
    ///
    /// **Parameters**:
    /// - types: Types of indexed fields (array order corresponds to keyPaths)
    ///
    /// **Throws**: IndexTypeValidationError if type not supported
    ///
    /// **Implementation guide**:
    /// 1. Check field count (if necessary)
    /// 2. Check each field type (use TypeValidation)
    /// 3. Throw with detailed reason on error
    ///
    /// **Examples**:
    /// ```swift
    /// // Scalar: Supports all Comparable types
    /// static func validateTypes(_ types: [Any.Type]) throws {
    ///     for type in types {
    ///         guard TypeValidation.isComparable(type) else {
    ///             throw IndexTypeValidationError.unsupportedType(
    ///                 index: identifier,
    ///                 type: type,
    ///                 reason: "Scalar index requires Comparable types"
    ///             )
    ///         }
    ///     }
    /// }
    ///
    /// // Vector: Single array type field only
    /// static func validateTypes(_ types: [Any.Type]) throws {
    ///     guard types.count == 1 else {
    ///         throw IndexTypeValidationError.invalidTypeCount(
    ///             index: identifier,
    ///             expected: 1,
    ///             actual: types.count
    ///         )
    ///     }
    ///
    ///     let type = types[0]
    ///     let supportedTypes: [Any.Type] = [
    ///         [Float32].self, [Float].self, [Double].self
    ///     ]
    ///
    ///     var isSupported = false
    ///     for supportedType in supportedTypes {
    ///         if type == supportedType {
    ///             isSupported = true
    ///             break
    ///         }
    ///     }
    ///
    ///     guard isSupported else {
    ///         throw IndexTypeValidationError.unsupportedType(
    ///             index: identifier,
    ///             type: type,
    ///             reason: "Vector index requires array of numeric types"
    ///         )
    ///     }
    /// }
    /// ```
    static func validateTypes(_ types: [Any.Type]) throws
}

/// Index type validation error
///
/// **Example**:
/// ```swift
/// throw IndexTypeValidationError.unsupportedType(
///     index: "vector",
///     type: String.self,
///     reason: "Vector index requires array types"
/// )
/// ```
public enum IndexTypeValidationError: Error, CustomStringConvertible {
    /// Unsupported type
    ///
    /// - Parameters:
    ///   - index: Index kind identifier
    ///   - type: Unsupported type
    ///   - reason: Error reason (user-facing message)
    case unsupportedType(index: String, type: Any.Type, reason: String)

    /// Invalid field count
    ///
    /// - Parameters:
    ///   - index: Index kind identifier
    ///   - expected: Expected field count
    ///   - actual: Actual field count
    case invalidTypeCount(index: String, expected: Int, actual: Int)

    /// Custom validation failed
    ///
    /// - Parameters:
    ///   - index: Index kind identifier
    ///   - reason: Failure reason (user-facing message)
    case customValidationFailed(index: String, reason: String)

    public var description: String {
        switch self {
        case let .unsupportedType(index, type, reason):
            return "Index '\(index)' does not support type '\(type)': \(reason)"

        case let .invalidTypeCount(index, expected, actual):
            return "Index '\(index)' expects \(expected) field(s), but got \(actual)"

        case let .customValidationFailed(index, reason):
            return "Index '\(index)' validation failed: \(reason)"
        }
    }
}
