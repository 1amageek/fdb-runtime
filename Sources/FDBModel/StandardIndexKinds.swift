// StandardIndexKinds.swift
// FDBModel - Standard IndexKind implementations (FDB-independent)
//
// These implementations are FDB-independent and can be used across all platforms.
// They are automatically available when importing FDBModel.

import Foundation

// MARK: - ScalarIndexKind

/// Standard VALUE index for sorting and range queries
///
/// This is the default index kind used by the #Index macro when no type is specified.
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     #Index<User>([\.email], type: ScalarIndexKind(), unique: true)
///     var email: String
/// }
/// ```
///
/// **Key Structure**: `[indexSubspace][fieldValue][primaryKey] = ''`
///
/// **Supports**:
/// - Exact match queries
/// - Range queries
/// - Prefix queries
/// - Unique constraints
public struct ScalarIndexKind: IndexKind {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard !types.isEmpty else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 1,
                actual: 0
            )
        }
        // Validate all fields are Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(
                    index: identifier,
                    type: type,
                    reason: "Scalar index requires Comparable types"
                )
            }
        }
    }

    public init() {}
}

// MARK: - CountIndexKind

/// Aggregation index for counting records by grouping fields
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     #Index<User>([\.city], type: CountIndexKind())
///     var city: String
/// }
/// ```
///
/// **Key Structure**: `[indexSubspace][groupKey] = Int64(count)`
///
/// **Supports**:
/// - Get count by group key
/// - Atomic increment/decrement on insert/delete
public struct CountIndexKind: IndexKind {
    public static let identifier = "count"
    public static let subspaceStructure = SubspaceStructure.aggregation

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard !types.isEmpty else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 1,
                actual: 0
            )
        }
        // Validate all grouping fields are Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(
                    index: identifier,
                    type: type,
                    reason: "Count index grouping fields must be Comparable"
                )
            }
        }
    }

    public init() {}
}

// MARK: - SumIndexKind

/// Aggregation index for summing numeric values by grouping fields
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct Order {
///     #Index<Order>([\.customerId, \.amount], type: SumIndexKind())
///     var customerId: String
///     var amount: Double
/// }
/// ```
///
/// **Key Structure**: `[indexSubspace][groupKey] = Double(sum)`
/// Last field in keyPaths is the value field; preceding fields are grouping keys.
///
/// **Supports**:
/// - Get sum by group key
/// - Atomic add/subtract on insert/update/delete
public struct SumIndexKind: IndexKind {
    public static let identifier = "sum"
    public static let subspaceStructure = SubspaceStructure.aggregation

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count >= 2 else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 2,
                actual: types.count
            )
        }
        // Validate grouping fields (all but last) are Comparable
        let groupingTypes = types.dropLast()
        for type in groupingTypes {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(
                    index: identifier,
                    type: type,
                    reason: "Sum index grouping fields must be Comparable"
                )
            }
        }
        // Validate value field (last) is Numeric
        let valueType = types.last!
        guard TypeValidation.isNumeric(valueType) else {
            throw IndexTypeValidationError.unsupportedType(
                index: identifier,
                type: valueType,
                reason: "Sum index value field must be Numeric"
            )
        }
    }

    public init() {}
}

// MARK: - MinIndexKind

/// Aggregation index for tracking minimum values by grouping fields
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct Product {
///     #Index<Product>([\.category, \.price], type: MinIndexKind())
///     var category: String
///     var price: Double
/// }
/// ```
///
/// **Key Structure**: `[indexSubspace][groupKey][value][primaryKey] = ''`
/// Last field in keyPaths is the value field; preceding fields are grouping keys.
///
/// **Supports**:
/// - Get minimum value by group key
/// - Efficient min tracking via sorted storage
public struct MinIndexKind: IndexKind {
    public static let identifier = "min"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count >= 2 else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 2,
                actual: types.count
            )
        }
        // Validate all fields are Comparable (both grouping and value)
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(
                    index: identifier,
                    type: type,
                    reason: "Min index requires all fields to be Comparable"
                )
            }
        }
    }

    public init() {}
}

// MARK: - MaxIndexKind

/// Aggregation index for tracking maximum values by grouping fields
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct Product {
///     #Index<Product>([\.category, \.price], type: MaxIndexKind())
///     var category: String
///     var price: Double
/// }
/// ```
///
/// **Key Structure**: `[indexSubspace][groupKey][value][primaryKey] = ''`
/// Last field in keyPaths is the value field; preceding fields are grouping keys.
///
/// **Supports**:
/// - Get maximum value by group key
/// - Efficient max tracking via reverse-sorted storage
public struct MaxIndexKind: IndexKind {
    public static let identifier = "max"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count >= 2 else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 2,
                actual: types.count
            )
        }
        // Validate all fields are Comparable (both grouping and value)
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexTypeValidationError.unsupportedType(
                    index: identifier,
                    type: type,
                    reason: "Max index requires all fields to be Comparable"
                )
            }
        }
    }

    public init() {}
}

// MARK: - VersionIndexKind

/// Index for tracking record versions
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     #Index<User>([\.version], type: VersionIndexKind())
///     var version: Int64
/// }
/// ```
///
/// **Key Structure**: `[indexSubspace][version][primaryKey] = ''`
///
/// **Supports**:
/// - Range queries by version
/// - Find records modified after a specific version
public struct VersionIndexKind: IndexKind {
    public static let identifier = "version"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count == 1 else {
            throw IndexTypeValidationError.invalidTypeCount(
                index: identifier,
                expected: 1,
                actual: types.count
            )
        }
        // Validate version field is Comparable (typically Int64)
        let versionType = types[0]
        guard TypeValidation.isComparable(versionType) else {
            throw IndexTypeValidationError.unsupportedType(
                index: identifier,
                type: versionType,
                reason: "Version index requires Comparable type"
            )
        }
    }

    public init() {}
}
