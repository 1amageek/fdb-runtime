// SumIndexKind.swift
// FDBIndexing - SUM aggregation index kind
//
// Aggregation index that calculates sum of numeric field per group.
// Stores Int64 sum value for each grouping key.

import Foundation
import FoundationDB

/// SUM aggregation index kind
///
/// **Purpose**: Efficiently retrieve numeric sum per group
/// - Group records by grouping fields
/// - Store sum of numeric field directly
/// - Update with AtomicOp (ADD/SUBTRACT)
///
/// **Subspace structure**: aggregation
/// - Key: `[indexSubspace][groupingValue] = Int64(sum)`
/// - Value: Sum value (Int64, Little Endian)
///
/// **Supported types**:
/// - Grouping fields: All Comparable-conforming types
/// - Value field (last field): Numeric types only (Int, Int64, Double, etc.)
///
/// **Example**:
/// ```swift
/// // Salary sum by department
/// let salaryByDeptIndex = IndexDescriptor(
///     name: "Employee_salary_by_dept",
///     keyPaths: ["department", "salary"],
///     kind: try! IndexKind(SumIndexKind()),
///     commonOptions: .init()
/// )
///
/// // Total sales by category
/// let salesByCategoryIndex = IndexDescriptor(
///     name: "Product_sales_by_category",
///     keyPaths: ["category", "totalSales"],
///     kind: try! IndexKind(SumIndexKind()),
///     commonOptions: .init()
/// )
/// ```
///
/// **Query example**:
/// ```swift
/// // Get total salary for Engineering department
/// let total = try await store.evaluateAggregate(
///     .sum(indexName: "Employee_salary_by_dept"),
///     groupBy: ["Engineering"]
/// )
/// // → Int64 (e.g., 50000000)
/// ```
public struct SumIndexKind: IndexKind {
    /// Kind identifier (built-in kinds use lowercase words)
    public static let identifier = "sum"

    /// Subspace structure: Aggregation (grouping key → aggregated value)
    ///
    /// **Reason**: SUM index stores aggregated value directly
    /// - `[indexSubspace][groupKey] = sum`
    /// - Update efficiently with AtomicOp (ADD)
    /// - Get sum in O(1)
    public static let subspaceStructure = SubspaceStructure.aggregation

    /// Type validation: Grouping fields (Comparable) + value field (numeric)
    ///
    /// **Validation**:
    /// - Field count: 2 or more (at least grouping 1 + value 1)
    /// - Grouping fields: Comparable protocol conformance
    /// - Value field (last): Numeric type (Int, Int64, Double, etc.)
    ///
    /// **Field composition**:
    /// ```
    /// [Grouping1, Grouping2, ..., Value field]
    ///  ^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^
    ///  Comparable conformance     Numeric type
    /// ```
    ///
    /// **Examples**:
    /// ```swift
    /// // OK: [String, Int64] = [department, salary]
    /// try SumIndexKind.validateTypes([String.self, Int64.self])
    ///
    /// // OK: [String, String, Double] = [category, region, amount]
    /// try SumIndexKind.validateTypes([String.self, String.self, Double.self])
    ///
    /// // NG: Value field is not numeric
    /// try SumIndexKind.validateTypes([String.self, String.self])  // throws
    ///
    /// // NG: Insufficient fields
    /// try SumIndexKind.validateTypes([Int64.self])  // throws
    /// ```
    ///
    /// - Parameter types: Array of field types (grouping + value)
    /// - Throws: IndexError.invalidConfiguration
    public static func validateTypes(_ types: [Any.Type]) throws {
        // At least 2 fields required (grouping 1 + value 1)
        guard types.count >= 2 else {
            throw IndexError.invalidConfiguration(
                "Sum index requires at least 2 fields (grouping + value), got \(types.count)"
            )
        }

        // Grouping fields (all except last field)
        let groupingFields = types.dropLast()
        for type in groupingFields {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration(
                    "Sum index requires Comparable types for grouping fields, got \(type)"
                )
            }
        }

        // Value field (last field) must be numeric
        guard let valueField = types.last else {
            // This should never happen due to guard at line 97
            fatalError("Internal error: types array is empty after validation")
        }
        guard TypeValidation.isNumeric(valueField) else {
            throw IndexError.invalidConfiguration(
                "Sum index requires numeric type (Int, Int64, Double, etc.) for value field, got \(valueField)"
            )
        }
    }

    /// Standard initializer
    ///
    /// **Example**:
    /// ```swift
    /// let kind = try IndexKind(SumIndexKind())
    /// ```
    public init() {}

    /// Create index maintainer (placeholder - actual implementation in upper layers)
}
