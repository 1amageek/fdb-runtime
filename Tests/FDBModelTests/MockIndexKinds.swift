// MockIndexKinds.swift
// FDBModel Tests - Mock IndexKind implementations for testing

import Foundation
@testable import FDBModel

// MARK: - ScalarIndexKind (Mock)

/// Mock implementation of ScalarIndexKind for testing
public struct ScalarIndexKind: IndexKind {
    public static let identifier = "scalar"
    public static let subspaceStructure = SubspaceStructure.flat

    public static func validateTypes(_ types: [Any.Type]) throws {
        guard !types.isEmpty else {
            throw IndexError.invalidConfiguration("Scalar index requires at least 1 field")
        }
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

    public init() {}
}
