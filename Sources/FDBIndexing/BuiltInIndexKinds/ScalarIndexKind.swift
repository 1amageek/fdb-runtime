// ScalarIndexKind.swift
// FDBIndexing - Scalar (VALUE) index kind
//
// Standard B-tree index. Used for range queries and lookups
// on Comparable fields.

import Foundation
import FoundationDB

/// Scalar (VALUE) index kind
///
/// **Purpose**: Basic search and Range reads
/// - Supports single or composite fields
/// - Requires Comparable protocol conformance
///
/// **Subspace structure**: flat
/// - Key: `[indexSubspace][fieldValue1][fieldValue2]...[primaryKey] = ''`
/// - Dictionary-sorted, efficient Range reads
///
/// **Supported types**:
/// - String, Int, Int64, Double, Float, Date, UUID, etc. (all Comparable-conforming types)
/// - Custom types (must conform to Comparable)
///
/// **Example**:
/// ```swift
/// // Single field index
/// let emailIndex = IndexDescriptor(
///     name: "User_email",
///     keyPaths: ["email"],
///     kind: ScalarIndexKind(),
///     commonOptions: .init(unique: true)
/// )
///
/// // Composite field index
/// let compositeIndex = IndexDescriptor(
///     name: "Product_category_price",
///     keyPaths: ["category", "price"],
///     kind: ScalarIndexKind(),
///     commonOptions: .init()
/// )
/// ```
public struct ScalarIndexKind: IndexKind {
    /// Kind identifier (built-in kinds use lowercase words)
    public static let identifier = "scalar"

    /// Subspace structure: Flat (simple key structure)
    ///
    /// **Reason**: Scalar indexes have simple 2-level key structure
    /// - `[indexSubspace][value][pk] = ''`
    /// - No DirectoryLayer needed, fast Range reads
    public static let subspaceStructure = SubspaceStructure.flat

    /// Type validation: Ensure all fields conform to Comparable
    ///
    /// **Validation**:
    /// - Field count: 1 or more (no limit)
    /// - Each field: Comparable protocol conformance
    ///
    /// **Examples**:
    /// ```swift
    /// // OK: Single Comparable field
    /// try ScalarIndexKind.validateTypes([String.self])
    ///
    /// // OK: Composite Comparable fields
    /// try ScalarIndexKind.validateTypes([String.self, Int64.self])
    ///
    /// // OK: Custom Comparable type
    /// struct Price: Comparable { ... }
    /// try ScalarIndexKind.validateTypes([Price.self])
    ///
    /// // NG: Non-Comparable type
    /// struct Product { ... }  // Not Comparable
    /// try ScalarIndexKind.validateTypes([Product.self])  // throws
    /// ```
    ///
    /// - Parameter types: Array of indexed field types
    /// - Throws: IndexError.invalidConfiguration
    public static func validateTypes(_ types: [Any.Type]) throws {
        // At least one field is required
        guard !types.isEmpty else {
            throw IndexError.invalidConfiguration(
                "Scalar index requires at least 1 field, got 0"
            )
        }

        // All fields must conform to Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration(
                    "Scalar index requires Comparable types, got \(type)"
                )
            }
        }
    }

    /// Standard initializer
    ///
    /// **Example**:
    /// ```swift
    /// let kind: any IndexKind = ScalarIndexKind()
    /// ```
    public init() {}

    /// Create index maintainer (placeholder - actual implementation in upper layers)
    ///
    /// **Note**: Built-in index kinds in fdb-runtime do not provide maintainers.
    /// Maintainers are implemented in upper layers (e.g., fdb-record-layer, fdb-indexes).
    ///
    /// - Parameters:
    ///   - index: Index definition
    ///   - subspace: FDB subspace for this index
    ///   - configuration: Runtime algorithm configuration (ignored for scalar indexes)
    /// - Throws: IndexError.invalidConfiguration
}
