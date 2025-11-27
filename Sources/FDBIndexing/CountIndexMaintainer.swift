// CountIndexMaintainer.swift
// FDBIndexing - Count aggregation index maintainer implementation
//
// Maintains count indexes for counting records by grouping keys.

import Foundation
import FoundationDB
import FDBModel
import FDBCore

/// Maintains count aggregation indexes by grouping keys
///
/// **Key Structure**: `[subspace][groupKey...] = Int64(count)`
///
/// **Supports**:
/// - Get count by group key
/// - Atomic increment on insert
/// - Atomic decrement on delete
///
/// **Usage**:
/// ```swift
/// let index = Index(
///     name: "User_count_by_city",
///     kind: CountIndexKind(),
///     rootExpression: FieldKeyExpression(fieldName: "city"),
///     subspaceKey: "User_count_by_city"
/// )
///
/// let maintainer = CountIndexMaintainer<User>(
///     index: index,
///     subspace: indexSubspace
/// )
/// ```
public struct CountIndexMaintainer<Item: Persistable>: IndexMaintainer {
    // MARK: - Properties

    /// Index definition
    public let index: Index

    /// Subspace for index storage
    public let subspace: Subspace

    /// ID expression for extracting item's unique identifier
    public let idExpression: KeyExpression

    // MARK: - Initialization

    /// Create a CountIndexMaintainer
    ///
    /// - Parameters:
    ///   - index: Index definition
    ///   - subspace: Subspace for index storage
    ///   - idExpression: Expression for extracting item's unique identifier
    public init(index: Index, subspace: Subspace, idExpression: KeyExpression) {
        self.index = index
        self.subspace = subspace
        self.idExpression = idExpression
    }

    // MARK: - IndexMaintainer

    /// Update index entries when an item changes
    ///
    /// - Insert (oldItem=nil, newItem=value): Increment count
    /// - Update (oldItem=value, newItem=value): Check if groupKey changed
    /// - Delete (oldItem=value, newItem=nil): Decrement count
    public func updateIndex(
        oldItem: Item?,
        newItem: Item?,
        transaction: any TransactionProtocol
    ) async throws {
        // Get old grouping key
        let oldGroupKey: [UInt8]?
        if let old = oldItem {
            oldGroupKey = try buildGroupKey(for: old)
        } else {
            oldGroupKey = nil
        }

        // Get new grouping key
        let newGroupKey: [UInt8]?
        if let new = newItem {
            newGroupKey = try buildGroupKey(for: new)
        } else {
            newGroupKey = nil
        }

        // Determine what changed
        let oldKeyChanged = oldGroupKey != nil && (newGroupKey == nil || oldGroupKey! != newGroupKey!)
        let newKeyChanged = newGroupKey != nil && (oldGroupKey == nil || newGroupKey! != oldGroupKey!)

        // Decrement old count if key changed or deleted
        if let key = oldGroupKey, oldKeyChanged {
            let decrement = withUnsafeBytes(of: Int64(-1).littleEndian) { Array($0) }
            transaction.atomicOp(key: key, param: decrement, mutationType: .add)
        }

        // Increment new count if key changed or inserted
        if let key = newGroupKey, newKeyChanged {
            let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
            transaction.atomicOp(key: key, param: increment, mutationType: .add)
        }
    }

    /// Build index entries for an item during batch indexing
    public func scanItem(
        _ item: Item,
        id: Tuple,
        transaction: any TransactionProtocol
    ) async throws {
        let key = try buildGroupKey(for: item)
        let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
        transaction.atomicOp(key: key, param: increment, mutationType: .add)
    }

    // MARK: - Private

    /// Build grouping key for an item
    ///
    /// Key structure: [subspace][groupKey...]
    private func buildGroupKey(for item: Item) throws -> [UInt8] {
        // Extract all field values (all are grouping keys for CountIndex)
        let fieldValues = try DataAccess.evaluate(item: item, expression: index.rootExpression)

        // Build key: [subspace][groupKey...]
        var allElements: [any TupleElement] = []
        for value in fieldValues {
            allElements.append(value)
        }

        return subspace.pack(Tuple(allElements))
    }
}

// MARK: - IndexKindMaintainable Extension

extension CountIndexKind: IndexKindMaintainable {
    /// Create a CountIndexMaintainer for this index kind
    public func makeIndexMaintainer<Item: Persistable>(
        index: Index,
        subspace: Subspace,
        idExpression: KeyExpression
    ) -> any IndexMaintainer<Item> {
        return CountIndexMaintainer<Item>(
            index: index,
            subspace: subspace.subspace(index.name),
            idExpression: idExpression
        )
    }
}
