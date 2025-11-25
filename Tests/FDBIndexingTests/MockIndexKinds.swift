// MockIndexKinds.swift
// FDBIndexing Tests - Mock IndexKind implementations for testing

import Foundation
import FDBModel
import FoundationDB
import FDBModel
import FDBCore
@testable import FDBIndexing

// MARK: - ScalarIndexKind (Mock)

/// Mock implementation of ScalarIndexKind for testing
public struct ScalarIndexKind: IndexKind {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard !types.isEmpty else {
            throw IndexError.invalidConfiguration("Scalar index requires at least 1 field")
        }

        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration("Scalar index requires Comparable types, got \(type)")
            }
        }
    }

    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return MockIndexMaintainer<Item>()
    }

    public init() {}
}

// MARK: - CountIndexKind (Mock)

/// Mock implementation of CountIndexKind for testing
public struct CountIndexKind: IndexKind {
    public static let identifier = "count"
    public static let subspaceStructure = SubspaceStructure.aggregation

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard !types.isEmpty else {
            throw IndexError.invalidConfiguration("Count index requires at least 1 grouping field, got 0")
        }

        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration("Count index requires Comparable types for grouping fields, got \(type)")
            }
        }
    }

    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return MockIndexMaintainer<Item>()
    }

    public init() {}
}

// MARK: - SumIndexKind (Mock)

/// Mock implementation of SumIndexKind for testing
public struct SumIndexKind: IndexKind {
    public static let identifier = "sum"
    public static let subspaceStructure = SubspaceStructure.aggregation

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count >= 2 else {
            throw IndexError.invalidConfiguration("Sum index requires at least 2 fields (grouping + value), got \(types.count)")
        }

        // Validate grouping fields (all but last)
        for type in types.dropLast() {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration("Sum index requires Comparable grouping fields, got \(type)")
            }
        }

        // Validate value field (last)
        let valueType = types.last!
        guard TypeValidation.isNumeric(valueType) else {
            throw IndexError.invalidConfiguration("Sum index requires numeric value field, got \(valueType)")
        }
    }

    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return MockIndexMaintainer<Item>()
    }

    public init() {}
}

// MARK: - MinIndexKind (Mock)

/// Mock implementation of MinIndexKind for testing
public struct MinIndexKind: IndexKind {
    public static let identifier = "min"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count >= 2 else {
            throw IndexError.invalidConfiguration("Min index requires at least 2 fields (grouping + value), got \(types.count)")
        }

        // All fields must be Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration("Min index requires Comparable fields, got \(type)")
            }
        }
    }

    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return MockIndexMaintainer<Item>()
    }

    public init() {}
}

// MARK: - MaxIndexKind (Mock)

/// Mock implementation of MaxIndexKind for testing
public struct MaxIndexKind: IndexKind {
    public static let identifier = "max"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count >= 2 else {
            throw IndexError.invalidConfiguration("Max index requires at least 2 fields (grouping + value), got \(types.count)")
        }

        // All fields must be Comparable
        for type in types {
            guard TypeValidation.isComparable(type) else {
                throw IndexError.invalidConfiguration("Max index requires Comparable fields, got \(type)")
            }
        }
    }

    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return MockIndexMaintainer<Item>()
    }

    public init() {}
}

// MARK: - VersionIndexKind (Mock)

/// Mock implementation of VersionIndexKind for testing
public struct VersionIndexKind: IndexKind {
    public static let identifier = "version"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard types.count == 1 else {
            throw IndexError.invalidConfiguration("Version index requires exactly 1 field, got \(types.count)")
        }
    }

    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        configuration: AlgorithmConfiguration?
    ) throws -> any IndexMaintainer<Item> {
        return MockIndexMaintainer<Item>()
    }

    public init() {}
}

// MARK: - MockIndexMaintainer

/// Minimal IndexMaintainer implementation for testing IndexKind protocol
struct MockIndexMaintainer<Item: Persistable>: IndexMaintainer {
    func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        transaction: any TransactionProtocol
    ) async throws {
        // No-op for testing
    }

    func scanItem(
        _ item: Item,
        primaryKey: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        // No-op for testing
    }
}
