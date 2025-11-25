// MinIndexKind.swift
// FDBIndexing - MIN aggregation index kind
//
// Aggregation index for efficiently retrieving minimum value per group.
// Uses FDB's ordered key characteristics to get minimum value in O(log n).

import Foundation
import FoundationDB

/// MIN aggregation index kind
///
/// **Purpose**: Efficiently retrieve minimum value per group
/// - Group records by grouping fields
/// - Utilize FDB's ordered key characteristics
/// - Get minimum value in O(log n) with Key Selector
///
/// **Subspace structure**: flat
/// - Key: `[indexSubspace][groupingValue][value][primaryKey] = ''`
/// - Value: Empty (information contained in index key)
/// - Minimum value = first key
///
/// **Supported types**:
/// - Grouping fields: All Comparable-conforming types
/// - Value field (last field): All Comparable-conforming types
///
/// **Example**:
/// ```swift
/// // Minimum price by region
/// let minPriceByRegionIndex = IndexDescriptor(
///     name: "Product_min_price_by_region",
///     keyPaths: ["region", "price"],
///     kind: MinIndexKind(),
///     commonOptions: .init()
/// )
///
/// // Youngest age by department
/// let minAgeByDeptIndex = IndexDescriptor(
///     name: "Employee_min_age_by_dept",
///     keyPaths: ["department", "age"],
///     kind: MinIndexKind(),
///     commonOptions: .init()
/// )
/// ```
///
/// **Query example**:
/// ```swift
/// // Get minimum price in Hokkaido region
/// let minPrice = try await store.evaluateAggregate(
///     .min(indexName: "Product_min_price_by_region"),
///     groupBy: ["Hokkaido"]
/// )
/// // → Comparable value (e.g., 1980.0)
/// ```
public struct MinIndexKind: IndexKind {
    /// Kind identifier (built-in kinds use lowercase words)
    public static let identifier = "min"

    /// Subspace structure: Flat (ordered keys)
    ///
    /// **Reason**: MIN index utilizes FDB's ordered key characteristics
    /// - `[indexSubspace][groupKey][value][pk] = ''`
    /// - Keys are dictionary-sorted
    /// - Minimum value = first key (efficiently retrieved with Key Selector)
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
    /// try MinIndexKind.validateTypes([String.self, Double.self])
    ///
    /// // OK: [String, String, Int64] = [dept, subDept, age]
    /// try MinIndexKind.validateTypes([String.self, String.self, Int64.self])
    ///
    /// // OK: Custom Comparable type
    /// struct Price: Comparable { ... }
    /// try MinIndexKind.validateTypes([String.self, Price.self])
    ///
    /// // NG: Value field is non-Comparable type
    /// struct Product { ... }  // Not Comparable
    /// try MinIndexKind.validateTypes([String.self, Product.self])  // throws
    ///
    /// // NG: Insufficient fields
    /// try MinIndexKind.validateTypes([Double.self])  // throws
    /// ```
    ///
    /// - Parameter types: Array of field types (grouping + value)
    /// - Throws: IndexError.invalidConfiguration
    public static func validateTypes(_ types: [Any.Type]) throws {
        // At least 2 fields required (grouping 1 + value 1)
        guard types.count >= 2 else {
            throw IndexError.invalidConfiguration(
                "Min index requires at least 2 fields (grouping + value), got \(types.count)"
            )
        }

        // All fields must conform to Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration(
                    "Min index requires Comparable types for all fields, got \(type)"
                )
            }
        }
    }

    /// Standard initializer
    ///
    /// **Example**:
    /// ```swift
    /// let kind: any IndexKind = MinIndexKind()
    /// ```
    public init() {}

    /// Create index maintainer (placeholder - actual implementation in upper layers)
}
