// MaxIndexKind.swift
// FDBIndexing - MAX aggregation index kind
//
// Aggregation index for efficiently retrieving maximum value per group.
// Uses FDB's ordered key characteristics to get maximum value in O(log n).

import Foundation

/// MAX aggregation index kind
///
/// **Purpose**: Efficiently retrieve maximum value per group
/// - Group records by grouping fields
/// - Utilize FDB's ordered key characteristics
/// - Get maximum value in O(log n) with Key Selector
///
/// **Subspace structure**: flat
/// - Key: `[indexSubspace][groupingValue][value][primaryKey] = ''`
/// - Value: Empty (information contained in index key)
/// - Maximum value = last key
///
/// **Supported types**:
/// - Grouping fields: All Comparable-conforming types
/// - Value field (last field): All Comparable-conforming types
///
/// **Example**:
/// ```swift
/// // Maximum price by region
/// let maxPriceByRegionIndex = IndexDescriptor(
///     name: "Product_max_price_by_region",
///     keyPaths: ["region", "price"],
///     kind: try! IndexKind(MaxIndexKind()),
///     commonOptions: .init()
/// )
///
/// // Maximum salary by department
/// let maxSalaryByDeptIndex = IndexDescriptor(
///     name: "Employee_max_salary_by_dept",
///     keyPaths: ["department", "salary"],
///     kind: try! IndexKind(MaxIndexKind()),
///     commonOptions: .init()
/// )
/// ```
///
/// **Query example**:
/// ```swift
/// // Get maximum price in Tokyo region
/// let maxPrice = try await store.evaluateAggregate(
///     .max(indexName: "Product_max_price_by_region"),
///     groupBy: ["Tokyo"]
/// )
/// // → Comparable value (e.g., 29800.0)
/// ```
public struct MaxIndexKind: IndexKindProtocol {
    /// Kind identifier (built-in kinds use lowercase words)
    public static let identifier = "max"

    /// Subspace structure: Flat (ordered keys)
    ///
    /// **Reason**: MAX index utilizes FDB's ordered key characteristics
    /// - `[indexSubspace][groupKey][value][pk] = ''`
    /// - Keys are dictionary-sorted
    /// - Maximum value = last key (efficiently retrieved with Key Selector)
    public static let subspaceStructure = SubspaceStructure.flat

    /// Type validation: Grouping fields (Comparable) + value field (Comparable)
    ///
    /// **Validation**:
    /// - Field count: 2 or more (at least grouping 1 + value 1)
    /// - Grouping fields: Comparable protocol conformance
    /// - Value field (last): Comparable protocol conformance
    ///
    /// **Field composition**:
    /// ```
    /// [Grouping1, Grouping2, ..., Value field]
    ///  ^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^
    ///  Comparable conformance     Comparable conformance
    /// ```
    ///
    /// **Examples**:
    /// ```swift
    /// // OK: [String, Double] = [region, price]
    /// try MaxIndexKind.validateTypes([String.self, Double.self])
    ///
    /// // OK: [String, String, Int64] = [dept, subDept, salary]
    /// try MaxIndexKind.validateTypes([String.self, String.self, Int64.self])
    ///
    /// // OK: Custom Comparable type
    /// struct Salary: Comparable { ... }
    /// try MaxIndexKind.validateTypes([String.self, Salary.self])
    ///
    /// // NG: Value field is non-Comparable type
    /// struct Employee { ... }  // Not Comparable
    /// try MaxIndexKind.validateTypes([String.self, Employee.self])  // throws
    ///
    /// // NG: Insufficient fields
    /// try MaxIndexKind.validateTypes([Double.self])  // throws
    /// ```
    ///
    /// - Parameter types: Array of field types (grouping + value)
    /// - Throws: IndexTypeValidationError
    public static func validateTypes(_ types: [Any.Type]) throws {
        // At least 2 fields required (grouping 1 + value 1)
        guard types.count >= 2 else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 2,
                actual: types.count
            )
        }

        // All fields must conform to Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(
                    index: identifier,
                    type: type,
                    reason: "Max index requires Comparable types for all fields"
                )
            }
        }
    }

    /// Standard initializer
    ///
    /// **Example**:
    /// ```swift
    /// let kind = try IndexKind(MaxIndexKind())
    /// ```
    public init() {}
}
