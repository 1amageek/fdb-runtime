// CountIndexKind.swift
// FDBIndexing - COUNT aggregation index kind
//
// Aggregation index that counts records per group.
// Stores Int64 count value for each grouping key.

import Foundation
import FoundationDB

/// COUNT aggregation index kind
///
/// **Purpose**: Efficiently retrieve record count per group
/// - Group records by grouping fields
/// - Store count directly for each group
/// - Update with AtomicOp (ADD/SUBTRACT)
///
/// **Subspace structure**: aggregation
/// - Key: `[indexSubspace][groupingValue] = Int64(count)`
/// - Value: Count value (Int64, Little Endian)
///
/// **Supported types**:
/// - Grouping fields: All Comparable-conforming types
///
/// **Example**:
/// ```swift
/// // User count by city
/// let cityCountIndex = IndexDescriptor(
///     name: "User_count_by_city",
///     keyPaths: ["city"],
///     kind: try! IndexKind(CountIndexKind()),
///     commonOptions: .init()
/// )
///
/// // Composite grouping: people count by department × role
/// let deptRoleCountIndex = IndexDescriptor(
///     name: "Employee_count_by_dept_role",
///     keyPaths: ["department", "role"],
///     kind: try! IndexKind(CountIndexKind()),
///     commonOptions: .init()
/// )
/// ```
///
/// **Query example**:
/// ```swift
/// // Get user count in Tokyo
/// let count = try await store.evaluateAggregate(
///     .count(indexName: "User_count_by_city"),
///     groupBy: ["Tokyo"]
/// )
/// // → Int64 (e.g., 12345)
/// ```
public struct CountIndexKind: IndexKind {
    /// Kind identifier (built-in kinds use lowercase words)
    public static let identifier = "count"

    /// Subspace structure: Aggregation (grouping key → aggregated value)
    ///
    /// **Reason**: COUNT index stores aggregated value directly
    /// - `[indexSubspace][groupKey] = count`
    /// - Update efficiently with AtomicOp (ADD)
    /// - Get count in O(1)
    public static let subspaceStructure = SubspaceStructure.aggregation

    /// Type validation: Ensure grouping fields conform to Comparable
    ///
    /// **Validation**:
    /// - Field count: 1 or more (no limit)
    /// - Each field: Comparable protocol conformance
    ///
    /// **Note**: COUNT index has no value field
    /// - Composed only of grouping fields
    /// - Count value is automatically managed by index
    ///
    /// **Examples**:
    /// ```swift
    /// // OK: Single grouping field
    /// try CountIndexKind.validateTypes([String.self])  // city
    ///
    /// // OK: Composite grouping fields
    /// try CountIndexKind.validateTypes([String.self, String.self])  // dept, role
    ///
    /// // NG: Non-Comparable type
    /// struct CustomType { ... }  // Not Comparable
    /// try CountIndexKind.validateTypes([CustomType.self])  // throws
    /// ```
    ///
    /// - Parameter types: Array of grouping field types
    /// - Throws: IndexError.invalidConfiguration
    public static func validateTypes(_ types: [Any.Type]) throws {
        // At least one grouping field is required
        guard !types.isEmpty else {
            throw IndexError.invalidConfiguration(
                "Count index requires at least 1 grouping field, got 0"
            )
        }

        // All grouping fields must conform to Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration(
                    "Count index requires Comparable types for grouping fields, got \(type)"
                )
            }
        }
    }

    /// Standard initializer
    ///
    /// **Example**:
    /// ```swift
    /// let kind = try IndexKind(CountIndexKind())
    /// ```
    public init() {}

    /// Create index maintainer (placeholder - actual implementation in upper layers)
}
