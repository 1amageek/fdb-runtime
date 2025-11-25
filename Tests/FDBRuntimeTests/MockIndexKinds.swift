// MockIndexKinds.swift
// FDBRuntime Tests - Mock IndexKind implementations for testing

import Foundation
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

// MARK: - MockIndexMaintainer

/// Minimal IndexMaintainer implementation for testing
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
